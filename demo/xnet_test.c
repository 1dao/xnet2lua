/* demo/xnet_test.c - Bootstrap the xnet Lua demo.
**
** Main Lua thread listens only. Accepted sockets are passed to a worker Lua
** thread, where lua_xnet attaches the fd and xchannel handles len32 packets.
*/

#define LUA_IMPL
#include "../3rd/minilua.h"

#include <stdio.h>
#include <stdlib.h>
#include <stdbool.h>

#include "xthread.h"
#include "xargs.h"
#include "xlog.h"

LUA_API int luaopen_cmsgpack(lua_State *L);
LUA_API int luaopen_xthread(lua_State *L);
LUA_API int luaopen_xnet(lua_State *L);

typedef struct {
    lua_State* L;
    int sync_handler_ref;
    int init_ref;
    int update_ref;
    int uninit_ref;
} MainLuaData;

static volatile bool g_running = false;
static int g_exit_code = 0;

static int l_xthread_stop(lua_State* L) {
    if (lua_gettop(L) >= 1 && !lua_isnil(L, 1)) {
        if (lua_isboolean(L, 1)) {
            g_exit_code = lua_toboolean(L, 1) ? 0 : 1;
        } else if (lua_isnumber(L, 1)) {
            g_exit_code = (int)lua_tointeger(L, 1);
        }
    }

    XLOGI("[xnet_test] stop requested, exit_code=%d", g_exit_code);
    g_running = false;
    return 0;
}

static void unref_if_needed(lua_State* L, int* ref) {
    if (*ref != LUA_NOREF && *ref != LUA_REFNIL) {
        luaL_unref(L, LUA_REGISTRYINDEX, *ref);
    }
    *ref = LUA_NOREF;
}

static MainLuaData* main_init(void) {
    MainLuaData* data = (MainLuaData*)calloc(1, sizeof(*data));
    if (!data) return NULL;

    data->sync_handler_ref = LUA_NOREF;
    data->init_ref = LUA_NOREF;
    data->update_ref = LUA_NOREF;
    data->uninit_ref = LUA_NOREF;

    data->L = luaL_newstate();
    if (!data->L) {
        free(data);
        return NULL;
    }

    lua_State* L = data->L;
    luaL_openlibs(L);

    luaL_requiref(L, "cmsgpack", luaopen_cmsgpack, 1);
    lua_pop(L, 1);
    luaL_requiref(L, "xthread", luaopen_xthread, 1);
    lua_pop(L, 1);
    luaL_requiref(L, "xnet", luaopen_xnet, 1);
    lua_pop(L, 1);

    if (luaL_dofile(L, "demo/xnet_main.lua") != LUA_OK) {
        XLOGE("[xnet_test] load demo/xnet_main.lua failed: %s", lua_tostring(L, -1));
        lua_close(L);
        free(data);
        return NULL;
    }

    if (!lua_istable(L, -1)) {
        XLOGE("[xnet_test] demo/xnet_main.lua did not return a table");
        lua_close(L);
        free(data);
        return NULL;
    }

    lua_getfield(L, -1, "__thread_handle");
    if (lua_isfunction(L, -1)) data->sync_handler_ref = luaL_ref(L, LUA_REGISTRYINDEX);
    else lua_pop(L, 1);

    lua_getfield(L, -1, "__init");
    if (lua_isfunction(L, -1)) data->init_ref = luaL_ref(L, LUA_REGISTRYINDEX);
    else lua_pop(L, 1);

    lua_getfield(L, -1, "__update");
    if (lua_isfunction(L, -1)) data->update_ref = luaL_ref(L, LUA_REGISTRYINDEX);
    else lua_pop(L, 1);

    lua_getfield(L, -1, "__uninit");
    if (lua_isfunction(L, -1)) data->uninit_ref = luaL_ref(L, LUA_REGISTRYINDEX);
    else lua_pop(L, 1);

    lua_pop(L, 1);

    lua_getglobal(L, "xthread");
    lua_pushcfunction(L, l_xthread_stop);
    lua_setfield(L, -2, "stop");
    lua_pop(L, 1);

    int base = lua_gettop(L);
    lua_getglobal(L, "xthread");
    lua_getfield(L, -1, "init");
    lua_remove(L, -2);
    int nargs = 0;
    if (data->sync_handler_ref != LUA_NOREF) {
        lua_rawgeti(L, LUA_REGISTRYINDEX, data->sync_handler_ref);
        nargs = 1;
    }
    if (lua_pcall(L, nargs, 0, 0) != LUA_OK) {
        XLOGE("[xnet_test] xthread.init failed: %s", lua_tostring(L, -1));
        lua_settop(L, base);
        g_exit_code = 1;
        g_running = false;
    }

    if (data->init_ref != LUA_NOREF && g_running) {
        base = lua_gettop(L);
        lua_rawgeti(L, LUA_REGISTRYINDEX, data->init_ref);
        if (lua_pcall(L, 0, 0, 0) != LUA_OK) {
            XLOGE("[xnet_test] __init failed: %s", lua_tostring(L, -1));
            lua_settop(L, base);
            g_exit_code = 1;
            g_running = false;
        }
    }

    return data;
}

static void main_update(MainLuaData* data) {
    if (!data || !data->L || data->update_ref == LUA_NOREF) return;
    lua_State* L = data->L;
    int base = lua_gettop(L);
    lua_rawgeti(L, LUA_REGISTRYINDEX, data->update_ref);
    if (lua_pcall(L, 0, 0, 0) != LUA_OK) {
        XLOGE("[xnet_test] __update failed: %s", lua_tostring(L, -1));
        lua_settop(L, base);
        g_exit_code = 1;
        g_running = false;
    }
}

static void main_uninit(MainLuaData* data) {
    if (!data) return;

    if (data->L && data->uninit_ref != LUA_NOREF) {
        lua_State* L = data->L;
        int base = lua_gettop(L);
        lua_rawgeti(L, LUA_REGISTRYINDEX, data->uninit_ref);
        if (lua_pcall(L, 0, 0, 0) != LUA_OK) {
            XLOGE("[xnet_test] __uninit failed: %s", lua_tostring(L, -1));
            lua_settop(L, base);
            if (g_exit_code == 0) g_exit_code = 1;
        }
    }

    if (data->L) {
        unref_if_needed(data->L, &data->sync_handler_ref);
        unref_if_needed(data->L, &data->init_ref);
        unref_if_needed(data->L, &data->update_ref);
        unref_if_needed(data->L, &data->uninit_ref);
        xThread* thr = xthread_current();
        if (thr) xthread_set_userdata(thr, NULL);
        lua_close(data->L);
    }

    free(data);
}

int main(int argc, char** argv) {
    (void)argc;
    (void)argv;
    console_set_consolas_font();

    if (!xthread_init()) {
        XLOGE("[xnet_test] xthread_init failed");
        return 1;
    }

    g_running = true;
    MainLuaData* main_data = main_init();
    if (!main_data) {
        xthread_uninit();
        return 1;
    }

    while (g_running) {
        main_update(main_data);
        xthread_update(0);
    }

    main_uninit(main_data);
    xthread_uninit();
    return g_exit_code;
}
