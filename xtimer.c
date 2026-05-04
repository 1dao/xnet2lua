// xtimer.c
#include "xtimer.h"

#include <stdio.h>
#include <stdlib.h>
#include <limits.h>

#define XTIMER_MIN_CAP        16
#define XTIMER_DEFAULT_CAP    100
#define XTIMER_MAX_TRIGGER    128
#define XTIMER_FREELIST_MUL   2

typedef struct xTimerNode {
    xHeapMinNode base;

    int id;
    fnOnTime callback;
    void* user_data;
    int repeat_num;       /* remaining count; INT_MAX means practically infinite */
    int repeat_interval;  /* milliseconds */

    unsigned char cancelled;
    unsigned char firing;
    unsigned char in_free_list;

    struct xTimerNode* free_next;
} xTimerNode;

typedef struct xTimerSet {
    xHeapMin* timer_heap;
    int next_timer_id;
    uint64_t current_time;

    xTimerNode* free_list;
    int free_count;
    int free_limit;
} xTimerSet;

/* ------------------------------------------------------------------------- */
/* node allocation / freelist */

static xTimerNode* xtimer_node_alloc(xTimerSet* tm) {
    xTimerNode* timer = NULL;

    if (tm && tm->free_list) {
        timer = tm->free_list;
        tm->free_list = timer->free_next;
        tm->free_count--;

        timer->free_next = NULL;
        timer->in_free_list = 0;

        return timer;
    }

    timer = (xTimerNode*)malloc(sizeof(xTimerNode));
    return timer;
}

static void xtimer_node_release(xTimerSet* tm, xTimerNode* timer) {
    if (!timer) return;

    if (timer->in_free_list) {
        return;
    }

    if (!tm || tm->free_count >= tm->free_limit) {
        free(timer);
        return;
    }

    timer->base.heap_index = -1;
    timer->base.key = 0;

    timer->id = 0;
    timer->callback = NULL;
    timer->user_data = NULL;
    timer->repeat_num = 0;
    timer->repeat_interval = 0;

    timer->cancelled = 0;
    timer->firing = 0;
    timer->in_free_list = 1;

    timer->free_next = tm->free_list;
    tm->free_list = timer;
    tm->free_count++;
}

static void xtimer_freelist_destroy(xTimerSet* tm) {
    if (!tm) return;

    xTimerNode* p = tm->free_list;
    tm->free_list = NULL;
    tm->free_count = 0;

    while (p) {
        xTimerNode* next = p->free_next;
        p->free_next = NULL;
        p->in_free_list = 0;
        free(p);
        p = next;
    }
}

static xTimerNode* xtimer_node_new(xTimerSet* tm,
                                   int id,
                                   uint64_t timeout,
                                   int interval_ms,
                                   fnOnTime callback,
                                   void* ud,
                                   int repeat_num) {
    xTimerNode* timer = xtimer_node_alloc(tm);
    if (!timer) return NULL;

    timer->base.heap_index = -1;
    timer->base.key = timeout;

    timer->id = id;
    timer->callback = callback;
    timer->user_data = ud;
    timer->repeat_num = repeat_num;
    timer->repeat_interval = interval_ms;

    timer->cancelled = 0;
    timer->firing = 0;
    timer->in_free_list = 0;
    timer->free_next = NULL;

    return timer;
}

/* ------------------------------------------------------------------------- */
/* pool */

xTimerSet* xtimer_pool_create(int capacity) {
    capacity = (capacity < XTIMER_MIN_CAP) ? XTIMER_MIN_CAP : capacity;

    xTimerSet* tm = (xTimerSet*)malloc(sizeof(xTimerSet));
    if (!tm) return NULL;

    tm->timer_heap = xheapmin_create(capacity, xheapmin_compare);
    if (!tm->timer_heap) {
        free(tm);
        return NULL;
    }

    tm->next_timer_id = 1;
    tm->current_time = time_clock_ms();

    tm->free_list = NULL;
    tm->free_count = 0;
    tm->free_limit = capacity * XTIMER_FREELIST_MUL;

    return tm;
}

void xtimer_pool_destroy(xTimerSet* tm) {
    if (!tm) return;

    if (tm->timer_heap) {
        for (int i = 0; i < tm->timer_heap->size; i++) {
            xTimerNode* timer = (xTimerNode*)tm->timer_heap->data[i];
            free(timer);
        }

        xheapmin_destroy(tm->timer_heap);
        tm->timer_heap = NULL;
    }

    xtimer_freelist_destroy(tm);

    free(tm);
}

/* ------------------------------------------------------------------------- */
/* create / destroy */

xTimerNode* xtimer_create(xTimerSet* tm,
                          int interval_ms,
                          fnOnTime callback,
                          void* ud,
                          int repeat_num) {
    if (!tm) return NULL;

    if (interval_ms < 0) {
        interval_ms = 0;
    }

    if (repeat_num == -1) {
        repeat_num = INT_MAX;
    } else if (repeat_num < 1) {
        repeat_num = 1;
    }

    uint64_t timeout = tm->current_time + (uint64_t)interval_ms;

    xTimerNode* timer = xtimer_node_new(tm,
                                        tm->next_timer_id++,
                                        timeout,
                                        interval_ms,
                                        callback,
                                        ud,
                                        repeat_num);
    if (!timer) return NULL;

    xheapmin_insert(tm->timer_heap, (xHeapMinNode*)timer);

    return timer;
}

void xtimer_destroy(xTimerSet* tm, xTimerNode* timer) {
    if (!timer) return;

    if (timer->in_free_list) {
        return;
    }

    if (timer->cancelled) {
        return;
    }

    timer->cancelled = 1;
    timer->callback = NULL;
    timer->user_data = NULL;

    /*
    ** If the timer is still inside heap, remove it first.
    ** If it is currently firing, it has already been extracted from heap.
    */
    if (tm && tm->timer_heap &&
        timer->base.heap_index >= 0 &&
        xheapmin_check(tm->timer_heap, (xHeapMinNode*)timer)) {
        xheapmin_remove(tm->timer_heap, timer->base.heap_index);
        timer->base.heap_index = -1;
    }

    /*
    ** If the timer is being called now, do not release it here.
    ** xtimer_poll() will release it after callback returns.
    */
    if (timer->firing) {
        return;
    }

    xtimer_node_release(tm, timer);
}

/* ------------------------------------------------------------------------- */
/* poll */

int xtimer_poll(xTimerSet* tm) {
    if (!tm || !tm->timer_heap) return 0;

    tm->current_time = time_clock_ms();

    int triggered_count = 0;
    int next_timeout = 0;

    while (xheapmin_size(tm->timer_heap) > 0) {
        xTimerNode* timer = (xTimerNode*)xheapmin_peek(tm->timer_heap);
        if (!timer) break;

        if (timer->base.key > tm->current_time) {
            next_timeout = (int)(timer->base.key - tm->current_time);
            break;
        }

        /*
        ** Extract first.
        ** During callback, current timer is not inside heap.
        ** This makes callback-time xtimer_del(current_timer) safe.
        */
        xheapmin_extract(tm->timer_heap);
        timer->base.heap_index = -1;

        if (timer->cancelled) {
            xtimer_node_release(tm, timer);
            continue;
        }

        --timer->repeat_num;

        fnOnTime callback = timer->callback;
        void* ud = timer->user_data;

        timer->firing = 1;

        if (callback) {
            callback(ud);
        }

        timer->firing = 0;

        if (timer->cancelled) {
            xtimer_node_release(tm, timer);
        } else if (timer->repeat_num > 0 && timer->repeat_interval >= 0) {
            timer->base.key = tm->current_time + (uint64_t)timer->repeat_interval;
            xheapmin_insert(tm->timer_heap, (xHeapMinNode*)timer);
        } else {
            xtimer_node_release(tm, timer);
        }

        triggered_count++;
        if (triggered_count > XTIMER_MAX_TRIGGER) {
            fprintf(stderr, "[WARN]: Timer triggered more than %d times; possible infinite loop detected.\n",
                    XTIMER_MAX_TRIGGER);
            break;
        }
    }

    return next_timeout;
}

/* ------------------------------------------------------------------------- */
/* debug */

void xtimer_print(xTimerSet* tm) {
    if (!tm) return;

    printf("\n=== timer manager status ===\n");
    printf("current_time: %llu\n", (unsigned long long)tm->current_time);
    printf("active timers: %d\n", tm->timer_heap ? xheapmin_size(tm->timer_heap) : 0);
    printf("freelist: %d / %d\n", tm->free_count, tm->free_limit);

    if (!tm->timer_heap) return;

    xTimerNode* next_timer = (xTimerNode*)xheapmin_peek(tm->timer_heap);
    if (next_timer) {
        uint64_t left = 0;
        if (next_timer->base.key > tm->current_time) {
            left = next_timer->base.key - tm->current_time;
        }

        printf("next timer: ID=%d, %llums later\n",
               next_timer->id,
               (unsigned long long)left);
    }

    printf("all timers:\n");

    for (int i = 0; i < tm->timer_heap->size; i++) {
        xTimerNode* timer = (xTimerNode*)tm->timer_heap->data[i];

        uint64_t left = 0;
        if (timer->base.key > tm->current_time) {
            left = timer->base.key - tm->current_time;
        }

        printf("  [%d] ID=%d, expire=%llu, left=%llums, repeat_num=%d, interval=%d, heap_index=%d, cancelled=%d, firing=%d\n",
               i,
               timer->id,
               (unsigned long long)timer->base.key,
               (unsigned long long)left,
               timer->repeat_num,
               timer->repeat_interval,
               timer->base.heap_index,
               timer->cancelled,
               timer->firing);
    }
}

/* ------------------------------------------------------------------------- */
/* thread-local default timer set */

#ifdef _MSC_VER
static __declspec(thread) xTimerSet* _cur = NULL;
#else
static __thread xTimerSet* _cur = NULL;
#endif

void xtimer_init(int cap) {
    if (!_cur) {
        _cur = xtimer_pool_create(cap);
    }
}

void xtimer_uninit() {
    if (_cur) {
        xtimer_pool_destroy(_cur);
        _cur = NULL;
    }
}

int xtimer_inited() {
    return _cur != NULL;
}

int xtimer_update() {
    if (_cur) {
        return xtimer_poll(_cur);
    }

    return 0;
}

int xtimer_last() {
    if (_cur && _cur->timer_heap) {
        uint64_t time_now = time_clock_ms();
        xTimerNode* next_timer = (xTimerNode*)xheapmin_peek(_cur->timer_heap);

        if (next_timer) {
            if (next_timer->base.key > time_now) {
                return (int)(next_timer->base.key - time_now);
            }

            return 0;
        }
    }

    return -1;
}

void xtimer_show() {
    xtimer_print(_cur);
}

xtimerHandler xtimer_add(int interval_ms,
                         fnOnTime callback,
                         void* ud,
                         int repeat_num) {
    if (!_cur) {
        _cur = xtimer_pool_create(XTIMER_DEFAULT_CAP);
        if (!_cur) return NULL;
    }

    return (xtimerHandler)xtimer_create(_cur,
                                        interval_ms,
                                        callback,
                                        ud,
                                        repeat_num);
}

void xtimer_del(xtimerHandler handler) {
    if (!handler) return;

    /*
    ** Handler belongs to current thread-local timer pool.
    ** If _cur is already destroyed, do nothing.
    ** This is safer than freeing a possibly stale pointer.
    */
    if (!_cur) return;

    xtimer_destroy(_cur, (xTimerNode*)handler);
}