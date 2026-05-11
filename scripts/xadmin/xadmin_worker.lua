-- xadmin_worker.lua - HTTP worker for the xadmin console.
--
-- Each HTTP request runs inside its own dispatch coroutine. The route handler
-- in scripts/xadmin/xadmin_app.lua may call xnats.rpc(...) (which yields when
-- it goes through the NATS thread) and the response is sent back from the
-- coroutine when the call returns. There is no "{async=true, action=...}"
-- marker any more, no per-request `pending` table, and no `send_*_reply`
-- shims; on_packet → coroutine → app.handle → codec.send_response is the
-- whole chain.
--
-- Pipelining: HTTP/1.1 requires responses on the same connection to be
-- delivered in arrival order. Each connection has at most one in-flight
-- coroutine; further parsed requests on the same conn go into a per-conn
-- queue and are started after the previous response has been sent.

local codec = dofile('scripts/core/share/xhttp_codec.lua')
local router = dofile('scripts/core/share/xrouter.lua')
local xnats = dofile('scripts/core/server/xnats.lua')
local xutils = require('xutils')

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
-- Reload-persistent state
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

app          = state.app
app_script   = state.app_script
max_request_size = state.max_request_size or max_request_size
server_name  = state.server_name or server_name
use_https    = state.use_https and true or false
tls_config   = state.tls_config

local connections = state.connections
local peers       = state.peers

local SELF_NAME = XNET_PROCESS_NAME or xutils.get_config('SERVER_NAME', 'xadmin1')
local TOKEN_REQUIRED = xutils.get_config('XADMIN_TOKEN', '') ~= ''
local PEER_TTL_MS = tonumber(xutils.get_config('XADMIN_PEER_TTL_MS', '15000')) or 15000

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
-- App loader: provides the route module (xadmin_app.lua) with worker-local
-- helpers (peer cache, identity, etc.) via app.setup(context).
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
-- Request dispatch
-- ---------------------------------------------------------------------------
local function dispatch_request(req)
    if not app or type(app.handle) ~= 'function' then
        return { status = 500, body = 'xadmin app not loaded\n' }
    end
    local resp = app.handle(req)
    if type(resp) ~= 'table' then
        return { status = 500, body = 'invalid app response\n' }
    end
    return resp
end

local start_request

-- Drain the next queued request on this connection (called after the previous
-- response has been written).
local function pump_queue(conn, cstate)
    if not cstate then return end
    local item = table.remove(cstate.queue, 1)
    if not item then
        cstate.busy = false
        cstate.inflight_co = nil
        return
    end
    start_request(conn, item.req, item.send_opts, cstate)
end

start_request = function(conn, req, send_opts, cstate)
    cstate.busy = true
    local co = coroutine.create(function()
        local ok, resp = pcall(dispatch_request, req)
        if not ok then
            io.stderr:write('[XADMIN-WORKER] app error: ' .. tostring(resp) .. '\n')
            resp = { status = 500, body = 'internal server error\n' }
        end
        if conn:fd() >= 0 then
            local sok, serr = pcall(codec.send_response, conn, req, resp, send_opts)
            if not sok then
                io.stderr:write('[XADMIN-WORKER] send_response error: ' .. tostring(serr) .. '\n')
            end
        end
        pump_queue(conn, cstate)
    end)
    cstate.inflight_co = co
    local ok, err = coroutine.resume(co)
    if not ok then
        io.stderr:write('[XADMIN-WORKER] dispatch coroutine failed: ' .. tostring(err) .. '\n')
        -- Coroutine crashed before yielding/sending a response. Best-effort
        -- 500 then move on so the next queued request can still run.
        if conn:fd() >= 0 then
            pcall(codec.send_error, conn, 500, 'internal server error', send_opts)
        end
        pump_queue(conn, cstate)
    end
end

-- ---------------------------------------------------------------------------
-- HTTP socket handler
-- ---------------------------------------------------------------------------
local server_handler = {}

function server_handler.on_connect(conn, ip, port)
    connections[conn] = {
        ip = ip,
        port = port,
        busy = false,
        inflight_co = nil,
        queue = {},
    }
    conn:set_framing({ type = 'raw', max_packet = max_request_size })
end

function server_handler.on_packet(conn, data)
    local cstate = connections[conn]
    if not cstate then return #data end
    local pos = 1
    local consumed = 0
    local data_len = #data
    local send_opts = { server_name = server_name }

    while pos <= data_len do
        local req, next_pos, err = codec.parse_request(data, pos, {
            max_request_size = max_request_size,
            state = cstate,
        })
        if not req then
            if err == 'incomplete' then break end
            codec.send_error(conn, err == 'request body too large' and 413 or 400, err, send_opts)
            return data_len
        end

        if cstate.busy then
            cstate.queue[#cstate.queue + 1] = { req = req, send_opts = send_opts }
        else
            start_request(conn, req, send_opts, cstate)
        end

        consumed = next_pos - 1
        pos = next_pos
    end

    return consumed
end

function server_handler.on_close(conn, reason)
    local _ = reason
    local cstate = connections[conn]
    connections[conn] = nil
    if cstate then
        -- Drop any queued requests; the in-flight coroutine (if any) will
        -- discover the dead fd via conn:fd() < 0 when it resumes and skip
        -- writing a response.
        cstate.queue = {}
        cstate.busy = false
        cstate.inflight_co = nil
    end
end

-- ---------------------------------------------------------------------------
-- Lifecycle wiring
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
        conn, err = xnet.attach_tls(fd, server_handler, ip, port, tls_config)
    else
        conn, err = xnet.attach(fd, server_handler, ip, port)
    end
    if not conn then
        io.stderr:write('[XADMIN-WORKER] attach failed: ' .. tostring(err) .. '\n')
    end
end)

xthread.register('xhttp_worker_stop', function()
    for conn in pairs(connections) do conn:close('xhttp_worker_stop') end
end)

local function __init()
    print('[XADMIN-WORKER] init')
    assert(xnet.init())
end

local function __update()
    xnet.poll(10)
end

local function __uninit()
    for conn in pairs(connections) do conn:close('worker_uninit') end
    -- Keep state.connections table identity but clear contents so that a
    -- subsequent reload finds a clean slate.
    for k in pairs(connections) do connections[k] = nil end
    xnet.uninit()
    print('[XADMIN-WORKER] uninit')
end

return {
    __init = __init,
    __update = __update,
    __uninit = __uninit,
    __thread_handle = router.handle,
}
