/* lua_xrecord.c -- Lua bindings for xrecord (schema-defined compact record
** pools; see xrecord.h for the design rationale).
**
** A schema is built once (e.g. at thread init) and names a PRIMARY KEY column
** (default "id") plus the non-key fields. Pools are created from the schema,
** one per player per object type; records never become Lua objects -- only
** ints (ids) and the pool handle do:
**
**   -- ONCE at init: shared layout, pk column defaults to "id"
**   local item_schema = xrecord.schema({
**       { name = "hp",   type = "int"    },
**       { name = "name", type = "string" },
**       { name = "dead", type = "bool"   },
**   })
**
**   -- per player at login: a pool over the schema
**   local items = item_schema:new(16)
**   items:create({ id = 1001, hp = 100, name = "sword" })  -- upsert one record
**   items:create(1002)                                     -- just reserve the id
**   items:set(1001, "hp", 90)
**   local hp = items:get(1001, "hp")
**   items:destroy(1002)                                    -- remove a record
**
**   -- bulk: login loads, logout saves; the two round-trip
**   items:load_all(db_rows)          -- array of { id=, field=value, ... }
**   local rows = items:save_all()     -- whole pool -> array of records -> DB
**   items:close()                     -- free the pool's C memory at logout
**
** The pk column is a naming convention, not a stored field: create()/load_all
** read the id from record[pk]; save_all writes it back as record[pk]. The id
** lives only in the index, so it cannot be corrupted via set().
**
** NOT thread-safe: a handle belongs to the Lua state that created it; never
** share one across xnet's shared-nothing threads.
*/

#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <errno.h>

#if defined(LUA_EMBEDDED)
#include "../3rd/minilua.h"
#else
#include "lua.h"
#include "lauxlib.h"
#endif

#include "../xrecord.h"

#define LUA_XRECORD_META        "xrecord.handle"
#define LUA_XRECORD_SCHEMA_META "xrecord.schema"
#define XRECORD_MAX_FIELDS 64
#define XRECORD_MAX_NAME_LEN 63

typedef struct {
    xrecord_schema_t *sc;
    char              pk[XRECORD_MAX_NAME_LEN + 1];   /* primary-key column name */
} LuaSchema;

/* A pool userdata pins its schema userdata via schema_ref (a registry ref) so
** the borrowed xrecord_schema_t can't be collected while the pool lives. pk is
** copied from the schema so create/save/load need no schema roundtrip. */
typedef struct {
    xrecord_t *s;
    int        schema_ref;
    char       pk[XRECORD_MAX_NAME_LEN + 1];
} LuaRecord;

static LuaSchema *check_schema(lua_State *L, int idx) {
    return (LuaSchema *)luaL_checkudata(L, idx, LUA_XRECORD_SCHEMA_META);
}

static LuaRecord *check_record(lua_State *L, int idx) {
    return (LuaRecord *)luaL_checkudata(L, idx, LUA_XRECORD_META);
}

static const char *status_msg(xrecord_status st) {
    switch (st) {
        case XRECORD_OK:            return NULL;
        case XRECORD_NOTFOUND:      return "id not bound";
        case XRECORD_EXISTS:        return "id already bound";
        case XRECORD_NOFIELD:       return "unknown field";
        case XRECORD_TYPE_MISMATCH: return "value type does not match field schema";
        case XRECORD_OUT_OF_RANGE:  return "value out of range for field type";
        case XRECORD_NOMEM:         return "out of memory";
        case XRECORD_BADARG:        return "bad argument";
        default:                    return "unknown error";
    }
}

/* Lua value -> xrecord_value (string ptr is borrowed from the Lua stack, only
** valid for the duration of the xrecord_set call that consumes it).
**
** Numbers are tagged XRECORD_V_NUM carrying a plain double regardless of field
** width -- Lua/LuaJIT has no int/float distinction to key off of here;
** xrecord_set narrows and range-checks against the target field's declared
** type (see xrecord.h). */
static int to_value(lua_State *L, int idx, xrecord_value *out) {
    switch (lua_type(L, idx)) {
        case LUA_TNUMBER:
            out->type  = XRECORD_V_NUM;
            out->v.num = lua_tonumber(L, idx);
            return 1;
        case LUA_TBOOLEAN:
            out->type = XRECORD_V_BOOL;
            out->v.b  = lua_toboolean(L, idx);
            return 1;
        case LUA_TSTRING: {
            size_t len;
            const char *str = lua_tolstring(L, idx, &len);
            out->type      = XRECORD_V_STR;
            out->v.str.ptr = str;
            out->v.str.len = len;
            return 1;
        }
        default:
            return 0;
    }
}

static void push_value(lua_State *L, const xrecord_value *v) {
    switch (v->type) {
        case XRECORD_V_NUM:  lua_pushnumber(L, v->v.num); break;
        case XRECORD_V_BOOL: lua_pushboolean(L, v->v.b); break;
        case XRECORD_V_STR:
            if (v->v.str.len == 0) lua_pushliteral(L, "");
            else                   lua_pushlstring(L, v->v.str.ptr, v->v.str.len);
            break;
        default: lua_pushnil(L); break;
    }
}

static int parse_type(const char *s, xrecord_type *out) {
    if (strcmp(s, "int") == 0)    { *out = XRECORD_INT;    return 1; }
    if (strcmp(s, "int8") == 0)   { *out = XRECORD_INT8;   return 1; }
    if (strcmp(s, "int16") == 0)  { *out = XRECORD_INT16;  return 1; }
    if (strcmp(s, "int32") == 0)  { *out = XRECORD_INT32;  return 1; }
    if (strcmp(s, "float") == 0)  { *out = XRECORD_FLOAT;  return 1; }
    if (strcmp(s, "bool") == 0)   { *out = XRECORD_BOOL;   return 1; }
    if (strcmp(s, "string") == 0) { *out = XRECORD_STRING; return 1; }
    return 0;
}

/* Apply every string-keyed entry of the table at index `tbl_idx` to `id` via
** xrecord_set, skipping a key equal to `skip_key` (the pk column). Stops at the
** first non-OK status (no rollback -- a trusted bulk/load path, not per-field
** runtime writes). On failure copies the offending field name into out_field
** (a plain C buffer, safe after this returns). */
static xrecord_status apply_fields(lua_State *L, xrecord_t *s, int64_t id, int tbl_idx,
                                    const char *skip_key, char *out_field, size_t out_field_cap) {
    lua_pushnil(L);
    while (lua_next(L, tbl_idx) != 0) {
        /* key at -2, value at -1 */
        if (lua_type(L, -2) != LUA_TSTRING) {
            lua_pop(L, 2);
            return XRECORD_BADARG;
        }
        const char *key = lua_tostring(L, -2);
        if (skip_key && strcmp(key, skip_key) == 0) {
            lua_pop(L, 1);
            continue;
        }

        xrecord_value val;
        if (!to_value(L, -1, &val)) {
            if (out_field) { strncpy(out_field, key, out_field_cap - 1); out_field[out_field_cap - 1] = '\0'; }
            lua_pop(L, 2);
            return XRECORD_BADARG;
        }

        xrecord_status st = xrecord_set(s, id, key, &val);
        if (st != XRECORD_OK) {
            if (out_field) { strncpy(out_field, key, out_field_cap - 1); out_field[out_field_cap - 1] = '\0'; }
            lua_pop(L, 2);
            return st;
        }
        lua_pop(L, 1);
    }
    return XRECORD_OK;
}

/* Push a new Lua table holding record `id`'s fields plus its primary-key column
** (pk -> id) so the table round-trips through create/load_all. id must be bound
** and every field name comes from the fixed schema, so xrecord_get cannot fail
** -- a defensive nil guards a hypothetical failure. */
static void push_record_table(lua_State *L, xrecord_t *s, int64_t id, const char *pk) {
    int nfields = xrecord_field_count(s);
    lua_createtable(L, 0, nfields + 1);
    lua_pushinteger(L, (lua_Integer)id);
    lua_setfield(L, -2, pk);
    for (int i = 0; i < nfields; i++) {
        const char *field = xrecord_field_name(s, i);
        xrecord_value val;
        if (xrecord_get(s, id, field, &val) == XRECORD_OK) push_value(L, &val);
        else                                               lua_pushnil(L);
        lua_setfield(L, -2, field);
    }
}

/* Parse a { {name=,type=}, ... } field table at absolute index `fields_idx`
** into a shared schema, validating that no field is named `pk`. Field
** names/types are copied into plain C memory. Raises a Lua error on any
** malformed field list. */
static xrecord_schema_t *build_schema(lua_State *L, int fields_idx, const char *pk) {
    luaL_checktype(L, fields_idx, LUA_TTABLE);
    lua_Integer n = (lua_Integer)lua_rawlen(L, fields_idx);
    if (n <= 0)
        luaL_error(L, "xrecord: field list is empty");
    if (n > XRECORD_MAX_FIELDS)
        luaL_error(L, "xrecord: too many fields (max %d)", XRECORD_MAX_FIELDS);

    char name_buf[XRECORD_MAX_FIELDS][XRECORD_MAX_NAME_LEN + 1];
    xrecord_field_def defs[XRECORD_MAX_FIELDS];

    for (lua_Integer i = 0; i < n; i++) {
        lua_rawgeti(L, fields_idx, i + 1);
        if (!lua_istable(L, -1))
            luaL_error(L, "xrecord: field #%d is not a table", (int)(i + 1));

        lua_getfield(L, -1, "name");
        const char *name = luaL_checkstring(L, -1);
        if (strlen(name) > XRECORD_MAX_NAME_LEN)
            luaL_error(L, "xrecord: field name '%s' too long", name);
        if (strcmp(name, pk) == 0)
            luaL_error(L, "xrecord: field '%s' collides with the primary key column", name);
        strcpy(name_buf[i], name);

        lua_getfield(L, -2, "type");
        const char *type_str = luaL_checkstring(L, -1);
        xrecord_type type;
        if (!parse_type(type_str, &type))
            luaL_error(L, "xrecord: field '%s' has unknown type '%s'", name, type_str);

        lua_pop(L, 3); /* type, name, field table */

        defs[i].name = name_buf[i];
        defs[i].type = type;
    }

    xrecord_schema_t *sc = xrecord_schema_create(defs, (int)n);
    if (!sc)
        luaL_error(L, "xrecord: schema create failed (duplicate field name or OOM)");
    return sc;
}

static void push_schema_ud(lua_State *L, xrecord_schema_t *sc, const char *pk) {
    LuaSchema *u = (LuaSchema *)lua_newuserdata(L, sizeof(LuaSchema));
    u->sc = sc;
    strncpy(u->pk, pk, sizeof(u->pk) - 1);
    u->pk[sizeof(u->pk) - 1] = '\0';
    luaL_setmetatable(L, LUA_XRECORD_SCHEMA_META);
}

/* Create a pool over the schema userdata at absolute index `schema_idx`,
** pinning it via a registry ref and copying its pk name into the pool. Pushes
** the pool userdata and returns 1. */
static int make_pool(lua_State *L, int schema_idx, lua_Integer capacity) {
    LuaSchema *su = check_schema(L, schema_idx);
    if (capacity <= 0)
        return luaL_error(L, "xrecord: capacity must be > 0");

    xrecord_t *s = xrecord_pool_create(su->sc, (size_t)capacity);
    if (!s)
        return luaL_error(L, "xrecord: pool create failed (OOM)");

    LuaRecord *u = (LuaRecord *)lua_newuserdata(L, sizeof(LuaRecord));
    u->s = s;
    u->schema_ref = LUA_NOREF;
    strcpy(u->pk, su->pk);
    luaL_setmetatable(L, LUA_XRECORD_META);

    lua_pushvalue(L, schema_idx);
    u->schema_ref = luaL_ref(L, LUA_REGISTRYINDEX);
    return 1;   /* pool userdata is on top */
}

/* xrecord.schema({ {name=,type=}, ... }[, pk]) -> schema
** Build the shared layout once (e.g. at thread init). pk names the primary-key
** column (default "id") and must not also be a field. */
static int l_xrecord_schema(lua_State *L) {
    const char *pk = luaL_optstring(L, 2, "id");
    if (!pk[0] || strlen(pk) > XRECORD_MAX_NAME_LEN)
        return luaL_error(L, "xrecord.schema: invalid primary key name");
    xrecord_schema_t *sc = build_schema(L, 1, pk);
    push_schema_ud(L, sc, pk);
    return 1;
}

/* schema:new(capacity) -> handle -- one per player, all sharing this schema */
static int l_schema_new(lua_State *L) {
    check_schema(L, 1);
    lua_Integer capacity = luaL_checkinteger(L, 2);
    return make_pool(L, 1, capacity);
}

/* xrecord.create({ {name=,type=}, ... }, capacity[, pk]) -> handle
** One-off convenience: builds a private schema and a pool over it in one call
** (the pool pins the schema, so it lives as long as the pool). */
static int l_xrecord_create(lua_State *L) {
    lua_Integer capacity = luaL_checkinteger(L, 2);
    const char *pk = luaL_optstring(L, 3, "id");
    if (!pk[0] || strlen(pk) > XRECORD_MAX_NAME_LEN)
        return luaL_error(L, "xrecord.create: invalid primary key name");
    xrecord_schema_t *sc = build_schema(L, 1, pk);
    push_schema_ud(L, sc, pk);
    return make_pool(L, lua_gettop(L), capacity);
}

static int l_schema_gc(lua_State *L) {
    LuaSchema *u = check_schema(L, 1);
    if (u->sc) { xrecord_schema_destroy(u->sc); u->sc = NULL; }
    return 0;
}

/* Free the pool and release the registry ref pinning its schema userdata (so a
** schema shared by no other live pool can then be collected). Idempotent. */
static void record_release(lua_State *L, LuaRecord *u) {
    if (u->s) { xrecord_pool_destroy(u->s); u->s = NULL; }
    if (u->schema_ref != LUA_NOREF) {
        luaL_unref(L, LUA_REGISTRYINDEX, u->schema_ref);
        u->schema_ref = LUA_NOREF;
    }
}

static int l_record_gc(lua_State *L) {
    record_release(L, check_record(L, 1));
    return 0;
}

/* handle:create(id) | create({ [pk] = id, field = value, ... }) -> true
**
** Reserve a record. Given an integer, just bind that id (fields zeroed). Given
** a table, read the id from its pk column, bind it, and set the other fields.
** Idempotent (upsert): an already-present id is fine -- create-with-a-table on
** an existing record updates its fields, folding in a bulk "set these fields".
** A bad field value raises a Lua error naming the field. */
static int l_record_create(lua_State *L) {
    LuaRecord *u = check_record(L, 1);
    int t = lua_type(L, 2);

    if (t == LUA_TNUMBER) {
        int64_t id = (int64_t)lua_tointeger(L, 2);
        xrecord_status st = xrecord_bind(u->s, id);
        if (st != XRECORD_OK && st != XRECORD_EXISTS)
            return luaL_error(L, "xrecord.create: %s", status_msg(st));
        lua_pushboolean(L, 1);
        return 1;
    }

    if (t == LUA_TTABLE) {
        lua_getfield(L, 2, u->pk);
        if (!lua_isnumber(L, -1))
            return luaL_error(L, "xrecord.create: record has no numeric '%s'", u->pk);
        int64_t id = (int64_t)lua_tointeger(L, -1);
        lua_pop(L, 1);

        xrecord_status st = xrecord_bind(u->s, id);
        if (st != XRECORD_OK && st != XRECORD_EXISTS)
            return luaL_error(L, "xrecord.create: %s", status_msg(st));

        char bad_field[XRECORD_MAX_NAME_LEN + 1] = { 0 };
        xrecord_status fst = apply_fields(L, u->s, id, 2, u->pk, bad_field, sizeof(bad_field));
        if (fst != XRECORD_OK)
            return luaL_error(L, "xrecord.create: field '%s': %s", bad_field, status_msg(fst));
        lua_pushboolean(L, 1);
        return 1;
    }

    return luaL_error(L, "xrecord.create: expected an integer id or a record table, got %s",
                      luaL_typename(L, 2));
}

/* handle:destroy(id) -> true | false, "id not bound" */
static int l_record_destroy(lua_State *L) {
    LuaRecord *u = check_record(L, 1);
    lua_Integer id = luaL_checkinteger(L, 2);
    xrecord_status st = xrecord_unbind(u->s, (int64_t)id);
    if (st == XRECORD_OK) { lua_pushboolean(L, 1); return 1; }
    if (st == XRECORD_NOTFOUND) {
        lua_pushboolean(L, 0);
        lua_pushstring(L, status_msg(st));
        return 2;
    }
    return luaL_error(L, "xrecord.destroy: %s", status_msg(st));
}

/* handle:has(id) -> boolean */
static int l_record_has(lua_State *L) {
    LuaRecord *u = check_record(L, 1);
    lua_Integer id = luaL_checkinteger(L, 2);
    lua_pushboolean(L, xrecord_has(u->s, (int64_t)id));
    return 1;
}

/* handle:set(id, field, value) -> true | false, "id not bound" */
static int l_record_set(lua_State *L) {
    LuaRecord *u = check_record(L, 1);
    lua_Integer id = luaL_checkinteger(L, 2);
    const char *field = luaL_checkstring(L, 3);
    luaL_checkany(L, 4);

    xrecord_value val;
    if (!to_value(L, 4, &val))
        return luaL_error(L, "xrecord.set: unsupported value type '%s'", luaL_typename(L, 4));

    xrecord_status st = xrecord_set(u->s, (int64_t)id, field, &val);
    if (st == XRECORD_OK) { lua_pushboolean(L, 1); return 1; }
    if (st == XRECORD_NOTFOUND) {
        lua_pushboolean(L, 0);
        lua_pushstring(L, status_msg(st));
        return 2;
    }
    return luaL_error(L, "xrecord.set: %s", status_msg(st));
}

/* handle:get(id, field, ...) -> value, ... | nil, "id not bound"
**
** Accepts one or MORE field names and returns one value per field, in order.
** The multi-field form amortizes the Lua->C call overhead (the dominant cost
** of a single get) across N fields -- reading 3 fields in one call is ~2x
** faster than 3 calls. The id->slot hash probe also runs once thanks to the
** pool's 1-entry slot cache. An unbound id returns nil, "id not bound" (id
** boundness cannot change mid-call, so this is always detected on the first
** field); an unknown field name raises. */
static int l_record_get(lua_State *L) {
    LuaRecord *u = check_record(L, 1);
    lua_Integer id = luaL_checkinteger(L, 2);
    int top = lua_gettop(L);
    if (top < 3)
        return luaL_error(L, "xrecord.get: at least one field name required");
    int nreq = top - 2;
    luaL_checkstack(L, nreq + 2, "xrecord.get");

    for (int a = 3; a <= top; a++) {
        const char *field = luaL_checkstring(L, a);
        xrecord_value val;
        xrecord_status st = xrecord_get(u->s, (int64_t)id, field, &val);
        if (st == XRECORD_OK) { push_value(L, &val); continue; }
        if (st == XRECORD_NOTFOUND) {
            lua_pushnil(L);
            lua_pushstring(L, status_msg(st));
            return 2;
        }
        return luaL_error(L, "xrecord.get: field '%s': %s", field, status_msg(st));
    }
    return nreq;
}

/* handle:load_all({ { [pk] = id, field = value, ... }, ... }) -> true
**
** Bulk create (login path). Each element carries its id in the pk column;
** create (upsert) it, then set the other fields. Meant for a trusted source
** (your own DB), so bad data raises a Lua error naming the record/field. */
static int l_record_load_all(lua_State *L) {
    LuaRecord *u = check_record(L, 1);
    luaL_checktype(L, 2, LUA_TTABLE);

    lua_Integer n = (lua_Integer)lua_rawlen(L, 2);
    for (lua_Integer i = 0; i < n; i++) {
        lua_rawgeti(L, 2, i + 1);
        int rec_idx = lua_gettop(L);
        if (!lua_istable(L, rec_idx))
            return luaL_error(L, "xrecord.load_all: record #%d is not a table", (int)(i + 1));

        lua_getfield(L, rec_idx, u->pk);
        if (!lua_isnumber(L, -1))
            return luaL_error(L, "xrecord.load_all: record #%d has no numeric '%s'",
                               (int)(i + 1), u->pk);
        lua_Integer id = lua_tointeger(L, -1);
        lua_pop(L, 1);

        xrecord_status st = xrecord_bind(u->s, (int64_t)id);
        if (st != XRECORD_OK && st != XRECORD_EXISTS)
            return luaL_error(L, "xrecord.load_all: record #%d (%s=%lld) create failed: %s",
                               (int)(i + 1), u->pk, (long long)id, status_msg(st));

        char bad_field[XRECORD_MAX_NAME_LEN + 1] = { 0 };
        xrecord_status fst = apply_fields(L, u->s, (int64_t)id, rec_idx, u->pk, bad_field, sizeof(bad_field));
        if (fst != XRECORD_OK)
            return luaL_error(L, "xrecord.load_all: record #%d (%s=%lld) field '%s': %s",
                               (int)(i + 1), u->pk, (long long)id, bad_field, status_msg(fst));

        lua_pop(L, 1); /* record table */
    }

    lua_pushboolean(L, 1);
    return 1;
}

/* Read a primary-key value at stack index `idx` as a full 64-bit id: a string
** is parsed with strtoll (no Lua-number precision loss for a large
** (player_id<<24|seq) id), a number falls back to lua_tointeger. Returns 0 on
** a type/parse failure. */
static int read_pk_id(lua_State *L, int idx, int64_t *out) {
    int t = lua_type(L, idx);
    if (t == LUA_TSTRING) {
        const char *s = lua_tostring(L, idx);
        errno = 0;
        char *end;
        long long v = strtoll(s, &end, 10);
        if (end == s) return 0;
        while (*end == ' ' || *end == '\t') end++;
        if (*end != '\0' || errno == ERANGE) return 0;
        *out = (int64_t)v;
        return 1;
    }
    if (t == LUA_TNUMBER) {
        *out = (int64_t)lua_tointeger(L, idx);
        return 1;
    }
    return 0;
}

/* handle:load_rows(fields, values) -> true
**
** Columnar login fast path for a text-protocol DB result (e.g. xmysql's
** `result.fields` + `result.values`). `fields` is the array of column names;
** `values` an array of positional rows, each a `{ cell, cell, ... }` array of
** string cells (nil for SQL NULL). Locates the pk column by name, parses each
** row's id in C (full 64-bit), creates the record, and types every other cell
** by its schema field's type via xrecord_set_str -- no keyed Lua table is
** built and DB strings are coerced to numbers without a hand-written pass.
** Columns not in the schema are ignored (a SELECT may carry extras). Bad data
** raises a Lua error naming the row/column. */
static int l_record_load_rows(lua_State *L) {
    LuaRecord *u = check_record(L, 1);
    luaL_checktype(L, 2, LUA_TTABLE);   /* fields (column names)  */
    luaL_checktype(L, 3, LUA_TTABLE);   /* values (positional rows) */

    int ncols = (int)lua_rawlen(L, 2);
    if (ncols <= 0)
        return luaL_error(L, "xrecord.load_rows: empty fields list");

    /* Locate the pk column index by name. */
    int pk_col = 0;
    for (int j = 1; j <= ncols; j++) {
        lua_rawgeti(L, 2, j);
        const char *cn = lua_tostring(L, -1);
        int match = (cn && strcmp(cn, u->pk) == 0);
        lua_pop(L, 1);
        if (match) { pk_col = j; break; }
    }
    if (!pk_col)
        return luaL_error(L, "xrecord.load_rows: primary key column '%s' not found in fields", u->pk);

    int nrows = (int)lua_rawlen(L, 3);
    for (int r = 1; r <= nrows; r++) {
        lua_rawgeti(L, 3, r);
        int row_idx = lua_gettop(L);
        if (!lua_istable(L, row_idx))
            return luaL_error(L, "xrecord.load_rows: row #%d is not a table", r);

        lua_rawgeti(L, row_idx, pk_col);
        int64_t id;
        if (!read_pk_id(L, -1, &id))
            return luaL_error(L, "xrecord.load_rows: row #%d has no valid '%s' value", r, u->pk);
        lua_pop(L, 1);

        xrecord_status st = xrecord_bind(u->s, id);
        if (st != XRECORD_OK && st != XRECORD_EXISTS)
            return luaL_error(L, "xrecord.load_rows: row #%d (%s=%lld) create failed: %s",
                               r, u->pk, (long long)id, status_msg(st));

        for (int j = 1; j <= ncols; j++) {
            if (j == pk_col) continue;
            lua_rawgeti(L, 2, j);            /* column name (borrowed) */
            const char *fname = lua_tostring(L, -1);
            lua_rawgeti(L, row_idx, j);      /* cell value */
            int ct = lua_type(L, -1);

            xrecord_status fst = XRECORD_OK;
            if (ct == LUA_TNIL) {
                /* SQL NULL -> leave the field at its create()-zeroed default */
            } else if (ct == LUA_TSTRING) {
                size_t clen;
                const char *cstr = lua_tolstring(L, -1, &clen);
                fst = xrecord_set_str(u->s, id, fname, cstr, clen);
            } else {
                xrecord_value val;
                if (!to_value(L, -1, &val)) fst = XRECORD_TYPE_MISMATCH;
                else                        fst = xrecord_set(u->s, id, fname, &val);
            }
            if (fst == XRECORD_NOFIELD) fst = XRECORD_OK;   /* column not in schema -> ignore */

            char col[XRECORD_MAX_NAME_LEN + 1] = { 0 };
            if (fst != XRECORD_OK && fname) {
                strncpy(col, fname, sizeof(col) - 1);
            }
            lua_pop(L, 2);   /* cell value, column name */
            if (fst != XRECORD_OK)
                return luaL_error(L, "xrecord.load_rows: row #%d column '%s': %s",
                                   r, col, status_msg(fst));
        }

        lua_pop(L, 1);   /* row table */
    }

    lua_pushboolean(L, 1);
    return 1;
}

/* Shared state for the whole-pool save: build a record table per visited id
** and append it to the result array at result_idx. */
typedef struct {
    lua_State  *L;
    xrecord_t  *s;
    const char *pk;
    int         result_idx;
    lua_Integer n;
} save_ctx;

static bool save_visit(int64_t id, void *ctx_) {
    save_ctx *c = (save_ctx *)ctx_;
    push_record_table(c->L, c->s, id, c->pk);
    lua_rawseti(c->L, c->result_idx, ++c->n);
    return true;
}

/* handle:save_all()             -> { { [pk] = id, field = value, ... }, ... }  (whole pool)
** handle:save_all({ id1, ... })  -> same, only the listed bound ids
**
** Logout / save counterpart to load_all: serialize records into Lua tables
** ready for cmsgpack/json + a DB write. Each element carries its id in the pk
** column, so the array round-trips -- load_all(save_all()) is an identity. No
** argument saves the whole pool (the natural per-player logout); an id array
** saves just that subset (e.g. dirty records), skipping ids not bound. */
static int l_record_save_all(lua_State *L) {
    LuaRecord *u = check_record(L, 1);

    if (lua_isnoneornil(L, 2)) {
        lua_createtable(L, (int)xrecord_count(u->s), 0);
        save_ctx ctx = { L, u->s, u->pk, lua_gettop(L), 0 };
        xrecord_foreach(u->s, save_visit, &ctx);
        return 1;
    }

    luaL_checktype(L, 2, LUA_TTABLE);
    lua_Integer n = (lua_Integer)lua_rawlen(L, 2);
    lua_createtable(L, (int)n, 0);   /* result array */
    int result_idx = lua_gettop(L);

    lua_Integer out = 0;
    for (lua_Integer i = 0; i < n; i++) {
        lua_rawgeti(L, 2, i + 1);
        if (!lua_isnumber(L, -1))
            return luaL_error(L, "xrecord.save_all: id list entry #%d is not a number", (int)(i + 1));
        int64_t id = (int64_t)lua_tointeger(L, -1);
        lua_pop(L, 1);

        if (!xrecord_has(u->s, id)) continue;   /* nothing to serialize */
        push_record_table(L, u->s, id, u->pk);
        lua_rawseti(L, result_idx, ++out);
    }
    return 1;   /* result array is already on top */
}

/* handle:close() -- free the pool's C memory now instead of waiting for GC.
** With one pool per player this is the logout teardown: drop the whole pool in
** one call. Idempotent; a closed handle behaves as an empty pool. */
static int l_record_close(lua_State *L) {
    record_release(L, check_record(L, 1));
    return 0;
}

static const luaL_Reg k_record_methods[] = {
    { "create",   l_record_create   },
    { "destroy",  l_record_destroy  },
    { "has",      l_record_has      },
    { "set",      l_record_set      },
    { "get",      l_record_get      },
    { "load_all",  l_record_load_all  },
    { "load_rows", l_record_load_rows },
    { "save_all",  l_record_save_all  },
    { "close",     l_record_close     },
    { NULL, NULL }
};

static const luaL_Reg k_schema_methods[] = {
    { "new", l_schema_new },
    { NULL, NULL }
};

static const luaL_Reg k_xrecord_funcs[] = {
    { "schema", l_xrecord_schema },
    { "create", l_xrecord_create },
    { NULL, NULL }
};

LUALIB_API int luaopen_xrecord(lua_State *L) {
    luaL_newmetatable(L, LUA_XRECORD_META);
    lua_pushvalue(L, -1);
    lua_setfield(L, -2, "__index");
    luaL_setfuncs(L, k_record_methods, 0);
    lua_pushcfunction(L, l_record_gc);
    lua_setfield(L, -2, "__gc");
    lua_pop(L, 1);

    luaL_newmetatable(L, LUA_XRECORD_SCHEMA_META);
    lua_pushvalue(L, -1);
    lua_setfield(L, -2, "__index");
    luaL_setfuncs(L, k_schema_methods, 0);
    lua_pushcfunction(L, l_schema_gc);
    lua_setfield(L, -2, "__gc");
    lua_pop(L, 1);

    luaL_newlib(L, k_xrecord_funcs);
    return 1;
}
