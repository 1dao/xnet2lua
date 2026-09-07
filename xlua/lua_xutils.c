/* lua_xutils.c - Small generic Lua utility bindings.
**
** Keep this module as a lightweight grab bag for tiny helpers.
** Current API:
**   xutils.json_pack(value)   -> JSON string
**   xutils.json_unpack(text)  -> Lua value
**   xutils.json_null          -> sentinel for JSON null
**   xutils.load_config(path)  -> true | false,err
**   xutils.get_config(key[, default]) -> value | default | nil
**   xutils.get_int(key[, default])    -> integer | nil   (default: integer)
**   xutils.get_double(key[, default]) -> number | nil    (default: number)
**   xutils.get_string(key[, default]) -> string | nil    (default: string)
**   xutils.scan_dir(path)     -> { { path=..., rel=... }, ... } | nil,err
**   xutils.list_dir(path)     -> { { name=..., dir=... }, ... } | nil,err  (one level)
**   xutils.mkdir_p(path)      -> true | nil,err
**   xutils.rmtree(path)       -> true | nil,err
**   xutils.cwd()              -> string | nil,err
**   xutils.pbkdf2_sha256(pw, salt, iter [, dklen]) -> raw string | nil,err
*/

#include <math.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <stdio.h>
#include <limits.h>
#include <errno.h>

#ifdef _WIN32
#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif
#include <windows.h>
#else
#include <dirent.h>
#include <sys/stat.h>
#include <fcntl.h>
#include <unistd.h>
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

#if defined(LUA_VERSION_NUM) && LUA_VERSION_NUM < 502
static int lua_isinteger(lua_State *L, int idx) {
    if (!lua_isnumber(L, idx)) return 0;
    lua_Number n = lua_tonumber(L, idx);
    lua_Integer i = lua_tointeger(L, idx);
    return ((lua_Number)i == n);
}

static const char *luaL_tolstring(lua_State *L, int idx, size_t *len) {
    idx = (idx > 0 || idx <= LUA_REGISTRYINDEX) ? idx : lua_gettop(L) + idx + 1;
    lua_getglobal(L, "tostring");
    lua_pushvalue(L, idx);
    lua_call(L, 1, 1);
    return lua_tolstring(L, -1, len);
}
#endif

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
    if (lua_json_table_is_array(L, idx, &array_len)) {
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
    const char *path = luaL_checkstring(L, 1);
    size_t n = strlen(path);
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
        if (!last && c != '/' && c != '\\') continue;
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
            if (e != ERROR_ALREADY_EXISTS) {
                free(work);
                lua_pushnil(L);
                lua_pushfstring(L, "cannot create: %s", work);
                return 2;
            }
        }
#else
        if (!skip && mkdir(work, 0777) != 0 && errno != EEXIST) {
            int e = errno;
            free(work);
            lua_pushnil(L);
            lua_pushfstring(L, "cannot create %s: %s", path, strerror(e));
            return 2;
        }
#endif
        if (!last) work[i] = c;
    }

    free(work);
    lua_pushboolean(L, 1);
    return 1;
}

/* xutils.list_dir(path) -> { { name=..., dir=bool }, ... } | nil, err
**
** ONE level. scan_dir recurses with no depth limit, which makes it unusable on
** anything that might contain a git object store; this is the "what is directly
** in here" call that a scratch sweep or a repository listing actually wants.
** '.' and '..' are omitted.
*/
static int l_util_list_dir(lua_State *L) {
    const char *path = luaL_checkstring(L, 1);
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
        lua_newtable(L);
        lua_pushstring(L, name);
        lua_setfield(L, -2, "name");
        lua_pushboolean(L, (fd.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY) != 0);
        lua_setfield(L, -2, "dir");
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

        int is_dir = 0;
#ifdef DT_DIR
        if (ent->d_type == DT_DIR)      is_dir = 1;
        else if (ent->d_type != DT_UNKNOWN) is_dir = 0;
        else
#endif
        {
            char *full = path_join_dup(path, name);
            struct stat st;
            if (full && lstat(full, &st) == 0) is_dir = S_ISDIR(st.st_mode);
            free(full);
        }

        lua_newtable(L);
        lua_pushstring(L, name);
        lua_setfield(L, -2, "name");
        lua_pushboolean(L, is_dir);
        lua_setfield(L, -2, "dir");
        lua_rawseti(L, -2, ++count);
    }
    closedir(dp);
#endif
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

static const luaL_Reg xutils_funcs[] = {
    { "json_pack",    l_util_json_pack },
    { "json_unpack",  l_util_json_unpack },
    { "load_config",  l_util_load_config },
    { "get_config",   l_util_get_config },
    { "get_int",      l_util_get_int },
    { "get_double",   l_util_get_double },
    { "get_string",   l_util_get_string },
    { "scan_dir",     l_util_scan_dir },
    { "list_dir",     l_util_list_dir },
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

    /* encodings */
    { "base64_encode",     l_util_base64_encode },
    { "base64_decode",     l_util_base64_decode },
    { "base64url_encode",  l_util_base64url_encode },
    { "base64url_decode",  l_util_base64_decode },   /* one decoder handles both */
    { "hex_encode",        l_util_hex_encode },
    { "hex_decode",        l_util_hex_decode },

    { NULL, NULL }
};

LUALIB_API int luaopen_xutils(lua_State *L) {
    luaL_newlib(L, xutils_funcs);
    push_json_null(L);
    lua_setfield(L, -2, "json_null");

    return 1;
}
