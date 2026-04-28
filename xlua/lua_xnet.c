/* lua_xnet.c - Lua binding layer for xnet.
**
** xpoll owns readiness. xchannel owns connection buffering and the three
** built-in stream protocols: raw, len32 and crlf.
*/

#include <stdlib.h>
#include <string.h>
#include <stdbool.h>
#include <stdint.h>

#if defined(LUA_EMBEDDED)
#include "../3rd/minilua.h"
#else
#include "lua.h"
#include "lauxlib.h"
#endif

#include "xchannel.h"
#include "xpoll.h"
#include "xthread.h"
#include "xargs.h"
#include "xlog.h"

#ifndef lua_absindex
#define lua_absindex(L, i) \
    (((i) > 0 || (i) <= LUA_REGISTRYINDEX) ? (i) : lua_gettop(L) + (i) + 1)
#endif

#define LUA_XNET_CONN_META     "xnet.connection"
#define LUA_XNET_LISTENER_META "xnet.listener"

typedef struct LuaNetConn {
    lua_State* L;
    xChannel* ch;
    int self_ref;
    int handler_ref;
    bool closed;
    char peer_ip[64];
    int peer_port;
} LuaNetConn;

typedef struct LuaNetListener {
    lua_State* L;
    SOCKET_T fd;
    int self_ref;
    int handler_ref;
    bool closed;
} LuaNetListener;

static int g_socket_started = 0;

static void listener_accept_cb(SOCKET_T fd, int mask, void* clientData);
static void listener_accept_fd_cb(SOCKET_T fd, int mask, void* clientData);
static void listener_error_cb(SOCKET_T fd, int mask, void* clientData);

static LuaNetConn* check_conn(lua_State* L, int idx) {
    return (LuaNetConn*)luaL_checkudata(L, idx, LUA_XNET_CONN_META);
}

static LuaNetListener* check_listener(lua_State* L, int idx) {
    return (LuaNetListener*)luaL_checkudata(L, idx, LUA_XNET_LISTENER_META);
}

static void ref_unref(lua_State* L, int* ref) {
    if (*ref != LUA_NOREF && *ref != LUA_REFNIL) {
        luaL_unref(L, LUA_REGISTRYINDEX, *ref);
    }
    *ref = LUA_NOREF;
}

static void ref_from_stack(lua_State* L, int idx, int* ref) {
    idx = lua_absindex(L, idx);
    ref_unref(L, ref);
    lua_pushvalue(L, idx);
    *ref = luaL_ref(L, LUA_REGISTRYINDEX);
}

static void push_conn_self(lua_State* L, LuaNetConn* c) {
    if (!c || c->self_ref == LUA_NOREF || c->self_ref == LUA_REFNIL)
        lua_pushnil(L);
    else
        lua_rawgeti(L, LUA_REGISTRYINDEX, c->self_ref);
}

static void push_listener_self(lua_State* L, LuaNetListener* s) {
    if (!s || s->self_ref == LUA_NOREF || s->self_ref == LUA_REFNIL)
        lua_pushnil(L);
    else
        lua_rawgeti(L, LUA_REGISTRYINDEX, s->self_ref);
}

static bool push_handler(lua_State* L, int handler_ref,
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

static void conn_unref_lua(LuaNetConn* c) {
    if (!c || !c->L) return;
    ref_unref(c->L, &c->handler_ref);
    ref_unref(c->L, &c->self_ref);
}

static void conn_destroy_channel(LuaNetConn* c) {
    if (!c || !c->ch) return;
    xChannel* ch = c->ch;
    c->ch = NULL;
    xchannel_set_userdata(ch, NULL);
    xchannel_destroy(ch);
}

static int conn_send_packet_c(LuaNetConn* c, const char* data, size_t len) {
    if (!c || !c->ch || c->closed) return -1;
    return xchannel_send_packet(c->ch, data, len);
}

static size_t packet_consumed_return(lua_State* L, int idx, size_t max_len) {
    if (lua_type(L, idx) != LUA_TNUMBER) return 0;
    lua_Number n = lua_tonumber(L, idx);
    if (n <= 0) return 0;
    if (n > (lua_Number)max_len) return max_len == SIZE_MAX ? SIZE_MAX : max_len + 1;
    return (size_t)n;
}

static void handle_packet_returns(LuaNetConn* c, int first, int last) {
    lua_State* L = c->L;
    for (int i = first; i <= last && !c->closed; i++) {
        if (lua_type(L, i) != LUA_TSTRING) continue;
        size_t len = 0;
        const char* data = lua_tolstring(L, i, &len);
        conn_send_packet_c(c, data, len);
    }
}

static void lua_conn_connect_cb(xChannel* ch, void* ud) {
    (void)ch;
    LuaNetConn* c = (LuaNetConn*)ud;
    if (!c || c->closed) return;

    lua_State* L = c->L;
    int base = lua_gettop(L);
    push_conn_self(L, c);

    if (push_handler(L, c->handler_ref, "on_connect", "connect", NULL)) {
        push_conn_self(L, c);
        if (c->peer_ip[0]) lua_pushstring(L, c->peer_ip);
        else lua_pushnil(L);
        if (c->peer_port > 0) lua_pushinteger(L, c->peer_port);
        else lua_pushnil(L);

        if (lua_pcall(L, 3, LUA_MULTRET, 0) != LUA_OK) {
            XLOGE("xnet: on_connect error: %s", lua_tostring(L, -1));
            lua_settop(L, base);
            if (c->ch) xchannel_close(c->ch, "handler_error");
            return;
        }

        if (lua_gettop(L) >= base + 2 && lua_istable(L, base + 2)) {
            ref_from_stack(L, base + 2, &c->handler_ref);
        }
    }

    lua_settop(L, base);
}

static size_t lua_conn_packet_cb(xChannel* ch, const char* data, size_t len, void* ud) {
    (void)ch;
    LuaNetConn* c = (LuaNetConn*)ud;
    if (!c || c->closed) return 0;

    lua_State* L = c->L;
    int base = lua_gettop(L);
    push_conn_self(L, c);

    if (!push_handler(L, c->handler_ref, "on_packet", "on_message", "on_recv")) {
        lua_settop(L, base);
        return 0;
    }

    push_conn_self(L, c);
    lua_pushlstring(L, data, len);
    if (lua_pcall(L, 2, LUA_MULTRET, 0) != LUA_OK) {
        XLOGE("xnet: on_packet error: %s", lua_tostring(L, -1));
        lua_settop(L, base);
        if (c->ch) xchannel_close(c->ch, "handler_error");
        return 0;
    }

    int first_ret = base + 2;
    int last_ret = lua_gettop(L);
    size_t consumed = (first_ret <= last_ret)
        ? packet_consumed_return(L, first_ret, len)
        : 0;
    handle_packet_returns(c, first_ret, last_ret);
    lua_settop(L, base);
    return consumed;
}

static void lua_conn_close_cb(xChannel* ch, const char* reason, void* ud) {
    LuaNetConn* c = (LuaNetConn*)ud;
    if (!c) return;

    lua_State* L = c->L;
    int base = lua_gettop(L);
    push_conn_self(L, c);

    if (!c->closed && push_handler(L, c->handler_ref, "on_close", "on_disconnect", NULL)) {
        push_conn_self(L, c);
        lua_pushstring(L, reason ? reason : "closed");
        if (lua_pcall(L, 2, 0, 0) != LUA_OK) {
            XLOGE("xnet: on_close error: %s", lua_tostring(L, -1));
        }
    }

    c->closed = true;
    if (c->ch == ch) {
        xchannel_set_userdata(ch, NULL);
        c->ch = NULL;
    }
    conn_unref_lua(c);
    lua_settop(L, base);
}

static const xChannelConfig s_lua_conn_cfg = {
    .connect_cb = lua_conn_connect_cb,
    .packet_cb  = lua_conn_packet_cb,
    .close_cb   = lua_conn_close_cb,
};

static LuaNetConn* push_conn(lua_State* L, xChannel* ch,
                              int handler_ref,
                              const char* ip, int port) {
    LuaNetConn* c = (LuaNetConn*)lua_newuserdata(L, sizeof(*c));
    memset(c, 0, sizeof(*c));
    c->L = L;
    c->ch = ch;
    c->self_ref = LUA_NOREF;
    c->handler_ref = LUA_NOREF;
    c->closed = false;
    if (ip) {
        strncpy(c->peer_ip, ip, sizeof(c->peer_ip) - 1);
        c->peer_ip[sizeof(c->peer_ip) - 1] = '\0';
    }
    c->peer_port = port;

    luaL_getmetatable(L, LUA_XNET_CONN_META);
    lua_setmetatable(L, -2);

    if (handler_ref != LUA_NOREF && handler_ref != LUA_REFNIL) {
        lua_rawgeti(L, LUA_REGISTRYINDEX, handler_ref);
        c->handler_ref = luaL_ref(L, LUA_REGISTRYINDEX);
    }

    lua_pushvalue(L, -1);
    c->self_ref = luaL_ref(L, LUA_REGISTRYINDEX);
    xchannel_set_userdata(c->ch, c);
    return c;
}

static void listener_close_internal(LuaNetListener* s, const char* reason) {
    if (!s || s->closed) return;
    s->closed = true;
    if (s->fd != INVALID_SOCKET_VAL) {
        xpoll_del_event(s->fd, XPOLL_ALL);
        xsock_close(s->fd);
        s->fd = INVALID_SOCKET_VAL;
    }

    lua_State* L = s->L;
    int base = lua_gettop(L);
    push_listener_self(L, s);
    if (push_handler(L, s->handler_ref, "on_close", NULL, NULL)) {
        push_listener_self(L, s);
        lua_pushstring(L, reason ? reason : "closed");
        if (lua_pcall(L, 2, 0, 0) != LUA_OK) {
            XLOGE("xnet: listener on_close error: %s", lua_tostring(L, -1));
        }
    }
    ref_unref(L, &s->handler_ref);
    ref_unref(L, &s->self_ref);
    lua_settop(L, base);
}

static void listener_accept_cb(SOCKET_T fd, int mask, void* clientData) {
    (void)fd;
    (void)mask;
    LuaNetListener* s = (LuaNetListener*)clientData;
    if (!s || s->closed) return;

    lua_State* L = s->L;
    int base = lua_gettop(L);
    push_listener_self(L, s);

    while (!s->closed) {
        char err[XSOCK_ERR_LEN] = {0};
        char ip[64] = {0};
        int port = 0;
        SOCKET_T cfd = xsock_accept(err, s->fd, ip, &port);
        if (cfd == INVALID_SOCKET_VAL) {
            if (socket_check_eagain()) break;
            listener_close_internal(s, err[0] ? err : "accept_error");
            break;
        }

        if (xsock_set_nonblock(err, cfd) != XSOCK_OK) {
            xsock_close(cfd);
            continue;
        }

        xChannel* ch = xchannel_create(cfd, &s_lua_conn_cfg);
        if (!ch) {
            xsock_close(cfd);
            continue;
        }

        LuaNetConn* c = push_conn(L, ch, s->handler_ref, ip, port);
        lua_conn_connect_cb(ch, c);
        if (!c->closed && c->ch && xchannel_attach(c->ch) != 0) {
            xchannel_close(c->ch, "poll_error");
        }
        lua_pop(L, 1);
    }

    lua_settop(L, base);
}

static void listener_accept_fd_cb(SOCKET_T fd, int mask, void* clientData) {
    (void)fd;
    (void)mask;
    LuaNetListener* s = (LuaNetListener*)clientData;
    if (!s || s->closed) return;

    lua_State* L = s->L;
    int base = lua_gettop(L);
    push_listener_self(L, s);

    while (!s->closed) {
        char err[XSOCK_ERR_LEN] = {0};
        char ip[64] = {0};
        int port = 0;
        SOCKET_T cfd = xsock_accept(err, s->fd, ip, &port);
        if (cfd == INVALID_SOCKET_VAL) {
            if (socket_check_eagain()) break;
            listener_close_internal(s, err[0] ? err : "accept_error");
            break;
        }

        if (xsock_set_nonblock(err, cfd) != XSOCK_OK) {
            xsock_close(cfd);
            continue;
        }

        bool transfer = false;
        if (push_handler(L, s->handler_ref, "on_accept", "accept", "on_fd")) {
            push_listener_self(L, s);
            lua_pushinteger(L, (lua_Integer)cfd);
            if (ip[0]) lua_pushstring(L, ip);
            else lua_pushnil(L);
            if (port > 0) lua_pushinteger(L, port);
            else lua_pushnil(L);

            if (lua_pcall(L, 4, 1, 0) != LUA_OK) {
                XLOGE("xnet: on_accept error: %s", lua_tostring(L, -1));
                lua_settop(L, base);
            } else {
                transfer = !lua_isboolean(L, -1) || lua_toboolean(L, -1);
                lua_settop(L, base);
            }
        } else {
            lua_settop(L, base);
        }

        if (!transfer) {
            xsock_close(cfd);
        }
    }

    lua_settop(L, base);
}

static void listener_error_cb(SOCKET_T fd, int mask, void* clientData) {
    (void)fd;
    (void)mask;
    listener_close_internal((LuaNetListener*)clientData, "socket_error");
}

static int l_conn_fd(lua_State* L) {
    LuaNetConn* c = check_conn(L, 1);
    if (!c->ch || c->closed) lua_pushnil(L);
    else lua_pushinteger(L, (lua_Integer)xchannel_fd(c->ch));
    return 1;
}

static int l_conn_peer(lua_State* L) {
    LuaNetConn* c = check_conn(L, 1);
    if (c->peer_ip[0]) lua_pushstring(L, c->peer_ip);
    else lua_pushnil(L);
    if (c->peer_port > 0) lua_pushinteger(L, c->peer_port);
    else lua_pushnil(L);
    return 2;
}

static int l_conn_is_closed(lua_State* L) {
    LuaNetConn* c = check_conn(L, 1);
    lua_pushboolean(L, c->closed || !c->ch || xchannel_is_closed(c->ch));
    return 1;
}

static int l_conn_close(lua_State* L) {
    LuaNetConn* c = check_conn(L, 1);
    const char* reason = luaL_optstring(L, 2, "closed");
    if (c->ch && !c->closed) xchannel_close(c->ch, reason);
    lua_pushboolean(L, 1);
    return 1;
}

static int l_conn_send(lua_State* L) {
    LuaNetConn* c = check_conn(L, 1);
    size_t len = 0;
    const char* data = luaL_checklstring(L, 2, &len);
    lua_pushboolean(L, conn_send_packet_c(c, data, len) == 0);
    return 1;
}

static int l_conn_send_raw(lua_State* L) {
    LuaNetConn* c = check_conn(L, 1);
    size_t len = 0;
    const char* data = luaL_checklstring(L, 2, &len);
    lua_pushboolean(L, c->ch && !c->closed &&
                       xchannel_send_raw(c->ch, data, len) == 0);
    return 1;
}

static int l_conn_send_packet(lua_State* L) {
    return l_conn_send(L);
}

static int l_conn_set_handler(lua_State* L) {
    LuaNetConn* c = check_conn(L, 1);
    luaL_checktype(L, 2, LUA_TTABLE);
    ref_from_stack(L, 2, &c->handler_ref);
    lua_pushvalue(L, 1);
    return 1;
}

static int l_xnet_attach(lua_State* L) {
    SOCKET_T fd = (SOCKET_T)luaL_checkinteger(L, 1);
    luaL_checktype(L, 2, LUA_TTABLE);
    const char* ip = luaL_optstring(L, 3, NULL);
    int port = (int)luaL_optinteger(L, 4, 0);

    if (fd == INVALID_SOCKET_VAL) {
        lua_pushnil(L);
        lua_pushstring(L, "invalid fd");
        return 2;
    }

    char err[XSOCK_ERR_LEN] = {0};
    if (xsock_set_nonblock(err, fd) != XSOCK_OK) {
        xsock_close(fd);
        lua_pushnil(L);
        lua_pushstring(L, err[0] ? err : "set nonblock failed");
        return 2;
    }

    xChannel* ch = xchannel_create(fd, &s_lua_conn_cfg);
    if (!ch) {
        xsock_close(fd);
        lua_pushnil(L);
        lua_pushstring(L, "xchannel_create failed");
        return 2;
    }

    LuaNetConn* c = push_conn(L, ch, LUA_NOREF, ip, port);
    ref_from_stack(L, 2, &c->handler_ref);
    lua_conn_connect_cb(ch, c);
    if (!c->closed && c->ch && xchannel_attach(c->ch) != 0) {
        xchannel_close(c->ch, "poll_error");
    }
    return 1;
}

static int valid_crlf_delim(const char* delim, size_t delim_len) {
    return !delim || (delim_len == 2 && delim[0] == '\r' && delim[1] == '\n');
}

static int apply_framing(lua_State* L, LuaNetConn* c,
                         const char* mode,
                         const char* delim,
                         size_t delim_len) {
    if (!c->ch || c->closed)
        return luaL_error(L, "xnet.conn:set_framing on closed connection");

    xChannelConfig cfg = XCHANNEL_CONFIG_INIT;
    if (strcmp(mode, "raw") == 0) {
        cfg.frame = XCHANNEL_FRAME_RAW;
    } else if (strcmp(mode, "len32") == 0 || strcmp(mode, "len32be") == 0) {
        cfg.frame = XCHANNEL_FRAME_LEN32;
    } else if (strcmp(mode, "line") == 0 ||
               strcmp(mode, "crlf") == 0 ||
               strcmp(mode, "delimiter") == 0) {
        if (!valid_crlf_delim(delim, delim_len)) return -1;
        cfg.frame = XCHANNEL_FRAME_CRLF;
    } else {
        return -1;
    }
    return xchannel_set_framing(c->ch, &cfg);
}

static int l_conn_set_framing(lua_State* L) {
    LuaNetConn* c = check_conn(L, 1);
    const char* mode = NULL;
    const char* delim = NULL;
    size_t delim_len = 0;

    if (!c->ch || c->closed)
        return luaL_error(L, "xnet.conn:set_framing on closed connection");

    if (lua_istable(L, 2)) {
        int base = lua_gettop(L);

        lua_getfield(L, 2, "max_packet");
        if (lua_isnumber(L, -1)) {
            lua_Integer mp = lua_tointeger(L, -1);
            if (mp > 0) xchannel_set_max_packet(c->ch, (size_t)mp);
        }
        lua_pop(L, 1);

        lua_getfield(L, 2, "type");
        if (!lua_isstring(L, -1)) {
            lua_pop(L, 1);
            lua_getfield(L, 2, "mode");
        }
        if (lua_isnil(L, -1)) {
            lua_settop(L, base);
            lua_pushvalue(L, 1);
            return 1;
        }
        mode = luaL_checkstring(L, -1);

        lua_getfield(L, 2, "delimiter");
        if (lua_isstring(L, -1)) {
            delim = lua_tolstring(L, -1, &delim_len);
        }

        if (apply_framing(L, c, mode, delim, delim_len) != 0) {
            return luaL_error(L, "unsupported framing mode '%s'", mode);
        }
        lua_settop(L, base);
    } else {
        mode = luaL_checkstring(L, 2);
        if (lua_isstring(L, 3)) delim = lua_tolstring(L, 3, &delim_len);
        if (apply_framing(L, c, mode, delim, delim_len) != 0) {
            return luaL_error(L, "unsupported framing mode '%s'", mode);
        }
    }

    lua_pushvalue(L, 1);
    return 1;
}

static int l_conn_gc(lua_State* L) {
    LuaNetConn* c = (LuaNetConn*)luaL_checkudata(L, 1, LUA_XNET_CONN_META);
    if (c) {
        conn_destroy_channel(c);
        conn_unref_lua(c);
    }
    return 0;
}

static int l_listener_fd(lua_State* L) {
    LuaNetListener* s = check_listener(L, 1);
    if (s->closed || s->fd == INVALID_SOCKET_VAL) lua_pushnil(L);
    else lua_pushinteger(L, (lua_Integer)s->fd);
    return 1;
}

static int l_listener_close(lua_State* L) {
    LuaNetListener* s = check_listener(L, 1);
    listener_close_internal(s, luaL_optstring(L, 2, "closed"));
    lua_pushboolean(L, 1);
    return 1;
}

static int l_listener_gc(lua_State* L) {
    LuaNetListener* s = (LuaNetListener*)luaL_checkudata(L, 1, LUA_XNET_LISTENER_META);
    if (s && !s->closed) listener_close_internal(s, "gc");
    return 0;
}

static int l_xnet_init(lua_State* L) {
    if (!g_socket_started) {
        if (socket_init() != 0) {
            lua_pushboolean(L, 0);
            lua_pushstring(L, "socket_init failed");
            return 2;
        }
        g_socket_started = 1;
    }

    int rc = xpoll_init();
    if (rc != 0) {
        lua_pushboolean(L, 0);
        lua_pushfstring(L, "xpoll_init failed: %d", rc);
        return 2;
    }

    if (lua_isnumber(L, 1)) {
        int setsize = (int)lua_tointeger(L, 1);
        if (setsize > 0) xpoll_resize(setsize);
    }

    if (xthread_current()) {
        xthread_wakeup_init();
    }

    lua_pushboolean(L, 1);
    return 1;
}

static int l_xnet_uninit(lua_State* L) {
    (void)L;
    if (xthread_current()) xthread_wakeup_uninit();
    xpoll_uninit();
    if (g_socket_started) {
        socket_cleanup();
        g_socket_started = 0;
    }
    return 0;
}

static int l_xnet_poll(lua_State* L) {
    int timeout_ms = (int)luaL_optinteger(L, 1, 0);
    lua_pushinteger(L, xpoll_poll(timeout_ms));
    return 1;
}

static int l_xnet_name(lua_State* L) {
    lua_pushstring(L, xpoll_name());
    return 1;
}

static int l_xnet_listen(lua_State* L) {
    const char* host = NULL;
    int port = 0;
    int handler_idx = 0;

    if (lua_isnumber(L, 1) && !lua_isstring(L, 1)) {
        port = (int)lua_tointeger(L, 1);
        handler_idx = 2;
    } else {
        if (!lua_isnil(L, 1)) host = luaL_checkstring(L, 1);
        port = (int)luaL_checkinteger(L, 2);
        handler_idx = 3;
    }
    luaL_checktype(L, handler_idx, LUA_TTABLE);

    char err[XSOCK_ERR_LEN] = {0};
    SOCKET_T fd = xsock_listen(err, host, port);
    if (fd == INVALID_SOCKET_VAL) {
        lua_pushnil(L);
        lua_pushstring(L, err[0] ? err : "listen failed");
        return 2;
    }
    if (xsock_set_nonblock(err, fd) != XSOCK_OK) {
        xsock_close(fd);
        lua_pushnil(L);
        lua_pushstring(L, err[0] ? err : "set nonblock failed");
        return 2;
    }

    LuaNetListener* s = (LuaNetListener*)lua_newuserdata(L, sizeof(*s));
    memset(s, 0, sizeof(*s));
    s->L = L;
    s->fd = fd;
    s->self_ref = LUA_NOREF;
    s->handler_ref = LUA_NOREF;
    s->closed = false;

    luaL_getmetatable(L, LUA_XNET_LISTENER_META);
    lua_setmetatable(L, -2);

    ref_from_stack(L, handler_idx, &s->handler_ref);
    lua_pushvalue(L, -1);
    s->self_ref = luaL_ref(L, LUA_REGISTRYINDEX);

    if (xpoll_add_event(fd, XPOLL_READABLE,
                        listener_accept_cb, NULL, listener_error_cb, s) != 0) {
        listener_close_internal(s, "poll_error");
        lua_pushnil(L);
        lua_pushstring(L, "xpoll_add_event failed");
        return 2;
    }
    xpoll_set_client_data(fd, s);
    return 1;
}

static int l_xnet_listen_fd(lua_State* L) {
    const char* host = NULL;
    int port = 0;
    int handler_idx = 0;

    if (lua_isnumber(L, 1) && !lua_isstring(L, 1)) {
        port = (int)lua_tointeger(L, 1);
        handler_idx = 2;
    } else {
        if (!lua_isnil(L, 1)) host = luaL_checkstring(L, 1);
        port = (int)luaL_checkinteger(L, 2);
        handler_idx = 3;
    }
    luaL_checktype(L, handler_idx, LUA_TTABLE);

    char err[XSOCK_ERR_LEN] = {0};
    SOCKET_T fd = xsock_listen(err, host, port);
    if (fd == INVALID_SOCKET_VAL) {
        lua_pushnil(L);
        lua_pushstring(L, err[0] ? err : "listen failed");
        return 2;
    }
    if (xsock_set_nonblock(err, fd) != XSOCK_OK) {
        xsock_close(fd);
        lua_pushnil(L);
        lua_pushstring(L, err[0] ? err : "set nonblock failed");
        return 2;
    }

    LuaNetListener* s = (LuaNetListener*)lua_newuserdata(L, sizeof(*s));
    memset(s, 0, sizeof(*s));
    s->L = L;
    s->fd = fd;
    s->self_ref = LUA_NOREF;
    s->handler_ref = LUA_NOREF;
    s->closed = false;

    luaL_getmetatable(L, LUA_XNET_LISTENER_META);
    lua_setmetatable(L, -2);

    ref_from_stack(L, handler_idx, &s->handler_ref);
    lua_pushvalue(L, -1);
    s->self_ref = luaL_ref(L, LUA_REGISTRYINDEX);

    if (xpoll_add_event(fd, XPOLL_READABLE,
                        listener_accept_fd_cb, NULL, listener_error_cb, s) != 0) {
        listener_close_internal(s, "poll_error");
        lua_pushnil(L);
        lua_pushstring(L, "xpoll_add_event failed");
        return 2;
    }
    xpoll_set_client_data(fd, s);
    return 1;
}

static int l_xnet_connect(lua_State* L) {
    const char* host = luaL_checkstring(L, 1);
    int port = (int)luaL_checkinteger(L, 2);
    luaL_checktype(L, 3, LUA_TTABLE);

    char err[XSOCK_ERR_LEN] = {0};
    SOCKET_T fd = xsock_tcp_aconnect(err, host, port);
    if (fd == INVALID_SOCKET_VAL) {
        lua_pushnil(L);
        lua_pushstring(L, err[0] ? err : "connect failed");
        return 2;
    }

    xChannel* ch = xchannel_create(fd, &s_lua_conn_cfg);
    if (!ch) {
        xsock_close(fd);
        lua_pushnil(L);
        lua_pushstring(L, "xchannel_create failed");
        return 2;
    }

    LuaNetConn* c = push_conn(L, ch, LUA_NOREF, host, port);
    ref_from_stack(L, 3, &c->handler_ref);
    if (xchannel_attach_connect(ch) != 0) {
        conn_destroy_channel(c);
        conn_unref_lua(c);
        lua_pushnil(L);
        lua_pushstring(L, "xchannel_attach_connect failed");
        return 2;
    }
    return 1;
}

static int l_xnet_load_config(lua_State* L) {
    const char* path = luaL_checkstring(L, 1);
    if (xargs_load_config(path) != 0) {
        lua_pushboolean(L, 0);
        lua_pushfstring(L, "load config failed: %s", path);
        return 2;
    }
    lua_pushboolean(L, 1);
    return 1;
}

static int l_xnet_get_config(lua_State* L) {
    const char* key = luaL_checkstring(L, 1);
    const char* value = xargs_get(key);
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

static const luaL_Reg conn_methods[] = {
    { "fd",          l_conn_fd },
    { "peer",        l_conn_peer },
    { "is_closed",   l_conn_is_closed },
    { "close",       l_conn_close },
    { "send",        l_conn_send },
    { "send_raw",    l_conn_send_raw },
    { "send_packet", l_conn_send_packet },
    { "set_handler", l_conn_set_handler },
    { "set_framing", l_conn_set_framing },
    { NULL, NULL }
};

static const luaL_Reg listener_methods[] = {
    { "fd",    l_listener_fd },
    { "close", l_listener_close },
    { NULL, NULL }
};

static const luaL_Reg xnet_funcs[] = {
    { "init",    l_xnet_init },
    { "uninit",  l_xnet_uninit },
    { "poll",    l_xnet_poll },
    { "name",    l_xnet_name },
    { "listen",  l_xnet_listen },
    { "listen_fd", l_xnet_listen_fd },
    { "connect", l_xnet_connect },
    { "attach",  l_xnet_attach },
    { "connect_fd", l_xnet_attach },
    { "load_config", l_xnet_load_config },
    { "get_config",  l_xnet_get_config },
    { NULL, NULL }
};

LUALIB_API int luaopen_xnet(lua_State* L) {
    if (luaL_newmetatable(L, LUA_XNET_CONN_META)) {
        lua_pushcfunction(L, l_conn_gc);
        lua_setfield(L, -2, "__gc");
        lua_newtable(L);
        luaL_setfuncs(L, conn_methods, 0);
        lua_setfield(L, -2, "__index");
    }
    lua_pop(L, 1);

    if (luaL_newmetatable(L, LUA_XNET_LISTENER_META)) {
        lua_pushcfunction(L, l_listener_gc);
        lua_setfield(L, -2, "__gc");
        lua_newtable(L);
        luaL_setfuncs(L, listener_methods, 0);
        lua_setfield(L, -2, "__index");
    }
    lua_pop(L, 1);

    luaL_newlib(L, xnet_funcs);
    lua_pushinteger(L, XPOLL_READABLE);
    lua_setfield(L, -2, "READABLE");
    lua_pushinteger(L, XPOLL_WRITABLE);
    lua_setfield(L, -2, "WRITABLE");
    lua_pushinteger(L, XPOLL_ERROR);
    lua_setfield(L, -2, "ERROR");
    lua_pushinteger(L, XPOLL_CLOSE);
    lua_setfield(L, -2, "CLOSE");
    return 1;
}
