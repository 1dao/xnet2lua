-- scripts/game/main.lua -- game service skeleton (no crypto)
--
-- Connect strategy:
--   1) Prefer NATS-discovered gate nodes (gate_announce).
--   2) If announce lacks host/port, query the gate over NATS RPC.
--   3) Fallback to static GAME_GATE_HOST/GAME_GATE_PORT.
--
-- All packets to/from gate carry a session_id prefix:
--   [session_id:4BE][opcode:2BE][payload:N]
--
-- Run with:  ./bin/xnet scripts/game/main.lua

local router = dofile('scripts/core/share/xrouter.lua')
router.set_log_prefix('GAME-MAIN')

local xnats = dofile('scripts/core/server/xnats.lua')
local xutils = require('xutils')

local CONFIG_FILE = 'xnet.cfg'
local ok_cfg, cfg_err = xutils.load_config(CONFIG_FILE)
if not ok_cfg then
    io.stderr:write('[GAME] config not loaded: ' .. tostring(cfg_err) .. '\n')
end

local PROCESS_NAME = XNET_PROCESS_NAME or xutils.get_config('SERVER_NAME', 'game1')
local GATE_TARGET = xutils.get_config('GAME_GATE_TARGET', '')
local GATE_HOST = xutils.get_config('GAME_GATE_HOST', '127.0.0.1')
local GATE_PORT = tonumber(xutils.get_config('GAME_GATE_PORT', '19181')) or 19181
local GATE_PEER_TTL_MS = tonumber(xutils.get_config('GAME_GATE_PEER_TTL_MS', '15000')) or 15000

local NATS_HOST = xutils.get_config('NATS_HOST', '127.0.0.1')
local NATS_PORT = tonumber(xutils.get_config('NATS_PORT', '4222')) or 4222
local NATS_PREFIX = xutils.get_config('NATS_PREFIX', 'xnet.test')
local NATS_RPC_TIMEOUT_MS = tonumber(xutils.get_config('GAME_GATE_NATS_RPC_TIMEOUT_MS', '1500')) or 1500

local RECONNECT_MS = 2000
local INTERNAL_MAX_PAYLOAD = 65535 - 4 - 2

local gate_conn
local reconnect_timer
local nats_started = false
local discovered_gates = {} -- name -> { name, host, port, last_seen_ms }
local gate_handler = {}

-- opcode -> handler(sid, payload) -> (reply_opcode, reply_payload) or nil
local handlers = {}

function xthread.register(pt, h) return router.register(pt, h) end

local function now_ms()
    if xtimer and xtimer.now_ms then
        return xtimer.now_ms()
    end
    return math.floor(os.time() * 1000)
end

local function sanitize_host(v)
    local s = tostring(v or '')
    if s == '' then return nil end
    return s
end

local function sanitize_port(v)
    local p = tonumber(v)
    if not p then return nil end
    if p < 1 or p > 65535 then return nil end
    return p
end

local function note_gate(name, host, port)
    name = tostring(name or '')
    if name == '' then return nil end
    local peer = discovered_gates[name]
    if not peer then
        peer = { name = name }
        discovered_gates[name] = peer
    end
    local h = sanitize_host(host)
    local p = sanitize_port(port)
    if h then peer.host = h end
    if p then peer.port = p end
    peer.last_seen_ms = now_ms()
    return peer
end

local function pick_gate_peer()
    local cutoff = now_ms() - GATE_PEER_TTL_MS
    if GATE_TARGET ~= '' then
        local target = discovered_gates[GATE_TARGET]
        if target and target.last_seen_ms and target.last_seen_ms >= cutoff then
            return target
        end
        return nil
    end

    local best
    for _, peer in pairs(discovered_gates) do
        if peer.last_seen_ms and peer.last_seen_ms >= cutoff then
            if not best or peer.last_seen_ms > best.last_seen_ms then
                best = peer
            end
        end
    end
    return best
end

local function parse_rpc_addr(app_ok, v2, v3)
    local host, port
    if app_ok == true then
        host, port = v2, v3
    elseif type(app_ok) == 'string' then
        host, port = app_ok, v2
    elseif type(app_ok) == 'table' then
        host = app_ok.host or app_ok.ip
        port = app_ok.port or app_ok.internal_port
    end
    host = sanitize_host(host)
    port = sanitize_port(port)
    if not host or not port then
        return nil, nil
    end
    return host, port
end

local function query_gate_addr(target)
    if not nats_started then
        return nil, nil, 'nats not started'
    end

    local rpc_pts = { 'gate_get_internal_addr', 'gate_get_addr' }
    local last_err = 'address query failed'
    for _, pt in ipairs(rpc_pts) do
        local ch_ok, app_ok, a, b = xnats.rpc(target, pt)
        if not ch_ok then
            last_err = tostring(app_ok)
        else
            local host, port = parse_rpc_addr(app_ok, a, b)
            if host and port then
                return host, port
            end
            if app_ok == false then
                last_err = tostring(a or 'remote address handler failed')
            else
                last_err = 'bad address reply'
            end
        end
    end
    return nil, nil, last_err
end

local function resolve_gate_endpoint()
    local peer = pick_gate_peer()
    if peer then
        local host = sanitize_host(peer.host)
        local port = sanitize_port(peer.port)
        if host and port then
            return host, port, 'nats-announce:' .. peer.name
        end

        local qhost, qport, qerr = query_gate_addr(peer.name)
        if qhost and qport then
            host, port = qhost, qport
            peer.host, peer.port = host, port
            return host, port, 'nats-rpc:' .. peer.name
        end
        return nil, nil, string.format('peer=%s address unresolved: %s',
            tostring(peer.name), tostring(qerr))
    end

    local fallback_host = sanitize_host(GATE_HOST)
    local fallback_port = sanitize_port(GATE_PORT)
    if fallback_host and fallback_port then
        return fallback_host, fallback_port, 'static-config'
    end
    return nil, nil, 'no gate discovered'
end

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
    if not gate_conn then return false end
    payload = payload or ''
    if #payload > INTERNAL_MAX_PAYLOAD then
        return false, string.format('payload too large (%d > %d)',
            #payload, INTERNAL_MAX_PAYLOAD)
    end
    return gate_conn:send(u32be(sid) .. u16be(opcode) .. payload)
end

-- =========================================================================
-- handlers
-- =========================================================================
local OP_ECHO         = 0x0001
local OP_PING         = 0x0002
local OP_SESSION_GONE = 0xFFFE

handlers[OP_ECHO] = function(sid, payload)
    print(string.format('[GAME] sid=%d ECHO %q', sid, payload or ''))
    return OP_ECHO, payload
end

handlers[OP_PING] = function(sid, payload)
    print(string.format('[GAME] sid=%d PING', sid))
    return OP_PING, 'pong'
end

handlers[OP_SESSION_GONE] = function(sid, _)
    print(string.format('[GAME] sid=%d session gone, cleaning up state', sid))
    -- in real code, drop the player object, save state, etc.
    return nil
end

-- =========================================================================
-- gate conn wiring
-- =========================================================================
local function try_connect_gate(trigger)
    if gate_conn then return true end
    local host, port, source_or_err = resolve_gate_endpoint()
    if not host then
        return false, source_or_err
    end
    print(string.format('[GAME] connect(%s) -> %s:%d (%s)',
        tostring(trigger), host, port, tostring(source_or_err)))
    local conn, err = xnet.connect(host, port, gate_handler)
    if not conn then
        return false, err
    end
    return true
end

local function start_reconnect_timer()
    if reconnect_timer then return end
    reconnect_timer = xtimer.delay(RECONNECT_MS, function()
        reconnect_timer = nil
        if gate_conn then return end
        local ok, err = try_connect_gate('retry')
        if not ok then
            print('[GAME] reconnect failed: ' .. tostring(err))
            start_reconnect_timer()
        end
    end)
end

xthread.register('gate_announce', function(name, host, port)
    local peer = note_gate(name, host, port)
    if not peer then return end

    print(string.format('[GAME] gate discovered name=%s host=%s port=%s',
        peer.name, tostring(peer.host), tostring(peer.port)))

    if gate_conn then return end
    local ok, err = try_connect_gate('announce')
    if not ok then
        print('[GAME] connect on announce failed: ' .. tostring(err))
        start_reconnect_timer()
    end
end)

function gate_handler.on_connect(conn, ip, port)
    conn:set_framing({ type = 'len16', max_packet = 64 * 1024 })
    gate_conn = conn
    print(string.format('[GAME] connected to gate %s:%s', tostring(ip), tostring(port)))
end

function gate_handler.on_packet(_, body)
    if #body < 6 then
        print('[GAME] short packet, dropping')
        return
    end
    local sid    = r32be(body, 1)
    local opcode = r16be(body, 5)
    local payload = #body > 6 and string.sub(body, 7) or ''

    local h = handlers[opcode]
    if not h then
        print(string.format('[GAME] sid=%d unknown opcode 0x%04X', sid, opcode))
        return
    end
    local rop, rpl = h(sid, payload)
    if rop then
        local ok, err = send_to_client(sid, rop, rpl)
        if not ok then
            print(string.format('[GAME] sid=%d send reply failed: %s',
                sid, tostring(err)))
        end
    end
end

function gate_handler.on_close(_, reason)
    gate_conn = nil
    print('[GAME] gate closed: ' .. tostring(reason) .. ', will reconnect')
    start_reconnect_timer()
end

-- =========================================================================
-- lifecycle
-- =========================================================================
local function __init()
    print('[GAME] init')
    assert(xnet.init())
    xtimer.init(32)

    local ok, err = xnats.start({
        host = NATS_HOST,
        port = NATS_PORT,
        name = PROCESS_NAME,
        prefix = NATS_PREFIX,
        workers = { xthread.MAIN },
        reconnect_ms = 1000,
        rpc_timeout_ms = NATS_RPC_TIMEOUT_MS,
    })
    if not ok then
        io.stderr:write('[GAME] xnats start failed: ' .. tostring(err) .. '\n')
    else
        nats_started = true
    end

    local connected, conn_err = try_connect_gate('init')
    if not connected then
        print('[GAME] initial connect failed: ' .. tostring(conn_err) .. ', will retry')
        start_reconnect_timer()
    end
end

local function __uninit()
    if reconnect_timer then reconnect_timer:del(); reconnect_timer = nil end
    if gate_conn       then gate_conn:close('uninit'); gate_conn = nil end
    if nats_started    then xnats.stop(true); nats_started = false end
    xnet.uninit()
    print('[GAME] uninit')
end

return {
    __init = __init,
    __uninit = __uninit,
    __thread_handle = router.handle,
}
