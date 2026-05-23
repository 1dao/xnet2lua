-- xadmin_main.lua - admin web console main thread.
-- Owns: xnet listener, NATS client and HTTP server bootstrap.
--
-- Launch with a unique SERVER_NAME, e.g.:
--   bin/xnet scripts/xadmin/xadmin_main.lua SERVER_NAME=xadmin1
--   bin/xnet scripts/xadmin/xadmin_main.lua SERVER_NAME=xadmin2 XADMIN_PORT=18081
--
-- HTTP APIs are handled locally in xadmin_worker.lua.

local xnats = dofile('scripts/core/server/xnats.lua')
local xhttp = dofile('scripts/core/server/xhttp.lua')
local xutils = require('xutils')
local router = dofile('scripts/core/share/xrouter.lua')
router.set_log_prefix('XADMIN-MAIN')

local CONFIG_FILE = 'xnet.cfg'
local ok_cfg, cfg_err = xutils.load_config(CONFIG_FILE)
if not ok_cfg then
    xthread.log_error('[XADMIN-MAIN] config not loaded: %s', tostring(cfg_err))
end

local SERVER_NAME = XNET_PROCESS_NAME or xutils.get_config('SERVER_NAME', 'xadmin1')
local HTTP_HOST = xutils.get_config('XADMIN_HOST', '127.0.0.1')
local HTTP_PORT = tonumber(xutils.get_config('XADMIN_PORT', '18090')) or 18090
local NATS_HOST = xutils.get_config('NATS_HOST', '127.0.0.1')
local NATS_PORT = tonumber(xutils.get_config('NATS_PORT', '4222')) or 4222
local NATS_PREFIX = xutils.get_config('NATS_PREFIX', 'xnet.test')
local HEARTBEAT_MS = tonumber(xutils.get_config('XADMIN_HEARTBEAT_MS', '5000')) or 5000
local TOKEN = xutils.get_config('XADMIN_TOKEN', '')
local HTTP_WORKER_COUNT = 10
local HTTP_WORKER_BASE = xthread.WORKER_GRP3

local function to_bool(v, default)
    if v == nil then return default end
    if v == true or v == 1 or v == '1' or v == 'true' or v == 'yes' or v == 'on' then return true end
    if v == false or v == 0 or v == '0' or v == 'false' or v == 'no' or v == 'off' then return false end
    return default
end

local HTTPS = to_bool(xutils.get_config('XADMIN_HTTPS', '0'), false)
local CERT = xutils.get_config('HTTPS_CERT', 'demo/certs/server.crt')
local KEY  = xutils.get_config('HTTPS_KEY',  'demo/certs/server.key')
local KEY_PASSWORD = xutils.get_config('HTTPS_KEY_PASSWORD', '')

local MAIN_ID = xthread.MAIN

function xthread.register(pt, h) return router.register(pt, h) end

xthread.register('xadmin_announce', function(name)
    local _ = name
end)

-- Backward-compatible alias for callers still using xadmin_remote_exec.
xthread.register('xadmin_remote_exec', function(src)
    local h = router.stubs['@run_script']
    if type(h) ~= 'function' then
        return false, '', '@run_script builtin not available'
    end
    return h(tostring(src or ''))
end)

local function __init()
    xthread.log_system('[XADMIN-MAIN] init server=%s http=%s://%s:%d nats=%s:%d prefix=%s',
        SERVER_NAME, HTTPS and 'https' or 'http', HTTP_HOST, HTTP_PORT,
        NATS_HOST, NATS_PORT, NATS_PREFIX)
    if TOKEN ~= '' then
        xthread.log_info('[XADMIN-MAIN] auth: X-Xadmin-Token required')
    else
        xthread.log_info('[XADMIN-MAIN] auth: open (set XADMIN_TOKEN to require a token)')
    end

    assert(xnet.init())
    xtimer.init(32)

    local nats_workers = { MAIN_ID }
    for i = 0, HTTP_WORKER_COUNT - 1 do
        nats_workers[#nats_workers + 1] = HTTP_WORKER_BASE + i
    end

    local ok, err = xnats.start({
        host = NATS_HOST,
        port = NATS_PORT,
        name = SERVER_NAME,
        prefix = NATS_PREFIX,
        workers = nats_workers,
        reconnect_ms = 1000,
        rpc_timeout_ms = 10000,
    })
    if not ok then error(err) end

    ok, err = xhttp.start({
        host = HTTP_HOST,
        port = HTTP_PORT,
        https = HTTPS,
        cert_file = CERT,
        key_file = KEY,
        key_password = KEY_PASSWORD,
        worker_count = HTTP_WORKER_COUNT,
        worker_base = HTTP_WORKER_BASE,
        worker_name = 'xadmin-worker',
        worker_script = 'scripts/xadmin/xadmin_worker.lua',
        app_script = 'scripts/xadmin/xadmin_app.lua',
        max_request_size = 4 * 1024 * 1024,
        server_name = 'xnet-xadmin',
    })
    if not ok then error(err) end

    -- Push caller-side routing info to HTTP workers so xnats.rpc(SELF, ...)
    -- on those threads short-circuits straight into the local business
    -- worker without bouncing through the NATS thread.
    xnats.bind_workers(xhttp.worker_ids())

    local function heartbeat()
        xnats.publish('xadmin_announce', SERVER_NAME)
    end
    heartbeat()
    xtimer.add(HEARTBEAT_MS, heartbeat, -1)

    xthread.log_system('[XADMIN-MAIN] open %s://%s:%d/', HTTPS and 'https' or 'http', HTTP_HOST, HTTP_PORT)
end

local function __uninit()
    xhttp.stop()
    xnats.stop(true)
    xnet.uninit()
    xthread.log_system('[XADMIN-MAIN] uninit')
end

return {
    __init = __init,
    __thread_handle = router.handle,
    __uninit = __uninit,
    __tick_ms = 10,
}
