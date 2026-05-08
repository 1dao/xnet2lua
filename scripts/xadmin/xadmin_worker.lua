-- xadmin_worker.lua - HTTP worker for the xadmin console.
--
-- Async HTTP actions are completed locally inside this worker:
--   * xadmin_query_peers  -> local peer cache (fed by NATS broadcast)
--   * xadmin_query_stats  -> local xthread.all_stats aggregation
--   * xadmin_run_script   -> direct xnats.rpc(target, '@run_script', script)

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

local connections = {}
local pending = {}
local next_id = 0

local SELF_NAME = XNET_PROCESS_NAME or xutils.get_config('SERVER_NAME', 'xadmin1')
local TOKEN_REQUIRED = xutils.get_config('XADMIN_TOKEN', '') ~= ''
local PEER_TTL_MS = tonumber(xutils.get_config('XADMIN_PEER_TTL_MS', '15000')) or 15000

local function pack_values(...)
    return { n = select('#', ...), ... }
end

local function alloc_id()
    next_id = next_id + 1
    return next_id
end

function xthread.register(pt, h) return router.register(pt, h) end

local function now_ms()
    if xtimer and xtimer.now_ms then
        return xtimer.now_ms()
    end
    return math.floor(os.time() * 1000)
end

local peers = {}

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
end

local function send_pending(id, status, body, content_type)
    local p = pending[id]
    if not p then return end
    pending[id] = nil
    if not p.conn or p.conn:fd() < 0 then return end
    codec.send_response(p.conn, p.req, {
        status = status or 200,
        body = body or '',
        headers = {
            ['Content-Type'] = content_type or 'application/json; charset=utf-8',
            ['Cache-Control'] = 'no-store',
        },
    }, p.send_opts)
end

local function send_json_pending(id, status, payload)
    local body, err = xutils.json_pack(payload)
    if not body then
        send_pending(id, 500, 'json pack failed: ' .. tostring(err), 'text/plain; charset=utf-8')
        return
    end
    send_pending(id, status or 200, body, 'application/json; charset=utf-8')
end

local function send_exec_reply(id, ok, target, stdout, result)
    send_json_pending(id, ok and 200 or 500, {
        ok = ok and true or false,
        target = target or '',
        stdout = stdout or '',
        result = result or '',
    })
end

local function action_query_peers(id)
    send_json_pending(id, 200, {
        self = SELF_NAME,
        peers = alive_peers(),
        token_required = TOKEN_REQUIRED,
    })
end

local function action_query_stats(id)
    local threads = xthread.all_stats()
    local summary = {
        thread_count = 0,
        queue_depth_total = 0,
        queue_max_total = 0,
        peak_queue_depth = 0,
        peak_queue_thread_id = 0,
        peak_queue_thread_name = '',
    }
    if type(threads) ~= 'table' then threads = {} end
    summary.thread_count = #threads
    for _, st in ipairs(threads) do
        local qd = tonumber(st.queue_depth) or 0
        local qm = tonumber(st.queue_max) or 0
        summary.queue_depth_total = summary.queue_depth_total + qd
        summary.queue_max_total = summary.queue_max_total + qm
        if qd > summary.peak_queue_depth then
            summary.peak_queue_depth = qd
            summary.peak_queue_thread_id = tonumber(st.id) or 0
            summary.peak_queue_thread_name = tostring(st.name or '')
        end
    end

    send_json_pending(id, 200, {
        self = SELF_NAME,
        at_ms = now_ms(),
        peers = alive_peers(),
        threads = threads,
        summary = summary,
        token_required = TOKEN_REQUIRED,
    })
end

local function action_run_script(id, target, script)
    target = tostring(target or '')
    script = tostring(script or '')
    if target == '' or target == 'self' then
        target = SELF_NAME
    end

    local co = coroutine.create(function()
        local rets = pack_values(xnats.rpc(target, '@run_script', script))
        local rpc_ok = rets[1]
        if not rpc_ok then
            send_exec_reply(id, false, target, '', 'rpc failed: ' .. tostring(rets[2]))
            return
        end

        local i = 2
        local last_bool = nil
        while i <= rets.n and type(rets[i]) == 'boolean' do
            last_bool = rets[i]
            i = i + 1
        end
        local exec_ok = (last_bool ~= nil) and (last_bool and true or false) or true
        local exec_stdout = rets[i]
        local exec_result = rets[i + 1]
        send_exec_reply(id, exec_ok, target, exec_stdout or '', exec_result or '')
    end)

    local ok, err = coroutine.resume(co)
    if not ok then
        send_exec_reply(id, false, target, '', 'worker exec coroutine failed: ' .. tostring(err))
    end
end

local function dispatch_request(req, conn, send_opts)
    if not app or type(app.handle) ~= 'function' then
        return { status = 500, body = 'xadmin app not loaded\n' }
    end

    local ok, resp = pcall(app.handle, req)
    if not ok then
        io.stderr:write('[XADMIN-WORKER] app error: ' .. tostring(resp) .. '\n')
        return { status = 500, body = 'internal server error\n' }
    end
    if type(resp) ~= 'table' or not resp.async then
        return resp
    end

    local id = alloc_id()
    pending[id] = { conn = conn, req = req, send_opts = send_opts }
    local args = resp.args or {}

    if resp.action == 'xadmin_query_peers' then
        action_query_peers(id)
        return nil
    end
    if resp.action == 'xadmin_query_stats' then
        action_query_stats(id)
        return nil
    end
    if resp.action == 'xadmin_run_script' then
        action_run_script(id, args[1], args[2])
        return nil
    end

    pending[id] = nil
    return { status = 400, body = 'unknown async action: ' .. tostring(resp.action) .. '\n' }
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

local server_handler = {}

function server_handler.on_connect(conn, ip, port)
    connections[conn] = { ip = ip, port = port }
    conn:set_framing({ type = 'raw', max_packet = max_request_size })
end

function server_handler.on_packet(conn, data)
    local state = connections[conn]
    local pos = 1
    local consumed = 0
    local data_len = #data
    local send_opts = { server_name = server_name }

    while pos <= data_len do
        local req, next_pos, err = codec.parse_request(data, pos, {
            max_request_size = max_request_size,
            state = state,
        })
        if not req then
            if err == 'incomplete' then break end
            codec.send_error(conn, err == 'request body too large' and 413 or 400, err, send_opts)
            return data_len
        end

        local resp = dispatch_request(req, conn, send_opts)
        if resp then
            codec.send_response(conn, req, resp, send_opts)
        end
        consumed = next_pos - 1
        pos = next_pos
    end

    return consumed
end

function server_handler.on_close(conn, reason)
    connections[conn] = nil
    local _ = reason
    for id, p in pairs(pending) do
        if p.conn == conn then pending[id] = nil end
    end
end

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
    connections = {}
    xnet.uninit()
    print('[XADMIN-WORKER] uninit')
end

return {
    __init = __init,
    __update = __update,
    __uninit = __uninit,
    __thread_handle = router.handle,
}
