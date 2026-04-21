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

#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>
#include <assert.h>

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

typedef struct xthrTask {
    XThreadFunc      func;
    void*            arg;
    struct xthrTask* next;
} xthrTask;

typedef struct {
    xthrTask*   head;
    xthrTask*   tail;
    int         size;
    int         pending;    /* 1 = notification already in flight */
    xMutex      lock;       /* recursive mutex, guards linked list */

    /* Wakeup primitive used when the thread has no xPollState */
#ifdef _WIN32
    HANDLE          event;      /* auto-reset Event */
#else
    pthread_mutex_t wait_mutex; /* plain (non-recursive) mutex for cond */
    pthread_cond_t  cond;
#endif
} xQueue;

struct xThread {
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

static bool xqueue_init(xQueue* q) {
    memset(q, 0, sizeof(*q));
    xnet_mutex_init(&q->lock);

#ifdef _WIN32
    q->event = CreateEvent(NULL, FALSE, FALSE, NULL); /* auto-reset */
    return q->event != NULL;
#else
    if (pthread_mutex_init(&q->wait_mutex, NULL) != 0)
        return false;
    if (pthread_cond_init(&q->cond, NULL) != 0) {
        pthread_mutex_destroy(&q->wait_mutex);
        return false;
    }
    return true;
#endif
}

static void xqueue_uninit(xQueue* q) {
    /* Free unprocessed task nodes */
    xthrTask* t = q->head;
    while (t) {
        xthrTask* next = t->next;
        free(t);
        t = next;
    }
    q->head = q->tail = NULL;
    q->size = 0;

#ifdef _WIN32
    if (q->event) { CloseHandle(q->event); q->event = NULL; }
#else
    pthread_cond_destroy (&q->cond);
    pthread_mutex_destroy(&q->wait_mutex);
#endif
    xnet_mutex_uninit(&q->lock);
}

/* Enqueue a task.
** out_new_size    – new queue depth (NULL to ignore).
** out_need_notify – true when caller should send a wakeup signal. */
static bool xqueue_push(xQueue* q, XThreadFunc func, void* arg,
                         int* out_new_size, bool* out_need_notify) {
    xthrTask* task = (xthrTask*)malloc(sizeof(xthrTask));
    if (!task) return false;
    task->func = func;
    task->arg  = arg;
    task->next = NULL;

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
    return true;
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

static int process_tasks(xThread* ctx) {
    int count = 0;
    xthrTask* task = xqueue_pop_all(&ctx->queue);
    while (task) {
        xthrTask* next = task->next;
        if (task->func) task->func(ctx, task->arg);
        free(task);
        count++;
        task = next;
    }
    return count;
}

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

    /* Reset pending so the next push can trigger a new write. */
    xnet_mutex_lock(&ctx->queue.lock);
    ctx->queue.pending = 0;
    xnet_mutex_unlock(&ctx->queue.lock);

    process_tasks(ctx);
}

/* Unified notification: fd write when poll is present, cond/Event otherwise. */
static void xthread_notify(xThread* target, bool need_notify) {
    if (!need_notify) return;

    if (target->poll) {
        /* Poke the poll fd */
        char c = '!';
#ifdef _WIN32
        if (send((SOCKET)target->notify_wfd, &c, 1, 0) < 0)
            XLOGE("Thread[%d:%s] notify send failed: %d",
                  target->id, target->name, WSAGetLastError());
#else
        if (write((int)target->notify_wfd, &c, 1) < 0 && errno != EAGAIN)
            XLOGE("Thread[%d:%s] notify write failed: %s",
                  target->id, target->name, strerror(errno));
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

static bool xthread_unregister_main(int id) {
    if (id <= 0 || id >= XTHR_MAX) return false;

    xnet_mutex_lock(&_lock);
    xThread* ctx = _threads[id];
    if (!ctx) { xnet_mutex_unlock(&_lock); return false; }
    atomic_store(&ctx->running, false);
    _threads[id] = NULL;
    xnet_mutex_unlock(&_lock);

    /* Wake the thread so it can observe running=false and exit */
    xthread_notify(ctx, true);

    xqueue_uninit(&ctx->queue);
    free(ctx);
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
    if (ctx->on_cleanup) ctx->on_cleanup(ctx);
    xthread_wakeup_uninit();
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
    for (int i = 0; i < XTHR_MAX; i++) {
        if (_threads[i]) xthread_unregister(i);
    }
#ifdef _WIN32
    if (_tls != TLS_OUT_OF_INDEXES) { TlsFree(_tls); _tls = TLS_OUT_OF_INDEXES; }
#endif
    xnet_mutex_uninit(&_lock);
    _init = false;

    // init main thread uninit wakeup
    xthread_wakeup_uninit();
    // xthread_unregister_main(XTHR_MAIN);
}

bool xthread_register(int id, const char* name,
                      void (*on_init)   (xThread*),
                      void (*on_update) (xThread*),
                      void (*on_cleanup)(xThread*)) {
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
    ctx->userdata   = NULL;
    ctx->group      = NULL;
    ctx->poll       = NULL;
    ctx->notify_wfd = INVALID_SOCKET;
    ctx->notify_rfd = INVALID_SOCKET;
    atomic_store(&ctx->running, true);

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

void xthread_unregister(int id) {
    if (id <= 0 || id >= XTHR_MAX) return;
    XLOGI("Thread unregister [%d:%s]", id, _threads[id] ? _threads[id]->name : "");

    xnet_mutex_lock(&_lock);
    xThread* ctx = _threads[id];
    if (!ctx) { xnet_mutex_unlock(&_lock); return; }
    atomic_store(&ctx->running, false);
    _threads[id] = NULL;
    xnet_mutex_unlock(&_lock);

    /* Wake the thread so it can observe running=false and exit */
    xthread_notify(ctx, true);

    if (ctx->handle) {
#ifdef _WIN32
        WaitForSingleObject(ctx->handle, INFINITE);
        CloseHandle(ctx->handle);
#else
        pthread_join(ctx->handle, NULL);
#endif
    }

    xqueue_uninit(&ctx->queue);
    free(ctx);  /* name is embedded in struct, freed with struct */
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
    xnet_mutex_lock(&ctx->queue.lock);
    if (ctx->queue.size == 0) {
        xqueue_wait(&ctx->queue, timeout_ms);
    }
    xnet_mutex_unlock(&ctx->queue.lock);
    return n;
}

bool xthread_post(int target_id, XThreadFunc func, void* arg) {
    xThread* target = xthread_get(target_id);
    if (!target || !atomic_load(&target->running)) return false;

    xThreadPool* group    = target->group;
    xThread*     selected = group ? xthread_pool_select_thread(group) : target;
    if (!selected) {
        XLOGE("xthread_post: no thread available for id=%d", target_id);
        return false;
    }

    int  new_size    = 0;
    bool need_notify = false;
    bool ok = xqueue_push(&selected->queue, func, arg, &new_size, &need_notify);
    if (ok) {
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
    return ok;
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
          thread->id, thread->name ? thread->name : "unnamed",
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
