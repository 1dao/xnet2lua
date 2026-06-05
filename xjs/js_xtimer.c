#include "xjs.h"
#include "xjs_actor.h"

#include <stdint.h>
#include <stdlib.h>
#include <string.h>

#include "../xtimer.h"

#ifndef countof
#define countof(x) ((int)(sizeof(x) / sizeof((x)[0])))
#endif

typedef struct XJSTimer {
    JSContext *ctx;
    xtimerHandler handle;
    JSValue callback;
    JSValue self;
    int repeat_remaining;
    struct XJSTimer *prev;
    struct XJSTimer *next;
} XJSTimer;

#if defined(_MSC_VER)
#define XJS_TLS __declspec(thread)
#elif defined(__STDC_VERSION__) && __STDC_VERSION__ >= 201112L
#define XJS_TLS _Thread_local
#else
#define XJS_TLS __thread
#endif

static XJS_TLS int g_xtimer_refs = 0;

static void timer_list_add(XJSActor *a, XJSTimer *t) {
    t->prev = NULL;
    t->next = a->timers;
    if (a->timers) a->timers->prev = t;
    a->timers = t;
}

static void timer_list_remove(XJSActor *a, XJSTimer *t) {
    if (t->prev) t->prev->next = t->next;
    else if (a && a->timers == t) a->timers = t->next;
    if (t->next) t->next->prev = t->prev;
    t->prev = NULL;
    t->next = NULL;
}

static void timer_release_ctx(XJSTimer *t, int cancel_c_timer) {
    if (!t || !t->ctx) return;
    JSContext *ctx = t->ctx;

    if (cancel_c_timer && t->handle) {
        xtimer_del(t->handle);
    }
    t->handle = NULL;
    timer_list_remove(xjs_actor(t->ctx), t);

    JSValue cb = t->callback;
    JSValue self = t->self;
    t->callback = JS_UNDEFINED;
    t->self = JS_UNDEFINED;
    JS_FreeValue(ctx, cb);
    JS_FreeValue(ctx, self);
}

static void xjs_timer_finalizer(JSRuntime *rt, JSValueConst val) {
    XJSTimer *t = (XJSTimer *)JS_GetOpaque(val, g_xjs_timer_class_id);
    if (!t) return;
    if (t->handle) {
        xtimer_del(t->handle);
        t->handle = NULL;
    }
    if (t->ctx) timer_list_remove(xjs_actor(t->ctx), t);
    if (!JS_IsUndefined(t->callback)) {
        JS_FreeValueRT(rt, t->callback);
    }
    js_free_rt(rt, t);
}

static void xjs_timer_mark(JSRuntime *rt, JSValueConst val, JS_MarkFunc *mark_func) {
    XJSTimer *t = (XJSTimer *)JS_GetOpaque(val, g_xjs_timer_class_id);
    if (!t) return;
    JS_MarkValue(rt, t->callback, mark_func);
}

static XJSTimer *xjs_timer_get(JSContext *ctx, JSValueConst val) {
    return (XJSTimer *)JS_GetOpaque2(ctx, val, g_xjs_timer_class_id);
}

static JSValue js_timer_del(JSContext *ctx, JSValueConst this_val,
                            int argc, JSValueConst *argv) {
    (void)argc;
    (void)argv;
    XJSTimer *t = xjs_timer_get(ctx, this_val);
    if (!t) return JS_EXCEPTION;
    timer_release_ctx(t, 1);
    return JS_UNDEFINED;
}

static JSValue js_timer_active(JSContext *ctx, JSValueConst this_val,
                               int argc, JSValueConst *argv) {
    (void)argc;
    (void)argv;
    XJSTimer *t = xjs_timer_get(ctx, this_val);
    if (!t) return JS_EXCEPTION;
    return JS_NewBool(ctx, t->handle != NULL);
}

static const JSCFunctionListEntry timer_proto_funcs[] = {
    JS_CFUNC_DEF("del", 0, js_timer_del),
    JS_CFUNC_DEF("delete", 0, js_timer_del),
    JS_CFUNC_DEF("active", 0, js_timer_active),
};

static int ensure_timer_class(JSContext *ctx) {
    JSRuntime *rt = JS_GetRuntime(ctx);
    xjs_alloc_class_ids(rt);
    if (!JS_IsRegisteredClass(rt, g_xjs_timer_class_id)) {
        JSClassDef def = {
            "XTimer",
            .finalizer = xjs_timer_finalizer,
            .gc_mark = xjs_timer_mark,
        };
        if (JS_NewClass(rt, g_xjs_timer_class_id, &def) < 0) return -1;
    }

    JSValue proto = JS_NewObject(ctx);
    if (JS_IsException(proto)) return -1;
    JS_SetPropertyFunctionList(ctx, proto, timer_proto_funcs, countof(timer_proto_funcs));
    JS_SetClassProto(ctx, g_xjs_timer_class_id, proto);
    return 0;
}

static void timer_callback_bridge(void *ud) {
    XJSTimer *t = (XJSTimer *)ud;
    if (!t || !t->ctx || JS_IsUndefined(t->callback)) return;

    JSContext *ctx = t->ctx;
    JSValue self = JS_DupValue(ctx, t->self);         /* keepalive: prevents t free mid-call */
    JSValue cb   = JS_DupValue(ctx, t->callback);     /* keepalive: callback may del itself */

    int last_call = 0;
    if (t->repeat_remaining > 0 && --t->repeat_remaining == 0) {
        last_call = 1;
        t->handle = NULL;
    }

    JSValue ret = JS_Call(ctx, cb, self, 1, (JSValueConst *)&self);
    if (JS_IsException(ret)) {
        xjs_dump_error_with_prefix(ctx, "xtimer callback: ");
    } else {
        JS_FreeValue(ctx, ret);
    }

    if (last_call) {
        timer_release_ctx(t, 0);   /* t guaranteed alive: `self` keepalive holds it */
    }
    JS_FreeValue(ctx, cb);         /* release callback ref after JS_Call has returned */
    JS_FreeValue(ctx, self);       /* last ref to t's JS object; finalizer may run now */
}

static JSValue xjs_timer_create(JSContext *ctx, const char *name, int interval_ms,
                            JSValueConst callback, int repeat_num) {
    if (!JS_IsFunction(ctx, callback)) {
        return JS_ThrowTypeError(ctx, "%s: callback must be a function", name);
    }
    if (interval_ms < 0) {
        return JS_ThrowRangeError(ctx, "%s: interval_ms must be >= 0", name);
    }
    if (repeat_num != -1 && repeat_num < 1) {
        return JS_ThrowRangeError(ctx, "%s: repeat must be -1 or >= 1", name);
    }
    if (ensure_timer_class(ctx) != 0) {
        return JS_EXCEPTION;
    }

    JSValue obj = JS_NewObjectClass(ctx, g_xjs_timer_class_id);
    if (JS_IsException(obj)) return obj;

    XJSTimer *t = (XJSTimer *)js_mallocz(ctx, sizeof(*t));
    if (!t) {
        JS_FreeValue(ctx, obj);
        return JS_ThrowOutOfMemory(ctx);
    }
    t->ctx = ctx;
    t->handle = NULL;
    t->callback = JS_DupValue(ctx, callback);
    t->self = JS_DupValue(ctx, obj);
    t->repeat_remaining = repeat_num;
    JS_SetOpaque(obj, t);
    timer_list_add(xjs_actor(ctx), t);

    t->handle = xtimer_add(interval_ms, timer_callback_bridge, t, repeat_num);
    if (!t->handle) {
        timer_release_ctx(t, 0);
        JS_FreeValue(ctx, obj);
        return JS_ThrowInternalError(ctx, "%s: xtimer_add failed", name);
    }
    return obj;
}

static JSValue js_xtimer_init(JSContext *ctx, JSValueConst this_val,
                              int argc, JSValueConst *argv) {
    (void)this_val;
    int32_t cap = 64;
    if (argc >= 1 && JS_ToInt32(ctx, &cap, argv[0]) < 0) return JS_EXCEPTION;
    if (cap < 1) cap = 1;
    if (g_xtimer_refs == 0 && !xtimer_inited()) xtimer_init((int)cap);
    g_xtimer_refs++;
    return JS_UNDEFINED;
}

static JSValue js_xtimer_uninit(JSContext *ctx, JSValueConst this_val,
                                int argc, JSValueConst *argv) {
    (void)this_val;
    (void)argc;
    (void)argv;
    xjs_xtimer_release_context(ctx);
    if (g_xtimer_refs > 0 && --g_xtimer_refs == 0) {
        xtimer_uninit();
    }
    return JS_UNDEFINED;
}

static JSValue js_xtimer_inited(JSContext *ctx, JSValueConst this_val,
                                int argc, JSValueConst *argv) {
    (void)this_val;
    (void)argc;
    (void)argv;
    return JS_NewBool(ctx, xtimer_inited() != 0);
}

static JSValue js_xtimer_count(JSContext *ctx, JSValueConst this_val,
                               int argc, JSValueConst *argv) {
    (void)this_val;
    (void)argc;
    (void)argv;
    return JS_NewInt32(ctx, xtimer_count());
}

static JSValue js_xtimer_update(JSContext *ctx, JSValueConst this_val,
                                int argc, JSValueConst *argv) {
    (void)this_val;
    (void)argc;
    (void)argv;
    return JS_NewInt32(ctx, xtimer_update());
}

static JSValue js_xtimer_last(JSContext *ctx, JSValueConst this_val,
                              int argc, JSValueConst *argv) {
    (void)this_val;
    (void)argc;
    (void)argv;
    return JS_NewInt32(ctx, xtimer_last());
}

static JSValue js_xtimer_show(JSContext *ctx, JSValueConst this_val,
                              int argc, JSValueConst *argv) {
    (void)ctx;
    (void)this_val;
    (void)argc;
    (void)argv;
    xtimer_show();
    return JS_UNDEFINED;
}

static JSValue js_xtimer_add(JSContext *ctx, JSValueConst this_val,
                             int argc, JSValueConst *argv) {
    (void)this_val;
    int32_t interval_ms = 0;
    int32_t repeat_num = 1;
    if (argc < 2) {
        return JS_ThrowTypeError(ctx, "xtimer.add: interval and callback expected");
    }
    if (JS_ToInt32(ctx, &interval_ms, argv[0]) < 0) return JS_EXCEPTION;
    if (argc >= 3 && JS_ToInt32(ctx, &repeat_num, argv[2]) < 0) return JS_EXCEPTION;
    return xjs_timer_create(ctx, "xtimer.add", interval_ms, argv[1], repeat_num);
}

static JSValue js_xtimer_delay(JSContext *ctx, JSValueConst this_val,
                               int argc, JSValueConst *argv) {
    (void)this_val;
    int32_t interval_ms = 0;
    if (argc < 2) {
        return JS_ThrowTypeError(ctx, "xtimer.delay: interval and callback expected");
    }
    if (JS_ToInt32(ctx, &interval_ms, argv[0]) < 0) return JS_EXCEPTION;
    return xjs_timer_create(ctx, "xtimer.delay", interval_ms, argv[1], 1);
}

static JSValue js_xtimer_del(JSContext *ctx, JSValueConst this_val,
                             int argc, JSValueConst *argv) {
    (void)this_val;
    if (argc < 1) {
        return JS_ThrowTypeError(ctx, "xtimer.del: timer expected");
    }
    return js_timer_del(ctx, argv[0], 0, NULL);
}

static JSValue js_xtimer_now_ms(JSContext *ctx, JSValueConst this_val,
                                int argc, JSValueConst *argv) {
    (void)this_val;
    (void)argc;
    (void)argv;
    return JS_NewInt64(ctx, (int64_t)time_clock_ms());
}

static JSValue js_xtimer_now_us(JSContext *ctx, JSValueConst this_val,
                                int argc, JSValueConst *argv) {
    (void)this_val;
    (void)argc;
    (void)argv;
    return JS_NewInt64(ctx, (int64_t)time_clock_us());
}

static JSValue js_xtimer_day_ms(JSContext *ctx, JSValueConst this_val,
                                int argc, JSValueConst *argv) {
    (void)this_val;
    (void)argc;
    (void)argv;
    return JS_NewInt64(ctx, (int64_t)time_day_ms());
}

static JSValue js_xtimer_day_us(JSContext *ctx, JSValueConst this_val,
                                int argc, JSValueConst *argv) {
    (void)this_val;
    (void)argc;
    (void)argv;
    return JS_NewInt64(ctx, (int64_t)time_day_us());
}

static JSValue js_xtimer_format(JSContext *ctx, JSValueConst this_val,
                                int argc, JSValueConst *argv) {
    (void)this_val;
    int64_t ms = (int64_t)time_day_ms();
    if (argc >= 1 && JS_ToInt64(ctx, &ms, argv[0]) < 0) return JS_EXCEPTION;
    char buf[24];
    time_get_dt((uint64_t)ms, buf);
    return JS_NewString(ctx, buf);
}

static const JSCFunctionListEntry xtimer_funcs[] = {
    JS_CFUNC_DEF("init", 1, js_xtimer_init),
    JS_CFUNC_DEF("uninit", 0, js_xtimer_uninit),
    JS_CFUNC_DEF("inited", 0, js_xtimer_inited),
    JS_CFUNC_DEF("count", 0, js_xtimer_count),
    JS_CFUNC_DEF("update", 0, js_xtimer_update),
    JS_CFUNC_DEF("last", 0, js_xtimer_last),
    JS_CFUNC_DEF("show", 0, js_xtimer_show),
    JS_CFUNC_DEF("add", 3, js_xtimer_add),
    JS_CFUNC_DEF("delay", 2, js_xtimer_delay),
    JS_CFUNC_DEF("del", 1, js_xtimer_del),
    JS_CFUNC_DEF("nowMs", 0, js_xtimer_now_ms),
    JS_CFUNC_DEF("nowUs", 0, js_xtimer_now_us),
    JS_CFUNC_DEF("dayMs", 0, js_xtimer_day_ms),
    JS_CFUNC_DEF("dayUs", 0, js_xtimer_day_us),
    JS_CFUNC_DEF("format", 1, js_xtimer_format),
    JS_CFUNC_DEF("now_ms", 0, js_xtimer_now_ms),
    JS_CFUNC_DEF("now_us", 0, js_xtimer_now_us),
    JS_CFUNC_DEF("day_ms", 0, js_xtimer_day_ms),
    JS_CFUNC_DEF("day_us", 0, js_xtimer_day_us),
};

JSValue xjs_new_xtimer_object(JSContext *ctx) {
    if (ensure_timer_class(ctx) != 0) return JS_EXCEPTION;
    JSValue obj = JS_NewObject(ctx);
    if (JS_IsException(obj)) return obj;
    JS_SetPropertyFunctionList(ctx, obj, xtimer_funcs, countof(xtimer_funcs));
    return obj;
}

static int js_xtimer_module_init(JSContext *ctx, JSModuleDef *m) {
    if (ensure_timer_class(ctx) != 0) return -1;
    if (JS_SetModuleExportList(ctx, m, xtimer_funcs, countof(xtimer_funcs)) < 0) {
        return -1;
    }
    JS_SetModuleExport(ctx, m, "default", xjs_new_xtimer_object(ctx));
    return 0;
}

JSModuleDef *js_init_module_xtimer(JSContext *ctx, const char *module_name) {
    JSModuleDef *m = JS_NewCModule(ctx, module_name, js_xtimer_module_init);
    if (!m) return NULL;
    JS_AddModuleExportList(ctx, m, xtimer_funcs, countof(xtimer_funcs));
    JS_AddModuleExport(ctx, m, "default");
    return m;
}

void xjs_xtimer_release_context(JSContext *ctx) {
    XJSActor *a = xjs_actor(ctx);
    if (!a) return;
    XJSTimer *t = a->timers;
    while (t) {
        XJSTimer *next = t->next;
        timer_release_ctx(t, 1);
        t = next;
    }
}
