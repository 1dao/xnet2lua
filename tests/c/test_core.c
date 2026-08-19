#ifndef XMACRO_USE_RPMALLOC
#define XMACRO_USE_RPMALLOC 0
#endif

#include "tests/c/xtest.h"

#include "xargs.h"
#include "xheapmin.h"
#include "xlog.h"
#include "xpoll.h"
#include "xtimer.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#ifdef _WIN32
#include <windows.h>
static void test_sleep_ms(int ms) { Sleep((DWORD)ms); }
#else
#include <unistd.h>
static void test_sleep_ms(int ms) { usleep((useconds_t)ms * 1000u); }
#endif

static void test_xargs_cli(xTestState* st) {
    xtest_suite("xargs cli parsing");

    xArgsCFG configs[] = {
        { 'p', "port", "1000", 0 },
        { 'v', "verbose", NULL, 1 },
        { 'm', "mode", "dev", 0 },
    };

    char arg0[] = "prog";
    char arg1[] = "-p";
    char arg2[] = "8080";
    char arg3[] = "--verbose";
    char arg4[] = "loose";
    char arg5[] = "--mode=prod";
    char arg6[] = "raw=1";
    char* argv[] = { arg0, arg1, arg2, arg3, arg4, arg5, arg6 };

    xargs_init(configs, 3, 7, argv);

    XTEST_EQ_STR(st, xargs_get("p"), "8080");
    XTEST_EQ_STR(st, xargs_get("port"), "8080");
    XTEST_EQ_STR(st, xargs_get("verbose"), "");
    XTEST_EQ_STR(st, xargs_get("mode"), "prod");
    XTEST_TRUE(st, strstr(xargs_get_other(), "loose") != NULL);
    /* bare key=value is now stored directly (no registration needed) rather
    ** than dumped into _other_, so it is retrievable by key and typed getters */
    XTEST_EQ_STR(st, xargs_get("raw"), "1");
    XTEST_EQ_INT(st, xargs_get_int("raw"), 1);
    /* dash-prefixed lookups resolve to the same stored key */
    XTEST_EQ_STR(st, xargs_get("--raw"), "1");
    XTEST_EQ_STR(st, xargs_get("--port"), "8080");
    XTEST_EQ_STR(st, xargs_get("-p"), "8080");
    XTEST_EQ_INT(st, xargs_get_int("port"), 8080);
    XTEST_EQ_INT(st, xargs_get_bool("verbose"), 1);
    XTEST_EQ_INT(st, xargs_get_int("missing"), 0);

    xargs_cleanup();
}

static void test_xargs_config_file(xTestState* st) {
    xtest_suite("xargs config loading");

    const char* cfg_path = "tests/c/.xargs_test.cfg";
    FILE* fp = fopen(cfg_path, "wb");
    XTEST_TRUE(st, fp != NULL);
    if (!fp) return;

    fputs("host = 127.0.0.1\n", fp);
    fputs("port = 9000 # argv/default should keep priority\n", fp);
    fputs("empty =\n", fp);
    fclose(fp);

    xArgsCFG configs[] = {
        { 'p', "port", "1000", 0 },
    };
    char arg0[] = "prog";
    char* argv[] = { arg0 };

    xargs_init(configs, 1, 1, argv);
    XTEST_EQ_INT(st, xargs_load_config(cfg_path), 0);
    XTEST_EQ_STR(st, xargs_get("host"), "127.0.0.1");
    XTEST_EQ_STR(st, xargs_get("port"), "1000");
    XTEST_EQ_STR(st, xargs_get("empty"), "");
    XTEST_EQ_INT(st, xargs_load_config("tests/c/.missing.cfg"), -1);

    xargs_cleanup();
    remove(cfg_path);
}

static void test_xheapmin_ordering(xTestState* st) {
    xtest_suite("xheapmin ordering");

    xHeapMinNode nodes[] = {
        { -1, 40 },
        { -1, 10 },
        { -1, 30 },
        { -1, 20 },
    };

    xHeapMin* heap = xheapmin_create(2, NULL);
    XTEST_TRUE(st, heap != NULL);
    if (!heap) return;

    for (int i = 0; i < 4; ++i) {
        XTEST_TRUE(st, xheapmin_insert(heap, &nodes[i]));
    }

    XTEST_EQ_INT(st, xheapmin_size(heap), 4);
    XTEST_EQ_PTR(st, xheapmin_peek(heap), &nodes[1]);

    xheapmin_refresh(heap, &nodes[0], 5);
    XTEST_EQ_PTR(st, xheapmin_peek(heap), &nodes[0]);

    XTEST_EQ_PTR(st, xheapmin_extract(heap), &nodes[0]);
    XTEST_EQ_PTR(st, xheapmin_extract(heap), &nodes[1]);

    xHeapMinNode* removed = xheapmin_remove(heap, nodes[3].heap_index);
    XTEST_EQ_PTR(st, removed, &nodes[3]);
    XTEST_FALSE(st, xheapmin_check(heap, &nodes[3]));
    XTEST_EQ_INT(st, xheapmin_size(heap), 1);

    xheapmin_destroy(heap);
}

static int g_timer_count = 0;

static void count_timer(void* ud) {
    int* count = (int*)ud;
    (*count)++;
    g_timer_count++;
}

static void pump_timers_until(int* value, int want, int max_ms) {
    for (int waited = 0; *value < want && waited < max_ms; ++waited) {
        test_sleep_ms(1);
        xtimer_update();
    }
}

static void test_xtimer_lifecycle(xTestState* st) {
    xtest_suite("xtimer lifecycle");

    xtimer_uninit();
    XTEST_FALSE(st, xtimer_inited());

    xtimer_init(4);
    XTEST_TRUE(st, xtimer_inited());
    XTEST_EQ_INT(st, xtimer_count(), 0);

    int once = 0;
    xtimerHandler once_h = xtimer_add(1, count_timer, &once, 1);
    XTEST_TRUE(st, once_h != NULL);
    XTEST_EQ_INT(st, xtimer_count(), 1);
    pump_timers_until(&once, 1, 100);
    XTEST_EQ_INT(st, once, 1);
    XTEST_EQ_INT(st, xtimer_count(), 0);

    int repeated = 0;
    xtimerHandler repeat_h = xtimer_add(1, count_timer, &repeated, 3);
    XTEST_TRUE(st, repeat_h != NULL);
    pump_timers_until(&repeated, 3, 200);
    XTEST_EQ_INT(st, repeated, 3);
    XTEST_EQ_INT(st, xtimer_count(), 0);

    int cancelled = 0;
    xtimerHandler cancel_h = xtimer_add(10000, count_timer, &cancelled, 1);
    XTEST_TRUE(st, cancel_h != NULL);
    XTEST_EQ_INT(st, xtimer_count(), 1);
    xtimer_del(cancel_h);
    XTEST_EQ_INT(st, xtimer_count(), 0);
    XTEST_EQ_INT(st, cancelled, 0);

    xtimer_uninit();
    XTEST_FALSE(st, xtimer_inited());
    XTEST_TRUE(st, g_timer_count >= 4);
}

static int test_file_exists(const char* path) {
    FILE* f = fopen(path, "rb");
    if (!f) return 0;
    fclose(f);
    return 1;
}

/* Reads the whole file into `buf`; leaves it empty when the file is absent. */
static void test_read_file(const char* path, char* buf, size_t cap) {
    FILE* f = fopen(path, "rb");
    size_t n;
    buf[0] = '\0';
    if (!f) return;
    n = fread(buf, 1, cap - 1u, f);
    buf[n] = '\0';
    fclose(f);
}

static void test_xlog_levels_and_files(xTestState* st) {
    /* Own process name so nothing collides with the real logs; console off so
    ** only the file sink is exercised. Every record is an error because WARN
    ** and above flush, which makes the bytes readable straight away. */
    const char* shared_log = "logs/xtest9_main_001.log";
    const char* thread_log = "logs/xtest9_demo_001.log";
    const char* unnamed_log = "logs/xtest9_t007_001.log";
    char buf[4096];

    xtest_suite("xlog levels and log-file naming");

    xlog_set_level(XLOG_LEVEL_INFO);
    XTEST_EQ_INT(st, xlog_get_level(), XLOG_LEVEL_INFO);
    XTEST_FALSE(st, xlog_is_enabled(XLOG_LEVEL_DEBUG));
    XTEST_TRUE(st, xlog_is_enabled(XLOG_LEVEL_ERROR));

    remove(shared_log);
    remove(thread_log);
    remove(unnamed_log);
    xlog_init("logs", "xtest9", 0);

    /* Opening is lazy: configuring the logger creates nothing. */
    XTEST_FALSE(st, test_file_exists(shared_log));

    /* A thread that never claimed a file writes to the process log. */
    xlog_set_thread(42, "worker/demo", "T42:worker");
    xloge("shared-line");
    XTEST_FALSE(st, test_file_exists(thread_log));
    XTEST_TRUE(st, test_file_exists(shared_log));
    test_read_file(shared_log, buf, sizeof(buf));
    XTEST_CONTAINS(st, buf, "[ERRR]");
    XTEST_CONTAINS(st, buf, "[T42:worker]");
    XTEST_CONTAINS(st, buf, "shared-line");

    /* After claiming one, records go to that file only -- and the file name
    ** drops the "worker" token from "worker/demo". */
    xlog_enable_thread_file();
    xloge("own-line");
    XTEST_TRUE(st, test_file_exists(thread_log));
    test_read_file(thread_log, buf, sizeof(buf));
    XTEST_CONTAINS(st, buf, "own-line");
    test_read_file(shared_log, buf, sizeof(buf));
    XTEST_NULL(st, strstr(buf, "own-line"));

    /* An unnamed thread falls back to the numeric tNNN form. */
    xlog_clear_thread();
    xlog_set_thread(7, NULL, NULL);
    xlog_enable_thread_file();
    xloge("unnamed-line");
    XTEST_TRUE(st, test_file_exists(unnamed_log));

    xlog_uninit();
    remove(shared_log);
    remove(thread_log);
    remove(unnamed_log);
    xlog_set_level(XLOG_LEVEL_VERBOSE);
}

static void test_xpoll_lifecycle(xTestState* st) {
    xtest_suite("xpoll lifecycle");

    xpoll_uninit();
    XTEST_FALSE(st, xpoll_inited());
    XTEST_EQ_INT(st, xpoll_add_event(INVALID_SOCKET_VAL, XPOLL_READABLE,
                                     NULL, NULL, NULL, NULL), -1);

    XTEST_EQ_INT(st, xpoll_init(), 0);
    XTEST_TRUE(st, xpoll_inited());
    XTEST_TRUE(st, xpoll_get_default() != NULL);
    XTEST_EQ_INT(st, xpoll_fd_count(), 0);
    XTEST_TRUE(st, xpoll_name() != NULL && xpoll_name()[0] != '\0');
    XTEST_EQ_INT(st, xpoll_resize(4096), 0);
    XTEST_EQ_INT(st, xpoll_get_fd(INVALID_SOCKET_VAL), -1);

    int marker = 123;
    xpoll_set_client_data(INVALID_SOCKET_VAL, &marker);
    XTEST_NULL(st, xpoll_get_client_data(INVALID_SOCKET_VAL));

    xpoll_uninit();
    XTEST_FALSE(st, xpoll_inited());
}

int main(void) {
    xTestState st = XTEST_STATE_INIT;

    test_xargs_cli(&st);
    test_xargs_config_file(&st);
    test_xheapmin_ordering(&st);
    test_xtimer_lifecycle(&st);
    test_xlog_levels_and_files(&st);
    test_xpoll_lifecycle(&st);

    return xtest_summary(&st);
}
