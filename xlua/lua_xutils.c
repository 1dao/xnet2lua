/* lua_xutils.c - Small generic Lua utility bindings.
**
** Keep this module as a lightweight grab bag for tiny helpers.
** Current API:
**   xutils.json_pack(value)   -> JSON string
**   xutils.json_unpack(text)  -> Lua value
**   xutils.json_null          -> sentinel for JSON null
**   xutils.load_config(path)  -> true | false,err
**   xutils.get_config(key[, default]) -> value | default | nil
**   xutils.scan_dir(path)     -> { { path=..., rel=... }, ... } | nil,err
*/

#include <math.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <stdio.h>
#include <limits.h>

#ifdef _WIN32
#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif
#include <windows.h>
#else
#include <dirent.h>
#include <sys/stat.h>
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
                              char *errbuf, size_t errcap) {
#ifdef _WIN32
    char *pattern = path_join_dup(dir, "*");
    if (!pattern) {
        snprintf(errbuf, errcap, "out of memory");
        return -1;
    }

    WIN32_FIND_DATAA data;
    HANDLE h = FindFirstFileA(pattern, &data);
    free(pattern);
    if (h == INVALID_HANDLE_VALUE) {
        snprintf(errbuf, errcap, "cannot open directory: %s", dir);
        return -1;
    }

    do {
        const char *name = data.cFileName;
        if (strcmp(name, ".") == 0 || strcmp(name, "..") == 0) continue;

        char *full = path_join_dup(dir, name);
        char *child_rel = rel_join_dup(rel, name);
        if (!full || !child_rel) {
            free(full);
            free(child_rel);
            FindClose(h);
            snprintf(errbuf, errcap, "out of memory");
            return -1;
        }

        if (data.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY) {
            if (scan_dir_recursive(L, table_idx, count, full, child_rel,
                                   errbuf, errcap) != 0) {
                free(full);
                free(child_rel);
                FindClose(h);
                return -1;
            }
        } else {
            scan_dir_push_file(L, table_idx, count, full, child_rel);
        }
        free(full);
        free(child_rel);
    } while (FindNextFileA(h, &data));

    FindClose(h);
    return 0;
#else
    DIR *d = opendir(dir);
    if (!d) {
        snprintf(errbuf, errcap, "cannot open directory: %s", dir);
        return -1;
    }

    struct dirent *ent;
    while ((ent = readdir(d)) != NULL) {
        const char *name = ent->d_name;
        if (strcmp(name, ".") == 0 || strcmp(name, "..") == 0) continue;

        char *full = path_join_dup(dir, name);
        char *child_rel = rel_join_dup(rel, name);
        if (!full || !child_rel) {
            free(full);
            free(child_rel);
            closedir(d);
            snprintf(errbuf, errcap, "out of memory");
            return -1;
        }

        struct stat st;
        if (stat(full, &st) != 0) {
            free(full);
            free(child_rel);
            continue;
        }

        if (S_ISDIR(st.st_mode)) {
            if (scan_dir_recursive(L, table_idx, count, full, child_rel,
                                   errbuf, errcap) != 0) {
                free(full);
                free(child_rel);
                closedir(d);
                return -1;
            }
        } else if (S_ISREG(st.st_mode)) {
            scan_dir_push_file(L, table_idx, count, full, child_rel);
        }
        free(full);
        free(child_rel);
    }

    closedir(d);
    return 0;
#endif
}

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
    { "scan_dir",     l_util_scan_dir },

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
