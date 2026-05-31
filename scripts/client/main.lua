-- scripts/client/main.lua -- test client skeleton (no crypto)
--
-- Connects to gate's client port and follows the weak-auth admission scheme
-- (design §4/§19.0 身份 ≠ 位置) before any crypto:
--   0. send a login frame FIRST and wait for the gate's 1-byte PROCEED ack -- the
--      gate has resolved us to a home lane and the owning worker now holds our fd.
--   1. send PING -> expect PONG back
--   2. send ECHO "hello" -> expect ECHO "hello" back
--   3. send ECHO "world" -> expect ECHO "world" back
-- Then exits with code 0 (success) or 1 (failure).
--
-- Why login-first: the gate routes a fresh accept to its auth lane, which migrates
-- the bare fd to lane = hash(account_id)%T and only THEN (post-attach, on the owning
-- lane) acks PROCEED. The salt/AEAD handshake must wait for PROCEED -- pipelining the
-- salt now would risk it landing in the auth lane's framing buffer, which detach()
-- discards.
--
-- Wire body (between gate and client):
--   login:  [flags:1][token_len:2BE][token][account_id:4BE]   (LEN16 framed)
--   then:   [opcode:2BE][payload:N]                            (LEN16 framed)
--
-- Run with:  ./bin/xnet scripts/client/main.lua

local GATE_HOST = '127.0.0.1'
local GATE_PORT = 19180

-- Weak-auth admission login (design §4/§19.0). In v1 a claimed account_id is trusted
-- as-is (src=claimed) and the gate shards the session to lane = hash(account_id)%T --
-- the player's home lane. The SAME id must later be sent as the OP_LOGIN player_id so
-- battle residency matches the admitted lane; piece 3 of the cutover will make the
-- gate carry this id into battle instead of trusting the client-sent OP_LOGIN. 4242 is
-- an arbitrary stand-in player_id for this smoke client.
local CLIENT_ACCOUNT_ID = 4242
local LOGIN_TOKEN = 'client-smoke-token'
local PROCEED = string.char(0x01)

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
local admitted       = false   -- got the 1-byte PROCEED ack from our owning lane
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

local function u32be(n)
    return string.char(
        math.floor(n / 16777216) % 256, math.floor(n / 65536) % 256,
        math.floor(n / 256) % 256, n % 256)
end

local function r16be(s, i)
    local b1, b2 = string.byte(s, i, i + 1)
    return b1 * 256 + b2
end

-- admit.parse_login layout: [flags:1][token_len:u16be][token][account_id:u32be].
-- flags bit0 = a claimed account_id follows (trusted as-is in v1, src=claimed).
local function login_frame(token, claimed)
    return string.char(1) .. u16be(#token) .. token .. u32be(claimed)
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
    -- Login FIRST (weak-auth admission). We hold the salt until PROCEED lands.
    local ok, err = c:send(login_frame(LOGIN_TOKEN, CLIENT_ACCOUNT_ID))
    if not ok then
        check(false, 'login frame send failed: ' .. tostring(err))
        finish()
        return
    end
    print(string.format('[CLIENT] connected to %s:%s, login sent (account=%d)',
        tostring(ip), tostring(port), CLIENT_ACCOUNT_ID))
end

function handler.on_packet(_, body)
    if not admitted then
        -- Phase 0: the gate's 1-byte PROCEED ack -- our fd has landed on its owning
        -- lane's worker. Only now is it safe to begin the salt/AEAD handshake.
        if #body ~= 1 or body ~= PROCEED then
            check(false, 'admission: expected 1-byte PROCEED, got ' .. #body .. ' bytes')
            finish()
            return
        end
        admitted = true
        client_salt = xnet.random_bytes(4)
        local ok, err = conn:send(client_salt)
        if not ok then
            check(false, 'handshake salt send failed: ' .. tostring(err))
            finish()
            return
        end
        print('[CLIENT] admitted (PROCEED), salt sent')
        return
    end
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
