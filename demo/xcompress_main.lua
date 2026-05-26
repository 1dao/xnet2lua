-- demo/xcompress_main.lua -- smoke test for the xcompress Lua module.
--
-- Covers:
--   * handle compressor: round-trip on each of {gzip, deflate, zlib} formats
--     at a couple of levels, variadic input, set_level lazy re-alloc
--   * one-shot compress/decompress wrappers
--   * crc32 / adler32 known vectors + multi-part equivalence
--
-- Run with:  ./bin/xnet demo/xcompress_main.lua

local fails = 0
local function check(cond, msg)
    if cond then
        print('PASS: ' .. msg)
    else
        fails = fails + 1
        io.stderr:write('FAIL: ' .. msg .. '\n')
    end
end

local function __init()
    print('[xcompress] init')

    -- ---- Round-trip on the handle ----
    local c = xcompress.new_compressor()
    check(c:level() == 6, 'default level is 6')

    local d = xcompress.new_decompressor()

    local plain = string.rep('the quick brown fox jumps over the lazy dog. ', 64)

    for _, fmt in ipairs({ 'gzip', 'deflate', 'zlib' }) do
        local ct = c[fmt](c, plain)
        check(ct ~= nil and #ct > 0 and #ct < #plain,
              fmt .. ': compressed (' .. #plain .. ' -> ' .. #ct .. ')')
        local pt, err = d[fmt](d, ct, #plain)
        check(pt == plain, fmt .. ': round-trip equals original')
    end

    -- ---- Variadic input matches concatenation ----
    local a, b, c_part = 'hello, ', 'gzip ', 'world!'
    local single = c:gzip(a .. b .. c_part)
    local varia  = c:gzip(a, b, c_part)
    -- gzip output isn't byte-deterministic across all libdeflate versions, but
    -- equal input -> equal output within a single binary, so the bytes do match.
    check(single == varia, 'variadic gzip(a,b,c) == gzip(a..b..c)')

    -- ---- set_level swaps the underlying compressor ----
    c:set_level(1)
    check(c:level() == 1, 'set_level(1) recorded')
    local fast = c:gzip(plain)
    c:set_level(12)
    local slow = c:gzip(plain)
    check(#slow <= #fast, 'level 12 not larger than level 1')

    -- ---- One-shot wrappers ----
    local g = xcompress.gzip(plain)
    local u = xcompress.gunzip(g, #plain)
    check(u == plain, 'one-shot gzip / gunzip round-trip')

    local raw = xcompress.deflate(plain, 9)
    local inflated = xcompress.inflate(raw, #plain)
    check(inflated == plain, 'one-shot deflate / inflate round-trip')

    local z = xcompress.zlib_compress(plain)
    local uz = xcompress.zlib_decompress(z, #plain)
    check(uz == plain, 'one-shot zlib round-trip')

    -- ---- Decompression error path ----
    local bad, err = d:gzip('not a gzip stream', 1024)
    check(bad == nil and err == 'bad_data', 'bad gzip data returns nil, "bad_data"')

    local short, err2 = d:gzip(g, 8)
    check(short == nil and err2 == 'insufficient_space',
          'too-small max_out returns nil, "insufficient_space"')

    -- ---- Checksums: known vectors ----
    -- CRC-32 of "123456789" = 0xcbf43926 (well-known IEEE 802.3 vector)
    check(xcompress.crc32('123456789') == 0xcbf43926,
          'crc32("123456789") = 0xcbf43926')
    -- Adler-32 of "Wikipedia" = 0x11e60398
    check(xcompress.adler32('Wikipedia') == 0x11e60398,
          'adler32("Wikipedia") = 0x11e60398')
    -- Adler-32 of "" = 1 (initial)
    check(xcompress.adler32('') == 1, 'adler32("") = 1')
    -- CRC-32 of "" = 0
    check(xcompress.crc32('') == 0, 'crc32("") = 0')

    -- ---- Multi-part checksum equals single-part ----
    local one = xcompress.crc32('123456789')
    local two = xcompress.crc32('12345', '6789')
    check(one == two, 'crc32 variadic equals concatenated')
    local r = xcompress.crc32_update(0, '12345')
    r = xcompress.crc32_update(r, '6789')
    check(r == one, 'crc32_update chain equals single call')

    c:close()
    d:close()

    print(string.format('\n--- xcompress smoke: %d failures ---', fails))
    xthread.stop(fails > 0 and 1 or 0)
end

local function __uninit()
    print('[xcompress] uninit')
end

return { __init = __init, __uninit = __uninit }
