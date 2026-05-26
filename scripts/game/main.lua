-- scripts/game/main.lua -- game service skeleton (no crypto)
--
-- Connects to gate's internal port. All packets to/from gate carry a
-- session_id prefix so the game can address replies to specific clients:
--
--   [session_id:4BE][opcode:2BE][payload:N]
--
-- session_id = 0 is reserved for gate-game system messages (unused in v0).
--
-- Run with:  ./bin/xnet scripts/game/main.lua

local GATE_HOST = '127.0.0.1'
local GATE_PORT = 19181

local RECONNECT_MS = 2000

local gate_conn
local reconnect_timer

-- opcode -> handler(sid, payload) -> (reply_opcode, reply_payload) or nil
local handlers = {}

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
    return gate_conn:send(u32be(sid) .. u16be(opcode) .. (payload or ''))
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
local gate_handler = {}

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
    if rop then send_to_client(sid, rop, rpl) end
end

local function start_reconnect_timer()
    if reconnect_timer then return end
    reconnect_timer = xtimer.delay(RECONNECT_MS, function()
        reconnect_timer = nil
        if gate_conn then return end
        print('[GAME] reconnect attempt...')
        local conn, err = xnet.connect(GATE_HOST, GATE_PORT, gate_handler)
        if not conn then
            print('[GAME] reconnect failed: ' .. tostring(err))
            start_reconnect_timer()
        end
    end)
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

    local conn, err = xnet.connect(GATE_HOST, GATE_PORT, gate_handler)
    if not conn then
        print('[GAME] initial connect failed: ' .. tostring(err) .. ', will retry')
        start_reconnect_timer()
    end
end

local function __uninit()
    if reconnect_timer then reconnect_timer:del(); reconnect_timer = nil end
    if gate_conn       then gate_conn:close('uninit'); gate_conn = nil end
    xnet.uninit()
    print('[GAME] uninit')
end

return { __init = __init, __uninit = __uninit }
