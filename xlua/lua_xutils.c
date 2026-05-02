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

#include "../3rd/yyjson.h"
#include "xargs.h"

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
    if (is_array && count == max) {
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

    if (len > (size_t)LUA_MAXINTEGER) {
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
            if (n <= (uint64_t)LUA_MAXINTEGER) {
                lua_pushinteger(L, (lua_Integer)n);
            } else {
                lua_pushnumber(L, (lua_Number)n);
            }
            return 1;
        }
        if (yyjson_is_sint(val)) {
            int64_t n = yyjson_get_sint(val);
            if (n < (int64_t)LUA_MININTEGER || n > (int64_t)LUA_MAXINTEGER) {
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
    yyjson_mut_doc *doc = yyjson_mut_doc_new(NULL);
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
    char *out = yyjson_mut_val_write_opts(root, 0, NULL, &len, &err);
    yyjson_mut_doc_free(doc);
    if (!out) {
        return json_error(L, err.msg ? err.msg : "json pack failed");
    }

    lua_pushlstring(L, out, len);
    free(out);
    return 1;
}

static int l_util_json_unpack(lua_State *L) {
    size_t len = 0;
    const char *text = luaL_checklstring(L, 1, &len);
    yyjson_read_err err;
    memset(&err, 0, sizeof(err));

    yyjson_doc *doc = yyjson_read_opts((char *)(void *)text, len, 0, NULL, &err);
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

static const luaL_Reg xutils_funcs[] = {
    { "json_pack",    l_util_json_pack },
    { "json_unpack",  l_util_json_unpack },
    { "load_config",  l_util_load_config },
    { "get_config",   l_util_get_config },
    { "scan_dir",     l_util_scan_dir },
    { NULL, NULL }
};

LUALIB_API int luaopen_xutils(lua_State *L) {
    luaL_newlib(L, xutils_funcs);
    push_json_null(L);
    lua_setfield(L, -2, "json_null");

    return 1;
}
