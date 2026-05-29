-- Unit specs for the pure AOI zone actor (scripts/game/zone.lua) and its
-- geometry helpers (scripts/game/zone_def.lua). No networking: this validates
-- the hardest concept in the large-world design (grid occupancy + enter/leave/
-- move delta + seq) in isolation. Run via:
--   bin/xnet tests/lua/zone_spec.lua
--   make -C tests unit-lua

local spec = dofile('tests/lua/spec_helper.lua')
local zone_def = dofile('scripts/game/zone_def.lua')
local Zone = dofile('scripts/game/zone.lua')

-- ----- helpers -----

local function route_of(pid)
    return { home_game = 1, home_lane = 1, sid = pid, id = pid }
end

-- Flush the zone and return a map pid -> { seq, zone_id, events }.
local function drain(zone)
    local got = {}
    zone:flush(function(route, zone_id, seq, events)
        got[route.id] = { seq = seq, zone_id = zone_id, events = events }
    end)
    return got
end

local function count_kind(bundle, kind)
    if not bundle then return 0 end
    local n = 0
    for _, e in ipairs(bundle.events) do if e.t == kind then n = n + 1 end end
    return n
end

local function find_event(bundle, kind, id)
    if not bundle then return nil end
    for _, e in ipairs(bundle.events) do
        if e.t == kind and e.id == id then return e end
    end
    return nil
end

-- enter a player and discard the snapshot return.
local function enter(zone, pid, x, y)
    return zone:enter(pid, route_of(pid), { x = x, y = y })
end

-- ----- geometry -----

spec.describe('zone_def geometry', function()
    spec.it('maps world coords to zone-local grid coords', function()
        local gx, gy = zone_def.pos_to_grid(10, 10)
        spec.equal(gx, 0); spec.equal(gy, 0)
        gx, gy = zone_def.pos_to_grid(40, 10)
        spec.equal(gx, 1); spec.equal(gy, 0)
        gx, gy = zone_def.pos_to_grid(100, 200)
        spec.equal(gx, 3); spec.equal(gy, 6)
    end)

    spec.it('keeps grid coords zone-local across zone boundaries', function()
        -- a point one zone to the right has the same local grid as the origin
        local gx0, gy0 = zone_def.pos_to_grid(10, 10)
        local gx1, gy1 = zone_def.pos_to_grid(zone_def.ZONE_SIZE + 10, 10)
        spec.equal(gx0, gx1); spec.equal(gy0, gy1)
    end)

    spec.it('numbers zones row-major, 1-based', function()
        spec.equal(zone_def.world_to_zone(10, 10), 1)
        spec.equal(zone_def.world_to_zone(zone_def.ZONE_SIZE + 10, 10), 2)
        spec.equal(zone_def.world_to_zone(10, zone_def.ZONE_SIZE + 10),
            zone_def.WORLD_COLS + 1)
    end)

    spec.it('returns a 3x3 neighbour block', function()
        spec.equal(#zone_def.neighbors9(5, 5), 9)
    end)

    spec.it('resolves zone owner by hash, honouring overrides', function()
        local g, l = zone_def.resolve_zone_owner(1)
        spec.equal(g, 1); spec.equal(l, 1)
        zone_def.zone_owner_override[7] = { 1, 3 }
        g, l = zone_def.resolve_zone_owner(7)
        spec.equal(g, 1); spec.equal(l, 3)
        zone_def.zone_owner_override[7] = nil
    end)
end)

-- ----- enter / visibility -----

spec.describe('zone enter and visibility', function()
    spec.it('two nearby players see each other', function()
        local z = Zone.new(1)
        local s1 = enter(z, 1, 10, 10)      -- alone -> empty snapshot
        spec.equal(#s1, 0)
        local s2 = enter(z, 2, 20, 20)      -- same cell -> sees p1
        spec.equal(#s2, 1)
        spec.equal(s2[1].id, 1)

        local got = drain(z)
        spec.equal(count_kind(got[1], Zone.EV_ENTER), 1)
        spec.truthy(find_event(got[1], Zone.EV_ENTER, 2),
            'p1 should be told p2 entered')
    end)

    spec.it('far-apart players do not see each other', function()
        local z = Zone.new(1)
        enter(z, 1, 10, 10)                  -- grid (0,0)
        local s2 = enter(z, 2, 500, 500)     -- grid (15,15) -- out of range
        spec.equal(#s2, 0)
        local got = drain(z)
        spec.nil_value(got[1], 'p1 should receive nothing')
    end)

    spec.it('counts subscribers', function()
        local z = Zone.new(1)
        enter(z, 1, 10, 10)
        enter(z, 2, 20, 20)
        spec.equal(z:subscriber_count(), 2)
    end)
end)

-- ----- movement -----

spec.describe('zone movement deltas', function()
    spec.it('same-cell move emits MOVE to watchers', function()
        local z = Zone.new(1)
        enter(z, 1, 10, 10)
        enter(z, 2, 20, 20)
        drain(z)                              -- clear enter events
        z:move(1, { x = 25, y = 25 })         -- still grid (0,0)
        local got = drain(z)
        local mv = find_event(got[2], Zone.EV_MOVE, 1)
        spec.truthy(mv, 'p2 should see p1 move')
        spec.equal(mv.x, 25); spec.equal(mv.y, 25)
    end)

    spec.it('cross-cell move INTO view emits ENTER both ways', function()
        local z = Zone.new(1)
        enter(z, 1, 10, 10)                   -- grid (0,0)
        enter(z, 2, 100, 10)                  -- grid (3,0) -- out of range
        drain(z)
        z:move(2, { x = 40, y = 10 })         -- grid (1,0) -- now adjacent
        local got = drain(z)
        spec.truthy(find_event(got[1], Zone.EV_ENTER, 2),
            'p1 should gain p2')
        spec.truthy(find_event(got[2], Zone.EV_ENTER, 1),
            'mover p2 should gain p1')
    end)

    spec.it('cross-cell move OUT of view emits LEAVE both ways', function()
        local z = Zone.new(1)
        enter(z, 1, 10, 10)                   -- grid (0,0)
        enter(z, 2, 40, 10)                   -- grid (1,0) -- adjacent/visible
        drain(z)
        z:move(2, { x = 100, y = 10 })        -- grid (3,0) -- out of range
        local got = drain(z)
        spec.truthy(find_event(got[1], Zone.EV_LEAVE, 2),
            'p1 should lose p2')
        spec.truthy(find_event(got[2], Zone.EV_LEAVE, 1),
            'mover p2 should lose p1')
    end)

    spec.it('move on a non-subscriber is a no-op', function()
        local z = Zone.new(1)
        z:move(99, { x = 1, y = 1 })
        local got = drain(z)
        spec.nil_value(next(got), 'no events for unknown player')
    end)
end)

-- ----- leave -----

spec.describe('zone leave', function()
    spec.it('notifies remaining watchers and drops the subscriber', function()
        local z = Zone.new(1)
        enter(z, 1, 10, 10)
        enter(z, 2, 20, 20)
        drain(z)
        z:leave(2)
        local got = drain(z)
        spec.truthy(find_event(got[1], Zone.EV_LEAVE, 2),
            'p1 should be told p2 left')
        spec.equal(z:subscriber_count(), 1)
    end)
end)

-- ----- seq ordering -----

spec.describe('zone seq', function()
    spec.it('increases monotonically across operations', function()
        local z = Zone.new(1)
        local s0 = z.seq
        enter(z, 1, 10, 10)
        enter(z, 2, 20, 20)
        z:move(1, { x = 25, y = 25 })
        z:leave(2)
        spec.truthy(z.seq > s0, 'seq must advance')
        spec.equal(z.seq, s0 + 4)
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
