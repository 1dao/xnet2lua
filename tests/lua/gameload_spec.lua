-- Stage 6 specs: character-creation load selection (design §17.8 / §13.2 / §4.0).
--
--   * gameload.lua -- the in-memory game.load registry the character-creation
--                     service maintains from NATS reports, with TTL staleness
--                     and pick_least_loaded.
--   * zone_def.assign_home -- mints a new character's permanent home: structural
--                     lane hash + load-picked game (hash fallback).
--
-- Run via: bin/xnet tests/lua/gameload_spec.lua

local spec = dofile('tests/lua/spec_helper.lua')
local gameload = dofile('scripts/game/gameload.lua')
local zone_def = dofile('scripts/game/zone_def.lua')

-- Multi-Game deployment so a load-picked home_game can differ from the hash one.
zone_def.GAME_COUNT = 4
zone_def.LANE_COUNT = 6

spec.describe('gameload registry picks the freest live Game (§17.8)', function()
    spec.it('reports and picks the lowest load', function()
        local r = gameload.new({ ttl_ms = 180000 })
        r:report(1, 900, 1000)
        r:report(2, 300, 1000)
        r:report(3, 650, 1000)
        local id, load = r:pick_least_loaded(1000)
        spec.equal(id, 2, 'game 2 is the least loaded')
        spec.equal(load, 300)
    end)

    spec.it('breaks ties on the lowest game_id (deterministic, no stampede)', function()
        local r = gameload.new()
        r:report(5, 400, 0)
        r:report(2, 400, 0)
        r:report(9, 400, 0)
        spec.equal(r:pick_least_loaded(0), 2, 'equal load -> lowest id wins')
    end)

    spec.it('updates a Game load on the next report', function()
        local r = gameload.new()
        r:report(1, 100, 1000)
        r:report(2, 200, 1000)
        spec.equal(r:pick_least_loaded(1000), 1)
        r:report(1, 999, 2000)            -- game 1 just got busy
        spec.equal(r:pick_least_loaded(2000), 2, 'now game 2 is freer')
    end)
end)

spec.describe('gameload staleness keeps dead Games out (§17.8)', function()
    spec.it('excludes a Game that stopped reporting past the TTL', function()
        local r = gameload.new({ ttl_ms = 180000 })
        r:report(1, 100, 0)               -- freest, but goes silent
        r:report(2, 500, 170000)          -- still reporting
        -- at t=190000, game 1's last report (t=0) is 190s old > 180s TTL
        spec.truthy(not r:is_live(1, 190000), 'game 1 is stale')
        spec.truthy(r:is_live(2, 190000), 'game 2 is fresh')
        spec.equal(r:pick_least_loaded(190000), 2,
            'a stale freer Game is not picked')
    end)

    spec.it('returns nil when no Game is currently live', function()
        local r = gameload.new({ ttl_ms = 1000 })
        r:report(1, 100, 0)
        spec.nil_value(r:pick_least_loaded(5000), 'all stale -> no pick')
    end)

    spec.it('reap drops stale entries and counts them', function()
        local r = gameload.new({ ttl_ms = 1000 })
        r:report(1, 100, 0)
        r:report(2, 200, 0)
        r:report(3, 300, 4500)            -- fresh at t=5000
        spec.equal(r:reap(5000), 2, 'games 1 and 2 reaped')
        spec.truthy(r:is_live(3, 5000), 'game 3 survives')
        spec.equal(r:pick_least_loaded(5000), 3)
    end)

    spec.it('snapshot reports load and liveness for monitoring', function()
        local r = gameload.new({ ttl_ms = 1000 })
        r:report(1, 100, 0)
        r:report(2, 200, 4500)
        local snap = r:snapshot(5000)
        spec.equal(snap[1].load, 100)
        spec.truthy(not snap[1].live, 'game 1 stale')
        spec.truthy(snap[2].live, 'game 2 live')
    end)
end)

spec.describe('assign_home mints a permanent home at creation (§4.0)', function()
    local PID = 123457

    spec.it('with no picker it is exactly the pure-hash home', function()
        local hg, hl = zone_def.assign_home(PID, nil)
        local rg, rl = zone_def.resolve_player_home(PID)
        spec.equal(hg, rg, 'home_game falls back to the hash')
        spec.equal(hl, rl, 'home_lane is the structural hash')
    end)

    spec.it('a picker steers home_game but never the structural lane', function()
        local _, structural_lane = zone_def.resolve_player_home(PID)
        local hg, hl = zone_def.assign_home(PID, function() return 3 end)
        spec.equal(hg, 3, 'home_game follows the load picker')
        spec.equal(hl, structural_lane, 'home_lane stays the hash, untouched')
    end)

    spec.it('a picker returning nil falls back to the hash game', function()
        local rg = (zone_def.resolve_player_home(PID))
        local hg = zone_def.assign_home(PID, function() return nil end)
        spec.equal(hg, rg, 'no load intel -> hash fallback')
    end)

    spec.it('end to end: the freest live Game becomes home_game', function()
        local r = gameload.new()
        r:report(1, 800, 1000)
        r:report(2, 250, 1000)            -- freest
        r:report(3, 600, 1000)
        local hg, hl = zone_def.assign_home(PID, r:picker(1000))
        spec.equal(hg, 2, 'home_game = least-loaded live Game')
        local _, structural_lane = zone_def.resolve_player_home(PID)
        spec.equal(hl, structural_lane, 'and the lane is still structural')
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
