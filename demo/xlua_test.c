/* demo/xlua_test.c - Test xthread Lua bindings (RPC and POST)
**
** This test creates two OS threads (MAIN + COMPUTE), initializes Lua in both,
** and tests cross-thread message passing:
**   1. Fire-and-forget POST from MAIN to COMPUTE
**   2. RPC from MAIN to COMPUTE (with result return)
**   3. RPC from COMPUTE to MAIN (with result return)
**
** Uses embedded minilua.h (single-file Lua 5.5) from 3rd/minilua.h
*/

#define LUA_EMBEDDED
#define LUA_IMPL
#include "3rd/minilua.h"

#include <stdio.h>
#include <stdlib.h>
#include <stdbool.h>

/* cmsgpack is statically linked */
LUA_API int luaopen_cmsgpack(lua_State *L);

#include "xthread.h"
#include "xlog.h"
#include "xthread_lua.h"
#include "xargs.h"

/* Per-thread Lua state data */
typedef struct {
    lua_State* L;
} ThreadLuaData;

/* COMPUTE thread on_init - runs Lua initialization */
static void compute_on_init(xThread* thr) {
    XLOGI("[compute] on_init starting");

    ThreadLuaData* data = (ThreadLuaData*)malloc(sizeof(ThreadLuaData));
    if (!data) {
        XLOGE("[compute] malloc failed");
        return;
    }

    /* Create new Lua state */
    data->L = luaL_newstate();
    if (!data->L) {
        XLOGE("[compute] luaL_newstate failed");
        free(data);
        return;
    }

    /* Open standard libraries */
    luaL_openlibs(data->L);

    /* Preload cmsgpack (statically linked) */
    luaL_requiref(data->L, "cmsgpack", luaopen_cmsgpack, 1);
    lua_pop(data->L, 1);

    /* Open xthread module */
    luaL_requiref(data->L, "xthread", luaopen_xthread, 1);
    lua_pop(data->L, 1);

    /* Run the compute script from file - this defines __thread_handle__ globally */
    if (luaL_dofile(data->L, "xlua_thread.lua") != LUA_OK) {
        XLOGE("[compute] Failed to run script: %s", lua_tostring(data->L, -1));
        lua_close(data->L);
        free(data);
        return;
    }

    /* Call xthread.init with nil handler - it will find the global __thread_handle__ we just defined */
    lua_getglobal(data->L, "xthread");
    lua_getfield(data->L, -1, "init");
    if (lua_pcall(data->L, 0, 0, 0) != LUA_OK) {
        XLOGE("[compute] xthread.init failed: %s", lua_tostring(data->L, -1));
        lua_close(data->L);
        free(data);
        return;
    }
    lua_pop(data->L, 1); /* pop xtable */

    xthread_set_userdata(thr, data);
    XLOGI("[compute] on_init complete");
}

/* COMPUTE thread on_cleanup */
static void compute_on_cleanup(xThread* thr) {
    XLOGI("[compute] on_cleanup");
    ThreadLuaData* data = (ThreadLuaData*)xthread_get_userdata(thr);
    if (data) {
        if (data->L) {
            lua_close(data->L);
        }
        free(data);
    }
}

/* COMPUTE thread on_update - process pending messages */
static void compute_on_update(xThread* thr) {
    /* Process all queued messages */
    xthread_update(0);
}

/* Main thread init */
static ThreadLuaData* main_init(void) {
    XLOGI("[main] initializing Lua");

    ThreadLuaData* data = (ThreadLuaData*)malloc(sizeof(ThreadLuaData));
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

    luaL_openlibs(data->L);

    /* Preload cmsgpack (statically linked) */
    luaL_requiref(data->L, "cmsgpack", luaopen_cmsgpack, 1);
    lua_pop(data->L, 1);

    /* Open xthread module */
    luaL_requiref(data->L, "xthread", luaopen_xthread, 1);
    lua_pop(data->L, 1);

    /* Run main script from file - this defines __thread_handle__ globally */
    if (luaL_dofile(data->L, "xlua_main.lua") != LUA_OK) {
        XLOGE("[main] Failed to run main script: %s", lua_tostring(data->L, -1));
        lua_close(data->L);
        free(data);
        return NULL;
    }

    /* Call xthread.init with nil handler - it will find the global __thread_handle__ we just defined */
    lua_getglobal(data->L, "xthread");
    lua_getfield(data->L, -1, "init");
    if (lua_pcall(data->L, 0, 0, 0) != LUA_OK) {
        XLOGE("[main] xthread.init failed: %s", lua_tostring(data->L, -1));
        lua_close(data->L);
        free(data);
        return NULL;
    }
    lua_pop(data->L, 1);

    XLOGI("[main] Lua initialized");
    return data;
}

int main(int argc, char** argv) {
    (void)argc;
    (void)argv;
    console_set_consolas_font();

    XLOGI("Starting xthread Lua test");

    /* Initialize xthread */
    if (!xthread_init()) {
        XLOGE("xthread_init failed");
        return 1;
    }

    /* Register COMPUTE thread with our init/update/cleanup callbacks */
    if (!xthread_register(XTHR_COMPUTE, "compute-lua",
        compute_on_init, compute_on_update, compute_on_cleanup)) {
        XLOGE("Failed to register COMPUTE thread");
        xthread_uninit();
        return 1;
    }

    /* Initialize main thread Lua */
    ThreadLuaData* main_data = main_init();
    if (!main_data) {
        XLOGE("Main Lua init failed");
        xthread_unregister(XTHR_COMPUTE);
        xthread_uninit();
        return 1;
    }

    /* Let the COMPUTE thread initialize */
    XLOGI("Waiting for COMPUTE thread to initialize...");
    for (int i = 0; i < 50; i++) {
        xthread_update(10); /* process tasks */
    }

    /* Kick off tests from Lua - this dispatches all RPCs */
    XLOGI("Starting tests from main thread");
    lua_getglobal(main_data->L, "run_tests");
    if (lua_pcall(main_data->L, 0, 0, 0) != LUA_OK) {
        XLOGE("run_tests failed: %s", lua_tostring(main_data->L, -1));
    }

    /* Event loop - process all pending messages */
    /* We need to keep pumping because RPC replies come back through xthread */
    int pending = 1;
    int max_iter = 1000;
    bool all_processed = false;
    for (int i = 0; i < max_iter; i++) {
        pending = xthread_update(10);
        if (pending == 0) {
            /* Check if all done - give more iterations for safety */
            if (i > 200) {
                all_processed = true;
                break;
            }
        }
    }

    /* Final pump to make sure everything is processed */
    for (int i = 0; i < 50; i++) {
        xthread_update(10);
    }

    /* Check and print results */
    bool test_passed = false;
    lua_getglobal(main_data->L, "check_results");
    if (lua_pcall(main_data->L, 0, 1, 0) != LUA_OK) {
        XLOGE("check_results failed: %s", lua_tostring(main_data->L, -1));
    } else {
        test_passed = lua_toboolean(main_data->L, -1);
        lua_pop(main_data->L, 1);
    }

    /* Cleanup */
    XLOGI("Shutting down...");
    xthread_unregister(XTHR_COMPUTE);

    if (main_data->L) {
        lua_close(main_data->L);
    }
    free(main_data);

    xthread_uninit();

    if (!all_processed) {
        XLOGW("Some tasks were still pending when timeout reached");
    }

    if (test_passed && all_processed) {
        XLOGI("✅ All tests passed!");
        return 0;
    } else {
        XLOGE("❌ Test failed or timed out");
        return 1;
    }
}
