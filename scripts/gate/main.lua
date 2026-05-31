-- scripts/gate/main.lua -- affinity gate orchestrator.
--
-- The main thread owns accept, admission for battle connections, and NATS
-- discovery. Each gate worker owns both its client sessions and the same-lane
-- battle connection, so gameplay packets are forwarded without a cross-thread
-- hop inside gate.
--
-- Client admission protocol (client -> gate, weak-auth scheme, design §4/§19.0
-- 身份 ≠ 位置): a new client accept does NOT go to a round-robin worker. It goes to
-- the auth lane first, which resolves the login frame to a permanent account_id,
-- shards lane = hash(account_id)%T (zone_def's single affinity hash site), and hands
-- the bare fd to that lane's worker -- so the session lands on the SAME lane its
-- battle home / persistent state use. The worker sends a 1-byte PROCEED ack and then
-- runs the existing salt/AEAD handshake. No AEAD state is migrated (none exists yet),
-- so the handoff is a cheap fd move. (recv half: gate/worker.lua client_admit; send
-- half: gate/auth_worker.lua; proven over real sockets by demo/gate_admit_main.lua.)
--
-- Internal admission protocol (battle -> gate, single port):
--   1. battle connects to GATE_INTERNAL_PORT
--   2. battle sends HELLO frame [lane_idx:1B] (LEN16-framed), then waits
--   3. main attaches conn briefly, validates lane_idx, detaches the fd,
--      and posts it to worker_ids[lane_idx]
--   4. target worker re-attaches, sends ACK byte 0x01 back
--   5. battle receives ACK, starts forwarding real traffic
-- All subsequent business packets bypass main entirely.
--
-- Run with: ./bin/xnet scripts/gate/main.lua SERVER_NAME=gate1

local xnats    = dofile('scripts/core/server/xnats.lua')
local xutils   = require('xutils')
local router   = dofile('scripts/core/share/xrouter.lua')
local zone_def = dofile('scripts/game/zone_def.lua')
router.set_log_prefix('GATE-MAIN')

local ok_cfg, cfg_err = xutils.load_config('xnet.cfg')
if not ok_cfg then
    xthread.log_info('[GATE-MAIN] config not loaded: %s (using defaults)', tostring(cfg_err))
end

local SERVER_NAME = XNET_PROCESS_NAME or xutils.get_config('SERVER_NAME', 'gate1')
local CLIENT_HOST = xutils.get_config('GATE_CLIENT_HOST', '127.0.0.1')
local CLIENT_PORT = tonumber(xutils.get_config('GATE_CLIENT_PORT', '19180')) or 19180
local INTERNAL_HOST = xutils.get_config('GATE_INTERNAL_HOST', '127.0.0.1')
local INTERNAL_PORT = tonumber(xutils.get_config('GATE_INTERNAL_PORT', '19181')) or 19181
local WORKER_COUNT = tonumber(xutils.get_config('GATE_WORKERS', '6')) or 6
local NATS_HOST = xutils.get_config('NATS_HOST', '127.0.0.1')
local NATS_PORT = tonumber(xutils.get_config('NATS_PORT', '4222')) or 4222
local NATS_PREFIX = xutils.get_config('NATS_PREFIX', 'xnet.test')
local HEARTBEAT_MS = tonumber(xutils.get_config('GATE_HEARTBEAT_MS', '5000')) or 5000

local MAIN_ID = xthread.MAIN
local WORKER_BASE = xthread.WORKER_GRP1
local WORKER_SCRIPT = 'scripts/gate/worker.lua'

-- Weak-auth admission lane (design §4/§19.0). New client accepts land HERE first;
-- it resolves the login frame to a permanent account_id and hands the fd to the
-- owning lane's worker. Placed off the worker group (WORKER_GRP2) so its tid can
-- never collide with a lane worker (WORKER_GRP1 + lane - 1).
local AUTH_ID = xthread.WORKER_GRP2
local AUTH_SCRIPT = 'scripts/gate/auth_worker.lua'

assert(WORKER_COUNT >= 1 and WORKER_COUNT <= 20, 'GATE_WORKERS must be in [1,20]')
assert(CLIENT_PORT >= 1 and CLIENT_PORT <= 65535, 'GATE_CLIENT_PORT must be in [1,65535]')
assert(INTERNAL_PORT >= 1 and INTERNAL_PORT <= 65535,
    'GATE_INTERNAL_PORT must be in [1,65535]')
-- The auth lane shards by hash(account_id) % zone_def.LANE_COUNT and posts to
-- WORKER_BASE + lane - 1, so the lane->worker map must be exactly 1:1 (the single
-- affinity hash site, design §19.1 hook 2). Fail loud rather than silently mis-route.
assert(WORKER_COUNT == zone_def.LANE_COUNT, string.format(
    'GATE_WORKERS (%d) must equal zone_def.LANE_COUNT (%d) for admission routing',
    WORKER_COUNT, zone_def.LANE_COUNT))

function xthread.register(pt, h) return router.register(pt, h) end

local worker_ids = {}
local internal_listener
local admission_pending = {}     -- conn -> { ip, port }
local client_listener
local heartbeat_timer
local nats_running = false

xthread.register('gate_get_internal_addr', function()
    return true, INTERNAL_HOST, INTERNAL_PORT, WORKER_COUNT
end)

xthread.register('gate_get_addr', function()
    return true, INTERNAL_HOST, INTERNAL_PORT, WORKER_COUNT
end)

xthread.register('gate_get_topology', function()
    return true, INTERNAL_HOST, INTERNAL_PORT, WORKER_COUNT
end)

-- NATS broadcasts are looped to the publishing process too.
xthread.register('xadmin_announce', function(_name) end)
xthread.register('gate_announce', function(_name, _host, _port, _workers) end)

local function start_workers()
    for lane = 1, WORKER_COUNT do
        local tid = WORKER_BASE + lane - 1
        local ok, err = xthread.create_thread(tid,
            string.format('gate-worker-%02d', lane), WORKER_SCRIPT)
        assert(ok, err)
        worker_ids[lane] = tid
        ok, err = xthread.post(tid, 'gate_worker_start', lane, WORKER_COUNT)
        assert(ok, err)
    end
end

local function stop_workers()
    for lane = #worker_ids, 1, -1 do
        xthread.shutdown_thread(worker_ids[lane])
        worker_ids[lane] = nil
    end
end

-- The auth lane must come up AFTER the workers (so a handoff always finds its
-- target lane) and is told the worker group's base tid + count: lane L's worker is
-- WORKER_BASE + L - 1, the same arithmetic start_workers uses.
local function start_auth()
    local ok, err = xthread.create_thread(AUTH_ID, 'gate-auth', AUTH_SCRIPT)
    assert(ok, err)
    ok, err = xthread.post(AUTH_ID, 'gate_auth_start', WORKER_BASE, WORKER_COUNT)
    assert(ok, err)
end

local function stop_auth()
    xthread.shutdown_thread(AUTH_ID)
end

local function publish_heartbeat()
    if not nats_running then return end
    xnats.publish('xadmin_announce', SERVER_NAME)
    xnats.publish('gate_announce', SERVER_NAME, INTERNAL_HOST, INTERNAL_PORT, WORKER_COUNT)
end

local function start_nats()
    local ok, err = xnats.start({
        host = NATS_HOST,
        port = NATS_PORT,
        name = SERVER_NAME,
        prefix = NATS_PREFIX,
        workers = { MAIN_ID },
        reconnect_ms = 1000,
        rpc_timeout_ms = 10000,
    })
    if not ok then
        xthread.log_error('[GATE-MAIN] xnats.start failed: %s', tostring(err))
        return
    end
    nats_running = true
    publish_heartbeat()
    heartbeat_timer = xtimer.add(HEARTBEAT_MS, publish_heartbeat, -1)
end

local function listen_clients()
    client_listener = assert(xnet.listen_fd(CLIENT_HOST, CLIENT_PORT, {
        on_accept = function(_, fd, ip, port)
            -- Weak-auth admission (design §4/§19.0): every new client goes to the
            -- auth lane first, NOT a round-robin worker. The auth lane resolves the
            -- login frame to account_id, shards lane = hash(account_id)%T, and hands
            -- the fd to that lane's worker. A worker is never picked here anymore.
            local ok, err = xthread.post(AUTH_ID, 'auth_accept', fd, ip, port)
            if not ok then
                xthread.log_error('[GATE-MAIN] client accept -> auth post failed: %s',
                    tostring(err))
                return false
            end
            return true
        end,
        on_close = function(_, reason)
            xthread.log_info('[GATE-MAIN] client listener closed: %s', tostring(reason))
        end,
    }))
    xthread.log_system('[GATE-MAIN] clients %s:%d workers=%d',
        CLIENT_HOST, CLIENT_PORT, WORKER_COUNT)
end

local admission_handler = {}

function admission_handler.on_connect(conn, ip, port)
    -- HELLO is a single byte; cap the recv buffer so a misbehaving peer
    -- can't flood us pre-handshake.
    conn:set_framing({ type = 'len16', max_packet = 64 })
    admission_pending[conn] = { ip = ip, port = port }
end

function admission_handler.on_packet(conn, body)
    local st = admission_pending[conn]
    if not st then
        -- packet arrived after HELLO was already processed -- shouldn't
        -- happen because we detach immediately on success, but defensively
        -- close to surface protocol bugs.
        conn:close('admission_extra_packet')
        return
    end
    if #body < 1 then
        admission_pending[conn] = nil
        conn:close('hello_too_short')
        return
    end
    local lane_idx = string.byte(body, 1)
    if lane_idx < 1 or lane_idx > WORKER_COUNT then
        xthread.log_error(
            '[GATE-MAIN] admission: bad lane=%d from %s:%s (workers=%d)',
            lane_idx, tostring(st.ip), tostring(st.port), WORKER_COUNT)
        admission_pending[conn] = nil
        conn:close('hello_lane_out_of_range')
        return
    end

    local target_tid = worker_ids[lane_idx]
    admission_pending[conn] = nil

    -- Surrender the fd: conn becomes unusable, fd remains open.
    local fd = conn:detach()
    local ok, err = xthread.post(target_tid, 'battle_accept', fd, st.ip, st.port)
    if not ok then
        xthread.log_error(
            '[GATE-MAIN] admission: post lane=%d tid=%d failed: %s; closing fd',
            lane_idx, target_tid, tostring(err))
        xnet.close_fd(fd)
        return
    end
    xthread.log_info('[GATE-MAIN] admission: lane=%d from %s:%s -> tid=%d',
        lane_idx, tostring(st.ip), tostring(st.port), target_tid)
end

function admission_handler.on_close(conn, reason)
    if admission_pending[conn] then
        admission_pending[conn] = nil
        xthread.log_info('[GATE-MAIN] admission closed pre-hello: %s',
            tostring(reason))
    end
end

local function listen_battles()
    internal_listener = assert(xnet.listen(INTERNAL_HOST, INTERNAL_PORT,
        admission_handler))
    xthread.log_system('[GATE-MAIN] internal admission %s:%d workers=%d',
        INTERNAL_HOST, INTERNAL_PORT, WORKER_COUNT)
end

local function __init()
    xthread.log_system('[GATE-MAIN] init server=%s workers=%d', SERVER_NAME, WORKER_COUNT)
    assert(xnet.init())
    xtimer.init(32)
    start_workers()
    start_auth()
    start_nats()
    listen_clients()
    listen_battles()
end

local function __uninit()
    if heartbeat_timer then heartbeat_timer:del(); heartbeat_timer = nil end
    if client_listener then client_listener:close('uninit'); client_listener = nil end
    if internal_listener then internal_listener:close('uninit'); internal_listener = nil end
    for conn in pairs(admission_pending) do conn:close('uninit') end
    admission_pending = {}
    if nats_running then xnats.stop(true); nats_running = false end
    -- Stop the auth lane before the workers so no late accept is handed to a
    -- lane that is already tearing down.
    stop_auth()
    stop_workers()
    xnet.uninit()
    xthread.log_system('[GATE-MAIN] uninit')
end

return {
    __init = __init,
    __uninit = __uninit,
    __thread_handle = router.handle,
}
