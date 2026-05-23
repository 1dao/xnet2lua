#ifndef __XHASH_H__
#define __XHASH_H__

#include <stddef.h>
#include <stdbool.h>
#include <string.h>
#include <stdlib.h>
#include <stdint.h>
#include <assert.h>

/* Route malloc/free/strdup used by XHASH_MALLOC/FREE/STRDUP through rpmalloc.
** xmacro.h is self-contained: it pulls <stdlib.h>/<string.h> first, then
** shadows the libc names — safe to include after the prototypes above. */
#include "xmacro.h"

#ifdef __cplusplus
extern "C" {
#endif

/* ========== Inline Control ========== */
#ifndef XHASH_NO_INLINE
    #define XHASH_INLINE static inline
#else
    #define XHASH_INLINE
#endif

/* ========== Allocator Macros ========== */
#ifndef XHASH_MALLOC
    #define XHASH_MALLOC(sz)  malloc(sz)
    #define XHASH_FREE(p)     free(p)
#endif
#ifndef XHASH_STRDUP
    #if !defined(_POSIX_C_SOURCE) && !defined(_XOPEN_SOURCE)
        #define _POSIX_C_SOURCE 200809L
    #endif
    #define XHASH_STRDUP(s)   strdup(s)
#endif

/* ========== Key Type ========== */
typedef enum { XHASH_KEY_INT, XHASH_KEY_STR } xhashKeyType;

/* ========== Unified Key ========== */
typedef union {
    long long   i;   
    const char *s;   
} xhashKey;

/* ========== Node ========== */
typedef struct xhashNode {
    union {
        long long  i;
        char      *s;
    } key;
    void             *value;
    struct xhashNode *next;   
} xhashNode;

/* ========== Active Bucket Index Tracker ========== */
typedef struct {
    size_t *indices;
    int    *pos;
    size_t  count;
} xhashActive;

XHASH_INLINE bool xhash_active_init(xhashActive *a, size_t size) {
    a->indices = (size_t*)XHASH_MALLOC(size * sizeof(size_t));
    if (!a->indices) return false;
    a->pos = (int*)XHASH_MALLOC(size * sizeof(int));
    if (!a->pos) { XHASH_FREE(a->indices); a->indices = NULL; return false; }
    for (size_t i = 0; i < size; i++) a->pos[i] = -1;
    a->count = 0;
    return true;
}

XHASH_INLINE void xhash_active_free(xhashActive *a) {
    if (a->indices) XHASH_FREE(a->indices); 
    if (a->pos) XHASH_FREE(a->pos);     
    a->indices = NULL;
    a->pos = NULL;
    a->count = 0;
}

XHASH_INLINE void xhash_active_add(xhashActive *a, size_t idx) {
    a->pos[idx]          = (int)a->count;
    a->indices[a->count] = idx;
    a->count++;
}

XHASH_INLINE void xhash_active_remove(xhashActive *a, size_t idx) {
    int    p    = a->pos[idx];
    size_t last = a->indices[a->count - 1];
    a->indices[p] = last;
    a->pos[last]  = p;
    a->pos[idx]   = -1;
    a->count--;
}

/* ========== Hash Table ========== */
typedef struct {
    xhashNode   **buckets;   
    xhashKeyType  key_type;
    size_t        size;      /* 保证永远是 2 的幂次方 */
    size_t        count;
    xhashActive   active;
} xhash;

typedef bool (*xhashForeachCb)(xhashKey key, void *value, void *ctx);

#define XHASH_DEFAULT_SIZE 64

// 辅助函数：将数值向上对齐到 2 的幂次方 (Bit Twiddling Hack)
XHASH_INLINE size_t xhash_next_pow2(size_t size) {
    if (size == 0) return XHASH_DEFAULT_SIZE;
    size--;
    size |= size >> 1;
    size |= size >> 2;
    size |= size >> 4;
    size |= size >> 8;
    size |= size >> 16;
#if SIZE_MAX > 0xFFFFFFFFULL
    size |= size >> 32;
#endif
    size++;
    return size;
}

// 提前声明 resize
XHASH_INLINE bool xhash_resize(xhash *h, size_t new_size);

/* ========== Hash Functions ========== */

XHASH_INLINE unsigned int xhash_int_func(long long key, size_t size) {
    unsigned long long k = (unsigned long long)key;
    k ^= k >> 33; k *= 0xff51afd7ed558ccdULL;
    k ^= k >> 33; k *= 0xc4ceb9fe1a85ec53ULL;
    k ^= k >> 33;
    // 【性能优化】：通过 size-1 的位与运算替代取模，极大提升速度
    return (unsigned int)(k & (size - 1));
}

XHASH_INLINE unsigned int xhash_str_func(const char *s, size_t size) {
    // 【算法升级】：使用 FNV-1a 算法，碰撞率更低，散列更均匀
    unsigned int h = 2166136261u; // FNV_OFFSET_BASIS
    while (*s) {
        h ^= (unsigned char)*s++;
        h *= 16777619u;           // FNV_PRIME
    }
    return h & (size - 1);
}

/* ========== Lifecycle ========== */

XHASH_INLINE xhash* xhash_create(size_t size, xhashKeyType type) {
    // 强制对齐到 2 的幂次方，以便支持极速的 & 取模
    size = xhash_next_pow2(size);

    xhash *h = (xhash*)XHASH_MALLOC(sizeof(xhash));
    if (!h) return NULL;

    h->buckets = (xhashNode**)XHASH_MALLOC(size * sizeof(xhashNode*));
    if (!h->buckets) { XHASH_FREE(h); return NULL; }
    memset(h->buckets, 0, size * sizeof(xhashNode*));

    if (!xhash_active_init(&h->active, size)) {
        XHASH_FREE(h->buckets);
        XHASH_FREE(h);
        return NULL;
    }

    h->key_type = type;
    h->size     = size;
    h->count    = 0;
    return h;
}

XHASH_INLINE void xhash_destroy(xhash *h, bool free_value) {
    if (!h) return;

    for (size_t i = 0; i < h->active.count; i++) {
        xhashNode *n = h->buckets[h->active.indices[i]];
        while (n) {
            xhashNode *next = n->next;
            if (h->key_type == XHASH_KEY_STR) XHASH_FREE(n->key.s);
            if (free_value && n->value)       XHASH_FREE(n->value);
            XHASH_FREE(n);
            n = next;
        }
    }

    XHASH_FREE(h->buckets);
    xhash_active_free(&h->active);
    XHASH_FREE(h);
}

/* ========== Integer Key Operations ========== */

XHASH_INLINE bool xhash_set_int(xhash *h, long long key, void *value) {
    assert(h && h->key_type == XHASH_KEY_INT);
    if (!h) return false;

    unsigned int idx = xhash_int_func(key, h->size);
    for (xhashNode *n = h->buckets[idx]; n; n = n->next) {
        if (n->key.i == key) { n->value = value; return true; }
    }

    xhashNode *n = (xhashNode*)XHASH_MALLOC(sizeof(xhashNode));
    if (!n) return false;
    n->key.i = key;
    n->value = value;
    n->next  = h->buckets[idx];
    if (!h->buckets[idx]) xhash_active_add(&h->active, idx);
    h->buckets[idx] = n;
    h->count++;
    
    // 【机制优化】：自动扩容，负载因子 (Load Factor) 达到 1.0 时翻倍扩容
    if (h->count >= h->size) {
        xhash_resize(h, h->size * 2);
    }
    return true;
}

XHASH_INLINE void* xhash_get_int(xhash *h, long long key) {
    assert(h && h->key_type == XHASH_KEY_INT);
    if (!h) return NULL;

    unsigned int idx = xhash_int_func(key, h->size);
    for (xhashNode *n = h->buckets[idx]; n; n = n->next)
        if (n->key.i == key) return n->value;
    return NULL;
}

XHASH_INLINE bool xhash_remove_int(xhash *h, long long key, bool free_value) {
    assert(h && h->key_type == XHASH_KEY_INT);
    if (!h) return false;

    unsigned int idx = xhash_int_func(key, h->size);
    xhashNode **pp = &h->buckets[idx];
    while (*pp) {
        if ((*pp)->key.i == key) {
            xhashNode *del = *pp;
            *pp = del->next;
            if (free_value && del->value) XHASH_FREE(del->value);
            XHASH_FREE(del);
            if (!h->buckets[idx]) xhash_active_remove(&h->active, idx);
            h->count--;
            return true;
        }
        pp = &(*pp)->next;
    }
    return false;
}

/* ========== String Key Operations ========== */

XHASH_INLINE bool xhash_set_str(xhash *h, const char *key, void *value) {
    assert(h && h->key_type == XHASH_KEY_STR);
    if (!h || !key) return false;

    unsigned int idx = xhash_str_func(key, h->size);
    for (xhashNode *n = h->buckets[idx]; n; n = n->next) {
        if (strcmp(n->key.s, key) == 0) { n->value = value; return true; }
    }

    xhashNode *n = (xhashNode*)XHASH_MALLOC(sizeof(xhashNode));
    if (!n) return false;
    n->key.s = XHASH_STRDUP(key);
    if (!n->key.s) { XHASH_FREE(n); return false; }
    n->value = value;
    n->next  = h->buckets[idx];
    if (!h->buckets[idx]) xhash_active_add(&h->active, idx);
    h->buckets[idx] = n;
    h->count++;
    
    // 自动扩容，负载因子 (Load Factor) 达到 0.85 时翻倍扩容
    if (h->count * 20 >= h->size * 17) {
        xhash_resize(h, h->size * 2);
    }
    return true;
}

XHASH_INLINE void* xhash_get_str(xhash *h, const char *key) {
    assert(h && h->key_type == XHASH_KEY_STR);
    if (!h || !key) return NULL;

    unsigned int idx = xhash_str_func(key, h->size);
    for (xhashNode *n = h->buckets[idx]; n; n = n->next)
        if (strcmp(n->key.s, key) == 0) return n->value;
    return NULL;
}

XHASH_INLINE bool xhash_remove_str(xhash *h, const char *key, bool free_value) {
    assert(h && h->key_type == XHASH_KEY_STR);
    if (!h || !key) return false;

    unsigned int idx = xhash_str_func(key, h->size);
    xhashNode **pp = &h->buckets[idx];
    while (*pp) {
        if (strcmp((*pp)->key.s, key) == 0) {
            xhashNode *del = *pp;
            *pp = del->next;
            XHASH_FREE(del->key.s);
            if (free_value && del->value) XHASH_FREE(del->value);
            XHASH_FREE(del);
            if (!h->buckets[idx]) xhash_active_remove(&h->active, idx);
            h->count--;
            return true;
        }
        pp = &(*pp)->next;
    }
    return false;
}

/* ========== Query ========== */

XHASH_INLINE size_t xhash_size(const xhash *h) {
    return h ? h->count : 0;
}

/* ========== Foreach ========== */

XHASH_INLINE bool xhash_foreach(xhash *h, xhashForeachCb cb, void *ctx) {
    if (!h || !cb) return false;

    if (h->key_type == XHASH_KEY_INT) {
        for (size_t i = 0; i < h->active.count;) {
            size_t idx = h->active.indices[i];
            xhashNode *n = h->buckets[idx];
            while (n) {
                xhashNode *next = n->next;
                if (!cb((xhashKey){ .i = n->key.i }, n->value, ctx)) return false;
                n = next;
            }
            if (i < h->active.count && h->active.indices[i] == idx)
                i++;
        }
    } else {
        for (size_t i = 0; i < h->active.count;) {
            size_t idx = h->active.indices[i];
            xhashNode *n = h->buckets[idx];
            while (n) {
                xhashNode *next = n->next;
                if (!cb((xhashKey){ .s = n->key.s }, n->value, ctx)) return false;
                n = next;
            }
            if (i < h->active.count && h->active.indices[i] == idx)
                i++;
        }
    }
    return true;
}

/* ========== Resize ========== */

XHASH_INLINE bool xhash_resize(xhash *h, size_t new_size) {
    if (!h || new_size == 0 || new_size == h->size) return false;
    
    // 强制新大小对齐到 2 的幂次方
    new_size = xhash_next_pow2(new_size);

    xhashNode **nb = (xhashNode**)XHASH_MALLOC(new_size * sizeof(xhashNode*));
    if (!nb) return false;
    memset(nb, 0, new_size * sizeof(xhashNode*));

    // 【安全修复】：先分配新的 active 数组，确保内存分配成功后再覆盖旧数据
    xhashActive new_active;
    if (!xhash_active_init(&new_active, new_size)) {
        XHASH_FREE(nb); // 回滚 buckets 的分配
        return false;
    }

    // 内存全部就绪，开始数据迁移
    for (size_t i = 0; i < h->active.count; i++) {
        xhashNode *n = h->buckets[h->active.indices[i]];
        while (n) {
            xhashNode *next = n->next;
            unsigned int ni = (h->key_type == XHASH_KEY_INT)
                ? xhash_int_func(n->key.i, new_size)
                : xhash_str_func(n->key.s, new_size);
            n->next = nb[ni];
            nb[ni]  = n;
            n = next;
        }
    }

    // 更新新 active 追踪器
    for (size_t i = 0; i < new_size; i++) {
        if (nb[i]) xhash_active_add(&new_active, i);
    }

    // 释放旧的数据
    XHASH_FREE(h->buckets);
    xhash_active_free(&h->active);

    // 挂载新数据
    h->buckets = nb;
    h->active = new_active;
    h->size = new_size;

    return true;
}

/* ========== Unified C11 _Generic API ========== */
/*
 * 彻底消除大部分类型不匹配时的编译报错
 */
#if defined(__STDC_VERSION__) && __STDC_VERSION__ >= 201112L

#define xhash_set(h, key, value)            \
    _Generic((key),                         \
        long long:          xhash_set_int,  \
        unsigned long long: xhash_set_int,  \
        long:               xhash_set_int,  \
        unsigned long:      xhash_set_int,  \
        int:                xhash_set_int,  \
        unsigned int:       xhash_set_int,  \
        short:              xhash_set_int,  \
        unsigned short:     xhash_set_int,  \
        char *:             xhash_set_str,  \
        const char *:       xhash_set_str   \
    )(h, key, value)

#define xhash_get(h, key)                   \
    _Generic((key),                         \
        long long:          xhash_get_int,  \
        unsigned long long: xhash_get_int,  \
        long:               xhash_get_int,  \
        unsigned long:      xhash_get_int,  \
        int:                xhash_get_int,  \
        unsigned int:       xhash_get_int,  \
        short:              xhash_get_int,  \
        unsigned short:     xhash_get_int,  \
        char *:             xhash_get_str,  \
        const char *:       xhash_get_str   \
    )(h, key)

#define xhash_remove(h, key, fv)            \
    _Generic((key),                         \
        long long:          xhash_remove_int, \
        unsigned long long: xhash_remove_int, \
        long:               xhash_remove_int, \
        unsigned long:      xhash_remove_int, \
        int:                xhash_remove_int, \
        unsigned int:       xhash_remove_int, \
        short:              xhash_remove_int, \
        unsigned short:     xhash_remove_int, \
        char *:             xhash_remove_str, \
        const char *:       xhash_remove_str  \
    )(h, key, fv)

#endif /* C11 */

#ifdef __cplusplus
}
#endif

#endif /* __XHASH_H__ */