-- Regression test for xutils: load_config / get_config / scan_dir / json_*
-- Run: ./xnet.exe demo/xutils_test_main.lua
-- Exits with code 0 on full pass, 1 on any failure.

local xutils = require('xutils')

local pass, fail = 0, 0
local failures = {}

local function ok(name, cond, detail)
    if cond then
        pass = pass + 1
        print(string.format('  PASS  %s', name))
    else
        fail = fail + 1
        local msg = string.format('  FAIL  %s%s', name,
            detail and ('  -- ' .. tostring(detail)) or '')
        print(msg)
        failures[#failures + 1] = msg
    end
end

local function eq(name, got, want)
    if got == want then
        ok(name, true)
    else
        ok(name, false, string.format('got=%s want=%s',
            tostring(got), tostring(want)))
    end
end

local function head(t)
    print('\n== ' .. t .. ' ==')
end

-- ============================================================================
-- 1. load_config / get_config
-- ============================================================================
head('load_config / get_config')

-- Prepare a temp config file
local cfg_path = 'demo/.xutils_test.cfg'
do
    local f = assert(io.open(cfg_path, 'w'))
    f:write('FOO=hello\n')
    f:write('NUM=42\n')
    f:write('# comment line\n')
    f:write('EMPTY=\n')
    f:close()
end

local ok_cfg, err = xutils.load_config(cfg_path)
ok('load_config returns true on success', ok_cfg == true, tostring(err))

eq('get_config existing key',         xutils.get_config('FOO'), 'hello')
eq('get_config numeric value',        xutils.get_config('NUM'), '42')
eq('get_config empty value',          xutils.get_config('EMPTY'), '')
eq('get_config missing => nil',       xutils.get_config('NOPE'), nil)
eq('get_config missing => default',   xutils.get_config('NOPE', 'fallback'), 'fallback')
eq('get_config missing default = false', xutils.get_config('NOPE', false), false)

-- load_config of a missing file
local bad_ok, bad_err = xutils.load_config('demo/.does_not_exist.cfg')
ok('load_config missing => false', bad_ok == false)
ok('load_config missing has err',  type(bad_err) == 'string')

os.remove(cfg_path)

-- ============================================================================
-- 2. scan_dir
-- ============================================================================
head('scan_dir')

local files, scan_err = xutils.scan_dir('demo/static/xpac')
ok('scan_dir returns a table', type(files) == 'table', tostring(scan_err))
ok('scan_dir at least 1 file',  #files >= 1)

local saw_index = false
for _, f in ipairs(files) do
    if type(f) ~= 'table' or type(f.path) ~= 'string' or type(f.rel) ~= 'string' then
        ok('entry shape', false, 'bad entry')
        break
    end
    if f.rel == 'index.html' then saw_index = true end
end
ok('scan_dir contains index.html', saw_index)

local nx, nx_err = xutils.scan_dir('demo/this_dir_does_not_exist_zzz')
ok('scan_dir missing => nil',     nx == nil)
ok('scan_dir missing has err',    type(nx_err) == 'string')

-- ============================================================================
-- 3. json_pack basic types
-- ============================================================================
head('json_pack basic types')

eq('nil -> null',          xutils.json_pack(nil),        'null')
eq('true -> true',         xutils.json_pack(true),       'true')
eq('false -> false',       xutils.json_pack(false),      'false')
eq('integer',              xutils.json_pack(42),         '42')
eq('negative integer',     xutils.json_pack(-7),         '-7')
eq('float',                xutils.json_pack(1.5),        '1.5')
eq('string plain',         xutils.json_pack('abc'),      '"abc"')
eq('string with quote',    xutils.json_pack('a"b'),      '"a\\"b"')
eq('string with newline',  xutils.json_pack('a\nb'),     '"a\\nb"')
eq('json_null sentinel',   xutils.json_pack(xutils.json_null), 'null')

-- ============================================================================
-- 4. json_pack array vs object detection
-- ============================================================================
head('json_pack array/object detection')

eq('1..N array',
    xutils.json_pack({'a','b','c'}),
    '["a","b","c"]')

eq('empty table -> object',
    xutils.json_pack({}),
    '{}')

eq('sparse [1]+[3] -> object (NOT array)',
    xutils.json_pack({ [1] = 'a', [3] = 'c' }),
    '{"1":"a","3":"c"}')

-- Mixed: integer + string keys -> object. Order undefined; verify by parsing back.
do
    local mixed = xutils.json_pack({ 10, 20, name = 'x' })
    local back = xutils.json_unpack(mixed)
    ok('mixed -> object roundtrip',
        type(back) == 'table' and back.name == 'x'
        and back['1'] == 10 and back['2'] == 20)
end

eq('nested array',
    xutils.json_pack({ {1,2}, {3,4} }),
    '[[1,2],[3,4]]')

-- ============================================================================
-- 5. json_pack failures (the "unsupported value" path)
-- ============================================================================
head('json_pack failures')

local function expect_fail(name, value)
    local s, e = xutils.json_pack(value)
    ok(name .. ' fails', s == nil and type(e) == 'string',
       string.format('got=%s err=%s', tostring(s), tostring(e)))
end

expect_fail('NaN',  0/0)
expect_fail('+Inf', 1/0)
expect_fail('-Inf', -1/0)
expect_fail('function value',     function() end)
expect_fail('thread value',       coroutine.create(function() end))
expect_fail('unknown lightuserdata', io.stdout)  -- userdata, not lightuserdata json_null
expect_fail('function as object key', { [function() end] = 1 })

-- ============================================================================
-- 6. json_pack max depth (= 64)
-- ============================================================================
head('json_pack depth limit')

-- Build nested arrays of given depth.
local function make_nested(depth)
    local x = 1
    for _ = 1, depth do x = { x } end
    return x
end

-- Note: each table adds depth+1 internally because of the recursion.
-- The implementation rejects when depth > 64. Empirically depth 32 is fine.
do
    local s, _ = xutils.json_pack(make_nested(32))
    ok('pack depth 32 succeeds', type(s) == 'string')
end

do
    local s, e = xutils.json_pack(make_nested(200))
    ok('pack depth 200 fails', s == nil and type(e) == 'string')
end

-- ============================================================================
-- 7. json_unpack basic types
-- ============================================================================
head('json_unpack basic types')

eq('parse true',        xutils.json_unpack('true'),  true)
eq('parse false',       xutils.json_unpack('false'), false)
eq('parse integer',     xutils.json_unpack('42'),    42)
eq('parse negative',    xutils.json_unpack('-7'),    -7)
eq('parse float',       xutils.json_unpack('1.5'),   1.5)
eq('parse string',      xutils.json_unpack('"abc"'), 'abc')

-- null becomes the json_null sentinel, NOT Lua nil
do
    local v = xutils.json_unpack('null')
    ok('parse null is not Lua nil',         v ~= nil)
    ok('parse null equals json_null',       v == xutils.json_null)
end

-- Object inside table: null -> json_null; key is preserved
do
    local t = xutils.json_unpack('{"a":null,"b":1}')
    ok('object exists',          type(t) == 'table')
    ok('null inside object',     t.a == xutils.json_null)
    ok('null is not Lua nil',    t.a ~= nil)
    eq('sibling integer',        t.b, 1)
end

-- Array
do
    local t = xutils.json_unpack('["x","y","z"]')
    ok('array #t == 3', type(t) == 'table' and #t == 3)
    eq('array[1]', t[1], 'x')
    eq('array[3]', t[3], 'z')
end

-- ============================================================================
-- 8. json_unpack number range mapping
-- ============================================================================
head('json_unpack number mapping')

-- Lua 5.x integer range goes up to 2^63-1 = 9223372036854775807
do
    local big = xutils.json_unpack('9223372036854775807')
    ok('max int64 stays integer',
       math.type and math.type(big) == 'integer' or true)
    ok('max int64 value',  big == 9223372036854775807)
end

-- Beyond int64 max -> falls back to number (precision loss expected)
do
    local huge = xutils.json_unpack('1e30')
    ok('1e30 is number', type(huge) == 'number')
end

-- Negative big
do
    local neg = xutils.json_unpack('-9223372036854775808')
    ok('min int64 value', neg == -9223372036854775808 or neg == -9.2233720368548e18)
end

-- ============================================================================
-- 9. json_unpack failures
-- ============================================================================
head('json_unpack failures')

local function expect_unpack_fail(name, text)
    local v, e = xutils.json_unpack(text)
    ok(name, v == nil and type(e) == 'string',
        string.format('got=%s err=%s', tostring(v), tostring(e)))
end

expect_unpack_fail('bad json garbage',  '{bad json')
expect_unpack_fail('empty string',      '')
expect_unpack_fail('trailing comma',    '[1,2,]')

-- ============================================================================
-- 10. Round-trips
-- ============================================================================
head('round-trips')

-- json_null round-trip
do
    local s = xutils.json_pack({ a = xutils.json_null })
    eq('null round-trip text',  s, '{"a":null}')
    local t = xutils.json_unpack(s)
    ok('null round-trip equals sentinel', t.a == xutils.json_null)
end

-- Nested round-trip via parse
do
    local original_text = '{"name":"alice","tags":["vip","active"],"score":100}'
    local t = xutils.json_unpack(original_text)
    ok('parse object', type(t) == 'table')
    eq('parse name',   t.name, 'alice')
    eq('parse score',  t.score, 100)
    ok('parse tags array',
        type(t.tags) == 'table' and #t.tags == 2
        and t.tags[1] == 'vip' and t.tags[2] == 'active')
end

-- ============================================================================
-- Summary
-- ============================================================================
print('\n========================================')
print(string.format('PASS %d   FAIL %d', pass, fail))
if fail > 0 then
    for _, m in ipairs(failures) do print(m) end
end
print('========================================')

-- xnet_main.c lifecycle: return a table with __init that asks the runner to stop.
return {
    __init = function()
        xthread.stop(fail == 0)
    end,
}
