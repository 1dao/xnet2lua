#ifndef __XRECORD_H__
#define __XRECORD_H__

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
 * xrecord.h -- schema-defined compact record pools (int/bool/string fields),
 * addressed by a caller-supplied int64 id.
 *
 * The problem this replaces: one Lua table per game object (item, quest, ...)
 * puts every live object under the Lua GC's mark/sweep -- at tens of
 * thousands of objects per Lua state that is real, measurable pressure. A
 * record pool moves the DATA into a flat C array and hands Lua only a pool
 * handle; individual records are addressed by integer id and never become
 * Lua objects at all.
 *
 * SCHEMA vs POOL. The layout (field names, types, packed offsets) is a
 * SCHEMA, built once -- e.g. at thread init -- with xrecord_schema_create().
 * Each object instance-set is a POOL, created from that schema with
 * xrecord_pool_create(). The recommended layout is one pool PER PLAYER per
 * object type, all sharing the one schema: the schema's field-name strings
 * and offset computation are paid once, not re-strdup'd for every player's
 * pool. A pool holds a borrowed pointer to its schema, so the schema MUST
 * outlive every pool built from it (the Lua binding enforces this by having
 * each pool userdata keep its schema userdata referenced).
 *
 * FIELD TYPES: int8/int16/int32/int (int64_t), float, bool, string (variable
 * length). Fields are packed with natural alignment (each field's offset is
 * rounded up to its own type's alignment, and the record's total size is
 * rounded up to the widest alignment in use) -- narrow types are a real
 * memory win at high record counts, not just cosmetic, so they are packed
 * tightly rather than padded to a uniform 8 bytes. A string field is stored
 * as an owned {ptr,len} pair; every xrecord_set on a string field calls
 * realloc() unconditionally rather than hand-rolling a capacity check --
 * rpmalloc already returns the same block without copying when the new size
 * still fits the current block's size class (see rpmalloc.c
 * heap_reallocate_block), so a manual capacity field would just duplicate
 * bookkeeping the allocator already does for free.
 *
 * NUMERIC VALUES CROSS THE C API AS double (XRECORD_V_NUM) REGARDLESS OF
 * FIELD WIDTH -- Lua/LuaJIT numbers don't distinguish int from float, so the
 * caller can't tag a value as "meant for an int8 field" vs "meant for a
 * float field" before xrecord_set knows which field it's headed for.
 * xrecord_set narrows/range-checks against the field's declared type: a
 * non-integral value into an int* field, or a value outside the field
 * width's range (e.g. 300 into int8, or a double past FLT_MAX into float),
 * is rejected as TYPE_MISMATCH / OUT_OF_RANGE rather than silently truncated
 * or turned into +/-Inf -- callers that want to treat out-of-range writes as
 * a hard error (e.g. kick a player sending impossible values) can rely on
 * this never clamping quietly. NaN/Inf are rejected for float as well.
 *
 * IDS ARE NOT ALLOCATED HERE. Callers mint ids however their domain requires
 * (DB primary key, (player_id << 24 | local_seq), ...); this module only maps
 * a given id to a slot via xrecord_bind()/xrecord_unbind(). `capacity` passed
 * to xrecord_pool_create() is only the INITIAL preallocation: xrecord_bind()
 * grows the pool (doubling) when it runs out of free slots, with no upper limit.
 * A hard cap that turns "we sized this wrong" into "the feature is down for
 * every player" is worse than a pool that costs a realloc to keep working --
 * if a ceiling is ever needed to catch a genuine id-leak bug instead of
 * legitimate growth, that belongs in a monitoring/alerting layer watching
 * capacity, not as a hard failure here.
 *
 * THREADING: NOT synchronized. Each xnet worker thread has its own private
 * Lua state (shared-nothing), so a record pool created inside one thread's
 * script is only ever touched by that thread. This is the mirror image of
 * xshared.h (which IS cross-thread and pays for shard locks); do not share a
 * xrecord_t* across threads.
 *
 * DIRTY TRACKING, PLAYER/RPC CONCEPTS, REDIS/DB SYNC: all out of scope here
 * and belong in the Lua layer built on top of this module.
 * ===========================================================================*/

typedef enum {
    XRECORD_INT = 0,    /* int64_t, 8 bytes                 */
    XRECORD_INT8,       /* int8_t,  1 byte                  */
    XRECORD_INT16,      /* int16_t, 2 bytes                 */
    XRECORD_INT32,      /* int32_t, 4 bytes                 */
    XRECORD_FLOAT,      /* float,   4 bytes                 */
    XRECORD_BOOL,       /* 1 byte, 0/1                      */
    XRECORD_STRING,     /* variable length: owned {ptr,len}  */
} xrecord_type;

typedef struct {
    const char  *name;
    xrecord_type type;
} xrecord_field_def;

/* ---- status codes ------------------------------------------------------- */

typedef enum {
    XRECORD_OK = 0,
    XRECORD_NOTFOUND,       /* id not bound to a slot */
    XRECORD_EXISTS,         /* bind() found the id already bound */
    XRECORD_NOFIELD,        /* unknown field name */
    XRECORD_TYPE_MISMATCH,  /* value type does not match the field's schema type,
                             ** or a non-integral value was given for an int* field */
    XRECORD_OUT_OF_RANGE,   /* numeric value does not fit the field's width (e.g.
                             ** 300 into an int8 field) */
    XRECORD_NOMEM,          /* allocation failed */
    XRECORD_BADARG,
} xrecord_status;

/* ---- value model (C API boundary) --------------------------------------- */

typedef enum { XRECORD_V_NUM, XRECORD_V_BOOL, XRECORD_V_STR } xrecord_vtype;

/* On xrecord_get, STR is a BORROWED pointer into the record's own buffer --
** valid until the next xrecord_set/unbind/destroy on that id. Copy it out
** (e.g. lua_pushlstring) before doing anything else with that id.
**
** NUM covers every numeric field width (int8/16/32/64, float) as a double --
** see the NUMERIC VALUES note above for why the width-specific narrowing
** happens in xrecord_set/get rather than in this tag. */
typedef struct {
    xrecord_vtype type;
    union {
        double  num;
        int     b;
        struct { const char *ptr; size_t len; } str;
    } v;
} xrecord_value;

/* ---- opaque handles ------------------------------------------------------ */

typedef struct xrecord_schema xrecord_schema_t;   /* shared layout */
typedef struct xrecord        xrecord_t;          /* per-instance pool */

/* Build the shared record layout (field names, types, packed offsets) once.
** Field names must be unique. Returns NULL on OOM or a bad field definition
** (duplicate name, zero fields). Create at thread init and reuse for every
** pool of that object type. */
xrecord_schema_t *xrecord_schema_create(const xrecord_field_def *fields, int nfields);

/* Free a schema. Must not be called while any pool built from it is alive. */
void xrecord_schema_destroy(xrecord_schema_t *sc);

/* Create a pool over `schema`, preallocating `capacity` slots (initial size
** only; bind() grows it). The pool borrows `schema` and does NOT own it --
** `schema` must outlive the pool. Returns NULL on OOM or zero capacity. */
xrecord_t *xrecord_pool_create(xrecord_schema_t *schema, size_t capacity);

/* Frees the pool and every string field's owned buffer. Does NOT free the
** schema (which may back other pools). */
void xrecord_pool_destroy(xrecord_t *s);

/* ---- record lifecycle ---------------------------------------------------- */

/* Claim a free slot for `id` (from the free list) and zero its fixed fields
** (int/bool -> 0, string -> empty). Previously-used slots may still hold an
** allocated (but now empty) string buffer from an earlier occupant -- that is
** intentional reuse, not a leak. Grows the pool (doubling capacity) when no
** slot is free -- see the capacity note above. XRECORD_EXISTS if id is
** already bound; XRECORD_NOMEM only if growth itself fails to allocate. */
xrecord_status xrecord_bind(xrecord_t *s, int64_t id);

/* Release id's slot back to the free list. String buffers are NOT freed here
** (kept warm for the next occupant); they are only freed in xrecord_pool_destroy. */
xrecord_status xrecord_unbind(xrecord_t *s, int64_t id);

bool xrecord_has(xrecord_t *s, int64_t id);

/* ---- field access ---------------------------------------------------------
** NOTFOUND if id is not bound. NOFIELD if `field` is not in the schema.
** TYPE_MISMATCH if val's tag doesn't match the field's declared type. */

xrecord_status xrecord_set(xrecord_t *s, int64_t id, const char *field, const xrecord_value *val);
xrecord_status xrecord_get(xrecord_t *s, int64_t id, const char *field, xrecord_value *out);

/* Set a field from a STRING, coercing to the field's declared type: int
** widths via strtoll, float via strtod (both parsing full precision in C, so
** a 64-bit value survives where a Lua number would not), bool as nonzero, and
** string stored as-is (binary-safe via len). This is the DB-load fast path --
** a text-protocol result column arrives as a string and is typed here without
** building a keyed Lua table. TYPE_MISMATCH if the string is not a valid
** number for a numeric field; OUT_OF_RANGE if it overflows the field width. */
xrecord_status xrecord_set_str(xrecord_t *s, int64_t id, const char *field,
                               const char *str, size_t len);

/* ---- introspection --------------------------------------------------------
** Schema is fixed after create, so field_count/field_name let a caller (e.g.
** the Lua binding's get_all) enumerate fields without re-parsing the schema.
** count = live bound records; capacity = current allocated slots (grows). A
** monitoring layer watches count vs capacity to catch an id-leak (records
** bound and never unbound), which is the intended alternative to a hard cap. */

int         xrecord_field_count(const xrecord_t *s);
const char *xrecord_field_name(const xrecord_t *s, int idx);  /* NULL if idx out of range */
size_t      xrecord_count(const xrecord_t *s);
size_t      xrecord_capacity(const xrecord_t *s);

/* Visit every bound id (hash order, unspecified). Return false from cb to stop
** early. cb must NOT bind/unbind on this pool during iteration. This is what
** lets a per-player pool dump its whole contents at logout without the caller
** tracking an id list. */
typedef bool (*xrecord_visit_fn)(int64_t id, void *ctx);
void xrecord_foreach(xrecord_t *s, xrecord_visit_fn cb, void *ctx);

#ifdef __cplusplus
}
#endif
#endif /* __XRECORD_H__ */
