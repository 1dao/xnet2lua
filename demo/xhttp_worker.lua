-- xhttp_worker.lua - worker-side HTTP connection dispatcher.
-- HTTP parsing and response serialization live in shared Lua modules.

local codec = dofile('demo/xhttp_codec.lua')

local app = nil
local app_script = nil
local max_request_size = 16 * 1024 * 1024
local server_name = 'xnet-http'
local use_https = false
local tls_config = nil
local connections = {}

_stubs = {}
_thread_replys = {}

function xthread.register(pt, h)
    _stubs[pt] = h
end

local function __thread_handle(reply_router, k1, k2, k3, ...)
    if reply_router then
        io.stderr:write('[XHTTP-WORKER] unexpected RPC message: ' .. tostring(k3) .. '\n')
        return
    end

    local h = _stubs[k1]
    if h then
        h(k2, k3, ...)
    elseif k1 then
        io.stderr:write('[XHTTP-WORKER] no handler for pt=' .. tostring(k1) .. '\n')
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
        error('app script must return a table or function')
    end
end

local function dispatch_request(req)
    if app and type(app.handle) == 'function' then
        return app.handle(req)
    end

    local router = app and app.router
    if type(router) == 'table' and type(router.handle) == 'function' then
        return router.handle(req)
    end

    local routes = app and (app.routes or (router and router.routes))
    if type(routes) == 'table' then
        local key = req.method .. ' ' .. req.path
        local method_routes = routes[req.method]
        local h = routes[key] or routes[req.path] or
            (type(method_routes) == 'table' and method_routes[req.path])
        if type(h) == 'function' then
            return h(req)
        end
        if type(h) == 'table' then
            return h
        end
    end

    return { status = 404, body = 'not found\n' }
end

local server_handler = {}

function server_handler.on_connect(conn, ip, port)
    connections[conn] = { ip = ip, port = port }
    conn:set_framing({ type = 'raw', max_packet = max_request_size })
    print(string.format('[XHTTP-WORKER] accepted fd=%s from %s:%s',
        tostring(conn:fd()), tostring(ip), tostring(port)))
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
            if err == 'incomplete' then
                break
            end
            codec.send_error(conn, err == 'request body too large' and 413 or 400, err, send_opts)
            return data_len
        end

        local ok, resp = pcall(dispatch_request, req)
        if ok then
            codec.send_response(conn, req, resp, send_opts)
        else
            io.stderr:write('[XHTTP-WORKER] app error: ' .. tostring(resp) .. '\n')
            codec.send_error(conn, 500, 'internal server error', send_opts)
        end

        consumed = next_pos - 1
        pos = next_pos
    end

    return consumed
end

function server_handler.on_close(conn, reason)
    connections[conn] = nil
    print('[XHTTP-WORKER] close:', reason)
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
    print(string.format('[XHTTP-WORKER] start scheme=%s app=%s max_request=%d',
        use_https and 'https' or 'http', tostring(script_path), max_request_size))
end)

xthread.register('xhttp_accept', function(fd, ip, port)
    local conn, err
    if use_https then
        conn, err = xnet.attach_tls(fd, server_handler, ip, port, tls_config)
    else
        conn, err = xnet.attach(fd, server_handler, ip, port)
    end
    if not conn then
        io.stderr:write('[XHTTP-WORKER] attach failed: ' .. tostring(err) .. '\n')
    end
end)

xthread.register('xhttp_worker_stop', function()
    for conn in pairs(connections) do
        conn:close('xhttp_worker_stop')
    end
end)

local function __init()
    print('[XHTTP-WORKER] init')
    assert(xnet.init())
end

local function __update()
    xnet.poll(10)
end

local function __uninit()
    for conn in pairs(connections) do
        conn:close('worker_uninit')
    end
    connections = {}
    xnet.uninit()
    print('[XHTTP-WORKER] uninit')
end

return {
    __init = __init,
    __update = __update,
    __uninit = __uninit,
    __thread_handle = __thread_handle,
}
