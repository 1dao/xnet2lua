-- scripts/game/battle_worker.lua -- one low-latency game battle lane.
--
-- This worker owns exactly one direct connection to its same-index gate lane.
-- Battle opcodes execute here; everything else is handed to a work worker.

local router = dofile('scripts/core/share/xrouter.lua')
local zone_host = dofile('scripts/game/zone_host.lua')
router.set_log_prefix('GAME-BATTLE')

function xthread.register(pt, h) return router.register(pt, h) end

local RECONNECT_MS = 2000
local INTERNAL_MAX_PAYLOAD = 65535 - 4 - 2
local FRAME_MS = 50                       -- AOI flush cadence (~20 Hz)
local OP_ECHO = 0x0001
local OP_ENTER_WORLD = 0x0002             -- client -> server: x(u32) y(u32)
local OP_MOVE = 0x0003                     -- client -> server: x(u32) y(u32)
local OP_AOI_SNAPSHOT = 0x0004             -- server -> client: full view
local OP_AOI_DELTA = 0x0005               -- server -> client: incremental view
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

-- zone_host deps: final delivery to a home client on this lane.
local function host_to_client(sid, kind, zone_id, seq, payload)
    if kind == 'snapshot' then
        send_to_client(sid, OP_AOI_SNAPSHOT, encode_snapshot(zone_id, seq, payload))
    else
        send_to_client(sid, OP_AOI_DELTA, encode_delta(zone_id, seq, payload))
    end
end

-- zone_host deps: route a message to host (game, lane_idx). Only ever called for
-- a REMOTE target (the host short-circuits same-lane work locally). Same-game
-- cross-lane rides xthread.post (MessagePack-encodes the table args). Cross-game
-- needs the peer mesh, which is a later stage (design §6 / P4).
local function host_post(game, lane_idx, msg, ...)
    if game == my_game then
        local tid = battle_tids[lane_idx]
        if tid then xthread.post(tid, msg, ...) end
    else
        print(string.format('[GAME-BATTLE:%d] drop cross-game msg=%s game=%s (no peer mesh)',
            lane, tostring(msg), tostring(game)))
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
        -- sid doubles as the entity id in v1 (one connection == one player).
        if host and #payload >= 8 then
            host:spawn_player(sid, sid, { x = r32be(payload, 1), y = r32be(payload, 5) })
        end
        return
    end
    if opcode == OP_MOVE then
        if host and #payload >= 8 then
            host:client_move(sid, { x = r32be(payload, 1), y = r32be(payload, 5) })
        end
        return
    end
    if opcode == OP_SESSION_GONE then
        if host then host:despawn_player(sid) end
        if work_tid then
            xthread.post(work_tid, 'battle_session_gone', lane, sid)
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

local function __init()
    assert(xnet.init())
    xtimer.init(32)
end

local function __uninit()
    if frame_timer then frame_timer:del(); frame_timer = nil end
    if reconnect_timer then reconnect_timer:del(); reconnect_timer = nil end
    if gate_conn    then gate_conn:close('uninit');    gate_conn = nil end
    if gate_pending then gate_pending:close('uninit'); gate_pending = nil end
    xnet.uninit()
end

return {
    __init = __init,
    __uninit = __uninit,
    __thread_handle = router.handle,
}
