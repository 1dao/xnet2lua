/* Lua 5.2-5.4 C API used by xlua modules, mapped onto LuaJIT (Lua 5.1 ABI).
 * Include after lua.h/lauxlib.h; a no-op for the embedded Lua 5.5 build. */
#ifndef XLUA_COMPAT_H
#define XLUA_COMPAT_H

#include <limits.h>

#if defined(LUA_VERSION_NUM) && LUA_VERSION_NUM < 502

/* Raw length only: LuaJIT without LUA52COMPAT ignores __len here. */
#define lua_rawlen(L, i)            lua_objlen((L), (i))
static inline lua_Integer luaL_len(lua_State *L, int i) {
    return (lua_Integer)lua_objlen(L, i);
}

#define lua_pushglobaltable(L)      lua_pushvalue((L), LUA_GLOBALSINDEX)

/* LuaJIT numbers are doubles: integral values count as integers. */
static inline int lua_isinteger(lua_State *L, int idx) {
    /* Range check first: casting NaN or an out-of-range double is undefined. */
    const lua_Number lim = sizeof(lua_Integer) >= 8 ? 9223372036854775808.0 : 2147483648.0;
    lua_Number n;
    if (lua_type(L, idx) != LUA_TNUMBER) return 0;
    n = lua_tonumber(L, idx);
    return n >= -lim && n < lim && (lua_Number)(lua_Integer)n == n;
}

static inline void lua_geti(lua_State *L, int idx, lua_Integer n) {
    idx = idx < 0 && idx > LUA_REGISTRYINDEX ? lua_gettop(L) + idx + 1 : idx;
    lua_pushinteger(L, n); lua_gettable(L, idx);
}
static inline void lua_seti(lua_State *L, int idx, lua_Integer n) {
    idx = idx < 0 && idx > LUA_REGISTRYINDEX ? lua_gettop(L) + idx + 1 : idx;
    lua_pushinteger(L, n); lua_insert(L, -2); lua_settable(L, idx);
}

/* User values: LuaJIT keeps one environment table per userdata, so slot n
 * lives at env[n]. Only setting is needed by current modules. */
#define lua_newuserdatauv(L, sz, nuv) lua_newuserdata((L), (sz))
static inline int lua_setiuservalue(lua_State *L, int idx, int n) {
    idx = idx < 0 && idx > LUA_REGISTRYINDEX ? lua_gettop(L) + idx + 1 : idx;
    lua_createtable(L, n, 0);
    lua_insert(L, -2);
    lua_rawseti(L, -2, n);
    return lua_setfenv(L, idx);
}

/* Sized buffers: 5.1 buffers only hand out LUAL_BUFFERSIZE chunks, so the
 * contiguous block is a scratch userdata kept on the stack until the result. */
static inline char *xlua_buffinitsize(lua_State *L, luaL_Buffer *B, size_t sz) {
    luaL_buffinit(L, B);
    return (char *)lua_newuserdata(L, sz ? sz : 1);
}
static inline void xlua_pushresultsize(luaL_Buffer *B, size_t sz) {
    lua_State *L = B->L;
    lua_pushlstring(L, (const char *)lua_touserdata(L, -1), sz);
    lua_remove(L, -2);
}
#define luaL_buffinitsize(L, B, sz) xlua_buffinitsize((L), (B), (sz))
#define luaL_pushresultsize(B, sz)  xlua_pushresultsize((B), (sz))

/* Lua 5.3+ utf8 library (xlua/lua_xutils.c); the runtime registers it on
 * every state it creates. */
int xlua_open_utf8(lua_State *L);

/* 5.1 has no LUA_RIDX_MAINTHREAD, so the runtime records each state's main
 * thread under a string key (integer slots belong to luaL_ref). Timers and
 * connections armed inside a coroutine must call back on this thread, never
 * on the coroutine, which may be collected first. */
#define XLUA_MAINTHREAD_KEY "xlua.mainthread"
static inline void xlua_set_mainthread(lua_State *L) {
    lua_pushthread(L);
    lua_setfield(L, LUA_REGISTRYINDEX, XLUA_MAINTHREAD_KEY);
}

static inline const char *luaL_tolstring(lua_State *L, int idx, size_t *len) {
    idx = idx < 0 && idx > LUA_REGISTRYINDEX ? lua_gettop(L) + idx + 1 : idx;
    if (luaL_callmeta(L, idx, "__tostring")) {
        if (!lua_isstring(L, -1)) luaL_error(L, "'__tostring' must return a string");
    } else {
        switch (lua_type(L, idx)) {
        case LUA_TNUMBER: case LUA_TSTRING: lua_pushvalue(L, idx); break;
        case LUA_TBOOLEAN: lua_pushstring(L, lua_toboolean(L, idx) ? "true" : "false"); break;
        case LUA_TNIL: lua_pushliteral(L, "nil"); break;
        default: lua_pushfstring(L, "%s: %p", luaL_typename(L, idx), lua_topointer(L, idx)); break;
        }
    }
    return lua_tolstring(L, -1, len);
}

#endif
#endif
