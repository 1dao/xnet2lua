/* lua_xcompress.c -- Lua bindings for libdeflate (gzip / raw deflate / zlib
**                    compression + CRC-32 / Adler-32 checksums).
**
** API surface (see also the docs in xcompress.lua-style comments below):
**
**   -- handle-based (preferred for repeated use; level held on the handle)
**   local c = xcompress.new_compressor()           -- default level 6
**   c:set_level(n)         -- 0..12 or -1 (=default)
**   c:level()              -- current level
**   c:gzip(p1, p2, ...)    -- variadic strings, concatenated then compressed
**   c:deflate(p1, ...)
**   c:zlib(p1, ...)
**   c:close()
**
**   local d = xcompress.new_decompressor()
**   d:gzip(data, max_out)  -- returns bytes | nil, err
**   d:deflate(data, max_out)
**   d:zlib(data, max_out)
**   d:close()
**
**   -- one-shot (allocates compressor internally; avoid in hot loops)
**   xcompress.gzip(data, [level])
**   xcompress.gunzip(data, max_out)
**   xcompress.deflate(data, [level])
**   xcompress.inflate(data, max_out)
**   xcompress.zlib_compress(data, [level])
**   xcompress.zlib_decompress(data, max_out)
**
**   -- checksums (variadic; no state)
**   xcompress.crc32(p1, p2, ...)             -- starts from 0
**   xcompress.crc32_update(running, p1, ...) -- continues
**   xcompress.adler32(p1, p2, ...)           -- starts from 1
**   xcompress.adler32_update(running, p1, ...)
**
** A single compressor / decompressor handle is NOT safe to use from multiple
** threads concurrently. Since xnet runs one Lua state per OS thread, this is
** naturally satisfied; just don't smuggle handles across threads. */

#include <stdlib.h>
#include <string.h>
#include <stdint.h>

#if defined(LUA_EMBEDDED)
#include "../3rd/minilua.h"
#else
#include "lua.h"
#include "lauxlib.h"
#endif

#include "libdeflate.h"

#define LUA_XCOMPRESS_COMPRESSOR_META   "xcompress.compressor"
#define LUA_XCOMPRESS_DECOMPRESSOR_META "xcompress.decompressor"

#define DEFAULT_LEVEL 6

typedef struct {
    struct libdeflate_compressor* c;
    int level;
    int closed;
} LuaCompressor;

typedef struct {
    struct libdeflate_decompressor* d;
    int closed;
} LuaDecompressor;

enum xc_format {
    XC_GZIP = 0,
    XC_DEFLATE,
    XC_ZLIB,
};

/* -------------------------------------------------------------------------
** Helpers
** ------------------------------------------------------------------------- */

static LuaCompressor* check_comp(lua_State* L, int idx) {
    return (LuaCompressor*)luaL_checkudata(L, idx, LUA_XCOMPRESS_COMPRESSOR_META);
}

static LuaDecompressor* check_dec(lua_State* L, int idx) {
    return (LuaDecompressor*)luaL_checkudata(L, idx, LUA_XCOMPRESS_DECOMPRESSOR_META);
}

/* Ensure the underlying libdeflate compressor matches lc->level. Allocates
** lazily and re-allocates if the level changed. Raises on alloc failure. */
static struct libdeflate_compressor* ensure_compressor(lua_State* L, LuaCompressor* lc) {
    if (lc->closed)
        luaL_error(L, "xcompress: compressor is closed");
    if (lc->c) return lc->c;
    lc->c = libdeflate_alloc_compressor(lc->level);
    if (!lc->c) luaL_error(L, "xcompress: libdeflate_alloc_compressor(level=%d) failed", lc->level);
    return lc->c;
}

/* Validate that args [start..top] are all strings and compute total length.
** Returns total byte count; raises on type / overflow errors. */
static size_t parts_total_length(lua_State* L, int start) {
    int top = lua_gettop(L);
    size_t total = 0;
    for (int i = start; i <= top; i++) {
        size_t len = 0;
        luaL_checklstring(L, i, &len);
        if (len > SIZE_MAX - total)
            luaL_error(L, "xcompress: combined input too large");
        total += len;
    }
    return total;
}

/* Concatenate args [start..top] into a freshly malloc'd buffer. Returns NULL
** with *out_len = 0 when total length is 0 (caller must handle that). Caller
** owns the returned pointer (free with free()).
** If only one string part is supplied and it's non-empty, skip the copy and
** return its Lua-owned pointer with *borrowed = 1 so the caller doesn't free. */
static char* collect_parts(lua_State* L, int start, size_t* out_len, int* borrowed) {
    *borrowed = 0;
    size_t total = parts_total_length(L, start);
    *out_len = total;
    if (total == 0) return NULL;

    int top = lua_gettop(L);
    if (top == start) {
        /* Single non-empty part -- give back the Lua string pointer directly. */
        size_t len = 0;
        const char* s = lua_tolstring(L, start, &len);
        *borrowed = 1;
        return (char*)s;
    }

    char* buf = (char*)malloc(total);
    if (!buf) luaL_error(L, "xcompress: out of memory (%zu bytes)", total);

    size_t off = 0;
    for (int i = start; i <= top; i++) {
        size_t len = 0;
        const char* s = lua_tolstring(L, i, &len);
        if (len > 0) {
            memcpy(buf + off, s, len);
            off += len;
        }
    }
    return buf;
}

static const char* decompress_err_str(enum libdeflate_result r) {
    switch (r) {
    case LIBDEFLATE_SUCCESS:            return "success";
    case LIBDEFLATE_BAD_DATA:           return "bad_data";
    case LIBDEFLATE_SHORT_OUTPUT:       return "short_output";
    case LIBDEFLATE_INSUFFICIENT_SPACE: return "insufficient_space";
    default:                            return "unknown_error";
    }
}

/* -------------------------------------------------------------------------
** Compression (handle methods + one-shot)
** ------------------------------------------------------------------------- */

static int compress_into_lua(lua_State* L,
                              struct libdeflate_compressor* c,
                              enum xc_format f,
                              const char* in, size_t in_len) {
    size_t bound;
    switch (f) {
    case XC_GZIP:    bound = libdeflate_gzip_compress_bound(c, in_len);    break;
    case XC_DEFLATE: bound = libdeflate_deflate_compress_bound(c, in_len); break;
    case XC_ZLIB:    bound = libdeflate_zlib_compress_bound(c, in_len);    break;
    default:         return luaL_error(L, "xcompress: bad format");
    }

    char* out = (char*)malloc(bound);
    if (!out) return luaL_error(L, "xcompress: out of memory (bound=%zu)", bound);

    size_t out_len;
    switch (f) {
    case XC_GZIP:    out_len = libdeflate_gzip_compress(c, in, in_len, out, bound);    break;
    case XC_DEFLATE: out_len = libdeflate_deflate_compress(c, in, in_len, out, bound); break;
    case XC_ZLIB:    out_len = libdeflate_zlib_compress(c, in, in_len, out, bound);    break;
    default: free(out); return luaL_error(L, "xcompress: bad format");
    }

    if (out_len == 0) {
        free(out);
        return luaL_error(L, "xcompress: compression failed (bound=%zu undersized?)", bound);
    }

    lua_pushlstring(L, out, out_len);
    free(out);
    return 1;
}

static int compress_handle_variant(lua_State* L, enum xc_format f) {
    LuaCompressor* lc = check_comp(L, 1);
    struct libdeflate_compressor* c = ensure_compressor(L, lc);

    int borrowed;
    size_t in_len;
    char* in = collect_parts(L, 2, &in_len, &borrowed);

    int rc = compress_into_lua(L, c, f, in ? in : "", in_len);
    if (!borrowed) free(in);
    return rc;
}

static int l_comp_gzip(lua_State* L)    { return compress_handle_variant(L, XC_GZIP); }
static int l_comp_deflate(lua_State* L) { return compress_handle_variant(L, XC_DEFLATE); }
static int l_comp_zlib(lua_State* L)    { return compress_handle_variant(L, XC_ZLIB); }

/* One-shot: alloc compressor inline, compress, free. Single string input. */
static int compress_oneshot(lua_State* L, enum xc_format f) {
    size_t in_len;
    const char* in = luaL_checklstring(L, 1, &in_len);
    int level = (int)luaL_optinteger(L, 2, DEFAULT_LEVEL);
    if (level == -1) level = DEFAULT_LEVEL;
    struct libdeflate_compressor* c = libdeflate_alloc_compressor(level);
    if (!c) return luaL_error(L, "xcompress: alloc_compressor(level=%d) failed", level);
    int rc = compress_into_lua(L, c, f, in, in_len);
    libdeflate_free_compressor(c);
    return rc;
}

static int l_gzip_oneshot(lua_State* L)          { return compress_oneshot(L, XC_GZIP); }
static int l_deflate_oneshot(lua_State* L)       { return compress_oneshot(L, XC_DEFLATE); }
static int l_zlib_compress_oneshot(lua_State* L) { return compress_oneshot(L, XC_ZLIB); }

/* -------------------------------------------------------------------------
** Decompression
** ------------------------------------------------------------------------- */

static int decompress_into_lua(lua_State* L,
                                struct libdeflate_decompressor* d,
                                enum xc_format f,
                                const char* in, size_t in_len,
                                size_t max_out) {
    char* out = (char*)malloc(max_out > 0 ? max_out : 1);
    if (!out) return luaL_error(L, "xcompress: out of memory (max_out=%zu)", max_out);

    size_t actual = 0;
    enum libdeflate_result rc;
    switch (f) {
    case XC_GZIP:
        rc = libdeflate_gzip_decompress(d, in, in_len, out, max_out, &actual);
        break;
    case XC_DEFLATE:
        rc = libdeflate_deflate_decompress(d, in, in_len, out, max_out, &actual);
        break;
    case XC_ZLIB:
        rc = libdeflate_zlib_decompress(d, in, in_len, out, max_out, &actual);
        break;
    default:
        free(out);
        return luaL_error(L, "xcompress: bad format");
    }

    if (rc != LIBDEFLATE_SUCCESS) {
        free(out);
        lua_pushnil(L);
        lua_pushstring(L, decompress_err_str(rc));
        return 2;
    }

    lua_pushlstring(L, out, actual);
    free(out);
    return 1;
}

static int decompress_handle_variant(lua_State* L, enum xc_format f) {
    LuaDecompressor* ld = check_dec(L, 1);
    if (ld->closed) return luaL_error(L, "xcompress: decompressor is closed");
    if (!ld->d) {
        ld->d = libdeflate_alloc_decompressor();
        if (!ld->d) return luaL_error(L, "xcompress: alloc_decompressor failed");
    }
    size_t in_len;
    const char* in = luaL_checklstring(L, 2, &in_len);
    lua_Integer max_out = luaL_checkinteger(L, 3);
    if (max_out <= 0) return luaL_error(L, "xcompress: max_out must be > 0");
    return decompress_into_lua(L, ld->d, f, in, in_len, (size_t)max_out);
}

static int l_dec_gzip(lua_State* L)    { return decompress_handle_variant(L, XC_GZIP); }
static int l_dec_deflate(lua_State* L) { return decompress_handle_variant(L, XC_DEFLATE); }
static int l_dec_zlib(lua_State* L)    { return decompress_handle_variant(L, XC_ZLIB); }

static int decompress_oneshot(lua_State* L, enum xc_format f) {
    size_t in_len;
    const char* in = luaL_checklstring(L, 1, &in_len);
    lua_Integer max_out = luaL_checkinteger(L, 2);
    if (max_out <= 0) return luaL_error(L, "xcompress: max_out must be > 0");
    struct libdeflate_decompressor* d = libdeflate_alloc_decompressor();
    if (!d) return luaL_error(L, "xcompress: alloc_decompressor failed");
    int rc = decompress_into_lua(L, d, f, in, in_len, (size_t)max_out);
    libdeflate_free_decompressor(d);
    return rc;
}

static int l_gunzip_oneshot(lua_State* L)          { return decompress_oneshot(L, XC_GZIP); }
static int l_inflate_oneshot(lua_State* L)         { return decompress_oneshot(L, XC_DEFLATE); }
static int l_zlib_decompress_oneshot(lua_State* L) { return decompress_oneshot(L, XC_ZLIB); }

/* -------------------------------------------------------------------------
** Compressor / decompressor lifecycle
** ------------------------------------------------------------------------- */

static int l_new_compressor(lua_State* L) {
    int level = (int)luaL_optinteger(L, 1, DEFAULT_LEVEL);
    if (level == -1) level = DEFAULT_LEVEL;
    if (level < 0 || level > 12)
        return luaL_error(L, "xcompress: level must be in [0,12] or -1 (got %d)", level);

    LuaCompressor* lc = (LuaCompressor*)lua_newuserdata(L, sizeof(*lc));
    lc->c = NULL;            /* lazy alloc on first compress */
    lc->level = level;
    lc->closed = 0;
    luaL_setmetatable(L, LUA_XCOMPRESS_COMPRESSOR_META);
    return 1;
}

static int l_comp_set_level(lua_State* L) {
    LuaCompressor* lc = check_comp(L, 1);
    if (lc->closed) return luaL_error(L, "xcompress: compressor is closed");
    int level = (int)luaL_checkinteger(L, 2);
    if (level == -1) level = DEFAULT_LEVEL;
    if (level < 0 || level > 12)
        return luaL_error(L, "xcompress: level must be in [0,12] or -1 (got %d)", level);
    if (level != lc->level && lc->c) {
        libdeflate_free_compressor(lc->c);
        lc->c = NULL;        /* re-alloc lazily at next use */
    }
    lc->level = level;
    lua_pushvalue(L, 1);
    return 1;
}

static int l_comp_level(lua_State* L) {
    LuaCompressor* lc = check_comp(L, 1);
    lua_pushinteger(L, lc->level);
    return 1;
}

static int l_comp_close(lua_State* L) {
    LuaCompressor* lc = check_comp(L, 1);
    if (!lc->closed) {
        if (lc->c) { libdeflate_free_compressor(lc->c); lc->c = NULL; }
        lc->closed = 1;
    }
    return 0;
}

static int l_comp_gc(lua_State* L) {
    LuaCompressor* lc = (LuaCompressor*)luaL_checkudata(L, 1, LUA_XCOMPRESS_COMPRESSOR_META);
    if (lc && !lc->closed) {
        if (lc->c) { libdeflate_free_compressor(lc->c); lc->c = NULL; }
        lc->closed = 1;
    }
    return 0;
}

static int l_new_decompressor(lua_State* L) {
    LuaDecompressor* ld = (LuaDecompressor*)lua_newuserdata(L, sizeof(*ld));
    ld->d = NULL;            /* lazy alloc on first decompress */
    ld->closed = 0;
    luaL_setmetatable(L, LUA_XCOMPRESS_DECOMPRESSOR_META);
    return 1;
}

static int l_dec_close(lua_State* L) {
    LuaDecompressor* ld = check_dec(L, 1);
    if (!ld->closed) {
        if (ld->d) { libdeflate_free_decompressor(ld->d); ld->d = NULL; }
        ld->closed = 1;
    }
    return 0;
}

static int l_dec_gc(lua_State* L) {
    LuaDecompressor* ld = (LuaDecompressor*)luaL_checkudata(L, 1, LUA_XCOMPRESS_DECOMPRESSOR_META);
    if (ld && !ld->closed) {
        if (ld->d) { libdeflate_free_decompressor(ld->d); ld->d = NULL; }
        ld->closed = 1;
    }
    return 0;
}

/* -------------------------------------------------------------------------
** Checksums (CRC-32 / Adler-32) -- variadic, state-free
** ------------------------------------------------------------------------- */

static int l_crc32(lua_State* L) {
    int top = lua_gettop(L);
    uint32_t crc = 0;
    for (int i = 1; i <= top; i++) {
        size_t len = 0;
        const char* p = luaL_checklstring(L, i, &len);
        crc = libdeflate_crc32(crc, p, len);
    }
    lua_pushinteger(L, (lua_Integer)crc);
    return 1;
}

static int l_crc32_update(lua_State* L) {
    uint32_t crc = (uint32_t)luaL_checkinteger(L, 1);
    int top = lua_gettop(L);
    for (int i = 2; i <= top; i++) {
        size_t len = 0;
        const char* p = luaL_checklstring(L, i, &len);
        crc = libdeflate_crc32(crc, p, len);
    }
    lua_pushinteger(L, (lua_Integer)crc);
    return 1;
}

static int l_adler32(lua_State* L) {
    int top = lua_gettop(L);
    uint32_t adler = 1;
    for (int i = 1; i <= top; i++) {
        size_t len = 0;
        const char* p = luaL_checklstring(L, i, &len);
        adler = libdeflate_adler32(adler, p, len);
    }
    lua_pushinteger(L, (lua_Integer)adler);
    return 1;
}

static int l_adler32_update(lua_State* L) {
    uint32_t adler = (uint32_t)luaL_checkinteger(L, 1);
    int top = lua_gettop(L);
    for (int i = 2; i <= top; i++) {
        size_t len = 0;
        const char* p = luaL_checklstring(L, i, &len);
        adler = libdeflate_adler32(adler, p, len);
    }
    lua_pushinteger(L, (lua_Integer)adler);
    return 1;
}

/* -------------------------------------------------------------------------
** Registration
** ------------------------------------------------------------------------- */

static const luaL_Reg compressor_methods[] = {
    { "set_level", l_comp_set_level },
    { "level",     l_comp_level },
    { "gzip",      l_comp_gzip },
    { "deflate",   l_comp_deflate },
    { "zlib",      l_comp_zlib },
    { "close",     l_comp_close },
    { NULL, NULL }
};

static const luaL_Reg decompressor_methods[] = {
    { "gzip",    l_dec_gzip },
    { "deflate", l_dec_deflate },
    { "zlib",    l_dec_zlib },
    { "close",   l_dec_close },
    { NULL, NULL }
};

static const luaL_Reg xcompress_funcs[] = {
    { "new_compressor",   l_new_compressor },
    { "new_decompressor", l_new_decompressor },
    { "gzip",             l_gzip_oneshot },
    { "gunzip",           l_gunzip_oneshot },
    { "deflate",          l_deflate_oneshot },
    { "inflate",          l_inflate_oneshot },
    { "zlib_compress",    l_zlib_compress_oneshot },
    { "zlib_decompress",  l_zlib_decompress_oneshot },
    { "crc32",            l_crc32 },
    { "crc32_update",     l_crc32_update },
    { "adler32",          l_adler32 },
    { "adler32_update",   l_adler32_update },
    { NULL, NULL }
};

LUALIB_API int luaopen_xcompress(lua_State* L) {
    if (luaL_newmetatable(L, LUA_XCOMPRESS_COMPRESSOR_META)) {
        lua_pushcfunction(L, l_comp_gc);
        lua_setfield(L, -2, "__gc");
        lua_newtable(L);
        luaL_setfuncs(L, compressor_methods, 0);
        lua_setfield(L, -2, "__index");
    }
    lua_pop(L, 1);

    if (luaL_newmetatable(L, LUA_XCOMPRESS_DECOMPRESSOR_META)) {
        lua_pushcfunction(L, l_dec_gc);
        lua_setfield(L, -2, "__gc");
        lua_newtable(L);
        luaL_setfuncs(L, decompressor_methods, 0);
        lua_setfield(L, -2, "__index");
    }
    lua_pop(L, 1);

    luaL_newlib(L, xcompress_funcs);
    return 1;
}
