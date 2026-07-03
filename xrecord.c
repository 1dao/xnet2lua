/* xrecord.c -- see xrecord.h for the design rationale. */

#include <string.h>
#include <stdint.h>
#include <math.h>

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

struct xrecord {
    field_t  *fields;
    int       nfields;
    size_t    elem_size;

    void     *pool;        /* capacity * elem_size bytes */
    size_t    capacity;

    uint32_t *free_stack;  /* capacity entries; top `free_top` are free slots */
    size_t    free_top;

    xhash    *id_to_slot;  /* int64 id -> (void*)(uintptr_t)(slot + 1) */
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

static field_t *find_field(xrecord_t *s, const char *name) {
    for (int i = 0; i < s->nfields; i++)
        if (strcmp(s->fields[i].name, name) == 0) return &s->fields[i];
    return NULL;
}

static bool lookup_slot(xrecord_t *s, int64_t id, uint32_t *out_slot) {
    void *v = xhash_get_int(s->id_to_slot, id);
    if (!v) return false;
    *out_slot = (uint32_t)((uintptr_t)v - 1);
    return true;
}

static void free_all_strings(xrecord_t *s) {
    if (!s->pool) return;
    for (int fi = 0; fi < s->nfields; fi++) {
        if (s->fields[fi].type != XRECORD_STRING) continue;
        size_t off = s->fields[fi].offset;
        for (size_t slot = 0; slot < s->capacity; slot++) {
            xrecord_strfield_t *vf =
                (xrecord_strfield_t *)((char *)s->pool + slot * s->elem_size + off);
            if (vf->ptr) { free(vf->ptr); vf->ptr = NULL; }
        }
    }
}

void xrecord_destroy(xrecord_t *s) {
    if (!s) return;
    free_all_strings(s);
    if (s->pool) free(s->pool);
    if (s->free_stack) free(s->free_stack);
    if (s->id_to_slot) xhash_destroy(s->id_to_slot, false);
    if (s->fields) {
        for (int i = 0; i < s->nfields; i++)
            if (s->fields[i].name) free(s->fields[i].name);
        free(s->fields);
    }
    free(s);
}

xrecord_t *xrecord_create(const xrecord_field_def *fields, int nfields, size_t capacity) {
    if (!fields || nfields <= 0 || capacity == 0) return NULL;

    for (int i = 0; i < nfields; i++) {
        if (!fields[i].name || !fields[i].name[0]) return NULL;
        for (int j = i + 1; j < nfields; j++)
            if (strcmp(fields[i].name, fields[j].name) == 0) return NULL;
    }

    xrecord_t *s = (xrecord_t *)calloc(1, sizeof(xrecord_t));
    if (!s) return NULL;

    s->fields = (field_t *)calloc((size_t)nfields, sizeof(field_t));
    if (!s->fields) { xrecord_destroy(s); return NULL; }
    s->nfields = nfields;

    size_t offset = 0, max_align = 1;
    for (int i = 0; i < nfields; i++) {
        s->fields[i].name = strdup(fields[i].name);
        if (!s->fields[i].name) { xrecord_destroy(s); return NULL; }
        size_t align = field_type_align(fields[i].type);
        if (align > max_align) max_align = align;
        offset = align_up(offset, align);
        s->fields[i].type   = fields[i].type;
        s->fields[i].offset = offset;
        offset += field_type_size(fields[i].type);
    }
    /* Round the whole record up to the widest alignment in use so every
    ** slot in the pool array -- not just slot 0 -- keeps its fields aligned. */
    s->elem_size = align_up(offset, max_align);
    s->capacity  = capacity;

    s->pool = calloc(capacity, s->elem_size);
    if (!s->pool) { xrecord_destroy(s); return NULL; }

    s->free_stack = (uint32_t *)malloc(capacity * sizeof(uint32_t));
    if (!s->free_stack) { xrecord_destroy(s); return NULL; }
    for (size_t i = 0; i < capacity; i++)
        s->free_stack[i] = (uint32_t)(capacity - 1 - i);
    s->free_top = capacity;

    s->id_to_slot = xhash_create(capacity, XHASH_KEY_INT);
    if (!s->id_to_slot) { xrecord_destroy(s); return NULL; }

    return s;
}

xrecord_status xrecord_bind(xrecord_t *s, int64_t id) {
    if (!s) return XRECORD_BADARG;
    if (xhash_get_int(s->id_to_slot, id)) return XRECORD_EXISTS;
    if (s->free_top == 0) return XRECORD_FULL;

    uint32_t slot = s->free_stack[s->free_top - 1];

    /* Zero fixed fields; string buffers are left allocated (if any) but
    ** logically emptied -- reuse across pool churn, not a leak. */
    char *rec = (char *)s->pool + (size_t)slot * s->elem_size;
    for (int i = 0; i < s->nfields; i++) {
        field_t *f = &s->fields[i];
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
    return XRECORD_OK;
}

xrecord_status xrecord_unbind(xrecord_t *s, int64_t id) {
    if (!s) return XRECORD_BADARG;
    uint32_t slot;
    if (!lookup_slot(s, id, &slot)) return XRECORD_NOTFOUND;
    xhash_remove_int(s->id_to_slot, id, false);
    s->free_stack[s->free_top++] = slot;
    return XRECORD_OK;
}

bool xrecord_has(xrecord_t *s, int64_t id) {
    if (!s) return false;
    return xhash_get_int(s->id_to_slot, id) != NULL;
}

xrecord_status xrecord_set(xrecord_t *s, int64_t id, const char *field, const xrecord_value *val) {
    if (!s || !field || !val) return XRECORD_BADARG;

    uint32_t slot;
    if (!lookup_slot(s, id, &slot)) return XRECORD_NOTFOUND;
    field_t *f = find_field(s, field);
    if (!f) return XRECORD_NOFIELD;

    void *fp = (char *)s->pool + (size_t)slot * s->elem_size + f->offset;

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
            if (isnan(val->v.num)) return XRECORD_TYPE_MISMATCH;
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
    field_t *f = find_field(s, field);
    if (!f) return XRECORD_NOFIELD;

    void *fp = (char *)s->pool + (size_t)slot * s->elem_size + f->offset;

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
