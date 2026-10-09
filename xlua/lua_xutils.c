/* lua_xutils.c - Small generic Lua utility bindings.
**
** Keep this module as a lightweight grab bag for tiny helpers.
** Current API:
**   xutils.json_pack(value)   -> JSON string
**   xutils.json_unpack(text)  -> Lua value
**   xutils.json_null          -> sentinel for JSON null
**   xutils.json_array_mt      -> metatable marking a table as a JSON array
**   xutils.stdout_binary()    -> true | nil,err (disable Windows CRLF translation)
**   xutils.cpu_count()        -> integer >= 1 (system online logical CPUs; ignores affinity and CPU quotas)
**   xutils.load_config(path)  -> true | false,err
**   xutils.get_config(key[, default]) -> value | default | nil
**   xutils.get_int(key[, default])    -> integer | nil   (default: integer)
**   xutils.get_double(key[, default]) -> number | nil    (default: number)
**   xutils.get_string(key[, default]) -> string | nil    (default: string)
**   xutils.scan_dir(path)     -> { { path=..., rel=... }, ... } | nil,err
**   xutils.list_dir(path[, limit[, with_stat]]) -> { { name=..., dir=... }, ... }, truncated | nil,err
**                             (one level; with_stat adds type, size, mtime as in stat)
**   xutils.stat(path)         -> { exists, type, size, mtime } | nil,err (no symlink following)
**   xutils.mkdir_p(path)      -> true | nil,err
**   xutils.rmtree(path)       -> true | nil,err
**   xutils.cwd()              -> string | nil,err
**   xutils.pbkdf2_sha256(pw, salt, iter [, dklen]) -> raw string | nil,err
**   xutils.aes_cbc_encrypt(key, iv, data) -> raw string | nil,err  (no padding)
**   xutils.aes_cbc_decrypt(key, iv, data) -> raw string | nil,err  (no padding)
*/

#include <math.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <stdio.h>
#include <limits.h>
#include <errno.h>

/* System headers must precede xmacro.h's allocator overrides. */
#if defined(__ANDROID__)
#include <jni.h>
#elif defined(__APPLE__)
#include <TargetConditionals.h>
#if TARGET_OS_IPHONE
#include <CoreFoundation/CoreFoundation.h>
#else
#include <iconv.h>
#endif
#elif !defined(_WIN32)
#include <iconv.h>
#endif

#ifdef _WIN32
#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif
#include <windows.h>
#include <io.h>
#include <fcntl.h>
#else
#include <dirent.h>
#include <sys/stat.h>
#include <fcntl.h>
#include <unistd.h>
#include <poll.h>
#if defined(__APPLE__)
#include <sys/attr.h>
#include <sys/vnode.h>
#elif defined(__linux__)
#include <sys/syscall.h>
#endif
#endif

#if defined(LUA_EMBEDDED)
#include "../3rd/minilua.h"
#else
#include "lua.h"
#include "lauxlib.h"
#include "xlua_compat.h"
#endif

/* yyjson.h has inline funcs that call alc.free(ctx, ptr) — that field name
** would collide with a function-like `free` macro, so yyjson.h MUST be
** preprocessed before xmacro.h takes effect. xmacro.h goes last. */
#include "../3rd/yyjson.h"
#include "xargs.h"

/* mbedTLS hash primitives. These four files are self-contained (no SSL / x509 /
** PSA dependencies), so the build links them on every configuration -- HTTPS or
** not -- and xutils exposes sha1/sha256/sha512/md5 + HMAC unconditionally.
** Pure declarations, safe to include before xmacro.h. */
#include "mbedtls/sha1.h"
#include "mbedtls/sha256.h"
#include "mbedtls/sha512.h"
#include "mbedtls/md5.h"
#include "mbedtls/aes.h"

#include "../xmacro.h"   /* malloc/free → rpmalloc; must be last include */

/* yyjson allocator routed through xmacro.h.
**
** Why this is needed:
**   yyjson's default allocator (passed as NULL) is libc malloc/free. Output
**   strings from yyjson_*_write_opts() are libc-allocated and the caller is
**   expected to libc-free them. But once xmacro.h is in scope, the bare
**   free(out) call in this file gets rewritten to rpfree(out) — feeding a
**   libc pointer to rpmalloc's free path, which corrupts the rp heap
**   (observed: STATUS_HEAP_CORRUPTION 0xC0000374 mid-test). Passing this
**   allocator into every yyjson entry point keeps both ends consistent.
**
** With WITH_RPMALLOC=0 the malloc/realloc/free inside these trampolines
** resolve back to libc (xmacro.h is pass-through in that mode), so behaviour
** matches the yyjson default — no #ifdef needed at the call sites. */
static void *xj_alc_malloc(void *ctx, size_t size) {
    (void)ctx;
    return malloc(size);
}
static void *xj_alc_realloc(void *ctx, void *ptr, size_t old_size, size_t size) {
    (void)ctx;
    (void)old_size;
    return realloc(ptr, size);
}
static void xj_alc_free(void *ctx, void *ptr) {
    (void)ctx;
    free(ptr);
}
static const yyjson_alc g_xj_alc = {
    xj_alc_malloc,
    xj_alc_realloc,
    xj_alc_free,
    NULL    /* no ctx needed — the allocator is process-global */
};

static lua_Integer lua_integer_max(void) {
    if (sizeof(lua_Integer) >= sizeof(long long)) return (lua_Integer)LLONG_MAX;
    if (sizeof(lua_Integer) >= sizeof(long)) return (lua_Integer)LONG_MAX;
    return (lua_Integer)INT_MAX;
}

static lua_Integer lua_integer_min(void) {
    if (sizeof(lua_Integer) >= sizeof(long long)) return (lua_Integer)LLONG_MIN;
    if (sizeof(lua_Integer) >= sizeof(long)) return (lua_Integer)LONG_MIN;
    return (lua_Integer)INT_MIN;
}

#ifndef lua_absindex
#define lua_absindex(L, i) \
    (((i) > 0 || (i) <= LUA_REGISTRYINDEX) ? (i) : lua_gettop(L) + (i) + 1)
#endif

#define LUA_UTIL_JSON_MAX_DEPTH 64

static char g_json_null_token;

static void push_json_null(lua_State *L) {
    lua_pushlightuserdata(L, &g_json_null_token);
}

static int is_json_null(lua_State *L, int idx) {
    return lua_touserdata(L, idx) == &g_json_null_token;
}

/* Lua cannot tell an empty array from an empty object, so json_unpack tags
** every decoded array with this metatable and json_pack encodes a tagged
** table as an array even when it is empty: [] round-trips as [] instead of
** turning into {}. Code building an empty array itself uses
** setmetatable({}, xutils.json_array_mt). Kept in the registry, so each
** lua_State has its own; luaL_newmetatable creates it on first use. */
#define JSON_ARRAY_MT "xutils.json_array_mt"

static void push_json_array_mt(lua_State *L) {
    luaL_newmetatable(L, JSON_ARRAY_MT);
}

static int is_json_array(lua_State *L, int idx) {
    int tagged;
    if (!lua_getmetatable(L, idx)) return 0;
    push_json_array_mt(L);
    tagged = lua_rawequal(L, -1, -2);
    lua_pop(L, 2);
    return tagged;
}

static int table_is_empty(lua_State *L, int idx) {
    lua_pushnil(L);
    if (!lua_next(L, idx)) return 1;
    lua_pop(L, 2);
    return 0;
}

static int json_error(lua_State *L, const char *msg) {
    lua_pushnil(L);
    lua_pushstring(L, msg ? msg : "json error");
    return 2;
}

static int lua_json_push_value(lua_State *L, const yyjson_val *val, int depth);
static yyjson_mut_val *lua_json_to_value(lua_State *L, yyjson_mut_doc *doc,
                                         int idx, int depth);

static int lua_json_table_is_array(lua_State *L, int idx, lua_Integer *out_len) {
    int base = lua_gettop(L);
    lua_Integer count = 0;
    lua_Integer max = 0;
    int is_array = 1;

    idx = lua_absindex(L, idx);
    lua_pushnil(L);
    while (lua_next(L, idx) != 0) {
        if (!lua_isinteger(L, -2)) {
            is_array = 0;
            lua_pop(L, 1);
            break;
        }

        lua_Integer key = lua_tointeger(L, -2);
        if (key < 1) {
            is_array = 0;
            lua_pop(L, 1);
            break;
        }

        count++;
        if (key > max) max = key;
        lua_pop(L, 1);
    }

    lua_settop(L, base);
    if (is_array && count > 0 && count == max) {
        *out_len = max;
        return 1;
    }
    *out_len = 0;
    return 0;
}

static yyjson_mut_val *lua_json_make_key(lua_State *L, yyjson_mut_doc *doc,
                                         int idx) {
    idx = lua_absindex(L, idx);
    switch (lua_type(L, idx)) {
    case LUA_TSTRING: {
        size_t len = 0;
        const char *s = lua_tolstring(L, idx, &len);
        return yyjson_mut_strncpy(doc, s, len);
    }
    case LUA_TNUMBER:
    case LUA_TBOOLEAN: {
        size_t len = 0;
        const char *s = luaL_tolstring(L, idx, &len);
        yyjson_mut_val *key = yyjson_mut_strncpy(doc, s, len);
        lua_pop(L, 1);
        return key;
    }
    default:
        return NULL;
    }
}

static yyjson_mut_val *lua_json_from_table(lua_State *L, yyjson_mut_doc *doc,
                                           int idx, int depth) {
    int base = lua_gettop(L);
    lua_Integer array_len = 0;
    yyjson_mut_val *root = NULL;

    if (depth > LUA_UTIL_JSON_MAX_DEPTH) {
        return NULL;
    }

    idx = lua_absindex(L, idx);
    /* The tag only decides the empty case; a non-empty table keeps the
    ** usual shape detection, so the tag never changes what it encodes to. */
    if (lua_json_table_is_array(L, idx, &array_len)
        || (is_json_array(L, idx) && table_is_empty(L, idx))) {
        root = yyjson_mut_arr(doc);
        if (!root) {
            lua_settop(L, base);
            return NULL;
        }

        for (lua_Integer i = 1; i <= array_len; i++) {
            lua_rawgeti(L, idx, i);
            yyjson_mut_val *child = lua_json_to_value(L, doc, -1, depth + 1);
            lua_pop(L, 1);
            if (!child || !yyjson_mut_arr_add_val(root, child)) {
                lua_settop(L, base);
                return NULL;
            }
        }

        lua_settop(L, base);
        return root;
    }

    root = yyjson_mut_obj(doc);
    if (!root) {
        lua_settop(L, base);
        return NULL;
    }

    lua_pushnil(L);
    while (lua_next(L, idx) != 0) {
        yyjson_mut_val *key = lua_json_make_key(L, doc, -2);
        if (!key) {
            lua_settop(L, base);
            return NULL;
        }

        yyjson_mut_val *child = lua_json_to_value(L, doc, -1, depth + 1);
        lua_pop(L, 1);
        if (!child || !yyjson_mut_obj_add(root, key, child)) {
            lua_settop(L, base);
            return NULL;
        }
    }

    lua_settop(L, base);
    return root;
}

static yyjson_mut_val *lua_json_to_value(lua_State *L, yyjson_mut_doc *doc,
                                         int idx, int depth) {
    idx = lua_absindex(L, idx);
    if (depth > LUA_UTIL_JSON_MAX_DEPTH) {
        return NULL;
    }

    switch (lua_type(L, idx)) {
    case LUA_TNIL:
        return yyjson_mut_null(doc);
    case LUA_TBOOLEAN:
        return yyjson_mut_bool(doc, lua_toboolean(L, idx) ? true : false);
    case LUA_TNUMBER:
        if (lua_isinteger(L, idx)) {
            lua_Integer n = lua_tointeger(L, idx);
            return yyjson_mut_int(doc, (int64_t)n);
        } else {
            double d = lua_tonumber(L, idx);
            if (!isfinite(d)) return NULL;
            return yyjson_mut_double(doc, d);
        }
    case LUA_TSTRING: {
        size_t len = 0;
        const char *s = lua_tolstring(L, idx, &len);
        return yyjson_mut_strncpy(doc, s, len);
    }
    case LUA_TLIGHTUSERDATA:
        if (is_json_null(L, idx)) return yyjson_mut_null(doc);
        return NULL;
    case LUA_TTABLE:
        return lua_json_from_table(L, doc, idx, depth);
    default:
        return NULL;
    }
}

static int lua_json_push_array(lua_State *L, const yyjson_val *val, int depth) {
    int base = lua_gettop(L);
    size_t len = yyjson_get_len(val);
    yyjson_arr_iter iter = yyjson_arr_iter_with(val);
    yyjson_val *elem = NULL;
    lua_Integer i = 1;

    if (len > (size_t)lua_integer_max()) {
        return 0;
    }

    lua_createtable(L, len <= (size_t)INT_MAX ? (int)len : 0, 0);
    while ((elem = yyjson_arr_iter_next(&iter)) != NULL) {
        if (!lua_json_push_value(L, elem, depth + 1)) {
            lua_settop(L, base);
            return 0;
        }
        lua_rawseti(L, -2, i++);
    }
    push_json_array_mt(L);
    lua_setmetatable(L, -2);

    return 1;
}

static int lua_json_push_object(lua_State *L, const yyjson_val *val, int depth) {
    int base = lua_gettop(L);
    yyjson_obj_iter iter = yyjson_obj_iter_with(val);
    yyjson_val *key = NULL;

    lua_newtable(L);
    while ((key = yyjson_obj_iter_next(&iter)) != NULL) {
        const char *name = yyjson_get_str(key);
        size_t name_len = yyjson_get_len(key);
        yyjson_val *child = yyjson_obj_iter_get_val(key);

        if (!name) {
            lua_settop(L, base);
            return 0;
        }
        if (!lua_json_push_value(L, child, depth + 1)) {
            lua_settop(L, base);
            return 0;
        }

        lua_pushlstring(L, name, name_len);
        lua_insert(L, -2);
        lua_rawset(L, -3);
    }

    return 1;
}

static int lua_json_push_value(lua_State *L, const yyjson_val *val, int depth) {
    if (depth > LUA_UTIL_JSON_MAX_DEPTH) return 0;

    switch (yyjson_get_type(val)) {
    case YYJSON_TYPE_NULL:
        push_json_null(L);
        return 1;
    case YYJSON_TYPE_BOOL:
        lua_pushboolean(L, yyjson_get_bool(val));
        return 1;
    case YYJSON_TYPE_NUM:
        if (yyjson_is_uint(val)) {
            uint64_t n = yyjson_get_uint(val);
            if (n <= (uint64_t)lua_integer_max()) {
                lua_pushinteger(L, (lua_Integer)n);
            } else {
                lua_pushnumber(L, (lua_Number)n);
            }
            return 1;
        }
        if (yyjson_is_sint(val)) {
            int64_t n = yyjson_get_sint(val);
            if (n < (int64_t)lua_integer_min() || n > (int64_t)lua_integer_max()) {
                lua_pushnumber(L, (lua_Number)n);
            } else {
                lua_pushinteger(L, (lua_Integer)n);
            }
            return 1;
        }
        lua_pushnumber(L, yyjson_get_num(val));
        return 1;
    case YYJSON_TYPE_STR: {
        const char *s = yyjson_get_str(val);
        size_t len = yyjson_get_len(val);
        lua_pushlstring(L, s ? s : "", len);
        return 1;
    }
    case YYJSON_TYPE_ARR:
        return lua_json_push_array(L, val, depth);
    case YYJSON_TYPE_OBJ:
        return lua_json_push_object(L, val, depth);
    default:
        return 0;
    }
}

static int l_util_json_pack(lua_State *L) {
    luaL_checkstack(L, LUA_UTIL_JSON_MAX_DEPTH * 4 + 32,
                    "json pack: too many nested values");

    yyjson_mut_doc *doc = yyjson_mut_doc_new(&g_xj_alc);
    if (!doc) {
        return json_error(L, "json pack: out of memory");
    }

    yyjson_mut_val *root = lua_json_to_value(L, doc, 1, 0);
    if (!root) {
        yyjson_mut_doc_free(doc);
        return json_error(L, "json pack: unsupported value or too deep");
    }

    yyjson_write_err err;
    memset(&err, 0, sizeof(err));
    size_t len = 0;
    /* g_xj_alc here makes the returned `out` come from our allocator, so the
    ** free(out) below (routed by xmacro.h) lands on the matching free path. */
    char *out = yyjson_mut_val_write_opts(root, 0, &g_xj_alc, &len, &err);
    yyjson_mut_doc_free(doc);
    if (!out) {
        return json_error(L, err.msg ? err.msg : "json pack failed");
    }

    lua_pushlstring(L, out, len);
    free(out);
    return 1;
}

static int l_util_json_unpack(lua_State *L) {
    luaL_checkstack(L, LUA_UTIL_JSON_MAX_DEPTH * 4 + 32,
                    "json unpack: too many nested values");

    size_t len = 0;
    const char *text = luaL_checklstring(L, 1, &len);
    yyjson_read_err err;
    memset(&err, 0, sizeof(err));

    yyjson_doc *doc = yyjson_read_opts((char *)(void *)text, len, 0, &g_xj_alc, &err);
    if (!doc) {
        int pos = (err.pos > (size_t)INT_MAX) ? INT_MAX : (int)err.pos;
        lua_pushnil(L);
        lua_pushfstring(L, "json unpack error at %d: %s",
                        pos, err.msg ? err.msg : "invalid json");
        return 2;
    }

    yyjson_val *root = yyjson_doc_get_root(doc);
    if (!root) {
        yyjson_doc_free(doc);
        return json_error(L, "json unpack: empty document");
    }

    if (!lua_json_push_value(L, root, 0)) {
        yyjson_doc_free(doc);
        return json_error(L, "json unpack: unsupported value or too deep");
    }

    yyjson_doc_free(doc);
    return 1;
}


static int l_util_load_config(lua_State *L) {
    const char *path = luaL_checkstring(L, 1);
    if (xargs_load_config(path) != 0) {
        lua_pushboolean(L, 0);
        lua_pushfstring(L, "load config failed: %s", path);
        return 2;
    }
    lua_pushboolean(L, 1);
    return 1;
}

static int l_util_get_config(lua_State *L) {
    const char *key = luaL_checkstring(L, 1);
    const char *value = xargs_get(key);
    if (value) {
        lua_pushstring(L, value);
        return 1;
    }
    if (lua_gettop(L) >= 2) {
        lua_pushvalue(L, 2);
        return 1;
    }
    lua_pushnil(L);
    return 1;
}

/* Typed getters validate the default (arg 2) against their return type up
** front, so a wrongly typed default fails loudly even when the key exists and
** the default goes unused. nil (or absent) means "no default" -> return nil. */
static int xu_has_default(lua_State *L) {
    return lua_gettop(L) >= 2 && !lua_isnil(L, 2);
}

static int l_util_get_int(lua_State *L) {
    const char *key = luaL_checkstring(L, 1);
    int has_def = xu_has_default(L);
    lua_Integer def = has_def ? luaL_checkinteger(L, 2) : 0;
    const char *value = xargs_get(key);
    if (value && value[0]) {
        char *end = NULL;
        long long n = strtoll(value, &end, 0);   /* base 0: 10, 0x.., 0.. */
        if (end != value && *end == '\0') {
            lua_pushinteger(L, (lua_Integer)n);
            return 1;
        }
    }
    if (has_def) lua_pushinteger(L, def); else lua_pushnil(L);
    return 1;
}

static int l_util_get_double(lua_State *L) {
    const char *key = luaL_checkstring(L, 1);
    int has_def = xu_has_default(L);
    lua_Number def = has_def ? luaL_checknumber(L, 2) : 0;
    const char *value = xargs_get(key);
    if (value && value[0]) {
        char *end = NULL;
        double d = strtod(value, &end);
        if (end != value && *end == '\0') {
            lua_pushnumber(L, (lua_Number)d);
            return 1;
        }
    }
    if (has_def) lua_pushnumber(L, def); else lua_pushnil(L);
    return 1;
}

static int l_util_get_string(lua_State *L) {
    const char *key = luaL_checkstring(L, 1);
    int has_def = xu_has_default(L);
    if (has_def) luaL_checkstring(L, 2);   /* coerces numbers in place */
    const char *value = xargs_get(key);
    if (value) {
        lua_pushstring(L, value);
        return 1;
    }
    if (has_def) lua_pushvalue(L, 2); else lua_pushnil(L);
    return 1;
}

static char *path_join_dup(const char *a, const char *b) {
    size_t alen = strlen(a);
    size_t blen = strlen(b);
    bool need_sep = alen > 0 && a[alen - 1] != '/' && a[alen - 1] != '\\';
    char *out = (char *)malloc(alen + blen + (need_sep ? 2 : 1));
    if (!out) return NULL;
    memcpy(out, a, alen);
    if (need_sep) out[alen++] = '/';
    memcpy(out + alen, b, blen);
    out[alen + blen] = '\0';
    return out;
}

static char *rel_join_dup(const char *rel, const char *name) {
    char *out = (!rel || rel[0] == '\0')
        ? (char *)malloc(strlen(name) + 1)
        : path_join_dup(rel, name);
    if (!out) return NULL;
    if (!rel || rel[0] == '\0') strcpy(out, name);
    for (char *p = out; *p; ++p) {
        if (*p == '\\') *p = '/';
    }
    return out;
}

static void scan_dir_push_file(lua_State *L, int table_idx, int *count,
                               const char *path, const char *rel) {
    lua_newtable(L);
    lua_pushstring(L, path);
    lua_setfield(L, -2, "path");
    lua_pushstring(L, rel);
    lua_setfield(L, -2, "rel");
    lua_rawseti(L, table_idx, ++(*count));
}

static int scan_dir_recursive(lua_State *L, int table_idx, int *count,
                              const char *dir, const char *rel,
                              char *errbuf, size_t errcap);

/* Build the child paths, then recurse into directories or record regular
** files. Shared by every platform backend so the path/Lua-table bookkeeping
** lives in exactly one place. */
static int scan_dir_handle_entry(lua_State *L, int table_idx, int *count,
                                 const char *dir, const char *rel,
                                 const char *name, int is_dir, int is_reg,
                                 char *errbuf, size_t errcap) {
    if (!is_dir && !is_reg) return 0;

    char *full = path_join_dup(dir, name);
    char *child_rel = rel_join_dup(rel, name);
    if (!full || !child_rel) {
        free(full);
        free(child_rel);
        snprintf(errbuf, errcap, "out of memory");
        return -1;
    }

    int rc = 0;
    if (is_dir) {
        rc = scan_dir_recursive(L, table_idx, count, full, child_rel,
                                errbuf, errcap);
    } else {
        scan_dir_push_file(L, table_idx, count, full, child_rel);
    }
    free(full);
    free(child_rel);
    return rc;
}

#define SCAN_DIR_NAME_DOTS(n) \
    ((n)[0] == '.' && ((n)[1] == '\0' || ((n)[1] == '.' && (n)[2] == '\0')))
#define SCAN_DIR_BUF (64 * 1024)

/* Each backend below enumerates `dir` with the fastest documented bulk API for
** its platform, classifies every child as directory / regular / other, and
** defers the recurse-or-record decision to scan_dir_handle_entry. Symlinks are
** followed so behaviour matches the historical stat()-based scan. */

#if defined(_WIN32)
/* Windows: GetFileInformationByHandleEx fills a whole buffer of entries per
** call (vs FindFirstFile's one-at-a-time) and FILE_ID_BOTH_DIR_INFO carries
** the attributes inline, so there is no extra stat/GetFileAttributes per child.
** Names stay in the system ANSI code page to match the narrow fopen() that
** ultimately serves these paths (xchannel_send_file_raw). */
static int scan_dir_recursive(lua_State *L, int table_idx, int *count,
                              const char *dir, const char *rel,
                              char *errbuf, size_t errcap) {
    HANDLE h = CreateFileA(dir, FILE_LIST_DIRECTORY,
                           FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE,
                           NULL, OPEN_EXISTING, FILE_FLAG_BACKUP_SEMANTICS, NULL);
    if (h == INVALID_HANDLE_VALUE) {
        snprintf(errbuf, errcap, "cannot open directory: %s", dir);
        return -1;
    }

    void *buf = malloc(SCAN_DIR_BUF);
    if (!buf) {
        CloseHandle(h);
        snprintf(errbuf, errcap, "out of memory");
        return -1;
    }

    int rc = 0;
    while (GetFileInformationByHandleEx(h, FileIdBothDirectoryInfo,
                                        buf, SCAN_DIR_BUF)) {
        FILE_ID_BOTH_DIR_INFO *info = (FILE_ID_BOTH_DIR_INFO *)buf;
        for (;;) {
            char name[1024];
            int wlen = (int)(info->FileNameLength / sizeof(WCHAR));
            int nlen = WideCharToMultiByte(CP_ACP, 0, info->FileName, wlen,
                                           name, (int)sizeof(name) - 1,
                                           NULL, NULL);
            if (nlen > 0) {
                name[nlen] = '\0';
                if (!SCAN_DIR_NAME_DOTS(name)) {
                    int is_dir = (info->FileAttributes &
                                  FILE_ATTRIBUTE_DIRECTORY) != 0;
                    rc = scan_dir_handle_entry(L, table_idx, count, dir, rel,
                                               name, is_dir, !is_dir,
                                               errbuf, errcap);
                }
            }
            if (rc != 0 || info->NextEntryOffset == 0) break;
            info = (FILE_ID_BOTH_DIR_INFO *)((char *)info +
                                             info->NextEntryOffset);
        }
        if (rc != 0) break;
    }

    if (rc == 0 && GetLastError() != ERROR_NO_MORE_FILES) {
        snprintf(errbuf, errcap, "cannot read directory: %s", dir);
        rc = -1;
    }

    free(buf);
    CloseHandle(h);
    return rc;
}

#elif defined(__APPLE__)
/* macOS: getattrlistbulk returns a bufferful of entries with name + object
** type inline, replacing readdir + per-entry stat/getattrlist. */
static int scan_dir_recursive(lua_State *L, int table_idx, int *count,
                              const char *dir, const char *rel,
                              char *errbuf, size_t errcap) {
    int fd = open(dir, O_RDONLY | O_CLOEXEC);
    if (fd < 0) {
        snprintf(errbuf, errcap, "cannot open directory: %s", dir);
        return -1;
    }

    char *buf = (char *)malloc(SCAN_DIR_BUF);
    if (!buf) {
        close(fd);
        snprintf(errbuf, errcap, "out of memory");
        return -1;
    }

    struct attrlist al;
    memset(&al, 0, sizeof(al));
    al.bitmapcount = ATTR_BIT_MAP_COUNT;
    al.commonattr  = ATTR_CMN_RETURNED_ATTRS | ATTR_CMN_NAME | ATTR_CMN_OBJTYPE;

    int rc = 0;
    for (;;) {
        int n = getattrlistbulk(fd, &al, buf, SCAN_DIR_BUF, 0);
        if (n < 0) {
            snprintf(errbuf, errcap, "cannot read directory: %s", dir);
            rc = -1;
            break;
        }
        if (n == 0) break;

        char *entry = buf;
        for (int i = 0; i < n && rc == 0; i++) {
            char *field = entry;
            uint32_t length;
            memcpy(&length, field, sizeof(length));
            char *next = entry + length;
            field += sizeof(uint32_t);

            /* Attributes follow in bitmap order, RETURNED_ATTRS always first. */
            attribute_set_t returned;
            memcpy(&returned, field, sizeof(returned));
            field += sizeof(returned);

            const char *name = NULL;
            if (returned.commonattr & ATTR_CMN_NAME) {
                attrreference_t ref;
                memcpy(&ref, field, sizeof(ref));
                name = field + ref.attr_dataoffset;
                field += sizeof(ref);
            }
            fsobj_type_t objtype = VNON;
            if (returned.commonattr & ATTR_CMN_OBJTYPE) {
                memcpy(&objtype, field, sizeof(objtype));
                field += sizeof(objtype);
            }

            entry = next;
            if (!name || SCAN_DIR_NAME_DOTS(name)) continue;

            int is_dir = (objtype == VDIR);
            int is_reg = (objtype == VREG);
            if (objtype == VLNK) {
                struct stat st;
                if (fstatat(fd, name, &st, 0) != 0) continue;
                is_dir = S_ISDIR(st.st_mode);
                is_reg = S_ISREG(st.st_mode);
            }
            rc = scan_dir_handle_entry(L, table_idx, count, dir, rel,
                                       name, is_dir, is_reg, errbuf, errcap);
        }
        if (rc != 0) break;
    }

    free(buf);
    close(fd);
    return rc;
}

#elif defined(__linux__)
/* Linux/Android: getdents64 returns many entries per syscall and d_type gives
** the kind without a stat. Only DT_UNKNOWN / DT_LNK fall back to fstatat, which
** follows the link to match the previous stat()-based behaviour. */
struct scan_dirent64 {
    uint64_t       d_ino;
    int64_t        d_off;
    unsigned short d_reclen;
    unsigned char  d_type;
    char           d_name[];
};

static int scan_dir_recursive(lua_State *L, int table_idx, int *count,
                              const char *dir, const char *rel,
                              char *errbuf, size_t errcap) {
    int fd = open(dir, O_RDONLY | O_DIRECTORY | O_CLOEXEC);
    if (fd < 0) {
        snprintf(errbuf, errcap, "cannot open directory: %s", dir);
        return -1;
    }

    char *buf = (char *)malloc(SCAN_DIR_BUF);
    if (!buf) {
        close(fd);
        snprintf(errbuf, errcap, "out of memory");
        return -1;
    }

    int rc = 0;
    for (;;) {
        long n = syscall(SYS_getdents64, fd, buf, SCAN_DIR_BUF);
        if (n < 0) {
            snprintf(errbuf, errcap, "cannot read directory: %s", dir);
            rc = -1;
            break;
        }
        if (n == 0) break;

        for (long off = 0; off < n && rc == 0; ) {
            struct scan_dirent64 *d = (struct scan_dirent64 *)(buf + off);
            const char *name = d->d_name;
            unsigned char type = d->d_type;
            off += d->d_reclen;

            if (SCAN_DIR_NAME_DOTS(name)) continue;

            int is_dir, is_reg;
            if (type == DT_DIR) { is_dir = 1; is_reg = 0; }
            else if (type == DT_REG) { is_dir = 0; is_reg = 1; }
            else {
                struct stat st;
                if (fstatat(fd, name, &st, 0) != 0) continue;
                is_dir = S_ISDIR(st.st_mode);
                is_reg = S_ISREG(st.st_mode);
            }
            rc = scan_dir_handle_entry(L, table_idx, count, dir, rel,
                                       name, is_dir, is_reg, errbuf, errcap);
        }
        if (rc != 0) break;
    }

    free(buf);
    close(fd);
    return rc;
}

#else
/* Generic POSIX (BSD, etc.): readdir with d_type when the filesystem provides
** it, fstatat otherwise -- still avoids the per-entry stat in the common case. */
static int scan_dir_recursive(lua_State *L, int table_idx, int *count,
                              const char *dir, const char *rel,
                              char *errbuf, size_t errcap) {
    DIR *dp = opendir(dir);
    if (!dp) {
        snprintf(errbuf, errcap, "cannot open directory: %s", dir);
        return -1;
    }
    int dfd = dirfd(dp);

    int rc = 0;
    struct dirent *ent;
    while (rc == 0 && (ent = readdir(dp)) != NULL) {
        const char *name = ent->d_name;
        if (SCAN_DIR_NAME_DOTS(name)) continue;

        int is_dir = 0, is_reg = 0;
#ifdef DT_DIR
        if (ent->d_type == DT_DIR)      { is_dir = 1; }
        else if (ent->d_type == DT_REG) { is_reg = 1; }
        else
#endif
        {
            struct stat st;
            if (fstatat(dfd, name, &st, 0) != 0) continue;
            is_dir = S_ISDIR(st.st_mode);
            is_reg = S_ISREG(st.st_mode);
        }
        rc = scan_dir_handle_entry(L, table_idx, count, dir, rel,
                                   name, is_dir, is_reg, errbuf, errcap);
    }

    closedir(dp);
    return rc;
}
#endif

static int l_util_scan_dir(lua_State *L) {
    const char *root = luaL_checkstring(L, 1);
    char errbuf[512] = {0};
    int count = 0;

    lua_newtable(L);
    int table_idx = lua_gettop(L);
    if (scan_dir_recursive(L, table_idx, &count, root, "", errbuf, sizeof(errbuf)) != 0) {
        lua_pop(L, 1);
        lua_pushnil(L);
        lua_pushstring(L, errbuf[0] ? errbuf : "scan directory failed");
        return 2;
    }
    return 1;
}

/* xutils.cwd() -> string | nil, err
**
** The process working directory.
**
** Lua has no getcwd, and the workaround every caller otherwise reaches for is
** to run `pwd` (or `cd` on Windows) through a shell and read the pipe. That is
** a process spawn for a value the OS will hand over for free, and on Windows it
** is also wrong: this process's ANSI APIs speak UTF-8 because of the manifest
** in xlua/xnet.rc, but a child's pipe OUTPUT is still the OEM code page, so an
** install path with non-ASCII in it comes back as mojibake. Asking the API has
** neither problem.
**
** Windows takes the ANSI call deliberately, for the same manifest reason: it
** already returns UTF-8 here, so there is no wide-char conversion to do.
*/
static int l_util_cwd(lua_State *L) {
#ifdef _WIN32
    /* Called with 0 it returns the size INCLUDING the terminator; called with a
    ** buffer it returns the length EXCLUDING it. A directory can be renamed
    ** between the two calls, so a second result that no longer fits is a
    ** failure rather than something to truncate. */
    DWORD need = GetCurrentDirectoryA(0, NULL);
    if (need == 0) {
        lua_pushnil(L);
        lua_pushstring(L, "GetCurrentDirectory failed");
        return 2;
    }
    char *buf = (char *)malloc(need);
    if (!buf) {
        lua_pushnil(L);
        lua_pushstring(L, "out of memory");
        return 2;
    }
    DWORD got = GetCurrentDirectoryA(need, buf);
    if (got == 0 || got >= need) {
        free(buf);
        lua_pushnil(L);
        lua_pushstring(L, "GetCurrentDirectory failed");
        return 2;
    }
    lua_pushlstring(L, buf, (size_t)got);
    free(buf);
    return 1;
#else
    /* Grown rather than fixed at PATH_MAX: PATH_MAX is not defined everywhere,
    ** and where it is it is not always the real limit. ERANGE is the only error
    ** worth retrying. */
    size_t cap = 512;
    for (;;) {
        char *buf = (char *)malloc(cap);
        if (!buf) {
            lua_pushnil(L);
            lua_pushstring(L, "out of memory");
            return 2;
        }
        if (getcwd(buf, cap)) {
            lua_pushstring(L, buf);
            free(buf);
            return 1;
        }
        int err = errno;
        free(buf);
        if (err != ERANGE || cap >= 65536) {
            lua_pushnil(L);
            lua_pushstring(L, strerror(err));
            return 2;
        }
        cap *= 2;
    }
#endif
}

/* ==========================================================================
** Directory operations
**
** These three exist because the alternative in Lua is a SHELL: `mkdir -p`,
** `rm -rf` / `rmdir /s /q`, `find -delete` / `del /q`. Every one of those is a
** process spawn for a syscall, needs a different spelling per platform, and
** puts a caller-influenced path through a quoting layer -- which for the
** recursive delete is the single most dangerous string in a git host.
** ======================================================================== */

/* Deepest tree rmtree() will walk. Not a real limit for a repository; it is
** there so a filesystem loop that survives the symlink check below cannot turn
** into unbounded recursion. */
#define XU_RMTREE_MAX_DEPTH 128

static int rmtree_walk(const char *path, char *errbuf, size_t errcap, int depth);

static void xu_err(char *errbuf, size_t errcap, const char *what, const char *path) {
    if (errbuf && errcap) snprintf(errbuf, errcap, "%s: %s", what, path ? path : "?");
}

#ifdef _WIN32
static int rmtree_children(const char *dir, char *errbuf, size_t errcap, int depth) {
    char *pattern = path_join_dup(dir, "*");
    if (!pattern) return -1;

    WIN32_FIND_DATAA fd;
    HANDLE h = FindFirstFileA(pattern, &fd);
    free(pattern);
    if (h == INVALID_HANDLE_VALUE) {
        xu_err(errbuf, errcap, "cannot list", dir);
        return -1;
    }

    int rc = 0;
    do {
        const char *name = fd.cFileName;
        if (name[0] == '.' && (name[1] == '\0' || (name[1] == '.' && name[2] == '\0'))) continue;

        char *full = path_join_dup(dir, name);
        if (!full) { rc = -1; break; }

        /* A reparse point (junction, symlink) is removed as itself, never
        ** followed -- following one would delete whatever it aims at. */
        int is_dir = (fd.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY) != 0;
        int is_link = (fd.dwFileAttributes & FILE_ATTRIBUTE_REPARSE_POINT) != 0;

        if (is_dir && !is_link) {
            rc = rmtree_walk(full, errbuf, errcap, depth + 1);
        } else {
            /* git leaves loose objects and packfiles read-only, and DeleteFile
            ** refuses a read-only file. `rmdir /s /q` had the same problem and
            ** got away with it only because it clears the attribute itself. */
            if (fd.dwFileAttributes & FILE_ATTRIBUTE_READONLY) {
                SetFileAttributesA(full, fd.dwFileAttributes & ~(DWORD)FILE_ATTRIBUTE_READONLY);
            }
            if (is_dir) {
                if (!RemoveDirectoryA(full)) { xu_err(errbuf, errcap, "cannot remove link", full); rc = -1; }
            } else if (!DeleteFileA(full)) {
                xu_err(errbuf, errcap, "cannot delete", full);
                rc = -1;
            }
        }
        free(full);
    } while (rc == 0 && FindNextFileA(h, &fd));

    FindClose(h);
    return rc;
}
#else
static int rmtree_children(const char *dir, char *errbuf, size_t errcap, int depth) {
    DIR *dp = opendir(dir);
    if (!dp) { xu_err(errbuf, errcap, "cannot list", dir); return -1; }

    int rc = 0;
    struct dirent *ent;
    while (rc == 0 && (ent = readdir(dp)) != NULL) {
        const char *name = ent->d_name;
        if (name[0] == '.' && (name[1] == '\0' || (name[1] == '.' && name[2] == '\0'))) continue;

        char *full = path_join_dup(dir, name);
        if (!full) { rc = -1; break; }

        /* lstat, not stat: a symlink to a directory must be unlinked, not
        ** descended into. */
        struct stat st;
        if (lstat(full, &st) != 0) {
            xu_err(errbuf, errcap, "cannot stat", full);
            rc = -1;
        } else if (S_ISDIR(st.st_mode)) {
            rc = rmtree_walk(full, errbuf, errcap, depth + 1);
        } else if (unlink(full) != 0) {
            xu_err(errbuf, errcap, "cannot delete", full);
            rc = -1;
        }
        free(full);
    }

    closedir(dp);
    return rc;
}
#endif

static int rmtree_walk(const char *path, char *errbuf, size_t errcap, int depth) {
    if (depth > XU_RMTREE_MAX_DEPTH) {
        xu_err(errbuf, errcap, "too deep", path);
        return -1;
    }
    if (rmtree_children(path, errbuf, errcap, depth) != 0) return -1;
#ifdef _WIN32
    if (!RemoveDirectoryA(path)) { xu_err(errbuf, errcap, "cannot remove", path); return -1; }
#else
    if (rmdir(path) != 0) { xu_err(errbuf, errcap, "cannot remove", path); return -1; }
#endif
    return 0;
}

/* xutils.rmtree(path) -> true | nil, err
**
** Remove a directory and everything under it. A path that does not exist is
** success, so the caller does not need an exists-check race.
**
** Symlinks are removed, never followed. Callers hand this a path built from
** user-influenced names, so the one thing it must not do is delete something
** outside the tree it was pointed at.
*/
static int l_util_rmtree(lua_State *L) {
    const char *path = luaL_checkstring(L, 1);
    if (path[0] == '\0') {
        lua_pushnil(L);
        lua_pushstring(L, "rmtree: empty path");
        return 2;
    }

    char errbuf[512] = {0};
#ifdef _WIN32
    DWORD attr = GetFileAttributesA(path);
    if (attr == INVALID_FILE_ATTRIBUTES) { lua_pushboolean(L, 1); return 1; }  /* already gone */
    if (!(attr & FILE_ATTRIBUTE_DIRECTORY)) {
        if (attr & FILE_ATTRIBUTE_READONLY) {
            SetFileAttributesA(path, attr & ~(DWORD)FILE_ATTRIBUTE_READONLY);
        }
        if (!DeleteFileA(path)) { lua_pushnil(L); lua_pushfstring(L, "cannot delete: %s", path); return 2; }
        lua_pushboolean(L, 1);
        return 1;
    }
#else
    struct stat st;
    if (lstat(path, &st) != 0) { lua_pushboolean(L, 1); return 1; }            /* already gone */
    if (!S_ISDIR(st.st_mode)) {
        if (unlink(path) != 0) { lua_pushnil(L); lua_pushfstring(L, "cannot delete: %s", path); return 2; }
        lua_pushboolean(L, 1);
        return 1;
    }
#endif

    if (rmtree_walk(path, errbuf, sizeof(errbuf), 0) != 0) {
        lua_pushnil(L);
        lua_pushstring(L, errbuf[0] ? errbuf : "rmtree failed");
        return 2;
    }
    lua_pushboolean(L, 1);
    return 1;
}

/* xutils.mkdir_p(path) -> true | nil, err
**
** Create a directory and any missing parents. An existing directory is success.
*/
static int l_util_mkdir_p(lua_State *L) {
    size_t n;
    const char *path = luaL_checklstring(L, 1, &n);
    luaL_argcheck(L, !memchr(path, 0, n), 1, "path contains NUL");
    if (n == 0) {
        lua_pushnil(L);
        lua_pushstring(L, "mkdir_p: empty path");
        return 2;
    }

    char *work = (char *)malloc(n + 1);
    if (!work) { lua_pushnil(L); lua_pushstring(L, "out of memory"); return 2; }
    memcpy(work, path, n + 1);

    /* Walk the separators left to right, creating each prefix. EEXIST is the
    ** normal case for every component but the last. */
    for (size_t i = 1; i <= n; i++) {
        char c = work[i];
        int last = (i == n);
        if (!last && c != '/'
#ifdef _WIN32
            && c != '\\'
#endif
        ) continue;
        if (!last) work[i] = '\0';

        /* Nothing to create for a bare root ("/", "//") or a drive ("C:"):
        ** the first is not ours to make and the second is not a directory. */
        int skip = 1;
        for (size_t k = 0; k < i; k++) {
            char ch = work[k];
            if (ch != '/' && ch != '\\' && ch != ':') { skip = 0; break; }
        }
        if (!skip && work[i - 1] == ':') skip = 1;
#ifdef _WIN32
        if (!skip && !CreateDirectoryA(work, NULL)) {
            DWORD e = GetLastError();
            DWORD attrs = GetFileAttributesA(work);
            if (e != ERROR_ALREADY_EXISTS || attrs == INVALID_FILE_ATTRIBUTES || !(attrs & FILE_ATTRIBUTE_DIRECTORY)) {
                lua_pushnil(L);
                lua_pushfstring(L, "cannot create: %s", work);
                free(work);
                return 2;
            }
        }
#else
        if (!skip && mkdir(work, 0777) != 0) {
            int e = errno;
            struct stat st;
            if (e != EEXIST || stat(work, &st) != 0 || !S_ISDIR(st.st_mode)) {
                free(work);
                lua_pushnil(L);
                lua_pushfstring(L, "cannot create %s: %s", path, strerror(e));
                return 2;
            }
        }
#endif
        if (!last) work[i] = c;
    }

    free(work);
    lua_pushboolean(L, 1);
    return 1;
}

/* Set type/size/mtime on the table at the top, the same fields stat reports. */
static void push_stat_fields(lua_State *L, const char *kind, lua_Integer size, lua_Integer mtime) {
    lua_pushstring(L, kind); lua_setfield(L, -2, "type");
    lua_pushinteger(L, size); lua_setfield(L, -2, "size");
    lua_pushinteger(L, mtime); lua_setfield(L, -2, "mtime");
}

#ifdef _WIN32
static lua_Integer filetime_to_unix(FILETIME ft) {
    uint64_t ticks = ((uint64_t)ft.dwHighDateTime << 32) | ft.dwLowDateTime;
    return (lua_Integer)(ticks / 10000000ULL) - 11644473600LL;
}

static const char *attr_kind(DWORD attrs) {
    return (attrs & FILE_ATTRIBUTE_REPARSE_POINT) ? "link" :
           (attrs & FILE_ATTRIBUTE_DIRECTORY) ? "directory" : "file";
}
#else
static const char *mode_kind(mode_t m) {
    return S_ISLNK(m) ? "link" : S_ISDIR(m) ? "directory" : S_ISREG(m) ? "file" : "other";
}
#endif

/* xutils.list_dir(path[, limit[, with_stat]]) -> { { name=..., dir=bool }, ... }, truncated | nil, err
**
** ONE level. scan_dir recurses with no depth limit, which makes it unusable on
** anything that might contain a git object store; this is the "what is directly
** in here" call that a scratch sweep or a repository listing actually wants.
** '.' and '..' are omitted.
**
** with_stat adds type, size and mtime exactly as stat reports them (links are
** not followed). Windows reads them from the directory entry itself, so a
** tree costs one call per directory instead of one stat per file; NTFS may
** refresh an entry's size and time only once a writer closes the file.
** Entries that vanish between listing and stat are left out.
*/
static int l_util_list_dir(lua_State *L) {
    size_t path_len;
    const char *path = luaL_checklstring(L, 1, &path_len);
    luaL_argcheck(L, path_len > 0 && !memchr(path, 0, path_len), 1, "invalid path");
    lua_Integer limit = luaL_optinteger(L, 2, INT_MAX);
    luaL_argcheck(L, limit > 0 && limit <= INT_MAX, 2, "invalid entry limit");
    int with_stat = lua_toboolean(L, 3);
    int truncated = 0;
    int count = 0;
    lua_newtable(L);

#ifdef _WIN32
    char *pattern = path_join_dup(path, "*");
    if (!pattern) { lua_pop(L, 1); lua_pushnil(L); lua_pushstring(L, "out of memory"); return 2; }
    WIN32_FIND_DATAA fd;
    HANDLE h = FindFirstFileA(pattern, &fd);
    free(pattern);
    if (h == INVALID_HANDLE_VALUE) {
        lua_pop(L, 1);
        lua_pushnil(L);
        lua_pushfstring(L, "cannot list: %s", path);
        return 2;
    }
    do {
        const char *name = fd.cFileName;
        if (name[0] == '.' && (name[1] == '\0' || (name[1] == '.' && name[2] == '\0'))) continue;
        if (count >= limit) { truncated = 1; break; }
        lua_newtable(L);
        lua_pushstring(L, name);
        lua_setfield(L, -2, "name");
        lua_pushboolean(L, (fd.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY) != 0);
        lua_setfield(L, -2, "dir");
        if (with_stat)
            push_stat_fields(L, attr_kind(fd.dwFileAttributes),
                             (lua_Integer)(((uint64_t)fd.nFileSizeHigh << 32) | fd.nFileSizeLow),
                             filetime_to_unix(fd.ftLastWriteTime));
        lua_rawseti(L, -2, ++count);
    } while (FindNextFileA(h, &fd));
    FindClose(h);
#else
    DIR *dp = opendir(path);
    if (!dp) {
        lua_pop(L, 1);
        lua_pushnil(L);
        lua_pushfstring(L, "cannot list %s: %s", path, strerror(errno));
        return 2;
    }
    struct dirent *ent;
    while ((ent = readdir(dp)) != NULL) {
        const char *name = ent->d_name;
        if (name[0] == '.' && (name[1] == '\0' || (name[1] == '.' && name[2] == '\0'))) continue;
        if (count >= limit) { truncated = 1; break; }

        int is_dir = 0;
        struct stat st;
        int have_st = 0;
        if (with_stat) {
            if (fstatat(dirfd(dp), name, &st, AT_SYMLINK_NOFOLLOW) != 0) continue;
            have_st = 1;
            is_dir = S_ISDIR(st.st_mode);
        } else {
#ifdef DT_DIR
            if (ent->d_type == DT_DIR)      is_dir = 1;
            else if (ent->d_type != DT_UNKNOWN) is_dir = 0;
            else
#endif
            {
                char *full = path_join_dup(path, name);
                if (full && lstat(full, &st) == 0) is_dir = S_ISDIR(st.st_mode);
                free(full);
            }
        }

        lua_newtable(L);
        lua_pushstring(L, name);
        lua_setfield(L, -2, "name");
        lua_pushboolean(L, is_dir);
        lua_setfield(L, -2, "dir");
        if (have_st)
            push_stat_fields(L, mode_kind(st.st_mode), (lua_Integer)st.st_size, (lua_Integer)st.st_mtime);
        lua_rawseti(L, -2, ++count);
    }
    closedir(dp);
#endif
    lua_pushboolean(L, truncated);
    return 2;
}

/* Missing paths are data, other OS errors are failures. Do not follow links:
** callers must be able to distinguish a link from its target before traversal. */
static int l_util_stat(lua_State *L) {
    size_t n;
    const char *path = luaL_checklstring(L, 1, &n);
    luaL_argcheck(L, n > 0 && !memchr(path, 0, n), 1, "invalid path");
    const char *kind = "other";
    lua_Integer size = 0, mtime = 0;
    int exists = 1;
#ifdef _WIN32
    WIN32_FILE_ATTRIBUTE_DATA data;
    if (!GetFileAttributesExA(path, GetFileExInfoStandard, &data)) {
        DWORD e = GetLastError();
        if (e == ERROR_FILE_NOT_FOUND || e == ERROR_PATH_NOT_FOUND) exists = 0;
        else { lua_pushnil(L); lua_pushfstring(L, "cannot stat %s (error %d)", path, (int)e); return 2; }
    } else {
        kind = attr_kind(data.dwFileAttributes);
        size = (lua_Integer)(((uint64_t)data.nFileSizeHigh << 32) | data.nFileSizeLow);
        mtime = filetime_to_unix(data.ftLastWriteTime);
    }
#else
    struct stat st;
    if (lstat(path, &st) != 0) {
        int e = errno;
        if (e == ENOENT || e == ENOTDIR) exists = 0;
        else { lua_pushnil(L); lua_pushfstring(L, "cannot stat %s: %s", path, strerror(e)); return 2; }
    } else {
        kind = mode_kind(st.st_mode);
        size = (lua_Integer)st.st_size; mtime = (lua_Integer)st.st_mtime;
    }
#endif
    lua_newtable(L);
    lua_pushboolean(L, exists); lua_setfield(L, -2, "exists");
    if (exists) push_stat_fields(L, kind, size, mtime);
    return 1;
}

/* ==========================================================================
** Hashing / HMAC / base64 / hex
**
** Backed by the self-contained mbedTLS hash files (linked on every build).
** base64 and hex are implemented here directly -- they need no crypto lib.
** These replace the per-module pure-Lua copies (xsha2, websocket handshake,
** MySQL auth, JWT/PKCE base64url) with one C implementation.
** ======================================================================== */

/* Suppress warn_unused_result on the mbedTLS calls (they can't fail for these
** one-shot/streaming uses with valid args). */
#define XU_MB(call) do { int _rc = (call); (void)_rc; } while (0)

static const char XU_HEXD[] = "0123456789abcdef";

static void xu_push_hex(lua_State *L, const unsigned char *p, size_t n) {
    luaL_Buffer b;
    char *out = luaL_buffinitsize(L, &b, n * 2);
    for (size_t i = 0; i < n; i++) {
        out[i * 2]     = XU_HEXD[(p[i] >> 4) & 0xf];
        out[i * 2 + 1] = XU_HEXD[p[i] & 0xf];
    }
    luaL_pushresultsize(&b, n * 2);
}

static int xu_hexval(int c) {
    if (c >= '0' && c <= '9') return c - '0';
    if (c >= 'a' && c <= 'f') return c - 'a' + 10;
    if (c >= 'A' && c <= 'F') return c - 'A' + 10;
    return -1;
}

/* --- one-shot hashes, unified (in, len, out) signature ----------------- */
static void mb_sha1  (const unsigned char *in, size_t n, unsigned char *o) { XU_MB(mbedtls_sha1(in, n, o)); }
static void mb_sha256(const unsigned char *in, size_t n, unsigned char *o) { XU_MB(mbedtls_sha256(in, n, o, 0)); }
static void mb_sha512(const unsigned char *in, size_t n, unsigned char *o) { XU_MB(mbedtls_sha512(in, n, o, 0)); }
static void mb_md5   (const unsigned char *in, size_t n, unsigned char *o) { XU_MB(mbedtls_md5(in, n, o)); }

#define HASH_FN(name, fn, DIGLEN)                                        \
    static int l_util_##name(lua_State *L) {                             \
        size_t n = 0; const char *s = luaL_checklstring(L, 1, &n);       \
        unsigned char d[DIGLEN];                                         \
        fn((const unsigned char *)s, n, d);                              \
        lua_pushlstring(L, (const char *)d, DIGLEN);                     \
        return 1;                                                        \
    }                                                                    \
    static int l_util_##name##_hex(lua_State *L) {                       \
        size_t n = 0; const char *s = luaL_checklstring(L, 1, &n);       \
        unsigned char d[DIGLEN];                                         \
        fn((const unsigned char *)s, n, d);                              \
        xu_push_hex(L, d, DIGLEN);                                       \
        return 1;                                                        \
    }

HASH_FN(sha1,   mb_sha1,   20)
HASH_FN(sha256, mb_sha256, 32)
HASH_FN(sha512, mb_sha512, 64)
HASH_FN(md5,    mb_md5,    16)

/* --- HMAC (streaming, block size 64 for sha1/sha256) ------------------- */
static void hmac_sha256_raw(const unsigned char *key, size_t kl,
                            const unsigned char *msg, size_t ml,
                            unsigned char out[32]) {
    unsigned char k[64], ipad[64], opad[64], inner[32];
    if (kl > 64) { mb_sha256(key, kl, k); key = k; kl = 32; }
    for (int i = 0; i < 64; i++) {
        unsigned char b = (i < (int)kl) ? key[i] : 0;
        ipad[i] = b ^ 0x36; opad[i] = b ^ 0x5c;
    }
    mbedtls_sha256_context c; mbedtls_sha256_init(&c);
    XU_MB(mbedtls_sha256_starts(&c, 0));
    XU_MB(mbedtls_sha256_update(&c, ipad, 64));
    XU_MB(mbedtls_sha256_update(&c, msg, ml));
    XU_MB(mbedtls_sha256_finish(&c, inner));
    XU_MB(mbedtls_sha256_starts(&c, 0));
    XU_MB(mbedtls_sha256_update(&c, opad, 64));
    XU_MB(mbedtls_sha256_update(&c, inner, 32));
    XU_MB(mbedtls_sha256_finish(&c, out));
    mbedtls_sha256_free(&c);
}

static void hmac_sha1_raw(const unsigned char *key, size_t kl,
                          const unsigned char *msg, size_t ml,
                          unsigned char out[20]) {
    unsigned char k[64], ipad[64], opad[64], inner[20];
    if (kl > 64) { mb_sha1(key, kl, k); key = k; kl = 20; }
    for (int i = 0; i < 64; i++) {
        unsigned char b = (i < (int)kl) ? key[i] : 0;
        ipad[i] = b ^ 0x36; opad[i] = b ^ 0x5c;
    }
    mbedtls_sha1_context c; mbedtls_sha1_init(&c);
    XU_MB(mbedtls_sha1_starts(&c));
    XU_MB(mbedtls_sha1_update(&c, ipad, 64));
    XU_MB(mbedtls_sha1_update(&c, msg, ml));
    XU_MB(mbedtls_sha1_finish(&c, inner));
    XU_MB(mbedtls_sha1_starts(&c));
    XU_MB(mbedtls_sha1_update(&c, opad, 64));
    XU_MB(mbedtls_sha1_update(&c, inner, 20));
    XU_MB(mbedtls_sha1_finish(&c, out));
    mbedtls_sha1_free(&c);
}

static int l_util_hmac_sha256(lua_State *L) {
    size_t kl = 0, ml = 0;
    const unsigned char *k = (const unsigned char *)luaL_checklstring(L, 1, &kl);
    const unsigned char *m = (const unsigned char *)luaL_checklstring(L, 2, &ml);
    unsigned char out[32]; hmac_sha256_raw(k, kl, m, ml, out);
    lua_pushlstring(L, (const char *)out, 32);
    return 1;
}
static int l_util_hmac_sha256_hex(lua_State *L) {
    size_t kl = 0, ml = 0;
    const unsigned char *k = (const unsigned char *)luaL_checklstring(L, 1, &kl);
    const unsigned char *m = (const unsigned char *)luaL_checklstring(L, 2, &ml);
    unsigned char out[32]; hmac_sha256_raw(k, kl, m, ml, out);
    xu_push_hex(L, out, 32);
    return 1;
}

/* xutils.pbkdf2_sha256(password, salt, iterations [, dklen]) -> raw | nil, err
**
** PBKDF2-HMAC-SHA256, RFC 8018. dklen defaults to 32 (one SHA-256 block).
**
** Built on hmac_sha256_raw above rather than on mbedtls_pkcs5_pbkdf2_hmac
** DELIBERATELY: pkcs5.c and md.c are only compiled into an HTTPS build, while
** the four hash files this module already uses are linked on every
** configuration. A password hash that exists or not depending on WITH_HTTPS is
** not something a caller can reason about.
**
** In Lua this is a loop of C HMAC calls with the XOR done in interpreted code,
** which is where the cost lives: measured at 10000 iterations it was ~55 ms per
** verification, enough that it needed a thread of its own to keep the event
** loop alive. The XOR belongs on this side of the boundary.
*/
static int l_util_pbkdf2_sha256(lua_State *L) {
    size_t pl = 0, sl = 0;
    const unsigned char *pw = (const unsigned char *)luaL_checklstring(L, 1, &pl);
    const unsigned char *salt = (const unsigned char *)luaL_checklstring(L, 2, &sl);
    lua_Integer iter = luaL_checkinteger(L, 3);
    lua_Integer dklen = luaL_optinteger(L, 4, 32);

    /* Bounded so a bad config cannot wedge the calling thread, and so the
    ** allocation below cannot be driven from a caller's arithmetic. */
    if (iter < 1 || iter > 10000000) {
        lua_pushnil(L);
        lua_pushstring(L, "pbkdf2: iterations out of range");
        return 2;
    }
    if (dklen < 1 || dklen > 1024) {
        lua_pushnil(L);
        lua_pushstring(L, "pbkdf2: dklen out of range");
        return 2;
    }

    unsigned char *dk = (unsigned char *)malloc((size_t)dklen);
    if (!dk) { lua_pushnil(L); lua_pushstring(L, "out of memory"); return 2; }

    /* salt || INT_BE32(block), the message for U1 of each block. */
    unsigned char *msg = (unsigned char *)malloc(sl + 4);
    if (!msg) { free(dk); lua_pushnil(L); lua_pushstring(L, "out of memory"); return 2; }
    if (sl) memcpy(msg, salt, sl);

    size_t done = 0;
    for (uint32_t block = 1; done < (size_t)dklen; block++) {
        msg[sl + 0] = (unsigned char)(block >> 24);
        msg[sl + 1] = (unsigned char)(block >> 16);
        msg[sl + 2] = (unsigned char)(block >> 8);
        msg[sl + 3] = (unsigned char)(block);

        unsigned char u[32], acc[32];
        hmac_sha256_raw(pw, pl, msg, sl + 4, u);
        memcpy(acc, u, 32);
        for (lua_Integer i = 2; i <= iter; i++) {
            hmac_sha256_raw(pw, pl, u, 32, u);
            for (int b = 0; b < 32; b++) acc[b] ^= u[b];
        }

        size_t take = (size_t)dklen - done;
        if (take > 32) take = 32;
        memcpy(dk + done, acc, take);
        done += take;
    }

    free(msg);
    lua_pushlstring(L, (const char *)dk, (size_t)dklen);
    free(dk);
    return 1;
}
static int l_util_hmac_sha1(lua_State *L) {
    size_t kl = 0, ml = 0;
    const unsigned char *k = (const unsigned char *)luaL_checklstring(L, 1, &kl);
    const unsigned char *m = (const unsigned char *)luaL_checklstring(L, 2, &ml);
    unsigned char out[20]; hmac_sha1_raw(k, kl, m, ml, out);
    lua_pushlstring(L, (const char *)out, 20);
    return 1;
}
static int l_util_hmac_sha1_hex(lua_State *L) {
    size_t kl = 0, ml = 0;
    const unsigned char *k = (const unsigned char *)luaL_checklstring(L, 1, &kl);
    const unsigned char *m = (const unsigned char *)luaL_checklstring(L, 2, &ml);
    unsigned char out[20]; hmac_sha1_raw(k, kl, m, ml, out);
    xu_push_hex(L, out, 20);
    return 1;
}

/* --- AES-CBC ------------------------------------------------------------
**
** xutils.aes_cbc_encrypt(key, iv, data) -> raw | nil, err
** xutils.aes_cbc_decrypt(key, iv, data) -> raw | nil, err
**
** The raw cipher, NO PADDING: `data` is a whole number of 16-byte blocks and
** comes back the same length. Padding is the protocol's business (PKCS#7 for
** WeCom's callback, something else elsewhere), and a primitive that stripped
** it could not tell a caller whether the plaintext had been padded at all.
**
** Key length picks the variant: 16, 24 or 32 bytes for AES-128/192/256.
**
** Like the hashes above, these are linked on EVERY build -- aes.c and its
** hardware paths are in the crypto subset the Makefile compiles when
** WITH_HTTPS=0, for the reason spelled out on pbkdf2_sha256.
*/
static int xu_aes_cbc(lua_State *L, int encrypt) {
    size_t kl = 0, il = 0, dl = 0;
    const unsigned char *key  = (const unsigned char *)luaL_checklstring(L, 1, &kl);
    const unsigned char *iv   = (const unsigned char *)luaL_checklstring(L, 2, &il);
    const unsigned char *data = (const unsigned char *)luaL_checklstring(L, 3, &dl);

    if (kl != 16 && kl != 24 && kl != 32) {
        lua_pushnil(L); lua_pushstring(L, "aes: key must be 16, 24 or 32 bytes"); return 2;
    }
    if (il != 16) {
        lua_pushnil(L); lua_pushstring(L, "aes: iv must be 16 bytes"); return 2;
    }
    if (dl == 0 || (dl % 16) != 0) {
        lua_pushnil(L); lua_pushstring(L, "aes: data must be whole 16-byte blocks"); return 2;
    }

    /* mbedtls_aes_crypt_cbc advances the IV in place, so it gets a copy: the
    ** caller's Lua string is immutable and may be reused for another call. */
    unsigned char ivbuf[16];
    memcpy(ivbuf, iv, 16);

    luaL_Buffer b;
    unsigned char *out = (unsigned char *)luaL_buffinitsize(L, &b, dl);

    mbedtls_aes_context ctx;
    mbedtls_aes_init(&ctx);
    int rc = encrypt ? mbedtls_aes_setkey_enc(&ctx, key, (unsigned int)(kl * 8))
                     : mbedtls_aes_setkey_dec(&ctx, key, (unsigned int)(kl * 8));
    if (rc == 0) {
        rc = mbedtls_aes_crypt_cbc(&ctx, encrypt ? MBEDTLS_AES_ENCRYPT : MBEDTLS_AES_DECRYPT,
                                   dl, ivbuf, data, out);
    }
    mbedtls_aes_free(&ctx);

    if (rc != 0) {
        luaL_pushresultsize(&b, 0);
        lua_pop(L, 1);
        lua_pushnil(L);
        lua_pushfstring(L, "aes: mbedtls error %d", rc);
        return 2;
    }
    luaL_pushresultsize(&b, dl);
    return 1;
}
static int l_util_aes_cbc_encrypt(lua_State *L) { return xu_aes_cbc(L, 1); }
static int l_util_aes_cbc_decrypt(lua_State *L) { return xu_aes_cbc(L, 0); }


/* --- base64 (standard + url-safe) and hex ------------------------------ */
static const char XU_B64STD[] =
    "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
static const char XU_B64URL[] =
    "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_";

static int xu_b64_encode(lua_State *L, const char *alpha, int pad) {
    size_t n = 0;
    const unsigned char *s = (const unsigned char *)luaL_checklstring(L, 1, &n);
    luaL_Buffer b; luaL_buffinit(L, &b);
    for (size_t i = 0; i < n; i += 3) {
        unsigned b0 = s[i];
        unsigned b1 = (i + 1 < n) ? s[i + 1] : 0;
        unsigned b2 = (i + 2 < n) ? s[i + 2] : 0;
        int rem = (int)(n - i);
        luaL_addchar(&b, alpha[b0 >> 2]);
        luaL_addchar(&b, alpha[((b0 & 3) << 4) | (b1 >> 4)]);
        if (rem > 1)       luaL_addchar(&b, alpha[((b1 & 15) << 2) | (b2 >> 6)]);
        else if (pad)      luaL_addchar(&b, '=');
        if (rem > 2)       luaL_addchar(&b, alpha[b2 & 63]);
        else if (pad)      luaL_addchar(&b, '=');
    }
    luaL_pushresult(&b);
    return 1;
}
static int l_util_base64_encode(lua_State *L)    { return xu_b64_encode(L, XU_B64STD, 1); }
static int l_util_base64url_encode(lua_State *L) { return xu_b64_encode(L, XU_B64URL, 0); }

/* Decodes both standard and url-safe alphabets; padding/whitespace ignored. */
static int xu_b64dval(int c) {
    if (c >= 'A' && c <= 'Z') return c - 'A';
    if (c >= 'a' && c <= 'z') return c - 'a' + 26;
    if (c >= '0' && c <= '9') return c - '0' + 52;
    if (c == '+' || c == '-') return 62;
    if (c == '/' || c == '_') return 63;
    return -1;
}
static int l_util_base64_decode(lua_State *L) {
    size_t n = 0;
    const unsigned char *s = (const unsigned char *)luaL_checklstring(L, 1, &n);
    luaL_Buffer b; luaL_buffinit(L, &b);
    int acc = 0, bits = 0;
    for (size_t i = 0; i < n; i++) {
        int c = s[i];
        if (c == '=' || c == '\r' || c == '\n' || c == ' ' || c == '\t') continue;
        int v = xu_b64dval(c);
        if (v < 0) { lua_pushnil(L); lua_pushstring(L, "invalid base64"); return 2; }
        acc = (acc << 6) | v; bits += 6;
        if (bits >= 8) { bits -= 8; luaL_addchar(&b, (char)((acc >> bits) & 0xff)); }
    }
    luaL_pushresult(&b);
    return 1;
}

static int l_util_hex_encode(lua_State *L) {
    size_t n = 0;
    const unsigned char *s = (const unsigned char *)luaL_checklstring(L, 1, &n);
    xu_push_hex(L, s, n);
    return 1;
}
static int l_util_hex_decode(lua_State *L) {
    size_t n = 0;
    const char *s = luaL_checklstring(L, 1, &n);
    if (n & 1) { lua_pushnil(L); lua_pushstring(L, "odd hex length"); return 2; }
    luaL_Buffer b; luaL_buffinit(L, &b);
    for (size_t i = 0; i < n; i += 2) {
        int hi = xu_hexval((unsigned char)s[i]);
        int lo = xu_hexval((unsigned char)s[i + 1]);
        if (hi < 0 || lo < 0) { lua_pushnil(L); lua_pushstring(L, "invalid hex"); return 2; }
        luaL_addchar(&b, (char)((hi << 4) | lo));
    }
    luaL_pushresult(&b);
    return 1;
}

/* Canonical existing paths and atomic cache publication. The Windows runtime
** embeds an UTF-8 activeCodePage manifest; A APIs therefore accept UTF-8. */
static int l_util_realpath(lua_State *L) {
    size_t n;
    const char *path = luaL_checklstring(L, 1, &n);
    luaL_argcheck(L, n > 0 && !memchr(path, 0, n), 1, "invalid path");
#ifdef _WIN32
    HANDLE h = CreateFileA(path, 0, FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE,
                          NULL, OPEN_EXISTING, FILE_FLAG_BACKUP_SEMANTICS, NULL);
    if (h == INVALID_HANDLE_VALUE) { lua_pushnil(L); lua_pushstring(L, "cannot resolve path"); return 2; }
    DWORD cap = GetFinalPathNameByHandleA(h, NULL, 0, FILE_NAME_NORMALIZED);
    char *buf = cap ? (char *)malloc((size_t)cap + 1) : NULL;
    DWORD len = buf ? GetFinalPathNameByHandleA(h, buf, cap + 1, FILE_NAME_NORMALIZED) : 0;
    CloseHandle(h);
    if (!len || len > cap) { free(buf); lua_pushnil(L); lua_pushstring(L, "cannot resolve path"); return 2; }
    if (strncmp(buf, "\\\\?\\UNC\\", 8) == 0) { buf[6] = '\\'; lua_pushstring(L, buf + 6); }
    else lua_pushstring(L, strncmp(buf, "\\\\?\\", 4) == 0 ? buf + 4 : buf);
    free(buf);
#else
    char buf[PATH_MAX];
    if (!realpath(path, buf)) { lua_pushnil(L); lua_pushstring(L, strerror(errno)); return 2; }
    lua_pushstring(L, buf);
#endif
    return 1;
}

static int l_util_replace_file(lua_State *L) {
    size_t ns, nd;
    const char *src = luaL_checklstring(L, 1, &ns);
    const char *dst = luaL_checklstring(L, 2, &nd);
    luaL_argcheck(L, ns && !memchr(src, 0, ns), 1, "invalid path");
    luaL_argcheck(L, nd && !memchr(dst, 0, nd), 2, "invalid path");
#ifdef _WIN32
    int ok = MoveFileExA(src, dst, MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH) != 0;
#else
    int ok = rename(src, dst) == 0;
#endif
    if (!ok) { lua_pushnil(L); lua_pushstring(L, "atomic file replacement failed"); return 2; }
    lua_pushboolean(L, 1);
    return 1;
}

/* Reserve a unique empty file in the destination directory, on the same
** filesystem as the eventual rename. The caller owns and removes it. */
static int l_util_temp_file(lua_State *L) {
    size_t n;
    const char *dir = luaL_checklstring(L, 1, &n);
    luaL_argcheck(L, n && !memchr(dir, 0, n), 1, "invalid directory");
#ifdef _WIN32
    char buf[MAX_PATH + 1];
    if (!GetTempFileNameA(dir, "cix", 0, buf)) {
        lua_pushnil(L); lua_pushstring(L, "cannot create temporary file"); return 2;
    }
    lua_pushstring(L, buf);
#else
    char *buf = (char *)malloc(n + 20);
    if (!buf) return luaL_error(L, "out of memory");
    snprintf(buf, n + 20, "%s/.cix-XXXXXX", dir);
    int fd = mkstemp(buf);
    if (fd < 0) { free(buf); lua_pushnil(L); lua_pushstring(L, strerror(errno)); return 2; }
    close(fd);
    lua_pushstring(L, buf);
    free(buf);
#endif
    return 1;
}

static int l_util_stdout_binary(lua_State *L) {
#ifdef _WIN32
    if (fflush(stdout) != 0 || _setmode(_fileno(stdout), _O_BINARY) == -1) {
        lua_pushnil(L); lua_pushstring(L, "cannot switch stdout to binary mode"); return 2;
    }
#endif
    lua_pushboolean(L, 1);
    return 1;
}

/* System online logical CPU count, at least 1 (also on query failure).
** Ignores process/thread affinity, container cpusets and CPU quotas.
** Cloud-server CPU limits are not accounted for; callers should separately
** check their instance limits, cgroup quotas and cloud-provider restrictions.
** This is a system capacity hint, not the CPU budget available to the caller.
** Windows counts all processor groups when targeting Windows 7 or later;
** the legacy GetSystemInfo fallback reports only the current group. */
static int l_util_cpu_count(lua_State *L) {
    long n = 0;
#ifdef _WIN32
#if defined(_WIN32_WINNT) && _WIN32_WINNT >= 0x0601
    n = (long)GetActiveProcessorCount(ALL_PROCESSOR_GROUPS);
#endif
    if (n <= 0) {
        SYSTEM_INFO si;
        GetSystemInfo(&si);
        n = (long)si.dwNumberOfProcessors;
    }
#else
    n = sysconf(_SC_NPROCESSORS_ONLN);
#endif
    lua_pushinteger(L, n > 0 ? (lua_Integer)n : 1);
    return 1;
}

/* Poll redirected stdin without blocking the network/protocol event loop.
** Returns bytes, empty string when idle, or nil + "eof" / error. */
static int l_util_read_stdin(lua_State *L) {
    int cap = (int)luaL_optinteger(L, 1, 65536);
    luaL_argcheck(L, cap > 0 && cap <= 1048576, 1, "invalid read limit");
    char *buf = (char *)malloc((size_t)cap);
    if (!buf) return luaL_error(L, "out of memory");
    int n = 0;
    const char *err = NULL;
#ifdef _WIN32
    HANDLE h = GetStdHandle(STD_INPUT_HANDLE);
    DWORD available = 0, read_count = 0;
    if (GetFileType(h) == FILE_TYPE_DISK) available = (DWORD)cap;
    else if (!PeekNamedPipe(h, NULL, 0, NULL, &available, NULL)) {
        err = GetLastError() == ERROR_BROKEN_PIPE ? "eof" : "stdio requires redirected stdin";
    }
    if (!err && available) {
        if (available > (DWORD)cap) available = (DWORD)cap;
        if (!ReadFile(h, buf, available, &read_count, NULL)) err = "stdin read failed";
        else if (!read_count) err = "eof";
        n = (int)read_count;
    }
#else
    struct pollfd p = { STDIN_FILENO, POLLIN, 0 };
    int ready = poll(&p, 1, 0);
    if (ready < 0 && errno != EINTR) err = "stdin poll failed";
    if (ready > 0) {
        n = (int)read(STDIN_FILENO, buf, (size_t)cap);
        if (!n) err = "eof";
        else if (n < 0) { if (errno != EINTR && errno != EAGAIN) err = "stdin read failed"; n = 0; }
    }
#endif
    if (err) { free(buf); lua_pushnil(L); lua_pushstring(L, err); return 2; }
    lua_pushlstring(L, buf, (size_t)n);
    free(buf);
    return 1;
}

static int l_util_random_bytes(lua_State *L) {
    int n = (int)luaL_optinteger(L, 1, 32);
    luaL_argcheck(L, n > 0 && n <= 4096, 1, "invalid random byte count");
    unsigned char buf[4096];
    int ok = 0;
#ifdef _WIN32
    HMODULE library = LoadLibraryA("bcrypt.dll");
    if (library) {
        typedef LONG (WINAPI *random_fn)(void *, unsigned char *, ULONG, ULONG);
        random_fn generate = (random_fn)GetProcAddress(library, "BCryptGenRandom");
        ok = generate && generate(NULL, buf, (ULONG)n, 2) == 0;
        FreeLibrary(library);
    }
#else
    FILE *f = fopen("/dev/urandom", "rb");
    if (f) { ok = fread(buf, 1, (size_t)n, f) == (size_t)n; fclose(f); }
#endif
    if (!ok) return luaL_error(L, "OS random source unavailable");
    lua_pushlstring(L, (const char *)buf, (size_t)n);
    return 1;
}

/* UTF-8 validation plus system-backed GBK decoding for lua_xutils.c.
 * Android: JNI CharsetDecoder; iOS: CoreFoundation; desktop: Win32/iconv.
 * No bundled mapping table or per-Lua-state callbacks.
 */
#if defined(__ANDROID__)
static JavaVM *xutils_android_vm;

/* Host calls once from JNI_OnLoad before creating workers; VM outlives them.
 * Startup-only, not concurrent with worker use. 0 = success, -1 = invalid VM.
 * Same VM is accepted; replacing a live VM is not supported. */
JNIEXPORT int xutils_android_init(JavaVM *vm) {
    if (!vm || (xutils_android_vm && xutils_android_vm != vm)) return -1;
    if (!xutils_android_vm) xutils_android_vm = vm;
    return 0;
}

/* No Lua allocation here: JNI references and temporary thread attachment must
 * be released before returning to Lua, including all Java exception paths.
 * output is caller-owned, at least 2 * n + 1 bytes. Bootstrap classes only.
 */
static const char *xutils_android_gbk(const unsigned char *s, size_t n,
                                    char *output, size_t capacity, size_t *written) {
    JavaVM *vm = xutils_android_vm;
    JNIEnv *env = NULL;
    jint state;
    int attached = 0, frame = 0;
    const char *error = "Android GBK conversion failed";
    jclass charset_class, decoder_class, action_class, buffer_class, chars_class, string_class;
    jmethodID for_name, new_decoder, malformed, unmappable, wrap, decode, to_string, get_bytes;
    jfieldID report_field;
    jobject charset, decoder, report, buffer, chars, configured;
    jstring gbk_name, utf8_name, string;
    jbyteArray input, encoded;
    jsize length;

    if (!vm) return "Android GBK requires xutils_android_init(JavaVM*) during host startup";
    if (n > INT_MAX) return "GBK input exceeds JNI array limit";
    state = (*vm)->GetEnv(vm, (void **)&env, JNI_VERSION_1_6);
    if (state == JNI_EDETACHED) {
        if ((*vm)->AttachCurrentThread(vm, (void *)&env, NULL) != JNI_OK)
            return "Cannot attach GBK conversion thread to JavaVM";
        attached = 1;
    } else if (state != JNI_OK) {
        return "Cannot obtain JNI environment for GBK conversion";
    }
    /* Do not consume an exception belonging to the host. */
    if ((*env)->ExceptionCheck(env)) {
        if (attached) (*vm)->DetachCurrentThread(vm);
        return "JNI exception pending before GBK conversion";
    }
    if ((*env)->PushLocalFrame(env, 32) < 0) goto done;
    frame = 1;

#define XUTILS_JNI_GET(target, expression) do { \
    target = (expression); \
    if (!(target) || (*env)->ExceptionCheck(env)) goto done; \
} while (0)
    XUTILS_JNI_GET(charset_class, (*env)->FindClass(env, "java/nio/charset/Charset"));
    XUTILS_JNI_GET(decoder_class, (*env)->FindClass(env, "java/nio/charset/CharsetDecoder"));
    XUTILS_JNI_GET(action_class, (*env)->FindClass(env, "java/nio/charset/CodingErrorAction"));
    XUTILS_JNI_GET(buffer_class, (*env)->FindClass(env, "java/nio/ByteBuffer"));
    XUTILS_JNI_GET(chars_class, (*env)->FindClass(env, "java/nio/CharBuffer"));
    XUTILS_JNI_GET(string_class, (*env)->FindClass(env, "java/lang/String"));
    XUTILS_JNI_GET(for_name, (*env)->GetStaticMethodID(env, charset_class, "forName", "(Ljava/lang/String;)Ljava/nio/charset/Charset;"));
    XUTILS_JNI_GET(new_decoder, (*env)->GetMethodID(env, charset_class, "newDecoder", "()Ljava/nio/charset/CharsetDecoder;"));
    XUTILS_JNI_GET(malformed, (*env)->GetMethodID(env, decoder_class, "onMalformedInput", "(Ljava/nio/charset/CodingErrorAction;)Ljava/nio/charset/CharsetDecoder;"));
    XUTILS_JNI_GET(unmappable, (*env)->GetMethodID(env, decoder_class, "onUnmappableCharacter", "(Ljava/nio/charset/CodingErrorAction;)Ljava/nio/charset/CharsetDecoder;"));
    XUTILS_JNI_GET(report_field, (*env)->GetStaticFieldID(env, action_class, "REPORT", "Ljava/nio/charset/CodingErrorAction;"));
    XUTILS_JNI_GET(wrap, (*env)->GetStaticMethodID(env, buffer_class, "wrap", "([B)Ljava/nio/ByteBuffer;"));
    XUTILS_JNI_GET(decode, (*env)->GetMethodID(env, decoder_class, "decode", "(Ljava/nio/ByteBuffer;)Ljava/nio/CharBuffer;"));
    XUTILS_JNI_GET(to_string, (*env)->GetMethodID(env, chars_class, "toString", "()Ljava/lang/String;"));
    XUTILS_JNI_GET(get_bytes, (*env)->GetMethodID(env, string_class, "getBytes", "(Ljava/lang/String;)[B"));
    XUTILS_JNI_GET(gbk_name, (*env)->NewStringUTF(env, "GBK"));
    XUTILS_JNI_GET(utf8_name, (*env)->NewStringUTF(env, "UTF-8"));
    XUTILS_JNI_GET(charset, (*env)->CallStaticObjectMethod(env, charset_class, for_name, gbk_name));
    XUTILS_JNI_GET(decoder, (*env)->CallObjectMethod(env, charset, new_decoder));
    XUTILS_JNI_GET(report, (*env)->GetStaticObjectField(env, action_class, report_field));
    XUTILS_JNI_GET(configured, (*env)->CallObjectMethod(env, decoder, malformed, report));
    XUTILS_JNI_GET(configured, (*env)->CallObjectMethod(env, decoder, unmappable, report));
    XUTILS_JNI_GET(input, (*env)->NewByteArray(env, (jsize)n));
    (*env)->SetByteArrayRegion(env, input, 0, (jsize)n, (const jbyte *)s);
    if ((*env)->ExceptionCheck(env)) goto done;
    XUTILS_JNI_GET(buffer, (*env)->CallStaticObjectMethod(env, buffer_class, wrap, input));
    error = "Invalid or unmappable GBK in Android CharsetDecoder";
    XUTILS_JNI_GET(chars, (*env)->CallObjectMethod(env, decoder, decode, buffer));
    error = "Android UTF-8 conversion failed";
    XUTILS_JNI_GET(string, (*env)->CallObjectMethod(env, chars, to_string));
    /* getBytes("UTF-8") produces standard UTF-8, unlike GetStringUTFChars,
     * whose modified UTF-8 would corrupt embedded NUL and supplementary text. */
    XUTILS_JNI_GET(encoded, (*env)->CallObjectMethod(env, string, get_bytes, utf8_name));
    length = (*env)->GetArrayLength(env, encoded);
    if ((*env)->ExceptionCheck(env)) goto done;
    if (length < 0 || (size_t)length > capacity) { error = "Android GBK output exceeds capacity"; goto done; }
    (*env)->GetByteArrayRegion(env, encoded, 0, length, (jbyte *)output);
    if ((*env)->ExceptionCheck(env)) goto done;
    *written = (size_t)length;
    error = NULL;
done:
    if ((*env)->ExceptionCheck(env)) (*env)->ExceptionClear(env);
    if (frame) (*env)->PopLocalFrame(env, NULL);
    if (attached && (*vm)->DetachCurrentThread(vm) != JNI_OK)
        error = "Cannot detach GBK conversion thread from JavaVM";
#undef XUTILS_JNI_GET
    return error;
}

#endif

static int xutils_encoding_failure(lua_State *L, const char *message) {
    lua_pushnil(L);
    lua_pushstring(L, message);
    return 2;
}

/* Return SIZE_MAX on success, otherwise the zero-based invalid sequence offset. */
static size_t xutils_utf8_error(const unsigned char *s, size_t n) {
    size_t i = 0;
    while (i < n) {
        unsigned char b = s[i];
        size_t width, j;
        if (b < 0x80) { ++i; continue; }
        width = b >= 0xc2 && b <= 0xdf ? 2 :
            b >= 0xe0 && b <= 0xef ? 3 : b >= 0xf0 && b <= 0xf4 ? 4 : 0;
        if (!width || n - i < width) return i;
        for (j = 1; j < width; ++j)
            if (s[i+j] < 0x80 || s[i+j] > 0xbf) return i;
        if ((b == 0xe0 && s[i+1] < 0xa0) || (b == 0xed && s[i+1] > 0x9f) ||
            (b == 0xf0 && s[i+1] < 0x90) || (b == 0xf4 && s[i+1] > 0x8f)) return i;
        i += width;
    }
    return SIZE_MAX;
}

static int xutils_decode_error(lua_State *L, const char *encoding, size_t offset) {
    char message[96];
    snprintf(message, sizeof(message), "Invalid %s at byte %llu", encoding,
        (unsigned long long)(offset + 1));
    lua_pushnil(L);
    lua_pushstring(L, message);
    lua_pushinteger(L, (lua_Integer)(offset + 1));
    return 3;
}

/* to_utf8(bytes [, 'auto' | 'utf-8' | 'gbk']) -> text, encoding | nil, error, byte */
static int l_util_to_utf8(lua_State *L) {
    size_t n, offset = 0, bad, i;
    const unsigned char *s = (const unsigned char *)luaL_checklstring(L, 1, &n);
    const char *mode = luaL_optstring(L, 2, "auto");
    int gbk = strcmp(mode, "gbk") == 0;
    int automatic = strcmp(mode, "auto") == 0;
    luaL_argcheck(L, gbk || automatic || strcmp(mode, "utf-8") == 0, 2,
        "expected auto, utf-8 or gbk");
    if (!gbk) {
        if (n >= 3 && s[0] == 0xef && s[1] == 0xbb && s[2] == 0xbf) offset = 3;
        bad = xutils_utf8_error(s + offset, n - offset);
        if (bad == SIZE_MAX) {
            if (!offset) lua_pushvalue(L, 1);
            else lua_pushlstring(L, (const char *)s + offset, n - offset);
            lua_pushstring(L, offset ? "utf-8-bom" : "utf-8");
            return 2;
        }
        /* An explicit BOM is authoritative; never reinterpret corrupt UTF-8 as GBK. */
        if (!automatic || offset) return xutils_decode_error(L, "UTF-8", offset + bad);
    }
    /* Reject malformed GBK byte structure; mapping comes from the platform. */
    for (i = 0; i < n;) {
        unsigned char b = s[i];
        if (b < 0x80) { ++i; continue; }
        if (b < 0x81 || b > 0xfe || n - i < 2 || s[i+1] < 0x40 || s[i+1] > 0xfe || s[i+1] == 0x7f)
            return xutils_decode_error(L, "GBK", i);
        i += 2;
    }
    if (n == 0) { lua_pushliteral(L, ""); lua_pushliteral(L, "gbk"); return 2; }
#if defined(__ANDROID__)
    {
        char *output;
        size_t capacity, written = 0;
        const char *error;
        if (n > INT_MAX || n > (SIZE_MAX - 1) / 2)
            return xutils_encoding_failure(L, "GBK input exceeds JNI array limit");
        capacity = n * 2 + 1;
        /* Allocate before acquiring JNI resources: Lua allocation may longjmp. */
        output = (char *)lua_newuserdata(L, capacity);
        error = xutils_android_gbk(s, n, output, capacity, &written);
        if (error) return xutils_encoding_failure(L, error);
        lua_pushlstring(L, output, written);
    }
#elif defined(__APPLE__) && TARGET_OS_IPHONE
    {
        CFStringRef decoded;
        CFIndex length, consumed, written = 0, capacity;
        UInt8 *output;
        if (n > ((size_t)LONG_MAX - 1) / 2)
            return xutils_encoding_failure(L, "GBK input exceeds CoreFoundation limit");
        capacity = (CFIndex)(n * 2 + 1);
        output = (UInt8 *)lua_newuserdata(L, (size_t)capacity);
        if (!CFStringIsEncodingAvailable(kCFStringEncodingGBK_95))
            return xutils_encoding_failure(L, "CoreFoundation does not provide GBK conversion");
        decoded = CFStringCreateWithBytes(kCFAllocatorDefault, s, (CFIndex)n,
                                         kCFStringEncodingGBK_95, false);
        if (!decoded) return xutils_encoding_failure(L, "Invalid or unmappable GBK in CoreFoundation");
        length = CFStringGetLength(decoded);
        consumed = CFStringGetBytes(decoded, CFRangeMake(0, length), kCFStringEncodingUTF8,
                                   0, false, output, capacity, &written);
        CFRelease(decoded);
        if (consumed != length || written < 0 || written > capacity)
            return xutils_encoding_failure(L, "CoreFoundation UTF-8 conversion failed");
        lua_pushlstring(L, (const char *)output, (size_t)written);
    }
#elif defined(_WIN32)
    {
        int wide_len, utf8_len;
        WCHAR *wide;
        char *out;
        if (n > INT_MAX) return xutils_encoding_failure(L, "GBK input exceeds Windows API limit");
        wide_len = MultiByteToWideChar(936, MB_ERR_INVALID_CHARS, (const char *)s, (int)n, NULL, 0);
        if (!wide_len) return xutils_encoding_failure(L, "GBK conversion failed in MultiByteToWideChar");
        wide = (WCHAR *)lua_newuserdata(L, (size_t)wide_len * sizeof(WCHAR));
        if (MultiByteToWideChar(936, MB_ERR_INVALID_CHARS, (const char *)s, (int)n, wide, wide_len) != wide_len)
            return xutils_encoding_failure(L, "GBK conversion failed in MultiByteToWideChar");
        utf8_len = WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS, wide, wide_len, NULL, 0, NULL, NULL);
        if (!utf8_len) return xutils_encoding_failure(L, "GBK conversion failed in WideCharToMultiByte");
        out = (char *)lua_newuserdata(L, (size_t)utf8_len);
        if (WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS, wide, wide_len, out, utf8_len, NULL, NULL) != utf8_len)
            return xutils_encoding_failure(L, "GBK conversion failed in WideCharToMultiByte");
        lua_pushlstring(L, out, (size_t)utf8_len);
    }
#else
    {
        iconv_t converter;
        char *input = (char *)s, *output, *cursor;
        size_t remaining = n, capacity, available, result;
        int error;
        if (n > (SIZE_MAX - 1) / 2) return xutils_encoding_failure(L, "GBK input too large");
        capacity = n * 2 + 1;
        output = (char *)lua_newuserdata(L, capacity);
        cursor = output;
        available = capacity;
        converter = iconv_open("UTF-8", "GBK");
        if (converter == (iconv_t)-1)
            return xutils_encoding_failure(L, "System iconv does not provide GBK to UTF-8 conversion");
        result = iconv(converter, &input, &remaining, &cursor, &available);
        error = errno;
        iconv_close(converter);
        if (result == (size_t)-1) {
            if (error == EILSEQ || error == EINVAL)
                return xutils_decode_error(L, "GBK", n - remaining);
            return xutils_encoding_failure(L, "GBK conversion failed in iconv");
        }
        if (result != 0 || remaining != 0)
            return xutils_encoding_failure(L, "GBK conversion was not lossless");
        lua_pushlstring(L, output, capacity - available);
    }
#endif
    lua_pushliteral(L, "gbk");
    return 2;
}

static const luaL_Reg xutils_funcs[] = {
    { "to_utf8", l_util_to_utf8 },
    { "read_stdin",   l_util_read_stdin },
    { "stdout_binary", l_util_stdout_binary },
    { "cpu_count",    l_util_cpu_count },
    { "random_bytes", l_util_random_bytes },
    { "realpath",     l_util_realpath },
    { "replace_file", l_util_replace_file },
    { "temp_file",    l_util_temp_file },
    { "json_pack",    l_util_json_pack },
    { "json_unpack",  l_util_json_unpack },
    { "load_config",  l_util_load_config },
    { "get_config",   l_util_get_config },
    { "get_int",      l_util_get_int },
    { "get_double",   l_util_get_double },
    { "get_string",   l_util_get_string },
    { "scan_dir",     l_util_scan_dir },
    { "list_dir",     l_util_list_dir },
    { "stat",         l_util_stat },
    { "mkdir_p",      l_util_mkdir_p },
    { "rmtree",       l_util_rmtree },
    { "cwd",          l_util_cwd },

    /* hashes: raw digest + lowercase-hex variant */
    { "sha1",          l_util_sha1 },
    { "sha1_hex",      l_util_sha1_hex },
    { "sha256",        l_util_sha256 },
    { "sha256_hex",    l_util_sha256_hex },
    { "sha512",        l_util_sha512 },
    { "sha512_hex",    l_util_sha512_hex },
    { "md5",           l_util_md5 },
    { "md5_hex",       l_util_md5_hex },

    /* HMAC */
    { "hmac_sha256",     l_util_hmac_sha256 },
    { "hmac_sha256_hex", l_util_hmac_sha256_hex },
    { "pbkdf2_sha256",   l_util_pbkdf2_sha256 },
    { "hmac_sha1",       l_util_hmac_sha1 },
    { "hmac_sha1_hex",   l_util_hmac_sha1_hex },

    /* AES-CBC, raw blocks: the caller pads */
    { "aes_cbc_encrypt", l_util_aes_cbc_encrypt },
    { "aes_cbc_decrypt", l_util_aes_cbc_decrypt },

    /* encodings */
    { "base64_encode",     l_util_base64_encode },
    { "base64_decode",     l_util_base64_decode },
    { "base64url_encode",  l_util_base64url_encode },
    { "base64url_decode",  l_util_base64_decode },   /* one decoder handles both */
    { "hex_encode",        l_util_hex_encode },
    { "hex_decode",        l_util_hex_decode },

    { NULL, NULL }
};

#if defined(LUA_VERSION_NUM) && LUA_VERSION_NUM < 502
/* utf8 library for LuaJIT, following Lua 5.4's lutf8lib: strict decoding by
 * default; the optional `lax` argument also accepts surrogates and code points
 * up to 0x7FFFFFFF. Lua strings are NUL-terminated, so reading one byte past
 * the end (as 5.4 does) is safe. */
#define XU8_MAXUNICODE 0x10FFFFu
#define XU8_MAXUTF     0x7FFFFFFFu
/* 5.1 patterns stop at an embedded NUL, so the class spells it %z. */
#define XU8_PATTERN    "[%z\x01-\x7F\xC2-\xFD][\x80-\xBF]*"
#define xu8_iscont(c)  (((unsigned char)(c) & 0xC0) == 0x80)

static lua_Integer xu8_posrelat(lua_Integer pos, size_t len) {
    if (pos >= 0) return pos;
    if ((size_t)-pos > len) return 0;
    return (lua_Integer)len + pos + 1;
}

static const char *xu8_decode(const char *s, unsigned int *val, int strict) {
    static const unsigned int limits[] = { ~0u, 0x80, 0x800, 0x10000u, 0x200000u, 0x4000000u };
    unsigned int c = (unsigned char)s[0];
    unsigned int res = 0;
    if (c < 0x80) {
        res = c;
    } else {
        int count = 0;
        for (; c & 0x40; c <<= 1) {
            unsigned int cc = (unsigned char)s[++count];
            if ((cc & 0xC0) != 0x80) return NULL;
            res = (res << 6) | (cc & 0x3F);
        }
        res |= (unsigned int)(c & 0x7F) << (count * 5);
        if (count > 5 || res > XU8_MAXUTF || res < limits[count]) return NULL;
        s += count;
    }
    if (strict && (res > XU8_MAXUNICODE || (res >= 0xD800u && res <= 0xDFFFu))) return NULL;
    if (val) *val = res;
    return s + 1;
}

/* Same byte layout as Lua's luaO_utf8esc (up to 6 bytes). */
static int xu8_encode(char *out, unsigned long x) {
    char buf[8];
    int n = 1;
    if (x < 0x80) {
        buf[7] = (char)x;
    } else {
        unsigned int mfb = 0x3f;
        do {
            buf[8 - (n++)] = (char)(0x80 | (x & 0x3f));
            x >>= 6;
            mfb >>= 1;
        } while (x > mfb);
        buf[8 - n] = (char)((~mfb << 1) | x);
    }
    memcpy(out, buf + 8 - n, (size_t)n);
    return n;
}

static int xu8_len(lua_State *L) {
    size_t len;
    const char *s = luaL_checklstring(L, 1, &len);
    lua_Integer posi = xu8_posrelat(luaL_optinteger(L, 2, 1), len);
    lua_Integer posj = xu8_posrelat(luaL_optinteger(L, 3, -1), len);
    int lax = lua_toboolean(L, 4);
    lua_Integer n = 0;
    luaL_argcheck(L, 1 <= posi && --posi <= (lua_Integer)len, 2, "initial position out of bounds");
    luaL_argcheck(L, --posj < (lua_Integer)len, 3, "final position out of bounds");
    while (posi <= posj) {
        const char *s1 = xu8_decode(s + posi, NULL, !lax);
        if (!s1) {
            lua_pushnil(L);
            lua_pushinteger(L, posi + 1);
            return 2;
        }
        posi = s1 - s;
        n++;
    }
    lua_pushinteger(L, n);
    return 1;
}

static int xu8_codepoint(lua_State *L) {
    size_t len;
    const char *s = luaL_checklstring(L, 1, &len);
    lua_Integer posi = xu8_posrelat(luaL_optinteger(L, 2, 1), len);
    lua_Integer pose = xu8_posrelat(luaL_optinteger(L, 3, posi), len);
    int lax = lua_toboolean(L, 4);
    const char *se;
    int n;
    luaL_argcheck(L, posi >= 1, 2, "out of bounds");
    luaL_argcheck(L, pose <= (lua_Integer)len, 3, "out of bounds");
    if (posi > pose) return 0;
    if (pose - posi >= INT_MAX) return luaL_error(L, "string slice too long");
    luaL_checkstack(L, (int)(pose - posi) + 1, "string slice too long");
    n = 0;
    se = s + pose;
    for (s += posi - 1; s < se;) {
        unsigned int code;
        s = xu8_decode(s, &code, !lax);
        if (!s) return luaL_error(L, "invalid UTF-8 code");
        lua_pushinteger(L, (lua_Integer)code);
        n++;
    }
    return n;
}

static int xu8_char(lua_State *L) {
    int n = lua_gettop(L), i;
    luaL_Buffer b;
    luaL_buffinit(L, &b);
    for (i = 1; i <= n; i++) {
        lua_Number code = luaL_checknumber(L, i);
        char buf[8];
        luaL_argcheck(L, code >= 0 && code <= XU8_MAXUTF && code == (lua_Number)(unsigned long)code,
                      i, "value out of range");
        luaL_addlstring(&b, buf, (size_t)xu8_encode(buf, (unsigned long)code));
    }
    luaL_pushresult(&b);
    return 1;
}

static int xu8_offset(lua_State *L) {
    size_t len;
    const char *s = luaL_checklstring(L, 1, &len);
    lua_Integer n = luaL_checkinteger(L, 2);
    lua_Integer posi = n >= 0 ? 1 : (lua_Integer)len + 1;
    posi = xu8_posrelat(luaL_optinteger(L, 3, posi), len);
    luaL_argcheck(L, 1 <= posi && --posi <= (lua_Integer)len, 3, "position out of bounds");
    if (n == 0) {
        while (posi > 0 && xu8_iscont(s[posi])) posi--;
    } else {
        if (xu8_iscont(s[posi])) return luaL_error(L, "initial position is a continuation byte");
        if (n < 0) {
            while (n < 0 && posi > 0) {
                do { posi--; } while (posi > 0 && xu8_iscont(s[posi]));
                n++;
            }
        } else {
            n--;
            while (n > 0 && posi < (lua_Integer)len) {
                do { posi++; } while (xu8_iscont(s[posi]));
                n--;
            }
        }
    }
    if (n == 0) lua_pushinteger(L, posi + 1);
    else lua_pushnil(L);
    return 1;
}

static int xu8_iter_aux(lua_State *L, int strict) {
    size_t len;
    const char *s = luaL_checklstring(L, 1, &len);
    lua_Integer pos = lua_tointeger(L, 2);
    size_t n = pos < 0 ? len : (size_t)pos;
    unsigned int code;
    const char *next;
    if (n < len) {
        while (xu8_iscont(s[n])) n++;
    }
    if (n >= len) return 0;
    next = xu8_decode(s + n, &code, strict);
    if (!next || xu8_iscont(*next)) return luaL_error(L, "invalid UTF-8 code");
    lua_pushinteger(L, (lua_Integer)n + 1);
    lua_pushinteger(L, (lua_Integer)code);
    return 2;
}
static int xu8_iter_strict(lua_State *L) { return xu8_iter_aux(L, 1); }
static int xu8_iter_lax(lua_State *L) { return xu8_iter_aux(L, 0); }

static int xu8_codes(lua_State *L) {
    int lax = lua_toboolean(L, 2);
    const char *s = luaL_checkstring(L, 1);
    luaL_argcheck(L, !xu8_iscont(*s), 1, "invalid UTF-8 code");
    lua_pushcfunction(L, lax ? xu8_iter_lax : xu8_iter_strict);
    lua_pushvalue(L, 1);
    lua_pushinteger(L, 0);
    return 3;
}

static const luaL_Reg xu8_funcs[] = {
    { "char",      xu8_char },
    { "codepoint", xu8_codepoint },
    { "codes",     xu8_codes },
    { "len",       xu8_len },
    { "offset",    xu8_offset },
    { NULL, NULL }
};

/* Registers global `utf8` and package.loaded.utf8 unless one already exists. */
int xlua_open_utf8(lua_State *L) {
    lua_getglobal(L, "utf8");
    if (!lua_isnil(L, -1)) {
        lua_pop(L, 1);
        return 0;
    }
    lua_pop(L, 1);
    lua_newtable(L);
    luaL_register(L, NULL, xu8_funcs);
    lua_pushlstring(L, XU8_PATTERN, sizeof(XU8_PATTERN) - 1);
    lua_setfield(L, -2, "charpattern");
    lua_pushvalue(L, -1);
    lua_setglobal(L, "utf8");
    lua_getglobal(L, "package");
    if (lua_istable(L, -1)) {
        lua_getfield(L, -1, "loaded");
        if (lua_istable(L, -1)) {
            lua_pushvalue(L, -3);
            lua_setfield(L, -2, "utf8");
        }
        lua_pop(L, 1);
    }
    lua_pop(L, 2);
    return 0;
}
#endif

LUALIB_API int luaopen_xutils(lua_State *L) {
    luaL_newlib(L, xutils_funcs);
    push_json_null(L);
    lua_setfield(L, -2, "json_null");
    push_json_array_mt(L);
    lua_setfield(L, -2, "json_array_mt");

    return 1;
}
