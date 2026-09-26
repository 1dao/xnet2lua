-- Unit specs for xutils.json_pack / json_unpack array/object shape.
-- Run via: bin/xnet.exe tests/lua/xutils_json_spec.lua
--
-- Lua has one table type, so an empty [] and an empty {} decode to the same
-- thing. json_unpack tags decoded arrays with xutils.json_array_mt so they
-- re-encode as [] (API payloads reject "required":{} or "content":{}).

local spec = dofile('tests/lua/spec_helper.lua')
local u    = require('xutils')

spec.describe('xutils json array shape', function()
    spec.it('round-trips empty arrays and empty objects, nested too', function()
        local t = u.json_unpack('{"a":[],"b":{},"c":[1,[]],"d":[{"e":[]}]}')
        spec.equal(u.json_pack(t.a), '[]')
        spec.equal(u.json_pack(t.b), '{}')
        spec.equal(u.json_pack(t.c), '[1,[]]')
        spec.equal(u.json_pack(t.d), '[{"e":[]}]')
    end)

    spec.it('tags decoded arrays only', function()
        spec.equal(getmetatable(u.json_unpack('[]')), u.json_array_mt)
        spec.equal(getmetatable(u.json_unpack('[1]')), u.json_array_mt)
        spec.nil_value(getmetatable(u.json_unpack('{}')))
    end)

    spec.it('encodes a tagged table as [] once it is emptied', function()
        local t = u.json_unpack('[1,2]')
        table.remove(t); table.remove(t)
        spec.equal(u.json_pack(t), '[]')
    end)

    spec.it('lets callers build an empty array', function()
        spec.equal(u.json_pack(setmetatable({}, u.json_array_mt)), '[]')
        spec.equal(u.json_pack({ list = setmetatable({}, u.json_array_mt) }), '{"list":[]}')
    end)

    spec.it('keeps untagged and non-empty shapes unchanged', function()
        spec.equal(u.json_pack({}), '{}')
        spec.equal(u.json_pack({ 1, 2 }), '[1,2]')
        -- A tag does not force a table with holes or string keys into an array.
        local t = u.json_unpack('[5]'); t[3] = 7
        spec.equal(u.json_unpack(u.json_pack(t))['3'], 7)
    end)
end)

spec.describe('xagent canonical json_encode', function()
    package.path = 'scripts/?.lua;' .. package.path
    local encode = require('xagent.llm.common').json_encode
    spec.it('follows the same array tag as json_pack', function()
        local schema = u.json_unpack('{"type":"object","properties":{},"required":[]}')
        spec.equal(encode(schema), '{"properties":{},"required":[],"type":"object"}')
        spec.equal(encode({}), '{}')
    end)
end)

local failures = spec.finish()

return {
    __init = function()
        if failures > 0 then os.exit(1) end
        xthread.stop(0)
    end,
}
