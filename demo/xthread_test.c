/*
 * test_xthread.c - Test demo for xthread thread pool library
 *
 * This demo tests:
 * 1. Basic thread registration
 * 2. Cross-thread task posting
 * 3. Thread pool with different scheduling strategies
 * 4. Multiple producers and consumers
 * 5. Thread local storage and userdata
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#ifdef _WIN32
#include <windows.h>
#define sleep(x) Sleep((x) * 1000)
#define usleep(x) Sleep((DWORD)(((x) + 999) / 1000))
#else
#include <unistd.h>
#endif

#include "../xthread.h"
#include "../xlog.h"

/* Test counters */
static volatile int task_counter = 0;
static volatile int producer_counter = 0;

/* Task structure for passing data */
typedef struct {
    int producer_id;
    int task_num;
} TestTask;

/* Worker thread on_init - called when thread starts */
static void worker_on_init(xThread* thr) {
    int id = xthread_get_id(thr);
    const char* name = xthread_get_name(thr);
    printf("[INIT]   Thread %d (%s) started, current thread id: %d\n",
           id, name, xthread_current_id());

    /* Store some test userdata */
    int* data = malloc(sizeof(int));
    *data = id * 1000;
    xthread_set_userdata(thr, data);
}

/* Worker thread on_update - called during xthread_update() */
static void worker_on_update(xThread* thr) {
    /* This is called in the worker thread's context when xthread_update() runs */
    int* data = (int*)xthread_get_userdata(thr);
    /* Nothing to do here for this demo */
    (void)thr;
    (void)data;
}

/* Worker thread on_cleanup - called when thread exits */
static void worker_on_cleanup(xThread* thr) {
    int id = xthread_get_id(thr);
    const char* name = xthread_get_name(thr);
    int* data = (int*)xthread_get_userdata(thr);

    printf("[CLEANUP] Thread %d (%s) exiting, userdata: %d\n",
           id, name, data ? *data : 0);

    if (data) {
        free(data);
    }
}

/* The actual task function that runs on the target thread */
static void test_task_func(xThread* thr, void* arg, int arg_len) {
    (void)arg_len;
    TestTask* task = (TestTask*)arg;
    int current_id = xthread_current_id();
    int target_id = xthread_get_id(thr);
    const char* name = xthread_get_name(thr);

    printf("[TASK]    Producer %d, task %d running on thread %d (%s), target: %d\n",
           task->producer_id, task->task_num, current_id, name, target_id);

    /* Simulate some work */
    usleep(10000);  /* 10ms */

    task_counter++;
    free(task);
}

/* Producer thread that posts tasks to worker pool */
static void producer_task_func(xThread* thr, void* arg, int arg_len) {
    (void)thr;
    (void)arg_len;
    int producer_id = *(int*)arg;
    int tasks_per_producer = 5;

    printf("[PRODUCER] Producer %d starting, posting %d tasks...\n", producer_id, tasks_per_producer);

    for (int i = 0; i < tasks_per_producer; i++) {
        TestTask* task = malloc(sizeof(TestTask));
        task->producer_id = producer_id;
        task->task_num = i;

        /* Post task to worker pool - posting to group base ID will automatically select a thread */
        int err = xthread_post(XTHR_WORKER_GRP1, test_task_func, task, 0);
        if (err != 0) {
            printf("[PRODUCER] Producer %d failed to post task %d (err=%d)\n", producer_id, i, err);
            free(task);
        } else {
            producer_counter++;
        }

        /* Small delay between posts */
        usleep(5000);
    }
}

/* Test 1: Basic single thread test */
static int test_basic_single_thread(void) {
    printf("\n========================================\n");
    printf("Test 1: Basic single thread test\n");
    printf("========================================\n");

    /* Register a simple worker thread */
    bool ok = xthread_register(XTHR_COMPUTE, "compute-worker",
                               worker_on_init, worker_on_update, worker_on_cleanup);
    if (!ok) {
        printf("Failed to register worker thread\n");
        return -1;
    }

    /* Post 3 tasks to it */
    for (int i = 0; i < 3; i++) {
        TestTask* task = malloc(sizeof(TestTask));
        task->producer_id = 0;
        task->task_num = i;
        int err = xthread_post(XTHR_COMPUTE, test_task_func, task, 0);
        if (err != 0) {
            printf("Failed to post task %d (err=%d)\n", i, err);
            free(task);
        }
    }

    /* Give some time for tasks to complete */
    sleep(1);

    printf("Test 1 done: completed %d tasks\n", task_counter);

    /* Unregister the thread */
    xthread_unregister(XTHR_COMPUTE);

    sleep(1);
    return 0;
}

/* Test 2: Thread group / pool test with round-robin strategy */
static int test_thread_pool_round_robin(void) {
    printf("\n========================================\n");
    printf("Test 2: Thread pool with round-robin strategy\n");
    printf("========================================\n");

    task_counter = 0;

    /* Register a group of 4 worker threads */
    bool ok = xthread_register_group(XTHR_WORKER_GRP1, 4,
                                      XTHSTRATEGY_ROUND_ROBIN,
                                      "thr-grp1-%d",
                                      worker_on_init, worker_on_update, worker_on_cleanup);
    if (!ok) {
        printf("Failed to register worker group\n");
        return -1;
    }

    /* 4 producers posting 5 tasks each = 20 tasks total */
    producer_counter = 0;
    for (int i = 0; i < 4; i++) {
        int* producer_id = malloc(sizeof(int));
        *producer_id = i + 1;
        int err = xthread_post(XTHR_MAIN, producer_task_func, producer_id, 0);
        if (err != 0) {
            printf("Failed to post producer task %d (err=%d)\n", i, err);
            free(producer_id);
        }
    }

    /* Process tasks on main thread (since we registered main thread) */
    printf("[MAIN] Processing tasks...\n");
    int processed;
    int waited = 0;
    do {
        processed = xthread_update(300);
        /* If we processed something, print it */
        if (processed > 0) {
            printf("[MAIN] Processed %d tasks this iteration\n", processed);
        }
        waited++;
        /* Timeout after ~30 seconds to avoid infinite loop */
        if (waited > 300) {
            printf("[TIMEOUT] Waited too long, exiting loop early. posted=%d, completed=%d\n",
                   producer_counter, task_counter);
            break;
        }
    } while (producer_counter < 20 || task_counter < 20);

    /* Final update to make sure all tasks are done */
    xthread_update(300);

    printf("Test 2 done: posted %d tasks, completed %d tasks\n",
           producer_counter, task_counter);

    /* Unregister all threads in group */
    for (int i = 0; i < 4; i++) {
        xthread_unregister(XTHR_WORKER_GRP1 + i);
    }

    sleep(1);
    return 0;
}

/* Test 3: Thread pool with least-queue strategy (default) */
static int test_thread_pool_least_queue(void) {
    printf("\n========================================\n");
    printf("Test 3: Thread pool with least-queue strategy\n");
    printf("========================================\n");

    task_counter = 0;
    producer_counter = 0;

    /* Register a group with least-queue scheduling (best for workload balancing) */
    bool ok = xthread_register_group(XTHR_WORKER_GRP2, 3,
                                      XTHSTRATEGY_LEAST_QUEUE,
                                      "thr-grp2-%d",
                                      worker_on_init, worker_on_update, worker_on_cleanup);
    if (!ok) {
        printf("Failed to register worker group\n");
        return -1;
    }

    /* Post a lot of tasks quickly to test load balancing */
    int total_tasks = 15;
    for (int i = 0; i < total_tasks; i++) {
        TestTask* task = malloc(sizeof(TestTask));
        task->producer_id = 0;
        task->task_num = i;
        int err = xthread_post(XTHR_WORKER_GRP2, test_task_func, task, 0);
        if (err != 0) {
            printf("Failed to post task %d (err=%d)\n", i, err);
            free(task);
        }
    }

    printf("Posted %d tasks, waiting for completion...\n", total_tasks);
    sleep(2);

    printf("Test 3 done: completed %d tasks\n", task_counter);

    /* Cleanup */
    for (int i = 0; i < 3; i++) {
        xthread_unregister(XTHR_WORKER_GRP2 + i);
    }

    sleep(1);
    return 0;
}

/* Test 4: Test current thread ID and get current thread */
static int test_thread_identification(void) {
    printf("\n========================================\n");
    printf("Test 4: Thread identification API\n");
    printf("========================================\n");

    int current_id = xthread_current_id();
    xThread* current = xthread_current();

    printf("Current thread ID: %d\n", current_id);
    printf("Current thread pointer: %p\n", (void*)current);

    if (current) {
        printf("Current thread name: %s\n", xthread_get_name(current));
        printf("Current thread get_id() returns: %d\n", xthread_get_id(current));
    }

    /* Lookup by ID */
    xThread* thr = xthread_get(XTHR_MAIN);
    if (thr) {
        printf("xthread_get(XTHR_MAIN) returned: %p, name: %s\n",
               (void*)thr, xthread_get_name(thr));
    }

    return 0;
}

/* Counter for worker -> main tasks */
static volatile int worker_to_main_counter = 0;

/* Task that runs on main thread, posted from worker */
static void worker_to_main_task(xThread* thr, void* arg, int arg_len) {
    (void)arg_len;
    int task_num = *(int*)arg;
    int from_thread_id = xthread_current_id();
    int target_id = xthread_get_id(thr);

    printf("[WORKER->MAIN] Task %d running on thread %d (target: %d), posted from worker\n",
           task_num, from_thread_id, target_id);

    worker_to_main_counter++;
    free(arg);
}

/* Worker posts tasks back to main thread - runs as on_update callback */
static void worker_post_to_main(xThread* thr) {
    static bool posted = false;
    if (posted) return;  // Only post once when thread starts
    posted = true;

    int worker_id = xthread_get_id(thr);
    int tasks_per_worker = 3;

    printf("[WORKER] Worker %d posting %d tasks back to main thread...\n",
           worker_id, tasks_per_worker);

    for (int i = 0; i < tasks_per_worker; i++) {
        int* task_num = malloc(sizeof(int));
        *task_num = i;
        int err = xthread_post(XTHR_MAIN, worker_to_main_task, task_num, 0);
        if (err != 0) {
            printf("[WORKER] Worker %d failed to post task %d to main (err=%d)\n", worker_id, i, err);
            free(task_num);
        }
    }
}

/* Test 5: Worker threads posting tasks back to main thread (reverse direction) */
static int test_worker_to_main(void) {
    printf("\n========================================\n");
    printf("Test 5: Worker threads posting tasks to main thread\n");
    printf("========================================\n");

    worker_to_main_counter = 0;

    /* Register 2 worker threads that post back to main when they start */
    bool ok = xthread_register_group(XTHR_WORKER_GRP3, 2,
                                      XTHSTRATEGY_ROUND_ROBIN,
                                      "worker2main-%d",
                                      worker_on_init, worker_post_to_main, worker_on_cleanup);
    if (!ok) {
        printf("Failed to register worker group\n");
        return -1;
    }

    /* Wait for all tasks to be processed by main */
    printf("[MAIN] Waiting for worker -> main tasks...\n");
    int waited = 0;
    do {
        worker_to_main_counter = worker_to_main_counter + xthread_update(300);
        usleep(10000);
        waited++;
        /* Timeout after ~10 seconds */
        if (waited > 1000) {
            printf("[TIMEOUT] Waited too long, exiting loop early. completed=%d\n",
                   worker_to_main_counter);
            break;
        }
    } while (worker_to_main_counter < 3);

    /* Final update */
    xthread_update(1000);

    printf("Test 5 done: received %d tasks from workers to main\n", worker_to_main_counter);

    /* Cleanup */
    for (int i = 0; i < 2; i++) {
        xthread_unregister(XTHR_WORKER_GRP3 + i);
    }

    sleep(1);
    return 0;
}

/* ============================================================================
** Test 6: arg_len semantics — pointer / inline copy / heap copy
** ============================================================================ */

typedef struct {
    unsigned int magic;
    int          task_num;
} SmallArg;

#define BIG_PAYLOAD_SIZE 512  /* must be > XTHREAD_TASK_ARG_INLINE (256) */

typedef struct {
    unsigned int magic;
    int          task_num;
    char         payload[BIG_PAYLOAD_SIZE - 8];  /* total 512B */
} BigArg;

static volatile int test6_pointer_count = 0;
static volatile int test6_inline_count  = 0;
static volatile int test6_heap_count    = 0;
static volatile int test6_errors        = 0;

/* arg_len == 0 → raw pointer (caller-owned, callback frees). */
static void test6_pointer_handler(xThread* thr, void* arg, int arg_len) {
    (void)thr;
    SmallArg* a = (SmallArg*)arg;
    if (arg_len != 0) {
        test6_errors++;
        printf("[T6 ptr] expected arg_len=0, got %d\n", arg_len);
    }
    if (a->magic != 0xCAFEBABEu) {
        test6_errors++;
        printf("[T6 ptr] bad magic 0x%x\n", a->magic);
    }
    test6_pointer_count++;
    free(arg);  /* pointer semantics — we own it */
}

/* 0 < arg_len <= XTHREAD_TASK_ARG_INLINE → arg copied into task's inline buffer. */
static void test6_inline_handler(xThread* thr, void* arg, int arg_len) {
    (void)thr;
    SmallArg* a = (SmallArg*)arg;
    if (arg_len != (int)sizeof(SmallArg)) {
        test6_errors++;
        printf("[T6 inline] expected arg_len=%d, got %d\n",
               (int)sizeof(SmallArg), arg_len);
    }
    if (a->magic != 0xDEADBEEFu) {
        test6_errors++;
        printf("[T6 inline] bad magic 0x%x\n", a->magic);
    }
    test6_inline_count++;
    /* No free — arg lives in the task's inline buffer, freed by xthread. */
}

/* arg_len > XTHREAD_TASK_ARG_INLINE → arg copied into a fresh heap buffer. */
static void test6_heap_handler(xThread* thr, void* arg, int arg_len) {
    (void)thr;
    BigArg* a = (BigArg*)arg;
    if (arg_len != (int)sizeof(BigArg)) {
        test6_errors++;
        printf("[T6 heap] expected arg_len=%d, got %d\n",
               (int)sizeof(BigArg), arg_len);
    }
    if (a->magic != 0x12345678u) {
        test6_errors++;
        printf("[T6 heap] bad magic 0x%x\n", a->magic);
    }
    /* Tail byte sentinel — catches truncated / partial copies. */
    if (a->payload[sizeof(a->payload) - 1] != (char)0x5A) {
        test6_errors++;
        printf("[T6 heap] payload tail mismatch\n");
    }
    test6_heap_count++;
    /* No free — heap buffer owned by xthread. */
}

static int test_arg_len_semantics(void) {
    printf("\n========================================\n");
    printf("Test 6: arg_len semantics (pointer / inline / heap copy)\n");
    printf("Sizes: SmallArg=%d  BigArg=%d  INLINE_MAX=%d\n",
           (int)sizeof(SmallArg), (int)sizeof(BigArg),
           XTHREAD_TASK_ARG_INLINE);
    printf("========================================\n");

    test6_pointer_count = 0;
    test6_inline_count  = 0;
    test6_heap_count    = 0;
    test6_errors        = 0;

    bool ok = xthread_register(XTHR_COMPUTE, "argtest-worker",
                               worker_on_init, worker_on_update, worker_on_cleanup);
    if (!ok) {
        printf("Failed to register worker thread\n");
        return -1;
    }

    const int N = 5;

    /* Mode 1: arg_len = 0 → raw pointer; producer mallocs, consumer frees. */
    for (int i = 0; i < N; i++) {
        SmallArg* a = malloc(sizeof(SmallArg));
        a->magic    = 0xCAFEBABEu;
        a->task_num = i;
        int err = xthread_post(XTHR_COMPUTE, test6_pointer_handler, a, 0);
        if (err != 0) { printf("post(ptr) err=%d\n", err); free(a); }
    }

    /* Mode 2: arg_len = sizeof(SmallArg) (<=256) → inline copy. Stack arg OK. */
    for (int i = 0; i < N; i++) {
        SmallArg a = { .magic = 0xDEADBEEFu, .task_num = i };
        int err = xthread_post(XTHR_COMPUTE, test6_inline_handler,
                               &a, sizeof(a));
        if (err != 0) printf("post(inline) err=%d\n", err);
    }

    /* Mode 3: arg_len = sizeof(BigArg) (>256) → heap copy. Stack arg OK. */
    for (int i = 0; i < N; i++) {
        BigArg a;
        memset(&a, 0, sizeof(a));
        a.magic    = 0x12345678u;
        a.task_num = i;
        a.payload[sizeof(a.payload) - 1] = (char)0x5A;
        int err = xthread_post(XTHR_COMPUTE, test6_heap_handler,
                               &a, sizeof(a));
        if (err != 0) printf("post(heap) err=%d\n", err);
    }

    sleep(1);
    xthread_unregister(XTHR_COMPUTE);
    sleep(1);

    printf("Test 6 done: pointer=%d  inline=%d  heap=%d  errors=%d "
           "(expected %d/%d/%d/0)\n",
           test6_pointer_count, test6_inline_count, test6_heap_count,
           test6_errors, N, N, N);

    if (test6_pointer_count != N || test6_inline_count != N
        || test6_heap_count != N || test6_errors != 0) {
        printf("[FAIL] Test 6 did not get expected counts\n");
        return -1;
    }
    return 0;
}

/* ============================================================================
** Test 7: backpressure — xthread_set_queue_max + xthread_post -2 path
** ============================================================================ */

#define BP_QUEUE_MAX  5
#define BP_TOTAL_POSTS 20

static volatile int bp_post_ok      = 0;
static volatile int bp_post_full    = 0;
static volatile int bp_post_other   = 0;
static volatile int bp_consumed     = 0;

/* Slow consumer keeps the queue backed up so further posts hit -2. */
static void bp_slow_task(xThread* thr, void* arg, int arg_len) {
    (void)thr;
    (void)arg_len;
    int task_id = *(int*)arg;
    free(arg);
    usleep(100000); /* 100 ms */
    bp_consumed++;
    (void)task_id;
}

static int test_backpressure(void) {
    printf("\n========================================\n");
    printf("Test 7: backpressure (max_size=%d, posts=%d)\n",
           BP_QUEUE_MAX, BP_TOTAL_POSTS);
    printf("========================================\n");

    bp_post_ok    = 0;
    bp_post_full  = 0;
    bp_post_other = 0;
    bp_consumed   = 0;

    bool ok = xthread_register(XTHR_COMPUTE, "bp-worker",
                               worker_on_init, worker_on_update, worker_on_cleanup);
    if (!ok) {
        printf("Failed to register worker thread\n");
        return -1;
    }

    if (xthread_set_queue_max(XTHR_COMPUTE, BP_QUEUE_MAX) != 0) {
        printf("xthread_set_queue_max failed\n");
        xthread_unregister(XTHR_COMPUTE);
        return -1;
    }

    for (int i = 0; i < BP_TOTAL_POSTS; i++) {
        int* task_id = malloc(sizeof(int));
        *task_id = i;
        int err = xthread_post(XTHR_COMPUTE, bp_slow_task, task_id, 0);
        if (err == 0) {
            bp_post_ok++;
        } else if (err == -2) {
            bp_post_full++;
            free(task_id);
        } else {
            bp_post_other++;
            free(task_id);
        }
        usleep(10000); /* 10 ms — faster than the 100 ms consumer */
    }

    /* Drain remaining queued tasks (post_ok * 100ms is the worst case). */
    sleep(3);

    xthread_unregister(XTHR_COMPUTE);

    printf("Test 7 done: ok=%d  full(-2)=%d  other_err=%d  consumed=%d\n",
           bp_post_ok, bp_post_full, bp_post_other, bp_consumed);

    if (bp_post_ok + bp_post_full + bp_post_other != BP_TOTAL_POSTS) {
        printf("[FAIL] post counts do not sum to %d\n", BP_TOTAL_POSTS);
        return -1;
    }
    if (bp_post_full == 0) {
        printf("[FAIL] no -2 (queue full) seen — backpressure not triggered\n");
        return -1;
    }
    if (bp_post_other != 0) {
        printf("[FAIL] unexpected error code seen\n");
        return -1;
    }
    if (bp_consumed != bp_post_ok) {
        printf("[FAIL] consumed (%d) != post_ok (%d)\n", bp_consumed, bp_post_ok);
        return -1;
    }
    return 0;
}

/* ============================================================================
** Test 8: per-thread task timeout + on_expired callback
** ============================================================================ */

static volatile int test8_normal_count  = 0;
static volatile int test8_expired_count = 0;

static void test8_normal_handler(xThread* thr, void* arg, int arg_len) {
    (void)thr; (void)arg_len;
    test8_normal_count++;
    free(arg);
}

static void test8_expired_handler(xThread* thr, void* arg, int arg_len) {
    (void)thr; (void)arg_len;
    test8_expired_count++;
    free(arg);  /* raw pointer mode — on_expired owns the free */
}

static int test_thread_timeout(void) {
    printf("\n========================================\n");
    printf("Test 8: per-thread timeout (1s) + on_expired callback\n");
    printf("========================================\n");

    test8_normal_count  = 0;
    test8_expired_count = 0;

    /* Phase 1: enable 1s timeout, post tasks, sleep 2s, drain.
    ** All tasks should expire and be routed to on_expired. */
    if (xthread_set_timeout(XTHR_MAIN, 1, test8_expired_handler) != 0) {
        printf("xthread_set_timeout failed\n");
        return -1;
    }

    const int N = 5;
    for (int i = 0; i < N; i++) {
        int* p = malloc(sizeof(int));
        *p = i;
        if (xthread_post(XTHR_MAIN, test8_normal_handler, p, 0) != 0) {
            printf("post failed\n");
            free(p);
        }
    }

    sleep(2);                  /* let tasks age past 1s timeout */
    xthread_update(0);          /* drain on this thread */

    if (test8_normal_count != 0 || test8_expired_count != N) {
        printf("[FAIL] Phase 1: normal=%d expired=%d (expected 0/%d)\n",
               test8_normal_count, test8_expired_count, N);
        xthread_set_timeout(XTHR_MAIN, 0, NULL);
        return -1;
    }
    printf("Phase 1 OK: normal=%d  expired=%d\n",
           test8_normal_count, test8_expired_count);

    /* Phase 2: disable timeout. Same delay, tasks must NOT expire. */
    xthread_set_timeout(XTHR_MAIN, 0, NULL);

    int n_before = test8_normal_count;
    int e_before = test8_expired_count;

    const int M = 3;
    for (int i = 0; i < M; i++) {
        int* p = malloc(sizeof(int));
        *p = i;
        if (xthread_post(XTHR_MAIN, test8_normal_handler, p, 0) != 0) {
            printf("post failed\n");
            free(p);
        }
    }
    sleep(2);
    xthread_update(0);

    int n_delta = test8_normal_count  - n_before;
    int e_delta = test8_expired_count - e_before;

    if (n_delta != M || e_delta != 0) {
        printf("[FAIL] Phase 2: normal_delta=%d expired_delta=%d (expected %d/0)\n",
               n_delta, e_delta, M);
        return -1;
    }
    printf("Phase 2 OK: normal_delta=%d  expired_delta=%d\n", n_delta, e_delta);

    printf("Test 8 done: phase1 expired %d/%d, phase2 normal %d/%d\n",
           test8_expired_count, N, n_delta, M);
    return 0;
}

int main(int argc, char** argv) {
    (void)argc;
    (void)argv;

    printf("========================================\n");
    printf("xthread library test demo\n");
    printf("========================================\n");

    /* Initialize the thread library
       This automatically registers main thread and initializes wakeup */
    if (!xthread_init()) {
        printf("Failed to initialize xthread library\n");
        return -1;
    }

    /* Run tests */
    int ret = 0;

    if (test_basic_single_thread() != 0) {
        ret = -1;
        goto cleanup;
    }

    if (test_thread_identification() != 0) {
        ret = -1;
        goto cleanup;
    }

    if (test_thread_pool_round_robin() != 0) {
        ret = -1;
        goto cleanup;
    }

    if (test_thread_pool_least_queue() != 0) {
        ret = -1;
        goto cleanup;
    }

    if (test_worker_to_main() != 0) {
        ret = -1;
        goto cleanup;
    }

    if (test_arg_len_semantics() != 0) {
        ret = -1;
        goto cleanup;
    }

    if (test_backpressure() != 0) {
        ret = -1;
        goto cleanup;
    }

    if (test_thread_timeout() != 0) {
        ret = -1;
        goto cleanup;
    }

    printf("\n========================================\n");
    printf("All tests completed successfully!\n");
    printf("Total tasks executed: %d\n", task_counter);
    printf("========================================\n");

cleanup:
    /* Final cleanup */
    xthread_uninit();

    return ret;
}
