-- Unit specs for the utf8 library. Under the embedded Lua 5.5 this is the
-- native library; under LuaJIT it is the port in xlua/lua_xutils.c, so the
-- same expectations keep the two in step.
-- Run via: bin/xnet tests/lua/utf8_spec.lua

local spec = dofile('tests/lua/spec_helper.lua')

local function codes_of(s, lax)
    local out = {}
    for pos, cp in utf8.codes(s, lax) do out[#out + 1] = pos .. ':' .. cp end
    return table.concat(out, ' ')
end

spec.describe('utf8', function()
    spec.it('is registered as a global and a module', function()
        spec.equal(type(utf8), 'table')
        spec.equal(package.loaded.utf8, utf8)
        spec.equal(type(utf8.charpattern), 'string')   -- spelling differs by runtime
    end)

    spec.it('encodes code points with char', function()
        spec.equal(utf8.char(), '')
        spec.equal(utf8.char(72, 0x4F60, 0x1F600), 'H你😀')
        spec.equal(utf8.char(0x7F, 0x80, 0x7FF, 0x800, 0xFFFF, 0x10000, 0x10FFFF),
            '\x7F\xC2\x80\xDF\xBF\xE0\xA0\x80\xEF\xBF\xBF\xF0\x90\x80\x80\xF4\x8F\xBF\xBF')
        spec.equal(utf8.char(0x7FFFFFFF), '\xFD\xBF\xBF\xBF\xBF\xBF')
        spec.equal(pcall(utf8.char, -1), false)
        spec.equal(pcall(utf8.char, 0x80000000), false)
    end)

    spec.it('counts characters and reports the first invalid byte', function()
        spec.equal(utf8.len(''), 0)
        spec.equal(utf8.len('héllo你好'), 7)
        spec.equal(utf8.len('héllo你好', 4), 5)
        spec.equal(utf8.len('héllo你好', -6), 2)
        local n0, p0 = utf8.len('héllo', 3)             -- starts on a continuation byte
        spec.nil_value(n0)
        spec.equal(p0, 3)
        local n, pos = utf8.len('ab\xFFcd')
        spec.nil_value(n)
        spec.equal(pos, 3)
        n, pos = utf8.len('\xC0\x80')          -- overlong NUL
        spec.nil_value(n)
        spec.equal(pos, 1)
        spec.nil_value((utf8.len('\xED\xA0\x80')))        -- surrogate: strict rejects
        spec.equal(utf8.len('\xED\xA0\x80', 1, -1, true), 1)
        spec.equal(pcall(utf8.len, 'abc', 5), false)
    end)

    spec.it('decodes with codepoint', function()
        spec.equal(utf8.codepoint('A'), 65)
        spec.equal(select('#', utf8.codepoint('héllo', 1, -1)), 5)
        local a, b, c = utf8.codepoint('a你b', 1, -1)
        spec.equal(a, 97); spec.equal(b, 0x4F60); spec.equal(c, 98)
        spec.equal(select('#', utf8.codepoint('abc', 3, 2)), 0)
        spec.equal(pcall(utf8.codepoint, '\xFF'), false)
    end)

    spec.it('maps character offsets to byte positions', function()
        local s = 'a你b好'
        spec.equal(utf8.offset(s, 1), 1)
        spec.equal(utf8.offset(s, 2), 2)
        spec.equal(utf8.offset(s, 3), 5)
        spec.equal(utf8.offset(s, 5), #s + 1)
        spec.nil_value(utf8.offset(s, 6))
        spec.equal(utf8.offset(s, -1), 6)
        spec.equal(utf8.offset(s, -2), 5)
        spec.equal(utf8.offset(s, 0, 3), 2)       -- start of the char holding byte 3
        spec.equal(utf8.offset(s, 2, 2), 5)
        spec.equal(pcall(utf8.offset, s, 1, 3), false)   -- continuation byte
    end)

    spec.it('iterates with codes', function()
        spec.equal(codes_of(''), '')
        spec.equal(codes_of('a你b'), '1:97 2:20320 5:98')
        spec.equal(pcall(codes_of, 'a\xFFb'), false)
        spec.equal(pcall(codes_of, '\x80'), false)
        spec.equal(pcall(codes_of, '\xED\xA0\x80'), false)
        spec.equal(codes_of('\xED\xA0\x80', true), '1:55296')
    end)

    spec.it('matches whole characters with charpattern', function()
        local parts = {}
        for ch in ('a\0你😀'):gmatch(utf8.charpattern) do parts[#parts + 1] = #ch end
        spec.equal(table.concat(parts, ','), '1,1,3,4')
    end)
end)

local failures = spec.finish()

return {
    __init = function()
        if failures > 0 then os.exit(1) end
        xthread.stop(0)
    end,
}
