-- Integration spec for cross-process combat (design §7.4 / §9). Two games, six
-- lanes, the same in-memory bus as border_aoi_spec: a same-game cross-lane hop is
-- a direct table call; a cross-game hop is serialized through peer_codec so the
-- COMBAT wire format is exercised end to end. wire.crossings counts game-boundary
-- hops, proving the flow really left the process.
--
-- Covers the two authority rules the design hinges on:
--   * player -> NPC : the ZONE OWNER settles (the NPC lives in its lane). §7.4.A
--   * player -> player : the TARGET's home_lane settles (only it may write the
--                        target's hp), validating range from the AOI-cached
--                        last-known position. §9.1
--
-- Run via: bin/xnet tests/lua/combat_flow_spec.lua

local spec = dofile('tests/lua/spec_helper.lua')
local zone_def = dofile('scripts/game/zone_def.lua')
local Host = dofile('scripts/game/zone_host.lua')
local peer_codec = dofile('scripts/game/peer_codec.lua')

local unpack_args = table.unpack or unpack

local GAMES, LANES = 2, 6
Host.configure({ game_count = GAMES, lane_count = LANES })
zone_def.GAME_COUNT = GAMES
zone_def.LANE_COUNT = LANES

-- Same bus as peer_mesh_spec / border_aoi_spec.
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

-- Spawn a player on its REAL hashed home lane, so cross-player combat routing
-- (which re-derives the home from the id) actually lands on it. Returns the pid.
local function spawn_at_home(hosts, pid, pos)
    local g, l = zone_def.resolve_player_home(pid)
    hosts[g][l]:spawn_player(pid, pid, pos)
    return pid
end

-- Find the lowest pid >= start whose home game is `game` (lane is whatever the
-- hash lands on). Lets a test place an attacker and a target in different games.
local function pid_in_game(start, game)
    for pid = start, start + 200000 do
        if (select(1, zone_def.resolve_player_home(pid))) == game then
            return pid
        end
    end
    error('no pid found in game ' .. tostring(game))
end

local function owner_of(hosts, zone_id)
    local g, l = zone_def.resolve_zone_owner(zone_id)
    return hosts[g][l], g, l
end

local function combat_events(log, sid, inner_kind)
    local q = log[sid]
    if not q then return {} end
    local out = {}
    for i = 1, #q do
        local e = q[i]
        if e.kind == 'combat' and type(e.payload) == 'table'
        and e.payload.kind == inner_kind then
            out[#out + 1] = e.payload
        end
    end
    return out
end

local function last_combat(log, sid, inner_kind)
    local list = combat_events(log, sid, inner_kind)
    return list[#list]
end

spec.describe('player attacks NPC across the game boundary (§7.4.A)', function()
    -- zone 2 is owned by game 2; the attacker homes in game 1, so the attack and
    -- every result ride the peer wire.
    local ZONE = 2
    local NPC_ID = 901
    local NPC_X, NPC_Y = zone_def.ZONE_SIZE + 24, 22     -- zone 2, grid (0,0)
    local ATTACKER = 4001

    spec.it('settles on the zone owner and bills the attacker', function()
        local hosts, log, wire = build_world()
        local owner = owner_of(hosts, ZONE)
        owner:spawn_npc(ZONE, NPC_ID, NPC_X, NPC_Y, 50)
        -- attacker stands in the same cell as the npc
        hosts[1][3]:spawn_player(ATTACKER, ATTACKER,
            { x = zone_def.ZONE_SIZE + 20, y = 20 })

        hosts[1][3]:client_attack_npc(ATTACKER, NPC_ID, 1)   -- melee, dmg 12

        local dmg = last_combat(log, ATTACKER, 'damage')
        spec.truthy(dmg, 'attacker receives a DAMAGE_DEALT number')
        spec.equal(dmg.damage, 12)
        spec.equal(dmg.target_hp, 38, 'npc hp 50 -> 38 settled on the owner')
        spec.truthy(last_combat(log, ATTACKER, 'fx'), 'attacker also sees the hit fx')
        spec.equal(owner.zones[ZONE]:npc(NPC_ID).hp, 38, 'authoritative npc hp dropped')
        spec.truthy(wire.crossings > 0, 'the PvE flow crossed the game boundary')
    end)

    spec.it('rejects an out-of-range hit (no damage, no hp change)', function()
        local hosts, log = build_world()
        local owner = owner_of(hosts, ZONE)
        owner:spawn_npc(ZONE, NPC_ID, NPC_X, NPC_Y, 50)
        -- attacker is in zone 2 but far from the npc cell
        hosts[1][5]:spawn_player(ATTACKER, ATTACKER,
            { x = zone_def.ZONE_SIZE + 500, y = 500 })

        hosts[1][5]:client_attack_npc(ATTACKER, NPC_ID, 1)

        spec.equal(#combat_events(log, ATTACKER, 'damage'), 0,
            'an out-of-range swing settles nothing')
        spec.equal(owner.zones[ZONE]:npc(NPC_ID).hp, 50, 'npc hp untouched')
    end)
end)

spec.describe('player attacks player across the game boundary (§9.1)', function()
    spec.it('the target home settles hp; both sides see the result', function()
        local hosts, log, wire = build_world()
        local p1 = pid_in_game(5000, 1)        -- attacker homes in game 1
        local p2 = pid_in_game(5000, 2)        -- target homes in game 2
        spec.truthy(p1 ~= p2, 'distinct players in distinct games')

        spawn_at_home(hosts, p1, { x = 20, y = 20 })   -- zone 1, grid (0,0)
        spawn_at_home(hosts, p2, { x = 28, y = 20 })   -- same cell -> mutually seen

        hosts[(select(1, zone_def.resolve_player_home(p1)))]
            [(select(2, zone_def.resolve_player_home(p1)))]
            :client_attack_player(p1, p2, 1)           -- melee, dmg 12

        -- target's own client gets the authoritative hp update
        local hp = last_combat(log, p2, 'hp')
        spec.truthy(hp, 'target receives an authoritative hp update')
        spec.equal(hp.damage, 12)
        spec.equal(hp.hp, 88, 'target hp 100 -> 88, written only by its home lane')
        -- attacker gets the floating number
        local dmg = last_combat(log, p1, 'damage')
        spec.truthy(dmg, 'attacker receives the damage number')
        spec.equal(dmg.damage, 12)
        -- both nearby players see the fx the zone owner broadcast
        spec.truthy(last_combat(log, p1, 'fx'), 'attacker sees the hit fx')
        spec.truthy(last_combat(log, p2, 'fx'), 'target sees the hit fx')
        spec.truthy(wire.crossings > 0, 'the PvP flow crossed the game boundary')
    end)

    spec.it('rejects an attacker the target has never seen', function()
        local hosts, log = build_world()
        local target = pid_in_game(5000, 2)
        local ghost_attacker = pid_in_game(9000, 1)
        spawn_at_home(hosts, target, { x = 28, y = 20 })        -- zone 1, grid (0,0)
        spawn_at_home(hosts, ghost_attacker, { x = 300, y = 300 }) -- grid (9,9), unseen

        local g, l = zone_def.resolve_player_home(ghost_attacker)
        hosts[g][l]:client_attack_player(ghost_attacker, target, 1)

        spec.equal(#combat_events(log, target, 'hp'), 0,
            'no hp write: the authority never saw the attacker')
        spec.equal(#combat_events(log, ghost_attacker, 'damage'), 0,
            'and no damage number for the unseen swing')
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
