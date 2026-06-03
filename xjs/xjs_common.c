#include "xjs.h"

#include <stdint.h>
#include <stdio.h>
#include <string.h>

#include "../3rd/quickjs/quickjs-libc.h"

#ifdef _WIN32
#include <windows.h>
#else
#include <pthread.h>
#endif

/* Class-id numbers are process-global; allocate them exactly once even if
** several pool threads create their first context concurrently (D2). The
** per-runtime JS_NewClass registration stays in each module (idempotent). */
JSClassID g_xjs_conn_class_id = 0;
JSClassID g_xjs_listener_class_id = 0;
JSClassID g_xjs_timer_class_id = 0;

static void xjs_alloc_class_ids_impl(JSRuntime *rt) {
    JS_NewClassID(rt, &g_xjs_conn_class_id);
    JS_NewClassID(rt, &g_xjs_listener_class_id);
    JS_NewClassID(rt, &g_xjs_timer_class_id);
}

#ifdef _WIN32
static INIT_ONCE g_xjs_class_once = INIT_ONCE_STATIC_INIT;
static JSRuntime *g_xjs_class_once_rt;
static BOOL CALLBACK xjs_class_once_cb(PINIT_ONCE o, PVOID p, PVOID *c) {
    (void)o; (void)p; (void)c;
    xjs_alloc_class_ids_impl(g_xjs_class_once_rt);
    return TRUE;
}
void xjs_alloc_class_ids(JSRuntime *rt) {
    g_xjs_class_once_rt = rt;
    InitOnceExecuteOnce(&g_xjs_class_once, xjs_class_once_cb, NULL, NULL);
}
#else
static pthread_once_t g_xjs_class_once = PTHREAD_ONCE_INIT;
static JSRuntime *g_xjs_class_once_rt;
static void xjs_class_once_cb(void) { xjs_alloc_class_ids_impl(g_xjs_class_once_rt); }
void xjs_alloc_class_ids(JSRuntime *rt) {
    g_xjs_class_once_rt = rt;
    pthread_once(&g_xjs_class_once, xjs_class_once_cb);
}
#endif

void xjs_dump_error_with_prefix(JSContext *ctx, const char *prefix) {
    JSValue exc = JS_GetException(ctx);
    JSValue stack = JS_UNDEFINED;
    const char *msg = JS_ToCString(ctx, exc);

    if (prefix && prefix[0]) {
        fprintf(stderr, "%s", prefix);
    }
    fprintf(stderr, "%s\n", msg ? msg : "<exception>");
    JS_FreeCString(ctx, msg);

    stack = JS_GetPropertyStr(ctx, exc, "stack");
    if (!JS_IsUndefined(stack)) {
        const char *s = JS_ToCString(ctx, stack);
        if (s && s[0]) {
            fprintf(stderr, "%s\n", s);
        }
        JS_FreeCString(ctx, s);
    }
    JS_FreeValue(ctx, stack);
    JS_FreeValue(ctx, exc);
}

void xjs_dump_error(JSContext *ctx) {
    xjs_dump_error_with_prefix(ctx, "");
}

JSValue xjs_call_json_parse(JSContext *ctx, const char *data, size_t len) {
    JSValue global = JS_GetGlobalObject(ctx);
    JSValue json = JS_GetPropertyStr(ctx, global, "JSON");
    JSValue parse = JS_GetPropertyStr(ctx, json, "parse");
    JSValue arg = JS_NewStringLen(ctx, data ? data : "", len);
    JSValue ret = JS_Call(ctx, parse, json, 1, (JSValueConst *)&arg);

    JS_FreeValue(ctx, arg);
    JS_FreeValue(ctx, parse);
    JS_FreeValue(ctx, json);
    JS_FreeValue(ctx, global);
    return ret;
}

JSValue xjs_call_json_stringify(JSContext *ctx, JSValueConst value) {
    JSValue global = JS_GetGlobalObject(ctx);
    JSValue json = JS_GetPropertyStr(ctx, global, "JSON");
    JSValue stringify = JS_GetPropertyStr(ctx, json, "stringify");
    JSValue ret = JS_Call(ctx, stringify, json, 1, &value);

    JS_FreeValue(ctx, stringify);
    JS_FreeValue(ctx, json);
    JS_FreeValue(ctx, global);
    return ret;
}

int xjs_to_bytes(JSContext *ctx, JSValueConst value, XJSBytes *out) {
    memset(out, 0, sizeof(*out));
    out->owner = JS_UNDEFINED;

    if (JS_IsArrayBuffer(value)) {
        uint8_t *buf = JS_GetArrayBuffer(ctx, &out->len, value);
        if (!buf) {
            return -1;
        }
        out->data = (const char *)buf;
        return 0;
    }

    if (JS_GetTypedArrayType(value) >= 0) {
        size_t byte_offset = 0;
        size_t byte_length = 0;
        size_t bytes_per_element = 0;
        JSValue abuf = JS_GetTypedArrayBuffer(ctx, value, &byte_offset,
                                              &byte_length, &bytes_per_element);
        (void)bytes_per_element;
        if (JS_IsException(abuf)) {
            return -1;
        }
        size_t abuf_len = 0;
        uint8_t *buf = JS_GetArrayBuffer(ctx, &abuf_len, abuf);
        if (!buf || byte_offset > abuf_len || byte_length > abuf_len - byte_offset) {
            JS_FreeValue(ctx, abuf);
            return -1;
        }
        out->owner = abuf;
        out->data = (const char *)buf + byte_offset;
        out->len = byte_length;
        return 0;
    }

    out->cstring = JS_ToCStringLen(ctx, &out->len, value);
    if (!out->cstring) {
        return -1;
    }
    out->data = out->cstring;
    return 0;
}

void xjs_free_bytes(JSContext *ctx, XJSBytes *bytes) {
    if (!bytes) return;
    if (bytes->cstring) {
        JS_FreeCString(ctx, bytes->cstring);
    }
    if (!JS_IsUndefined(bytes->owner)) {
        JS_FreeValue(ctx, bytes->owner);
    }
    memset(bytes, 0, sizeof(*bytes));
    bytes->owner = JS_UNDEFINED;
}

JSValue xjs_make_error_pair(JSContext *ctx, const char *msg) {
    JSValue arr = JS_NewArray(ctx);
    JS_SetPropertyUint32(ctx, arr, 0, JS_NULL);
    JS_SetPropertyUint32(ctx, arr, 1, JS_NewString(ctx, msg ? msg : "error"));
    return arr;
}

int xjs_set_bool_prop(JSContext *ctx, JSValueConst obj, const char *name, bool value) {
    return JS_SetPropertyStr(ctx, obj, name, JS_NewBool(ctx, value));
}

int xjs_set_i32_prop(JSContext *ctx, JSValueConst obj, const char *name, int value) {
    return JS_SetPropertyStr(ctx, obj, name, JS_NewInt32(ctx, value));
}

int xjs_set_i64_prop(JSContext *ctx, JSValueConst obj, const char *name, int64_t value) {
    return JS_SetPropertyStr(ctx, obj, name, JS_NewInt64(ctx, value));
}

int xjs_set_string_prop(JSContext *ctx, JSValueConst obj, const char *name, const char *value) {
    return JS_SetPropertyStr(ctx, obj, name, value ? JS_NewString(ctx, value) : JS_NULL);
}

int xjs_init_modules(JSContext *ctx) {
    JSValue global;

    js_init_module_std(ctx, "std");
    js_init_module_os(ctx, "os");
    js_init_module_xutils(ctx, "xutils");
    js_init_module_xtimer(ctx, "xtimer");
    js_init_module_xthread(ctx, "xthread");
    js_init_module_xnet(ctx, "xnet");

    global = JS_GetGlobalObject(ctx);
    JS_SetPropertyStr(ctx, global, "xutils", xjs_new_xutils_object(ctx));
    JS_SetPropertyStr(ctx, global, "xtimer", xjs_new_xtimer_object(ctx));
    JS_SetPropertyStr(ctx, global, "xthread", xjs_new_xthread_object(ctx));
    JS_SetPropertyStr(ctx, global, "xnet", xjs_new_xnet_object(ctx));
    JS_FreeValue(ctx, global);
    return 0;
}
