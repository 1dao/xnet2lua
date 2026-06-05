/* lua_xnet.h - internal header shared by lua_xnet.c and lua_xnet_tls.c.
**
** Two things live here:
**   1. Small Lua-glue helpers that were previously verbatim-duplicated across
**      both translation units. They are `static inline` so each .c still gets
**      its own copy (no link-time symbol clash) while the source lives once.
**   2. The TLS entry points implemented in lua_xnet_tls.c, exposed to
**      lua_xnet.c only when XNET_WITH_HTTPS is on.
**
** Both consumers compile straight into the xnet binary, and lua_xnet_tls.c is
** wholly behind `#if XNET_WITH_HTTPS`, so including this header respects that
** guard.
*/
#ifndef LUA_XNET_H
#define LUA_XNET_H

#include <stddef.h>
#include <stdint.h>
#include <stdbool.h>

#if defined(LUA_EMBEDDED)
#include "../3rd/minilua.h"
#else
#include "lua.h"
#include "lauxlib.h"
#endif

#ifndef XNET_WITH_HTTPS
#define XNET_WITH_HTTPS 0
#endif

#ifndef lua_absindex
#define lua_absindex(L, i) \
    (((i) > 0 || (i) <= LUA_REGISTRYINDEX) ? (i) : lua_gettop(L) + (i) + 1)
#endif

/* ── Shared Lua-glue helpers ─────────────────────────────────────────────── */

/* The main thread's lua_State, where registry refs and userdata live. Falls
** back to L on Lua builds without LUA_RIDX_MAINTHREAD. */
static inline lua_State* main_lua_state(lua_State* L) {
#ifdef LUA_RIDX_MAINTHREAD
    lua_rawgeti(L, LUA_REGISTRYINDEX, LUA_RIDX_MAINTHREAD);
    lua_State* mainL = lua_tothread(L, -1);
    lua_pop(L, 1);
    return mainL ? mainL : L;
#else
    return L;
#endif
}

static inline void ref_unref(lua_State* L, int* ref) {
    if (*ref != LUA_NOREF && *ref != LUA_REFNIL) {
        luaL_unref(L, LUA_REGISTRYINDEX, *ref);
    }
    *ref = LUA_NOREF;
}

static inline void ref_from_stack(lua_State* L, int idx, int* ref) {
    idx = lua_absindex(L, idx);
    ref_unref(L, ref);
    lua_pushvalue(L, idx);
    *ref = luaL_ref(L, LUA_REGISTRYINDEX);
}

/* Resolve the handler table held by handler_ref and push the first of
** name1/name2/name3 that is a function. Leaves that function on the stack and
** returns true; on any miss restores the stack and returns false. */
static inline bool push_handler(lua_State* L, int handler_ref,
                                const char* name1,
                                const char* name2,
                                const char* name3) {
    if (handler_ref == LUA_NOREF || handler_ref == LUA_REFNIL) return false;

    int base = lua_gettop(L);
    lua_rawgeti(L, LUA_REGISTRYINDEX, handler_ref);
    if (!lua_istable(L, -1)) {
        lua_settop(L, base);
        return false;
    }

    lua_getfield(L, -1, name1);
    if (!lua_isfunction(L, -1) && name2) {
        lua_pop(L, 1);
        lua_getfield(L, -1, name2);
    }
    if (!lua_isfunction(L, -1) && name3) {
        lua_pop(L, 1);
        lua_getfield(L, -1, name3);
    }
    if (!lua_isfunction(L, -1)) {
        lua_settop(L, base);
        return false;
    }

    lua_remove(L, -2);
    return true;
}

/* Interpret a packet handler's "bytes consumed" return value at stack idx.
** Non-number / <= 0 means "consumed nothing"; a value past max_len is clamped
** to max_len + 1 (or SIZE_MAX) so callers can detect the over-consume case. */
static inline size_t packet_consumed_return(lua_State* L, int idx, size_t max_len) {
    if (lua_type(L, idx) != LUA_TNUMBER) return 0;
    lua_Number n = lua_tonumber(L, idx);
    if (n <= 0) return 0;
    if (n > (lua_Number)max_len) return max_len == SIZE_MAX ? SIZE_MAX : max_len + 1;
    return (size_t)n;
}

/* ── TLS entry points (implemented in lua_xnet_tls.c) ────────────────────── */
#if XNET_WITH_HTTPS
int l_xnet_attach_tls(lua_State* L);
int l_xnet_connect_tls(lua_State* L);
void lua_xnet_tls_register(lua_State* L);
#endif

#endif /* LUA_XNET_H */
