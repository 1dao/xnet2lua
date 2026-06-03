#include "xjs.h"
#include "xjs_actor.h"

#include <stdbool.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

#include "../xlog.h"
#include "../xpoll.h"
#include "../xsock.h"
#include "../xthread.h"
#include "../xtimer.h"
#include "../3rd/quickjs/quickjs-libc.h"
#include "../xmacro.h"

#ifndef countof
#define countof(x) ((int)(sizeof(x) / sizeof((x)[0])))
#endif

#if defined(_MSC_VER)
#define XJS_TLS __declspec(thread)
#elif defined(__STDC_VERSION__) && __STDC_VERSION__ >= 201112L
#define XJS_TLS _Thread_local
#else
#define XJS_TLS __thread
#endif

typedef struct XJSThreadData {
    JSRuntime *rt;
    JSContext *ctx;
    char *script_path;
    JSValue def;
    JSValue init;
    JSValue update;
    JSValue uninit;
    JSValue handler;
    int auto_xpoll;
} XJSThreadData;

/* The pool thread's active JS context. L1 routes cross-thread messages to this
** single per-thread context (multi-actor routing is a later layer). */
static XJS_TLS JSContext *g_thread_ctx = NULL;

void xjs_xthread_set_thread_ctx(JSContext *ctx) { g_thread_ctx = ctx; }

static void xthread_message_handler(xThread *thr, void *arg, int arg_len);

static void xjs_xthread_set_handler(JSContext *ctx, JSValueConst handler) {
    XJSActor *a = xjs_actor(ctx);
    if (!a) return;
    if (a->msg_handler_set) JS_FreeValue(ctx, a->msg_handler);
    a->msg_handler = JS_DupValue(ctx, handler);
    a->msg_handler_set = 1;
}

void xjs_xthread_release_context(JSContext *ctx) {
    XJSActor *a = xjs_actor(ctx);
    if (!a || !a->msg_handler_set) return;
    JS_FreeValue(ctx, a->msg_handler);
    a->msg_handler = JS_UNDEFINED;
    a->msg_handler_set = 0;
}

static JSValue get_prop(JSContext *ctx, JSValueConst obj,
                        const char *name, bool want_function) {
    JSValue v = JS_GetPropertyStr(ctx, obj, name);
    if (JS_IsException(v)) return v;
    if (JS_IsUndefined(v) || JS_IsNull(v)) return v;
    if (want_function && !JS_IsFunction(ctx, v)) {
        JS_FreeValue(ctx, v);
        return JS_UNDEFINED;
    }
    return v;
}

static JSValue get_handler_func(JSContext *ctx, JSValueConst handler,
                                const char **names, int name_count) {
    if (JS_IsFunction(ctx, handler)) {
        return JS_DupValue(ctx, handler);
    }
    if (!JS_IsObject(handler)) {
        return JS_UNDEFINED;
    }
    for (int i = 0; i < name_count; i++) {
        JSValue f = get_prop(ctx, handler, names[i], true);
        if (JS_IsException(f)) return f;
        if (!JS_IsUndefined(f)) return f;
        JS_FreeValue(ctx, f);
    }
    return JS_UNDEFINED;
}

static int call_thread_handler(JSContext *ctx, JSValueConst handler,
                               int argc, JSValueConst *argv) {
    const char *names[] = { "__thread_handle", "onMessage", "on_message", "handle" };
    JSValue func = get_handler_func(ctx, handler, names, countof(names));
    if (JS_IsException(func)) return -1;
    if (JS_IsUndefined(func)) {
        JS_FreeValue(ctx, func);
        return 0;
    }
    JSValue ret = JS_Call(ctx, func, handler, argc, argv);
    JS_FreeValue(ctx, func);
    if (JS_IsException(ret)) {
        xjs_dump_error_with_prefix(ctx, "xthread handler: ");
        return -1;
    }
    JS_FreeValue(ctx, ret);
    return 0;
}

static uint32_t array_length(JSContext *ctx, JSValueConst arr) {
    JSValue lenv = JS_GetPropertyStr(ctx, arr, "length");
    uint32_t len = 0;
    JS_ToUint32(ctx, &len, lenv);
    JS_FreeValue(ctx, lenv);
    return len;
}

static void xthread_message_handler(xThread *thr, void *arg, int arg_len) {
    (void)thr;
    JSContext *ctx = g_thread_ctx;
    XJSActor *a = ctx ? xjs_actor(ctx) : NULL;
    if (!a || !a->msg_handler_set || !arg || arg_len <= 0) return;

    JSValue parsed = xjs_call_json_parse(ctx, (const char *)arg, (size_t)arg_len);
    if (JS_IsException(parsed)) {
        xjs_dump_error_with_prefix(ctx, "xthread message parse: ");
        return;
    }

    if (JS_IsArray(parsed)) {
        uint32_t len = array_length(ctx, parsed);
        JSValue *argv = len ? (JSValue *)malloc(sizeof(JSValue) * len) : NULL;
        if (len && !argv) {
            JS_FreeValue(ctx, parsed);
            return;
        }
        for (uint32_t i = 0; i < len; i++) {
            argv[i] = JS_GetPropertyUint32(ctx, parsed, i);
        }
        call_thread_handler(ctx, a->msg_handler, (int)len, (JSValueConst *)argv);
        for (uint32_t i = 0; i < len; i++) JS_FreeValue(ctx, argv[i]);
        free(argv);
    } else {
        call_thread_handler(ctx, a->msg_handler, 1, &parsed);
    }
    JS_FreeValue(ctx, parsed);
}

static JSValue js_xthread_init(JSContext *ctx, JSValueConst this_val,
                               int argc, JSValueConst *argv) {
    (void)this_val;
    if (!xthread_init()) {
        return JS_ThrowInternalError(ctx, "xthread.init: xthread_init failed");
    }
    if (argc >= 1 && !JS_IsUndefined(argv[0]) && !JS_IsNull(argv[0])) {
        if (!JS_IsFunction(ctx, argv[0]) && !JS_IsObject(argv[0])) {
            return JS_ThrowTypeError(ctx, "xthread.init: handler must be a function or object");
        }
        xjs_xthread_set_handler(ctx, argv[0]);
    }
    return JS_TRUE;
}

static JSValue js_xthread_post(JSContext *ctx, JSValueConst this_val,
                               int argc, JSValueConst *argv) {
    (void)this_val;
    if (argc < 2) {
        return JS_ThrowTypeError(ctx, "xthread.post: target_id and message expected");
    }
    int32_t target_id = 0;
    if (JS_ToInt32(ctx, &target_id, argv[0]) < 0) return JS_EXCEPTION;

    JSValue arr = JS_NewArray(ctx);
    if (JS_IsException(arr)) return arr;
    for (int i = 1; i < argc; i++) {
        if (JS_SetPropertyUint32(ctx, arr, (uint32_t)(i - 1),
                                 JS_DupValue(ctx, argv[i])) < 0) {
            JS_FreeValue(ctx, arr);
            return JS_EXCEPTION;
        }
    }
    JSValue json = xjs_call_json_stringify(ctx, arr);
    JS_FreeValue(ctx, arr);
    if (JS_IsException(json)) return json;
    if (JS_IsUndefined(json)) {
        JS_FreeValue(ctx, json);
        return JS_ThrowTypeError(ctx, "xthread.post: message is not JSON serializable");
    }

    size_t len = 0;
    const char *data = JS_ToCStringLen(ctx, &len, json);
    if (!data) {
        JS_FreeValue(ctx, json);
        return JS_EXCEPTION;
    }
    int rc = xthread_post(target_id, xthread_message_handler, data, len);
    JS_FreeCString(ctx, data);
    JS_FreeValue(ctx, json);
    if (rc == 0) return JS_TRUE;
    if (rc == -2) return JS_FALSE;
    return JS_ThrowInternalError(ctx, "xthread.post failed: %d", rc);
}

static JSValue js_xthread_set_queue_max(JSContext *ctx, JSValueConst this_val,
                                        int argc, JSValueConst *argv) {
    (void)this_val;
    int32_t target_id = 0;
    int32_t max_size = 0;
    if (argc < 2) {
        return JS_ThrowTypeError(ctx, "xthread.setQueueMax: id and max expected");
    }
    if (JS_ToInt32(ctx, &target_id, argv[0]) < 0) return JS_EXCEPTION;
    if (JS_ToInt32(ctx, &max_size, argv[1]) < 0) return JS_EXCEPTION;
    return JS_NewBool(ctx, xthread_set_queue_max(target_id, max_size) == 0);
}

static JSValue thread_stats_object(JSContext *ctx, int id) {
    JSValue obj = JS_NewObject(ctx);
    if (JS_IsException(obj)) return obj;
    xjs_set_i32_prop(ctx, obj, "id", id);
    int depth = xthread_get_queue_depth(id);
    int max = xthread_get_queue_max(id);
    xjs_set_i32_prop(ctx, obj, "queueDepth", depth < 0 ? 0 : depth);
    xjs_set_i32_prop(ctx, obj, "queueMax", max < 0 ? 0 : max);
    xjs_set_bool_prop(ctx, obj, "registered", xthread_get(id) != NULL);
    return obj;
}

static JSValue js_xthread_stats(JSContext *ctx, JSValueConst this_val,
                                int argc, JSValueConst *argv) {
    (void)this_val;
    int32_t id = xthread_current_id();
    if (argc >= 1 && JS_ToInt32(ctx, &id, argv[0]) < 0) return JS_EXCEPTION;
    return thread_stats_object(ctx, id);
}

static JSValue js_xthread_all_stats(JSContext *ctx, JSValueConst this_val,
                                    int argc, JSValueConst *argv) {
    (void)this_val;
    (void)argc;
    (void)argv;
    JSValue arr = JS_NewArray(ctx);
    if (JS_IsException(arr)) return arr;
    uint32_t n = 0;
    for (int id = 1; id < XTHR_MAX; id++) {
        if (!xthread_get(id)) continue;
        JS_SetPropertyUint32(ctx, arr, n++, thread_stats_object(ctx, id));
    }
    return arr;
}

static JSValue js_xthread_current_id(JSContext *ctx, JSValueConst this_val,
                                     int argc, JSValueConst *argv) {
    (void)this_val;
    (void)argc;
    (void)argv;
    return JS_NewInt32(ctx, xthread_current_id());
}

static void td_free_values(XJSThreadData *td) {
    if (!td || !td->ctx) return;
    JS_FreeValue(td->ctx, td->def);
    JS_FreeValue(td->ctx, td->init);
    JS_FreeValue(td->ctx, td->update);
    JS_FreeValue(td->ctx, td->uninit);
    JS_FreeValue(td->ctx, td->handler);
    td->def = JS_UNDEFINED;
    td->init = JS_UNDEFINED;
    td->update = JS_UNDEFINED;
    td->uninit = JS_UNDEFINED;
    td->handler = JS_UNDEFINED;
}

static void td_init_values(XJSThreadData *td) {
    td->def = JS_UNDEFINED;
    td->init = JS_UNDEFINED;
    td->update = JS_UNDEFINED;
    td->uninit = JS_UNDEFINED;
    td->handler = JS_UNDEFINED;
}

static void extract_lifecycle(XJSThreadData *td, JSValueConst def) {
    JSContext *ctx = td->ctx;
    td->def = JS_DupValue(ctx, def);
    td->init = get_prop(ctx, def, "__init", true);
    td->update = get_prop(ctx, def, "__update", true);
    td->uninit = get_prop(ctx, def, "__uninit", true);
    td->handler = get_prop(ctx, def, "__thread_handle", false);
    if (JS_IsUndefined(td->handler)) {
        JS_FreeValue(ctx, td->handler);
        td->handler = get_prop(ctx, def, "threadHandle", false);
    }
}

static void xjs_thread_on_init(xThread *thr) {
    XJSThreadData *td = (XJSThreadData *)xthread_get_userdata(thr);
    if (!td) return;

    char *argv[2] = { (char *)"xjs-thread", td->script_path };
    td->rt = xjs_new_runtime();
    td->ctx = td->rt ? xjs_new_context(td->rt, 2, argv) : NULL;
    if (!td->ctx) {
        xloge("xjs thread %d: create JS context failed", xthread_get_id(thr));
        return;
    }
    g_thread_ctx = td->ctx;
    td_init_values(td);

    JSValue def = JS_UNDEFINED;
    if (xjs_eval_file(td->ctx, td->script_path, &def) != 0 || !JS_IsObject(def)) {
        xloge("xjs thread %d: %s did not export a lifecycle object",
              xthread_get_id(thr), td->script_path);
        JS_FreeValue(td->ctx, def);
        return;
    }
    extract_lifecycle(td, def);
    JS_FreeValue(td->ctx, def);

    if (!JS_IsUndefined(td->handler) && !JS_IsNull(td->handler)) {
        xjs_xthread_set_handler(td->ctx, td->handler);
    }

    if (!JS_IsUndefined(td->init)) {
        JSValue ret = JS_Call(td->ctx, td->init, td->def, 0, NULL);
        if (JS_IsException(ret)) {
            xjs_dump_error_with_prefix(td->ctx, "xjs thread __init: ");
        } else {
            JS_FreeValue(td->ctx, ret);
        }
    }

    if (xtimer_inited() && !xpoll_inited()) {
        if (socket_init() == 0) {
            if (xpoll_init() == 0) {
                xthread_wakeup_init();
                td->auto_xpoll = 1;
            } else {
                socket_cleanup();
            }
        }
    }
}

static void xjs_thread_on_update(xThread *thr) {
    XJSThreadData *td = (XJSThreadData *)xthread_get_userdata(thr);
    if (!td || !td->ctx) return;

    if (!JS_IsUndefined(td->update)) {
        JSValue ret = JS_Call(td->ctx, td->update, td->def, 0, NULL);
        if (JS_IsException(ret)) {
            xjs_dump_error_with_prefix(td->ctx, "xjs thread __update: ");
        } else {
            JS_FreeValue(td->ctx, ret);
        }
    }
    xjs_run_pending_jobs(td->rt);

    int wait_ms = 16;
    if (xtimer_inited()) {
        int next = xtimer_update();
        if (next > 0 && next < wait_ms) wait_ms = next;
    }
    if (xpoll_inited()) {
        xpoll_poll(wait_ms);
    }
}

static void xjs_thread_on_cleanup(xThread *thr) {
    XJSThreadData *td = (XJSThreadData *)xthread_get_userdata(thr);
    if (!td) return;

    if (td->ctx && !JS_IsUndefined(td->uninit)) {
        JSValue ret = JS_Call(td->ctx, td->uninit, td->def, 0, NULL);
        if (JS_IsException(ret)) {
            xjs_dump_error_with_prefix(td->ctx, "xjs thread __uninit: ");
        } else {
            JS_FreeValue(td->ctx, ret);
        }
    }

    if (xtimer_inited()) xtimer_uninit();
    if (td->auto_xpoll) {
        xthread_wakeup_uninit();
        xpoll_uninit();
        socket_cleanup();
        td->auto_xpoll = 0;
    }

    if (td->ctx) {
        td_free_values(td);
        g_thread_ctx = NULL;
        xjs_free_context(td->ctx);
        td->ctx = NULL;
    }
    if (td->rt) {
        js_std_free_handlers(td->rt);
        JS_FreeRuntime(td->rt);
        td->rt = NULL;
    }
    free(td->script_path);
    td->script_path = NULL;
    xthread_set_userdata(thr, NULL);
    free(td);
}

static JSValue js_xthread_create_thread(JSContext *ctx, JSValueConst this_val,
                                        int argc, JSValueConst *argv) {
    (void)this_val;
    if (!xthread_init()) {
        return JS_ThrowInternalError(ctx, "xthread.createThread: xthread_init failed");
    }
    if (argc < 3) {
        return JS_ThrowTypeError(ctx, "xthread.createThread: id, name and scriptPath expected");
    }
    int32_t id = 0;
    if (JS_ToInt32(ctx, &id, argv[0]) < 0) return JS_EXCEPTION;
    const char *name = JS_ToCString(ctx, argv[1]);
    const char *script = JS_ToCString(ctx, argv[2]);
    if (!name || !script) {
        JS_FreeCString(ctx, name);
        JS_FreeCString(ctx, script);
        return JS_EXCEPTION;
    }

    XJSThreadData *td = (XJSThreadData *)calloc(1, sizeof(*td));
    if (!td) {
        JS_FreeCString(ctx, name);
        JS_FreeCString(ctx, script);
        return JS_ThrowOutOfMemory(ctx);
    }
    td->script_path = (char *)malloc(strlen(script) + 1);
    if (!td->script_path) {
        free(td);
        JS_FreeCString(ctx, name);
        JS_FreeCString(ctx, script);
        return JS_ThrowOutOfMemory(ctx);
    }
    strcpy(td->script_path, script);

    bool ok = xthread_register_ex(id, name, xjs_thread_on_init,
                                  xjs_thread_on_update,
                                  xjs_thread_on_cleanup, td);
    JS_FreeCString(ctx, name);
    JS_FreeCString(ctx, script);
    if (!ok) {
        free(td->script_path);
        free(td);
        return JS_FALSE;
    }
    return JS_TRUE;
}

static JSValue js_xthread_shutdown_thread(JSContext *ctx, JSValueConst this_val,
                                          int argc, JSValueConst *argv) {
    (void)this_val;
    if (argc < 1) {
        return JS_ThrowTypeError(ctx, "xthread.shutdownThread: id expected");
    }
    int32_t id = 0;
    if (JS_ToInt32(ctx, &id, argv[0]) < 0) return JS_EXCEPTION;
    if (!xthread_get(id)) return JS_FALSE;
    xthread_unregister(id);
    return JS_TRUE;
}

static const char *level_name(int level) {
    switch (level) {
    case XLOG_LEVEL_VERBOSE: return XLOG_LEVEL_NAME_VERBOSE;
    case XLOG_LEVEL_DEBUG: return XLOG_LEVEL_NAME_DEBUG;
    case XLOG_LEVEL_INFO: return XLOG_LEVEL_NAME_INFO;
    case XLOG_LEVEL_SYSM: return XLOG_LEVEL_NAME_SYSM;
    case XLOG_LEVEL_WARN: return XLOG_LEVEL_NAME_WARN;
    case XLOG_LEVEL_ERROR: return XLOG_LEVEL_NAME_ERROR;
    case XLOG_LEVEL_FATAL: return XLOG_LEVEL_NAME_FATAL;
    default: return XLOG_LEVEL_NAME_INFO;
    }
}

static const char *level_tag(int level) {
    switch (level) {
    case XLOG_LEVEL_VERBOSE: return XLOG_TAG_VERBOSE;
    case XLOG_LEVEL_DEBUG: return XLOG_TAG_DEBUG;
    case XLOG_LEVEL_INFO: return XLOG_TAG_INFO;
    case XLOG_LEVEL_SYSM: return XLOG_TAG_SYSM;
    case XLOG_LEVEL_WARN: return XLOG_TAG_WARN;
    case XLOG_LEVEL_ERROR: return XLOG_TAG_ERROR;
    case XLOG_LEVEL_FATAL: return XLOG_TAG_FATAL;
    default: return XLOG_TAG_INFO;
    }
}

static JSValue js_xthread_log_magic(JSContext *ctx, JSValueConst this_val,
                                    int argc, JSValueConst *argv, int magic) {
    (void)this_val;
    if (!xlog_is_enabled(magic)) return JS_TRUE;
    size_t cap = 1;
    char *msg = (char *)malloc(cap);
    if (!msg) return JS_ThrowOutOfMemory(ctx);
    msg[0] = '\0';
    size_t len = 0;

    for (int i = 0; i < argc; i++) {
        size_t part_len = 0;
        const char *part = JS_ToCStringLen(ctx, &part_len, argv[i]);
        if (!part) {
            free(msg);
            return JS_EXCEPTION;
        }
        size_t add = part_len + (i > 0 ? 1 : 0);
        char *next = (char *)realloc(msg, len + add + 1);
        if (!next) {
            JS_FreeCString(ctx, part);
            free(msg);
            return JS_ThrowOutOfMemory(ctx);
        }
        msg = next;
        if (i > 0) msg[len++] = '\t';
        memcpy(msg + len, part, part_len);
        len += part_len;
        msg[len] = '\0';
        JS_FreeCString(ctx, part);
    }

    xlog_write(magic, level_name(magic), level_tag(magic), msg, len, 1);
    free(msg);
    return JS_TRUE;
}

static JSValue js_xthread_log_enabled(JSContext *ctx, JSValueConst this_val,
                                      int argc, JSValueConst *argv) {
    (void)this_val;
    int32_t level = XLOG_LEVEL_INFO;
    if (argc >= 1 && JS_ToInt32(ctx, &level, argv[0]) < 0) return JS_EXCEPTION;
    return JS_NewBool(ctx, xlog_is_enabled(level) != 0);
}

static JSValue js_xthread_set_level(JSContext *ctx, JSValueConst this_val,
                                    int argc, JSValueConst *argv) {
    (void)this_val;
    int32_t level = XLOG_LEVEL_INFO;
    if (argc >= 1 && JS_ToInt32(ctx, &level, argv[0]) < 0) return JS_EXCEPTION;
    xlog_set_level(level);
    return JS_TRUE;
}

static JSValue js_xthread_get_level(JSContext *ctx, JSValueConst this_val,
                                    int argc, JSValueConst *argv) {
    (void)this_val;
    (void)argc;
    (void)argv;
    return JS_NewInt32(ctx, xlog_get_level());
}

static JSValue js_xthread_rpc(JSContext *ctx, JSValueConst this_val,
                              int argc, JSValueConst *argv) {
    (void)this_val;
    (void)argc;
    (void)argv;
    return JS_ThrowInternalError(ctx, "xthread.rpc is not implemented in xjs yet");
}

static const JSCFunctionListEntry xthread_funcs[] = {
    JS_CFUNC_DEF("init", 1, js_xthread_init),
    JS_CFUNC_DEF("post", 2, js_xthread_post),
    JS_CFUNC_DEF("rpc", 3, js_xthread_rpc),
    JS_CFUNC_DEF("setQueueMax", 2, js_xthread_set_queue_max),
    JS_CFUNC_DEF("set_queue_max", 2, js_xthread_set_queue_max),
    JS_CFUNC_DEF("stats", 1, js_xthread_stats),
    JS_CFUNC_DEF("allStats", 0, js_xthread_all_stats),
    JS_CFUNC_DEF("all_stats", 0, js_xthread_all_stats),
    JS_CFUNC_DEF("currentId", 0, js_xthread_current_id),
    JS_CFUNC_DEF("current_id", 0, js_xthread_current_id),
    JS_CFUNC_DEF("createThread", 3, js_xthread_create_thread),
    JS_CFUNC_DEF("create_thread", 3, js_xthread_create_thread),
    JS_CFUNC_DEF("shutdownThread", 1, js_xthread_shutdown_thread),
    JS_CFUNC_DEF("shutdown_thread", 1, js_xthread_shutdown_thread),
    JS_CFUNC_DEF("logEnabled", 1, js_xthread_log_enabled),
    JS_CFUNC_DEF("setLevel", 1, js_xthread_set_level),
    JS_CFUNC_DEF("setLogLevel", 1, js_xthread_set_level),
    JS_CFUNC_DEF("getLevel", 0, js_xthread_get_level),
    JS_CFUNC_DEF("getLogLevel", 0, js_xthread_get_level),
    JS_CFUNC_MAGIC_DEF("logVerbose", 1, js_xthread_log_magic, XLOG_LEVEL_VERBOSE),
    JS_CFUNC_MAGIC_DEF("logDebug", 1, js_xthread_log_magic, XLOG_LEVEL_DEBUG),
    JS_CFUNC_MAGIC_DEF("logInfo", 1, js_xthread_log_magic, XLOG_LEVEL_INFO),
    JS_CFUNC_MAGIC_DEF("logSystem", 1, js_xthread_log_magic, XLOG_LEVEL_SYSM),
    JS_CFUNC_MAGIC_DEF("logWarn", 1, js_xthread_log_magic, XLOG_LEVEL_WARN),
    JS_CFUNC_MAGIC_DEF("logError", 1, js_xthread_log_magic, XLOG_LEVEL_ERROR),
    JS_CFUNC_MAGIC_DEF("logFatal", 1, js_xthread_log_magic, XLOG_LEVEL_FATAL),
    JS_CFUNC_MAGIC_DEF("log_verbose", 1, js_xthread_log_magic, XLOG_LEVEL_VERBOSE),
    JS_CFUNC_MAGIC_DEF("log_debug", 1, js_xthread_log_magic, XLOG_LEVEL_DEBUG),
    JS_CFUNC_MAGIC_DEF("log_info", 1, js_xthread_log_magic, XLOG_LEVEL_INFO),
    JS_CFUNC_MAGIC_DEF("log_system", 1, js_xthread_log_magic, XLOG_LEVEL_SYSM),
    JS_CFUNC_MAGIC_DEF("log_warn", 1, js_xthread_log_magic, XLOG_LEVEL_WARN),
    JS_CFUNC_MAGIC_DEF("log_error", 1, js_xthread_log_magic, XLOG_LEVEL_ERROR),
    JS_CFUNC_MAGIC_DEF("log_fatal", 1, js_xthread_log_magic, XLOG_LEVEL_FATAL),
    JS_PROP_INT32_DEF("MAIN", XTHR_MAIN, JS_PROP_ENUMERABLE),
    JS_PROP_INT32_DEF("REDIS", XTHR_REDIS, JS_PROP_ENUMERABLE),
    JS_PROP_INT32_DEF("MYSQL", XTHR_MYSQL, JS_PROP_ENUMERABLE),
    JS_PROP_INT32_DEF("LOG", XTHR_LOG, JS_PROP_ENUMERABLE),
    JS_PROP_INT32_DEF("IO", XTHR_IO, JS_PROP_ENUMERABLE),
    JS_PROP_INT32_DEF("COMPUTE", XTHR_COMPUTE, JS_PROP_ENUMERABLE),
    JS_PROP_INT32_DEF("NATS", XTHR_NATS, JS_PROP_ENUMERABLE),
    JS_PROP_INT32_DEF("HTTP", XTHR_HTTP, JS_PROP_ENUMERABLE),
    JS_PROP_INT32_DEF("WORKER_GRP1", XTHR_WORKER_GRP1, JS_PROP_ENUMERABLE),
    JS_PROP_INT32_DEF("WORKER_GRP2", XTHR_WORKER_GRP2, JS_PROP_ENUMERABLE),
    JS_PROP_INT32_DEF("WORKER_GRP3", XTHR_WORKER_GRP3, JS_PROP_ENUMERABLE),
    JS_PROP_INT32_DEF("WORKER_GRP4", XTHR_WORKER_GRP4, JS_PROP_ENUMERABLE),
    JS_PROP_INT32_DEF("WORKER_GRP5", XTHR_WORKER_GRP5, JS_PROP_ENUMERABLE),
    JS_PROP_INT32_DEF("LOG_VERBOSE", XLOG_LEVEL_VERBOSE, JS_PROP_ENUMERABLE),
    JS_PROP_INT32_DEF("LOG_DEBUG", XLOG_LEVEL_DEBUG, JS_PROP_ENUMERABLE),
    JS_PROP_INT32_DEF("LOG_INFO", XLOG_LEVEL_INFO, JS_PROP_ENUMERABLE),
    JS_PROP_INT32_DEF("LOG_SYSTEM", XLOG_LEVEL_SYSM, JS_PROP_ENUMERABLE),
    JS_PROP_INT32_DEF("LOG_WARN", XLOG_LEVEL_WARN, JS_PROP_ENUMERABLE),
    JS_PROP_INT32_DEF("LOG_ERROR", XLOG_LEVEL_ERROR, JS_PROP_ENUMERABLE),
    JS_PROP_INT32_DEF("LOG_FATAL", XLOG_LEVEL_FATAL, JS_PROP_ENUMERABLE),
};

JSValue xjs_new_xthread_object(JSContext *ctx) {
    JSValue obj = JS_NewObject(ctx);
    if (JS_IsException(obj)) return obj;
    JS_SetPropertyFunctionList(ctx, obj, xthread_funcs, countof(xthread_funcs));
    return obj;
}

static int js_xthread_module_init(JSContext *ctx, JSModuleDef *m) {
    if (JS_SetModuleExportList(ctx, m, xthread_funcs, countof(xthread_funcs)) < 0) {
        return -1;
    }
    JS_SetModuleExport(ctx, m, "default", xjs_new_xthread_object(ctx));
    return 0;
}

JSModuleDef *js_init_module_xthread(JSContext *ctx, const char *module_name) {
    JSModuleDef *m = JS_NewCModule(ctx, module_name, js_xthread_module_init);
    if (!m) return NULL;
    JS_AddModuleExportList(ctx, m, xthread_funcs, countof(xthread_funcs));
    JS_AddModuleExport(ctx, m, "default");
    return m;
}
