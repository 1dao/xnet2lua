#ifndef LUA_XNET_TLS_H
#define LUA_XNET_TLS_H

#ifndef XNET_WITH_HTTPS
#define XNET_WITH_HTTPS 0
#endif

#if XNET_WITH_HTTPS

#if defined(LUA_EMBEDDED)
#include "../3rd/minilua.h"
#else
#include "lua.h"
#endif

int l_xnet_attach_tls(lua_State* L);
void lua_xnet_tls_register(lua_State* L);

#endif /* XNET_WITH_HTTPS */

#endif /* LUA_XNET_TLS_H */