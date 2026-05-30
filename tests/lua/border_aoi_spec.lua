-- Integration spec for cross-zone border AOI (design §8.4): two adjacent zones,
-- owned by DIFFERENT games, "stitched" along their shared edge. A player sitting
-- on the edge of zone 1 and a player on the edge of zone 2 are within AOI range
-- across the boundary, even though neither zone owner knows the other's
-- subscribers. The border-subscription mechanism (edge egress -> neighbour ghost
-- injection) must make them see each other, and -- because the two zones live in
-- different games -- every border hop is serialized through peer_codec, exactly
-- as it would ride the diagonal TCP link.
--
-- This is the "两块拼起来的地图" integration test the design suggests for Stage 5.
-- Run via: bin/xnet tests/lua/border_aoi_spec.lua

local spec = dofile('tests/lua/spec_helper.lua')
local zone_def = dofile('scripts/game/zone_def.lua')
local Zone = dofile('scripts/game/zone.lua')
local Host = dofile('scripts/game/zone_host.lua')
local peer_codec = dofile('scripts/game/peer_codec.lua')

local unpack_args = table.unpack or unpack

local GAMES = 2
local LANES = 6
Host.configure({ game_count = GAMES, lane_count = LANES })
zone_def.GAME_COUNT = GAMES
zone_def.LANE_COUNT = LANES

-- Same in-memory bus as peer_mesh_spec: same-game cross-lane is a direct table
-- call; a cross-game hop is serialized through peer_codec so the wire format is
-- exercised end to end. wire.crossings counts game-boundary hops.
local function build_world()
    local hosts = {}
    local client_log = {}
    local wire = { crossings = 0 }

    local function to_client(sid, kind, zone_id, seq, payload)
        local q = client_log[sid]
        if not q then q = {}; client_log[sid] = q end
        q[#q + 1] = { kind = kind, zone_id = zone_id, seq = seq, payload = payload }
    end

    local function make_post(src_game)
        return function(game, lane, msg, ...)
            local target = hosts[game] and hosts[game][lane]
            if not target then return end
            if game == src_game then
                target:recv(msg, ...)
                return
            end
            wire.crossings = wire.crossings + 1
            local frame = assert(peer_codec.encode_host_msg(lane, lane, msg, ...))
            local _hdr, body = peer_codec.decode_header(frame)
            local vals = peer_codec.unpack_body(body)
            target:recv(unpack_args(vals, 1, vals.n))
        end
    end

    for g = 1, GAMES do
        hosts[g] = {}
        for l = 1, LANES do
            hosts[g][l] = Host.new({
                game = g, lane = l, post = make_post(g), to_client = to_client,
            })
        end
    end
    return hosts, client_log, wire
end

-- Tick every owned lane a few rounds so border ghosts propagate both ways. One
-- round carries an egress to the neighbour and flushes the resulting ghost delta;
-- the reverse direction needs the following round.
local function tick_world(hosts, rounds)
    for _ = 1, (rounds or 3) do
        for g = 1, GAMES do
            for l = 1, LANES do hosts[g][l]:tick() end
        end
    end
end

local function last_delta(client_log, sid)
    local q = client_log[sid]
    if not q then return nil end
    for i = #q, 1, -1 do if q[i].kind == 'delta' then return q[i] end end
    return nil
end

local function any_event(client_log, sid, t, id)
    local q = client_log[sid]
    if not q then return nil end
    for i = #q, 1, -1 do
        for _, e in ipairs(q[i].payload) do
            if e.t == t and e.id == id then return e end
        end
    end
    return nil
end

-- Positions: A is on the right edge of zone 1 (gx=31), B on the left edge of
-- zone 2 (gx=0). Globally they are one grid apart -> within AOI range. Zone 1 is
-- owned by (game 1, lane 1); zone 2 by (game 2, lane 2): the border is a peer hop.
local A, B = 301, 302
local A_X, A_Y = (zone_def.GRIDS_PER_ZONE - 1) * zone_def.GRID_SIZE + 8, 100   -- zone 1
local B_X, B_Y = zone_def.ZONE_SIZE + 8, 100                                    -- zone 2

spec.describe('border AOI: zones stitched across a game boundary', function()
    spec.it('confirms the two zones are adjacent and owned by different games', function()
        spec.equal(zone_def.world_to_zone(A_X, A_Y), 1, 'A is in zone 1')
        spec.equal(zone_def.world_to_zone(B_X, B_Y), 2, 'B is in zone 2')
        spec.equal(zone_def.neighbor_zone(1, 1, 0), 2, 'zone 2 is east of zone 1')
        local g1 = select(1, zone_def.resolve_zone_owner(1))
        local g2 = select(1, zone_def.resolve_zone_owner(2))
        spec.truthy(g1 ~= g2, 'the two zone owners are in different games')
    end)

    spec.it('lets a player see a neighbour-zone player across the border', function()
        local hosts, log, wire = build_world()
        -- home lanes (3,4) are distinct from both zone owners (1,2), so every hop
        -- -- enter, snapshot, border ghost, delta -- exercises real routing.
        hosts[1][3]:spawn_player(A, A, { x = A_X, y = A_Y })   -- home (1,3), zone 1
        hosts[1][4]:spawn_player(B, B, { x = B_X, y = B_Y })   -- home (1,4), zone 2
        tick_world(hosts)

        spec.truthy(any_event(log, B, Zone.EV_ENTER, A), 'B sees A across the border')
        spec.truthy(any_event(log, A, Zone.EV_ENTER, B), 'A sees B across the border')
        spec.truthy(wire.crossings > 0, 'border traffic crossed the game boundary')

        -- the ghost the client learns about carries the foreign world position.
        local seen_a = any_event(log, B, Zone.EV_ENTER, A)
        spec.equal(seen_a.x, A_X, 'B learns A\'s real x')
    end)

    spec.it('relays a cross-border MOVE as a ghost update', function()
        local hosts, log = build_world()
        hosts[1][3]:spawn_player(A, A, { x = A_X, y = A_Y })
        hosts[1][4]:spawn_player(B, B, { x = B_X, y = B_Y })
        tick_world(hosts)
        for k in pairs(log) do log[k] = nil end

        -- A slides along the edge (same cell, still zone 1) -> B should see a MOVE.
        hosts[1][3]:client_move(A, { x = A_X + 4, y = A_Y + 3 })
        tick_world(hosts)

        local mv = any_event(log, B, Zone.EV_MOVE, A)
        spec.truthy(mv, 'B sees A move across the border')
        spec.equal(mv.x, A_X + 4)
    end)

    spec.it('retracts the ghost when the border player leaves', function()
        local hosts, log = build_world()
        hosts[1][3]:spawn_player(A, A, { x = A_X, y = A_Y })
        hosts[1][4]:spawn_player(B, B, { x = B_X, y = B_Y })
        tick_world(hosts)
        for k in pairs(log) do log[k] = nil end

        hosts[1][3]:despawn_player(A)        -- A logs off
        tick_world(hosts)

        spec.truthy(any_event(log, B, Zone.EV_LEAVE, A),
            'B sees A leave when A despawns across the border')
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
