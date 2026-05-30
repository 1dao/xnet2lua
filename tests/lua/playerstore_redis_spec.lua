-- Unit specs for scripts/game/playerstore_redis.lua: the Redis write-through sink
-- for the player store (design §19.1.4 "持久字段变更立即写 Redis"). Pure logic, no
-- sockets -- it runs against a small in-memory Redis-hash emulator so we can assert
-- the EXACT commands issued and prove a real round-trip through playerstore. Run via:
--   bin/xnet tests/lua/playerstore_redis_spec.lua
--   make -C tests unit-lua

local spec = dofile('tests/lua/spec_helper.lua')
local sink = dofile('scripts/game/playerstore_redis.lua')
local store = dofile('scripts/game/playerstore.lua')

-- An in-memory Redis HASH emulator exposing the xredis call/post API. post('HSET',..)
-- mirrors how xredis.post(cb, cmd, ...) shifts a non-function first arg to the command.
local function fake_redis()
    local r = { hashes = {}, posts = 0, calls = 0, last_post = nil }
    r.call = function(cmd, ...)
        r.calls = r.calls + 1
        local a = { ... }
        if cmd == 'HGETALL' then
            local h = r.hashes[a[1]]
            local out = {}
            if h then for k, v in pairs(h) do out[#out + 1] = k; out[#out + 1] = v end end
            return true, out
        end
        return true, nil
    end
    r.post = function(cmd, ...)
        r.posts = r.posts + 1
        local a = { ... }
        r.last_post = { cmd = cmd, key = a[1], fields = {} }
        if cmd == 'HSET' then
            local key = a[1]
            local h = r.hashes[key]; if not h then h = {}; r.hashes[key] = h end
            local i = 2
            while i + 1 <= #a do
                h[a[i]] = a[i + 1]
                r.last_post.fields[a[i]] = a[i + 1]
                i = i + 2
            end
        end
        return true
    end
    return r
end

-- ----- command construction -----

spec.describe('write issues a field-level HSET of the dirty subset', function()
    spec.it('HSETs exactly the given fields under player:<pid>', function()
        local r = fake_redis()
        local s = sink.make(r)
        s.write(7, { gold = '100', level = '3' })
        spec.equal(r.posts, 1, 'one fire-and-forget HSET')
        spec.equal(r.last_post.cmd, 'HSET')
        spec.equal(r.last_post.key, 'player:7', 'keyed player:<pid>')
        spec.equal(r.last_post.fields.gold, '100')
        spec.equal(r.last_post.fields.level, '3')
    end)

    spec.it('an empty field set issues no command at all', function()
        local r = fake_redis()
        local s = sink.make(r)
        s.write(7, {})
        spec.equal(r.posts, 0, 'nothing dirty -> no HSET')
    end)

    spec.it('stringifies non-string values (documented round-trip limitation)', function()
        local r = fake_redis()
        local s = sink.make(r)
        s.write(7, { gold = 100 })               -- a number going in
        spec.equal(r.last_post.fields.gold, '100', 'stored as the bulk string "100"')
    end)
end)

spec.describe('load issues HGETALL and decodes the flat reply', function()
    spec.it('decodes { f, v, ... } into a field table', function()
        local r = fake_redis()
        r.hashes['player:7'] = { gold = '100', name = 'A' }
        local s = sink.make(r)
        local t = s.load(7)
        spec.equal(r.calls, 1, 'one HGETALL')
        spec.equal(t.gold, '100')
        spec.equal(t.name, 'A')
    end)

    spec.it('a missing key decodes to an empty table', function()
        local r = fake_redis()
        local s = sink.make(r)
        local t = s.load(404)
        spec.equal(next(t), nil, 'no fields for an unknown player')
    end)

    spec.it('a connection error (ok=false) yields an empty table, not a crash', function()
        local r = { call = function() return false, 'conn_refused' end }
        local s = sink.make(r)
        local t = s.load(7)
        spec.equal(next(t), nil, 'cold start with defaults on error')
    end)
end)

-- ----- key prefix -----

spec.describe('key prefix is configurable', function()
    spec.it('honours opts.prefix for both load and write', function()
        local r = fake_redis()
        local s = sink.make(r, { prefix = 'p:' })
        spec.equal(s.key_of(7), 'p:7')
        s.write(7, { a = '1' })
        spec.equal(r.last_post.key, 'p:7', 'write uses the custom prefix')
    end)
end)

-- ----- the point: a real round-trip through playerstore -----

spec.describe('round-trips persistent state through a real playerstore', function()
    spec.it('set -> flush HSETs; a fresh store cold-loads the same values', function()
        local r = fake_redis()
        local adapter = sink.make(r)

        local s1 = store.new(adapter)
        s1:spawn(7, nil, 0)                      -- HGETALL player:7 -> {} (new player)
        s1:set(7, 'gold', '200', 0)
        s1:set(7, 'name', 'Z', 0)
        spec.equal(s1:flush(0, true), 1, 'one player flushed')
        spec.equal(r.posts, 1, 'one HSET carried both fields')

        local s2 = store.new(adapter)            -- a cold cache (e.g. after a reap)
        s2:spawn(7, nil, 0)                      -- HGETALL player:7 -> the flushed hash
        spec.equal(s2:get(7, 'gold'), '200', 'gold survived the round-trip')
        spec.equal(s2:get(7, 'name'), 'Z', 'name survived the round-trip')
    end)

    spec.it('flush writes only fields dirtied since the last flush, not the whole record', function()
        local r = fake_redis()
        local adapter = sink.make(r)
        local s1 = store.new(adapter)
        s1:spawn(7, nil, 0)
        s1:set(7, 'gold', '1', 0)
        s1:flush(0, true)                        -- HSET gold
        s1:set(7, 'name', 'Q', 0)
        s1:flush(0, true)                        -- HSET name ONLY
        spec.equal(r.posts, 2, 'two separate HSETs')
        spec.equal(r.last_post.fields.name, 'Q', 'second write carried name')
        spec.equal(r.last_post.fields.gold, nil, 'second write did NOT re-send gold')
    end)
end)

local failures = spec.finish()

return {
    __init = function()
        if failures > 0 then
            os.exit(1)
        end
        xthread.stop(0)
    end,
}
