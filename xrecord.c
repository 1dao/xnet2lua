/* xrecord.c -- see xrecord.h for the design rationale. */

#include <string.h>
#include <stdint.h>
#include <math.h>
#include <float.h>
#include <errno.h>
#include <stdlib.h>

#include "xrecord.h"
#include "xhash.h"

typedef struct {
    char        *ptr;    /* owned, rpmalloc'd; NULL until first non-empty set */
    uint32_t     len;
    uint32_t     _pad;
} xrecord_strfield_t;

typedef struct {
    char        *name;    /* owned copy */
    xrecord_type type;
    size_t       offset;
} field_t;

/* Shared, immutable-after-create layout. One per object type, reused by every
** pool of that type -- field-name strings and offset math are paid once. */
struct xrecord_schema {
    field_t *fields;
    int      nfields;
    size_t   elem_size;
};

/* Per-instance pool. Borrows its schema (does not own it). */
struct xrecord {
    xrecord_schema_t *schema;   /* NOT owned; must outlive this pool */

    void     *pool;        /* capacity * elem_size bytes */
    size_t    capacity;
    size_t    elem_size;   /* cached from schema so teardown needs no schema */

    uint32_t *free_stack;  /* capacity entries; top `free_top` are free slots */
    size_t    free_top;

    xhash    *id_to_slot;  /* int64 id -> (void*)(uintptr_t)(slot + 1) */

    /* Byte offsets of the STRING fields within a record, cached at create so
    ** teardown can free every string buffer WITHOUT touching the schema. At
    ** lua_close the schema and pool userdata finalize in an unspecified order;
    ** reading schema->fields here would be a use-after-free if the schema went
    ** first. Everything the destroy path needs lives in the pool itself. */
    size_t   *str_offsets;
    int       n_str;

    /* 1-entry id->slot cache: game code typically touches the same record
    ** several times in a row (bind then set fields; get several fields), so a
    ** repeat hit skips the hash probe. Slots never move (grow_pool only
    ** appends), so the only invalidation point is unbind of the cached id. */
    int64_t   cached_id;
    uint32_t  cached_slot;
    int       cache_valid;
};

static size_t field_type_size(xrecord_type t) {
    switch (t) {
        case XRECORD_INT8:   return sizeof(int8_t);
        case XRECORD_INT16:  return sizeof(int16_t);
        case XRECORD_INT32:  return sizeof(int32_t);
        case XRECORD_INT:    return sizeof(int64_t);
        case XRECORD_FLOAT:  return sizeof(float);
        case XRECORD_BOOL:   return sizeof(uint8_t);
        case XRECORD_STRING: return sizeof(xrecord_strfield_t);
        default:              return 0;
    }
}

/* Natural alignment per type -- fields are packed at aligned offsets (not
** padded to a uniform width) so int8/int16/int32/float actually save memory
** instead of just adding cases that still cost 8 bytes each. */
static size_t field_type_align(xrecord_type t) {
    switch (t) {
        case XRECORD_INT8:   return 1;
        case XRECORD_INT16:  return 2;
        case XRECORD_INT32:  return 4;
        case XRECORD_INT:    return 8;
        case XRECORD_FLOAT:  return 4;
        case XRECORD_BOOL:   return 1;
        case XRECORD_STRING: return sizeof(void *); /* dominated by the ptr member */
        default:              return 1;
    }
}

static size_t align_up(size_t v, size_t a) {
    return (v + (a - 1)) & ~(a - 1);
}

/* Narrow a caller-supplied double into an int-family field, rejecting NaN,
** fractional values, and out-of-width magnitudes rather than truncating them
** -- callers that want "bad data kicks the player" semantics rely on this
** never clamping quietly. */
static xrecord_status coerce_int(double v, int64_t lo, int64_t hi, int64_t *out) {
    if (isnan(v) || v != floor(v)) return XRECORD_TYPE_MISMATCH;
    if (v < (double)lo || v > (double)hi) return XRECORD_OUT_OF_RANGE;
    *out = (int64_t)v;
    return XRECORD_OK;
}

static field_t *find_field(xrecord_schema_t *sc, const char *name) {
    for (int i = 0; i < sc->nfields; i++)
        if (strcmp(sc->fields[i].name, name) == 0) return &sc->fields[i];
    return NULL;
}

static bool lookup_slot(xrecord_t *s, int64_t id, uint32_t *out_slot) {
    if (s->cache_valid && s->cached_id == id) {
        *out_slot = s->cached_slot;
        return true;
    }
    void *v = xhash_get_int(s->id_to_slot, id);
    if (!v) return false;
    uint32_t slot = (uint32_t)((uintptr_t)v - 1);
    s->cached_id    = id;
    s->cached_slot  = slot;
    s->cache_valid  = 1;
    *out_slot = slot;
    return true;
}

/* ---- schema lifecycle ---------------------------------------------------- */

void xrecord_schema_destroy(xrecord_schema_t *sc) {
    if (!sc) return;
    if (sc->fields) {
        for (int i = 0; i < sc->nfields; i++)
            if (sc->fields[i].name) free(sc->fields[i].name);
        free(sc->fields);
    }
    free(sc);
}

xrecord_schema_t *xrecord_schema_create(const xrecord_field_def *fields, int nfields) {
    if (!fields || nfields <= 0) return NULL;

    for (int i = 0; i < nfields; i++) {
        if (!fields[i].name || !fields[i].name[0]) return NULL;
        for (int j = i + 1; j < nfields; j++)
            if (strcmp(fields[i].name, fields[j].name) == 0) return NULL;
    }

    xrecord_schema_t *sc = (xrecord_schema_t *)calloc(1, sizeof(xrecord_schema_t));
    if (!sc) return NULL;

    sc->fields = (field_t *)calloc((size_t)nfields, sizeof(field_t));
    if (!sc->fields) { xrecord_schema_destroy(sc); return NULL; }
    sc->nfields = nfields;

    for (int i = 0; i < nfields; i++) {
        sc->fields[i].name = strdup(fields[i].name);
        if (!sc->fields[i].name) { xrecord_schema_destroy(sc); return NULL; }
        sc->fields[i].type = fields[i].type;
    }

    /* Stable insertion sort by DESCENDING alignment before assigning offsets.
    ** Fields are looked up by name, never by declaration position, so the
    ** internal order is free to choose -- and widest-first packing produces
    ** zero interior padding (each next alignment divides the previous one),
    ** shrinking elem_size for interleaved declarations like
    ** int8,string,int8,int (24 bytes declared order -> 16 sorted). At high
    ** record counts that is real memory and cache-line savings, not polish. */
    for (int i = 1; i < nfields; i++) {
        field_t key = sc->fields[i];
        size_t  ka  = field_type_align(key.type);
        int j = i - 1;
        while (j >= 0 && field_type_align(sc->fields[j].type) < ka) {
            sc->fields[j + 1] = sc->fields[j];
            j--;
        }
        sc->fields[j + 1] = key;
    }

    size_t offset = 0, max_align = 1;
    for (int i = 0; i < nfields; i++) {
        size_t align = field_type_align(sc->fields[i].type);
        if (align > max_align) max_align = align;
        offset = align_up(offset, align);
        sc->fields[i].offset = offset;
        offset += field_type_size(sc->fields[i].type);
    }
    /* Round the whole record up to the widest alignment in use so every
    ** slot in the pool array -- not just slot 0 -- keeps its fields aligned. */
    sc->elem_size = align_up(offset, max_align);
    return sc;
}

/* ---- pool lifecycle ------------------------------------------------------ */

/* Uses only pool-local cached data (elem_size, str_offsets) -- never the
** schema -- so it is safe even if the schema was already finalized. */
static void free_all_strings(xrecord_t *s) {
    if (!s->pool || !s->str_offsets) return;
    for (int i = 0; i < s->n_str; i++) {
        size_t off = s->str_offsets[i];
        for (size_t slot = 0; slot < s->capacity; slot++) {
            xrecord_strfield_t *vf =
                (xrecord_strfield_t *)((char *)s->pool + slot * s->elem_size + off);
            if (vf->ptr) { free(vf->ptr); vf->ptr = NULL; }
        }
    }
}

void xrecord_pool_destroy(xrecord_t *s) {
    if (!s) return;
    free_all_strings(s);
    if (s->pool) free(s->pool);
    if (s->free_stack) free(s->free_stack);
    if (s->str_offsets) free(s->str_offsets);
    if (s->id_to_slot) xhash_destroy(s->id_to_slot, false);
    free(s);
}

xrecord_t *xrecord_pool_create(xrecord_schema_t *schema, size_t capacity) {
    if (!schema || capacity == 0) return NULL;

    xrecord_t *s = (xrecord_t *)calloc(1, sizeof(xrecord_t));
    if (!s) return NULL;
    s->schema    = schema;
    s->capacity  = capacity;
    s->elem_size = schema->elem_size;

    /* Cache the string-field offsets for a schema-free teardown. */
    for (int i = 0; i < schema->nfields; i++)
        if (schema->fields[i].type == XRECORD_STRING) s->n_str++;
    if (s->n_str > 0) {
        s->str_offsets = (size_t *)malloc((size_t)s->n_str * sizeof(size_t));
        if (!s->str_offsets) { xrecord_pool_destroy(s); return NULL; }
        int k = 0;
        for (int i = 0; i < schema->nfields; i++)
            if (schema->fields[i].type == XRECORD_STRING)
                s->str_offsets[k++] = schema->fields[i].offset;
    }

    s->pool = calloc(capacity, s->elem_size);
    if (!s->pool) { xrecord_pool_destroy(s); return NULL; }

    s->free_stack = (uint32_t *)malloc(capacity * sizeof(uint32_t));
    if (!s->free_stack) { xrecord_pool_destroy(s); return NULL; }
    for (size_t i = 0; i < capacity; i++)
        s->free_stack[i] = (uint32_t)(capacity - 1 - i);
    s->free_top = capacity;

    s->id_to_slot = xhash_create(capacity, XHASH_KEY_INT);
    if (!s->id_to_slot) { xrecord_pool_destroy(s); return NULL; }

    return s;
}

/* Double the pool's capacity when xrecord_bind runs out of free slots. The
** newly added region must be explicitly zeroed -- realloc() does not zero-
** extend the way the initial calloc() did, and a string field's `ptr` must
** start NULL rather than garbage (a later xrecord_set would hand that
** garbage pointer straight to realloc()). */
static xrecord_status grow_pool(xrecord_t *s) {
    size_t old_capacity = s->capacity;
    size_t new_capacity = old_capacity * 2;
    size_t elem_size    = s->elem_size;

    void *new_pool = realloc(s->pool, new_capacity * elem_size);
    if (!new_pool) return XRECORD_NOMEM;
    s->pool = new_pool;
    memset((char *)s->pool + old_capacity * elem_size, 0,
           (new_capacity - old_capacity) * elem_size);

    uint32_t *new_free_stack = (uint32_t *)realloc(s->free_stack, new_capacity * sizeof(uint32_t));
    if (!new_free_stack) return XRECORD_NOMEM;
    s->free_stack = new_free_stack;

    for (size_t i = old_capacity; i < new_capacity; i++)
        s->free_stack[s->free_top++] = (uint32_t)i;

    s->capacity = new_capacity;
    return XRECORD_OK;
}

xrecord_status xrecord_bind(xrecord_t *s, int64_t id) {
    if (!s) return XRECORD_BADARG;
    if (xhash_get_int(s->id_to_slot, id)) return XRECORD_EXISTS;
    if (s->free_top == 0) {
        xrecord_status st = grow_pool(s);
        if (st != XRECORD_OK) return st;
    }

    xrecord_schema_t *sc = s->schema;
    uint32_t slot = s->free_stack[s->free_top - 1];

    /* Zero fixed fields; string buffers are left allocated (if any) but
    ** logically emptied -- reuse across pool churn, not a leak. */
    char *rec = (char *)s->pool + (size_t)slot * sc->elem_size;
    for (int i = 0; i < sc->nfields; i++) {
        field_t *f = &sc->fields[i];
        void *fp = rec + f->offset;
        switch (f->type) {
            case XRECORD_STRING: ((xrecord_strfield_t *)fp)->len = 0; break;
            case XRECORD_INT8:   *(int8_t *)fp  = 0;    break;
            case XRECORD_INT16:  *(int16_t *)fp = 0;    break;
            case XRECORD_INT32:  *(int32_t *)fp = 0;    break;
            case XRECORD_INT:    *(int64_t *)fp = 0;    break;
            case XRECORD_FLOAT:  *(float *)fp   = 0.0f; break;
            case XRECORD_BOOL:   *(uint8_t *)fp = 0;    break;
        }
    }

    if (!xhash_set_int(s->id_to_slot, id, (void *)(uintptr_t)(slot + 1)))
        return XRECORD_NOMEM;

    s->free_top--;

    /* Prime the cache: bind is almost always followed by field writes on the
    ** same id (create-with-table, load paths). */
    s->cached_id   = id;
    s->cached_slot = slot;
    s->cache_valid = 1;
    return XRECORD_OK;
}

xrecord_status xrecord_unbind(xrecord_t *s, int64_t id) {
    if (!s) return XRECORD_BADARG;
    uint32_t slot;
    if (!lookup_slot(s, id, &slot)) return XRECORD_NOTFOUND;
    xhash_remove_int(s->id_to_slot, id, false);
    s->free_stack[s->free_top++] = slot;
    if (s->cache_valid && s->cached_id == id)
        s->cache_valid = 0;
    return XRECORD_OK;
}

bool xrecord_has(xrecord_t *s, int64_t id) {
    if (!s) return false;
    uint32_t slot;
    return lookup_slot(s, id, &slot);
}

xrecord_status xrecord_set(xrecord_t *s, int64_t id, const char *field, const xrecord_value *val) {
    if (!s || !field || !val) return XRECORD_BADARG;

    uint32_t slot;
    if (!lookup_slot(s, id, &slot)) return XRECORD_NOTFOUND;
    field_t *f = find_field(s->schema, field);
    if (!f) return XRECORD_NOFIELD;

    void *fp = (char *)s->pool + (size_t)slot * s->schema->elem_size + f->offset;

    switch (f->type) {
        case XRECORD_INT8: {
            if (val->type != XRECORD_V_NUM) return XRECORD_TYPE_MISMATCH;
            int64_t iv;
            xrecord_status st = coerce_int(val->v.num, INT8_MIN, INT8_MAX, &iv);
            if (st != XRECORD_OK) return st;
            *(int8_t *)fp = (int8_t)iv;
            return XRECORD_OK;
        }
        case XRECORD_INT16: {
            if (val->type != XRECORD_V_NUM) return XRECORD_TYPE_MISMATCH;
            int64_t iv;
            xrecord_status st = coerce_int(val->v.num, INT16_MIN, INT16_MAX, &iv);
            if (st != XRECORD_OK) return st;
            *(int16_t *)fp = (int16_t)iv;
            return XRECORD_OK;
        }
        case XRECORD_INT32: {
            if (val->type != XRECORD_V_NUM) return XRECORD_TYPE_MISMATCH;
            int64_t iv;
            xrecord_status st = coerce_int(val->v.num, INT32_MIN, INT32_MAX, &iv);
            if (st != XRECORD_OK) return st;
            *(int32_t *)fp = (int32_t)iv;
            return XRECORD_OK;
        }
        case XRECORD_INT: {
            if (val->type != XRECORD_V_NUM) return XRECORD_TYPE_MISMATCH;
            if (isnan(val->v.num) || val->v.num != floor(val->v.num)) return XRECORD_TYPE_MISMATCH;
            *(int64_t *)fp = (int64_t)val->v.num;
            return XRECORD_OK;
        }
        case XRECORD_FLOAT:
            if (val->type != XRECORD_V_NUM) return XRECORD_TYPE_MISMATCH;
            /* NaN/Inf are never valid game data; a finite double past float's
            ** range would cast to +/-Inf, which is the silent corruption the
            ** hard-error contract exists to prevent -- reject it instead. */
            if (isnan(val->v.num) || isinf(val->v.num)) return XRECORD_TYPE_MISMATCH;
            if (val->v.num < -(double)FLT_MAX || val->v.num > (double)FLT_MAX)
                return XRECORD_OUT_OF_RANGE;
            *(float *)fp = (float)val->v.num;
            return XRECORD_OK;

        case XRECORD_BOOL:
            if (val->type != XRECORD_V_BOOL) return XRECORD_TYPE_MISMATCH;
            *(uint8_t *)fp = val->v.b ? 1 : 0;
            return XRECORD_OK;

        case XRECORD_STRING: {
            if (val->type != XRECORD_V_STR) return XRECORD_TYPE_MISMATCH;
            xrecord_strfield_t *vf = (xrecord_strfield_t *)fp;
            size_t len = val->v.str.len;
            if (len > 0) {
                /* Always realloc -- rpmalloc returns the same block without
                ** copying when len still fits the current size class, so a
                ** hand-rolled capacity field would only duplicate that. */
                char *np = (char *)realloc(vf->ptr, len);
                if (!np) return XRECORD_NOMEM;
                memcpy(np, val->v.str.ptr, len);
                vf->ptr = np;
            }
            vf->len = (uint32_t)len;
            return XRECORD_OK;
        }
    }
    return XRECORD_BADARG;
}

xrecord_status xrecord_get(xrecord_t *s, int64_t id, const char *field, xrecord_value *out) {
    if (!s || !field || !out) return XRECORD_BADARG;

    uint32_t slot;
    if (!lookup_slot(s, id, &slot)) return XRECORD_NOTFOUND;
    field_t *f = find_field(s->schema, field);
    if (!f) return XRECORD_NOFIELD;

    void *fp = (char *)s->pool + (size_t)slot * s->schema->elem_size + f->offset;

    switch (f->type) {
        case XRECORD_INT8:
            out->type = XRECORD_V_NUM;
            out->v.num = (double)(*(int8_t *)fp);
            return XRECORD_OK;

        case XRECORD_INT16:
            out->type = XRECORD_V_NUM;
            out->v.num = (double)(*(int16_t *)fp);
            return XRECORD_OK;

        case XRECORD_INT32:
            out->type = XRECORD_V_NUM;
            out->v.num = (double)(*(int32_t *)fp);
            return XRECORD_OK;

        case XRECORD_INT:
            out->type = XRECORD_V_NUM;
            out->v.num = (double)(*(int64_t *)fp);
            return XRECORD_OK;

        case XRECORD_FLOAT:
            out->type = XRECORD_V_NUM;
            out->v.num = (double)(*(float *)fp);
            return XRECORD_OK;

        case XRECORD_BOOL:
            out->type = XRECORD_V_BOOL;
            out->v.b  = (*(uint8_t *)fp) != 0;
            return XRECORD_OK;

        case XRECORD_STRING: {
            xrecord_strfield_t *vf = (xrecord_strfield_t *)fp;
            out->type      = XRECORD_V_STR;
            out->v.str.ptr = vf->ptr;
            out->v.str.len = vf->len;
            return XRECORD_OK;
        }
    }
    return XRECORD_BADARG;
}

/* Parse `str` (NUL-terminated) as a base-10 integer, requiring the whole
** string to be consumed (leading spaces allowed, trailing junk rejected). */
static xrecord_status parse_ll(const char *str, long long *out) {
    errno = 0;
    char *end;
    long long v = strtoll(str, &end, 10);
    if (end == str) return XRECORD_TYPE_MISMATCH;     /* no digits */
    while (*end == ' ' || *end == '\t') end++;         /* tolerate trailing blanks */
    if (*end != '\0') return XRECORD_TYPE_MISMATCH;    /* trailing junk */
    if (errno == ERANGE) return XRECORD_OUT_OF_RANGE;
    *out = v;
    return XRECORD_OK;
}

xrecord_status xrecord_set_str(xrecord_t *s, int64_t id, const char *field,
                               const char *str, size_t len) {
    if (!s || !field || !str) return XRECORD_BADARG;

    uint32_t slot;
    if (!lookup_slot(s, id, &slot)) return XRECORD_NOTFOUND;
    field_t *f = find_field(s->schema, field);
    if (!f) return XRECORD_NOFIELD;

    void *fp = (char *)s->pool + (size_t)slot * s->schema->elem_size + f->offset;

    switch (f->type) {
        case XRECORD_STRING: {
            /* store bytes as-is (binary-safe) -- same reuse path as xrecord_set */
            xrecord_strfield_t *vf = (xrecord_strfield_t *)fp;
            if (len > 0) {
                char *np = (char *)realloc(vf->ptr, len);
                if (!np) return XRECORD_NOMEM;
                memcpy(np, str, len);
                vf->ptr = np;
            }
            vf->len = (uint32_t)len;
            return XRECORD_OK;
        }
        case XRECORD_FLOAT: {
            errno = 0;
            char *end;
            double d = strtod(str, &end);
            if (end == str) return XRECORD_TYPE_MISMATCH;
            while (*end == ' ' || *end == '\t') end++;
            if (*end != '\0') return XRECORD_TYPE_MISMATCH;
            if (isnan(d) || isinf(d)) return XRECORD_TYPE_MISMATCH;
            if (d < -(double)FLT_MAX || d > (double)FLT_MAX) return XRECORD_OUT_OF_RANGE;
            *(float *)fp = (float)d;
            return XRECORD_OK;
        }
        default: {  /* int8/int16/int32/int/bool -- all integer-parsed */
            long long v;
            xrecord_status st = parse_ll(str, &v);
            if (st != XRECORD_OK) return st;
            switch (f->type) {
                case XRECORD_INT8:
                    if (v < INT8_MIN  || v > INT8_MAX)  return XRECORD_OUT_OF_RANGE;
                    *(int8_t *)fp = (int8_t)v; return XRECORD_OK;
                case XRECORD_INT16:
                    if (v < INT16_MIN || v > INT16_MAX) return XRECORD_OUT_OF_RANGE;
                    *(int16_t *)fp = (int16_t)v; return XRECORD_OK;
                case XRECORD_INT32:
                    if (v < INT32_MIN || v > INT32_MAX) return XRECORD_OUT_OF_RANGE;
                    *(int32_t *)fp = (int32_t)v; return XRECORD_OK;
                case XRECORD_INT:
                    *(int64_t *)fp = (int64_t)v; return XRECORD_OK;
                case XRECORD_BOOL:
                    *(uint8_t *)fp = (v != 0); return XRECORD_OK;
                default:
                    return XRECORD_BADARG;
            }
        }
    }
}

int xrecord_field_count(const xrecord_t *s) {
    return s ? s->schema->nfields : 0;
}

const char *xrecord_field_name(const xrecord_t *s, int idx) {
    if (!s || idx < 0 || idx >= s->schema->nfields) return NULL;
    return s->schema->fields[idx].name;
}

size_t xrecord_count(const xrecord_t *s) {
    return s ? xhash_size(s->id_to_slot) : 0;
}

size_t xrecord_capacity(const xrecord_t *s) {
    return s ? s->capacity : 0;
}

typedef struct { xrecord_visit_fn cb; void *ctx; } visit_adapter;

static bool visit_trampoline(xhashKey key, void *value, void *ctx_) {
    (void)value;
    visit_adapter *a = (visit_adapter *)ctx_;
    return a->cb((int64_t)key.i, a->ctx);
}

void xrecord_foreach(xrecord_t *s, xrecord_visit_fn cb, void *ctx) {
    if (!s || !cb) return;
    visit_adapter a = { cb, ctx };
    xhash_foreach(s->id_to_slot, visit_trampoline, &a);
}
