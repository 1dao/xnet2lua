/* xshared.c -- process-global, thread-safe scalar key/value dictionaries.
**
** See xshared.h for the design rationale. This is structure "A": a sharded
** hash map of scalar (number/boolean/string) values with per-shard mutex,
** intrusive LRU, byte budget, and lazy TTL expiry.
**
** Each shard owns: a mutex, a power-of-two bucket array of intrusively-chained
** entries, an LRU list (head = MRU, tail = LRU), and a byte budget. A single
** entry is ONE allocation: header + key bytes + (string) value bytes, so keys
** are binary-safe and there is no per-entry strdup/value double-alloc.
**
** Concurrency contract (see header): every dict is created from the MAIN thread
** at boot, before workers spawn. The name->dict registry is therefore written
** once and read lock-free afterwards (thread creation establishes the
** happens-before). Per-key operations take only the owning shard's lock.
*/

#include "xshared.h"     /* pulls xmacro.h -> malloc/free/strdup via rpmalloc */
#include "xmutex.h"
#include "xtimer.h"      /* time_clock_ms() : monotonic milliseconds */

#include <string.h>

/* ---- tunables ---------------------------------------------------------- */
#define XSHARED_INIT_BUCKETS  16u      /* per-shard, grows on load factor > 1 */
#define XSHARED_MAX_SHARDS    1024u
#define XSHARED_FNV64_BASIS   1469598103934665603ULL
#define XSHARED_FNV64_PRIME   1099511628211ULL
#define XSHARED_SWEEP_INTERVAL_MS 10000  /* main-thread sweep cadence (tune 5k-30k) */
#define XSHARED_SWEEP_BUDGET      4096u  /* max entries scanned per dict per tick */

/* ---- entry ------------------------------------------------------------- */
/* One allocation. buf holds [key bytes][value bytes(STR only)]. */
typedef struct entry {
    struct entry *hnext;                 /* bucket chain */
    struct entry *lru_prev, *lru_next;   /* LRU list */
    uint64_t      hash;                  /* full 64-bit key hash */
    int64_t       expire_ms;             /* 0 = persistent (monotonic clock) */
    size_t        klen;
    uint32_t      vlen;                  /* string byte length (STR only) */
    uint8_t       type;                  /* xshared_type */
    union { double num; int b; } scalar; /* NUM / BOOL inline */
    char          buf[];                 /* key bytes, then string value bytes */
} entry;

#define ENTRY_KEY(e) ((e)->buf)
#define ENTRY_VAL(e) ((e)->buf + (e)->klen)

static inline size_t entry_bytes(const entry *e) {
    return sizeof(entry) + e->klen + (e->type == XSHARED_STR ? e->vlen : 0);
}

/* ---- shard ------------------------------------------------------------- */
typedef struct {
    xMutex   lock;
    entry  **buckets;
    size_t   nbuckets;        /* power of two */
    size_t   count;
    entry   *lru_head;        /* MRU */
    entry   *lru_tail;        /* LRU */
    size_t   used_bytes;
    size_t   budget_bytes;
    uint64_t evicted;
    uint64_t expired;
} shard;

/* ---- dict -------------------------------------------------------------- */
struct xshared_dict {
    char    *name;
    uint32_t nshards;
    uint32_t shard_mask;
    shard   *shards;
    /* incremental TTL-sweep cursor; touched only by xshared_tick on the main
    ** thread, so it needs no lock of its own. */
    uint32_t sweep_shard;
    size_t   sweep_bucket;
};

/* ---- registry (boot-time only; read lock-free afterwards) -------------- */
typedef struct reg_node {
    xshared_dict_t  *dict;
    struct reg_node *next;
} reg_node;

static reg_node *g_registry = NULL;

/* ---- helpers ----------------------------------------------------------- */

static inline int64_t now_ms(void) { return (int64_t)time_clock_ms(); }

static uint64_t hash_key(const char *k, size_t klen) {
    uint64_t h = XSHARED_FNV64_BASIS;
    for (size_t i = 0; i < klen; i++) {
        h ^= (unsigned char)k[i];
        h *= XSHARED_FNV64_PRIME;
    }
    return h;
}

static uint32_t next_pow2_u32(uint32_t v) {
    if (v < 1) return 1;
    v--;
    v |= v >> 1; v |= v >> 2; v |= v >> 4; v |= v >> 8; v |= v >> 16;
    v++;
    return v;
}

/* ---- LRU (intrusive) --------------------------------------------------- */

static void lru_unlink(shard *s, entry *e) {
    if (e->lru_prev) e->lru_prev->lru_next = e->lru_next;
    else             s->lru_head = e->lru_next;
    if (e->lru_next) e->lru_next->lru_prev = e->lru_prev;
    else             s->lru_tail = e->lru_prev;
    e->lru_prev = e->lru_next = NULL;
}

static void lru_push_front(shard *s, entry *e) {
    e->lru_prev = NULL;
    e->lru_next = s->lru_head;
    if (s->lru_head) s->lru_head->lru_prev = e;
    else             s->lru_tail = e;
    s->lru_head = e;
}

static void lru_touch(shard *s, entry *e) {
    if (s->lru_head == e) return;
    lru_unlink(s, e);
    lru_push_front(s, e);
}

/* ---- bucket ops -------------------------------------------------------- */

static void bucket_insert(shard *s, entry *e) {
    size_t bi = (size_t)e->hash & (s->nbuckets - 1);
    e->hnext = s->buckets[bi];
    s->buckets[bi] = e;
}

static void bucket_remove(shard *s, entry *e) {
    size_t bi = (size_t)e->hash & (s->nbuckets - 1);
    entry **pp = &s->buckets[bi];
    while (*pp) {
        if (*pp == e) { *pp = e->hnext; return; }
        pp = &(*pp)->hnext;
    }
}

static void shard_maybe_grow(shard *s) {
    if (s->count <= s->nbuckets) return;
    size_t nb = s->nbuckets << 1;
    entry **nbuf = (entry **)calloc(nb, sizeof(entry *));
    if (!nbuf) return;                 /* grow is best-effort */
    for (size_t i = 0; i < s->nbuckets; i++) {
        entry *e = s->buckets[i];
        while (e) {
            entry *nx = e->hnext;
            size_t bi = (size_t)e->hash & (nb - 1);
            e->hnext = nbuf[bi];
            nbuf[bi] = e;
            e = nx;
        }
    }
    free(s->buckets);
    s->buckets  = nbuf;
    s->nbuckets = nb;
}

/* Detach + free an entry already located in the shard. */
static void entry_drop(shard *s, entry *e) {
    bucket_remove(s, e);
    lru_unlink(s, e);
    s->used_bytes -= entry_bytes(e);
    s->count--;
    free(e);
}

static void evict_tail(shard *s) {
    entry *victim = s->lru_tail;
    if (!victim) return;
    s->evicted++;
    entry_drop(s, victim);
}

/* Find a LIVE entry, reaping it if it has expired. */
static entry *shard_lookup(shard *s, uint64_t h, const char *key, size_t klen,
                           int64_t now) {
    size_t bi = (size_t)h & (s->nbuckets - 1);
    for (entry *e = s->buckets[bi]; e; e = e->hnext) {
        if (e->hash == h && e->klen == klen && memcmp(ENTRY_KEY(e), key, klen) == 0) {
            if (e->expire_ms != 0 && e->expire_ms <= now) {
                s->expired++;
                entry_drop(s, e);
                return NULL;
            }
            return e;
        }
    }
    return NULL;
}

static entry *entry_new(uint64_t h, const char *key, size_t klen,
                        const xshared_value *val, int64_t expire) {
    size_t vbytes = (val->type == XSHARED_STR) ? val->v.str.len : 0;
    entry *e = (entry *)malloc(sizeof(entry) + klen + vbytes);
    if (!e) return NULL;
    e->hnext = e->lru_prev = e->lru_next = NULL;
    e->hash = h;
    e->expire_ms = expire;
    e->klen = klen;
    e->vlen = (uint32_t)vbytes;
    e->type = (uint8_t)val->type;
    if (val->type == XSHARED_NUM)       e->scalar.num = val->v.num;
    else if (val->type == XSHARED_BOOL) e->scalar.b   = val->v.boolean;
    if (klen)   memcpy(ENTRY_KEY(e), key, klen);
    if (vbytes) memcpy(ENTRY_VAL(e), val->v.str.ptr, vbytes);
    return e;
}

static shard *shard_for(xshared_dict_t *d, uint64_t h) {
    /* high bits select the shard, low bits select the bucket */
    return &d->shards[(uint32_t)(h >> 32) & d->shard_mask];
}

/* ---- set / add / replace ----------------------------------------------- */

typedef enum { MODE_SET, MODE_ADD, MODE_REPLACE } set_mode;

static xshared_status do_set(xshared_dict_t *d, const char *key, size_t klen,
                             const xshared_value *val, int64_t ttl_ms,
                             set_mode mode) {
    if (!d || !key || !val) return XSHARED_BADARG;
    if (val->type != XSHARED_NUM && val->type != XSHARED_BOOL &&
        val->type != XSHARED_STR)
        return XSHARED_BADARG;

    uint64_t h   = hash_key(key, klen);
    shard   *s   = shard_for(d, h);
    int64_t  now = now_ms();
    int64_t  expire = (ttl_ms > 0) ? now + ttl_ms : 0;
    size_t   vbytes = (val->type == XSHARED_STR) ? val->v.str.len : 0;
    size_t   need   = sizeof(entry) + klen + vbytes;

    xnet_mutex_lock(&s->lock);

    if (need > s->budget_bytes) { xnet_mutex_unlock(&s->lock); return XSHARED_TOOBIG; }

    entry *e = shard_lookup(s, h, key, klen, now);
    if (e) {
        if (mode == MODE_ADD) { xnet_mutex_unlock(&s->lock); return XSHARED_EXISTS; }
        entry_drop(s, e);   /* replace by remove + reinsert (size may change) */
    } else if (mode == MODE_REPLACE) {
        xnet_mutex_unlock(&s->lock);
        return XSHARED_NOTFOUND;
    }

    while (s->used_bytes + need > s->budget_bytes && s->lru_tail) evict_tail(s);

    entry *ne = entry_new(h, key, klen, val, expire);
    if (!ne) { xnet_mutex_unlock(&s->lock); return XSHARED_NOMEM; }
    bucket_insert(s, ne);
    lru_push_front(s, ne);
    s->used_bytes += need;
    s->count++;
    shard_maybe_grow(s);

    xnet_mutex_unlock(&s->lock);
    return XSHARED_OK;
}

xshared_status xshared_set(xshared_dict_t *d, const char *key, size_t klen,
                           const xshared_value *val, int64_t ttl_ms) {
    return do_set(d, key, klen, val, ttl_ms, MODE_SET);
}
xshared_status xshared_add(xshared_dict_t *d, const char *key, size_t klen,
                           const xshared_value *val, int64_t ttl_ms) {
    return do_set(d, key, klen, val, ttl_ms, MODE_ADD);
}
xshared_status xshared_replace(xshared_dict_t *d, const char *key, size_t klen,
                               const xshared_value *val, int64_t ttl_ms) {
    return do_set(d, key, klen, val, ttl_ms, MODE_REPLACE);
}

/* ---- get --------------------------------------------------------------- */

xshared_status xshared_get(xshared_dict_t *d, const char *key, size_t klen,
                           xshared_value *out) {
    if (!d || !key || !out) return XSHARED_BADARG;
    out->type = XSHARED_NIL;

    uint64_t h = hash_key(key, klen);
    shard   *s = shard_for(d, h);
    int64_t  now = now_ms();

    xnet_mutex_lock(&s->lock);
    entry *e = shard_lookup(s, h, key, klen, now);
    if (!e) { xnet_mutex_unlock(&s->lock); return XSHARED_NOTFOUND; }

    lru_touch(s, e);
    out->type = (xshared_type)e->type;
    if (e->type == XSHARED_NUM) {
        out->v.num = e->scalar.num;
    } else if (e->type == XSHARED_BOOL) {
        out->v.boolean = e->scalar.b;
    } else { /* STR: hand back an OWNED copy (never a pointer into shared mem) */
        char *cp = (char *)malloc(e->vlen ? e->vlen : 1);
        if (!cp) { xnet_mutex_unlock(&s->lock); out->type = XSHARED_NIL; return XSHARED_NOMEM; }
        memcpy(cp, ENTRY_VAL(e), e->vlen);
        out->v.str.ptr = cp;
        out->v.str.len = e->vlen;
    }
    xnet_mutex_unlock(&s->lock);
    return XSHARED_OK;
}

void xshared_value_dispose(xshared_value *val) {
    if (val && val->type == XSHARED_STR && val->v.str.ptr) {
        free((void *)val->v.str.ptr);
        val->v.str.ptr = NULL;
        val->v.str.len = 0;
    }
    if (val) val->type = XSHARED_NIL;
}

/* ---- delete ------------------------------------------------------------ */

xshared_status xshared_delete(xshared_dict_t *d, const char *key, size_t klen) {
    if (!d || !key) return XSHARED_BADARG;
    uint64_t h = hash_key(key, klen);
    shard   *s = shard_for(d, h);
    int64_t  now = now_ms();

    xnet_mutex_lock(&s->lock);
    entry *e = shard_lookup(s, h, key, klen, now);
    if (!e) { xnet_mutex_unlock(&s->lock); return XSHARED_NOTFOUND; }
    entry_drop(s, e);
    xnet_mutex_unlock(&s->lock);
    return XSHARED_OK;
}

/* ---- incr -------------------------------------------------------------- */

xshared_status xshared_incr(xshared_dict_t *d, const char *key, size_t klen,
                            double delta, double init, int64_t init_ttl_ms,
                            double *out_new) {
    if (!d || !key) return XSHARED_BADARG;
    uint64_t h = hash_key(key, klen);
    shard   *s = shard_for(d, h);
    int64_t  now = now_ms();

    xnet_mutex_lock(&s->lock);
    entry *e = shard_lookup(s, h, key, klen, now);
    if (e) {
        if (e->type != XSHARED_NUM) { xnet_mutex_unlock(&s->lock); return XSHARED_NOTNUM; }
        e->scalar.num += delta;
        lru_touch(s, e);
        if (out_new) *out_new = e->scalar.num;
        xnet_mutex_unlock(&s->lock);
        return XSHARED_OK;
    }

    /* absent -> create as (init + delta) with init_ttl */
    xshared_value v;
    v.type  = XSHARED_NUM;
    v.v.num = init + delta;
    int64_t expire = (init_ttl_ms > 0) ? now + init_ttl_ms : 0;
    size_t  need   = sizeof(entry) + klen;

    if (need > s->budget_bytes) { xnet_mutex_unlock(&s->lock); return XSHARED_TOOBIG; }
    while (s->used_bytes + need > s->budget_bytes && s->lru_tail) evict_tail(s);

    entry *ne = entry_new(h, key, klen, &v, expire);
    if (!ne) { xnet_mutex_unlock(&s->lock); return XSHARED_NOMEM; }
    bucket_insert(s, ne);
    lru_push_front(s, ne);
    s->used_bytes += need;
    s->count++;
    shard_maybe_grow(s);
    if (out_new) *out_new = v.v.num;

    xnet_mutex_unlock(&s->lock);
    return XSHARED_OK;
}

/* ---- TTL --------------------------------------------------------------- */

xshared_status xshared_expire(xshared_dict_t *d, const char *key, size_t klen,
                              int64_t ttl_ms) {
    if (!d || !key) return XSHARED_BADARG;
    uint64_t h = hash_key(key, klen);
    shard   *s = shard_for(d, h);
    int64_t  now = now_ms();

    xnet_mutex_lock(&s->lock);
    entry *e = shard_lookup(s, h, key, klen, now);
    if (!e) { xnet_mutex_unlock(&s->lock); return XSHARED_NOTFOUND; }
    e->expire_ms = (ttl_ms > 0) ? now + ttl_ms : 0;
    xnet_mutex_unlock(&s->lock);
    return XSHARED_OK;
}

xshared_status xshared_ttl(xshared_dict_t *d, const char *key, size_t klen,
                           int64_t *out_ms) {
    if (!d || !key || !out_ms) return XSHARED_BADARG;
    uint64_t h = hash_key(key, klen);
    shard   *s = shard_for(d, h);
    int64_t  now = now_ms();

    xnet_mutex_lock(&s->lock);
    entry *e = shard_lookup(s, h, key, klen, now);
    if (!e) { xnet_mutex_unlock(&s->lock); return XSHARED_NOTFOUND; }
    *out_ms = (e->expire_ms == 0) ? -1 : (e->expire_ms - now);
    xnet_mutex_unlock(&s->lock);
    return XSHARED_OK;
}

/* ---- maintenance ------------------------------------------------------- */

/* Reap expired keys incrementally: resume from the dict's round-robin cursor,
** scan at most `budget` entries this call (0 = one full pass), then save the
** cursor for next time. Called only from the main thread (xshared_tick), so the
** cursor needs no lock; each shard's own lock guards its scan. Bounding the
** per-call work caps both CPU and lock-hold time on large dicts. Internal: the
** only caller is xshared_tick (same thread), so it is not declared in the header. */
static size_t sweep_expired(xshared_dict_t *d, size_t budget) {
    if (!d) return 0;
    size_t   reaped = 0, scanned = 0;
    int64_t  now = now_ms();
    uint32_t si = d->sweep_shard;
    size_t   bi = d->sweep_bucket;

    for (uint32_t visited = 0; visited < d->nshards; visited++) {
        shard *s = &d->shards[si];
        xnet_mutex_lock(&s->lock);
        if (bi >= s->nbuckets) bi = 0;          /* bucket array grew under us */
        for (; bi < s->nbuckets; bi++) {
            entry **pp = &s->buckets[bi];
            while (*pp) {
                entry *e = *pp;
                scanned++;
                if (e->expire_ms != 0 && e->expire_ms <= now) {
                    *pp = e->hnext;
                    lru_unlink(s, e);
                    s->used_bytes -= entry_bytes(e);
                    s->count--;
                    s->expired++;
                    free(e);
                    reaped++;
                } else {
                    pp = &e->hnext;
                }
                if (budget && scanned >= budget) { /* pause; resume this bucket */
                    d->sweep_shard  = si;
                    d->sweep_bucket = bi;
                    xnet_mutex_unlock(&s->lock);
                    return reaped;
                }
            }
        }
        xnet_mutex_unlock(&s->lock);
        si = (si + 1) & d->shard_mask;          /* next shard, from its bucket 0 */
        bi = 0;
    }
    d->sweep_shard  = si;
    d->sweep_bucket = 0;
    return reaped;
}

/* Main-thread housekeeping. The runner calls this once per tick; it is
** self-throttled to XSHARED_SWEEP_INTERVAL_MS and then sweeps expired keys from
** every registered dict. This is the single coarse "reaper" that replaces a
** per-key timer: lazy expiry already keeps expired values unobservable, so all
** this does is reclaim the memory of keys nobody touches again. g_registry is
** only ever mutated at boot (on this same main thread), so reading it here needs
** no lock; flush_expired takes each shard's lock for the actual scan. */
void xshared_tick(void) {
    static int64_t last_sweep_ms = 0;
    int64_t now = now_ms();
    if (last_sweep_ms == 0) { last_sweep_ms = now; return; }   /* defer first sweep */
    if (now - last_sweep_ms < XSHARED_SWEEP_INTERVAL_MS) return;
    last_sweep_ms = now;
    for (reg_node *n = g_registry; n; n = n->next) {
        sweep_expired(n->dict, XSHARED_SWEEP_BUDGET);  /* bounded, cursor-resumed */
    }
}

void xshared_stats(xshared_dict_t *d, xshared_stats_t *out) {
    if (!d || !out) return;
    memset(out, 0, sizeof(*out));
    out->nshards = d->nshards;
    for (uint32_t si = 0; si < d->nshards; si++) {
        shard *s = &d->shards[si];
        xnet_mutex_lock(&s->lock);
        out->capacity_bytes += s->budget_bytes;
        out->used_bytes     += s->used_bytes;
        out->item_count     += s->count;
        out->evicted        += s->evicted;
        out->expired        += s->expired;
        xnet_mutex_unlock(&s->lock);
    }
}

/* ---- registry / lifecycle (MAIN thread, at boot) ----------------------- */

xshared_dict_t *xshared_get_dict(const char *name) {
    if (!name) return NULL;
    for (reg_node *n = g_registry; n; n = n->next) {
        if (strcmp(n->dict->name, name) == 0) return n->dict;
    }
    return NULL;
}

xshared_dict_t *xshared_create(const char *name, size_t budget_bytes,
                               uint32_t nshards) {
    if (!name || budget_bytes == 0) return NULL;
    if (xshared_get_dict(name)) return NULL;   /* duplicate */

    if (nshards == 0) nshards = 8;
    nshards = next_pow2_u32(nshards);
    if (nshards > XSHARED_MAX_SHARDS) nshards = XSHARED_MAX_SHARDS;

    xshared_dict_t *d = (xshared_dict_t *)calloc(1, sizeof(*d));
    if (!d) return NULL;
    d->name = strdup(name);
    d->shards = (shard *)calloc(nshards, sizeof(shard));
    if (!d->name || !d->shards) { free(d->name); free(d->shards); free(d); return NULL; }
    d->nshards    = nshards;
    d->shard_mask = nshards - 1;

    size_t per = budget_bytes / nshards;
    if (per < sizeof(entry)) per = sizeof(entry);   /* at least one tiny entry */

    for (uint32_t i = 0; i < nshards; i++) {
        shard *s = &d->shards[i];
        xnet_mutex_init(&s->lock);
        s->buckets = (entry **)calloc(XSHARED_INIT_BUCKETS, sizeof(entry *));
        if (!s->buckets) {
            /* unwind the shards built so far */
            for (uint32_t j = 0; j <= i; j++) {
                if (d->shards[j].buckets) free(d->shards[j].buckets);
                xnet_mutex_uninit(&d->shards[j].lock);
            }
            free(d->shards); free(d->name); free(d);
            return NULL;
        }
        s->nbuckets     = XSHARED_INIT_BUCKETS;
        s->budget_bytes = per;
    }

    reg_node *node = (reg_node *)malloc(sizeof(reg_node));
    if (!node) { /* leak-free unwind */
        for (uint32_t i = 0; i < nshards; i++) {
            free(d->shards[i].buckets);
            xnet_mutex_uninit(&d->shards[i].lock);
        }
        free(d->shards); free(d->name); free(d);
        return NULL;
    }
    node->dict = d;
    node->next = g_registry;
    g_registry = node;
    return d;
}

static void dict_free(xshared_dict_t *d) {
    if (!d) return;
    for (uint32_t si = 0; si < d->nshards; si++) {
        shard *s = &d->shards[si];
        for (size_t bi = 0; bi < s->nbuckets; bi++) {
            entry *e = s->buckets[bi];
            while (e) { entry *nx = e->hnext; free(e); e = nx; }
        }
        free(s->buckets);
        xnet_mutex_uninit(&s->lock);
    }
    free(d->shards);
    free(d->name);
    free(d);
}

void xshared_shutdown(void) {
    reg_node *n = g_registry;
    g_registry = NULL;
    while (n) {
        reg_node *nx = n->next;
        dict_free(n->dict);
        free(n);
        n = nx;
    }
}
