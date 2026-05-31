-- demo/gate_admit_main.lua -- integration test for the gate's weak-auth admission
-- handoff (design §4 / §19.0 身份 ≠ 位置). Proves the NEW glue the cutover adds,
-- over real sockets and real threads:
--
--   client --login frame--> [auth lane: auth_worker.lua] --admit.decide + detach-->
--     xthread.post('client_admit', fd, account_id) --> [owning lane: worker.lua]
--     --attach + PROCEED--> client
--
-- The client sends ONE login frame and must receive the 1-byte PROCEED ack back
-- from a gate worker. The frame carries a CLAIMED account_id, so the shard lane is
-- deterministic: lane = hash(account_id)%T via zone_def's single affinity hash. We
-- compute that lane up front and staff ONLY it. So a PROCEED coming back proves the
-- auth lane surrendered the fd to exactly lane=hash(account_id)%T -- route it to any
-- other lane and no worker is there, the handoff post fails, and the test times out.
-- (The token->minted-id resolution is unit-tested by admit_spec/auth_spec; this test
-- targets the socket glue + correct-lane routing the unit tests can't reach.)
--
-- We stop at PROCEED on purpose. The AEAD salt handshake that would follow is
-- unchanged legacy code AND needs xframe_aead (a WITH_HTTPS build), so keeping the
-- assertion pre-AEAD lets this run in the default WITH_HTTPS=0 core matrix.
--
-- The listener -> 'auth_accept' wiring below is exactly what gate/main.lua adopts at
-- the live cutover, against the REAL auth_worker.lua + worker.lua.
--
-- Run with: ./bin/xnet demo/gate_admit_main.lua

local router   = dofile('scripts/core/share/xrouter.lua')
local zone_def = dofile('scripts/game/zone_def.lua')
router.set_log_prefix('GATE-ADMIT')

local HOST = '127.0.0.1'
local PORT = 19188
local LANES = zone_def.LANE_COUNT
local WORKER_BASE = xthread.WORKER_GRP1     -- lane L -> WORKER_BASE + L - 1
local AUTH_ID = xthread.WORKER_GRP2         -- auth lane, off the worker group
local ACCOUNT_ID = 4242                     -- claimed id -> deterministic home lane
local HOME_LANE = select(2, zone_def.resolve_player_home(ACCOUNT_ID))
local TOKEN = 'admit-smoke-token'
local PROCEED = string.char(0x01)
local CONNECT_TIMEOUT_MS = 3000

local worker_tid
local listener
local conn
local fails = 0
local done = false
local connect_timer
local answered = false

local function u16be(n)
    return string.char(math.floor(n / 256) % 256, n % 256)
end

local function u32be(n)
    return string.char(
        math.floor(n / 16777216) % 256, math.floor(n / 65536) % 256,
        math.floor(n / 256) % 256, n % 256)
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
    print(string.format('\n--- gate admit smoke test: %d failures ---', fails))
    if conn then conn:close('done'); conn = nil end
    if listener then listener:close('done'); listener = nil end
    xthread.shutdown_thread(AUTH_ID)
    if worker_tid then xthread.shutdown_thread(worker_tid) end
    xthread.stop(fails > 0 and 1 or 0)
end

function xthread.register(pt, h) return router.register(pt, h) end

-- login frame: admit.parse_login layout --
--   [flags:1][token_len:u16be][token][account_id:u32be]   (flags bit0 = claimed id)
local function login_frame(token, claimed)
    return string.char(1) .. u16be(#token) .. token .. u32be(claimed)
end

local client_handler = {}

function client_handler.on_connect(c, ip, port)
    c:set_framing({ type = 'len16', max_packet = 4096 })
    conn = c
    local ok, err = c:send(login_frame(TOKEN, ACCOUNT_ID))
    if not ok then
        check(false, 'login frame send failed: ' .. tostring(err))
        finish()
        return
    end
    print(string.format('[GATE-ADMIT] client connected %s:%s, login sent (account=%d)',
        tostring(ip), tostring(port), ACCOUNT_ID))
end

function client_handler.on_packet(_, body)
    if answered then return end
    answered = true
    check(#body == 1 and body == PROCEED, string.format(
        'admitted client got the 1-byte PROCEED ack from lane %d (=hash(%d)%%%d)',
        HOME_LANE, ACCOUNT_ID, LANES))
    finish()
end

function client_handler.on_close(_, reason)
    print('[GATE-ADMIT] client closed: ' .. tostring(reason))
    if not done then
        check(false, 'connection closed before PROCEED (reason='
            .. tostring(reason) .. ')')
        finish()
    end
end

local function start_lanes()
    -- Staff ONLY the home lane the claimed id shards to. The auth lane resolves the
    -- same lane (same zone_def hash) and posts client_admit to WORKER_BASE+lane-1,
    -- so a successful handoff is itself the proof the routing landed correctly.
    worker_tid = WORKER_BASE + HOME_LANE - 1
    assert(xthread.create_thread(worker_tid,
        string.format('gate-worker-%02d', HOME_LANE), 'scripts/gate/worker.lua'))
    assert(xthread.post(worker_tid, 'gate_worker_start', HOME_LANE, LANES))
    assert(xthread.create_thread(AUTH_ID, 'gate-auth', 'scripts/gate/auth_worker.lua'))
    assert(xthread.post(AUTH_ID, 'gate_auth_start', WORKER_BASE, LANES))
end

local function __init()
    print(string.format('[GATE-ADMIT] init: account=%d -> home lane=%d of %d',
        ACCOUNT_ID, HOME_LANE, LANES))
    assert(xnet.init())
    xtimer.init(32)
    start_lanes()

    listener = assert(xnet.listen_fd(HOST, PORT, {
        on_accept = function(_, fd, ip, port)
            -- exactly the cutover wiring: route a fresh client accept to the auth
            -- lane (NOT a round-robin worker) for weak-auth admission.
            local ok, err = xthread.post(AUTH_ID, 'auth_accept', fd, ip, port)
            if not ok then
                io.stderr:write('[GATE-ADMIT] post auth_accept failed: '
                    .. tostring(err) .. '\n')
                return false
            end
            return true
        end,
        on_close = function(_, reason)
            print('[GATE-ADMIT] listener closed: ' .. tostring(reason))
        end,
    }))
    print(string.format('[GATE-ADMIT] listening %s:%d', HOST, PORT))

    connect_timer = xtimer.delay(CONNECT_TIMEOUT_MS, function()
        connect_timer = nil
        if done then return end
        check(false, 'admission timed out after ' .. CONNECT_TIMEOUT_MS .. 'ms')
        finish()
    end)

    local c, err = xnet.connect(HOST, PORT, client_handler)
    if not c then
        check(false, 'xnet.connect failed: ' .. tostring(err))
        finish()
    end
end

local function __uninit()
    cancel_connect_timer()
    if conn then conn:close('uninit'); conn = nil end
    if listener then listener:close('uninit'); listener = nil end
    xnet.uninit()
    print('[GATE-ADMIT] uninit')
end

return {
    __init = __init,
    __uninit = __uninit,
    __thread_handle = router.handle,
}
