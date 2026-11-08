#include "lua_xnet.h"

#if XNET_WITH_UDP
#include "xudp.h"
#include "xlog.h"
#include <string.h>

#define LUA_XNET_UDP_META "xnet.udp"
#ifdef _MSC_VER
#define UDP_LUA_TLS __declspec(thread)
#else
#define UDP_LUA_TLS __thread
#endif

typedef struct LuaUdp {
    lua_State* L;
    xUdp* udp;
    int self_ref, handler_ref;
    struct LuaUdp *prev, *next;
    bool listed;
} LuaUdp;

/* Only active objects are rooted. Each belongs to a Lua state on this thread;
 * cleanup of a worker state cannot touch a different state's Lua registry. */
static UDP_LUA_TLS LuaUdp* udp_head;

static LuaUdp* check_udp(lua_State* L) {
    return (LuaUdp*)luaL_checkudata(L, 1, LUA_XNET_UDP_META);
}

static void udp_close_lua(LuaUdp* u) {
    xudp_close(u->udp);
    if (u->listed) {
        if (u->prev) u->prev->next = u->next; else udp_head = u->next;
        if (u->next) u->next->prev = u->prev;
        u->listed = false;
        u->prev = u->next = NULL;
    }
    ref_unref(u->L, &u->handler_ref);
    ref_unref(u->L, &u->self_ref);
}

void lua_xnet_udp_cleanup(lua_State* L) {
    LuaUdp* u = udp_head;
    lua_State* owner = L ? main_lua_state(L) : NULL;
    while (u) {
        LuaUdp* next = u->next;
        if (!owner || u->L == owner) udp_close_lua(u);
        u = next;
    }
}

static void udp_datagram(xUdp* udp, const char* data, size_t len,
                         const xUdpAddress* addr, void* userdata) {
    LuaUdp* u = (LuaUdp*)userdata;
    lua_State* L = u->L;
    int base = lua_gettop(L);
    (void)udp;
    /* Keep the wrapper alive even if close/uninit releases registry roots and
     * the user's callback immediately runs a full collection. */
    lua_rawgeti(L, LUA_REGISTRYINDEX, u->self_ref);
    if (push_handler(L, u->handler_ref, "on_datagram", NULL, NULL)) {
        lua_pushvalue(L, base + 1);
        lua_pushlstring(L, data, len);
        lua_pushstring(L, addr->ip);
        lua_pushinteger(L, addr->port);
        if (lua_pcall(L, 4, 0, 0) != LUA_OK) {
            xloge("xnet: UDP on_datagram error: %s", lua_tostring(L, -1));
            udp_close_lua(u);
        }
    }
    lua_settop(L, base);
}

static void udp_error(xUdp* udp, int error, bool fatal, void* userdata) {
    LuaUdp* u = (LuaUdp*)userdata;
    lua_State* L = u->L;
    int base = lua_gettop(L);
    (void)udp;
    lua_rawgeti(L, LUA_REGISTRYINDEX, u->self_ref);
    if (push_handler(L, u->handler_ref, "on_error", NULL, NULL)) {
        lua_pushvalue(L, base + 1);
        lua_pushinteger(L, error);
        lua_pushboolean(L, fatal);
        if (lua_pcall(L, 3, 0, 0) != LUA_OK) {
            xloge("xnet: UDP on_error error: %s", lua_tostring(L, -1));
            fatal = true;
        }
    }
    if (fatal) udp_close_lua(u);
    lua_settop(L, base);
}

static int udp_result(lua_State* L, int rc, int error) {
    lua_pushboolean(L, rc == XUDP_OK);
    if (rc == XUDP_OK) return 1;
    lua_pushstring(L, xudp_result_name(rc));
    lua_pushinteger(L, error);
    return 3;
}

static int l_udp_sendto(lua_State* L) {
    LuaUdp* u = check_udp(L);
    size_t len;
    const char* data = luaL_checklstring(L, 2, &len);
    const char* ip = luaL_checkstring(L, 3);
    lua_Integer port = luaL_checkinteger(L, 4);
    xUdpAddress addr;
    int error = 0;
    if (port < 1 || port > 65535 || xudp_address(ip, (int)port, &addr))
        return udp_result(L, XUDP_INVALID_ADDRESS, 0);
    int rc = xudp_sendto(u->udp, data, len, &addr, &error);
    return udp_result(L, rc, error);
}

static int l_udp_sockname(lua_State* L) {
    xUdpAddress addr;
    int rc = xudp_sockname(check_udp(L)->udp, &addr);
    if (rc) { lua_pushnil(L); lua_pushstring(L, xudp_result_name(rc)); return 2; }
    lua_pushstring(L, addr.ip);
    lua_pushinteger(L, addr.port);
    return 2;
}

static int l_udp_close(lua_State* L) { udp_close_lua(check_udp(L)); return 0; }
static int l_udp_closed(lua_State* L) {
    lua_pushboolean(L, xudp_is_closed(check_udp(L)->udp));
    return 1;
}
static int l_udp_gc(lua_State* L) {
    LuaUdp* u = check_udp(L);
    udp_close_lua(u);
    xudp_destroy(u->udp);
    u->udp = NULL;
    return 0;
}
static int l_udp_stats(lua_State* L) {
    xUdpStats stats;
    xudp_get_stats(check_udp(L)->udp, &stats);
    lua_createtable(L, 0, 12);
#define UDP_STAT(field) lua_pushinteger(L, (lua_Integer)stats.field); lua_setfield(L, -2, #field)
    UDP_STAT(datagrams_sent); UDP_STAT(bytes_sent);
    UDP_STAT(datagrams_received); UDP_STAT(bytes_received);
    UDP_STAT(dropped_oversize); UDP_STAT(receive_errors); UDP_STAT(send_errors);
    UDP_STAT(send_would_block); UDP_STAT(receive_calls); UDP_STAT(budget_yields);
    UDP_STAT(last_error);
#undef UDP_STAT
    return 1;
}

int l_xnet_udp_bind(lua_State* L) {
    const char* host = luaL_optstring(L, 1, "0.0.0.0");
    lua_Integer port = luaL_checkinteger(L, 2);
    xUdpConfig cfg = {0};
    char error[XSOCK_ERR_LEN];
    luaL_checktype(L, 3, LUA_TTABLE);
    lua_getfield(L, 3, "on_datagram");
    luaL_argcheck(L, lua_isfunction(L, -1), 3, "on_datagram function required");
    lua_pop(L, 1);
    luaL_argcheck(L, port >= 0 && port <= 65535, 2, "port must be in 0..65535");
    if (!lua_isnoneornil(L, 4)) {
        lua_Integer value;
        luaL_checktype(L, 4, LUA_TTABLE);
        lua_getfield(L, 4, "max_datagram");
        value = lua_isnil(L, -1) ? XUDP_MAX_DATAGRAM : luaL_checkinteger(L, -1);
        luaL_argcheck(L, value > 0 && value <= XUDP_MAX_DATAGRAM, 4, "invalid max_datagram");
        cfg.max_datagram = (size_t)value;
        lua_pop(L, 1);
        lua_getfield(L, 4, "recv_budget");
        value = lua_isnil(L, -1) ? XUDP_DEFAULT_RECV_BUDGET : luaL_checkinteger(L, -1);
        luaL_argcheck(L, value > 0 && value <= XUDP_MAX_RECV_BUDGET, 4, "invalid recv_budget");
        cfg.recv_budget = (unsigned)value;
        lua_pop(L, 1);
    }
    LuaUdp* u = (LuaUdp*)lua_newuserdata(L, sizeof(*u));
    memset(u, 0, sizeof(*u));
    u->L = main_lua_state(L);
    u->self_ref = u->handler_ref = LUA_NOREF;
    luaL_getmetatable(L, LUA_XNET_UDP_META);
    lua_setmetatable(L, -2);
    cfg.on_datagram = udp_datagram;
    cfg.on_error = udp_error;
    cfg.userdata = u;
    u->udp = xudp_bind(host, (int)port, &cfg, error);
    if (!u->udp) { lua_pushnil(L); lua_pushstring(L, error); return 2; }
    ref_from_stack(L, 3, &u->handler_ref);
    ref_from_stack(L, -1, &u->self_ref);
    u->listed = true;
    u->next = udp_head;
    if (udp_head) udp_head->prev = u;
    udp_head = u;
    return 1;
}

void lua_xnet_udp_register(lua_State* L) {
    static const luaL_Reg methods[] = {
        {"sendto", l_udp_sendto}, {"sockname", l_udp_sockname},
        {"close", l_udp_close}, {"is_closed", l_udp_closed},
        {"stats", l_udp_stats}, {NULL, NULL}
    };
    if (luaL_newmetatable(L, LUA_XNET_UDP_META)) {
        lua_pushcfunction(L, l_udp_gc); lua_setfield(L, -2, "__gc");
        lua_newtable(L); luaL_setfuncs(L, methods, 0); lua_setfield(L, -2, "__index");
    }
    lua_pop(L, 1);
}
#endif /* XNET_WITH_UDP */
