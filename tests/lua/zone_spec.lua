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

-- ----- cross-zone border: ghosts + egress (design §8.4) -----

-- right-edge cell of a zone is gx = GRIDS_PER_ZONE-1; pick a world x inside it.
local EDGE_X = (zone_def.GRIDS_PER_ZONE - 1) * zone_def.GRID_SIZE + 1   -- gx=31
local NEXT_X = zone_def.ZONE_SIZE + 1                                   -- next zone, gx=0

local function find_egress(list, ev, dgx, dgy, id)
    for _, e in ipairs(list) do
        if e.ev == ev and e.dgx == dgx and e.dgy == dgy and e.id == id then
            return e
        end
    end
    return nil
end

spec.describe('zone border egress', function()
    spec.it('announces an edge entity to the neighbour direction', function()
        local z = Zone.new(1)
        enter(z, 1, EDGE_X, 100)              -- right edge of zone 1
        local out = z:drain_border()
        spec.truthy(find_egress(out, 'enter', 1, 0, 1),
            'right-edge entity egresses east (dgx=1)')
    end)

    spec.it('does not announce an interior entity', function()
        local z = Zone.new(1)
        enter(z, 1, 500, 500)                 -- grid (15,15) -- fully interior
        spec.equal(#z:drain_border(), 0)
    end)

    spec.it('emits a leave egress when an edge entity leaves', function()
        local z = Zone.new(1)
        enter(z, 1, EDGE_X, 100)
        z:drain_border()                      -- clear the enter egress
        z:leave(1)
        spec.truthy(find_egress(z:drain_border(), 'leave', 1, 0, 1),
            'leaving an edge cell retracts the ghost east')
    end)
end)

spec.describe('zone ghost injection', function()
    spec.it('makes a foreign entity visible to a border watcher', function()
        local z = Zone.new(1)
        enter(z, 1, EDGE_X, 100)              -- local player on the right edge
        drain(z)
        z:ghost_set(99, NEXT_X, 100)          -- foreign entity just across border
        local got = drain(z)
        spec.truthy(find_event(got[1], Zone.EV_ENTER, 99),
            'border watcher should see the ghost enter')
    end)

    spec.it('tracks ghost move then remove', function()
        local z = Zone.new(1)
        enter(z, 1, EDGE_X, 100)
        z:ghost_set(99, NEXT_X, 100)
        drain(z)
        z:ghost_set(99, NEXT_X + 2, 105)      -- same ghost cell -> MOVE
        local got = drain(z)
        local mv = find_event(got[1], Zone.EV_MOVE, 99)
        spec.truthy(mv, 'ghost move reaches the watcher')
        spec.equal(mv.x, NEXT_X + 2)
        z:ghost_remove(99)
        spec.truthy(find_event(drain(z)[1], Zone.EV_LEAVE, 99),
            'ghost remove reaches the watcher')
    end)

    spec.it('includes a pre-existing ghost in a new entrant snapshot', function()
        local z = Zone.new(1)
        z:ghost_set(99, NEXT_X, 100)          -- ghost present before anyone enters
        local snap = enter(z, 1, EDGE_X, 100) -- enters into its view
        local seen = false
        for _, e in ipairs(snap) do if e.id == 99 then seen = true end end
        spec.truthy(seen, 'snapshot should carry the visible ghost')
    end)

    spec.it('does not show a ghost to an interior player', function()
        local z = Zone.new(1)
        enter(z, 1, 500, 500)                 -- interior; far from the border
        drain(z)
        z:ghost_set(99, NEXT_X, 100)
        spec.nil_value(drain(z)[1], 'interior player must not see the ghost')
    end)
end)

-- ----- NPC combat: zone owner authority (design §7.4.A / §7.5) -----

-- A skill_def is just { range, damage }; zone.lua never reaches into combat.lua.
local MELEE = { range = 48, damage = 12 }

spec.describe('zone NPC combat', function()
    spec.it('settles an in-range hit and returns the fx audience', function()
        local z = Zone.new(1)
        enter(z, 1, 20, 20)                   -- attacker, grid (0,0)
        z:spawn_npc(901, 24, 22, 50)          -- npc in the same cell
        local r, fx = z:attack_npc(1, 901, MELEE)
        spec.truthy(r.ok, 'the hit lands')
        spec.equal(r.damage, 12)
        spec.equal(r.npc_hp, 38)
        spec.truthy(not r.dead, 'npc survives')
        spec.equal(r.attacker_route.sid, 1, 'attacker route carried back for DAMAGE_DEALT')
        local seen = false
        for _, w in ipairs(fx) do if w.pid == 1 then seen = true end end
        spec.truthy(seen, 'attacker is part of the fx audience')
    end)

    spec.it('rejects an out-of-range hit and leaves hp intact', function()
        local z = Zone.new(1)
        enter(z, 1, 20, 20)
        z:spawn_npc(901, 500, 500, 50)        -- far across the zone
        local r = z:attack_npc(1, 901, MELEE)
        spec.truthy(not r.ok)
        spec.equal(r.reason, 'out_of_range')
        spec.equal(z:npc(901).hp, 50, 'a miss never touches hp')
    end)

    spec.it('rejects a hit from a non-subscriber', function()
        local z = Zone.new(1)
        z:spawn_npc(901, 20, 20, 50)
        local r = z:attack_npc(42, 901, MELEE)
        spec.truthy(not r.ok)
        spec.equal(r.reason, 'no_attacker')
    end)

    spec.it('marks the npc dead, clamps hp at 0, and refuses a second hit', function()
        local z = Zone.new(1)
        enter(z, 1, 20, 20)
        z:spawn_npc(901, 24, 22, 10)          -- one 12-dmg melee kills it
        local r = z:attack_npc(1, 901, MELEE)
        spec.truthy(r.dead, 'npc dies')
        spec.equal(r.npc_hp, 0, 'hp clamped at 0, never negative')
        local again = z:attack_npc(1, 901, MELEE)
        spec.truthy(not again.ok, 'a corpse cannot be hit')
        spec.equal(again.reason, 'no_npc')
    end)
end)

-- ----- v2-facing seam: subscriber home update (design §19.1 hook 5) -----
--
-- This is NOT a v1 feature: v1 never migrates a player, so update_route has no v1
-- caller. The test drives the seam directly to prove that IF a future v2 swaps the
-- cached route, the subscriber's deltas re-address to the new home with no change
-- to any zone logic -- and that nothing else is required of v1 but to store it.

spec.describe('zone subscriber home update', function()
    spec.it('reroutes a subscriber to its new home in place', function()
        local z = Zone.new(1)
        enter(z, 1, 10, 10)
        enter(z, 2, 20, 20)                 -- same cell: mutually visible
        drain(z)                            -- clear the enter events
        -- p1's home flips {1,1} -> {2,5}; the zone caches only the route, so
        -- swapping that record is the entire migration (no other code touched).
        local nr = { home_game = 2, home_lane = 5, sid = 1, id = 1 }
        spec.equal(z:update_route(1, nr), nr, 'returns the new route')
        z:move(2, { x = 25, y = 25 })       -- p1 should be told p2 moved
        local got = {}
        z:flush(function(route, _zid, _seq, events)
            got[route.id] = { route = route, events = events }
        end)
        spec.truthy(got[1], 'p1 still receives deltas after migration')
        spec.equal(got[1].route.home_game, 2, 'delta routed to the new home game')
        spec.equal(got[1].route.home_lane, 5, 'delta routed to the new home lane')
        spec.truthy(find_event(got[1], Zone.EV_MOVE, 2),
            'the delta content is unchanged by the reroute')
    end)

    spec.it('returns nil for a pid that is not subscribed here', function()
        local z = Zone.new(1)
        spec.nil_value(z:update_route(99, { home_game = 2, home_lane = 5, sid = 99 }),
            'nothing to migrate -> nil')
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
