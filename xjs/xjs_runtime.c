#include "xjs.h"
#include "xjs_actor.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "../3rd/quickjs/quickjs-libc.h"

JSRuntime *xjs_new_runtime(void) {
    JSRuntime *rt = JS_NewRuntime();
    if (!rt) return NULL;
    js_std_init_handlers(rt);
    JS_SetModuleLoaderFunc2(rt, NULL, js_module_loader,
                            js_module_check_attributes, NULL);
    JS_SetHostPromiseRejectionTracker(rt, js_std_promise_rejection_tracker, NULL);
    xjs_watch_install(rt);   /* soft-watchdog interrupt handler (L2) */
    return rt;
}

JSContext *xjs_new_context(JSRuntime *rt, int argc, char **argv) {
    JSContext *ctx = JS_NewContext(rt);
    if (!ctx) return NULL;

    XJSActor *a = (XJSActor *)calloc(1, sizeof(*a));
    if (!a) {
        JS_FreeContext(ctx);
        return NULL;
    }
    a->ctx = ctx;
    a->msg_handler = JS_UNDEFINED;
    JS_SetContextOpaque(ctx, a);

    js_std_add_helpers(ctx, argc, argv);
    xjs_init_modules(ctx);
    return ctx;
}

void xjs_free_context(JSContext *ctx) {
    if (!ctx) return;
    XJSActor *a = xjs_actor(ctx);          /* grab before JS_FreeContext */
    xjs_xthread_release_context(ctx);
    xjs_xnet_release_context(ctx);
    xjs_xtimer_release_context(ctx);
    JS_FreeContext(ctx);                   /* finalizers run; opaque still set */
    free(a);                               /* free actor after the context */
}

int xjs_run_pending_jobs(JSRuntime *rt) {
    JSContext *ctx1 = NULL;
    int rc = 0;
    for (;;) {
        rc = JS_ExecutePendingJob(rt, &ctx1);
        if (rc <= 0) break;
    }
    if (rc < 0 && ctx1) {
        xjs_dump_error(ctx1);
        return -1;
    }
    return 0;
}

static JSValue get_global_exports(JSContext *ctx) {
    JSValue global = JS_GetGlobalObject(ctx);
    JSValue ret = JS_GetPropertyStr(ctx, global, "exports");
    if (JS_IsUndefined(ret)) {
        JS_FreeValue(ctx, ret);
        JSValue module = JS_GetPropertyStr(ctx, global, "module");
        if (JS_IsObject(module)) {
            ret = JS_GetPropertyStr(ctx, module, "exports");
        } else {
            ret = JS_UNDEFINED;
        }
        JS_FreeValue(ctx, module);
    }
    JS_FreeValue(ctx, global);
    return ret;
}

static int eval_module_file(JSContext *ctx, const char *filename,
                            const char *buf, size_t len, JSValue *out_main) {
    JSValue obj = JS_Eval(ctx, buf, len, filename,
                          JS_EVAL_TYPE_MODULE | JS_EVAL_FLAG_COMPILE_ONLY);
    if (JS_IsException(obj)) return -1;

    if (JS_ResolveModule(ctx, obj) < 0) {
        JS_FreeValue(ctx, obj);
        return -1;
    }
    if (js_module_set_import_meta(ctx, obj, true, true) < 0) {
        JS_FreeValue(ctx, obj);
        return -1;
    }

    JSModuleDef *m = (JSModuleDef *)JS_VALUE_GET_PTR(obj);
    JSValue eval_ret = JS_EvalFunction(ctx, JS_DupValue(ctx, obj));
    eval_ret = js_std_await(ctx, eval_ret);
    if (JS_IsException(eval_ret)) {
        JS_FreeValue(ctx, obj);
        return -1;
    }
    JS_FreeValue(ctx, eval_ret);

    JSValue ns = JS_GetModuleNamespace(ctx, m);
    if (JS_IsException(ns)) {
        JS_FreeValue(ctx, obj);
        return -1;
    }
    JSValue def = JS_GetPropertyStr(ctx, ns, "default");
    JS_FreeValue(ctx, ns);
    JS_FreeValue(ctx, obj);
    *out_main = def;
    return 0;
}

static int eval_global_file(JSContext *ctx, const char *filename,
                            const char *buf, size_t len, JSValue *out_main) {
    JSValue ret = JS_Eval(ctx, buf, len, filename, JS_EVAL_TYPE_GLOBAL);
    ret = js_std_await(ctx, ret);
    if (JS_IsException(ret)) {
        return -1;
    }

    if (!JS_IsUndefined(ret)) {
        *out_main = ret;
        return 0;
    }
    JS_FreeValue(ctx, ret);

    ret = get_global_exports(ctx);
    if (!JS_IsUndefined(ret)) {
        *out_main = ret;
        return 0;
    }
    JS_FreeValue(ctx, ret);
    *out_main = JS_UNDEFINED;
    return 0;
}

int xjs_eval_file(JSContext *ctx, const char *filename, JSValue *out_main) {
    size_t len = 0;
    uint8_t *buf = js_load_file(ctx, &len, filename);
    if (!buf) {
        fprintf(stderr, "%s: cannot load file\n", filename);
        return -1;
    }

    int is_module = 0;
    size_t fn_len = strlen(filename);
    if (fn_len >= 4 && strcmp(filename + fn_len - 4, ".mjs") == 0) {
        is_module = 1;
    } else if (JS_DetectModule((const char *)buf, len)) {
        is_module = 1;
    }

    int rc = is_module
        ? eval_module_file(ctx, filename, (const char *)buf, len, out_main)
        : eval_global_file(ctx, filename, (const char *)buf, len, out_main);
    js_free(ctx, buf);
    if (rc != 0) {
        xjs_dump_error(ctx);
        return -1;
    }
    return 0;
}
