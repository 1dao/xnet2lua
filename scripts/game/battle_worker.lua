-- scripts/game/battle_worker.lua -- one low-latency game battle lane.
--
-- This worker owns exactly one direct connection to its same-index gate lane.
-- Battle opcodes execute here; everything else is handed to a work worker.

local router = dofile('scripts/core/share/xrouter.lua')
local zone_host = dofile('scripts/game/zone_host.lua')
local peer_codec = dofile('scripts/game/peer_codec.lua')
router.set_log_prefix('GAME-BATTLE')

-- LuaJIT here exposes table.unpack, not the bare 5.1 global.
local unpack_args = table.unpack or unpack

function xthread.register(pt, h) return router.register(pt, h) end

local RECONNECT_MS = 2000
local INTERNAL_MAX_PAYLOAD = 65535 - 4 - 2
local FRAME_MS = 50                       -- AOI flush cadence (~20 Hz)
local OP_ECHO = 0x0001
local OP_ENTER_WORLD = 0x0002             -- client -> server: x(u32) y(u32)
local OP_MOVE = 0x0003                     -- client -> server: x(u32) y(u32)
local OP_AOI_SNAPSHOT = 0x0004             -- server -> client: full view
local OP_AOI_DELTA = 0x0005               -- server -> client: incremental view
local OP_ATTACK_NPC = 0x0006             -- client -> server: npc_id(u32) skill(u16)
local OP_ATTACK_PLAYER = 0x0007          -- client -> server: target(u32) skill(u16)
local OP_COMBAT_EVENT = 0x0008           -- server -> client: see encode_combat
local OP_SESSION_GONE = 0xFFFE
local GATE_ACK_BYTE = 0x01

local lane = 0
local lane_count = 0
local work_tid
local work_index = 0
local target_name
local target_host
local target_port
local gate_conn               -- ready for business (set when ACK received)
local gate_pending            -- channel mid-handshake (HELLO sent, no ACK)
local reconnect_timer
local gate_handler = {}

-- AOI: this lane is also a zone_host -- it owns home players whose home_lane is
-- this lane, plus any zones hashed to this lane (design §7/§8). The host is
-- transport-agnostic; the closures below wire it to xthread.post / the gate.
local my_game = 1
local battle_tids = {}        -- lane_idx -> tid (filled by 'battle_peers')
local host
local frame_timer

-- Peer mesh (§6): this lane holds one diagonal TCP link to the SAME lane index
-- in every other Game. Dialer side waits for ACK before it is "ready"; accept
-- side (fd handed over by main) is ready the moment it sends ACK.
local peer_conns = {}         -- peer_game_id -> conn (handshake complete)
local peer_pending = {}       -- peer_game_id -> conn (dialer, awaiting ACK)
local conn_peer_game = {}     -- conn -> peer_game_id

local function u16be(n)
    return string.char(math.floor(n / 256) % 256, n % 256)
end

local function r16be(s, i)
    local b1, b2 = string.byte(s, i, i + 1)
    return b1 * 256 + b2
end

local function u32be(n)
    return string.char(
        math.floor(n / 16777216) % 256,
        math.floor(n / 65536) % 256,
        math.floor(n / 256) % 256,
        n % 256)
end

local function r32be(s, i)
    local b1, b2, b3, b4 = string.byte(s, i, i + 3)
    return b1 * 16777216 + b2 * 65536 + b3 * 256 + b4
end

local function send_to_client(sid, opcode, payload)
    if not gate_conn then return false, 'gate down' end
    payload = payload or ''
    if #payload > INTERNAL_MAX_PAYLOAD then
        return false, 'payload too large'
    end
    return gate_conn:send(u32be(sid) .. u16be(opcode) .. payload)
end

-- ----- AOI wire codecs (server -> client) -----
-- snapshot: zone(u32) seq(u32) count(u16) then count*[id(u32) x(u32) y(u32)]
local function encode_snapshot(zone_id, seq, list)
    local parts = { u32be(zone_id), u32be(seq), u16be(#list) }
    for i = 1, #list do
        local e = list[i]
        parts[#parts + 1] = u32be(e.id) .. u32be(e.x) .. u32be(e.y)
    end
    return table.concat(parts)
end

-- delta: zone(u32) seq(u32) count(u16) then count*[type(u8) id(u32) x(u32) y(u32)]
local function encode_delta(zone_id, seq, events)
    local parts = { u32be(zone_id), u32be(seq), u16be(#events) }
    for i = 1, #events do
        local e = events[i]
        parts[#parts + 1] = string.char(e.t) .. u32be(e.id)
            .. u32be(e.x or 0) .. u32be(e.y or 0)
    end
    return table.concat(parts)
end

-- combat: kind(u8) zone(u32) a(u32) b(u32) damage(u32) value(u32) dead(u8) where
-- (a,b,value) carry per-kind ids/hp:
--   hp     -> a=target, b=0,        value=target_hp   (authoritative, to victim)
--   damage -> a=target, b=0,        value=target_hp   (floating number, to attacker)
--   fx     -> a=attacker, b=target, value=0           (effect, to nearby players)
local COMBAT_KIND = { hp = 1, damage = 2, fx = 3 }
local function encode_combat(zone_id, p)
    local a, b, value
    if p.kind == 'fx' then
        a, b, value = p.attacker or 0, p.target or 0, 0
    else
        a, b, value = p.target or 0, 0, p.hp or p.target_hp or 0
    end
    return string.char(COMBAT_KIND[p.kind] or 0)
        .. u32be(zone_id or 0) .. u32be(a) .. u32be(b)
        .. u32be(p.damage or 0) .. u32be(value)
        .. string.char(p.dead and 1 or 0)
end

-- zone_host deps: final delivery to a home client on this lane.
local function host_to_client(sid, kind, zone_id, seq, payload)
    if kind == 'snapshot' then
        send_to_client(sid, OP_AOI_SNAPSHOT, encode_snapshot(zone_id, seq, payload))
    elseif kind == 'combat' then
        send_to_client(sid, OP_COMBAT_EVENT, encode_combat(zone_id, payload))
    else
        send_to_client(sid, OP_AOI_DELTA, encode_delta(zone_id, seq, payload))
    end
end

-- ----- peer mesh: inbound business (§14.3 / §14.4) -----
-- A decoded peer frame is just a zone_host (msg, ...) tuple; feed it straight
-- into the local host, which knows whether it is the zone owner or the home.
local function peer_on_business(conn, frame)
    local hdr, body = peer_codec.decode_header(frame)
    if not hdr then
        print(string.format('[GAME-BATTLE:%d] bad peer frame (%d bytes)', lane, #frame))
        return
    end
    local mt = hdr.msg_type
    if mt == peer_codec.MIGRATE then
        -- v2 rolling-upgrade hook: never assert, just drop (design §19.1 hook 6).
        print(string.format('[GAME-BATTLE:%d] migrate frame dropped (v1)', lane))
        return
    end
    if mt == peer_codec.ZONE_CTRL or mt == peer_codec.AOI
    or mt == peer_codec.BORDER_SUB or mt == peer_codec.COMBAT then
        if not host then return end
        local vals = peer_codec.unpack_body(body)
        if vals.n >= 1 then host:recv(unpack_args(vals, 1, vals.n)) end
        return
    end
    print(string.format('[GAME-BATTLE:%d] unhandled peer msg_type=0x%02X dropped',
        lane, mt))
end

local function clear_peer(conn)
    local g = conn_peer_game[conn]
    if not g then return end
    conn_peer_game[conn] = nil
    if peer_pending[g] == conn then peer_pending[g] = nil end
    if peer_conns[g] == conn then peer_conns[g] = nil end
    return g
end

-- Accept side: main already validated HELLO and handed us the fd; we are ready
-- as soon as we send ACK.
local peer_accept_handler = {}
function peer_accept_handler.on_packet(conn, body) peer_on_business(conn, body) end
function peer_accept_handler.on_close(conn, reason)
    local g = clear_peer(conn)
    if g then
        print(string.format('[GAME-BATTLE:%d] peer game=%d closed (accept): %s',
            lane, g, tostring(reason)))
    end
end

-- Dialer side: connect, send HELLO, then the first inbound packet must be ACK.
local peer_dial_handler = {}
function peer_dial_handler.on_connect(conn, ip, port)
    conn:set_framing({ type = 'len16', max_packet = 64 * 1024 })
    local ok, err = conn:send(peer_codec.encode_hello(my_game, lane))
    if not ok then
        print(string.format('[GAME-BATTLE:%d] peer hello send failed: %s',
            lane, tostring(err)))
        conn:close('peer_hello_failed')
    end
end
function peer_dial_handler.on_packet(conn, body)
    local g = conn_peer_game[conn]
    if not g then return end
    if peer_conns[g] == conn then
        peer_on_business(conn, body)
        return
    end
    if #body == 1 and string.byte(body, 1) == GATE_ACK_BYTE then
        peer_pending[g] = nil
        peer_conns[g] = conn
        print(string.format('[GAME-BATTLE:%d] peer game=%d ready (dialer)', lane, g))
        return
    end
    print(string.format('[GAME-BATTLE:%d] peer game=%d unexpected pre-ack, closing',
        lane, g))
    conn:close('peer_expected_ack')
    clear_peer(conn)
end
function peer_dial_handler.on_close(conn, reason)
    local g = clear_peer(conn)
    if g then
        print(string.format('[GAME-BATTLE:%d] peer game=%d closed (dialer): %s',
            lane, g, tostring(reason)))
    end
end

-- Encode + send a zone_host (msg, ...) onto the diagonal link to peer_game. We
-- are always on the lane that aligns with the target lane, so src=dst=lane.
local function peer_send(peer_game, msg, ...)
    local conn = peer_conns[peer_game]
    if not conn then
        -- target Game offline / not yet linked: drop (design §12.3).
        print(string.format('[GAME-BATTLE:%d] no peer link to game=%s, drop msg=%s',
            lane, tostring(peer_game), tostring(msg)))
        return false
    end
    local frame, err = peer_codec.encode_host_msg(lane, lane, msg, ...)
    if not frame then
        print(string.format('[GAME-BATTLE:%d] peer encode failed: %s', lane, tostring(err)))
        return false
    end
    return conn:send(frame)
end

-- zone_host deps: route a message to host (game, lane_idx). Only ever called for
-- a REMOTE target (the host short-circuits same-lane work locally). Same-game
-- cross-lane rides xthread.post (MessagePack-encodes the table args). Cross-game
-- aligns the lane locally first, then crosses the process boundary on the
-- lane_N <-> lane_N diagonal (design §6.2: keeps peer traffic on the diagonal).
local function host_post(game, lane_idx, msg, ...)
    if game == my_game then
        local tid = battle_tids[lane_idx]
        if tid then xthread.post(tid, msg, ...) end
        return
    end
    if lane_idx == lane then
        peer_send(game, msg, ...)
    else
        local tid = battle_tids[lane_idx]
        if tid then xthread.post(tid, 'peer_forward', game, msg, ...) end
    end
end

local function start_reconnect_timer()
    if reconnect_timer or not target_host or not target_port then return end
    reconnect_timer = xtimer.delay(RECONNECT_MS, function()
        reconnect_timer = nil
        if gate_conn or gate_pending then return end
        local _, err = xnet.connect(target_host, target_port, gate_handler)
        if err then
            print(string.format('[GAME-BATTLE:%d] reconnect failed: %s',
                lane, tostring(err)))
            start_reconnect_timer()
        end
    end)
end

local function connect_gate()
    if gate_conn or gate_pending or not target_host or not target_port then
        return
    end
    local _, err = xnet.connect(target_host, target_port, gate_handler)
    if err then
        print(string.format('[GAME-BATTLE:%d] connect failed: %s',
            lane, tostring(err)))
        start_reconnect_timer()
    end
end

function gate_handler.on_connect(conn, ip, port)
    conn:set_framing({ type = 'len16', max_packet = 64 * 1024 })
    gate_pending = conn
    -- HELLO: one byte = our lane index (1-based, matches gate worker_ids[]).
    -- Battle stays mute until the ACK arrives so admission can detach this
    -- fd cleanly (no pipelined business packets stuck in xchannel's recv
    -- buffer at detach time).
    local ok, err = conn:send(string.char(lane))
    if not ok then
        print(string.format('[GAME-BATTLE:%d] hello send failed: %s',
            lane, tostring(err)))
        conn:close('hello_send_failed')
        gate_pending = nil
        start_reconnect_timer()
        return
    end
    print(string.format('[GAME-BATTLE:%d] hello sent to gate=%s %s:%s work=%d',
        lane, tostring(target_name), tostring(ip), tostring(port), work_index))
end

function gate_handler.on_packet(conn, body)
    -- Pre-business: expect ACK as the very first packet from gate.
    if not gate_conn then
        if conn ~= gate_pending then return end
        if #body == 1 and string.byte(body, 1) == GATE_ACK_BYTE then
            gate_conn = gate_pending
            gate_pending = nil
            print(string.format('[GAME-BATTLE:%d] gate ack received, ready', lane))
            return
        end
        print(string.format(
            '[GAME-BATTLE:%d] unexpected pre-ack packet len=%d, closing',
            lane, #body))
        conn:close('expected_ack')
        gate_pending = nil
        return
    end

    if #body < 6 then return end
    local sid = r32be(body, 1)
    local opcode = r16be(body, 5)
    local payload = #body > 6 and string.sub(body, 7) or ''

    if opcode == OP_ECHO then
        send_to_client(sid, OP_ECHO, payload)
        return
    end
    if opcode == OP_ENTER_WORLD then
        -- Defer the live spawn (§19.1.3 build_entity(persistent, runtime_hint)): the
        -- work lane owns the persistent store, so we ask IT to cold-load the player
        -- and resolve the spawn position, then it replies 'spawn_at'. The client's
        -- coords are only a first-login fallback -- a returning player spawns at the
        -- logout location written through on their last disconnect. sid doubles as
        -- the entity id in v1 (one connection == one player). on_packet can't block
        -- on Redis, so the round-trip stays on the work lane, off the battle frame.
        if host and work_tid and #payload >= 8 then
            xthread.post(work_tid, 'battle_session_new',
                xthread.current_id(), lane, sid, r32be(payload, 1), r32be(payload, 5))
        end
        return
    end
    if opcode == OP_MOVE then
        if host and #payload >= 8 then
            host:client_move(sid, { x = r32be(payload, 1), y = r32be(payload, 5) })
        end
        return
    end
    if opcode == OP_ATTACK_NPC then
        if host and #payload >= 6 then
            host:client_attack_npc(sid, r32be(payload, 1), r16be(payload, 5))
        end
        return
    end
    if opcode == OP_ATTACK_PLAYER then
        if host and #payload >= 6 then
            host:client_attack_player(sid, r32be(payload, 1), r16be(payload, 5))
        end
        return
    end
    if opcode == OP_SESSION_GONE then
        -- Capture the logout position BEFORE despawn drops the entity; the work
        -- lane write-throughs it to Redis as the player's persistent location
        -- (§19.1.4). pos is nil if the player never entered the world.
        local pos = host and host:player_pos(sid)
        if host then host:despawn_player(sid) end
        if work_tid then
            if pos then
                xthread.post(work_tid, 'battle_session_gone', lane, sid, pos.x, pos.y)
            else
                xthread.post(work_tid, 'battle_session_gone', lane, sid)
            end
        end
        return
    end
    if work_tid then
        local ok, err = xthread.post(work_tid, 'from_battle',
            xthread.current_id(), lane, sid, opcode, payload)
        if not ok then
            print(string.format('[GAME-BATTLE:%d] work post failed: %s',
                lane, tostring(err)))
        end
    end
end

function gate_handler.on_close(conn, reason)
    if conn ~= gate_conn and conn ~= gate_pending then return end
    gate_conn = nil
    gate_pending = nil
    print(string.format('[GAME-BATTLE:%d] gate closed: %s', lane, tostring(reason)))
    start_reconnect_timer()
end

xthread.register('battle_start', function(index, total, target_work_tid, target_work_index)
    lane = tonumber(index) or 0
    lane_count = tonumber(total) or 0
    work_tid = tonumber(target_work_tid)
    work_index = tonumber(target_work_index) or 0
    router.set_log_prefix('GAME-BATTLE-' .. tostring(lane))
    print(string.format('[GAME-BATTLE:%d] start lanes=%d work=%d',
        lane, lane_count, work_index))
end)

xthread.register('battle_set_gate', function(name, host, port, total)
    if tonumber(total) ~= lane_count then return end
    local changed = target_host ~= host or target_port ~= tonumber(port)
    target_name = tostring(name)
    target_host = tostring(host)
    target_port = tonumber(port)
    if changed then
        if gate_conn then gate_conn:close('gate_endpoint_changed'); gate_conn = nil end
        if gate_pending then gate_pending:close('gate_endpoint_changed'); gate_pending = nil end
    end
    connect_gate()
end)

xthread.register('work_reply', function(sid, opcode, payload)
    local ok, err = send_to_client(sid, opcode, payload)
    if not ok then
        print(string.format('[GAME-BATTLE:%d] work reply failed sid=%s: %s',
            lane, tostring(sid), tostring(err)))
    end
end)

-- Async completion of the enter-world handshake (§19.1.3): the work lane loaded
-- this player's persistent state and resolved their spawn position, so build the
-- live entity now. This is the SAME spawn entry point v2 will call on the MIGRATE
-- recv end; v1 only ever reaches it via this cold-load reply.
xthread.register('spawn_at', function(sid, x, y)
    if host then host:spawn_player(sid, sid, { x = x, y = y }) end
end)

-- Sibling lane directory + game index, sent once after 'battle_start'. With it
-- in hand the lane can reach any same-game lane and is ready to host AOI.
xthread.register('battle_peers', function(game_index, tids, game_count)
    my_game = tonumber(game_index) or 1
    battle_tids = tids or {}
    zone_host.configure({ lane_count = lane_count, game_count = tonumber(game_count) or 1 })
    host = zone_host.new({
        game = my_game,
        lane = lane,
        post = host_post,
        to_client = host_to_client,
    })
    if not frame_timer then
        frame_timer = xtimer.add(FRAME_MS, function()
            if host then host:tick() end
        end, -1)
    end
    print(string.format('[GAME-BATTLE:%d] peers set game=%d lanes=%d',
        lane, my_game, #battle_tids))
end)

-- Cross-lane AOI inbox (owner role + home role). Each just forwards into the
-- zone_host, which knows whether it is the zone owner or the player's home.
local function host_dispatch(msg)
    return function(...)
        if host then host:recv(msg, ...) end
    end
end
xthread.register('enter_zone', host_dispatch('enter_zone'))
xthread.register('leave_zone', host_dispatch('leave_zone'))
xthread.register('player_move', host_dispatch('player_move'))
xthread.register('aoi_in', host_dispatch('aoi_in'))
-- cross-lane combat inbox (design §7.4 / §9): same five msgs the peer mesh feeds
-- in, but arriving from a sibling lane via xthread.post.
xthread.register('attack_npc', host_dispatch('attack_npc'))
xthread.register('attack_player', host_dispatch('attack_player'))
xthread.register('damage_dealt', host_dispatch('damage_dealt'))
xthread.register('hit_broadcast', host_dispatch('hit_broadcast'))
xthread.register('combat_fx', host_dispatch('combat_fx'))

-- Peer accept (§6.1): main validated the HELLO and detached the fd to us. Attach
-- it, register the link, and ACK so the dialer can start business traffic.
xthread.register('peer_accept', function(fd, peer_game)
    peer_game = tonumber(peer_game)
    local conn, err = xnet.attach(fd, peer_accept_handler)
    if not conn then
        io.stderr:write('[GAME-BATTLE] peer attach failed: ' .. tostring(err) .. '\n')
        return
    end
    conn:set_framing({ type = 'len16', max_packet = 64 * 1024 })
    if peer_conns[peer_game] then peer_conns[peer_game]:close('peer_replaced') end
    conn_peer_game[conn] = peer_game
    peer_conns[peer_game] = conn
    local ok, serr = conn:send(peer_codec.ACK)
    if not ok then
        print(string.format('[GAME-BATTLE:%d] peer ack send failed game=%s: %s',
            lane, tostring(peer_game), tostring(serr)))
        conn:close('peer_ack_failed')
        clear_peer(conn)
        return
    end
    print(string.format('[GAME-BATTLE:%d] peer game=%d accepted (ack sent)',
        lane, peer_game))
end)

-- Peer dial (§6): main discovered a lower-id Game; this lane opens the diagonal
-- link to the same lane index in that Game.
xthread.register('peer_dial', function(peer_game, peer_host, peer_port)
    peer_game = tonumber(peer_game)
    peer_host = tostring(peer_host or '')
    peer_port = tonumber(peer_port)
    if not peer_game or peer_host == '' or not peer_port then return end
    if peer_conns[peer_game] or peer_pending[peer_game] then return end
    local conn, err = xnet.connect(peer_host, peer_port, peer_dial_handler)
    if not conn then
        print(string.format('[GAME-BATTLE:%d] peer dial game=%d %s:%d failed: %s',
            lane, peer_game, peer_host, peer_port, tostring(err)))
        return
    end
    conn_peer_game[conn] = peer_game
    peer_pending[peer_game] = conn
    print(string.format('[GAME-BATTLE:%d] dialing peer game=%d at %s:%d',
        lane, peer_game, peer_host, peer_port))
end)

-- Local-hop relay (§6.2): a sibling lane aligned the lane to us; we hold the
-- diagonal link to the target Game, so finish the send.
xthread.register('peer_forward', function(peer_game, msg, ...)
    peer_send(tonumber(peer_game), msg, ...)
end)

local function __init()
    assert(xnet.init())
    xtimer.init(32)
end

local function __uninit()
    if frame_timer then frame_timer:del(); frame_timer = nil end
    if reconnect_timer then reconnect_timer:del(); reconnect_timer = nil end
    if gate_conn    then gate_conn:close('uninit');    gate_conn = nil end
    if gate_pending then gate_pending:close('uninit'); gate_pending = nil end
    for _, conn in pairs(peer_conns) do conn:close('uninit') end
    for _, conn in pairs(peer_pending) do conn:close('uninit') end
    peer_conns = {}
    peer_pending = {}
    conn_peer_game = {}
    xnet.uninit()
end

return {
    __init = __init,
    __uninit = __uninit,
    __thread_handle = router.handle,
}
