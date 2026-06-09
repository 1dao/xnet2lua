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
local xmysql = dofile('scripts/core/server/xmysql.lua')
local store = dofile('scripts/xadmin/xadmin_store.lua')
local xutils = require('xutils')
local router = dofile('scripts/core/share/xrouter.lua')
local to_bool = dofile('scripts/core/share/xmisc.lua').to_bool
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
local SUPER_TOKEN = xutils.get_config('XADMIN_SUPER_TOKEN', '')
-- mTLS: PEM file with the CA bundle that signs accepted client certs. When
-- non-empty, xhttp runs in mTLS mode and every /api/ request must present a
-- cert verifiable against this CA. The peer cert's subject DN is exposed on
-- req.peer_cert_subject.
local TLS_CA_FILE = xutils.get_config('XADMIN_TLS_CA_FILE', '')
local HTTP_WORKER_COUNT = 10
local HTTP_WORKER_BASE = xthread.WORKER_GRP3

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

-- ---------------------------------------------------------------------------
-- Outbound HTTP bridge for OAuth2 / OIDC discovery (called by workers via
-- xthread.post(MAIN, 'xadmin_oauth_http', request_id, opts)). Runs
-- xhttp_client.request asynchronously and posts the result back to the
-- originating worker thread, which resumes a session coroutine that was
-- yielded on async_http_call. This lives on MAIN because MAIN has its own
-- xnet event loop and can drive xhttp_client without blocking the workers.
-- ---------------------------------------------------------------------------
local httpc = dofile('scripts/core/share/xhttp_client.lua')
xthread.register('xadmin_oauth_http', function(request_id, opts)
    local worker_id = xthread.current_id and xthread.current_id() or 0
    -- Note: opts may have come from a worker (untrusted by definition, but
    -- the only sender is our own worker so we accept the trust assumption).
    -- xhttp_client uses xnet.connect(_tls) which requires this thread to
    -- have called xnet.init(); MAIN does so in __init.
    httpc.request(opts or {}, function(err, resp)
        -- Fire-and-forget reply: target the worker that originated the call
        -- (re-derived from request_id so we don't have to trust opts).
        local target = request_id:match('^(%d+):') and tonumber(request_id:match('^(%d+):')) or worker_id
        xthread.post(target, '@xadmin_oauth_reply', request_id, err, resp)
    end)
    return true   -- handler returns immediately; the callback delivers the real result
end)

-- ---------------------------------------------------------------------------
-- MySQL lifecycle (owned by the main thread)
-- ---------------------------------------------------------------------------
-- The pool connects WITHOUT a default database so the setup flow can create it;
-- queries fully qualify table names with the configured database name.
local function mysql_config(db)
    return {
        host = db.host,
        port = db.port,
        user = db.user,
        password = db.password,
        database = '',
        pool_size = 2,
        reconnect_ms = 1000,
        max_reply_size = 4 * 1024 * 1024,
    }
end

local function start_mysql(db)
    return xmysql.start(mysql_config(db))
end

-- Worker setup flow calls this to (re)point the pool at the submitted creds.
xthread.register('xadmin_db_apply', function(host, port, user, password)
    local db = { host = host, port = port, user = user, password = password }
    local ok, err
    if xmysql.running() then
        -- Reconfigure the EXISTING pool in place (close sockets + reconnect on
        -- the same thread). Do NOT shutdown_thread here: tearing the live MySQL
        -- thread down mid-process corrupts other threads' poll state and sends
        -- the process into an error spin. This path is hit on every setup retry
        -- (e.g. after a first attempt with wrong credentials).
        ok, err = xmysql.reconfigure(mysql_config(db))
    else
        ok, err = start_mysql(db)
    end
    if not ok then
        return false, tostring(err)
    end
    xthread.log_system('[XADMIN-MAIN] mysql pool (re)started %s@%s:%s',
        tostring(user), tostring(host), tostring(port))
    return true
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
    if SUPER_TOKEN ~= '' then
        xthread.log_info('[XADMIN-MAIN] auth: master bypass token ENABLED (X-Xadmin-Super-Token)')
    end
    if to_bool(xutils.get_config('XADMIN_DEV_NO_AUTH', '0'), false) then
        xthread.log_error('[XADMIN-MAIN] auth: DEV_NO_AUTH ENABLED -- ALL '
            .. 'authentication AND authorization are DISABLED (every request is '
            .. 'admin). LOCAL TESTING ONLY; never use in production.')
    end
    if TLS_CA_FILE ~= '' then
        -- mTLS requires TLS. Without XADMIN_HTTPS=1 the worker never builds a
        -- TLS config, so the CA file is silently ignored and NO client-cert
        -- check happens -- while we'd otherwise log "mTLS ENABLED". Fail loud
        -- instead of advertising a security control that isn't active.
        if not HTTPS then
            error('[XADMIN-MAIN] XADMIN_TLS_CA_FILE is set but XADMIN_HTTPS is not '
                .. 'enabled; mTLS needs TLS. Set XADMIN_HTTPS=1 (with HTTPS_CERT/'
                .. 'HTTPS_KEY), or unset XADMIN_TLS_CA_FILE.')
        end
        xthread.log_info('[XADMIN-MAIN] auth: mTLS ENABLED (CA=%s)', TLS_CA_FILE)
    end
    -- OAuth2 / JWT providers are listed in the log so misconfiguration is
    -- obvious at startup. Providers are configured via XADMIN_OAUTH_<NAME>_{CLIENT_ID,CLIENT_SECRET,AUTH_URL,TOKEN_URL,USERINFO_URL,SCOPE}.
    local oauth_providers = xutils.get_config('XADMIN_OAUTH_PROVIDERS', '')
    if oauth_providers and oauth_providers ~= '' then
        xthread.log_info('[XADMIN-MAIN] auth: OAuth2 providers=%s', oauth_providers)
    end
    local jwt_secret = xutils.get_config('XADMIN_JWT_HS256_SECRET', '')
    if jwt_secret ~= '' then
        xthread.log_info('[XADMIN-MAIN] auth: JWT HS256 ENABLED (aud=%s iss=%s)',
            tostring(xutils.get_config('XADMIN_JWT_AUDIENCE', 'xadmin')),
            tostring(xutils.get_config('XADMIN_JWT_ISSUER', '*')))
    end
    -- Pre-generate + persist the OAuth state-signing secret here on MAIN, before
    -- any worker serves a request, so the HTTP workers don't race to each
    -- generate and overwrite a *different* secret (which would make in-flight
    -- OAuth round-trips fail state verification). Only needed when OAuth is used.
    if oauth_providers and oauth_providers ~= '' then
        local auth = dofile('scripts/xadmin/xadmin_auth.lua')
        local secret, serr = auth.get_state_secret()
        if not secret then
            xthread.log_error('[XADMIN-MAIN] oauth state secret: %s', tostring(serr))
        end
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
        ca_file = TLS_CA_FILE,
        worker_count = HTTP_WORKER_COUNT,
        worker_base = HTTP_WORKER_BASE,
        worker_name = 'xadmin-worker',
        worker_script = 'scripts/xadmin/xadmin_worker.lua',
        app_script = 'scripts/xadmin/xadmin_app.lua',
        max_request_size = 4 * 1024 * 1024,
        server_name = 'xnet-xadmin',
    })
    if not ok then error(err) end

    -- Start the MySQL pool now if the console was configured in a prior run, or
    -- if xnet.cfg already fully specifies the DB (so first-time setup can reach
    -- it to create the admin). Otherwise it starts lazily via xadmin_db_apply.
    local store_cfg = store.load_db_config()
    local db = store_cfg.db or {}
    -- Authorization: admin endpoints (/api/exec, /api/reload) require the
    -- 'admin' role, granted to the setup admin (persisted as admin_user) plus
    -- XADMIN_ADMINS. A console configured before admin_user was persisted has
    -- no admin unless XADMIN_ADMINS is set -- warn so it isn't a silent lockout.
    if store_cfg.configured and (not store_cfg.admin_user or store_cfg.admin_user == '')
        and xutils.get_config('XADMIN_ADMINS', '') == '' then
        xthread.log_error('[XADMIN-MAIN] auth: no admin principal defined '
            .. '(legacy config has no admin_user); set XADMIN_ADMINS=<user> or '
            .. 're-run setup, else /api/exec and /api/reload are denied to everyone')
    end
    if (store_cfg.configured or store_cfg.db_from_cfg) and db.host then
        local mok, merr = start_mysql(db)
        if mok then
            xthread.log_system('[XADMIN-MAIN] mysql pool started %s@%s:%s db=%s (source=%s)',
                tostring(db.user), tostring(db.host), tostring(db.port),
                tostring(db.database), store_cfg.db_from_cfg and 'xnet.cfg' or 'xadmin_db.json')
        else
            xthread.log_error('[XADMIN-MAIN] mysql start failed: %s', tostring(merr))
        end
    else
        xthread.log_info('[XADMIN-MAIN] not configured yet; open the web console to set up the database')
    end

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
    if xmysql.running() then
        xmysql.stop(true)
    end
    xnet.uninit()
    xthread.log_system('[XADMIN-MAIN] uninit')
end

return {
    __init = __init,
    __thread_handle = router.handle,
    __uninit = __uninit,
    __tick_ms = 10,
}
