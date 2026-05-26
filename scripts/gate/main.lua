-- scripts/gate/main.lua -- gate orchestrator (main thread).
--
-- Threading topology (mirrors the xhttp.lua / xadmin_main.lua model):
--   main thread        : owns the two listen_fd's; forwards accepted sockets
--                        to the workers via xthread.post(fd, ip, port).
--                        Also hosts the NATS client (xthread.NATS) so that
--                        xadmin can reach this process for hot-reload, etc.
--   gate-client worker : owns ALL client connections (LEN16 + AEAD), the
--                        session_id table, and the salt handshake.
--   gate-game worker   : owns the single game connection (LEN16, plaintext).
--
-- Cross-thread message protocol (xthread.post payloads):
--   main          -> client_worker : client_accept(fd, ip, port)
--   main          -> game_worker   : game_accept(fd, ip, port)
--   client_worker -> game_worker   : forward_to_game(sid, body)
--                                    session_gone(sid)
--   game_worker   -> client_worker : forward_to_client(sid, body)
--                                    game_status(up)         -- backend up/down
--
-- NATS responsibilities (handled in __init below):
--   * Publish heartbeat 'xadmin_announce' so the admin console sees this
--     process under its SERVER_NAME.
--   * Publish 'gate_announce' so game services can discover and connect.
--   * Reply gate address RPCs for game side when announce payload has no port.
--   * Reachable for built-in @reload / @reload_thread RPCs via xrouter,
--     which is wired up on main + both workers (__thread_handle = router.handle).
--
-- Run with:  ./bin/xnet scripts/gate/main.lua [SERVER_NAME=gate1]

local xnats  = dofile('scripts/core/server/xnats.lua')
local xutils = require('xutils')
local router = dofile('scripts/core/share/xrouter.lua')
router.set_log_prefix('GATE-MAIN')

local CONFIG_FILE = 'xnet.cfg'
local ok_cfg, cfg_err = xutils.load_config(CONFIG_FILE)
if not ok_cfg then
    xthread.log_info('[GATE-MAIN] config not loaded: %s (using defaults)', tostring(cfg_err))
end

local SERVER_NAME  = XNET_PROCESS_NAME or xutils.get_config('SERVER_NAME', 'gate1')
local CLIENT_HOST  = xutils.get_config('GATE_CLIENT_HOST', '127.0.0.1')
local CLIENT_PORT  = tonumber(xutils.get_config('GATE_CLIENT_PORT', '19180')) or 19180
local INTERNAL_HOST = xutils.get_config('GATE_INTERNAL_HOST', '127.0.0.1')
local INTERNAL_PORT = tonumber(xutils.get_config('GATE_INTERNAL_PORT', '19181')) or 19181
local NATS_HOST    = xutils.get_config('NATS_HOST', '127.0.0.1')
local NATS_PORT    = tonumber(xutils.get_config('NATS_PORT', '4222')) or 4222
local NATS_PREFIX  = xutils.get_config('NATS_PREFIX', 'xnet.test')
local HEARTBEAT_MS = tonumber(xutils.get_config('GATE_HEARTBEAT_MS', '5000')) or 5000

local MAIN_ID          = xthread.MAIN
local CLIENT_WORKER_ID = xthread.WORKER_GRP1
local GAME_WORKER_ID   = xthread.WORKER_GRP1 + 1

local CLIENT_WORKER_SCRIPT = 'scripts/gate/client_worker.lua'
local GAME_WORKER_SCRIPT   = 'scripts/gate/game_worker.lua'

function xthread.register(pt, h) return router.register(pt, h) end

xthread.register('gate_get_internal_addr', function()
    return true, INTERNAL_HOST, INTERNAL_PORT
end)

-- Compatibility alias for callers using a shorter RPC point.
xthread.register('gate_get_addr', function()
    return true, INTERNAL_HOST, INTERNAL_PORT
end)

-- The broker rebroadcasts our own heartbeats back; register no-ops so they
-- land somewhere on the main thread instead of logging "no handler".
xthread.register('xadmin_announce', function(_name) end)
xthread.register('gate_announce',   function(_name, _host, _port) end)

local client_listener
local game_listener
local nats_running = false

local function start_nats()
    -- Only the main thread joins as a NATS worker -- the gate workers don't
    -- subscribe to broadcasts and don't issue cross-process RPCs, so fanning
    -- announces to them just generates "no handler" log noise. Hot-reload
    -- still reaches the workers because xrouter's @reload walks
    -- xthread.all_stats() and posts @reload_thread to every live thread.
    local ok, err = xnats.start({
        host           = NATS_HOST,
        port           = NATS_PORT,
        name           = SERVER_NAME,
        prefix         = NATS_PREFIX,
        workers        = { MAIN_ID },
        reconnect_ms   = 1000,
        rpc_timeout_ms = 10000,
    })
    if not ok then
        xthread.log_error('[GATE-MAIN] xnats.start failed: %s (hot-reload disabled)',
            tostring(err))
        return false
    end
    nats_running = true

    local function heartbeat()
        xnats.publish('xadmin_announce', SERVER_NAME)
        xnats.publish('gate_announce', SERVER_NAME, INTERNAL_HOST, INTERNAL_PORT)
    end
    heartbeat()
    xtimer.add(HEARTBEAT_MS, heartbeat, -1)

    xthread.log_system('[GATE-MAIN] nats=%s:%d prefix=%s name=%s heartbeat=%dms',
        NATS_HOST, NATS_PORT, NATS_PREFIX, SERVER_NAME, HEARTBEAT_MS)
    return true
end

local function __init()
    xthread.log_system('[GATE-MAIN] init server=%s', SERVER_NAME)
    assert(xnet.init())
    xtimer.init(32)

    assert(xthread.create_thread(CLIENT_WORKER_ID, 'gate-client', CLIENT_WORKER_SCRIPT))
    assert(xthread.create_thread(GAME_WORKER_ID,   'gate-game',   GAME_WORKER_SCRIPT))

    -- Tell each worker the other's thread id. Posted before listen_fd starts
    -- so the first accepted fd never reaches a worker without a registered peer.
    assert(xthread.post(CLIENT_WORKER_ID, 'gate_set_peer', GAME_WORKER_ID))
    assert(xthread.post(GAME_WORKER_ID,   'gate_set_peer', CLIENT_WORKER_ID))

    -- NATS is best-effort: if the broker is unreachable, gate still serves
    -- traffic without hot-reload / admin RPC.
    start_nats()

    client_listener = assert(xnet.listen_fd(CLIENT_HOST, CLIENT_PORT, {
        on_accept = function(_, fd, ip, port)
            local ok, err = xthread.post(CLIENT_WORKER_ID, 'client_accept', fd, ip, port)
            if not ok then
                xthread.log_error('[GATE-MAIN] client post failed: %s', tostring(err))
                return false
            end
            return true
        end,
        on_close = function(_, reason)
            xthread.log_info('[GATE-MAIN] client listener closed: %s', tostring(reason))
        end,
    }))
    xthread.log_system('[GATE-MAIN] client listener %s:%d -> thread %d',
        CLIENT_HOST, CLIENT_PORT, CLIENT_WORKER_ID)

    game_listener = assert(xnet.listen_fd(INTERNAL_HOST, INTERNAL_PORT, {
        on_accept = function(_, fd, ip, port)
            local ok, err = xthread.post(GAME_WORKER_ID, 'game_accept', fd, ip, port)
            if not ok then
                xthread.log_error('[GATE-MAIN] game post failed: %s', tostring(err))
                return false
            end
            return true
        end,
        on_close = function(_, reason)
            xthread.log_info('[GATE-MAIN] game listener closed: %s', tostring(reason))
        end,
    }))
    xthread.log_system('[GATE-MAIN] internal listener %s:%d -> thread %d',
        INTERNAL_HOST, INTERNAL_PORT, GAME_WORKER_ID)
end

local function __uninit()
    if client_listener then client_listener:close('uninit'); client_listener = nil end
    if game_listener   then game_listener:close('uninit');   game_listener   = nil end
    if nats_running then xnats.stop(true); nats_running = false end
    xthread.shutdown_thread(CLIENT_WORKER_ID)
    xthread.shutdown_thread(GAME_WORKER_ID)
    xnet.uninit()
    xthread.log_system('[GATE-MAIN] uninit')
end

return {
    __init = __init,
    __uninit = __uninit,
    __thread_handle = router.handle,
}
