-- scripts/client/main.lua -- test client skeleton (no crypto)
--
-- Connects to gate's client port, runs a small test sequence:
--   1. send PING -> expect PONG back
--   2. send ECHO "hello" -> expect ECHO "hello" back
--   3. send ECHO "world" -> expect ECHO "world" back
-- Then exits with code 0 (success) or 1 (failure).
--
-- Wire body (between gate and client):
--   [opcode:2BE][payload:N]    (LEN16 framed)
--
-- Run with:  ./bin/xnet scripts/client/main.lua

local GATE_HOST = '127.0.0.1'
local GATE_PORT = 19180

local OP_ECHO = 0x0001
local OP_PING = 0x0002

-- Must match gate. v0 placeholder, will be ECDH-derived later.
local K_C2S = string.rep('\1', 32)  -- client send key
local K_S2C = string.rep('\2', 32)  -- client recv key

-- LEN16 body includes opcode and, after handshake, AEAD seq/tag overhead.
local CLIENT_MAX_PAYLOAD = 65535 - 24 - 2

-- Connection-establishment deadline. Killed the moment handshake completes;
-- if it fires first we know the session is stuck (no gate reply, blackhole,
-- or gate accepted then froze). After handshake the timer is gone, so it
-- can never false-fire against a later test.
local CONNECT_TIMEOUT_MS = 3000

local conn
local handshake_done = false
local client_salt    = nil
local fails  = 0
local cur    = 0
local tests
local done   = false
local connect_timer = nil

local function u16be(n)
    return string.char(math.floor(n / 256) % 256, n % 256)
end

local function r16be(s, i)
    local b1, b2 = string.byte(s, i, i + 1)
    return b1 * 256 + b2
end

local function send_op(op, payload)
    payload = payload or ''
    if #payload > CLIENT_MAX_PAYLOAD then
        return false, string.format('payload too large (%d > %d)',
            #payload, CLIENT_MAX_PAYLOAD)
    end
    return conn:send(u16be(op) .. payload)
end

local function check(cond, msg)
    if cond then
        print('PASS: ' .. msg)
    else
        fails = fails + 1
        io.stderr:write('FAIL: ' .. msg .. '\n')
    end
end

local function cancel_connect_timer()
    if connect_timer then connect_timer:del(); connect_timer = nil end
end

local function finish()
    if done then return end
    done = true
    cancel_connect_timer()
    print(string.format('\n--- client smoke test: %d failures ---', fails))
    if conn then conn:close('done'); conn = nil end
    xthread.stop(fails > 0 and 1 or 0)
end

local function next_test()
    cur = cur + 1
    local t = tests[cur]
    if not t then finish(); return end
    print(string.format('\n[Test %d] %s', cur, t.name))
    local ok, err = t.start()
    if ok == false then
        check(false, t.name .. ' send failed: ' .. tostring(err))
        finish()
    end
end

tests = {
    {
        name = 'ping',
        start = function() return send_op(OP_PING) end,
        expect = function(op, body)
            check(op == OP_PING and body == 'pong', 'ping -> pong')
            next_test()
        end,
    },
    {
        name = 'echo hello',
        start = function() return send_op(OP_ECHO, 'hello') end,
        expect = function(op, body)
            check(op == OP_ECHO and body == 'hello', 'echo "hello"')
            next_test()
        end,
    },
    {
        name = 'echo world',
        start = function() return send_op(OP_ECHO, 'world') end,
        expect = function(op, body)
            check(op == OP_ECHO and body == 'world', 'echo "world"')
            next_test()
        end,
    },
}

local handler = {}

function handler.on_connect(c, ip, port)
    c:set_framing({ type = 'len16', max_packet = 64 * 1024 })
    conn = c
    client_salt = xnet.random_bytes(4)
    -- Send our salt plain; gate replies with its salt, then both flip AEAD on.
    local ok, err = c:send(client_salt)
    if not ok then
        check(false, 'handshake send failed: ' .. tostring(err))
        finish()
        return
    end
    print(string.format('[CLIENT] connected to %s:%s (handshake)',
        tostring(ip), tostring(port)))
end

function handler.on_packet(_, body)
    if not handshake_done then
        if #body ~= 4 then
            check(false, 'gate handshake: expected 4 bytes, got ' .. #body)
            return
        end
        conn:enable_aead(K_C2S, K_S2C, client_salt, body)
        handshake_done = true
        cancel_connect_timer()
        print('[CLIENT] handshake done, AEAD on')
        next_test()
        return
    end
    if #body < 2 then
        check(false, 'short reply from gate')
        return
    end
    local op   = r16be(body, 1)
    local rest = #body > 2 and string.sub(body, 3) or ''
    local t = tests[cur]
    if t and t.expect then t.expect(op, rest) end
end

function handler.on_close(_, reason)
    print('[CLIENT] closed: ' .. tostring(reason))
    if not done then
        check(false, 'connection closed before tests finished')
        finish()
    end
end

local function __init()
    print('[CLIENT] init')
    assert(xnet.init())
    xtimer.init(32)
    connect_timer = xtimer.delay(CONNECT_TIMEOUT_MS, function()
        connect_timer = nil
        if done or handshake_done then return end
        check(false, 'session establishment timed out after ' ..
            CONNECT_TIMEOUT_MS .. 'ms')
        finish()
    end)
    local c, err = xnet.connect(GATE_HOST, GATE_PORT, handler)
    if not c then
        io.stderr:write('[CLIENT] connect failed: ' .. tostring(err) .. '\n')
        finish()
    end
end

local function __uninit()
    cancel_connect_timer()
    if conn then conn:close('uninit'); conn = nil end
    xnet.uninit()
    print('[CLIENT] uninit')
end

return { __init = __init, __uninit = __uninit }
