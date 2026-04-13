/* xthread.c - Thread pool and cross-thread task posting (pure C implementation) */

#include "xthread.h"
#include "xlog.h"
#include <string.h>
#include <assert.h>
#include <stdlib.h>

#ifdef _WIN32
#  include <process.h>
#else
#  include <sys/socket.h>
#  include <fcntl.h>
#  include <poll.h>
#  include <errno.h>
#endif

/* ============================================================================
** Global state
** ========================================================================== */

static xThread* _threads[XTHR_MAX];
static xMutex   _lock;
static bool     _init = false;

#ifdef _WIN32
static DWORD _tls = TLS_OUT_OF_INDEXES;
#  define XTHR_COMPLETION_KEY ((ULONG_PTR)-1)
#else
static pthread_key_t  _tls;
static pthread_once_t _tls_once = PTHREAD_ONCE_INIT;
static void tls_init_once(void) { pthread_key_create(&_tls, NULL); }
#endif

/* ============================================================================
** TLS (Thread-Local Storage, stores current thread ID)
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
** xQueue
** ========================================================================== */

bool xqueue_init(xQueue* q, bool xwait) {
    memset(q, 0, sizeof(*q));
    q->xwait   = xwait;
    q->pending = 0;
    xnet_mutex_init(&q->lock);

    if (!xwait) {
#ifdef _WIN32
        q->iocp = CreateIoCompletionPort(INVALID_HANDLE_VALUE, NULL, 0, 1);
        return q->iocp != NULL;
#else
        if (socketpair(AF_UNIX, SOCK_STREAM, 0, q->fds) != 0) return false;
        fcntl(q->fds[0], F_SETFL, O_NONBLOCK);
        fcntl(q->fds[1], F_SETFL, O_NONBLOCK);
        return true;
#endif
    }

    /* xwait mode: fd/iocp is set externally via xthread_set_notify() */
#ifdef _WIN32
    q->iocp = NULL;
#else
    q->fds[0] = q->fds[1] = -1;
#endif
    return true;
}

void xqueue_uninit(xQueue* q) {
    /* Release unprocessed task nodes */
    xthrTask* t = q->head;
    while (t) {
        xthrTask* next = t->next;
        free(t);
        t = next;
    }
    q->head = q->tail = NULL;
    q->size = 0;

    if (!q->xwait) {
#ifdef _WIN32
        if (q->iocp) { CloseHandle(q->iocp); q->iocp = NULL; }
#else
        if (q->fds[0] >= 0) {
            close(q->fds[0]);
            close(q->fds[1]);
            q->fds[0] = q->fds[1] = -1;
        }
#endif
    }
    xnet_mutex_uninit(&q->lock);
}

bool xqueue_push(xQueue* q, XThreadFunc func, void* arg, int* out_new_size) {
    xthrTask* task = (xthrTask*)malloc(sizeof(xthrTask));
    if (!task) return false;
    task->func = func;
    task->arg  = arg;
    task->next = NULL;

    xnet_mutex_lock(&q->lock);
    if (q->tail) {
        q->tail->next = task;
        q->tail = task;
    } else {
        q->head = q->tail = task;
    }
    q->size++;
    int  new_size    = q->size;
    bool need_notify = (q->pending == 0);
    if (need_notify) q->pending = 1;
    xnet_mutex_unlock(&q->lock);

    if (out_new_size) *out_new_size = new_size;

    /* Write outside lock to reduce lock hold time */
#ifdef _WIN32
    if (need_notify && q->iocp) {
        if (!PostQueuedCompletionStatus(q->iocp, 0, XTHR_COMPLETION_KEY, NULL)) {
            XLOGE("PostQueuedCompletionStatus failed: %lu", GetLastError());
            xnet_mutex_lock(&q->lock);
            q->pending = 0;
            xnet_mutex_unlock(&q->lock);
        }
    }
#else
    if (need_notify && q->fds[0] > 0) {
        if (write(q->fds[0], "!", 1) < 1) {
            xnet_mutex_lock(&q->lock);
            q->pending = 0;
            xnet_mutex_unlock(&q->lock);
        }
    }
#endif
    return true;
}

/* Returns popped linked list head; caller is responsible for traversing and freeing each node */
xthrTask* xqueue_pop_all(xQueue* q) {
    xnet_mutex_lock(&q->lock);
    q->pending  = 0;
    xthrTask* head = q->head;
    q->head = q->tail = NULL;
    q->size = 0;
    xnet_mutex_unlock(&q->lock);
    return head;
}

bool xqueue_wait(xQueue* q, int timeout_ms) {
    if (q->xwait) return true;
#ifdef _WIN32
    DWORD timeout = (timeout_ms < 0) ? INFINITE : (DWORD)timeout_ms;
    DWORD trans; ULONG_PTR key; LPOVERLAPPED ov;
    return GetQueuedCompletionStatus(q->iocp, &trans, &key, &ov, timeout) != FALSE;
#else
    char buf[64];
    /* Consume all written notification bytes, then poll for next event */
    while (recv(q->fds[1], buf, sizeof(buf), 0) > 0);
    struct pollfd pfd = { q->fds[1], POLLIN, 0 };
    return poll(&pfd, 1, timeout_ms) > 0;
#endif
}

/* ============================================================================
** Task processing (called internally by worker thread)
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
    (void)ctx; // unused in this build
    // if (ctx->name) {
    //     xlog_set_thread_name(ctx->name);
    // } else {
    //     char name[32];
    //     snprintf(name, sizeof(name), "THR:%d", ctx->id);
    //     xlog_set_thread_name(name);
    // }

    if (ctx->on_init) ctx->on_init(ctx);

    while (atomic_load(&ctx->running)) {
        if (ctx->queue.xwait) {
            /* xwait mode: driven by external event loop, xthread_update() is called in on_update */
            if (ctx->on_update) ctx->on_update(ctx);
            XLOGW("Thread[%s] wakeup & process tasks", ctx->name);
            process_tasks(ctx);
        } else {
            if (xqueue_wait(&ctx->queue, 100)) {
                process_tasks(ctx);
            }
            if (ctx->on_update) ctx->on_update(ctx);
        }
    }

    /* Process remaining tasks before exit */
    process_tasks(ctx);

    if (ctx->on_cleanup) ctx->on_cleanup(ctx);

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
}

bool xthread_register(int id, bool xwait, const char* name,
                      void (*on_init)   (xThread*),
                      void (*on_update) (xThread*),
                      void (*on_cleanup)(xThread*)) {
    if (id <= 0 || id >= XTHR_MAX || !_init) return false;

    xnet_mutex_lock(&_lock);
    if (_threads[id]) { xnet_mutex_unlock(&_lock); return false; }

    xThread* ctx = (xThread*)calloc(1, sizeof(xThread));
    if (!ctx) { xnet_mutex_unlock(&_lock); return false; }

    ctx->id         = id;
    ctx->name       = name;
    ctx->on_init    = on_init;
    ctx->on_update  = on_update;
    ctx->on_cleanup = on_cleanup;
    ctx->userdata   = NULL;
    ctx->group      = NULL;
    atomic_store(&ctx->running, true);

    if (!xqueue_init(&ctx->queue, xwait)) {
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

bool xthread_register_main(int id, bool xwait, const char* name) {
    if (id <= 0 || id >= XTHR_MAX || !_init) return false;

    xnet_mutex_lock(&_lock);
    if (_threads[id]) { xnet_mutex_unlock(&_lock); return false; }

    xThread* ctx = (xThread*)calloc(1, sizeof(xThread));
    if (!ctx) { xnet_mutex_unlock(&_lock); return false; }

    ctx->id    = id;
    ctx->name  = name;
    ctx->group = NULL;
    atomic_store(&ctx->running, true);

    if (!xqueue_init(&ctx->queue, xwait)) {
        free(ctx);
        xnet_mutex_unlock(&_lock);
        return false;
    }

    _threads[id] = ctx;
    tls_set(id);
    xnet_mutex_unlock(&_lock);
    return true;
}

void xthread_unregister(int id) {
    if (id <= 0 || id >= XTHR_MAX) return;

    xnet_mutex_lock(&_lock);
    xThread* ctx = _threads[id];
    if (!ctx) { xnet_mutex_unlock(&_lock); return; }
    atomic_store(&ctx->running, false);
    _threads[id] = NULL;
    xnet_mutex_unlock(&_lock);

    if (ctx->handle) {
#ifdef _WIN32
        WaitForSingleObject(ctx->handle, INFINITE);
        CloseHandle(ctx->handle);
#else
        pthread_join(ctx->handle, NULL);
#endif
    }

    xqueue_uninit(&ctx->queue);
    free(ctx);
}

xThread* xthread_get(int id) {
    if (id <= 0 || id >= XTHR_MAX) return NULL;
    return _threads[id];
}

int      xthread_current_id(void) { return tls_get(); }
xThread* xthread_current   (void) { return xthread_get(tls_get()); }

int xthread_set_notify(void* fd) {
    xThread* ctx = xthread_current();
    if (!ctx) return -1;

#ifdef _WIN32
    ctx->queue.iocp = (HANDLE)fd;
    XLOGW("xthread_set_notify: %s, %p", ctx->name ? ctx->name : "", fd);
#else
    int fd_int = (fd != NULL) ? (int)(intptr_t)fd : -1;
    assert(fd_int <= 0 || ctx->queue.xwait);
    ctx->queue.fds[0] = fd_int;
    XLOGW("xthread_set_notify: %s, %d", ctx->name ? ctx->name : "", fd_int);
#endif

    /* Process tasks posted during thread initialization */
    xthread_update();
    return 0;
}

int xthread_update(void) {
    xThread* ctx = xthread_current();
    if (!ctx) return 0;
    return process_tasks(ctx);
}

bool xthread_post(int target_id, XThreadFunc func, void* arg) {
    xThread* target = xthread_get(target_id);
    if (!target || !atomic_load(&target->running)) return false;

    xThreadPool* group = target->group;
    if (!group) {
        int      src  = tls_get();
        xThread* self = xthread_get(src);
        XLOGD("xthread_post to:%s-%d, from:%s-%d",
                   target->name ? target->name : "", target->id,
                   self ? (self->name ? self->name : "") : "", src);
        return xqueue_push(&target->queue, func, arg, NULL);
    }

    /* Thread group: select optimal thread to post */
    xThread* selected = xthread_pool_select_thread(group);
    if (!selected) {
        XLOGE("ThreadPool[%s] no available thread", group->name);
        return false;
    }
    int new_size = 0;
    bool ok = xqueue_push(&selected->queue, func, arg, &new_size);
    if (ok) xthread_pool_queue_resize(group, selected->id, new_size);
    return ok;
}

/* ============================================================================
** xThreadPool
** ========================================================================== */

xThreadPool* xthread_pool_create(int group_id, int strategy, const char* name) {
    xThreadPool* set = (xThreadPool*)calloc(1, sizeof(xThreadPool));
    if (!set) return NULL;
    set->group_id = group_id;
    set->strategy = strategy;
    set->name     = name;
    atomic_store(&set->thread_count, 0);
    atomic_store(&set->next_index,   0);
    for (int i = 0; i < XTHR_GROUP_MAX; i++)
        atomic_store(&set->queue_sizes[i], 0);
    return set;
}

void xthread_pool_destroy(xThreadPool* set) {
    free(set);
}

bool xthread_pool_add_thread(xThreadPool* set, xThread* thread) {
    int count = atomic_load(&set->thread_count);
    if (count >= XTHR_GROUP_MAX) {
        XLOGE("ThreadPool[%s] reached max threads (%d)", set->name, XTHR_GROUP_MAX);
        return false;
    }
    thread->group       = set;
    set->threads[count] = thread;
    atomic_store(&set->queue_sizes[count], 0);
    atomic_store(&set->thread_count, count + 1);
    XLOGI("Thread[%d:%s] added to pool[%d:%s]",
              thread->id, thread->name ? thread->name : "unnamed",
              set->group_id, set->name);
    return true;
}

xThread* xthread_pool_select_thread(xThreadPool* set) {
    int count = atomic_load(&set->thread_count);
    if (count == 0) return NULL;

    switch (set->strategy) {
        case XTHSTRATEGY_ROUND_ROBIN: {
            int idx = atomic_fetch_add(&set->next_index, 1) % count;
            return set->threads[idx];
        }
        case XTHSTRATEGY_RANDOM: {
            int idx = rand() % count;
            return set->threads[idx];
        }
        case XTHSTRATEGY_LEAST_QUEUE:
        default: {
            int best = 0;
            int min  = atomic_load(&set->queue_sizes[0]);
            if (min == 0) return set->threads[0];
            for (int i = 1; i < count; i++) {
                int sz = atomic_load(&set->queue_sizes[i]);
                if (sz == 0) return set->threads[i];
                if (sz < min) { min = sz; best = i; }
            }
            return set->threads[best];
        }
    }
}

xThread* xthread_pool_get_thread(xThreadPool* set, int index) {
    int count = atomic_load(&set->thread_count);
    if (index < 0 || index >= count) return NULL;
    return set->threads[index];
}

void xthread_pool_queue_resize(xThreadPool* set, int id, int size) {
    int count = atomic_load(&set->thread_count);
    for (int i = 0; i < count; i++) {
        if (set->threads[i] && set->threads[i]->id == id) {
            atomic_store(&set->queue_sizes[i], size);
            return;
        }
    }
    XLOGW("ThreadPool[%s] thread %d not found", set->name, id);
}

/* ============================================================================
** Thread group registration
** ========================================================================== */

bool xthread_register_group(int base_id, int count,
                            ThreadSelStrategy strategy, bool xwait,
                            const char* name_pattern,
                            void (*on_init)   (xThread*),
                            void (*on_update) (xThread*),
                            void (*on_cleanup)(xThread*)) {
    if (count <= 0 || base_id <= 0 || (base_id + count) >= XTHR_MAX) return false;

    xThreadPool* pool = xthread_pool_create(base_id, strategy, name_pattern);
    if (!pool) return false;

    bool all_ok = true;
    for (int i = 0; i < count; i++) {
        int  thread_id = base_id + i;
        char name[32];
        snprintf(name, sizeof(name), "%s:%02d", name_pattern, i);

        if (!xthread_register(thread_id, xwait, name, on_init, on_update, on_cleanup)) {
            XLOGE("Failed to register thread %d", thread_id);
            all_ok = false;
            continue;
        }

        xThread* thread = xthread_get(thread_id);
        if (thread) xthread_pool_add_thread(pool, thread);
    }

    if (!all_ok) {
        xthread_pool_destroy(pool);
    }

    return all_ok;
}
