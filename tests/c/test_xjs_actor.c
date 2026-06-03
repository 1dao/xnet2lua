#ifndef XMACRO_USE_RPMALLOC
#define XMACRO_USE_RPMALLOC 0
#endif

#include "xjs/xjs.h"
#include "xjs/xjs_actor.h"
#include "quickjs-libc.h"
#include "xtimer.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#ifdef _WIN32
#include <windows.h>
#include <process.h>
#else
#include <pthread.h>
#endif

static int g_failures = 0;
#define CHECK(cond, msg) do { \
    if (!(cond)) { fprintf(stderr, "FAIL: %s\n", (msg)); g_failures++; } \
} while (0)

/* On eval this registers two long-interval timers in THIS actor's context. */
static const char *ACTOR_SCRIPT =
    "xtimer.init(16);"
    "xtimer.add(1000000, function(){}, -1);"
    "xtimer.add(1000000, function(){}, -1);";

static JSContext *make_actor(JSRuntime *rt) {
    char *argv[1] = { (char *)"actor" };
    JSContext *ctx = xjs_new_context(rt, 1, argv);
    CHECK(ctx != NULL, "xjs_new_context");
    if (!ctx) return NULL;
    JSValue r = JS_Eval(ctx, ACTOR_SCRIPT, strlen(ACTOR_SCRIPT),
                        "<actor>", JS_EVAL_TYPE_GLOBAL);
    if (JS_IsException(r)) { xjs_dump_error(ctx); g_failures++; }
    JS_FreeValue(ctx, r);
    xjs_run_pending_jobs(rt);
    CHECK(xjs_actor(ctx) != NULL, "actor opaque set");
    return ctx;
}

/* Isolation + independent teardown on one runtime/thread. */
static void test_isolation(void) {
    JSRuntime *rt = xjs_new_runtime();
    CHECK(rt != NULL, "runtime");
    if (!rt) return;

    JSContext *a = make_actor(rt);
    int after_a = xtimer_count();
    JSContext *b = make_actor(rt);
    int after_b = xtimer_count();
    CHECK(after_b > after_a, "second actor adds its own timers");

    /* Free actor B; A's timers must survive (count returns to after_a). */
    xjs_free_context(b);
    int after_free_b = xtimer_count();
    CHECK(after_free_b == after_a, "freeing B leaves A's timers intact");

    xjs_free_context(a);
    js_std_free_handlers(rt);
    JS_FreeRuntime(rt);
}

/* S1 stress: N OS threads, each its own runtime+context, each spinning
** timer add/del. With per-actor lists this is race-free; the old global
** list would corrupt/crash here (especially under ASan). */
#define STRESS_THREADS 6
#define STRESS_ITERS   2000

static void stress_body(void) {
    JSRuntime *rt = xjs_new_runtime();
    char *argv[1] = { (char *)"stress" };
    JSContext *ctx = xjs_new_context(rt, 1, argv);
    const char *init = "xtimer.init(16);";
    JSValue r = JS_Eval(ctx, init, strlen(init), "<s>", JS_EVAL_TYPE_GLOBAL);
    JS_FreeValue(ctx, r);
    const char *add =
        "for (let i=0;i<50;i++){ const t=xtimer.add(1000000,function(){},-1); t.del(); }";
    for (int i = 0; i < STRESS_ITERS; i++) {
        JSValue rr = JS_Eval(ctx, add, strlen(add), "<a>", JS_EVAL_TYPE_GLOBAL);
        if (JS_IsException(rr)) { xjs_dump_error(ctx); }
        JS_FreeValue(ctx, rr);
    }
    xjs_free_context(ctx);
    js_std_free_handlers(rt);
    JS_FreeRuntime(rt);
}

#ifdef _WIN32
static unsigned __stdcall stress_thread(void *p) { (void)p; stress_body(); return 0; }
#else
static void *stress_thread(void *p) { (void)p; stress_body(); return NULL; }
#endif

static void test_stress(void) {
#ifdef _WIN32
    HANDLE th[STRESS_THREADS];
    for (int i = 0; i < STRESS_THREADS; i++)
        th[i] = (HANDLE)_beginthreadex(NULL, 0, stress_thread, NULL, 0, NULL);
    WaitForMultipleObjects(STRESS_THREADS, th, TRUE, INFINITE);
    for (int i = 0; i < STRESS_THREADS; i++) CloseHandle(th[i]);
#else
    pthread_t th[STRESS_THREADS];
    for (int i = 0; i < STRESS_THREADS; i++) pthread_create(&th[i], NULL, stress_thread, NULL);
    for (int i = 0; i < STRESS_THREADS; i++) pthread_join(th[i], NULL);
#endif
}

int main(void) {
    test_isolation();
    test_stress();
    if (g_failures) { fprintf(stderr, "%d failure(s)\n", g_failures); return 1; }
    printf("test_xjs_actor: OK\n");
    return 0;
}
