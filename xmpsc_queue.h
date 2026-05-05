#ifndef XMPSC_QUEUE_H
#define XMPSC_QUEUE_H

#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

/*
    MPSC queue
    Multiple Producer, Single Consumer.

    Rules:
    1. xmpsc_push() can be called by multiple producer threads.
    2. xmpsc_pop() can only be called by one consumer thread.
    3. A node must not be reused before it is popped.
    4. Queue must not be destroyed while producers may still push.
*/

typedef struct xMPSCNode {
    struct xMPSCNode* next;
} xMPSCNode;

typedef struct xMPSCQueue {
    xMPSCNode* volatile head;  /* shared by producers and consumer */
    xMPSCNode* cache;          /* consumer-only FIFO cache */
} xMPSCQueue;


/* ============================================================
 * Atomic pointer helpers
 * ============================================================ */

#if defined(_MSC_VER)

#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif

#include <windows.h>

static __inline void* xmpsc_atomic_load_ptr(void* volatile* p) {
    return InterlockedCompareExchangePointer((PVOID volatile*)p, NULL, NULL);
}

static __inline void* xmpsc_atomic_exchange_ptr(void* volatile* p, void* v) {
    return InterlockedExchangePointer((PVOID volatile*)p, v);
}

static __inline int xmpsc_atomic_cas_ptr(void* volatile* p, void* expected, void* desired) {
    return InterlockedCompareExchangePointer((PVOID volatile*)p, desired, expected) == expected;
}

#elif defined(__GNUC__) || defined(__clang__)

static inline void* xmpsc_atomic_load_ptr(void* volatile* p) {
    return __atomic_load_n(p, __ATOMIC_ACQUIRE);
}

static inline void* xmpsc_atomic_exchange_ptr(void* volatile* p, void* v) {
    return __atomic_exchange_n(p, v, __ATOMIC_ACQ_REL);
}

static inline int xmpsc_atomic_cas_ptr(void* volatile* p, void* expected, void* desired) {
    void* e = expected;
    return __atomic_compare_exchange_n(
        p,
        &e,
        desired,
        0,
        __ATOMIC_RELEASE,
        __ATOMIC_RELAXED
    );
}

#else
#error "xmpsc_queue.h needs MSVC Interlocked* or GCC/Clang __atomic builtins"
#endif


/* ============================================================
 * Queue implementation
 * ============================================================ */

static inline void xmpsc_queue_init(xMPSCQueue* q) {
    q->head = NULL;
    q->cache = NULL;
}

static inline void xmpsc_node_init(xMPSCNode* n) {
    n->next = NULL;
}

/*
    Push node into queue.

    Thread-safety:
    - Can be called by multiple producer threads.
*/
static inline void xmpsc_push(xMPSCQueue* q, xMPSCNode* n) {
    xMPSCNode* old_head;

    n->next = NULL;

    for (;;) {
        old_head = (xMPSCNode*)xmpsc_atomic_load_ptr((void* volatile*)&q->head);
        n->next = old_head;

        if (xmpsc_atomic_cas_ptr((void* volatile*)&q->head, old_head, n)) {
            return;
        }
    }
}

/*
    Reverse producer stack into consumer FIFO list.
*/
static inline xMPSCNode* xmpsc_reverse_list(xMPSCNode* list) {
    xMPSCNode* prev = NULL;
    xMPSCNode* next;

    while (list) {
        next = list->next;
        list->next = prev;
        prev = list;
        list = next;
    }

    return prev;
}

/*
    Pop one node.

    Thread-safety:
    - Must only be called by the single consumer thread.
*/
static inline xMPSCNode* xmpsc_pop(xMPSCQueue* q) {
    xMPSCNode* n;

    n = q->cache;

    if (n == NULL) {
        n = (xMPSCNode*)xmpsc_atomic_exchange_ptr((void* volatile*)&q->head, NULL);
        n = xmpsc_reverse_list(n);
        q->cache = n;
    }

    if (n == NULL) {
        return NULL;
    }

    q->cache = n->next;
    n->next = NULL;

    return n;
}

/*
    Approximate empty check.

    Because producers may push concurrently, this result is only reliable
    from the consumer thread as a momentary observation.
*/
static inline int xmpsc_empty(xMPSCQueue* q) {
    if (q->cache != NULL) {
        return 0;
    }

    return xmpsc_atomic_load_ptr((void* volatile*)&q->head) == NULL;
}

#define XMPSC_CONTAINER_OF(ptr, type, member) \
    ((type*)((char*)(ptr) - offsetof(type, member)))

#ifdef __cplusplus
}
#endif

#endif /* XMPSC_QUEUE_H */