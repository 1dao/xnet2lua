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
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Per-task inline arg buffer size. Args with arg_len <= this size are copied
** into the task node (zero allocation); larger args fall back to malloc. */
#ifndef XTHREAD_TASK_ARG_INLINE
#define XTHREAD_TASK_ARG_INLINE 256
#endif

/* Per-queue task freelist size. Tasks are pre-allocated at xqueue_init.
** Once exhausted, additional tasks are malloc'd individually. */
#ifndef XTHREAD_TASK_POOL_SIZE
#define XTHREAD_TASK_POOL_SIZE 256
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
#define XTHR_NATS           7   /* NATS I/O thread              */
#define XTHR_HTTP           8   /* HTTP/HTTPS service thread    */
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

/* Task callback: (owning thread context, user argument, arg length) */
typedef void (*XThreadFunc)(xThread* thr, void* arg, int arg_len);

/* Thread-group load-balancing strategy */
typedef enum {
    XTHSTRATEGY_LEAST_QUEUE = 0,  /* fewest queued tasks (default) */
    XTHSTRATEGY_ROUND_ROBIN,      /* cyclic                        */
    XTHSTRATEGY_RANDOM            /* random                        */
} ThreadSelStrategy;

/* ============================================================================
** Global init / uninit, Must be called after xpoll_init if using xpoll
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

/* Register a worker thread with userdata – creates a new OS thread.
** on_init / on_update / on_cleanup run inside the new thread.
** The userdata pointer is stored with the thread and can be retrieved
** via xthread_get_userdata(). */
bool xthread_register_ex(int id, const char* name,
                         void (*on_init)   (xThread*),
                         void (*on_update) (xThread*),
                         void (*on_cleanup)(xThread*),
                         void* userdata);

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

/* Re-arm the calling thread's wakeup backend.
** Call after xpoll_init() if the thread was already registered before the
** poll instance existed. */
int  xthread_wakeup_init(void);
void xthread_wakeup_uninit(void);

/* ============================================================================
** Cross-thread task posting
** ========================================================================== */

/* Asynchronously post func(arg) to target_id.
** If target belongs to a pool, the best thread in the pool is selected.
**
** arg semantics by arg_len:
**   arg_len == 0                       → arg stored as raw pointer (caller owns lifetime)
**   0 < arg_len <= XTHREAD_TASK_ARG_INLINE → arg copied into task's inline buffer
**   arg_len  > XTHREAD_TASK_ARG_INLINE → arg copied into a fresh malloc buffer
**
** Callback receives a pointer to the stored / copied bytes (or the original
** pointer for arg_len == 0). The buffer is freed automatically after the
** callback returns; do not retain the pointer.
**
** Returns: 0 success, -1 malloc failed, -2 queue full (backpressure). */
int xthread_post(int target_id, XThreadFunc func,
                 const void* arg, size_t arg_len);

/* Reply path: post directly to target_id (no pool load balancing) and
** bypass the queue's max_size cap. Use this for RPC reply or any path
** where delivery MUST succeed under load.
**
** arg semantics identical to xthread_post.
**
** Returns: 0 success, -1 malloc failed. Never returns -2. */
int xthread_post_reply(int target_id, XThreadFunc func,
                       const void* arg, size_t arg_len);

/* Set per-thread task timeout. When a task has been queued for at least
** timeout_secs (measured from xthread_post call to process_tasks dispatch),
** process_tasks invokes on_expired(thr, arg, arg_len) instead of the
** original task->func, then releases the task as usual.
**
**   timeout_secs == 0 → disable expiration (default; on_expired is ignored).
**   on_expired == NULL → expired tasks are dropped silently.
**     NOTE: in raw pointer mode (arg_len == 0) the arg pointer is leaked
**     unless on_expired frees it.
**
** xthread_post_reply tasks NEVER expire — reply delivery is guaranteed by
** design (a reply means the producer has finished its work and the
** originating thread must be notified).
**
** Publish-once contract: call this during thread init, before tasks start
** flowing in. process_tasks reads timeout_secs / on_expired without a lock,
** so changing them while the thread is processing tasks is racy.
**
** Returns: 0 success, -1 thread not found. */
int xthread_set_timeout(int target_id, uint32_t timeout_secs,
                        XThreadFunc on_expired);

/* Set the queue backpressure cap for a specific thread.
**   new_max  > 0  → xthread_post returns -2 once queue size >= new_max
**   new_max == 0  → unlimited (cap disabled)
** Affects subsequent xthread_post calls; in-flight tasks unaffected.
** xthread_post_reply always bypasses this cap.
**
** Returns: 0 success, -1 thread not found. */
int xthread_set_queue_max(int target_id, int new_max);

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
