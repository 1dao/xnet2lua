#include "xjs.h"

#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "../3rd/quickjs/quickjs-libc.h"

#include "../xargs.h"
#include "../xdaemon.h"
#include "../xlog.h"
#include "../xpoll.h"
#include "../xsock.h"
#include "../xthread.h"
#include "../xtimer.h"
#include "../xmacro.h"

#ifndef XNET_WITH_HTTP
#define XNET_WITH_HTTP 1
#endif

#ifndef XNET_WITH_HTTPS
#define XNET_WITH_HTTPS 0
#endif

typedef struct MainJSData {
    JSRuntime *rt;
    JSContext *ctx;
    JSValue def;
    JSValue init;
    JSValue update;
    JSValue uninit;
    JSValue thread_handler;
    int tick_ms;
} MainJSData;

static volatile bool g_running = false;
static int g_exit_code = 0;
static const char *g_main_file = NULL;
static int g_script_argc = 0;
static char **g_script_argv = NULL;
static const char *g_process_name = NULL;

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
    { 0,   "REDIS_HOST", NULL, 0 },
    { 0,   "REDIS_PORT", NULL, 0 },
    { 0,   "REDIS_DB", NULL, 0 },
    { 0,   "MYSQL_HOST", NULL, 0 },
    { 0,   "MYSQL_PORT", NULL, 0 },
    { 0,   "MYSQL_USER", NULL, 0 },
    { 0,   "MYSQL_PASSWORD", NULL, 0 },
    { 0,   "MYSQL_DATABASE", NULL, 0 },
};

static JSValue js_xthread_stop(JSContext *ctx, JSValueConst this_val,
                               int argc, JSValueConst *argv) {
    (void)this_val;
    if (argc >= 1 && !JS_IsUndefined(argv[0]) && !JS_IsNull(argv[0])) {
        if (JS_IsBool(argv[0])) {
            int b = JS_ToBool(ctx, argv[0]);
            g_exit_code = b ? 0 : 1;
        } else {
            int32_t code = 0;
            if (JS_ToInt32(ctx, &code, argv[0]) == 0) g_exit_code = code;
        }
    }
    xlogs("[xjs] stop requested, exit_code=%d", g_exit_code);
    g_running = false;
    return JS_UNDEFINED;
}

static JSValue get_func_prop(JSContext *ctx, JSValueConst obj, const char *name) {
    JSValue v = JS_GetPropertyStr(ctx, obj, name);
    if (JS_IsException(v)) return v;
    if (!JS_IsFunction(ctx, v)) {
        JS_FreeValue(ctx, v);
        return JS_UNDEFINED;
    }
    return v;
}

static JSValue get_any_prop(JSContext *ctx, JSValueConst obj,
                            const char *name1, const char *name2) {
    JSValue v = JS_GetPropertyStr(ctx, obj, name1);
    if (JS_IsException(v)) return v;
    if (JS_IsUndefined(v) && name2) {
        JS_FreeValue(ctx, v);
        v = JS_GetPropertyStr(ctx, obj, name2);
    }
    return v;
}

static void free_main_values(MainJSData *data) {
    if (!data || !data->ctx) return;
    JS_FreeValue(data->ctx, data->def);
    JS_FreeValue(data->ctx, data->init);
    JS_FreeValue(data->ctx, data->update);
    JS_FreeValue(data->ctx, data->uninit);
    JS_FreeValue(data->ctx, data->thread_handler);
    data->def = JS_UNDEFINED;
    data->init = JS_UNDEFINED;
    data->update = JS_UNDEFINED;
    data->uninit = JS_UNDEFINED;
    data->thread_handler = JS_UNDEFINED;
}

static void set_runner_globals(JSContext *ctx) {
    JSValue global = JS_GetGlobalObject(ctx);
    JS_SetPropertyStr(ctx, global, "XNET_MAIN_FILE", JS_NewString(ctx, g_main_file));
    JS_SetPropertyStr(ctx, global, "XNET_PROCESS_NAME",
                      g_process_name ? JS_NewString(ctx, g_process_name) : JS_NULL);
    JS_SetPropertyStr(ctx, global, "XNET_WITH_HTTP", JS_NewBool(ctx, XNET_WITH_HTTP ? 1 : 0));
    JS_SetPropertyStr(ctx, global, "XNET_WITH_HTTPS", JS_NewBool(ctx, XNET_WITH_HTTPS ? 1 : 0));

    JSValue arg = JS_NewArray(ctx);
    JS_SetPropertyUint32(ctx, arg, 0, JS_NewString(ctx, g_main_file));
    for (int i = 0; i < g_script_argc; i++) {
        JS_SetPropertyUint32(ctx, arg, (uint32_t)(i + 1), JS_NewString(ctx, g_script_argv[i]));
    }
    JS_SetPropertyStr(ctx, global, "arg", arg);

    JSValue xthread = JS_GetPropertyStr(ctx, global, "xthread");
    if (JS_IsObject(xthread)) {
        JS_SetPropertyStr(ctx, xthread, "stop",
                          JS_NewCFunction(ctx, js_xthread_stop, "stop", 1));
    }
    JS_FreeValue(ctx, xthread);
    JS_FreeValue(ctx, global);
}

static int call_xthread_init(MainJSData *data) {
    if (JS_IsUndefined(data->thread_handler) || JS_IsNull(data->thread_handler)) {
        return 0;
    }
    JSContext *ctx = data->ctx;
    JSValue global = JS_GetGlobalObject(ctx);
    JSValue xthread = JS_GetPropertyStr(ctx, global, "xthread");
    JSValue init = JS_GetPropertyStr(ctx, xthread, "init");
    JSValue ret = JS_Call(ctx, init, xthread, 1, (JSValueConst *)&data->thread_handler);
    JS_FreeValue(ctx, init);
    JS_FreeValue(ctx, xthread);
    JS_FreeValue(ctx, global);
    if (JS_IsException(ret)) {
        xjs_dump_error_with_prefix(ctx, "xthread.init: ");
        return -1;
    }
    JS_FreeValue(ctx, ret);
    return 0;
}

static int extract_lifecycle(MainJSData *data, JSValueConst def) {
    JSContext *ctx = data->ctx;
    data->def = JS_DupValue(ctx, def);
    data->init = get_func_prop(ctx, def, "__init");
    data->update = get_func_prop(ctx, def, "__update");
    data->uninit = get_func_prop(ctx, def, "__uninit");
    data->thread_handler = get_any_prop(ctx, def, "__thread_handle", "threadHandle");
    data->tick_ms = 10;

    JSValue tick = get_any_prop(ctx, def, "__tick_ms", "tickMs");
    if (!JS_IsException(tick) && !JS_IsUndefined(tick) && !JS_IsNull(tick)) {
        int32_t n = 10;
        if (JS_ToInt32(ctx, &n, tick) == 0 && n >= 0) data->tick_ms = n;
    }
    JS_FreeValue(ctx, tick);
    return 0;
}

static MainJSData *main_init(int argc, char **argv) {
    MainJSData *data = (MainJSData *)calloc(1, sizeof(*data));
    if (!data) return NULL;
    data->def = JS_UNDEFINED;
    data->init = JS_UNDEFINED;
    data->update = JS_UNDEFINED;
    data->uninit = JS_UNDEFINED;
    data->thread_handler = JS_UNDEFINED;
    data->tick_ms = 10;

    data->rt = xjs_new_runtime();
    data->ctx = data->rt ? xjs_new_context(data->rt, argc, argv) : NULL;
    if (!data->ctx) {
        free(data);
        return NULL;
    }
    set_runner_globals(data->ctx);
    xjs_xthread_set_thread_ctx(data->ctx);
    xjs_xthread_set_thread_rt(data->rt);   /* enables xthread.spawn on the main thread */

    xlogs("[xjs] loading main script '%s'", g_main_file);
    JSValue def = JS_UNDEFINED;
    if (xjs_eval_file(data->ctx, g_main_file, &def) != 0 || !JS_IsObject(def)) {
        xloge("[xjs] %s did not export a lifecycle object", g_main_file);
        JS_FreeValue(data->ctx, def);
        xjs_free_context(data->ctx);
        js_std_free_handlers(data->rt);
        JS_FreeRuntime(data->rt);
        free(data);
        g_exit_code = 1;
        return NULL;
    }

    extract_lifecycle(data, def);
    JS_FreeValue(data->ctx, def);

    if (call_xthread_init(data) != 0) {
        g_exit_code = 1;
        g_running = false;
    }

    if (!JS_IsUndefined(data->init) && g_running) {
        JSValue ret = JS_Call(data->ctx, data->init, data->def, 0, NULL);
        if (JS_IsException(ret)) {
            xjs_dump_error_with_prefix(data->ctx, "__init: ");
            g_exit_code = 1;
            g_running = false;
        } else {
            JS_FreeValue(data->ctx, ret);
        }
    }

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

#define XNET_AUTO_WAIT_CAP 16

static int main_auto_drive(int max_wait_ms) {
    int wait_ms = (max_wait_ms > XNET_AUTO_WAIT_CAP) ? XNET_AUTO_WAIT_CAP : max_wait_ms;
    if (wait_ms < 0) wait_ms = 0;

    if (xtimer_inited()) {
        int next = xtimer_update();
        if (next > 0 && next < wait_ms) wait_ms = next;
    }
    if (xpoll_inited()) {
        xpoll_poll(wait_ms);
        return 0;
    }
    return wait_ms;
}

static void main_update(MainJSData *data) {
    if (!data || !data->ctx) return;
    if (!JS_IsUndefined(data->update)) {
        JSValue ret = JS_Call(data->ctx, data->update, data->def, 0, NULL);
        if (JS_IsException(ret)) {
            xjs_dump_error_with_prefix(data->ctx, "__update: ");
            g_exit_code = 1;
            g_running = false;
        } else {
            JS_FreeValue(data->ctx, ret);
        }
    }
    if (xjs_run_pending_jobs(data->rt) != 0) {
        g_exit_code = 1;
        g_running = false;
    }
    int residual = main_auto_drive(data->tick_ms);
    xthread_update(residual);
}

static void main_uninit(MainJSData *data) {
    if (!data) return;
    if (data->ctx && !JS_IsUndefined(data->uninit)) {
        JSValue ret = JS_Call(data->ctx, data->uninit, data->def, 0, NULL);
        if (JS_IsException(ret)) {
            xjs_dump_error_with_prefix(data->ctx, "__uninit: ");
            if (g_exit_code == 0) g_exit_code = 1;
        } else {
            JS_FreeValue(data->ctx, ret);
        }
    }

    if (xtimer_inited()) xtimer_uninit();
    if (xpoll_inited()) {
        xthread_wakeup_uninit();
        xpoll_uninit();
    }

    if (data->ctx) {
        xjs_xthread_free_spawned();   /* free actors id>=1 before the default ctx */
        free_main_values(data);
        xThread *thr = xthread_current();
        if (thr) xthread_set_userdata(thr, NULL);
        xjs_free_context(data->ctx);
        xjs_xthread_set_thread_ctx(NULL);
        xjs_xthread_set_thread_rt(NULL);
    }
    if (data->rt) {
        js_std_free_handlers(data->rt);
        JS_FreeRuntime(data->rt);
    }
    free(data);
}

int main(int argc, char **argv) {
    if (rpmalloc_initialize(NULL) != 0) {
        fprintf(stderr, "[xjs] rpmalloc_initialize failed\n");
        return 1;
    }

    console_set_consolas_font();

    if (argc < 2) {
        fprintf(stderr, "usage: %s <main.js|main.mjs> [SERVER_NAME=name]\n", argv[0]);
        rpmalloc_finalize();
        return 2;
    }

    g_main_file = argv[1];
    g_script_argc = argc - 2;
    g_script_argv = (argc > 2) ? &argv[2] : NULL;
    xargs_init(g_arg_configs, (int)(sizeof(g_arg_configs) / sizeof(g_arg_configs[0])),
               argc - 1, &argv[1]);
    g_process_name = xargs_get("SERVER_NAME");
    xlog_init("logs", g_process_name ? g_process_name : "xjs", !xdaemon_is_daemon());

    if (!xthread_init()) {
        xloge("[xjs] xthread_init failed");
        xargs_cleanup();
        xlog_uninit();
        rpmalloc_finalize();
        return 1;
    }

    g_running = true;
    MainJSData *data = main_init(argc, argv);
    if (!data) {
        xthread_uninit();
        xargs_cleanup();
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
    xlog_uninit();
    rpmalloc_finalize();
    return g_exit_code;
}
