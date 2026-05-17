-- xadmin_worker.lua -- HTTP worker for the xadmin console.
--
-- Built on scripts/core/share/xsession.lua + xhttp_router. Each connection
-- runs one session coroutine that dispatches HTTP requests serially through
-- the app handler. Inside an app handler you may freely call xnats.rpc /
-- xthread.rpc -- the session co yields, the C @async_resume path drives
-- the response back, and pipelined requests on the same conn queue without
-- being re-resumed (see xsession.lua for the state machine).
--
-- TLS: xhttp_accept switches between xnet.attach and xnet.attach_tls based
-- on use_https; xsession's connection bookkeeping is unchanged either way.

local xsession = dofile('scripts/core/share/xsession.lua')
local codec    = dofile('scripts/core/share/xhttp_codec.lua')
local router   = dofile('scripts/core/share/xrouter.lua')
local _xnats   = dofile('scripts/core/server/xnats.lua')
local xutils   = require('xutils')

router.set_log_prefix('XADMIN-WORKER')
router.set_unknown_rpc(function(reply_router, co_id, sk, pt, ...)
    local _ = reply_router
    _ = co_id
    _ = sk
    _ = ...
    io.stderr:write('[XADMIN-WORKER] unexpected RPC message: ' .. tostring(pt) .. '\n')
end)

local app = nil
local app_script = nil
local max_request_size = 4 * 1024 * 1024
local server_name = 'xnet-xadmin'
local use_https = false
local tls_config = nil

-- ---------------------------------------------------------------------------
-- Reload-persistent state (survives `dofile` of this script during reload)
-- ---------------------------------------------------------------------------
local STATE_KEY = '__xnet_xadmin_worker_state'
local state = rawget(_G, STATE_KEY)
if type(state) ~= 'table' then
    state = {}
    rawset(_G, STATE_KEY, state)
end

if state.max_request_size == nil then state.max_request_size = max_request_size end
if state.server_name == nil then state.server_name = server_name end
if state.use_https == nil then state.use_https = use_https end
if type(state.connections) ~= 'table' then state.connections = {} end
if type(state.peers) ~= 'table' then state.peers = {} end
state.loaded = true

app              = state.app
app_script       = state.app_script
max_request_size = state.max_request_size or max_request_size
server_name      = state.server_name or server_name
use_https        = state.use_https and true or false
tls_config       = state.tls_config

local connections = state.connections
local peers      = state.peers

local SELF_NAME      = XNET_PROCESS_NAME or xutils.get_config('SERVER_NAME', 'xadmin1')
local TOKEN_REQUIRED = xutils.get_config('XADMIN_TOKEN', '') ~= ''
local PEER_TTL_MS    = tonumber(xutils.get_config('XADMIN_PEER_TTL_MS', '15000')) or 15000

function xthread.register(pt, h) return router.register(pt, h) end

local function now_ms()
    if xtimer and xtimer.now_ms then
        return xtimer.now_ms()
    end
    return math.floor(os.time() * 1000)
end

-- ---------------------------------------------------------------------------
-- Peer cache (fed by xadmin_announce broadcasts on the NATS broadcast subject)
-- ---------------------------------------------------------------------------
local function note_peer(name)
    name = tostring(name or '')
    if name == '' then return end
    peers[name] = now_ms()
end

local function alive_peers()
    local cutoff = now_ms() - PEER_TTL_MS
    local out = {}
    for name, last in pairs(peers) do
        if last >= cutoff then
            out[#out + 1] = { name = name, last_seen_ms = last }
        end
    end
    table.sort(out, function(a, b) return a.name < b.name end)
    return out
end

xthread.register('xadmin_announce', function(name)
    if name and name ~= SELF_NAME then
        note_peer(name)
    end
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
-- App loader
-- ---------------------------------------------------------------------------
local function build_app_context()
    return {
        self_name      = SELF_NAME,
        token_required = TOKEN_REQUIRED,
        alive_peers    = alive_peers,
        now_ms         = now_ms,
    }
end

local function load_app(path)
    app_script = path
    local loaded = dofile(path)
    if type(loaded) == 'function' then
        app = { handle = loaded }
    elseif type(loaded) == 'table' then
        app = loaded
    else
        error('xadmin app script must return a table or function')
    end
    if type(app.setup) == 'function' then
        local ok, err = pcall(app.setup, build_app_context())
        if not ok then
            io.stderr:write('[XADMIN-WORKER] app.setup failed: ' .. tostring(err) .. '\n')
        end
    end
    state.app = app
    state.app_script = app_script
end

if app_script then
    local ok, err = pcall(load_app, app_script)
    if not ok then
        io.stderr:write('[XADMIN-WORKER] reload app failed: ' .. tostring(err) .. '\n')
    end
end

-- ---------------------------------------------------------------------------
-- xsession server handler
-- ---------------------------------------------------------------------------
-- Wraps the app via http_router-shape adapter so xsession can dispatch it.
-- The wrapper handles "app not loaded", pcall-catches handler errors, and
-- normalizes non-table returns to a 500.
local app_router = {
    handle = function(req)
        if not app or type(app.handle) ~= 'function' then
            return { status = 500, body = 'xadmin app not loaded\n' }
        end
        local ok, resp = pcall(app.handle, req)
        if not ok then
            io.stderr:write('[XADMIN-WORKER] app error: ' .. tostring(resp) .. '\n')
            return { status = 500, body = 'internal server error\n' }
        end
        if type(resp) ~= 'table' then
            return { status = 500, body = 'invalid app response\n' }
        end
        return resp
    end,
}

local handler = xsession.make({
    -- No spec.framing -- max_request_size may change after xhttp_worker_start
    -- arrives, so framing is applied lazily in on_connect below.
    parse_packet = function(data, pos, _, cstate)
        return codec.parse_request(data, pos, {
            max_request_size = max_request_size,
            state = cstate,
        })
    end,

    classify = function(_) return 'rpc' end,  -- HTTP serializes per fd

    send_response = function(conn, req, resp)
        codec.send_response(conn, req, resp, { server_name = server_name })
    end,

    on_parse_error = function(conn, err)
        local status = (err == 'request too large' or err == 'request body too large')
            and 413 or 400
        codec.send_error(conn, status, err, { server_name = server_name })
    end,

    http_router = app_router,

    on_connect = function(conn, _, _)
        conn:set_framing({ type = 'raw', max_packet = max_request_size })
    end,

    log_prefix    = 'XADMIN-WORKER',
    max_queue_len = 256,
    connections   = connections,
})

-- ---------------------------------------------------------------------------
-- Lifecycle xthread messages
-- ---------------------------------------------------------------------------
xthread.register('xhttp_worker_start', function(script_path, max_size, name,
                                                https, cert_file, key_file, key_password)
    max_request_size = tonumber(max_size) or max_request_size
    server_name = name or server_name
    use_https = https and true or false
    if use_https then
        tls_config = {
            cert_file = cert_file,
            key_file = key_file,
            password = key_password ~= '' and key_password or nil,
            max_packet = max_request_size,
        }
    else
        tls_config = nil
    end
    state.max_request_size = max_request_size
    state.server_name = server_name
    state.use_https = use_https
    state.tls_config = tls_config
    load_app(script_path)
    print(string.format('[XADMIN-WORKER] start scheme=%s app=%s',
        use_https and 'https' or 'http', tostring(script_path)))
end)

xthread.register('xhttp_accept', function(fd, ip, port)
    local conn, err
    if use_https then
        conn, err = xnet.attach_tls(fd, handler, ip, port, tls_config)
    else
        conn, err = xnet.attach(fd, handler, ip, port)
    end
    if not conn then
        io.stderr:write('[XADMIN-WORKER] attach failed: ' .. tostring(err) .. '\n')
    end
end)

xthread.register('xhttp_worker_stop', function()
    handler.close_all('xhttp_worker_stop')
end)

local function __init()
    print('[XADMIN-WORKER] init')
    assert(xnet.init())
end

local function __uninit()
    handler.close_all('worker_uninit')
    xnet.uninit()
    print('[XADMIN-WORKER] uninit')
end

return {
    __init = __init,
    __uninit = __uninit,
    __thread_handle = router.handle,
}
