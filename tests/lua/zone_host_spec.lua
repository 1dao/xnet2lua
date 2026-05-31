-- Integration specs for scripts/game/zone_host.lua: the per-lane AOI
-- coordinator. Wires several hosts (one per lane, single game) through an
-- in-memory bus so the cross-lane routing, snapshot/delta delivery, the §7.3
-- staleness guard, and cross-zone transitions are validated end-to-end without
-- any networking. Run via: bin/xnet tests/lua/zone_host_spec.lua

local spec = dofile('tests/lua/spec_helper.lua')
local zone_def = dofile('scripts/game/zone_def.lua')
local Zone = dofile('scripts/game/zone.lua')
local Host = dofile('scripts/game/zone_host.lua')

-- Build a single-game world: one host per lane, connected by a synchronous bus.
-- Returns (hosts, client_log). client_log[sid] is the ordered list of messages
-- delivered to that client: { kind, zone_id, seq, payload }.
local function build_world()
    local hosts = {}
    local client_log = {}
    local function post(_game, lane, msg, ...)
        hosts[lane]:recv(msg, ...)
    end
    local function to_client(sid, kind, zone_id, seq, payload)
        local q = client_log[sid]
        if not q then q = {}; client_log[sid] = q end
        q[#q + 1] = { kind = kind, zone_id = zone_id, seq = seq, payload = payload }
    end
    for lane = 1, zone_def.LANE_COUNT do
        hosts[lane] = Host.new({ game = 1, lane = lane, post = post, to_client = to_client })
    end
    return hosts, client_log
end

local function clear(client_log)
    for k in pairs(client_log) do client_log[k] = nil end
end

local function last_msg(client_log, sid, kind)
    local q = client_log[sid]
    if not q then return nil end
    for i = #q, 1, -1 do
        if (not kind) or q[i].kind == kind then return q[i] end
    end
    return nil
end

local function payload_has_id(payload, id)         -- snapshot entry {id,x,y}
    for _, e in ipairs(payload) do if e.id == id then return e end end
    return nil
end

local function delta_has(payload, t, id)           -- delta event {t,id,x,y}
    for _, e in ipairs(payload) do if e.t == t and e.id == id then return e end end
    return nil
end

-- Positions: zone 3 is x in [2048,3072) (owner lane 3); zone 4 is x in
-- [3072,4096) (owner lane 4). Players A/B are homed on lanes 1/2 so home lane
-- and zone owner lane are always distinct -> exercises real cross-lane routing.
local A, B = 101, 102
local function spawn_AB(hosts)
    hosts[1]:spawn_player(A, A, { x = 2058, y = 10 })   -- zone 3, grid (0,0)
    hosts[2]:spawn_player(B, B, { x = 2068, y = 20 })   -- zone 3, grid (0,0)
end

spec.describe('zone_host owner resolution', function()
    spec.it('routes a zone to the expected lane', function()
        local g, l = zone_def.resolve_zone_owner(3)
        spec.equal(g, 1); spec.equal(l, 3)
        g, l = zone_def.resolve_zone_owner(4)
        spec.equal(g, 1); spec.equal(l, 4)
    end)
end)

spec.describe('zone_host spawn + snapshot', function()
    spec.it('delivers a snapshot of existing players to a newcomer', function()
        local hosts, log = build_world()
        spawn_AB(hosts)
        local sa = last_msg(log, A, 'snapshot')
        local sb = last_msg(log, B, 'snapshot')
        spec.truthy(sa, 'A got a snapshot')
        spec.equal(#sa.payload, 0)                       -- A entered an empty zone
        spec.truthy(sb, 'B got a snapshot')
        spec.truthy(payload_has_id(sb.payload, A), 'B snapshot includes A')
    end)

    spec.it('pushes an ENTER delta to the incumbent on next tick', function()
        local hosts, log = build_world()
        spawn_AB(hosts)
        clear(log)
        hosts[3]:tick()                                  -- zone 3 owner flushes
        local d = last_msg(log, A, 'delta')
        spec.truthy(d, 'A got a delta')
        spec.truthy(delta_has(d.payload, Zone.EV_ENTER, B), 'A sees B enter')
    end)
end)

spec.describe('zone_host movement', function()
    spec.it('relays a same-cell move as MOVE across lanes', function()
        local hosts, log = build_world()
        spawn_AB(hosts)
        hosts[3]:tick()
        clear(log)
        hosts[2]:client_move(B, { x = 2078, y = 20 })    -- still zone 3, grid (0,0)
        hosts[3]:tick()
        local d = last_msg(log, A, 'delta')
        local mv = d and delta_has(d.payload, Zone.EV_MOVE, B)
        spec.truthy(mv, 'A sees B move')
        spec.equal(mv.x, 2078)
    end)
end)

spec.describe('zone_host cross-zone transition', function()
    spec.it('LEAVEs the old zone watchers and SNAPSHOTs the new zone', function()
        local hosts, log = build_world()
        spawn_AB(hosts)
        hosts[3]:tick()
        clear(log)
        hosts[1]:client_move(A, { x = 3082, y = 10 })    -- zone 3 -> zone 4
        hosts[3]:tick()                                  -- old owner flushes LEAVE
        -- B (still in zone 3) is told A left
        local db = last_msg(log, B, 'delta')
        spec.truthy(db and delta_has(db.payload, Zone.EV_LEAVE, A), 'B sees A leave')
        -- A receives a fresh snapshot for zone 4
        local sa = last_msg(log, A, 'snapshot')
        spec.truthy(sa, 'A got a new snapshot')
        spec.equal(sa.zone_id, 4)
    end)
end)

spec.describe('zone_host staleness guard (design §7.3)', function()
    spec.it('drops a delta tagged with a zone the player already left', function()
        local hosts, log = build_world()
        spawn_AB(hosts)
        hosts[1]:client_move(A, { x = 3082, y = 10 })    -- A now in zone 4
        clear(log)
        -- a late delta from the old zone 3 arrives at A's home lane
        hosts[1]:recv('aoi_in', A, 'delta', 3, 9999, { { t = Zone.EV_MOVE, id = B } })
        spec.nil_value(last_msg(log, A), 'stale-zone delta must be dropped')
    end)

    spec.it('drops an out-of-order (<= last_seq) delta for the current zone', function()
        local hosts, log = build_world()
        spawn_AB(hosts)
        -- A's snapshot set last_seq[zone3]; replay a delta at seq 0
        clear(log)
        local cur = hosts[1].players[A].current_zone
        hosts[1]:recv('aoi_in', A, 'delta', cur, 0, { { t = Zone.EV_MOVE, id = B } })
        spec.nil_value(last_msg(log, A), 'stale-seq delta must be dropped')
    end)
end)

spec.describe('zone_host despawn', function()
    spec.it('notifies remaining watchers when a player goes offline', function()
        local hosts, log = build_world()
        spawn_AB(hosts)
        hosts[3]:tick()
        clear(log)
        hosts[2]:despawn_player(B)
        hosts[3]:tick()
        local d = last_msg(log, A, 'delta')
        spec.truthy(d and delta_has(d.payload, Zone.EV_LEAVE, B), 'A sees B despawn')
    end)
end)

-- The logout-position read the battle lane hands to the work lane for the §19.1.4
-- write-through. It must reflect the LIVE position (post-move), and must be nil
-- for a player who is not home here (so the work lane skips the persist).
spec.describe('zone_host player_pos (§19.1.4 logout location)', function()
    spec.it('returns the live position, tracking moves', function()
        local hosts = build_world()
        spawn_AB(hosts)
        local pos = hosts[1]:player_pos(A)
        spec.truthy(pos, 'A has a resident position')
        spec.equal(pos.x, 2058); spec.equal(pos.y, 10)
        hosts[1]:client_move(A, { x = 2078, y = 11 })       -- same zone, grid (0,0)
        local moved = hosts[1]:player_pos(A)
        spec.equal(moved.x, 2078); spec.equal(moved.y, 11)
    end)

    spec.it('returns nil for a player not home on this lane', function()
        local hosts = build_world()
        spawn_AB(hosts)
        spec.nil_value(hosts[2]:player_pos(A), 'A is home on lane 1, not lane 2')
        hosts[1]:despawn_player(A)
        spec.nil_value(hosts[1]:player_pos(A), 'a despawned player has no position')
    end)
end)

-- ----- v2-facing seam: subscriber home update (design §19.1 hook 5) -----
--
-- This is NOT a v1 feature: v1 never migrates a player, so update_subscriber_home
-- has no v1 caller. The test drives the seam directly to prove that IF a future v2
-- swaps the owner's cached route, the AOI fan-out re-addresses to the NEW home
-- game+lane with NO change to zone.lua. The single-game build_world bus ignores
-- `game`, so this test uses a bus that records each post's full {game, lane}
-- address and proves A's delta now targets game 2.

spec.describe('zone_host subscriber home update', function()
    spec.it('reroutes a migrated subscriber AOI to its new home game/lane', function()
        local hosts, posts = {}, {}
        local function post(game, lane, msg, ...)
            posts[#posts + 1] = { game = game, lane = lane, msg = msg, a = { ... } }
            if game == 1 and hosts[lane] then hosts[lane]:recv(msg, ...) end
        end
        local function to_client() end
        for lane = 1, zone_def.LANE_COUNT do
            hosts[lane] = Host.new({ game = 1, lane = lane, post = post, to_client = to_client })
        end
        hosts[1]:spawn_player(A, A, { x = 2058, y = 10 })   -- zone 3, home lane 1
        hosts[2]:spawn_player(B, B, { x = 2068, y = 20 })   -- zone 3, home lane 2

        -- A migrates home {game1,lane1} -> {game2,lane5}; only the zone owner's
        -- cached route record changes -- zone.lua internals stay untouched.
        local ret = hosts[3]:update_subscriber_home(3, A, { home_game = 2, home_lane = 5, sid = A })
        spec.truthy(ret, 'owner returns the swapped route')
        spec.equal(ret.home_game, 2)

        posts = {}                                          -- drop spawn/enter traffic
        hosts[2]:client_move(B, { x = 2078, y = 20 })       -- same cell -> MOVE to A
        hosts[3]:tick()                                     -- zone 3 owner flushes

        local aoi
        for _, p in ipairs(posts) do
            if p.msg == 'aoi_in' and p.a[1] == A then aoi = p end
        end
        spec.truthy(aoi, 'A\'s AOI delta was posted')
        spec.equal(aoi.game, 2, 'delta now routed to the migrated home game')
        spec.equal(aoi.lane, 5, 'delta now routed to the migrated home lane')
    end)

    spec.it('returns nil when this lane does not own the zone', function()
        local hosts = build_world()                          -- lane 1 != zone-3 owner
        spec.nil_value(hosts[1]:update_subscriber_home(3, A,
            { home_game = 2, home_lane = 5, sid = A }),
            'a non-owner has no subscription to migrate')
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
