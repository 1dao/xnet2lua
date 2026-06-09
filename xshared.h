#ifndef __XSHARED_H__
#define __XSHARED_H__

#include <stddef.h>
#include <stdbool.h>
#include <stdint.h>

/* Route malloc/free/strdup through rpmalloc, same as xhash.h. xmacro.h shadows
** the libc names; include it after the standard headers above. */
#include "xmacro.h"

#ifdef __cplusplus
extern "C" {
#endif

/* ===========================================================================
 * xshared.h -- process-global, thread-safe SCALAR key/value dictionaries.
 *
 * The shared-memory layer for xnet2lua's shared-nothing threads (one Lua state
 * per OS thread, nothing shared by reference). A dict lives in C process memory;
 * every worker thread reaches the SAME dict by name, and the values are GLOBAL
 * MUTABLE state -- which is the entire point. A per-thread copy of a rate-limit
 * counter or a replay-nonce set is not a missed optimization, it is a
 * correctness bug: each thread would only ever see its own slice.
 *
 * --------------------------------------------------------------------------
 * SCOPE (v1): values are SCALARS only -- number / boolean / string. That covers
 * every load-bearing use case -- rate limiting, replay/dedup, global counters,
 * kill switches / live config flags, ban lists, session tokens, single-flight
 * locks -- with ZERO serialization cost: scalars are stored natively and read
 * back with no decode. Structured (table) values are a deliberate NON-goal here.
 * Packing a table with cmsgpack and decoding a fresh per-thread copy on every
 * read buys nothing over each thread just loading its own copy, so tables are
 * pushed to a later lazy-proxy type instead (see EXTENSION SEAMS at the bottom).
 *
 * --------------------------------------------------------------------------
 * THREADING: every operation is internally synchronized. The dict is SHARDED
 * (key hash -> shard); each shard owns its own mutex + hash map (xhash) + LRU
 * list + byte budget, so unrelated keys on different shards never contend. A
 * critical section covers only the map op plus a value copy -- callers
 * materialize into Lua OUTSIDE every lock, and NO call ever returns a pointer
 * into live shared memory (string reads hand back an owned copy).
 *
 * LIFECYCLE: create every dict from the MAIN thread, before workers spawn, via
 * xshared_create(). Workers resolve it by name with xshared_get_dict(). The
 * name->dict registry is thus written once at boot and never mutated
 * concurrently, so it needs no lock of its own.
 *
 * SCOPE BOUNDARY: this is shared memory within ONE process. It replaces the
 * "each thread keeps its own count + hand-rolled inter-thread sync" layer, NOT
 * Redis. A cluster-wide view (CCU across game processes, cross-process limits)
 * still goes through xredis / xnats.
 * ===========================================================================*/

/* ---- value model ------------------------------------------------------- */

typedef enum {
    XSHARED_NIL  = 0,   /* absent / cleared */
    XSHARED_NUM,        /* IEEE-754 double, stored inline */
    XSHARED_BOOL,       /* 0 / 1, stored inline */
    XSHARED_STR         /* byte string (binary-safe), stored as a blob */
} xshared_type;

/* A value crossing the C API boundary. For XSHARED_STR returned by a get, the
** bytes are an OWNED copy: release with xshared_value_dispose(). NUM/BOOL are
** inline and need no disposal. On the set side, str.ptr is borrowed -- the dict
** copies the bytes under the shard lock and never retains the caller pointer. */
typedef struct {
    xshared_type type;
    union {
        double num;
        int    boolean;
        struct { const char *ptr; size_t len; } str;
    } v;
} xshared_value;

/* Release an OWNED string returned by xshared_get(); no-op for NUM/BOOL/NIL. */
void xshared_value_dispose(xshared_value *val);

/* ---- status codes ------------------------------------------------------ */

typedef enum {
    XSHARED_OK = 0,
    XSHARED_NOTFOUND,   /* key absent or expired */
    XSHARED_EXISTS,     /* add() found the key already present */
    XSHARED_NOTNUM,     /* incr() on a key whose value is not a number */
    XSHARED_TOOBIG,     /* value (key+blob+overhead) exceeds one shard's budget */
    XSHARED_NOMEM,      /* allocation failed */
    XSHARED_BADARG
} xshared_status;

/* ---- the dict handle (opaque) ------------------------------------------ */

typedef struct xshared_dict xshared_dict_t;

/* ---- registry / lifecycle (MAIN thread, at boot) ----------------------- */

/* Frees every registered dict; call once at process exit. The registry needs no
** explicit init -- it is a zero-initialised static, populated by xshared_create. */
void xshared_shutdown(void);

/* Create a named dict. budget_bytes is the TOTAL memory ceiling (split across
** shards); nshards is rounded up to a power of two and should be >= ~2x the
** worker-thread count (e.g. 16/32). Returns NULL on OOM or duplicate name. */
xshared_dict_t *xshared_create(const char *name,
                               size_t      budget_bytes,
                               uint32_t    nshards);

/* Resolve a dict created at boot. NULL if the name was never created. Safe to
** call from any thread (registry is read-only after boot). */
xshared_dict_t *xshared_get_dict(const char *name);

/* ---- core operations (any thread) -------------------------------------- */
/* ttl_ms == 0 means "no expiry". Keys are binary-safe (klen explicit). */

/* Overwrite (or insert) key=val with the given ttl. */
xshared_status xshared_set(xshared_dict_t *d, const char *key, size_t klen,
                           const xshared_value *val, int64_t ttl_ms);

/* Insert only if ABSENT -> XSHARED_EXISTS if already present. This is the
** atomic primitive behind replay-nonce / dedup and single-flight locks.
** CAVEAT: under memory pressure LRU eviction can drop a not-yet-expired entry,
** so for security-critical replay windows, size budget_bytes to hold the whole
** TTL window's worth of keys. */
xshared_status xshared_add(xshared_dict_t *d, const char *key, size_t klen,
                           const xshared_value *val, int64_t ttl_ms);

/* Overwrite only if PRESENT -> XSHARED_NOTFOUND otherwise. */
xshared_status xshared_replace(xshared_dict_t *d, const char *key, size_t klen,
                               const xshared_value *val, int64_t ttl_ms);

/* Read. On XSHARED_OK, *out is filled (STR is an owned copy -> dispose it).
** Refreshes LRU recency. Expired-on-read keys are reaped and report NOTFOUND. */
xshared_status xshared_get(xshared_dict_t *d, const char *key, size_t klen,
                           xshared_value *out);

/* Remove a key. XSHARED_NOTFOUND if it was not present. */
xshared_status xshared_delete(xshared_dict_t *d, const char *key, size_t klen);

/* Atomic numeric increment, the counter fast path (rate limits, CCU, metrics).
** If the key is absent it is CREATED as (init + delta) with init_ttl_ms; if it
** exists its ttl is left untouched and delta is added. Non-number -> NOTNUM.
** *out_new (optional) receives the resulting value. This single call is the
** "incr; set the window TTL only on first hit" idiom in one shot. */
xshared_status xshared_incr(xshared_dict_t *d, const char *key, size_t klen,
                            double delta, double init, int64_t init_ttl_ms,
                            double *out_new);

/* ---- TTL helpers ------------------------------------------------------- */

/* (Re)set a key's ttl. ttl_ms == 0 makes it persistent. NOTFOUND if absent. */
xshared_status xshared_expire(xshared_dict_t *d, const char *key, size_t klen,
                              int64_t ttl_ms);

/* Remaining ttl: *out_ms = milliseconds left (> 0), or -1 for "persistent".
** NOTFOUND if the key is absent/expired. */
xshared_status xshared_ttl(xshared_dict_t *d, const char *key, size_t klen,
                           int64_t *out_ms);

/* ---- maintenance / introspection --------------------------------------- */

/* Main-thread housekeeping: call once per runner tick. Self-throttled to
** XSHARED_SWEEP_INTERVAL_MS, then INCREMENTALLY sweeps expired keys from every
** registered dict -- bounded work per tick via a round-robin cursor, so a large
** dict is reaped across many ticks without a CPU or lock-hold spike. This single
** coarse reaper replaces a per-key timer: lazy expiry already keeps expired
** values unobservable on access; this only reclaims the memory of keys never
** accessed again (the runtime's job, not the script's -- hence no Lua flush
** API). Safe to call when no dicts exist (no-op). The reaping itself is an
** internal static in xshared.c. */
void   xshared_tick(void);

typedef struct {
    size_t   capacity_bytes;
    size_t   used_bytes;
    uint64_t item_count;
    uint64_t evicted;    /* entries dropped by LRU under pressure */
    uint64_t expired;    /* entries reaped for TTL */
    uint32_t nshards;
} xshared_stats_t;

void xshared_stats(xshared_dict_t *d, xshared_stats_t *out);

/* ===========================================================================
 * INTERNAL LAYOUT (defined in xshared.c -- recorded here so the skeleton is
 * fixed; callers never see these):
 *
 *   struct xshared_dict {
 *       char     *name;
 *       uint32_t  nshards;        // power of two
 *       uint32_t  shard_mask;     // nshards - 1
 *       shard    *shards;         // calloc'd array of nshards
 *       uint32_t  sweep_shard;    // incremental TTL-sweep cursor (main thread
 *       size_t    sweep_bucket;   //   only; round-robins shards then buckets)
 *   };
 *
 *   struct shard {                // one mutex-guarded partition
 *       xMutex    lock;           // xmutex.h; one short critical section per op
 *       entry   **buckets;        // purpose-built chained map (binary-safe keys)
 *       size_t    nbuckets;       // power of two; grows at load factor > 1
 *       size_t    count;
 *       entry    *lru_head, *lru_tail;     // MRU ... LRU
 *       size_t    used_bytes, budget_bytes;
 *       uint64_t  evicted, expired;
 *   };
 *
 *   struct entry {                // ONE allocation: header + key + (STR) value
 *       entry    *hnext;          // bucket chain
 *       entry    *lru_prev, *lru_next;
 *       uint64_t  hash;           // full 64-bit key hash
 *       int64_t   expire_ms;      // 0 = persistent; monotonic clock
 *       size_t    klen;
 *       uint32_t  vlen;           // STR byte length
 *       uint8_t   type;           // XSHARED_NUM | _BOOL | _STR
 *       union { double num; int b; } scalar;   // NUM/BOOL inline
 *       char      buf[];          // key bytes, then STR value bytes
 *   };
 *
 * ALGORITHMS:
 *   shard select : h = FNV1a64(key); shard = (h >> 32) & shard_mask
 *   bucket       : low bits of h; chained, grows at load factor > 1
 *   incr         : shard lock; find-or-create; add to the inline double
 *   TTL          : lazy reap on access + an incremental cursor sweep on the main
 *                  thread (xshared_tick -> flush_expired), bounded per tick
 *   LRU          : intrusive list per shard; insert-over-budget evicts lru_tail
 *   clock        : monotonic ms (time_clock_ms)
 *
 * EXTENSION SEAMS (future, NOT v1 -- keep this header's scalar contract clean):
 *   B. snapshot type  : _Atomic(versioned_blob*) current; lock-free read +
 *                       per-thread version-memoized decode. For runtime-coherent
 *                       bulk config (e.g. zone topology) that actually mutates.
 *   C. lazy proxy     : table value returned as a userdata whose __index reads
 *                       single fields straight from the shared blob (+ version
 *                       check) -- no full decode. This, not B, is what makes
 *                       sharing big read-mostly data beat a per-thread copy.
 *   D. precise expiry : per-shard min-heap (xheapmin.h) keyed by expire_ms, only
 *                       if fire-on-expire or O(due) sweeps are ever needed. It
 *                       adds O(log n) to every entry create/expire/evict path,
 *                       so the cursor sweep above is preferred until justified.
 * ===========================================================================*/

#ifdef __cplusplus
}
#endif
#endif /* __XSHARED_H__ */
