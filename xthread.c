/* xthread.c - Thread pool and cross-thread task posting
**
** Internal layout (hidden from callers):
**   xthrTask   – singly-linked task node
**   xQueue     – thread-safe task queue + wakeup primitive
**   xThread    – full thread context (opaque in xthread.h)
**   xThreadPool– load-balanced thread group (opaque in xthread.h)
**
** Wakeup strategy chosen at xthread_wakeup_init() time:
**   poll present  →  socketpair; read-end in xpoll, write-end pinged on push
**   poll absent   →  pthread_cond_signal / Windows SetEvent
*/

#include "xthread.h"
#include "xpoll.h"      /* xPollState, xpoll_get_default, xpoll_add/del_event, SOCKET_T */
#include "xmutex.h"
#include "xlog.h"
#include "xtimer.h"     /* time_clock_ms for per-task deadlines */
#ifdef XTHREAD_MPSCQ
#include "xmpsc_queue.h"
#endif

#include <stdatomic.h>
#include <stdalign.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <assert.h>
#include <time.h>

#ifdef _WIN32
#  define WIN32_LEAN_AND_MEAN
#  include <winsock2.h>
#  include <windows.h>
#  include <process.h>
#else
#  include <pthread.h>
#  include <unistd.h>
#  include <sys/socket.h>
#  include <fcntl.h>
#  include <errno.h>
#  include <time.h>
#endif

/* ============================================================================
** Internal types
** ========================================================================== */

/* Default backpressure cap on pending tasks per queue.
** xthread_post returns -2 once size >= max_size. xthread_post_reply ignores it.
** Override at build time with -DXTHREAD_QUEUE_MAX_DEFAULT=N.
** Set to 0 to disable the cap (unbounded — not recommended for production). */
#ifndef XTHREAD_QUEUE_MAX_DEFAULT
#define XTHREAD_QUEUE_MAX_DEFAULT 65536
#endif

typedef union xAlignMax {
    void* p;
    void (*fp)(void);
    long l;
    long long ll;
    double d;
    long double ld;
} xAlignMax;
/* Task node with inline arg buffer.
** arg_len == 0          → use arg_ptr (raw pointer, caller-owned, not freed)
** arg_len <= INLINE     → arg_buf holds copied bytes
** arg_len  > INLINE     → arg_ptr holds a malloc'd copy (freed in process_tasks)
**
** deadline_ms is a monotonic absolute deadline from time_clock_ms().
** 0 means the task never expires. */
typedef struct xthrTask {
#ifdef XTHREAD_MPSCQ
    xMPSCNode node;
#endif
    XThreadFunc      func;
    struct xthrTask* next;
    uint32_t         arg_len;       /* 0 = pointer semantics                  */
    uint8_t          from_heap;     /* 1 if node is malloc'd (not from pool)  */
    uint8_t          arg_external;  /* 1 if arg payload is malloc'd externally*/
    uint16_t         _pad;          /* align deadline_ms                      */
    uint64_t         deadline_ms;   /* monotonic absolute deadline; 0 = none  */
    union {
        void*        arg_ptr;       /* used when arg_len == 0 OR arg_external */
        uint8_t      arg_buf[XTHREAD_TASK_ARG_INLINE];
        xAlignMax   _align;        /* force alignment to max_align_t         */
    };
} xthrTask;

typedef struct {
    xthrTask*   head;
    xthrTask*   tail;
    int         size;
    int         max_size;   /* pending upper bound; 0 = unlimited */
    int         pending;    /* 1 = notification already in flight */
    xMutex      lock;       /* recursive mutex, guards linked list + freelist */

    /* Pre-allocated task pool (one contiguous slab). */
    xthrTask*   pool_storage;   /* base of slab, NULL if disabled         */
    int         pool_capacity;  /* number of pre-allocated nodes          */
    xthrTask*   freelist;       /* head of free list (pool nodes only)    */
    int         freelist_count; /* current freelist depth                 */

    /* Wakeup primitive used when the thread has no xPollState */
#ifdef _WIN32
    HANDLE          event;      /* auto-reset Event */
#else
    pthread_mutex_t wait_mutex; /* plain (non-recursive) mutex for cond */
    pthread_cond_t  cond;
#endif
} xQueue;

struct xThread {
#ifdef XTHREAD_MPSCQ
    xMPSCQueue   task_queue;        /* lock-free MPSC node list                */
    atomic_int   pending_tasks;     /* current depth (soft backpressure)       */
    int          max_pending_tasks; /* 0 = unlimited                           */
    atomic_int   notify_pending;    /* 0 = idle, 1 = wakeup already in flight  */
#endif
    int          id;
    char         name[16];  /* fixed-size name buffer, no allocation needed */
    atomic_bool  running;
    xQueue       queue;
    void*        userdata;
    xThreadPool* group;

    /* Poll-based wakeup (NULL when not using xpoll) */
    xPollState*  poll;
    SOCKET_T     notify_wfd;   /* write-end: xthread_post writes '!' here   */
    SOCKET_T     notify_rfd;   /* read-end:  registered in xpoll            */

#ifdef _WIN32
    HANDLE       handle;
#else
    pthread_t    handle;
#endif

    void (*on_init)   (xThread*);
    void (*on_update) (xThread*);
    void (*on_cleanup)(xThread*);
};

struct xThreadPool {
    int         group_id;
    int         strategy;
    const char* name;
    xThread*    threads[XTHR_GROUP_MAX];
    atomic_int  thread_count;
    atomic_int  queue_sizes[XTHR_GROUP_MAX];
    atomic_int  next_index;
};

/* ============================================================================
** Global state
** ========================================================================== */

static xThread* _threads[XTHR_MAX];
static xMutex   _lock;
static bool     _init = false;

void xthread_wakeup_uninit(void);

#ifdef _WIN32
static DWORD _tls = TLS_OUT_OF_INDEXES;
#else
static pthread_key_t  _tls;
static pthread_once_t _tls_once = PTHREAD_ONCE_INIT;
static void tls_init_once(void) { pthread_key_create(&_tls, NULL); }
#endif

/* ============================================================================
** TLS helpers
** ========================================================================== */

static void tls_set(int id) {
#ifdef _WIN32
    TlsSetValue(_tls, (LPVOID)(intptr_t)id);
#else
    pthread_setspecific(_tls, (void*)(intptr_t)id);
#endif
}

static int tls_get(void) {
#ifdef _WIN32
    return (int)(intptr_t)TlsGetValue(_tls);
#else
    return (int)(intptr_t)pthread_getspecific(_tls);
#endif
}

/* ============================================================================
** Windows socketpair (TCP loopback)
** ========================================================================== */

#ifdef _WIN32
static int win_socketpair(SOCKET fds[2]) {
    struct sockaddr_in addr;
    int addrlen = sizeof(addr);

    memset(&addr, 0, sizeof(addr));
    addr.sin_family      = AF_INET;
    addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    addr.sin_port        = 0;

    SOCKET listener = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
    if (listener == INVALID_SOCKET) return -1;

    if (bind  (listener, (struct sockaddr*)&addr, sizeof(addr)) != 0 ||
        listen(listener, 1)                                      != 0 ||
        getsockname(listener, (struct sockaddr*)&addr, &addrlen) != 0) {
        closesocket(listener);
        return -1;
    }

    fds[0] = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
    if (fds[0] == INVALID_SOCKET) { closesocket(listener); return -1; }

    if (connect(fds[0], (struct sockaddr*)&addr, sizeof(addr)) != 0) {
        closesocket(fds[0]); closesocket(listener); return -1;
    }

    fds[1] = accept(listener, NULL, NULL);
    closesocket(listener);
    if (fds[1] == INVALID_SOCKET) { closesocket(fds[0]); return -1; }

    u_long mode = 1;
    ioctlsocket(fds[0], FIONBIO, &mode);
    ioctlsocket(fds[1], FIONBIO, &mode);
    return 0;
}
#endif /* _WIN32 */

/* ============================================================================
** xQueue  (static – never exposed to callers)
** ========================================================================== */

/* Allocate the per-queue task slab and chain its nodes onto the freelist.
** Called from xqueue_init; returns false on allocation failure. */
static bool xqueue_pool_init(xQueue* q, int capacity) {
    if (capacity <= 0) {
        q->pool_storage   = NULL;
        q->pool_capacity  = 0;
        q->freelist       = NULL;
        q->freelist_count = 0;
        return true;
    }
    xthrTask* slab = (xthrTask*)calloc((size_t)capacity, sizeof(xthrTask));
    if (!slab) return false;
    q->pool_storage  = slab;
    q->pool_capacity = capacity;
    /* Chain backwards so first allocations come from the front of the slab. */
    xthrTask* head = NULL;
    for (int i = 0; i < capacity; i++) {
        slab[i].from_heap = 0;
        slab[i].next      = head;
        head              = &slab[i];
    }
    q->freelist       = head;
    q->freelist_count = capacity;
    return true;
}

static bool xqueue_init(xQueue* q) {
    memset(q, 0, sizeof(*q));
    q->max_size = XTHREAD_QUEUE_MAX_DEFAULT;
    xnet_mutex_init(&q->lock);

    /* In MPSC mode the task list (head/tail/size/freelist) is unused —
    ** xQueue is kept only for its wakeup primitives (event/cond). Skip the
    ** ~70KB task slab to avoid wasted memory across many threads. */
#ifdef XTHREAD_MPSCQ
    if (!xqueue_pool_init(q, 0)) {
#else
    if (!xqueue_pool_init(q, XTHREAD_TASK_POOL_SIZE)) {
#endif
        xnet_mutex_uninit(&q->lock);
        return false;
    }

#ifdef _WIN32
    q->event = CreateEvent(NULL, FALSE, FALSE, NULL); /* auto-reset */
    if (!q->event) {
        free(q->pool_storage);
        xnet_mutex_uninit(&q->lock);
        return false;
    }
    return true;
#else
    if (pthread_mutex_init(&q->wait_mutex, NULL) != 0) {
        free(q->pool_storage);
        xnet_mutex_uninit(&q->lock);
        return false;
    }
    if (pthread_cond_init(&q->cond, NULL) != 0) {
        pthread_mutex_destroy(&q->wait_mutex);
        free(q->pool_storage);
        xnet_mutex_uninit(&q->lock);
        return false;
    }
    return true;
#endif
}

/* Free a single task node according to its from_heap / arg_external flags.
** Pool nodes are NOT returned to the freelist here — caller is destroying
** the queue, so the entire slab is released afterwards. */
static void xqueue_release_task_destroy(xthrTask* t) {
    if (t->arg_external && t->arg_ptr) free(t->arg_ptr);
    if (t->from_heap) free(t);
}

static void xqueue_uninit(xQueue* q) {
    /* Free unprocessed task nodes (queue is being destroyed: just release
    ** any external arg buffers and any heap-allocated overflow nodes; the
    ** pool slab is freed wholesale below). */
    xthrTask* t = q->head;
    while (t) {
        xthrTask* next = t->next;
        xqueue_release_task_destroy(t);
        t = next;
    }
    q->head = q->tail = NULL;
    q->size = 0;

    /* Release the pre-allocated slab. */
    if (q->pool_storage) {
        free(q->pool_storage);
        q->pool_storage   = NULL;
        q->pool_capacity  = 0;
        q->freelist       = NULL;
        q->freelist_count = 0;
    }

#ifdef _WIN32
    if (q->event) { CloseHandle(q->event); q->event = NULL; }
#else
    pthread_cond_destroy (&q->cond);
    pthread_mutex_destroy(&q->wait_mutex);
#endif
    xnet_mutex_uninit(&q->lock);
}

#ifndef XTHREAD_MPSCQ
/* Try to take a task node from the freelist while holding q->lock.
** Returns NULL if pool is empty (caller must malloc one outside the lock). */
static xthrTask* xqueue_freelist_take_locked(xQueue* q) {
    xthrTask* t = q->freelist;
    if (!t) return NULL;
    q->freelist = t->next;
    q->freelist_count--;
    return t;
}

/* Return a pool node to the freelist. Caller must hold q->lock. */
static void xqueue_freelist_return_locked(xQueue* q, xthrTask* t) {
    t->next     = q->freelist;
    q->freelist = t;
    q->freelist_count++;
}
#endif /* !XTHREAD_MPSCQ */

#ifndef XTHREAD_MPSCQ
/* Enqueue a task.
**
** ignore_max:
**   false → standard backpressure (return -2 when q->size >= q->max_size)
**   true  → bypass cap (used by xthread_post_reply)
**
** out_new_size    – new queue depth (NULL to ignore).
** out_need_notify – true when caller should send a wakeup signal.
**
** Returns: 0 success, -1 malloc failed, -2 queue full (only when !ignore_max).
**
** Convention: every malloc/free happens outside q->lock. The critical
** section only does O(1) pointer/counter updates and freelist swaps. */
static int xqueue_push_internal(xQueue* q, XThreadFunc func,
                                const void* arg, size_t arg_len,
                                bool ignore_max,
                                uint64_t deadline_ms,
                                int* out_new_size, bool* out_need_notify) {
    /* Decide whether arg payload needs an external buffer (out-of-band copy).
    ** arg_len == 0           → pointer semantics, no copy
    ** arg_len <= INLINE      → copied into task->arg_buf later
    ** arg_len  > INLINE      → copy into a fresh malloc buffer (this branch). */
    void* ext_buf = NULL;
    if (arg_len > XTHREAD_TASK_ARG_INLINE) {
        ext_buf = malloc(arg_len);
        if (!ext_buf) return -1;
        if (arg) memcpy(ext_buf, arg, arg_len);
    }

    /* Acquire a node: try pool first, fall back to malloc outside the lock. */
    xnet_mutex_lock(&q->lock);
    if (!ignore_max && q->max_size > 0 && q->size >= q->max_size) {
        xnet_mutex_unlock(&q->lock);
        if (ext_buf) free(ext_buf);
        return -2;
    }
    xthrTask* task = xqueue_freelist_take_locked(q);
    xnet_mutex_unlock(&q->lock);

    bool from_heap = false;
    if (!task) {
        task = (xthrTask*)malloc(sizeof(xthrTask));
        if (!task) {
            if (ext_buf) free(ext_buf);
            return -1;
        }
        from_heap = true;
    }

    /* Populate node (outside the lock — this node is private to us). */
    task->func         = func;
    task->next         = NULL;
    task->arg_len      = (uint32_t)arg_len;
    task->from_heap    = from_heap ? 1 : 0;
    task->arg_external = ext_buf ? 1 : 0;
    task->deadline_ms  = deadline_ms;
    if (arg_len == 0) {
        task->arg_ptr = (void*)arg;            /* pointer semantics */
    } else if (ext_buf) {
        task->arg_ptr = ext_buf;               /* large copy, freed later */
    } else if (arg_len > 0 && arg) {
        memcpy(task->arg_buf, arg, arg_len);   /* inline copy */
    }

    /* Enqueue node (outside the lock — this node is private to us). 
    * 
    *  The max_size parameter is used for backpressure control. 
    *  It only needs to provide basic backpressure effects and 
    *  does not have to strictly prevent values from exceeding max_size. 
    *  Therefore, there is no need to add an additional judgment on max_size here.
    * */
    xnet_mutex_lock(&q->lock);
    if (q->tail) { q->tail->next = task; q->tail = task; }
    else          { q->head = q->tail = task; }
    q->size++;
    int  new_size    = q->size;
    bool need_notify = (q->pending == 0);
    if (need_notify) q->pending = 1;
    xnet_mutex_unlock(&q->lock);

    if (out_new_size)    *out_new_size    = new_size;
    if (out_need_notify) *out_need_notify = need_notify;
    return 0;
}
#endif /* !XTHREAD_MPSCQ */

#ifdef XTHREAD_MPSCQ
/* Lock-free producer push for MPSC mode.
**
** ignore_max:
**   false → soft backpressure (return -2 when pending_tasks >= max_pending_tasks)
**   true  → bypass cap (used by reply path)
**
** out_new_size    – approximate post-push depth (NULL to ignore).
** out_need_notify – true when caller should send a wakeup signal.
**
** Returns: 0 success, -1 malloc failed, -2 backpressure (only when !ignore_max).
**
** Ordering rules:
**   1. xmpsc_push (release CAS) MUST happen before notify_pending exchange,
**      otherwise the consumer can wake on an empty queue and miss the task.
**   2. pending_tasks fetch_add is a soft counter; transient drift is OK. */
static int xmpscq_push_internal(xThread* t, XThreadFunc func,
                                const void* arg, size_t arg_len,
                                bool ignore_max,
                                uint64_t deadline_ms,
                                int* out_new_size, bool* out_need_notify) {
    void* ext_buf = NULL;
    if (arg_len > XTHREAD_TASK_ARG_INLINE) {
        ext_buf = malloc(arg_len);
        if (!ext_buf) return -1;
        if (arg) memcpy(ext_buf, arg, arg_len);
    }

    if (!ignore_max && t->max_pending_tasks > 0) {
        int pending = atomic_load(&t->pending_tasks);
        if (pending >= t->max_pending_tasks) {
            if (ext_buf) free(ext_buf);
            return -2;
        }
    }

    xthrTask* task = (xthrTask*)malloc(sizeof(xthrTask));
    if (!task) {
        if (ext_buf) free(ext_buf);
        return -1;
    }

    task->func         = func;
    task->next         = NULL;
    task->arg_len      = (uint32_t)arg_len;
    task->from_heap    = 1;
    task->arg_external = ext_buf ? 1 : 0;
    task->deadline_ms  = deadline_ms;
    xmpsc_node_init(&task->node);
    if (arg_len == 0) {
        task->arg_ptr = (void*)arg;
    } else if (ext_buf) {
        task->arg_ptr = ext_buf;
    } else if (arg_len > 0 && arg) {
        memcpy(task->arg_buf, arg, arg_len);
    }

    int new_pending = atomic_fetch_add(&t->pending_tasks, 1) + 1;
    xmpsc_push(&t->task_queue, &task->node);

    bool need_notify = (atomic_exchange(&t->notify_pending, 1) == 0);

    if (out_new_size)    *out_new_size    = new_pending;
    if (out_need_notify) *out_need_notify = need_notify;
    return 0;
}

/* Drain remaining tasks from the MPSC queue at thread teardown.
** Caller must guarantee no producer is still pushing. */
static void xmpscq_drain_destroy(xThread* t) {
    xMPSCNode* n;
    while ((n = xmpsc_pop(&t->task_queue)) != NULL) {
        xthrTask* task = XMPSC_CONTAINER_OF(n, xthrTask, node);
        if (task->arg_external && task->arg_ptr) free(task->arg_ptr);
        free(task);
    }
    atomic_store(&t->pending_tasks, 0);
    atomic_store(&t->notify_pending, 0);
}
#endif /* XTHREAD_MPSCQ */

#ifndef XTHREAD_MPSCQ
static int xqueue_push_deadline(xQueue* q, XThreadFunc func,
                                const void* arg, size_t arg_len,
                                uint64_t deadline_ms,
                                int* out_new_size, bool* out_need_notify) {
    return xqueue_push_internal(q, func, arg, arg_len,
                                /*ignore_max=*/false,
                                deadline_ms,
                                out_new_size, out_need_notify);
}

static int xqueue_push_reply(xQueue* q, XThreadFunc func,
                             const void* arg, size_t arg_len,
                             int* out_new_size, bool* out_need_notify) {
    return xqueue_push_internal(q, func, arg, arg_len,
                                /*ignore_max=*/true,
                                /*deadline_ms=*/0,
                                out_new_size, out_need_notify);
}

/* Atomically dequeue all tasks; returns head of linked list.
** Caller traverses and frees each node.
** Also resets pending so the next push can fire a fresh notification. */
static xthrTask* xqueue_pop_all(xQueue* q) {
    xnet_mutex_lock(&q->lock);
    q->pending     = 0;
    xthrTask* head = q->head;
    q->head = q->tail = NULL;
    q->size = 0;
    xnet_mutex_unlock(&q->lock);
    return head;
}
#endif /* !XTHREAD_MPSCQ */

/* Block until a task arrives or timeout elapses.
** Used only by threads that do NOT have an xPollState. */
static void xqueue_wait(xQueue* q, int timeout_ms) {
#ifdef _WIN32
    DWORD ms = (timeout_ms < 0) ? INFINITE : (DWORD)timeout_ms;
    WaitForSingleObject(q->event, ms);
#else
    pthread_mutex_lock(&q->wait_mutex);
    if (timeout_ms < 0) {
        pthread_cond_wait(&q->cond, &q->wait_mutex);
    } else {
        struct timespec ts;
        clock_gettime(CLOCK_REALTIME, &ts);
        ts.tv_sec  +=  timeout_ms / 1000;
        ts.tv_nsec += (long)(timeout_ms % 1000) * 1000000L;
        if (ts.tv_nsec >= 1000000000L) {
            ts.tv_sec++;
            ts.tv_nsec -= 1000000000L;
        }
        pthread_cond_timedwait(&q->cond, &q->wait_mutex, &ts);
    }
    pthread_mutex_unlock(&q->wait_mutex);
#endif
}

/* ============================================================================
** Task dispatch
** ========================================================================== */

/* Resolve callback arg pointer based on storage class.
**   arg_len == 0          → raw pointer in arg_ptr
**   arg_external          → external malloc buffer in arg_ptr
**   otherwise (inline)    → arg_buf */
static inline void* task_arg_ptr(xthrTask* t) {
    if (t->arg_len == 0) return t->arg_ptr;
    if (t->arg_external) return t->arg_ptr;
    return (void*)t->arg_buf;
}

static inline bool task_deadline_expired(xthrTask* t) {
    return t->deadline_ms != 0 && time_clock_ms() >= t->deadline_ms;
}

#ifdef XTHREAD_MPSCQ
static int process_tasks(xThread* ctx) {
    int count = 0;

    /* Reset notify flag BEFORE draining. A producer that pushes between this
    ** store and the next pop will set the flag back to 1 (and notify), so the
    ** consumer is guaranteed to be woken again on the next iteration. */
    atomic_store(&ctx->notify_pending, 0);

    xMPSCNode* n;
    while ((n = xmpsc_pop(&ctx->task_queue)) != NULL) {
        xthrTask* task = XMPSC_CONTAINER_OF(n, xthrTask, node);
        void*     a    = task_arg_ptr(task);

        if (!task_deadline_expired(task) && task->func) {
            task->func(ctx, a, (int)task->arg_len);
        }

        if (task->arg_external && task->arg_ptr) free(task->arg_ptr);
        free(task);

        atomic_fetch_sub(&ctx->pending_tasks, 1);
        count++;
    }
    return count;
}
#else
static int process_tasks(xThread* ctx) {
    int count = 0;
    xQueue*   q    = &ctx->queue;

    xthrTask* task = xqueue_pop_all(q);

    /* Locally batch pool nodes for return; free heap nodes individually. */
    xthrTask* return_head = NULL;
    int       return_count = 0;

    while (task) {
        xthrTask* next = task->next;
        void*     a    = task_arg_ptr(task);

        if (!task_deadline_expired(task) && task->func) {
            task->func(ctx, a, (int)task->arg_len);
        }

        /* Release external arg payload (if any). */
        if (task->arg_external && task->arg_ptr) {
            free(task->arg_ptr);
            task->arg_ptr      = NULL;
            task->arg_external = 0;
        }

        if (task->from_heap) {
            free(task);
        } else {
            /* Pool node — chain into local batch, return all under one lock. */
            task->next   = return_head;
            return_head  = task;
            return_count++;
        }
        count++;
        task = next;
    }

    if (return_head) {
        xnet_mutex_lock(&q->lock);
        while (return_head) {
            xthrTask* nx = return_head->next;
            xqueue_freelist_return_locked(q, return_head);
            return_head = nx;
        }
        xnet_mutex_unlock(&q->lock);
        (void)return_count;
    }
    return count;
}
#endif /* XTHREAD_MPSCQ */

/* ============================================================================
** Wakeup notification
** ========================================================================== */

/* xpoll read-end callback: drain notification bytes then dispatch tasks. */
static void notify_read_cb(SOCKET_T fd, int mask, void* clientData) {
    (void)mask;
    char buf[64];
#ifdef _WIN32
    while (recv((SOCKET)fd, buf, sizeof(buf), 0) > 0);
#else
    while (read((int)fd, buf, sizeof(buf)) > 0);
#endif
    xThread* ctx = (xThread*)clientData;
    if (!ctx) return;
    process_tasks(ctx);
}

/* Unified notification: fd write when poll is present, cond/Event otherwise. */
static void xthread_notify(xThread* target, bool need_notify) {
    if (!need_notify) return;

    if (target->poll && target->notify_wfd != INVALID_SOCKET_VAL) {
        /* Poke the poll fd */
        char c = '!';
#ifdef _WIN32
        if (send((SOCKET)target->notify_wfd, &c, 1, 0) < 0) {
            int err = WSAGetLastError();
            if (atomic_load(&target->running)) {
                XLOGE("Thread[%d:%s] notify send failed: %d",
                      target->id, target->name, err);
            }
        }
#else
        if (write((int)target->notify_wfd, &c, 1) < 0 && errno != EAGAIN) {
            if (atomic_load(&target->running)) {
                XLOGE("Thread[%d:%s] notify write failed: %s",
                      target->id, target->name, strerror(errno));
            }
        }
#endif
    } else {
        /* Signal the blocking primitive */
#ifdef _WIN32
        SetEvent(target->queue.event);
#else
        pthread_cond_signal(&target->queue.cond);
#endif
    }
}

/* ============================================================================
** Wakeup initialisation/uninitialisation
**
** Must be called once per thread to arm its wakeup mechanism:
**
**   Worker thread  – call from on_init callback; pass (0, NULL), the id/name
**                    are ignored because the thread is already registered.
**
**   Main thread    – call before the event loop; pass the desired id/name.
**                    Internally calls xthread_register_main when the current
**                    thread has not yet been registered (detected via TLS).
**
** The function inspects xpoll_get_default():
**   non-NULL  →  creates a socketpair; read-end is registered in the poll
**                instance; write-end is used by xthread_post to wake up the
**                thread's xpoll_poll() call.
**   NULL      →  uses pthread_cond_signal (POSIX) / SetEvent (Windows).
**
** xthread_wakeup_uninit must be called from the same thread (e.g. on_cleanup)
** before the poll instance is destroyed.
** ========================================================================== */
int xthread_wakeup_init() {
    xThread* ctx = xthread_current();
    assert(ctx != NULL);

    xPollState* poll = xpoll_get_default();

    if (ctx->poll) {
        if (ctx->poll == poll) {
            process_tasks(ctx);
            return 0;
        }
        xthread_wakeup_uninit();
    }

    if (poll) {
        /* ── fd-based wakeup ─────────────────────────────────── */
#ifdef _WIN32
        SOCKET fds[2] = { INVALID_SOCKET, INVALID_SOCKET };
        if (win_socketpair(fds) != 0) {
            XLOGE("Thread[%d:%s] win_socketpair failed: %d",
                  ctx->id, ctx->name, WSAGetLastError());
            return -1;
        }
#else
        int fds[2];
        if (socketpair(AF_UNIX, SOCK_STREAM, 0, fds) != 0) {
            XLOGE("Thread[%d:%s] socketpair failed: %s",
                  ctx->id, ctx->name, strerror(errno));
            return -1;
        }
        fcntl(fds[0], F_SETFL, O_NONBLOCK);
        fcntl(fds[1], F_SETFL, O_NONBLOCK);
#endif
        /* Register the read-end in the poll instance */
        if (xpoll_add_event((SOCKET_T)fds[1], XPOLL_READABLE,
                            notify_read_cb, NULL, NULL, ctx) != 0) {
            XLOGE("Thread[%d:%s] xpoll_add_event failed", ctx->id, ctx->name);
#ifdef _WIN32
            closesocket(fds[0]); closesocket(fds[1]);
#else
            close(fds[0]); close(fds[1]);
#endif
            return -1;
        }

        ctx->poll       = poll;
        ctx->notify_wfd = (SOCKET_T)fds[0]; /* push writes here   */
        ctx->notify_rfd = (SOCKET_T)fds[1]; /* poll monitors this */

        XLOGI("Thread[%d:%s] wakeup=fd  wfd=%d rfd=%d",
              ctx->id, ctx->name, (int)fds[0], (int)fds[1]);
    } else {
        /* ── cond / Event wakeup (primitives already in xQueue) ─ */
        ctx->poll       = NULL;
        ctx->notify_wfd = INVALID_SOCKET;
        ctx->notify_rfd = INVALID_SOCKET;

        XLOGI("Thread[%d:%s] wakeup=cond", ctx->id, ctx->name);
    }

    /* Dispatch any tasks that were posted before the wakeup fd was ready */
    process_tasks(ctx);
    return 0;
}

void xthread_wakeup_uninit(void) {
    xThread* ctx = xthread_current();
    if (!ctx || !ctx->poll) return;

    xpoll_del_event(ctx->notify_rfd, XPOLL_READABLE);

#ifdef _WIN32
    closesocket((SOCKET)ctx->notify_rfd);
    closesocket((SOCKET)ctx->notify_wfd);
#else
    close((int)ctx->notify_rfd);
    close((int)ctx->notify_wfd);
#endif

    ctx->poll       = NULL;
    ctx->notify_rfd = INVALID_SOCKET;
    ctx->notify_wfd = INVALID_SOCKET;

    XLOGI("Thread[%d:%s] wakeup uninit", ctx->id, ctx->name);
}


/* ============================================================================
** Internal: register the calling (main) thread without creating an OS thread
** ========================================================================== */

static bool xthread_register_main(int id, const char* name) {
    if (id <= 0 || id >= XTHR_MAX || !_init) return false;

    xnet_mutex_lock(&_lock);
    if (_threads[id]) { xnet_mutex_unlock(&_lock); return false; }

    xThread* ctx = (xThread*)calloc(1, sizeof(xThread));
    if (!ctx) { xnet_mutex_unlock(&_lock); return false; }

    ctx->id         = id;
    strncpy(ctx->name, name, sizeof(ctx->name) - 1);
    ctx->name[sizeof(ctx->name) - 1] = '\0';  /* ensure null-terminated */
    ctx->group      = NULL;
    ctx->poll       = NULL;
    ctx->notify_wfd = INVALID_SOCKET;
    ctx->notify_rfd = INVALID_SOCKET;
    atomic_store(&ctx->running, true);

#ifdef XTHREAD_MPSCQ
    xmpsc_queue_init(&ctx->task_queue);
    atomic_store(&ctx->pending_tasks, 0);
    atomic_store(&ctx->notify_pending, 0);
    ctx->max_pending_tasks = XTHREAD_QUEUE_MAX_DEFAULT;
#endif

    if (!xqueue_init(&ctx->queue)) {
        free(ctx);
        xnet_mutex_unlock(&_lock);
        return false;
    }

    _threads[id] = ctx;
    tls_set(id);
    xnet_mutex_unlock(&_lock);
    return true;
}

/* ============================================================================
** thread internal init / uninit
** ========================================================================== */
static inline void xthread_internal_init(xThread* ctx) {
    if (ctx->on_init) ctx->on_init(ctx);
    xthread_wakeup_init();
}

static inline void xthread_internal_update(xThread* ctx) {
    process_tasks(ctx);
    if (ctx->on_update) ctx->on_update(ctx);
}

static inline void xthread_internal_uninit(xThread* ctx) {
    xthread_wakeup_uninit(); // must first uninit
    if (ctx->on_cleanup) ctx->on_cleanup(ctx);
}

/* ============================================================================
** Worker thread entry point
** ========================================================================== */

#ifdef _WIN32
static unsigned __stdcall worker_func(void* arg) {
#else
static void* worker_func(void* arg) {
#endif
    xThread* ctx = (xThread*)arg;
    tls_set(ctx->id);
    XLOGI("Thread[%d:%s] started", ctx->id, ctx->name);

    xthread_internal_init(ctx);
    /* on_init is expected to call xthread_wakeup_init(), which sets ctx->poll */

    while (atomic_load(&ctx->running)) {
        if (ctx->poll) {
            /* Poll-driven: on_update calls xpoll_poll().
               Tasks arrive via notify_read_cb invoked inside xpoll_poll(). */
            xthread_internal_update(ctx);
        } else {
            /* Cond/Event-driven: block, then dispatch, then run user update. */
            xqueue_wait(&ctx->queue, 100);
            xthread_internal_update(ctx);
        }
    }

    process_tasks(ctx); /* flush tasks posted after stop was requested */
    xthread_internal_uninit(ctx);
    XLOGI("Thread[%d:%s] stopped", ctx->id, ctx->name);

#ifdef _WIN32
    return 0;
#else
    return NULL;
#endif
}

/* ============================================================================
** Global API
** ========================================================================== */

bool xthread_init(void) {
    if (_init) return true;
    xnet_mutex_init(&_lock);
    memset(_threads, 0, sizeof(_threads));
#ifdef _WIN32
    _tls = TlsAlloc();
    if (_tls == TLS_OUT_OF_INDEXES) return false;
#else
    pthread_once(&_tls_once, tls_init_once);
#endif
    _init = true;

    // init main thread
    xThread* ctx = xthread_current();
    if (!ctx) {
        /* TLS is empty → calling thread is not yet registered.
           Treat it as the main thread and register it now. */
        if (!xthread_register_main(XTHR_MAIN, "main")) {
            XLOGE("xthread_wakeup_init: register_main(%d, '%s') failed", XTHR_MAIN, "main");
            return false;
        }
        xthread_wakeup_init();
    }
    return true;
}

void xthread_uninit(void) {
    if (!_init) return;
    xThread* main_ctx = _threads[XTHR_MAIN];
    if (main_ctx) xthread_wakeup_uninit(); // xthread_unregister_main(XTHR_MAIN);

    for (int i = 0; i < XTHR_MAX; i++) {
        if (_threads[i]) xthread_unregister(i);
    }
#ifdef _WIN32
    if (_tls != TLS_OUT_OF_INDEXES) { TlsFree(_tls); _tls = TLS_OUT_OF_INDEXES; }
#endif
    xnet_mutex_uninit(&_lock);
    _init = false;
}

bool xthread_register_ex(int id, const char* name,
                      void (*on_init)   (xThread*),
                      void (*on_update) (xThread*),
                      void (*on_cleanup)(xThread*)
                      , void* userdata) {
    if (id <= 0 || id >= XTHR_MAX || !_init) return false;

    xnet_mutex_lock(&_lock);
    if (_threads[id]) { xnet_mutex_unlock(&_lock); return false; }

    xThread* ctx = (xThread*)calloc(1, sizeof(xThread));
    if (!ctx) { xnet_mutex_unlock(&_lock); return false; }

    ctx->id         = id;
    strncpy(ctx->name, name, sizeof(ctx->name) - 1);
    ctx->name[sizeof(ctx->name) - 1] = '\0';  /* ensure null-terminated */
    ctx->on_init    = on_init;
    ctx->on_update  = on_update;
    ctx->on_cleanup = on_cleanup;
    ctx->userdata   = userdata;
    ctx->group      = NULL;
    ctx->poll       = NULL;
    ctx->notify_wfd = INVALID_SOCKET;
    ctx->notify_rfd = INVALID_SOCKET;
    atomic_store(&ctx->running, true);

#ifdef XTHREAD_MPSCQ
    xmpsc_queue_init(&ctx->task_queue);
    atomic_store(&ctx->pending_tasks, 0);
    atomic_store(&ctx->notify_pending, 0);
    ctx->max_pending_tasks = XTHREAD_QUEUE_MAX_DEFAULT;
#endif
    if (!xqueue_init(&ctx->queue)) {
        free(ctx);
        xnet_mutex_unlock(&_lock);
        return false;
    }

    _threads[id] = ctx;

#ifdef _WIN32
    ctx->handle = (HANDLE)_beginthreadex(NULL, 0, worker_func, ctx, 0, NULL);
    if (!ctx->handle) {
        xqueue_uninit(&ctx->queue);
        free(ctx);
        _threads[id] = NULL;
        xnet_mutex_unlock(&_lock);
        return false;
    }
#else
    if (pthread_create(&ctx->handle, NULL, worker_func, ctx) != 0) {
        xqueue_uninit(&ctx->queue);
        free(ctx);
        _threads[id] = NULL;
        xnet_mutex_unlock(&_lock);
        return false;
    }
#endif

    xnet_mutex_unlock(&_lock);
    return true;
}

bool xthread_register(int id, const char* name,
                      void (*on_init)   (xThread*),
                      void (*on_update) (xThread*),
                      void (*on_cleanup)(xThread*))
{
    return xthread_register_ex(id, name, on_init, on_update, on_cleanup, NULL);
}

void xthread_unregister(int id) {
    if (id <= 0 || id >= XTHR_MAX) return;
    xnet_mutex_lock(&_lock);
    xThread* ctx = _threads[id];
    if (!ctx) { xnet_mutex_unlock(&_lock); return; }
    atomic_store(&ctx->running, false);
    _threads[id] = NULL;
    xnet_mutex_unlock(&_lock);

    #ifdef _WIN32
        bool is_worker = (ctx->handle != NULL);
    #else
        bool is_worker = (ctx->handle != 0);
    #endif

    if (is_worker) {
        /* Sub-thread: wake it up and let worker_func complete the cleanup process by itself */
        xthread_notify(ctx, true);
#ifdef _WIN32
        WaitForSingleObject(ctx->handle, INFINITE);
        CloseHandle(ctx->handle);
#else
        pthread_join(ctx->handle, NULL);
#endif
        /* process_tasks / on_cleanup / xthread_wakeup_uninit
            已在 worker_func 的 xthread_internal_uninit 中完成 */
    } else {
        /* Main thread: No worker_func exists, manually supplement the same final cleanup steps */
        process_tasks(ctx);
        xthread_internal_uninit(ctx);  // on_cleanup → xthread_wakeup_uninit
    }

    xqueue_uninit(&ctx->queue);
#ifdef XTHREAD_MPSCQ
    /* Final drain: process_tasks already ran, but a late producer (between
    ** running=false and our notify) could have slipped a task in. Free any
    ** remaining nodes so we don't leak. */
    xmpscq_drain_destroy(ctx);
#endif
    free(ctx);
}

xThread* xthread_get       (int id) {
    if (id <= 0 || id >= XTHR_MAX) return NULL;
    return _threads[id];
}
int      xthread_current_id(void) { return tls_get(); }
xThread* xthread_current   (void) { return xthread_get(tls_get()); }

int xthread_update(int timeout_ms) {
    xThread* ctx = xthread_current();
    if (!ctx) return 0;

    int n = process_tasks(ctx);
    if (ctx->poll) return n;

    // Only wait if queue is still empty after processing tasks
#ifdef XTHREAD_MPSCQ
    bool empty = xmpsc_empty(&ctx->task_queue);
#else
    xnet_mutex_lock(&ctx->queue.lock);
    bool empty = (ctx->queue.size == 0);
    xnet_mutex_unlock(&ctx->queue.lock);
#endif

    if (empty) {
        xqueue_wait(&ctx->queue, timeout_ms);
        n += process_tasks(ctx);
    }
    return n;
}

int xthread_post(int target_id, XThreadFunc func,
                 const void* arg, size_t arg_len) {
    return xthread_post_deadline(target_id, func, arg, arg_len, 0);
}

int xthread_post_deadline(int target_id, XThreadFunc func,
                          const void* arg, size_t arg_len,
                          uint64_t deadline_ms) {
    xThread* target = xthread_get(target_id);
    if (!target || !atomic_load(&target->running)) {
        XLOGE("xthread_post: no thread available for id=%d", target_id);
        return -1;
    }

    xThreadPool* group    = target->group;
    xThread*     selected = group ? xthread_pool_select_thread(group) : target;
    if (!selected) {
        XLOGE("xthread_post: no thread available for id=%d", target_id);
        return -1;
    }

    int  new_size    = 0;
    bool need_notify = false;
#ifdef XTHREAD_MPSCQ
    int err = xmpscq_push_internal(selected, func, arg, arg_len,
                                    /*ignore_max=*/false,
                                    deadline_ms,
                                    &new_size, &need_notify);
#else
    int err = xqueue_push_deadline(&selected->queue, func, arg, arg_len,
                                   deadline_ms, &new_size, &need_notify);
#endif
    if (err == 0) {
        if (group) {
            /* Update pool's load tracker */
            int count = atomic_load(&group->thread_count);
            for (int i = 0; i < count; i++) {
                if (group->threads[i] && group->threads[i]->id == selected->id) {
                    atomic_store(&group->queue_sizes[i], new_size);
                    break;
                }
            }
        }
        xthread_notify(selected, need_notify);
    }
    return err;
}

int xthread_get_queue_depth(int id) {
    xThread* thr = xthread_get(id);
    if (!thr) return -1;
#ifdef XTHREAD_MPSCQ
    return atomic_load(&thr->pending_tasks);
#else
    xnet_mutex_lock(&thr->queue.lock);
    int depth = thr->queue.size;
    xnet_mutex_unlock(&thr->queue.lock);
    return depth;
#endif
}

int xthread_get_queue_max(int id) {
    xThread* thr = xthread_get(id);
    if (!thr) return -1;
#ifdef XTHREAD_MPSCQ
    return thr->max_pending_tasks;
#else
    xnet_mutex_lock(&thr->queue.lock);
    int max = thr->queue.max_size;
    xnet_mutex_unlock(&thr->queue.lock);
    return max;
#endif
}

int xthread_set_queue_max(int target_id, int new_max) {
    xThread* target = xthread_get(target_id);
    if (!target) return -1;
    if (new_max < 0) new_max = 0;

#ifdef XTHREAD_MPSCQ
    target->max_pending_tasks = new_max;
#else
    xnet_mutex_lock(&target->queue.lock);
    target->queue.max_size = new_max;
    xnet_mutex_unlock(&target->queue.lock);
#endif
    return 0;
}

/* Reply path: no pool selection, no max_size cap. Sends directly to the
** thread identified by target_id so the reply reaches the originating thread. */
int xthread_post_reply(int target_id, XThreadFunc func,
                       const void* arg, size_t arg_len) {
    xThread* target = xthread_get(target_id);
    if (!target || !atomic_load(&target->running)) {
        XLOGE("xthread_post_reply: no thread available for id=%d", target_id);
        return -1;
    }

    int  new_size    = 0;
    bool need_notify = false;
#ifdef XTHREAD_MPSCQ
    int err = xmpscq_push_internal(target, func, arg, arg_len,
                                    /*ignore_max=*/true,
                                    /*deadline_ms=*/0,
                                    &new_size, &need_notify);
#else
    int err = xqueue_push_reply(&target->queue, func, arg, arg_len,
                                &new_size, &need_notify);
#endif
    if (err == 0) {
        /* No pool load-tracker update for direct reply. */
        xthread_notify(target, need_notify);
    }
    return err;
}

/* ============================================================================
** xThread accessors
** ========================================================================== */

int         xthread_get_id      (xThread* thr) { return thr ? thr->id       : 0;    }
const char* xthread_get_name    (xThread* thr) { return thr ? thr->name     : NULL; }
void*       xthread_get_userdata(xThread* thr) { return thr ? thr->userdata : NULL; }
void        xthread_set_userdata(xThread* thr, void* data) { if (thr) thr->userdata = data; }

/* ============================================================================
** Thread pool
** ========================================================================== */

xThreadPool* xthread_pool_create(int group_id, int strategy, const char* name) {
    xThreadPool* pool = (xThreadPool*)calloc(1, sizeof(xThreadPool));
    if (!pool) return NULL;
    if (strategy == XTHSTRATEGY_LEAST_QUEUE) {
        XLOGW("ThreadPool[%s]: LEAST_QUEUE is temporarily disabled, fallback to ROUND_ROBIN",
              name ? name : "unnamed");
        strategy = XTHSTRATEGY_ROUND_ROBIN;
    }
    pool->group_id = group_id;
    pool->strategy = strategy;
    pool->name     = name;
    atomic_store(&pool->thread_count, 0);
    atomic_store(&pool->next_index,   0);
    for (int i = 0; i < XTHR_GROUP_MAX; i++)
        atomic_store(&pool->queue_sizes[i], 0);
    return pool;
}

void xthread_pool_destroy(xThreadPool* pool) {
    free(pool);
}

bool xthread_pool_add_thread(xThreadPool* pool, xThread* thread) {
    int count = atomic_load(&pool->thread_count);
    if (count >= XTHR_GROUP_MAX) {
        XLOGE("ThreadPool[%s] reached max threads (%d)", pool->name, XTHR_GROUP_MAX);
        return false;
    }
    thread->group       = pool;
    pool->threads[count] = thread;
    atomic_store(&pool->queue_sizes[count], 0);
    atomic_store(&pool->thread_count, count + 1);
    XLOGI("Thread[%d:%s] added to pool[%d:%s]",
          thread->id, thread->name[0] ? thread->name : "unnamed",
          pool->group_id, pool->name);
    return true;
}

xThread* xthread_pool_select_thread(xThreadPool* pool) {
    int count = atomic_load(&pool->thread_count);
    if (count == 0) return NULL;

    switch (pool->strategy) {
        case XTHSTRATEGY_ROUND_ROBIN: {
            int idx = atomic_fetch_add(&pool->next_index, 1) % count;
            return pool->threads[idx];
        }
        case XTHSTRATEGY_RANDOM: {
            return pool->threads[rand() % count];
        }
        case XTHSTRATEGY_LEAST_QUEUE:
        default: {
            int best = 0;
            int min  = atomic_load(&pool->queue_sizes[0]);
            if (min == 0) return pool->threads[0];
            for (int i = 1; i < count; i++) {
                int sz = atomic_load(&pool->queue_sizes[i]);
                if (sz == 0) return pool->threads[i];
                if (sz < min) { min = sz; best = i; }
            }
            return pool->threads[best];
        }
    }
}

xThread* xthread_pool_get_thread(xThreadPool* pool, int index) {
    int count = atomic_load(&pool->thread_count);
    if (index < 0 || index >= count) return NULL;
    return pool->threads[index];
}

/* ============================================================================
** Thread group registration
** ========================================================================== */

bool xthread_register_group(int base_id, int count,
                            ThreadSelStrategy strategy,
                            const char* name_pattern,
                            void (*on_init)   (xThread*),
                            void (*on_update) (xThread*),
                            void (*on_cleanup)(xThread*)) {
    if (count <= 0 || base_id <= 0 || (base_id + count) >= XTHR_MAX)
        return false;

    xThreadPool* pool = xthread_pool_create(base_id, strategy, name_pattern);
    if (!pool) return false;

    bool all_ok = true;
    for (int i = 0; i < count; i++) {
        int  thread_id = base_id + i;
        char name[32];
        snprintf(name, sizeof(name), "%s:%02d", name_pattern, i);

        if (!xthread_register(thread_id, name, on_init, on_update, on_cleanup)) {
            XLOGE("xthread_register_group: failed to register thread %d", thread_id);
            all_ok = false;
            continue;
        }

        xThread* thread = xthread_get(thread_id);
        if (thread) xthread_pool_add_thread(pool, thread);
    }

    if (!all_ok) {
        xthread_pool_destroy(pool);
        return false;
    }
    return true;
}
