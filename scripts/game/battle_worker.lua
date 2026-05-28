-- scripts/game/battle_worker.lua -- one low-latency game battle lane.
--
-- This worker owns exactly one direct connection to its same-index gate lane.
-- Battle opcodes execute here; everything else is handed to a work worker.

local router = dofile('scripts/core/share/xrouter.lua')
router.set_log_prefix('GAME-BATTLE')

function xthread.register(pt, h) return router.register(pt, h) end

local RECONNECT_MS = 2000
local INTERNAL_MAX_PAYLOAD = 65535 - 4 - 2
local OP_ECHO = 0x0001
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
    if opcode == OP_SESSION_GONE then
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

local function __init()
    assert(xnet.init())
    xtimer.init(32)
end

local function __uninit()
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
