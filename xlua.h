// lua_xthread.h
#ifndef _LUA_XTHREAD_H
#define _LUA_XTHREAD_H

#if defined(LUA_EMBEDDED)
#include "3rd/minilua.h"
#else
#include "lua.h"
#include "lauxlib.h"
#endif

#ifdef __cplusplus
extern "C" {
#endif

/** Lua module initialization. Called via require("xthread"). */
LUALIB_API int luaopen_xthread(lua_State *L);

/** Lua module initialization. Called via require("cmsgpack"). */
LUALIB_API int luaopen_cmsgpack(lua_State *L);

#ifdef __cplusplus
}
#endif
#endif /* _LUA_XTHREAD_H */
