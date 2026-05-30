-- Stage 6 specs: Game master/standby failover (design §17.3 / §12.1 / §3).
--
--   * cluster.lua  -- the gate's game_id -> endpoint routing table + the
--                     primary/standby health state machine with a grace freeze.
--   * zone_def     -- zone-owner failover: a controller-declared game-down flips
--                     affected zones to their configured standby owner, and the
--                     single ownership site carries it to every caller.
--
-- Run via: bin/xnet tests/lua/cluster_spec.lua

local spec = dofile('tests/lua/spec_helper.lua')
local cluster = dofile('scripts/game/cluster.lua')
local zone_def = dofile('scripts/game/zone_def.lua')

local function ep(host, port) return { host = host, port = port } end

local function fresh_cluster()
    local c = cluster.new({ grace_ms = 30000 })
    c:configure({
        [1] = { primary = ep('10.0.0.1', 7001), standby = ep('10.0.9.1', 7001) },
        [2] = { primary = ep('10.0.0.2', 7002) },   -- no standby (down on expiry)
    })
    return c
end

spec.describe('cluster routing table while healthy', function()
    spec.it('resolves to the primary and is not frozen', function()
        local c = fresh_cluster()
        local endpoint, state, frozen = c:resolve(1)
        spec.equal(state, cluster.UP)
        spec.equal(endpoint.host, '10.0.0.1')
        spec.equal(endpoint.port, 7001)
        spec.truthy(not frozen, 'a healthy game is never frozen')
    end)

    spec.it('returns nothing for an unknown game_id', function()
        local c = fresh_cluster()
        local endpoint, state, frozen = c:resolve(99)
        spec.nil_value(endpoint)
        spec.nil_value(state)
        spec.truthy(not frozen)
    end)
end)

spec.describe('cluster grace window on a primary drop (§12.1)', function()
    spec.it('freezes upstream and offers no endpoint during grace', function()
        local c = fresh_cluster()
        spec.equal(c:on_disconnect(1, 1000), cluster.GRACE)
        local endpoint, state, frozen = c:resolve(1)
        spec.nil_value(endpoint, 'no endpoint while frozen')
        spec.equal(state, cluster.GRACE)
        spec.truthy(frozen, 'sids homed here see OP_SERVER_BUSY')
        spec.truthy(c:is_frozen(1))
    end)

    spec.it('a tick before the deadline keeps it in grace', function()
        local c = fresh_cluster()
        c:on_disconnect(1, 1000)
        spec.nil_value(c:tick(30999, 1), 'not yet expired -> no transition')
        spec.equal(c:state(1), cluster.GRACE)
    end)

    spec.it('a primary reconnect inside grace recovers to up', function()
        local c = fresh_cluster()
        c:on_disconnect(1, 1000)
        spec.equal(c:on_reconnect(1), cluster.UP)
        local endpoint, state, frozen = c:resolve(1)
        spec.equal(state, cluster.UP)
        spec.equal(endpoint.host, '10.0.0.1', 'back on the primary')
        spec.truthy(not frozen)
    end)
end)

spec.describe('cluster failover to standby (§17.3)', function()
    spec.it('grace expiry with a standby flips the endpoint, unfreezes', function()
        local c = fresh_cluster()
        c:on_disconnect(1, 1000)
        spec.equal(c:tick(31000, 1), cluster.STANDBY, 'deadline reached -> standby')
        local endpoint, state, frozen = c:resolve(1)
        spec.equal(state, cluster.STANDBY)
        spec.equal(endpoint.host, '10.0.9.1', 'now dialing the standby host')
        spec.truthy(not frozen, 'standby serves traffic, no freeze')
    end)

    spec.it('grace expiry with NO standby goes down (clients reconnect)', function()
        local c = fresh_cluster()
        c:on_disconnect(2, 1000)
        spec.equal(c:tick(31000, 2), cluster.DOWN)
        local endpoint, state, frozen = c:resolve(2)
        spec.nil_value(endpoint, 'down: no endpoint, clients land elsewhere')
        spec.equal(state, cluster.DOWN)
        spec.truthy(not frozen)
    end)

    spec.it('a controller failover skips the grace wait', function()
        local c = fresh_cluster()
        spec.truthy(c:failover(1), 'has a standby -> immediate flip')
        spec.equal(c:state(1), cluster.STANDBY)
        spec.truthy(not c:failover(2), 'no standby -> failover refused')
        spec.equal(c:state(2), cluster.UP, 'and game 2 is untouched')
    end)

    spec.it('restore returns a failed-over game to its primary', function()
        local c = fresh_cluster()
        c:failover(1)
        spec.truthy(c:restore(1))
        local endpoint, state = c:resolve(1)
        spec.equal(state, cluster.UP)
        spec.equal(endpoint.host, '10.0.0.1', 'primary back in service')
    end)

    spec.it('a sweep tick promotes every expired game at once', function()
        local c = fresh_cluster()
        c:on_disconnect(1, 1000)
        c:on_disconnect(2, 1000)
        local changed = c:tick(31000)            -- no game_id -> sweep all
        spec.truthy(changed, 'something transitioned')
        spec.equal(changed[1], cluster.STANDBY)
        spec.equal(changed[2], cluster.DOWN)
    end)
end)

spec.describe('zone-owner failover via the single ownership site (§3/§17.3)', function()
    -- Pin a zone's primary owner and standby so the test is independent of the
    -- hash, then exercise the controller hooks. resolve_zone_owner is the only
    -- ownership site, so this is exactly what combat/AOI routing would observe.
    local ZONE = 42

    local function with_clean_zone_def(fn)
        zone_def.zone_owner_override[ZONE] = { 1, 3 }   -- primary: game 1, lane 3
        zone_def.zone_standby[ZONE] = { 2, 5 }          -- standby: game 2, lane 5
        zone_def.game_down = {}
        local ok, err = pcall(fn)
        zone_def.zone_owner_override[ZONE] = nil
        zone_def.zone_standby[ZONE] = nil
        zone_def.game_down = {}
        if not ok then error(err, 0) end
    end

    spec.it('resolves to the primary owner while the game is up', function()
        with_clean_zone_def(function()
            local g, l = zone_def.resolve_zone_owner(ZONE)
            spec.equal(g, 1)
            spec.equal(l, 3)
        end)
    end)

    spec.it('flips to the standby owner when the primary game is down', function()
        with_clean_zone_def(function()
            zone_def.mark_game_down(1)
            local g, l = zone_def.resolve_zone_owner(ZONE)
            spec.equal(g, 2, 'owner moved to the standby game')
            spec.equal(l, 5, 'and the configured standby lane')
        end)
    end)

    spec.it('restores the primary owner once the game is marked up', function()
        with_clean_zone_def(function()
            zone_def.mark_game_down(1)
            zone_def.mark_game_up(1)
            local g, l = zone_def.resolve_zone_owner(ZONE)
            spec.equal(g, 1)
            spec.equal(l, 3)
        end)
    end)

    spec.it('a down game with no standby keeps the primary (nothing to flip to)', function()
        with_clean_zone_def(function()
            zone_def.zone_standby[ZONE] = nil
            zone_def.mark_game_down(1)
            local g, l = zone_def.resolve_zone_owner(ZONE)
            spec.equal(g, 1, 'no standby configured -> owner unchanged')
            spec.equal(l, 3)
        end)
    end)

    spec.it('a sibling zone on a healthy game is unaffected', function()
        with_clean_zone_def(function()
            zone_def.zone_owner_override[7] = { 2, 1 }   -- primary on game 2
            zone_def.mark_game_down(1)                    -- only game 1 is down
            local g, l = zone_def.resolve_zone_owner(7)
            spec.equal(g, 2, 'game-2 zone untouched by a game-1 outage')
            spec.equal(l, 1)
            zone_def.zone_owner_override[7] = nil
        end)
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
