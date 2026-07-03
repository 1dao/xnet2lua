/* lua_xrecord.c -- Lua bindings for xrecord (schema-defined compact record
** pools; see xrecord.h for the design rationale).
**
** Create one handle per object TYPE (Item, Quest, ...), not one per instance
** -- individual records never become Lua objects, only ints (ids) do:
**
**   local item_h = xrecord.create({
**       { name = "hp",   type = "int"    },
**       { name = "name", type = "string" },
**       { name = "dead", type = "bool"   },
**   }, 100000)
**
**   item_h:bind(id)                    -- claim a slot for a caller-minted id
**   item_h:set(id, "hp", 100)
**   local hp = item_h:get(id, "hp")
**   item_h:unbind(id)                  -- release the slot
**
** NOT thread-safe: create one handle per Lua state (each xnet worker thread
** owns its own), never share a handle across threads.
*/

#include <stdlib.h>
#include <string.h>
#include <stdint.h>

#if defined(LUA_EMBEDDED)
#include "../3rd/minilua.h"
#else
#include "lua.h"
#include "lauxlib.h"
#endif

#include "../xrecord.h"

#define LUA_XRECORD_META "xrecord.handle"
#define XRECORD_MAX_FIELDS 64
#define XRECORD_MAX_NAME_LEN 63

typedef struct { xrecord_t *s; } LuaRecord;

static LuaRecord *check_record(lua_State *L, int idx) {
    return (LuaRecord *)luaL_checkudata(L, idx, LUA_XRECORD_META);
}

static void push_record(lua_State *L, xrecord_t *s) {
    LuaRecord *u = (LuaRecord *)lua_newuserdata(L, sizeof(LuaRecord));
    u->s = s;
    luaL_setmetatable(L, LUA_XRECORD_META);
}

static const char *status_msg(xrecord_status st) {
    switch (st) {
        case XRECORD_OK:            return NULL;
        case XRECORD_NOTFOUND:      return "id not bound";
        case XRECORD_EXISTS:        return "id already bound";
        case XRECORD_FULL:          return "pool capacity exhausted";
        case XRECORD_NOFIELD:       return "unknown field";
        case XRECORD_TYPE_MISMATCH: return "value type does not match field schema";
        case XRECORD_OUT_OF_RANGE:  return "value out of range for field type";
        case XRECORD_NOMEM:         return "out of memory";
        case XRECORD_BADARG:        return "bad argument";
        default:                    return "unknown error";
    }
}

/* Lua value -> xrecord_value (string ptr is borrowed from the Lua stack, only
** valid for the duration of the xrecord_set call that consumes it).
**
** Numbers are tagged XRECORD_V_NUM carrying a plain double regardless of
** field width -- Lua/LuaJIT has no int/float distinction to key off of here;
** xrecord_set narrows and range-checks against the target field's declared
** type (see xrecord.h). */
static int to_value(lua_State *L, int idx, xrecord_value *out) {
    switch (lua_type(L, idx)) {
        case LUA_TNUMBER:
            out->type  = XRECORD_V_NUM;
            out->v.num = lua_tonumber(L, idx);
            return 1;
        case LUA_TBOOLEAN:
            out->type = XRECORD_V_BOOL;
            out->v.b  = lua_toboolean(L, idx);
            return 1;
        case LUA_TSTRING: {
            size_t len;
            const char *str = lua_tolstring(L, idx, &len);
            out->type      = XRECORD_V_STR;
            out->v.str.ptr = str;
            out->v.str.len = len;
            return 1;
        }
        default:
            return 0;
    }
}

static void push_value(lua_State *L, const xrecord_value *v) {
    switch (v->type) {
        case XRECORD_V_NUM:  lua_pushnumber(L, v->v.num); break;
        case XRECORD_V_BOOL: lua_pushboolean(L, v->v.b); break;
        case XRECORD_V_STR:
            if (v->v.str.len == 0) lua_pushliteral(L, "");
            else                   lua_pushlstring(L, v->v.str.ptr, v->v.str.len);
            break;
        default: lua_pushnil(L); break;
    }
}

static bool parse_type(const char *s, xrecord_type *out) {
    if (strcmp(s, "int") == 0)    { *out = XRECORD_INT;    return true; }
    if (strcmp(s, "int8") == 0)   { *out = XRECORD_INT8;   return true; }
    if (strcmp(s, "int16") == 0)  { *out = XRECORD_INT16;  return true; }
    if (strcmp(s, "int32") == 0)  { *out = XRECORD_INT32;  return true; }
    if (strcmp(s, "float") == 0)  { *out = XRECORD_FLOAT;  return true; }
    if (strcmp(s, "bool") == 0)   { *out = XRECORD_BOOL;   return true; }
    if (strcmp(s, "string") == 0) { *out = XRECORD_STRING; return true; }
    return false;
}

/* xrecord.create({ {name=,type=}, ... }, capacity) -> handle */
static int l_xrecord_create(lua_State *L) {
    luaL_checktype(L, 1, LUA_TTABLE);
    lua_Integer capacity = luaL_checkinteger(L, 2);
    if (capacity <= 0)
        return luaL_error(L, "xrecord.create: capacity must be > 0");

    lua_Integer n = (lua_Integer)lua_rawlen(L, 1);
    if (n <= 0)
        return luaL_error(L, "xrecord.create: field list is empty");
    if (n > XRECORD_MAX_FIELDS)
        return luaL_error(L, "xrecord.create: too many fields (max %d)", XRECORD_MAX_FIELDS);

    /* Copied into plain C memory (not left as borrowed Lua-stack pointers)
    ** so nothing here depends on GC rooting across the loop. */
    char name_buf[XRECORD_MAX_FIELDS][XRECORD_MAX_NAME_LEN + 1];
    xrecord_field_def defs[XRECORD_MAX_FIELDS];

    for (lua_Integer i = 0; i < n; i++) {
        lua_rawgeti(L, 1, i + 1);
        if (!lua_istable(L, -1))
            return luaL_error(L, "xrecord.create: field #%d is not a table", (int)(i + 1));

        lua_getfield(L, -1, "name");
        const char *name = luaL_checkstring(L, -1);
        if (strlen(name) > XRECORD_MAX_NAME_LEN)
            return luaL_error(L, "xrecord.create: field name '%s' too long", name);
        strcpy(name_buf[i], name);

        lua_getfield(L, -2, "type");
        const char *type_str = luaL_checkstring(L, -1);
        xrecord_type type;
        if (!parse_type(type_str, &type))
            return luaL_error(L, "xrecord.create: field '%s' has unknown type '%s'", name, type_str);

        lua_pop(L, 3); /* type, name, field table */

        defs[i].name = name_buf[i];
        defs[i].type = type;
    }

    xrecord_t *s = xrecord_create(defs, (int)n, (size_t)capacity);
    if (!s)
        return luaL_error(L, "xrecord.create: failed (duplicate field name or OOM)");

    push_record(L, s);
    return 1;
}

static int l_record_gc(lua_State *L) {
    LuaRecord *u = check_record(L, 1);
    if (u->s) { xrecord_destroy(u->s); u->s = NULL; }
    return 0;
}

static int l_record_bind(lua_State *L) {
    LuaRecord *u = check_record(L, 1);
    lua_Integer id = luaL_checkinteger(L, 2);
    xrecord_status st = xrecord_bind(u->s, (int64_t)id);
    if (st == XRECORD_OK) { lua_pushboolean(L, 1); return 1; }
    if (st == XRECORD_EXISTS || st == XRECORD_FULL) {
        lua_pushboolean(L, 0);
        lua_pushstring(L, status_msg(st));
        return 2;
    }
    return luaL_error(L, "xrecord.bind: %s", status_msg(st));
}

static int l_record_unbind(lua_State *L) {
    LuaRecord *u = check_record(L, 1);
    lua_Integer id = luaL_checkinteger(L, 2);
    xrecord_status st = xrecord_unbind(u->s, (int64_t)id);
    if (st == XRECORD_OK) { lua_pushboolean(L, 1); return 1; }
    if (st == XRECORD_NOTFOUND) {
        lua_pushboolean(L, 0);
        lua_pushstring(L, status_msg(st));
        return 2;
    }
    return luaL_error(L, "xrecord.unbind: %s", status_msg(st));
}

static int l_record_has(lua_State *L) {
    LuaRecord *u = check_record(L, 1);
    lua_Integer id = luaL_checkinteger(L, 2);
    lua_pushboolean(L, xrecord_has(u->s, (int64_t)id));
    return 1;
}

static int l_record_set(lua_State *L) {
    LuaRecord *u = check_record(L, 1);
    lua_Integer id = luaL_checkinteger(L, 2);
    const char *field = luaL_checkstring(L, 3);
    luaL_checkany(L, 4);

    xrecord_value val;
    if (!to_value(L, 4, &val))
        return luaL_error(L, "xrecord.set: unsupported value type '%s'", luaL_typename(L, 4));

    xrecord_status st = xrecord_set(u->s, (int64_t)id, field, &val);
    if (st == XRECORD_OK) { lua_pushboolean(L, 1); return 1; }
    if (st == XRECORD_NOTFOUND) {
        lua_pushboolean(L, 0);
        lua_pushstring(L, status_msg(st));
        return 2;
    }
    return luaL_error(L, "xrecord.set: %s", status_msg(st));
}

static int l_record_get(lua_State *L) {
    LuaRecord *u = check_record(L, 1);
    lua_Integer id = luaL_checkinteger(L, 2);
    const char *field = luaL_checkstring(L, 3);

    xrecord_value val;
    xrecord_status st = xrecord_get(u->s, (int64_t)id, field, &val);
    if (st == XRECORD_OK) { push_value(L, &val); return 1; }
    if (st == XRECORD_NOTFOUND) {
        lua_pushnil(L);
        lua_pushstring(L, status_msg(st));
        return 2;
    }
    return luaL_error(L, "xrecord.get: %s", status_msg(st));
}

static const luaL_Reg k_record_methods[] = {
    { "bind",   l_record_bind   },
    { "unbind", l_record_unbind },
    { "has",    l_record_has    },
    { "set",    l_record_set    },
    { "get",    l_record_get    },
    { NULL, NULL }
};

static const luaL_Reg k_xrecord_funcs[] = {
    { "create", l_xrecord_create },
    { NULL, NULL }
};

LUALIB_API int luaopen_xrecord(lua_State *L) {
    luaL_newmetatable(L, LUA_XRECORD_META);
    lua_pushvalue(L, -1);
    lua_setfield(L, -2, "__index");
    luaL_setfuncs(L, k_record_methods, 0);
    lua_pushcfunction(L, l_record_gc);
    lua_setfield(L, -2, "__gc");
    lua_pop(L, 1);

    luaL_newlib(L, k_xrecord_funcs);
    return 1;
}
