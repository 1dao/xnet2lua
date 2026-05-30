-- Stage 7 故障演练: drive the §12 failure / recovery paths end-to-end across the
-- Stage 6 failover modules.
--
-- cluster.lua is the gate's game_id -> endpoint health machine; zone_def is the
-- single zone-ownership site. A real incident touches BOTH: the gate freezes and
-- then re-points its routing while the controller flips zone ownership -- and
-- through all of it the LOGICAL game_id (and therefore every player's home_lane /
-- sid) must stay fixed (§17.3). No single unit spec exercises that cross-module
-- flip; these drills do, and assert exactly the invariant.
--
-- Run via: bin/xnet tests/lua/fault_drill_spec.lua

local spec = dofile('tests/lua/spec_helper.lua')
local cluster = dofile('scripts/game/cluster.lua')
local zone_def = dofile('scripts/game/zone_def.lua')

-- A two-game deployment, pinned via overrides so the drill is deterministic and
-- independent of the default GAME_COUNT:
--   game 1 owns zone 100 (lane 3), standby on game 2 (lane 5)
--   game 2 owns zone 200 (lane 2), NO standby
zone_def.zone_owner_override[100] = { 1, 3 }
zone_def.zone_standby[100]        = { 2, 5 }
zone_def.zone_owner_override[200] = { 2, 2 }

-- A fresh gate routing table for each drill (cluster is per-instance state).
local function new_gate()
    return cluster.new({ grace_ms = 30000 }):configure({
        [1] = { primary = { host = '10.0.1.1', port = 7001 },
                standby = { host = '10.0.9.1', port = 7001 } },
        [2] = { primary = { host = '10.0.1.2', port = 7002 } },
    })
end

local function owner(zone_id)
    return zone_def.resolve_zone_owner(zone_id)
end

spec.describe('§12.1 Game down, primary recovers inside the grace window', function()
    spec.it('freezes upstream during grace, never flips the zone, then recovers', function()
        local cl = new_gate()

        local ep, st, frozen = cl:resolve(1)
        spec.equal(ep.host, '10.0.1.1', 'steady state -> primary endpoint')
        spec.equal(st, cluster.UP)
        spec.truthy(not frozen)
        local g0, l0 = owner(100)
        spec.equal(g0, 1, 'zone 100 owned by its primary game')
        spec.equal(l0, 3)

        -- gate sees battle_conn[1] close
        spec.equal(cl:on_disconnect(1, 0), cluster.GRACE)
        spec.truthy(cl:is_frozen(1), 'gate returns OP_SERVER_BUSY while frozen')
        local ep2, st2, frozen2 = cl:resolve(1)
        spec.nil_value(ep2, 'nothing to dial mid-grace')
        spec.equal(st2, cluster.GRACE)
        spec.truthy(frozen2)
        -- controller has NOT declared the game down -> ownership unchanged
        local g1, l1 = owner(100)
        spec.equal(g1, 1, 'zone owner still primary during grace')
        spec.equal(l1, 3)

        -- primary readmitted before the 30s deadline
        spec.equal(cl:on_reconnect(1), cluster.UP)
        spec.truthy(not cl:is_frozen(1))
        local ep3 = cl:resolve(1)
        spec.equal(ep3.host, '10.0.1.1', 'back on primary; no flip ever happened')
    end)
end)

spec.describe('§12.1 / §17.3 grace expires -> standby failover -> restore', function()
    spec.it('flips physical endpoint + zone owner while logical identity holds', function()
        local cl = new_gate()
        -- a sample player whose home must NOT move across the incident
        local hg_before, hl_before = zone_def.resolve_player_home(123457)

        spec.equal(cl:on_disconnect(1, 0), cluster.GRACE)
        spec.nil_value(cl:tick(29999, 1), 'still inside grace -> no change')
        spec.truthy(cl:is_frozen(1), 'still frozen at 29999')

        spec.equal(cl:tick(30000, 1), cluster.STANDBY, 'grace deadline -> standby')
        local ep, st, frozen = cl:resolve(1)
        spec.equal(ep.host, '10.0.9.1', 'now dialing the standby endpoint')
        spec.equal(st, cluster.STANDBY)
        spec.truthy(not frozen, 'unfrozen once on the standby')

        -- controller declares game 1 down -> zone ownership flips to the standby
        zone_def.mark_game_down(1)
        local g, l = owner(100)
        spec.equal(g, 2, 'zone 100 owner failed over to the standby game')
        spec.equal(l, 5)
        -- ...but the LOGICAL identity is untouched: same player home as before
        local hg_after, hl_after = zone_def.resolve_player_home(123457)
        spec.equal(hg_after, hg_before, 'home_game unchanged by the failover')
        spec.equal(hl_after, hl_before, 'home_lane unchanged by the failover')

        -- restore: primary healthy again
        spec.truthy(cl:restore(1))
        spec.equal(cl:state(1), cluster.UP)
        zone_def.mark_game_up(1)
        local rg, rl = owner(100)
        spec.equal(rg, 1, 'ownership restored to primary')
        spec.equal(rl, 3)
    end)
end)

spec.describe('§12.1 Game down with no standby -> clients dropped', function()
    spec.it('goes down at the deadline so clients reconnect elsewhere (Redis/backup)', function()
        local cl = new_gate()
        spec.equal(cl:on_disconnect(2, 0), cluster.GRACE)
        spec.equal(cl:tick(30000, 2), cluster.DOWN, 'no standby -> down')
        local ep, st, frozen = cl:resolve(2)
        spec.nil_value(ep, 'no endpoint -> gate drops these clients')
        spec.equal(st, cluster.DOWN)
        spec.truthy(not frozen)
        -- zone 200 has no standby owner: even if the controller marks game 2 down,
        -- ownership stays put until a backup is assigned.
        zone_def.mark_game_down(2)
        local g, l = owner(200)
        spec.equal(g, 2, 'no standby owner -> zone stays on its primary game')
        spec.equal(l, 2)
        zone_def.mark_game_up(2)
    end)
end)

spec.describe('§17.3 controller-driven immediate failover (skip the grace wait)', function()
    spec.it('flips at once when a standby exists, no-ops otherwise', function()
        local cl = new_gate()
        spec.truthy(cl:failover(1), 'game 1 has a standby -> immediate flip')
        spec.equal(cl:state(1), cluster.STANDBY)
        local ep = cl:resolve(1)
        spec.equal(ep.host, '10.0.9.1', 'routing already on the standby')
        spec.truthy(not cl:failover(2), 'game 2 has no standby -> no-op')
        spec.equal(cl:state(2), cluster.UP, 'and stays up')
    end)
end)

spec.describe('§12.2 Gate down -> reconnect re-derives the same affinity', function()
    spec.it('home is a pure function of pid, so any gate recovers it identically', function()
        -- the client reconnects to some other gate; that gate re-derives the home
        -- lane from the pid alone -- no shared session state needed.
        local g1, l1 = zone_def.resolve_player_home(7777)
        local g2, l2 = zone_def.resolve_player_home(7777)
        spec.equal(g1, g2, 'same home_game from any gate')
        spec.equal(l1, l2, 'same home_lane from any gate')
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
