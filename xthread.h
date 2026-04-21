#ifndef _XTHREAD_H
#define _XTHREAD_H

/* xthread.h - Thread pool and cross-thread task posting (pure C)
**
** xThread and xThreadPool are fully opaque; internals (xQueue, xthrTask)
** are hidden inside xthread.c.
**
** Wakeup strategy (selected at runtime by xthread_wakeup_init):
**   xpoll_get_default() != NULL  →  socketpair fd registered in xpoll
**   xpoll_get_default() == NULL  →  pthread_cond_signal / Windows SetEvent
*/

#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

/* ============================================================================
** Predefined thread IDs (0–99 reserved)
** ========================================================================== */
#define XTHR_INVALID        0
#define XTHR_MAIN           1   /* main thread                  */
#define XTHR_REDIS          2   /* Redis I/O thread             */
#define XTHR_MYSQL          3   /* MySQL I/O thread             */
#define XTHR_LOG            4   /* logging thread               */
#define XTHR_IO             5   /* generic I/O thread           */
#define XTHR_COMPUTE        6   /* compute thread               */
#define XTHR_WORKER_GRP1    10  /* worker group 1 base          */
#define XTHR_WORKER_GRP2    30  /* worker group 2 base          */
#define XTHR_WORKER_GRP3    50  /* worker group 3 base          */
#define XTHR_WORKER_GRP4    60  /* worker group 4 base          */
#define XTHR_WORKER_GRP5    70  /* worker group 5 base          */
#define XTHR_MAX            100
#define XTHR_GROUP_MAX      20

/* Error codes */
#define XTHR_ERR_NO_THREAD  -101
#define XTHR_ERR_QUEUE_FULL -102
#define XTHR_ERR_NOT_INIT   -103

/* ============================================================================
** Opaque types  (definitions live in xthread.c)
** ========================================================================== */
typedef struct xThread     xThread;
typedef struct xThreadPool xThreadPool;

/* Task callback: (owning thread context, user argument) */
typedef void (*XThreadFunc)(xThread* thr, void* arg);

/* Thread-group load-balancing strategy */
typedef enum {
    XTHSTRATEGY_LEAST_QUEUE = 0,  /* fewest queued tasks (default) */
    XTHSTRATEGY_ROUND_ROBIN,      /* cyclic                        */
    XTHSTRATEGY_RANDOM            /* random                        */
} ThreadSelStrategy;

/* ============================================================================
** Global init / uninit
** ========================================================================== */
bool xthread_init  (void);
void xthread_uninit(void);

/* ============================================================================
** Thread registration
** ========================================================================== */

/* Register a worker thread – creates a new OS thread.
** on_init / on_update / on_cleanup run inside the new thread. */
bool xthread_register(int id, const char* name,
                      void (*on_init)   (xThread*),
                      void (*on_update) (xThread*),
                      void (*on_cleanup)(xThread*));

/* Register a thread group (base_id … base_id+count-1). */
bool xthread_register_group(int base_id, int count,
                            ThreadSelStrategy strategy,
                            const char* name_pattern,
                            void (*on_init)   (xThread*),
                            void (*on_update) (xThread*),
                            void (*on_cleanup)(xThread*));

/* ============================================================================
** Thread lifecycle
** ========================================================================== */
void     xthread_unregister(int id);
xThread* xthread_get       (int id);
int      xthread_current_id(void);
xThread* xthread_current   (void);

/* Process all queued tasks on the calling thread (main / poll-driven use). */
int xthread_update(int timeout_ms);

/* ============================================================================
** Cross-thread task posting
** ========================================================================== */

/* Asynchronously post func(arg) to target_id.
** If target belongs to a pool, the best thread in the pool is selected. */
bool xthread_post(int target_id, XThreadFunc func, void* arg);

/* ============================================================================
** xThread field accessors  (required because xThread is opaque)
** ========================================================================== */
int         xthread_get_id      (xThread* thr);
const char* xthread_get_name    (xThread* thr);
void*       xthread_get_userdata(xThread* thr);
void        xthread_set_userdata(xThread* thr, void* data);

/* ============================================================================
** Thread-pool API
** ========================================================================== */
xThreadPool* xthread_pool_create       (int group_id, int strategy, const char* name);
void         xthread_pool_destroy      (xThreadPool* pool);
bool         xthread_pool_add_thread   (xThreadPool* pool, xThread* thread);
xThread*     xthread_pool_select_thread(xThreadPool* pool);
xThread*     xthread_pool_get_thread   (xThreadPool* pool, int index);

#ifdef __cplusplus
}
#endif
#endif /* _XTHREAD_H */
