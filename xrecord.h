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
 * record pool moves the DATA into a flat C array (rpmalloc'd once, sized at
 * create time) and hands Lua only the SCHEMA HANDLE -- one userdata per
 * object *type* (Item, Quest, ...), not one per instance. Individual records
 * are addressed by integer id and never become Lua objects at all.
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
 * width's range (e.g. 300 into int8), is rejected as TYPE_MISMATCH /
 * OUT_OF_RANGE rather than silently truncated -- callers that want to treat
 * out-of-range writes as a hard error (e.g. kick a player sending impossible
 * values) can rely on this never clamping quietly.
 *
 * IDS ARE NOT ALLOCATED HERE. Callers mint ids however their domain requires
 * (DB primary key, (player_id << 32 | local_seq), ...); this module only maps
 * a given id to a slot via xrecord_bind()/xrecord_unbind(). A record pool has
 * a fixed capacity chosen at create time -- there is no growth in v1.
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
    XRECORD_FULL,           /* bind() found no free slot (capacity reached) */
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

/* ---- the pool handle (opaque) -------------------------------------------- */

typedef struct xrecord xrecord_t;

/* Define the record layout and preallocate `capacity` slots. Field names must
** be unique. Returns NULL on OOM or a bad field definition (duplicate name,
** zero fields, zero capacity). */
xrecord_t *xrecord_create(const xrecord_field_def *fields, int nfields, size_t capacity);

/* Frees the pool, every string field's owned buffer, and the handle itself. */
void xrecord_destroy(xrecord_t *s);

/* ---- record lifecycle ---------------------------------------------------- */

/* Claim a free slot for `id` (from the free list) and zero its fixed fields
** (int/bool -> 0, string -> empty). Previously-used slots may still hold an
** allocated (but now empty) string buffer from an earlier occupant -- that is
** intentional reuse, not a leak. XRECORD_EXISTS if id is already bound,
** XRECORD_FULL if capacity is exhausted. */
xrecord_status xrecord_bind(xrecord_t *s, int64_t id);

/* Release id's slot back to the free list. String buffers are NOT freed here
** (kept warm for the next occupant); they are only freed in xrecord_destroy. */
xrecord_status xrecord_unbind(xrecord_t *s, int64_t id);

bool xrecord_has(xrecord_t *s, int64_t id);

/* ---- field access ---------------------------------------------------------
** NOTFOUND if id is not bound. NOFIELD if `field` is not in the schema.
** TYPE_MISMATCH if val's tag doesn't match the field's declared type. */

xrecord_status xrecord_set(xrecord_t *s, int64_t id, const char *field, const xrecord_value *val);
xrecord_status xrecord_get(xrecord_t *s, int64_t id, const char *field, xrecord_value *out);

#ifdef __cplusplus
}
#endif
#endif /* __XRECORD_H__ */
