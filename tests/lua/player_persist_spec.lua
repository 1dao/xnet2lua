-- Integration spec for the work lane's persistence lifecycle (§19.1.3/4), keyed by
-- the PERMANENT player_id (§19.0 身份 ≠ 位置). It proves the cross-connection payoff
-- the sid-keyed v1 could not show: a returning player -- a NEW connection with a
-- fresh sid but the SAME player_id -- restores the position written through on their
-- last disconnect, instead of falling back to the coords the client proposes.
--
-- The helpers below replay EXACTLY the playerstore calls work_worker.lua makes in
-- battle_session_new / battle_session_gone / the persist_timer tick, against a
-- Redis-like sink that OUTLIVES a single resident entry (the role Redis plays once
-- the reap reclaims lane memory). A regression that re-keyed the store by the
-- per-connection sid would make the second login's cold load miss -- the restore
-- assertions below would fail, so this is not a vacuous test.
--
-- Run via: bin/xnet tests/lua/player_persist_spec.lua

local spec = dofile('tests/lua/spec_helper.lua')
local store = dofile('scripts/game/playerstore.lua')

-- A persistent hash sink: load() reads a stored row, write() merges the dirty
-- subset. Unlike lane memory it survives reap(), exactly like Redis. Values are
-- stringified on write to mirror the HSET/HGETALL round-trip (playerstore_redis
-- stores hash fields as strings), so the helper's tonumber() is load-bearing.
local function redis_like()
    local r = { db = {}, writes = 0 }
    r.load = function(pid)
        local out, src = {}, r.db[pid]
        if src then for k, v in pairs(src) do out[k] = v end end
        return out
    end
    r.write = function(pid, fields)
        local row = r.db[pid] or {}
        for k, v in pairs(fields) do row[k] = tostring(v) end
        r.db[pid] = row
        r.writes = r.writes + 1
    end
    return r
end

local function new_store(r)
    return store.new({ load = r.load, write = r.write,
                       flush_max_ms = 1000, drop_after_ms = 30000 })
end

-- work_worker.lua 'battle_session_new': cold-load by pid, resolve the spawn pos
-- (saved persistent value wins; the client's coords are the first-login fallback).
local function work_session_new(ps, pid, fx, fy, now)
    ps:spawn(pid, nil, now)
    local x = tonumber(ps:get(pid, 'x')) or fx
    local y = tonumber(ps:get(pid, 'y')) or fy
    return x, y
end

-- work_worker.lua 'battle_session_gone': write-through the logout pos, start grace.
local function work_session_gone(ps, pid, x, y, now)
    if x ~= nil and y ~= nil then
        ps:set(pid, 'x', x, now)
        ps:set(pid, 'y', y, now)
    end
    ps:disconnect(pid, now)
end

-- work_worker.lua persist_timer tick: drain dirty within the bound, reap the stale.
local function work_tick(ps, now)
    ps:flush(now, false)
    ps:reap(now)
end

spec.describe('persistence keyed by player_id survives a new connection (§19.1.3/4)', function()
    spec.it('a returning player restores the written-through logout position', function()
        local r = redis_like()
        local ps = new_store(r)
        local P = 7777

        -- ---- connection #1 (sid_a). First login, DB cold -> client coords win.
        local x1, y1 = work_session_new(ps, P, 100, 200, 0)
        spec.equal(x1, 100, 'first login (no saved pos) falls back to client x')
        spec.equal(y1, 200, 'first login falls back to client y')

        -- player walks, then logs out at (2058, 311): write-through + grace start.
        work_session_gone(ps, P, 2058, 311, 5000)
        work_tick(ps, 6000)                    -- past the 1s bound -> drains to Redis
        spec.equal(r.db[P].x, '2058', 'logout x written through to Redis')
        spec.equal(r.db[P].y, '311', 'logout y written through to Redis')

        -- 30s with no return: reap reclaims lane memory (data safe in Redis).
        work_tick(ps, 5000 + 30000)
        spec.truthy(not ps:known(P), 'lane memory reclaimed after the grace window')

        -- ---- connection #2: a NEW sid, SAME player_id. The client proposes fresh
        -- coords, but the saved logout position must win.
        local x2, y2 = work_session_new(ps, P, 999, 888, 100000)
        spec.equal(x2, 2058, 'returning player restores saved x, not the client fallback')
        spec.equal(y2, 311, 'returning player restores saved y')
    end)

    spec.it('the restore is per-player_id: a different id does not leak state', function()
        local r = redis_like()
        local ps = new_store(r)
        local P, Q = 111, 222
        work_session_new(ps, P, 50, 60, 0)     -- P enters the world (becomes resident)
        work_session_gone(ps, P, 70, 80, 0)    -- ...then logs out at (70,80)
        work_tick(ps, 2000)                    -- flush P's pos to Redis
        -- Q logs in cold: it must NOT see P's saved position.
        local qx, qy = work_session_new(ps, Q, 33, 44, 3000)
        spec.equal(qx, 33, 'Q falls back to its own client coords')
        spec.equal(qy, 44)
    end)

    spec.it('a fresh sid keyed in place of the player_id would LOSE the restore', function()
        -- The bug the player_id keying fixes: had the store kept keying by the
        -- per-connection sid, connection #2 (a different sid) would cold-load
        -- nothing. We model that miss explicitly so the fix's value is not vacuous.
        local r = redis_like()
        local ps = new_store(r)
        local P, sid_b = 555, 0x02000003       -- sid_b: a later connection's sid
        work_session_new(ps, P, 10, 20, 0)     -- P enters the world
        work_session_gone(ps, P, 2058, 311, 0) -- write-through under the permanent id
        work_tick(ps, 2000)
        -- keyed by the NEW sid (the old, broken behaviour) -> miss -> client fallback:
        local bx, by = work_session_new(ps, sid_b, 999, 888, 3000)
        spec.equal(bx, 999, 'sid-keyed cold load finds nothing -> client fallback')
        spec.equal(by, 888)
        -- keyed by the permanent player_id -> restore:
        local px, py = work_session_new(ps, P, 999, 888, 3000)
        spec.equal(px, 2058, 'player_id-keyed cold load restores the saved pos')
        spec.equal(py, 311)
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
