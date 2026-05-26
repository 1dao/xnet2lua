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

local conn
local fails  = 0
local cur    = 0
local tests
local done   = false

local function u16be(n)
    return string.char(math.floor(n / 256) % 256, n % 256)
end

local function r16be(s, i)
    local b1, b2 = string.byte(s, i, i + 1)
    return b1 * 256 + b2
end

local function send_op(op, payload)
    return conn:send(u16be(op) .. (payload or ''))
end

local function check(cond, msg)
    if cond then
        print('PASS: ' .. msg)
    else
        fails = fails + 1
        io.stderr:write('FAIL: ' .. msg .. '\n')
    end
end

local function finish()
    if done then return end
    done = true
    print(string.format('\n--- client smoke test: %d failures ---', fails))
    if conn then conn:close('done'); conn = nil end
    xthread.stop(fails > 0 and 1 or 0)
end

local function next_test()
    cur = cur + 1
    local t = tests[cur]
    if not t then finish(); return end
    print(string.format('\n[Test %d] %s', cur, t.name))
    t.start()
end

tests = {
    {
        name = 'ping',
        start = function() send_op(OP_PING) end,
        expect = function(op, body)
            check(op == OP_PING and body == 'pong', 'ping -> pong')
            next_test()
        end,
    },
    {
        name = 'echo hello',
        start = function() send_op(OP_ECHO, 'hello') end,
        expect = function(op, body)
            check(op == OP_ECHO and body == 'hello', 'echo "hello"')
            next_test()
        end,
    },
    {
        name = 'echo world',
        start = function() send_op(OP_ECHO, 'world') end,
        expect = function(op, body)
            check(op == OP_ECHO and body == 'world', 'echo "world"')
            next_test()
        end,
    },
}

local handler = {}

function handler.on_connect(c, ip, port)
    c:set_framing({ type = 'len16', max_packet = 64 * 1024 })
    c:enable_aead(K_C2S, K_S2C)
    conn = c
    print(string.format('[CLIENT] connected to %s:%s (AEAD on)',
        tostring(ip), tostring(port)))
    next_test()
end

function handler.on_packet(_, body)
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
    local c, err = xnet.connect(GATE_HOST, GATE_PORT, handler)
    if not c then
        io.stderr:write('[CLIENT] connect failed: ' .. tostring(err) .. '\n')
        finish()
    end
end

local function __uninit()
    if conn then conn:close('uninit'); conn = nil end
    xnet.uninit()
    print('[CLIENT] uninit')
end

return { __init = __init, __uninit = __uninit }
