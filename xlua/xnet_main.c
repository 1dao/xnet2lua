/* xnet_main.c - Generic Lua main runner for xnet/xthread demos.
**
** xnet test mode:
**   Build this file once into xnet.exe, then run any Lua test by passing the
**   test's main script. Shared service configuration can be loaded by Lua via
**   xutils.load_config(); SERVER_NAME can be supplied after the main script.
**
** Usage:
**   xnet.exe demo/xnats_main.lua SERVER_NAME=game1
**   xnet.exe demo/xhttp_main.lua
**   xnet.exe demo/xmysql_main.lua
**   xnet.exe demo/xredis_main.lua
**   xnet.exe demo/xnet_main.lua
**   xnet.exe demo/xlua_main.lua
*/

#include "xpoll.h"

#if defined(LUA_EMBEDDED)
#define LUA_IMPL
/* macOS <unistd.h> exposes BSD getmode(3); rename minilua.h's internal
   symbol to avoid a redeclaration clash. Safe because LUA_IMPL is only
   defined here, so this is the only TU that compiles the function body. */
#define getmode lua_getmode
#include "3rd/minilua.h"
#undef getmode
#else
#include "lua.h"
#include "lauxlib.h"
#include "lualib.h"
#if defined(XLUA_USE_LUAJIT)
#include "luajit.h"
#endif
#endif

#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "xargs.h"
#include "xdaemon.h"
#include "xlog.h"
#include "xthread.h"
#include "xtimer.h"
#include "xlua/lua_xdebug.h"

#include "xmacro.h"   /* malloc/free → rpmalloc; runtime lifecycle in main() */

#if defined(LUA_VERSION_NUM) && LUA_VERSION_NUM < 502
static void luaL_requiref(lua_State* L, const char* modname,
                          lua_CFunction openf, int glb) {
    lua_pushcfunction(L, openf);
    lua_pushstring(L, modname);
    lua_call(L, 1, 1);

    lua_getfield(L, LUA_REGISTRYINDEX, "_LOADED");
    if (!lua_istable(L, -1)) {
        lua_pop(L, 1);
        lua_newtable(L);
        lua_pushvalue(L, -1);
        lua_setfield(L, LUA_REGISTRYINDEX, "_LOADED");
    }
    lua_pushvalue(L, -2);
    lua_setfield(L, -2, modname);
    lua_pop(L, 1);

    if (glb) {
        lua_pushvalue(L, -1);
        lua_setglobal(L, modname);
    }
}
#endif

#ifndef XNET_WITH_HTTP
#define XNET_WITH_HTTP 1
#endif

#ifndef XNET_WITH_HTTPS
#define XNET_WITH_HTTPS 0
#endif

LUA_API int luaopen_cmsgpack(lua_State *L);
LUA_API int luaopen_xthread(lua_State *L);
LUA_API int luaopen_xnet(lua_State *L);
LUA_API int luaopen_xutils(lua_State *L);
LUA_API int luaopen_xtimer(lua_State *L);
LUA_API int luaopen_xcompress(lua_State *L);

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

static int l_xnet_main_reload(lua_State* L);

static void lua_runtime_post_init(lua_State* L) {
#if defined(XLUA_USE_LUAJIT)
    /* Explicitly keep the JIT engine enabled when running with LuaJIT. */
    if (L) luaJIT_setmode(L, 0, LUAJIT_MODE_ENGINE | LUAJIT_MODE_ON);
#else
    (void)L;
#endif
}

static xArgsCFG g_arg_configs[] = {
    { 'c', "config", NULL, 0 },
    { 'd', "daemon", NULL, 1 },
    { 0,   "DAEMON", NULL, 0 },
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
    { 0,   "HTTPS_KEY_PASSWORD", NULL, 0 },
    { 0,   "HTTPS_TEST_SECONDS", NULL, 0 },
    { 0,   "PAC_WEB_HOST", NULL, 0 },
    { 0,   "PAC_WEB_PORT", NULL, 0 },
    { 0,   "PAC_FILE", NULL, 0 },
    { 0,   "PAC_STATIC_DIR", NULL, 0 },
    { 0,   "PAC_HTTP_PROXY_HOST", NULL, 0 },
    { 0,   "PAC_HTTP_PROXY_PORT", NULL, 0 },
    { 0,   "PAC_SOCKS5_PROXY_HOST", NULL, 0 },
    { 0,   "PAC_SOCKS5_PROXY_PORT", NULL, 0 },
    { 0,   "XADMIN_HOST", NULL, 0 },
    { 0,   "XADMIN_PORT", NULL, 0 },
    { 0,   "XADMIN_HTTPS", NULL, 0 },
    { 0,   "XADMIN_STATIC_DIR", NULL, 0 },
    { 0,   "XADMIN_TOKEN", NULL, 0 },
    { 0,   "XADMIN_HEARTBEAT_MS", NULL, 0 },
    { 0,   "XADMIN_PEER_TTL_MS", NULL, 0 },
    { 0,   "XDEBUG_BOOT", NULL, 0 },
    { 0,   "XDEBUG_PORT", NULL, 0 },
    { 0,   "XDEBUG_WAIT", NULL, 0 },
    { 0,   "REDIS_HOST", NULL, 0 },
    { 0,   "REDIS_PORT", NULL, 0 },
    { 0,   "REDIS_DB", NULL, 0 },
    { 0,   "MYSQL_HOST", NULL, 0 },
    { 0,   "MYSQL_PORT", NULL, 0 },
    { 0,   "MYSQL_USER", NULL, 0 },
    { 0,   "MYSQL_PASSWORD", NULL, 0 },
    { 0,   "MYSQL_DATABASE", NULL, 0 },
};

static bool config_bool_enabled(const char* value) {
    if (!value) return false;
    if (value[0] == '\0') return true;

    char buf[16];
    size_t n = strlen(value);
    if (n >= sizeof(buf)) n = sizeof(buf) - 1;
    for (size_t i = 0; i < n; ++i) {
        char c = value[i];
        if (c >= 'A' && c <= 'Z') c = (char)(c - 'A' + 'a');
        buf[i] = c;
    }
    buf[n] = '\0';

    return strcmp(buf, "1") == 0 ||
           strcmp(buf, "true") == 0 ||
           strcmp(buf, "yes") == 0 ||
           strcmp(buf, "on") == 0 ||
           strcmp(buf, "daemon") == 0;
}

static int load_runner_config(void) {
    const char* config_file = xargs_get("config");
    if (config_file && config_file[0]) {
        if (xargs_load_config(config_file) != 0) {
            fprintf(stderr, "[xnet] config not loaded: %s\n", config_file);
            return -1;
        }
        return 0;
    }

    /* Best-effort default preload so process-level options such as DAEMON can
    ** take effect before Lua starts. Lua scripts may load xnet.cfg again; argv
    ** and already-loaded values keep priority in xargs_load_config(). */
    (void)xargs_load_config("xnet.cfg");
    return 0;
}

static bool daemon_requested(void) {
    const char* daemon_arg = xargs_get("daemon");
    if (daemon_arg) return config_bool_enabled(daemon_arg);
    return config_bool_enabled(xargs_get("DAEMON"));
}

static int l_xthread_stop(lua_State* L) {
    if (lua_gettop(L) >= 1 && !lua_isnil(L, 1)) {
        if (lua_isboolean(L, 1)) {
            g_exit_code = lua_toboolean(L, 1) ? 0 : 1;
        } else if (lua_isnumber(L, 1)) {
            g_exit_code = (int)lua_tointeger(L, 1);
        }
    }

    xlogs("[xnet] stop requested, exit_code=%d", g_exit_code);
    g_running = false;
    return 0;
}

static void unref_if_needed(lua_State* L, int* ref) {
    if (*ref != LUA_NOREF && *ref != LUA_REFNIL) {
        luaL_unref(L, LUA_REGISTRYINDEX, *ref);
    }
    *ref = LUA_NOREF;
}

static void unref_lifecycle(MainLuaData* data) {
    if (!data || !data->L) return;
    unref_if_needed(data->L, &data->sync_handler_ref);
    unref_if_needed(data->L, &data->init_ref);
    unref_if_needed(data->L, &data->update_ref);
    unref_if_needed(data->L, &data->uninit_ref);
}

static void preload_modules(lua_State* L) {
    luaL_requiref(L, "cmsgpack", luaopen_cmsgpack, 1);
    lua_pop(L, 1);

    luaL_requiref(L, "xthread", luaopen_xthread, 1);
    lua_pop(L, 1);

    luaL_requiref(L, "xnet", luaopen_xnet, 1);
    lua_pop(L, 1);

    luaL_requiref(L, "xutils", luaopen_xutils, 1);
    lua_pop(L, 1);

    luaL_requiref(L, "xtimer", luaopen_xtimer, 1);
    lua_pop(L, 1);

    luaL_requiref(L, "xcompress", luaopen_xcompress, 1);
    lua_pop(L, 1);
}

static void install_stop(lua_State* L) {
    lua_getglobal(L, "xthread");
    lua_pushcfunction(L, l_xthread_stop);
    lua_setfield(L, -2, "stop");
    lua_pop(L, 1);
}

static void install_main_reload(MainLuaData* data) {
    lua_State* L = data->L;
    lua_getglobal(L, "xnet");
    if (lua_istable(L, -1)) {
        lua_pushlightuserdata(L, data);
        lua_pushcclosure(L, l_xnet_main_reload, 1);
        lua_setfield(L, -2, "__reload");
    }
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
        xloge("[xnet] xthread.init failed: %s", lua_tostring(L, -1));
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

static int reload_main_script(MainLuaData* data, lua_State* L) {
    if (!data || !L || !g_main_file) {
        lua_pushboolean(L, 0);
        lua_pushstring(L, "xnet.__reload: main runner is not initialized");
        return 2;
    }

    int base = lua_gettop(L);
    xlogs("[xnet] reload main script '%s'", g_main_file);
    if (luaL_dofile(L, g_main_file) != LUA_OK) {
        const char* err = lua_tostring(L, -1);
        char msg[1024];
        snprintf(msg, sizeof(msg), "xnet.__reload: load %s failed: %s",
                 g_main_file, err ? err : "unknown error");
        lua_settop(L, base);
        lua_pushboolean(L, 0);
        lua_pushstring(L, msg);
        return 2;
    }

    if (!lua_istable(L, -1)) {
        lua_settop(L, base);
        lua_pushboolean(L, 0);
        lua_pushfstring(L, "xnet.__reload: %s did not return a table", g_main_file);
        return 2;
    }

    unref_lifecycle(data);
    data->tick_ms = 10;
    ref_lifecycle(data);
    lua_settop(L, base);

    lua_pushboolean(L, 1);
    lua_pushfstring(L, "main reloaded %s", g_main_file);
    return 2;
}

static int l_xnet_main_reload(lua_State* L) {
    MainLuaData* data = (MainLuaData*)lua_touserdata(L, lua_upvalueindex(1));
    return reload_main_script(data, L);
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
    lua_runtime_post_init(L);
    preload_modules(L);
    install_stop(L);
    install_main_reload(data);
    set_runner_globals(L);
    xdebug_attach_state(L, XTHR_MAIN, g_main_file);

    xlogs("[xnet] loading main script '%s'", g_main_file);
    if (luaL_dofile(L, g_main_file) != LUA_OK) {
        xloge("[xnet] load %s failed: %s", g_main_file, lua_tostring(L, -1));
        xdebug_detach_state(L);
        lua_close(L);
        free(data);
        g_exit_code = 1;
        return NULL;
    }

    if (!lua_istable(L, -1)) {
        xloge("[xnet] %s did not return a table", g_main_file);
        xdebug_detach_state(L);
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
            xloge("[xnet] __init failed: %s", lua_tostring(L, -1));
            lua_settop(L, base);
            g_exit_code = 1;
            g_running = false;
        }
    }

    /* Auto-init xpoll if the script started a timer pool but skipped xnet.init.
    ** xpoll gives us a precise sleep-with-wakeup mechanism for the auto-update
    ** loop below. We track this so we balance the teardown ourselves and don't
    ** double-uninit anything the script set up via xnet.init. */
    if (g_running && xtimer_inited() && !xpoll_inited()) {
        if (socket_init() == 0) {
            if (xpoll_init() == 0) {
                xthread_wakeup_init();
            } else {
                socket_cleanup();
            }
        }
    }

    return data;
}

/* Auto-drive xtimer + xpoll. Returns the residual wait that the caller still
** needs to honour (zero if xpoll already slept). */
#define XNET_AUTO_WAIT_CAP 16

static int main_auto_drive(int max_wait_ms) {
    int wait_ms = (max_wait_ms > XNET_AUTO_WAIT_CAP) ? XNET_AUTO_WAIT_CAP : max_wait_ms;
    if (wait_ms < 0) wait_ms = 0;

    if (xtimer_inited()) {
        int next = xtimer_update();
        if (next > 0 && next < wait_ms) wait_ms = next;
        /* next == 0 means heap empty or all timers due; let I/O take the full slice. */
    }

    if (xpoll_inited()) {
        xpoll_poll(wait_ms);
        return 0;
    }
    return wait_ms;
}

static void main_update(MainLuaData* data) {
    if (!data || !data->L) return;
    lua_State* L = data->L;
    xdebug_update_state(L);

    if (data->update_ref != LUA_NOREF) {
        int base = lua_gettop(L);
        lua_rawgeti(L, LUA_REGISTRYINDEX, data->update_ref);
        if (lua_pcall(L, 0, 0, 0) != LUA_OK) {
            xloge("[xnet] __update failed: %s", lua_tostring(L, -1));
            lua_settop(L, base);
            g_exit_code = 1;
            g_running = false;
        }
    }

    int residual = main_auto_drive(data->tick_ms);
    xthread_update(residual);
}

static void main_uninit(MainLuaData* data) {
    if (!data) return;

    if (data->L && data->uninit_ref != LUA_NOREF) {
        lua_State* L = data->L;
        int base = lua_gettop(L);
        lua_rawgeti(L, LUA_REGISTRYINDEX, data->uninit_ref);
        if (lua_pcall(L, 0, 0, 0) != LUA_OK) {
            xloge("[xnet] __uninit failed: %s", lua_tostring(L, -1));
            lua_settop(L, base);
            if (g_exit_code == 0) g_exit_code = 1;
        }
    }

    /* Auto-cleanup any subsystem the script started but forgot to tear down.
    ** Each *_uninit is internally idempotent. */
    if (xtimer_inited()) xtimer_uninit();
    if (xpoll_inited()) {
        xthread_wakeup_uninit();
        xpoll_uninit();
    }

    if (data->L) {
        xdebug_detach_state(data->L);
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
    /* Initialise rpmalloc before ANY other allocation in this process.
    ** rpmalloc_initialize() also registers the calling (main) thread, so
    ** main does not need a separate rpmalloc_thread_initialize(). */
    if (rpmalloc_initialize(NULL) != 0) {
        fprintf(stderr, "[xnet] rpmalloc_initialize failed\n");
        return 1;
    }

    console_set_consolas_font();

    if (argc < 2) {
        fprintf(stderr, "usage: %s <main.lua> [SERVER_NAME=name]\n", argv[0]);
        rpmalloc_finalize();
        return 2;
    }

    g_main_file = argv[1];
    g_script_argc = argc - 2;
    g_script_argv = (argc > 2) ? &argv[2] : NULL;
    xargs_init(g_arg_configs, (int)(sizeof(g_arg_configs) / sizeof(g_arg_configs[0])),
               argc - 1, &argv[1]);
    if (load_runner_config() != 0) {
        xargs_cleanup();
        rpmalloc_finalize();
        return 1;
    }
    g_process_name = xargs_get("SERVER_NAME");
    xdebug_configure(xargs_get("XDEBUG_BOOT"), xargs_get("XDEBUG_PORT"), xargs_get("XDEBUG_WAIT"));

    if (daemon_requested() && xdaemon_daemonize() != 0) {
        fprintf(stderr, "[xnet] daemonize failed\n");
        xargs_cleanup();
        xdebug_shutdown();
        rpmalloc_finalize();
        return 1;
    }

    xlog_init("logs", g_process_name ? g_process_name : "xnet", !xdaemon_is_daemon());

    if (!xthread_init()) {
        xloge("[xnet] xthread_init failed");
        xargs_cleanup();
        xdebug_shutdown();
        xlog_uninit();
        rpmalloc_finalize();
        return 1;
    }

    g_running = true;
    MainLuaData* data = main_init();
    if (!data) {
        xthread_uninit();
        xargs_cleanup();
        xdebug_shutdown();
        xlog_uninit();
        rpmalloc_finalize();
        return g_exit_code ? g_exit_code : 1;
    }

    while (g_running) {
        main_update(data);
    }

    main_uninit(data);
    xthread_uninit();
    xargs_cleanup();
    xdebug_shutdown();
    xlog_uninit();
    rpmalloc_finalize();
    return g_exit_code;
}
