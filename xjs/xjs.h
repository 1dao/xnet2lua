#ifndef XJS_H
#define XJS_H

#include <stddef.h>
#include <stdint.h>
#include <stdbool.h>

#include "../3rd/quickjs/quickjs.h"

#ifdef __cplusplus
extern "C" {
#endif

int xjs_init_modules(JSContext *ctx);
void xjs_dump_error(JSContext *ctx);
void xjs_dump_error_with_prefix(JSContext *ctx, const char *prefix);
JSRuntime *xjs_new_runtime(void);
JSContext *xjs_new_context(JSRuntime *rt, int argc, char **argv);
void xjs_free_context(JSContext *ctx);
int xjs_eval_file(JSContext *ctx, const char *filename, JSValue *out_main);
int xjs_run_pending_jobs(JSRuntime *rt);

JSValue xjs_call_json_parse(JSContext *ctx, const char *data, size_t len);
JSValue xjs_call_json_stringify(JSContext *ctx, JSValueConst value);

typedef struct XJSBytes {
    const char *data;
    size_t len;
    JSValue owner;
    const char *cstring;
} XJSBytes;

int xjs_to_bytes(JSContext *ctx, JSValueConst value, XJSBytes *out);
void xjs_free_bytes(JSContext *ctx, XJSBytes *bytes);

JSValue xjs_make_error_pair(JSContext *ctx, const char *msg);
int xjs_set_bool_prop(JSContext *ctx, JSValueConst obj, const char *name, bool value);
int xjs_set_i32_prop(JSContext *ctx, JSValueConst obj, const char *name, int value);
int xjs_set_i64_prop(JSContext *ctx, JSValueConst obj, const char *name, int64_t value);
int xjs_set_string_prop(JSContext *ctx, JSValueConst obj, const char *name, const char *value);

JSModuleDef *js_init_module_xutils(JSContext *ctx, const char *module_name);
JSModuleDef *js_init_module_xtimer(JSContext *ctx, const char *module_name);
JSModuleDef *js_init_module_xthread(JSContext *ctx, const char *module_name);
JSModuleDef *js_init_module_xnet(JSContext *ctx, const char *module_name);

JSValue xjs_new_xutils_object(JSContext *ctx);
JSValue xjs_new_xtimer_object(JSContext *ctx);
JSValue xjs_new_xthread_object(JSContext *ctx);
JSValue xjs_new_xnet_object(JSContext *ctx);

void xjs_xtimer_release_context(JSContext *ctx);
void xjs_xnet_release_context(JSContext *ctx);
void xjs_xthread_release_context(JSContext *ctx);
void xjs_xthread_set_thread_ctx(JSContext *ctx);
void xjs_xthread_set_thread_rt(JSRuntime *rt);
void xjs_xthread_free_spawned(void);

extern JSClassID g_xjs_conn_class_id;
extern JSClassID g_xjs_listener_class_id;
extern JSClassID g_xjs_timer_class_id;
void xjs_alloc_class_ids(JSRuntime *rt);

#ifdef __cplusplus
}
#endif

#endif /* XJS_H */
