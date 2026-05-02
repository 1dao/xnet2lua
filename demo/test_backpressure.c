#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#include "xthread.h"

static int post_count = 0;
static int drop_count = 0;

static void slow_task(xThread* thr, void* arg) {
    (void)thr;
    int task_id = *(int*)arg;
    printf("  [TASK %d] executing\n", task_id);
    free(arg);
    usleep(100000); /* 100ms to keep queue backed up */
}

static void slow_init(xThread* thr) {
    printf("[INIT] Slow worker starting\n");
}

static void slow_update(xThread* thr) {
    printf("  [UPDATE] worker tick\n");
}

static void slow_cleanup(xThread* thr) {
    printf("[CLEANUP] Slow worker exiting\n");
}

int main(void) {
    printf("\n=== Backpressure Test (max_size=5) ===\n\n");

    xthread_init();
    
    if (!xthread_register(10, "slow-worker", slow_init, slow_update, slow_cleanup)) {
        printf("Failed to register worker\n");
        return 1;
    }

    usleep(500000); /* Let worker initialize */

    printf("Posting 20 tasks to queue with max_size=5...\n");
    for (int i = 0; i < 20; i++) {
        int* task_id = malloc(sizeof(int));
        *task_id = i;
        
        int err = xthread_post(10, slow_task, task_id, 0);
        if (err == 0) {
            post_count++;
            printf("[%d] POST OK (total posted: %d)\n", i, post_count);
        } else {
            drop_count++;
            printf("[%d] POST REJECTED err=%d (total dropped: %d)\n", i, err, drop_count);
            free(task_id);
        }
        usleep(10000);
    }

    printf("\nWaiting for queue to drain...\n");
    sleep(3);

    printf("\n=== Results ===\n");
    printf("Posted: %d\n", post_count);
    printf("Dropped: %d\n", drop_count);
    printf("Total: %d\n", post_count + drop_count);

    xthread_unregister(10);
    xthread_uninit();

    if (drop_count > 0) {
        printf("\n✓ Backpressure working! Rejected posts when queue full.\n");
        return 0;
    } else {
        printf("\n✗ No backpressure detected.\n");
        return 1;
    }
}
