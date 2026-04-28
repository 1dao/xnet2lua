/* demo/xnet_main.c - Generic Lua main runner for xnet/xthread demos.
**
** xnet test mode:
**   Build this file once into xnet.exe, then run any Lua test by passing the
**   test's main script. Shared service configuration can be loaded by Lua via
**   xnet.load_config(); SERVER_NAME can be supplied after the main script.
**
** Usage:
**   xnet.exe demo/xnats_main.lua SERVER_NAME=game1
**   xnet.exe demo/xhttp_main.lua
**   xnet.exe demo/xmysql_main.lua
**   xnet.exe demo/xredis_main.lua
**   xnet.exe demo/xnet_main.lua
**   xnet.exe demo/xlua_main.lua
*/

#define LUA_IMPL
#include "../3rd/minilua.h"

#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>

#include "xargs.h"
#include "xlog.h"
#include "xthread.h"

#ifndef XNET_WITH_HTTP
#define XNET_WITH_HTTP 1
#endif

#ifndef XNET_WITH_HTTPS
#define XNET_WITH_HTTPS 0
#endif

LUA_API int luaopen_cmsgpack(lua_State *L);
LUA_API int luaopen_xthread(lua_State *L);
LUA_API int luaopen_xnet(lua_State *L);

typedef struct {
    lua_State* L;
    int sync_handler_ref;
    int init_ref;
    int update_ref;
    int uninit_ref;
    int tick_ms;
} MainLuaData;

static volatile bool g_running = false;
static int g_exit_code = 0;
static const char* g_main_file = NULL;
static int g_script_argc = 0;
static char** g_script_argv = NULL;
static const char* g_process_name = NULL;

static xArgsCFG g_arg_configs[] = {
    { 'c', "config", NULL, 0 },
    { 0,   "SERVER_NAME", NULL, 0 },
    { 0,   "NATS_HOST", NULL, 0 },
    { 0,   "NATS_PORT", NULL, 0 },
    { 0,   "NATS_PREFIX", NULL, 0 },
    { 0,   "NATS_TEST_DELAY_SEC", NULL, 0 },
    { 0,   "NATS_TEST_TIMEOUT_SEC", NULL, 0 },
    { 0,   "NATS_TEST_HOLD_SEC", NULL, 0 },
    { 0,   "NATS_TEST_PEER", NULL, 0 },
    { 0,   "HTTP_ENABLE", NULL, 0 },
    { 0,   "HTTP_HOST", NULL, 0 },
    { 0,   "HTTP_PORT", NULL, 0 },
    { 0,   "HTTP_WORKERS", NULL, 0 },
    { 0,   "HTTPS_ENABLE", NULL, 0 },
    { 0,   "HTTPS_PORT", NULL, 0 },
    { 0,   "HTTPS_CERT", NULL, 0 },
    { 0,   "HTTPS_KEY", NULL, 0 },
    { 0,   "REDIS_HOST", NULL, 0 },
    { 0,   "REDIS_PORT", NULL, 0 },
    { 0,   "REDIS_DB", NULL, 0 },
    { 0,   "MYSQL_HOST", NULL, 0 },
    { 0,   "MYSQL_PORT", NULL, 0 },
    { 0,   "MYSQL_USER", NULL, 0 },
    { 0,   "MYSQL_PASSWORD", NULL, 0 },
    { 0,   "MYSQL_DATABASE", NULL, 0 },
};

static int l_xthread_stop(lua_State* L) {
    if (lua_gettop(L) >= 1 && !lua_isnil(L, 1)) {
        if (lua_isboolean(L, 1)) {
            g_exit_code = lua_toboolean(L, 1) ? 0 : 1;
        } else if (lua_isnumber(L, 1)) {
            g_exit_code = (int)lua_tointeger(L, 1);
        }
    }

    XLOGI("[xnet] stop requested, exit_code=%d", g_exit_code);
    g_running = false;
    return 0;
}

static void unref_if_needed(lua_State* L, int* ref) {
    if (*ref != LUA_NOREF && *ref != LUA_REFNIL) {
        luaL_unref(L, LUA_REGISTRYINDEX, *ref);
    }
    *ref = LUA_NOREF;
}

static void preload_modules(lua_State* L) {
    luaL_requiref(L, "cmsgpack", luaopen_cmsgpack, 1);
    lua_pop(L, 1);

    luaL_requiref(L, "xthread", luaopen_xthread, 1);
    lua_pop(L, 1);

    luaL_requiref(L, "xnet", luaopen_xnet, 1);
    lua_pop(L, 1);
}

static void install_stop(lua_State* L) {
    lua_getglobal(L, "xthread");
    lua_pushcfunction(L, l_xthread_stop);
    lua_setfield(L, -2, "stop");
    lua_pop(L, 1);
}

static void set_runner_globals(lua_State* L) {
    lua_pushstring(L, g_main_file);
    lua_setglobal(L, "XNET_MAIN_FILE");

    if (g_process_name) lua_pushstring(L, g_process_name);
    else lua_pushnil(L);
    lua_setglobal(L, "XNET_PROCESS_NAME");

    lua_pushboolean(L, XNET_WITH_HTTP ? 1 : 0);
    lua_setglobal(L, "XNET_WITH_HTTP");

    lua_pushboolean(L, XNET_WITH_HTTPS ? 1 : 0);
    lua_setglobal(L, "XNET_WITH_HTTPS");

    lua_newtable(L);
    lua_pushstring(L, g_main_file);
    lua_rawseti(L, -2, 0);
    for (int i = 0; i < g_script_argc; i++) {
        lua_pushstring(L, g_script_argv[i]);
        lua_rawseti(L, -2, i + 1);
    }
    lua_setglobal(L, "arg");
}

static void call_xthread_init(MainLuaData* data) {
    lua_State* L = data->L;
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
        XLOGE("[xnet] xthread.init failed: %s", lua_tostring(L, -1));
        lua_settop(L, base);
        g_exit_code = 1;
        g_running = false;
    }
}

static void ref_lifecycle(MainLuaData* data) {
    lua_State* L = data->L;

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

    lua_getfield(L, -1, "__tick_ms");
    if (lua_isnumber(L, -1)) {
        int tick_ms = (int)lua_tointeger(L, -1);
        if (tick_ms >= 0) data->tick_ms = tick_ms;
    }
    lua_pop(L, 1);
}

static MainLuaData* main_init(void) {
    MainLuaData* data = (MainLuaData*)calloc(1, sizeof(*data));
    if (!data) return NULL;

    data->sync_handler_ref = LUA_NOREF;
    data->init_ref = LUA_NOREF;
    data->update_ref = LUA_NOREF;
    data->uninit_ref = LUA_NOREF;
    data->tick_ms = 10;

    data->L = luaL_newstate();
    if (!data->L) {
        free(data);
        return NULL;
    }

    lua_State* L = data->L;
    luaL_openlibs(L);
    preload_modules(L);
    install_stop(L);
    set_runner_globals(L);

    XLOGI("[xnet] loading main script '%s'", g_main_file);
    if (luaL_dofile(L, g_main_file) != LUA_OK) {
        XLOGE("[xnet] load %s failed: %s", g_main_file, lua_tostring(L, -1));
        lua_close(L);
        free(data);
        g_exit_code = 1;
        return NULL;
    }

    if (!lua_istable(L, -1)) {
        XLOGE("[xnet] %s did not return a table", g_main_file);
        lua_close(L);
        free(data);
        g_exit_code = 1;
        return NULL;
    }

    ref_lifecycle(data);
    lua_pop(L, 1);

    call_xthread_init(data);

    if (data->init_ref != LUA_NOREF && g_running) {
        int base = lua_gettop(L);
        lua_rawgeti(L, LUA_REGISTRYINDEX, data->init_ref);
        if (lua_pcall(L, 0, 0, 0) != LUA_OK) {
            XLOGE("[xnet] __init failed: %s", lua_tostring(L, -1));
            lua_settop(L, base);
            g_exit_code = 1;
            g_running = false;
        }
    }

    return data;
}

static void main_update(MainLuaData* data) {
    if (!data || !data->L) return;
    lua_State* L = data->L;

    if (data->update_ref != LUA_NOREF) {
        int base = lua_gettop(L);
        lua_rawgeti(L, LUA_REGISTRYINDEX, data->update_ref);
        if (lua_pcall(L, 0, 0, 0) != LUA_OK) {
            XLOGE("[xnet] __update failed: %s", lua_tostring(L, -1));
            lua_settop(L, base);
            g_exit_code = 1;
            g_running = false;
        }
    }

    xthread_update(data->tick_ms);
}

static void main_uninit(MainLuaData* data) {
    if (!data) return;

    if (data->L && data->uninit_ref != LUA_NOREF) {
        lua_State* L = data->L;
        int base = lua_gettop(L);
        lua_rawgeti(L, LUA_REGISTRYINDEX, data->uninit_ref);
        if (lua_pcall(L, 0, 0, 0) != LUA_OK) {
            XLOGE("[xnet] __uninit failed: %s", lua_tostring(L, -1));
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
    console_set_consolas_font();

    if (argc < 2) {
        fprintf(stderr, "usage: %s <main.lua> [SERVER_NAME=name]\n", argv[0]);
        return 2;
    }

    g_main_file = argv[1];
    g_script_argc = argc - 2;
    g_script_argv = (argc > 2) ? &argv[2] : NULL;
    xargs_init(g_arg_configs, (int)(sizeof(g_arg_configs) / sizeof(g_arg_configs[0])),
               argc - 1, &argv[1]);
    g_process_name = xargs_get("SERVER_NAME");

    if (!xthread_init()) {
        XLOGE("[xnet] xthread_init failed");
        xargs_cleanup();
        return 1;
    }

    g_running = true;
    MainLuaData* data = main_init();
    if (!data) {
        xthread_uninit();
        xargs_cleanup();
        return g_exit_code ? g_exit_code : 1;
    }

    while (g_running) {
        main_update(data);
    }

    main_uninit(data);
    xthread_uninit();
    xargs_cleanup();
    return g_exit_code;
}
