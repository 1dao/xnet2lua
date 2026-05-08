-- xadmin_worker.lua - HTTP worker for the xadmin console.
--
-- This is an extended version of demo/xhttp_worker.lua: when an app handler
-- returns a table tagged `{ async = true, ... }` the worker stashes the
-- (conn, req) pair in a `pending` table, posts a request to xthread.MAIN,
-- and returns from on_packet without sending a response. When MAIN posts
-- the matching reply back (`xadmin_peers_reply` / `xadmin_exec_reply`), the
-- worker looks up the pending entry and writes the HTTP response then.

local codec = dofile('scripts/core/share/xhttp_codec.lua')

local app = nil
local app_script = nil
local max_request_size = 4 * 1024 * 1024
local server_name = 'xnet-xadmin'
local use_https = false
local tls_config = nil

local connections = {}
local pending = {}
local next_id = 0
local MAIN_ID = xthread.MAIN
local unpack_args = table.unpack or unpack

_stubs = {}
_thread_replys = {}

local function alloc_id()
    next_id = next_id + 1
    return next_id
end

function xthread.register(pt, h)
    _stubs[pt] = h
end

local function __thread_handle(reply_router, k1, k2, k3, ...)
    if reply_router then
        io.stderr:write('[XADMIN-WORKER] unexpected RPC message: ' .. tostring(k3) .. '\n')
        return
    end
    local h = _stubs[k1]
    if h then
        h(k2, k3, ...)
    elseif k1 then
        io.stderr:write('[XADMIN-WORKER] no handler for pt=' .. tostring(k1) .. '\n')
    end
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

-- Sync dispatch. Returns the response table, or returns nil after stashing
-- pending state and posting an async request to main.
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

    -- Async: keep conn alive, post to main, send response later.
    local id = alloc_id()
    pending[id] = { conn = conn, req = req, send_opts = send_opts }
    local args = resp.args or {}
    local n = #args
    local ok2, perr
    if n == 0 then
        ok2, perr = xthread.post(MAIN_ID, resp.action, xthread.current_id(), id)
    else
        ok2, perr = xthread.post(MAIN_ID, resp.action, xthread.current_id(), id, unpack_args(args, 1, n))
    end
    if not ok2 then
        pending[id] = nil
        return { status = 500, body = 'main post failed: ' .. tostring(perr) .. '\n' }
    end
    return nil
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

xthread.register('xadmin_peers_reply', function(id, json_body)
    send_pending(id, 200, json_body or '{}', 'application/json; charset=utf-8')
end)

xthread.register('xadmin_exec_reply', function(id, ok, target, stdout, result)
    local payload, err = require('xutils').json_pack({
        ok = ok and true or false,
        target = target or '',
        stdout = stdout or '',
        result = result or '',
    })
    if not payload then
        payload = '{"ok":false,"target":"' .. tostring(target or '') ..
                  '","stdout":"","result":"json pack failed: ' .. tostring(err) .. '"}'
    end
    send_pending(id, ok and 200 or 500, payload, 'application/json; charset=utf-8')
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
    -- Drop any pending entries that referenced this conn so replies don't
    -- crash on a closed fd.
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
    __thread_handle = __thread_handle,
}
