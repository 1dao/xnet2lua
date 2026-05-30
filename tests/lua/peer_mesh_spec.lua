-- Integration spec for the cross-game peer path (design §6 + §14.3). It wires
-- TWO games' zone_hosts through an in-memory bus that mirrors battle_worker's
-- host_post: same-game cross-lane is delivered as a direct table call (the
-- xthread.post path), while a CROSS-GAME hop is serialized through peer_codec
-- (encode_host_msg -> decode_header -> unpack_body -> recv), exactly as it would
-- ride the diagonal TCP link. This proves the peer wire faithfully carries real
-- enter_zone / aoi_in traffic without any sockets.
--
-- Run via: bin/xnet tests/lua/peer_mesh_spec.lua

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

-- Build a two-game world. hosts[g][l] is the lane host. wire_log counts how many
-- messages crossed the game boundary (i.e. went through the peer codec).
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
                target:recv(msg, ...)                 -- same game: in-process post
                return
            end
            -- cross game: ride the peer wire (lane already aligned: src=dst=lane)
            wire.crossings = wire.crossings + 1
            local frame = assert(peer_codec.encode_host_msg(lane, lane, msg, ...))
            local hdr, body = peer_codec.decode_header(frame)
            assert(hdr, 'frame decodes')
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

local function last_msg(client_log, sid, kind)
    local q = client_log[sid]
    if not q then return nil end
    for i = #q, 1, -1 do
        if (not kind) or q[i].kind == kind then return q[i] end
    end
    return nil
end

local function payload_has_id(payload, id)
    for _, e in ipairs(payload) do if e.id == id then return e end end
    return nil
end

local function delta_has(payload, t, id)
    for _, e in ipairs(payload) do if e.t == t and e.id == id then return e end end
    return nil
end

-- zone 2 hashes to owner (game 2, lane 2) under (GAMES=2, LANES=6); positions
-- x in [1024,2048) land there. Both players are homed in game 1, so the zone
-- owner is always in the OTHER game -> every owner<->home hop is a peer hop.
local A, B = 201, 202

spec.describe('peer mesh: zone owned by a different game', function()
    spec.it('confirms the test topology really crosses the game boundary', function()
        local g, l = zone_def.resolve_zone_owner(2)
        spec.equal(g, 2, 'zone 2 owner game')
        spec.equal(l, 2, 'zone 2 owner lane')
    end)

    spec.it('delivers a cross-game snapshot that includes the incumbent', function()
        local hosts, log, wire = build_world()
        hosts[1][1]:spawn_player(A, A, { x = 1100, y = 10 })   -- home (1,1), zone 2
        hosts[1][2]:spawn_player(B, B, { x = 1110, y = 20 })   -- home (1,2), zone 2

        local sb = last_msg(log, B, 'snapshot')
        spec.truthy(sb, 'B got a snapshot over the peer wire')
        spec.equal(sb.zone_id, 2)
        spec.truthy(payload_has_id(sb.payload, A), 'B snapshot includes A')
        spec.truthy(wire.crossings > 0, 'traffic actually crossed games')
    end)

    spec.it('pushes a cross-game ENTER delta to the incumbent on tick', function()
        local hosts, log = build_world()
        hosts[1][1]:spawn_player(A, A, { x = 1100, y = 10 })
        hosts[1][2]:spawn_player(B, B, { x = 1110, y = 20 })
        -- clear snapshots
        for k in pairs(log) do log[k] = nil end

        hosts[2][2]:tick()                                     -- zone-2 owner flushes
        local d = last_msg(log, A, 'delta')
        spec.truthy(d, 'A got a delta back across the boundary')
        spec.truthy(delta_has(d.payload, Zone.EV_ENTER, B), 'A sees B enter')
    end)

    spec.it('relays a cross-game MOVE', function()
        local hosts, log = build_world()
        hosts[1][1]:spawn_player(A, A, { x = 1100, y = 10 })
        hosts[1][2]:spawn_player(B, B, { x = 1110, y = 20 })
        hosts[2][2]:tick()
        for k in pairs(log) do log[k] = nil end

        hosts[1][2]:client_move(B, { x = 1120, y = 20 })       -- same cell, zone 2
        hosts[2][2]:tick()
        local d = last_msg(log, A, 'delta')
        local mv = d and delta_has(d.payload, Zone.EV_MOVE, B)
        spec.truthy(mv, 'A sees B move across games')
        spec.equal(mv.x, 1120)
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
