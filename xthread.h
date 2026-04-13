#ifndef _XTHREAD_H
#define _XTHREAD_H
/* xthread.h - Thread pool and cross-thread task posting (pure C implementation)
** Supports predefined thread IDs, main-thread registration, and thread-group load balancing
*/

#ifdef _WIN32
#include <winsock2.h>
#include <windows.h>
#else
#include <pthread.h>
#include <unistd.h>
#endif

#include <stdatomic.h>
#include <stdbool.h>
#include "xmutex.h"
#include "xlog.h"

/* ============================================================================
** Predefined thread IDs (0-99)
** ========================================================================== */

#define XTHR_INVALID        0
#define XTHR_MAIN           1   /* main thread */
#define XTHR_REDIS          2   /* Redis thread */
#define XTHR_MYSQL          3   /* MySQL thread */
#define XTHR_LOG            4   /* logging thread */
#define XTHR_IO             5   /* IO thread */
#define XTHR_COMPUTE        6   /* compute thread */
#define XTHR_WORKER_GRP1    10  /* worker group 1 start */
#define XTHR_WORKER_GRP2    30  /* worker group 2 start */
#define XTHR_WORKER_GRP3    50  /* worker group 3 start */
#define XTHR_WORKER_GRP4    60  /* worker group 4 start */
#define XTHR_WORKER_GRP5    70  /* worker group 5 start */

#define XTHR_MAX            100
#define XTHR_GROUP_MAX      20

/* Error codes */
#define XTHR_ERR_NO_THREAD  -101
#define XTHR_ERR_QUEUE_FULL -102
#define XTHR_ERR_NOT_INIT   -103

/* ============================================================================
** Forward declarations
** ========================================================================== */

typedef struct xThread    xThread;
typedef struct xThreadPool xThreadPool;

/* Task function type: (thread context, user argument) */
typedef void (*XThreadFunc)(xThread* thr, void* arg);

/* Thread group selection strategies */
typedef enum {
    XTHSTRATEGY_LEAST_QUEUE = 0,   /* least-queue (default) */
    XTHSTRATEGY_ROUND_ROBIN,       /* round-robin             */
    XTHSTRATEGY_RANDOM             /* random                  */
} ThreadSelStrategy;

/* ============================================================================
** Task node (intrusive singly-linked list)
** ========================================================================== */

typedef struct xthrTask {
    XThreadFunc       func;
    void*             arg;
    struct xthrTask*  next;
} xthrTask;

/* ============================================================================
** Task queue (thread-safe, supports IOCP / socketpair wakeup)
** ========================================================================== */

typedef struct {
    xthrTask*   head;
    xthrTask*   tail;
    int         size;
    int         pending;
    bool        xwait;
    xMutex      lock;
#ifdef _WIN32
    HANDLE      iocp;
#else
    int         fds[2];   /* fds[0]=write end/notify fd, fds[1]=read end */
#endif
} xQueue;

/* ============================================================================
** Thread context
** ========================================================================== */

struct xThread {
    int             id;
    const char*     name;
    atomic_bool     running;
    xQueue          queue;
    void*           userdata;
    xThreadPool*    group;

#ifdef _WIN32
    HANDLE          handle;
#else
    pthread_t       handle;
#endif

    void (*on_init)   (xThread*);
    void (*on_update) (xThread*);
    void (*on_cleanup)(xThread*);
};

/* ============================================================================
** Thread group
** ========================================================================== */

struct xThreadPool {
    int             group_id;
    int             strategy;
    const char*     name;
    xThread*        threads[XTHR_GROUP_MAX];
    atomic_int      thread_count;
    atomic_int      queue_sizes[XTHR_GROUP_MAX];
    atomic_int      next_index;
};

/* ============================================================================
** Global API
** ========================================================================== */

bool     xthread_init   (void);
void     xthread_uninit (void);

/* Register a worker thread (creates a new thread) */
bool xthread_register(int id, bool xwait, const char* name,
                      void (*on_init)   (xThread*),
                      void (*on_update) (xThread*),
                      void (*on_cleanup)(xThread*));

/* Register a thread group */
bool xthread_register_group(int base_id, int count,
                            ThreadSelStrategy strategy, bool xwait,
                            const char* name_pattern,
                            void (*on_init)   (xThread*),
                            void (*on_update) (xThread*),
                            void (*on_cleanup)(xThread*));

/* Register the main thread (does not create a new thread) */
bool xthread_register_main(int id, bool xwait, const char* name);

void     xthread_unregister (int id);
xThread* xthread_get        (int id);
int      xthread_current_id (void);
xThread* xthread_current    (void);

/* Set external wakeup fd for xwait threads (owned by the event loop) */
int      xthread_set_notify (void* fd);

/* Called by main/xwait thread: process all tasks in the current queue */
int      xthread_update     (void);

/* Asynchronously post a task (do not wait for result) */
bool     xthread_post       (int target_id, XThreadFunc func, void* arg);

/* ============================================================================
** Queue API (for internal or advanced usage)
** ========================================================================== */
bool      xqueue_init   (xQueue* q, bool xwait);
void      xqueue_uninit (xQueue* q);
bool      xqueue_push   (xQueue* q, XThreadFunc func, void* arg, int* out_new_size);
xthrTask* xqueue_pop_all(xQueue* q);   /* returns head of list; caller must free each node */
bool      xqueue_wait   (xQueue* q, int timeout_ms);

/* ============================================================================
** Thread group API
** ========================================================================== */
xThreadPool* xthread_pool_create           (int group_id, int strategy, const char* name);
void        xthread_pool_destroy          (xThreadPool* set);
bool        xthread_pool_add_thread       (xThreadPool* set, xThread* thread);
xThread*    xthread_pool_select_thread    (xThreadPool* set);
xThread*    xthread_pool_get_thread       (xThreadPool* set, int index);
void        xthread_pool_queue_resize     (xThreadPool* set, int id, int size);

#endif /* _XTHREAD_H */
