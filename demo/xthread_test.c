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
static void test_task_func(xThread* thr, void* arg) {
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
static void producer_task_func(xThread* thr, void* arg) {
    (void)thr;
    int producer_id = *(int*)arg;
    int tasks_per_producer = 5;

    printf("[PRODUCER] Producer %d starting, posting %d tasks...\n", producer_id, tasks_per_producer);

    for (int i = 0; i < tasks_per_producer; i++) {
        TestTask* task = malloc(sizeof(TestTask));
        task->producer_id = producer_id;
        task->task_num = i;

        /* Post task to worker pool - posting to group base ID will automatically select a thread */
        bool ok = xthread_post(XTHR_WORKER_GRP1, test_task_func, task);
        if (!ok) {
            printf("[PRODUCER] Producer %d failed to post task %d\n", producer_id, i);
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
        ok = xthread_post(XTHR_COMPUTE, test_task_func, task);
        if (!ok) {
            printf("Failed to post task %d\n", i);
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
        ok = xthread_post(XTHR_MAIN, producer_task_func, producer_id);
        if (!ok) {
            printf("Failed to post producer task %d\n", i);
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
        ok = xthread_post(XTHR_WORKER_GRP2, test_task_func, task);
        if (!ok) {
            printf("Failed to post task %d\n", i);
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
static void worker_to_main_task(xThread* thr, void* arg) {
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
        bool ok = xthread_post(XTHR_MAIN, worker_to_main_task, task_num);
        if (!ok) {
            printf("[WORKER] Worker %d failed to post task %d to main\n", worker_id, i);
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

    printf("\n========================================\n");
    printf("All tests completed successfully!\n");
    printf("Total tasks executed: %d\n", task_counter);
    printf("========================================\n");

cleanup:
    /* Final cleanup */
    xthread_uninit();

    return ret;
}
