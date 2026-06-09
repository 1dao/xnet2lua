/* lua_xshared.c -- Lua bindings for xshared (process-global scalar dicts).
**
** A dict is shared C memory owned by the process registry, NOT by any Lua
** state. Create dicts from the MAIN thread at boot:
**
**   xshared.create('login_guard', 8 * 1024 * 1024, 16)   -- name, bytes, shards
**
** Then, in any thread (main or worker), resolve and use them:
**
**   local guard = xshared.dict('login_guard')
**   local n = guard:incr('ip:' .. ip, 1, 0, 60000)        -- +1, init 0, 60s ttl
**   if n > 10 then conn:close() end
**
** The Lua handle is a thin userdata over the C pointer; it carries no __gc
** (the registry owns the lifetime, freed once at process shutdown).
**
** Methods: get/set/add/replace/delete/incr/expire/ttl/stats. Values are
** scalars: number / boolean / string. Expiry reclamation is the runtime's job
** (xshared_tick on the main thread), so no flush_* is exposed here.
*/

#include <stdint.h>
#include <string.h>

#if defined(LUA_EMBEDDED)
#include "../3rd/minilua.h"
#else
#include "lua.h"
#include "lauxlib.h"
#endif

#include "../xshared.h"

#define LUA_XSHARED_DICT_META "xshared.dict"

typedef struct { xshared_dict_t *d; } LuaDict;

static LuaDict *check_dict(lua_State *L, int idx) {
    return (LuaDict *)luaL_checkudata(L, idx, LUA_XSHARED_DICT_META);
}

static void push_dict(lua_State *L, xshared_dict_t *d) {
    LuaDict *u = (LuaDict *)lua_newuserdata(L, sizeof(LuaDict));
    u->d = d;
    luaL_setmetatable(L, LUA_XSHARED_DICT_META);
}

/* Lua value -> xshared_value (string ptr is borrowed from the Lua stack). */
static int to_value(lua_State *L, int idx, xshared_value *out) {
    switch (lua_type(L, idx)) {
        case LUA_TNUMBER:
            out->type  = XSHARED_NUM;
            out->v.num = lua_tonumber(L, idx);
            return 1;
        case LUA_TBOOLEAN:
            out->type      = XSHARED_BOOL;
            out->v.boolean = lua_toboolean(L, idx);
            return 1;
        case LUA_TSTRING: {
            size_t len;
            const char *s = lua_tolstring(L, idx, &len);
            out->type      = XSHARED_STR;
            out->v.str.ptr = s;
            out->v.str.len = len;
            return 1;
        }
        default:
            return 0;
    }
}

static void push_value(lua_State *L, const xshared_value *v) {
    switch (v->type) {
        case XSHARED_NUM:  lua_pushnumber(L, v->v.num); break;
        case XSHARED_BOOL: lua_pushboolean(L, v->v.boolean); break;
        case XSHARED_STR:  lua_pushlstring(L, v->v.str.ptr, v->v.str.len); break;
        default:           lua_pushnil(L); break;
    }
}

/* d:get(key) -> value | nil */
static int l_get(lua_State *L) {
    LuaDict *h = check_dict(L, 1);
    size_t klen;
    const char *key = luaL_checklstring(L, 2, &klen);

    xshared_value v;
    int rc = xshared_get(h->d, key, klen, &v);
    if (rc == XSHARED_NOTFOUND) { lua_pushnil(L); return 1; }
    if (rc != XSHARED_OK) return luaL_error(L, "xshared:get failed (%d)", rc);

    push_value(L, &v);
    xshared_value_dispose(&v);
    return 1;
}

/* shared body for set / add / replace */
static int set_like(lua_State *L,
                    xshared_status (*fn)(xshared_dict_t *, const char *, size_t,
                                         const xshared_value *, int64_t),
                    const char *what, int soft_miss_status) {
    LuaDict *h = check_dict(L, 1);
    size_t klen;
    const char *key = luaL_checklstring(L, 2, &klen);
    xshared_value v;
    if (!to_value(L, 3, &v))
        return luaL_error(L, "xshared:%s value must be number/boolean/string", what);
    int64_t ttl = (int64_t)luaL_optinteger(L, 4, 0);

    int rc = fn(h->d, key, klen, &v, ttl);
    if (rc == XSHARED_OK) { lua_pushboolean(L, 1); return 1; }
    if (rc == soft_miss_status) {                       /* add->EXISTS, replace->NOTFOUND */
        lua_pushnil(L);
        lua_pushstring(L, rc == XSHARED_EXISTS ? "exists" : "notfound");
        return 2;
    }
    if (rc == XSHARED_TOOBIG)
        return luaL_error(L, "xshared:%s value exceeds shard budget", what);
    return luaL_error(L, "xshared:%s failed (%d)", what, rc);
}

static int l_set(lua_State *L)     { return set_like(L, xshared_set,     "set",     -1); }
static int l_add(lua_State *L)     { return set_like(L, xshared_add,     "add",     XSHARED_EXISTS); }
static int l_replace(lua_State *L) { return set_like(L, xshared_replace, "replace", XSHARED_NOTFOUND); }

/* d:incr(key [, delta=1 [, init=0 [, init_ttl_ms=0]]]) -> new | nil,"not a number" */
static int l_incr(lua_State *L) {
    LuaDict *h = check_dict(L, 1);
    size_t klen;
    const char *key = luaL_checklstring(L, 2, &klen);
    double  delta = luaL_optnumber(L, 3, 1);
    double  init  = luaL_optnumber(L, 4, 0);
    int64_t ttl   = (int64_t)luaL_optinteger(L, 5, 0);

    double out;
    int rc = xshared_incr(h->d, key, klen, delta, init, ttl, &out);
    if (rc == XSHARED_OK) { lua_pushnumber(L, out); return 1; }
    if (rc == XSHARED_NOTNUM) {
        lua_pushnil(L);
        lua_pushstring(L, "not a number");
        return 2;
    }
    if (rc == XSHARED_TOOBIG)
        return luaL_error(L, "xshared:incr value exceeds shard budget");
    return luaL_error(L, "xshared:incr failed (%d)", rc);
}

/* d:delete(key) -> true|false */
static int l_delete(lua_State *L) {
    LuaDict *h = check_dict(L, 1);
    size_t klen;
    const char *key = luaL_checklstring(L, 2, &klen);
    int rc = xshared_delete(h->d, key, klen);
    lua_pushboolean(L, rc == XSHARED_OK);
    return 1;
}

/* d:expire(key, ttl_ms) -> true | nil,"notfound" */
static int l_expire(lua_State *L) {
    LuaDict *h = check_dict(L, 1);
    size_t klen;
    const char *key = luaL_checklstring(L, 2, &klen);
    int64_t ttl = (int64_t)luaL_checkinteger(L, 3);
    int rc = xshared_expire(h->d, key, klen, ttl);
    if (rc == XSHARED_OK) { lua_pushboolean(L, 1); return 1; }
    if (rc == XSHARED_NOTFOUND) { lua_pushnil(L); lua_pushstring(L, "notfound"); return 2; }
    return luaL_error(L, "xshared:expire failed (%d)", rc);
}

/* d:ttl(key) -> ms (-1 = persistent) | nil */
static int l_ttl(lua_State *L) {
    LuaDict *h = check_dict(L, 1);
    size_t klen;
    const char *key = luaL_checklstring(L, 2, &klen);
    int64_t ms;
    int rc = xshared_ttl(h->d, key, klen, &ms);
    if (rc == XSHARED_NOTFOUND) { lua_pushnil(L); return 1; }
    if (rc != XSHARED_OK) return luaL_error(L, "xshared:ttl failed (%d)", rc);
    lua_pushinteger(L, (lua_Integer)ms);
    return 1;
}

/* d:stats() -> { capacity, used, items, evicted, expired, shards } */
static int l_stats(lua_State *L) {
    LuaDict *h = check_dict(L, 1);
    xshared_stats_t st;
    xshared_stats(h->d, &st);
    lua_createtable(L, 0, 6);
    lua_pushinteger(L, (lua_Integer)st.capacity_bytes); lua_setfield(L, -2, "capacity");
    lua_pushinteger(L, (lua_Integer)st.used_bytes);     lua_setfield(L, -2, "used");
    lua_pushinteger(L, (lua_Integer)st.item_count);     lua_setfield(L, -2, "items");
    lua_pushinteger(L, (lua_Integer)st.evicted);        lua_setfield(L, -2, "evicted");
    lua_pushinteger(L, (lua_Integer)st.expired);        lua_setfield(L, -2, "expired");
    lua_pushinteger(L, (lua_Integer)st.nshards);        lua_setfield(L, -2, "shards");
    return 1;
}

/* xshared.create(name [, size_bytes=1MB [, nshards=8]]) -> dict
** Idempotent at boot: a second create of the same name returns the existing
** dict (so re-running a main script does not error). */
static int l_create(lua_State *L) {
    const char *name = luaL_checkstring(L, 1);
    lua_Integer size    = luaL_optinteger(L, 2, 1024 * 1024);
    lua_Integer nshards = luaL_optinteger(L, 3, 8);
    if (size <= 0)    return luaL_error(L, "xshared.create: size must be > 0");
    if (nshards <= 0) nshards = 8;

    xshared_dict_t *d = xshared_create(name, (size_t)size, (uint32_t)nshards);
    if (!d) {
        d = xshared_get_dict(name);                 /* already existed */
        if (!d) return luaL_error(L, "xshared.create('%s') failed", name);
    }
    push_dict(L, d);
    return 1;
}

/* xshared.dict(name) -> dict  (errors if not created at boot) */
static int l_dict(lua_State *L) {
    const char *name = luaL_checkstring(L, 1);
    xshared_dict_t *d = xshared_get_dict(name);
    if (!d)
        return luaL_error(L,
            "xshared dict '%s' not created (call xshared.create in the main "
            "thread before workers spawn)", name);
    push_dict(L, d);
    return 1;
}

static const luaL_Reg k_dict_methods[] = {
    { "get",           l_get },
    { "set",           l_set },
    { "add",           l_add },
    { "replace",       l_replace },
    { "delete",        l_delete },
    { "incr",          l_incr },
    { "expire",        l_expire },
    { "ttl",           l_ttl },
    { "stats",         l_stats },
    { NULL, NULL }
};

static const luaL_Reg k_module[] = {
    { "create", l_create },
    { "dict",   l_dict },
    { NULL, NULL }
};

#if defined(_WIN32)
__declspec(dllexport)
#endif
int luaopen_xshared(lua_State *L) {
    luaL_newmetatable(L, LUA_XSHARED_DICT_META);
    lua_pushvalue(L, -1);
    lua_setfield(L, -2, "__index");
    luaL_setfuncs(L, k_dict_methods, 0);
    lua_pop(L, 1);

    luaL_newlib(L, k_module);
    return 1;
}
