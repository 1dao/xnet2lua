-- Unit specs for scripts/game/playerstore.lua: one home lane's resident player
-- store (design §19.1 hooks 3+4, §19.3 anti-patterns 5/6/8). Pure logic, no
-- sockets. Proves the v1 obligations the design pins:
--   * persistent state is WRITE-THROUGH with a droppable cache, not flush-on-logout
--   * lifecycle (spawn/despawn) is standalone and decoupled from "login"
--   * runtime state is the only thing a v2 MIGRATE would carry (never persisted)
--   * the disconnect-grace reap drops cold memory WITHOUT data loss
--   * invalidate() exists (the §19.3 #8 interface) and drops WITHOUT flushing
-- and deliberately exercises the §19.3 #7 异常 paths (unknown pid everywhere) that
-- a v1 with never-moving players would otherwise leave untested. Run via:
--   bin/xnet tests/lua/playerstore_spec.lua
--   make -C tests unit-lua

local spec = dofile('tests/lua/spec_helper.lua')
local store = dofile('scripts/game/playerstore.lua')

-- A recording load/write sink so each test can assert exactly what hit "Redis".
local function new_recorder(seed)
    local rec = { writes = {}, loads = {}, seed = seed or {} }
    rec.opts = {
        flush_max_ms = 1000,
        drop_after_ms = 30000,
        load = function(pid)
            rec.loads[#rec.loads + 1] = pid
            local out = {}
            local s = rec.seed[pid]
            if s then for k, v in pairs(s) do out[k] = v end end
            return out
        end,
        write = function(pid, fields)
            local copy = {}
            local n = 0
            for k, v in pairs(fields) do copy[k] = v; n = n + 1 end
            rec.writes[#rec.writes + 1] = { pid = pid, fields = copy, count = n }
            return true
        end,
    }
    return rec
end

local function writes_for(rec, pid)
    local n = 0
    for _, w in ipairs(rec.writes) do if w.pid == pid then n = n + 1 end end
    return n
end

-- ----- spawn: cold-load (v1) and runtime_hint (v2), idempotency (§19.1.3) -----

spec.describe('spawn cold-loads persistent and accepts a runtime hint', function()
    spec.it('v1 spawn (runtime_hint nil) cold-loads persistent from the sink', function()
        local rec = new_recorder({ [42] = { gold = 100, name = 'A' } })
        local ps = store.new(rec.opts)
        ps:spawn(42, nil, 0)
        spec.equal(#rec.loads, 1, 'load() called exactly once on cold spawn')
        spec.equal(ps:get(42, 'gold'), 100, 'persistent field loaded')
        spec.equal(ps:get(42, 'name'), 'A')
        spec.truthy(ps:known(42), 'resident after spawn')
        spec.truthy(ps:online(42), 'online after spawn')
        spec.nil_value(ps:get_runtime(42, 'hp'), 'no runtime carried in v1')
    end)

    spec.it('v2 spawn carries the MIGRATE runtime態 via runtime_hint', function()
        local rec = new_recorder()
        local ps = store.new(rec.opts)
        ps:spawn(7, { hp = 50, buff = 'haste' }, 0)
        spec.equal(ps:get_runtime(7, 'hp'), 50, 'runtime hint adopted')
        spec.equal(ps:get_runtime(7, 'buff'), 'haste')
    end)

    spec.it('re-spawn is idempotent: no reload, unflushed memory preserved', function()
        local rec = new_recorder({ [9] = { gold = 100 } })
        local ps = store.new(rec.opts)
        ps:spawn(9, nil, 0)
        ps:set(9, 'gold', 200, 0)                 -- dirty, not yet flushed
        ps:spawn(9, nil, 0)                        -- second spawn
        spec.equal(#rec.loads, 1, 'load() NOT called again on re-spawn')
        spec.equal(ps:get(9, 'gold'), 200, 'unflushed memory not clobbered')
        spec.truthy(ps:is_dirty(9), 'still dirty after re-spawn')
    end)
end)

-- ----- write-through: dirty + time-bounded, batched flush (§19.1.4, §19.3 #5) ---

spec.describe('persistent writes are write-through, batched, time-bounded', function()
    spec.it('set marks dirty but does not write until flush', function()
        local rec = new_recorder()
        local ps = store.new(rec.opts)
        ps:spawn(1, nil, 0)
        ps:set(1, 'gold', 5, 0)
        spec.truthy(ps:is_dirty(1), 'dirty after set')
        spec.equal(#rec.writes, 0, 'no write happens inside set()')
    end)

    spec.it('flush honours the time bound, then writes and clears dirty', function()
        local rec = new_recorder()
        local ps = store.new(rec.opts)               -- flush_max_ms = 1000
        ps:spawn(1, nil, 0)
        ps:set(1, 'gold', 5, 0)
        spec.equal(ps:flush(999, false), 0, 'not yet aged past the bound -> no write')
        spec.truthy(ps:is_dirty(1), 'still dirty below the bound')
        spec.equal(ps:flush(1000, false), 1, 'aged to the bound -> one player written')
        spec.equal(writes_for(rec, 1), 1)
        spec.truthy(not ps:is_dirty(1), 'dirty cleared after flush')
        spec.equal(ps:flush(2000, false), 0, 'nothing left to write')
    end)

    spec.it('force flush writes immediately regardless of age', function()
        local rec = new_recorder()
        local ps = store.new(rec.opts)
        ps:spawn(1, nil, 0)
        ps:set(1, 'gold', 5, 0)
        spec.equal(ps:flush(0, true), 1, 'force ignores the time bound')
        spec.equal(rec.writes[1].fields.gold, 5)
    end)

    spec.it('multiple field changes coalesce into ONE batched write', function()
        local rec = new_recorder()
        local ps = store.new(rec.opts)
        ps:spawn(1, nil, 0)
        ps:set(1, 'gold', 5, 0)
        ps:set(1, 'level', 3, 0)
        ps:set(1, 'name', 'Z', 0)
        ps:flush(0, true)
        spec.equal(#rec.writes, 1, 'one write call for three field changes')
        spec.equal(rec.writes[1].count, 3, 'all three fields in the single batch')
        spec.equal(rec.writes[1].fields.gold, 5)
        spec.equal(rec.writes[1].fields.level, 3)
        spec.equal(rec.writes[1].fields.name, 'Z')
    end)

    spec.it('dirty_since tracks the OLDEST pending change', function()
        local rec = new_recorder()
        local ps = store.new(rec.opts)               -- flush_max_ms = 1000
        ps:spawn(1, nil, 0)
        ps:set(1, 'gold', 5, 0)                      -- oldest pending at t=0
        spec.equal(ps:flush(500, false), 0, 'first change not yet aged')
        ps:set(1, 'level', 3, 600)                   -- newer change; dirty_since stays 0
        spec.equal(ps:flush(1000, false), 1, 'oldest hit the bound -> write')
        spec.equal(rec.writes[1].count, 2, 'both pending fields flushed together')
    end)
end)

-- ----- runtime state is transient: never persisted (§19.1.4) -----

spec.describe('runtime state is never persisted', function()
    spec.it('set_runtime does not dirty and force flush writes nothing', function()
        local rec = new_recorder()
        local ps = store.new(rec.opts)
        ps:spawn(1, nil, 0)
        ps:set_runtime(1, 'cooldown', 1200)
        spec.truthy(not ps:is_dirty(1), 'runtime change is not dirty')
        spec.equal(ps:flush(0, true), 0, 'force flush writes no runtime fields')
        spec.equal(#rec.writes, 0)
        spec.equal(ps:get_runtime(1, 'cooldown'), 1200, 'runtime still readable in memory')
    end)
end)

-- ----- despawn: force-flush then drop (§19.1.3 logout / MIGRATE-send) -----

spec.describe('despawn force-flushes then drops', function()
    spec.it('writes pending state and removes the player', function()
        local rec = new_recorder()
        local ps = store.new(rec.opts)
        ps:spawn(1, nil, 0)
        ps:set(1, 'gold', 9, 0)
        spec.truthy(ps:despawn(1, 0), 'despawn returns true')
        spec.equal(writes_for(rec, 1), 1, 'force-flushed on the way out')
        spec.equal(rec.writes[1].fields.gold, 9)
        spec.truthy(not ps:known(1), 'memory dropped')
        spec.equal(ps:count(), 0)
    end)
end)

-- ----- disconnect grace + reap boundary (§19.1.4) -----

spec.describe('disconnect keeps memory for the grace window', function()
    spec.it('disconnect marks offline but keeps the cache resident', function()
        local rec = new_recorder({ [1] = { gold = 100 } })
        local ps = store.new(rec.opts)
        ps:spawn(1, nil, 0)
        spec.truthy(ps:disconnect(1, 0), 'disconnect returns true')
        spec.truthy(not ps:online(1), 'offline after disconnect')
        spec.truthy(ps:known(1), 'still resident during grace')
        spec.equal(ps:get(1, 'gold'), 100, 'cache still readable for a quick reconnect')
    end)

    spec.it('reap drops a stale entry only AT the grace boundary, force-flushing it', function()
        local rec = new_recorder()
        local ps = store.new(rec.opts)               -- drop_after_ms = 30000
        ps:spawn(1, nil, 0)
        ps:set(1, 'gold', 7, 0)
        ps:disconnect(1, 1000)                       -- disconnected at t=1000
        spec.equal(ps:reap(1000 + 29999), 0, 'one ms before the window -> kept')
        spec.truthy(ps:known(1), 'still resident at grace-1')
        spec.truthy(ps:is_dirty(1), 'still dirty, not yet flushed')
        spec.equal(ps:reap(1000 + 30000), 1, 'at the window -> dropped')
        spec.equal(writes_for(rec, 1), 1, 'force-flushed before drop -> no data loss')
        spec.equal(rec.writes[1].fields.gold, 7)
        spec.truthy(not ps:known(1), 'memory reclaimed')
    end)

    spec.it('reconnect inside the window cancels the pending drop', function()
        local rec = new_recorder()
        local ps = store.new(rec.opts)
        ps:spawn(1, nil, 0)
        ps:disconnect(1, 1000)
        spec.truthy(ps:reconnect(1, 5000), 'reconnect returns true')
        spec.truthy(ps:online(1), 'online again')
        spec.equal(ps:reap(1000 + 1000000), 0, 'an online player is never reaped')
        spec.truthy(ps:known(1), 'still resident long after the original window')
    end)

    spec.it('an online (never-disconnected) player is never reaped', function()
        local rec = new_recorder()
        local ps = store.new(rec.opts)
        ps:spawn(1, nil, 0)
        spec.equal(ps:reap(999999999), 0, 'online players are immune to reap')
        spec.truthy(ps:known(1))
    end)
end)

-- ----- invalidate: drop WITHOUT flushing (§19.3 #8 interface) -----

spec.describe('invalidate drops the cache without writing', function()
    spec.it('forgets a player and does NOT flush (distinct from despawn)', function()
        local rec = new_recorder()
        local ps = store.new(rec.opts)
        ps:spawn(1, nil, 0)
        ps:set(1, 'gold', 5, 0)                      -- dirty on purpose
        spec.truthy(ps:invalidate(1), 'invalidate returns true')
        spec.truthy(not ps:known(1), 'cache forgotten')
        spec.equal(#rec.writes, 0, 'invalidate writes nothing -- it is a pure forget')
    end)
end)

-- ----- §19.3 #7: the 异常 paths a never-moving v1 would leave untested -----

spec.describe('unknown-pid paths are safe (no crash, no resurrection)', function()
    spec.it('reads on an unknown pid return nil', function()
        local ps = store.new(new_recorder().opts)
        spec.nil_value(ps:get(404, 'gold'), 'get unknown -> nil')
        spec.nil_value(ps:get_runtime(404, 'hp'), 'get_runtime unknown -> nil')
        spec.truthy(not ps:known(404))
        spec.truthy(not ps:online(404), 'online on unknown -> false')
        spec.truthy(not ps:is_dirty(404))
    end)

    spec.it('mutations on an unknown pid fail without creating an entry', function()
        local ps = store.new(new_recorder().opts)
        spec.nil_value(ps:set(404, 'gold', 1, 0), 'set unknown -> nil')
        spec.nil_value(ps:set_runtime(404, 'hp', 1), 'set_runtime unknown -> nil')
        spec.truthy(not ps:disconnect(404, 0), 'disconnect unknown -> false')
        spec.truthy(not ps:reconnect(404, 0), 'reconnect unknown -> false')
        spec.truthy(not ps:despawn(404, 0), 'despawn unknown -> false')
        spec.truthy(not ps:invalidate(404), 'invalidate unknown -> false')
        spec.truthy(not ps:known(404), 'no entry was conjured by any of the above')
        spec.equal(ps:count(), 0)
    end)

    spec.it('flush and reap on an empty store are no-ops', function()
        local ps = store.new(new_recorder().opts)
        spec.equal(ps:flush(0, true), 0)
        spec.equal(ps:reap(999999), 0)
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
