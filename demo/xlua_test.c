/* demo/xlua_test.c - Bootstrap the xthread Lua demo
**
** C initializes xthread, loads the Lua entry script, pumps the main thread,
** and lets Lua own the dynamic thread lifecycle.
*/

#define LUA_IMPL
#include "../3rd/minilua.h"

#include <stdio.h>
#include <stdlib.h>
#include <stdbool.h>

#include "xthread.h"
#include "xargs.h"
#include "xlog.h"

/* cmsgpack is statically linked */
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

    XLOGI("[C] Received stop request from Lua, exit_code=%d", g_exit_code);
    g_running = false;
    return 0;
}

static MainLuaData* main_init(void) {
    XLOGI("[main] initializing Lua");

    MainLuaData* data = (MainLuaData*)malloc(sizeof(MainLuaData));
    if (!data) {
        XLOGE("[main] malloc failed");
        return NULL;
    }

    data->L = luaL_newstate();
    if (!data->L) {
        XLOGE("[main] luaL_newstate failed");
        free(data);
        return NULL;
    }

    data->sync_handler_ref = LUA_NOREF;
    data->init_ref = LUA_NOREF;
    data->update_ref = LUA_NOREF;
    data->uninit_ref = LUA_NOREF;

    luaL_openlibs(data->L);

    luaL_requiref(data->L, "cmsgpack", luaopen_cmsgpack, 1);
    lua_pop(data->L, 1);

    luaL_requiref(data->L, "xthread", luaopen_xthread, 1);
    lua_pop(data->L, 1);

    luaL_requiref(data->L, "xnet", luaopen_xnet, 1);
    lua_pop(data->L, 1);

    XLOGI("[main] loading script 'demo/xlua_main.lua'");
    if (luaL_dofile(data->L, "demo/xlua_main.lua") != LUA_OK) {
        XLOGE("[main] failed to run main script: %s", lua_tostring(data->L, -1));
        lua_close(data->L);
        free(data);
        return NULL;
    }

    if (!lua_istable(data->L, -1)) {
        XLOGE("[main] script 'demo/xlua_main.lua' did not return a definition table");
        lua_close(data->L);
        free(data);
        return NULL;
    }

    lua_getfield(data->L, -1, "__thread_handle");
    if (lua_isfunction(data->L, -1)) {
        data->sync_handler_ref = luaL_ref(data->L, LUA_REGISTRYINDEX);
    } else {
        lua_pop(data->L, 1);
        XLOGW("[main] no __thread_handle in script");
        data->sync_handler_ref = LUA_NOREF;
    }

    lua_getfield(data->L, -1, "__init");
    if (lua_isfunction(data->L, -1)) {
        data->init_ref = luaL_ref(data->L, LUA_REGISTRYINDEX);
    } else {
        lua_pop(data->L, 1);
        data->init_ref = LUA_NOREF;
    }

    lua_getfield(data->L, -1, "__update");
    if (lua_isfunction(data->L, -1)) {
        data->update_ref = luaL_ref(data->L, LUA_REGISTRYINDEX);
    } else {
        lua_pop(data->L, 1);
        data->update_ref = LUA_NOREF;
    }

    lua_getfield(data->L, -1, "__uninit");
    if (lua_isfunction(data->L, -1)) {
        data->uninit_ref = luaL_ref(data->L, LUA_REGISTRYINDEX);
    } else {
        lua_pop(data->L, 1);
        data->uninit_ref = LUA_NOREF;
    }

    lua_pop(data->L, 1);

    lua_getglobal(data->L, "xthread");
    lua_pushcfunction(data->L, l_xthread_stop);
    lua_setfield(data->L, -2, "stop");
    lua_pop(data->L, 1);

    // call xthread.init-->init(thread_handler)
    int base = lua_gettop(data->L);
    lua_getglobal(data->L, "xthread");
    lua_getfield(data->L, -1, "init");
    lua_remove(data->L, -2);
    int nargs = 0;
    if (data->sync_handler_ref != LUA_NOREF) {
        lua_rawgeti(data->L, LUA_REGISTRYINDEX, data->sync_handler_ref);
        nargs = 1;
    }
    if (lua_pcall(data->L, nargs, 0, 0) != LUA_OK) {
        XLOGE("[main] xthread.init failed: %s", lua_tostring(data->L, -1));
        lua_settop(data->L, base);
        g_exit_code = 1;
        g_running = false;
    }

    if (data->init_ref != LUA_NOREF && g_running) {
        base = lua_gettop(data->L);
        lua_rawgeti(data->L, LUA_REGISTRYINDEX, data->init_ref);
        if (lua_pcall(data->L, 0, 0, 0) != LUA_OK) {
            XLOGE("[main] user init callback error: %s", lua_tostring(data->L, -1));
            lua_settop(data->L, base);
            g_exit_code = 1;
            g_running = false;
        }
    }

    XLOGI("[main] Lua initialized");
    return data;
}

static void main_update(MainLuaData* data) {
    if (!data || !data->L) {
        return;
    }

    lua_State* L = data->L;
    if (data->update_ref != LUA_NOREF) {
        int base = lua_gettop(L);
        lua_rawgeti(L, LUA_REGISTRYINDEX, data->update_ref);
        if (lua_pcall(L, 0, 0, 0) != LUA_OK) {
            XLOGE("[main] update callback error: %s", lua_tostring(L, -1));
            lua_settop(L, base);
            g_exit_code = 1;
            g_running = false;
        }
    }
}

static void main_uninit(MainLuaData* data) {
    if (!data) {
        return;
    }

    if (data->uninit_ref != LUA_NOREF && data->L) {
        lua_State* L = data->L;
        int base = lua_gettop(L);

        lua_rawgeti(L, LUA_REGISTRYINDEX, data->uninit_ref);
        if (lua_pcall(L, 0, 0, 0) != LUA_OK) {
            XLOGE("[main] uninit callback error: %s", lua_tostring(L, -1));
            lua_settop(L, base);
            if (g_exit_code == 0) {
                g_exit_code = 1;
            }
        }
    }

    if (data->L) {
        if (data->sync_handler_ref != LUA_NOREF) {
            luaL_unref(data->L, LUA_REGISTRYINDEX, data->sync_handler_ref);
        }
        if (data->init_ref != LUA_NOREF) {
            luaL_unref(data->L, LUA_REGISTRYINDEX, data->init_ref);
        }
        if (data->update_ref != LUA_NOREF) {
            luaL_unref(data->L, LUA_REGISTRYINDEX, data->update_ref);
        }
        if (data->uninit_ref != LUA_NOREF) {
            luaL_unref(data->L, LUA_REGISTRYINDEX, data->uninit_ref);
        }

        xThread* thr = xthread_current();
        if (thr) {
            xthread_set_userdata(thr, NULL);
        }
        lua_close(data->L);
        data->L = NULL;
    }

    free(data);
    XLOGI("[main] cleaned up");
}

int main(int argc, char** argv) {
    (void)argc;
    (void)argv;
    console_set_consolas_font();

    XLOGI("Starting xthread Lua demo");

    if (!xthread_init()) {
        XLOGE("xthread_init failed");
        return 1;
    }

    g_running = true;

    MainLuaData* main_data = main_init();
    if (!main_data) {
        XLOGE("Main Lua init failed");
        xthread_uninit();
        return 1;
    }

    XLOGI("Entering main event loop");
    while (g_running) {
        main_update(main_data);
        xthread_update(10);
    }

    XLOGI("Shutting down...");
    main_uninit(main_data);
    xthread_uninit();

    return g_exit_code;
}
