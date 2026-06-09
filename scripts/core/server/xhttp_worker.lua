-- xhttp_worker.lua - worker-side HTTP connection dispatcher through xsession.
-- HTTP parsing and response serialization live in shared Lua modules.

local xsession = dofile('scripts/core/share/xsession.lua')
local codec    = dofile('scripts/core/share/xhttp_codec.lua')
local xws      = dofile('scripts/core/share/xwebsocket.lua')
local router   = dofile('scripts/core/share/xrouter.lua')
router.set_log_prefix('XHTTP-WORKER')
router.set_unknown_rpc(function(reply_router, co_id, sk, pt, ...)
    local _ = reply_router
    _ = co_id
    _ = sk
    _ = ...
    io.stderr:write('[XHTTP-WORKER] unexpected RPC message: ' .. tostring(pt) .. '\n')
end)

local app = nil
local app_script = nil
local max_request_size = 16 * 1024 * 1024
local server_name = 'xnet-http'
local use_https = false
local tls_config = nil
local connections = {}

-- HTTP -> HTTPS upgrade knobs (set from xhttp_worker_start).
local force_https = false      -- redirect plaintext requests to https
local redirect_port = 443      -- target port for the redirect
local redirect_status = 301    -- 301/302/307/308
local hsts_opts = nil          -- Strict-Transport-Security spec (or nil)

-- Compression knobs. Response compression is on by default with a 256-byte
-- floor (smaller bodies aren't worth the headers). Request decompression is
-- also on so handlers see plain bytes regardless of Content-Encoding.
local compression_opts = {
    enabled  = true,
    min_size = 256,
    level    = 6,
}
local decompress_requests = true
local max_decompressed_size = nil   -- nil -> codec uses max_request_size

function xthread.register(pt, h) return router.register(pt, h) end

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

local app_router = {
    handle = function(req)
        -- HTTP -> HTTPS upgrade: on a plaintext worker with force_https on,
        -- bounce every request to the https:// URL before touching the app.
        if force_https and not use_https then
            return codec.https_redirect(req, {
                https_port = redirect_port,
                status     = redirect_status,
                hsts       = hsts_opts,
            })
        end

        local ok, resp = pcall(dispatch_request, req)
        if not ok then
            io.stderr:write('[XHTTP-WORKER] app error: ' .. tostring(resp) .. '\n')
            return {
                status = 500,
                body = 'internal server error\n',
                headers = { ['Content-Type'] = 'text/plain; charset=utf-8' },
            }
        end
        if type(resp) ~= 'table' then
            return {
                status = 500,
                body = 'invalid app response\n',
                headers = { ['Content-Type'] = 'text/plain; charset=utf-8' },
            }
        end
        return resp
    end,
}

local server_handler = xsession.make({
    parse_packet = function(data, pos, _, cstate)
        return codec.parse_request(data, pos, {
            max_request_size      = max_request_size,
            state                 = cstate,
            decompress            = decompress_requests,
            max_decompressed_size = max_decompressed_size,
        })
    end,

    classify = function(_) return 'rpc' end,

    send_response = function(conn, req, resp)
        -- WebSocket upgrade: an app route returns
        --   { websocket = { on_open=, on_message=, on_close=, ... },
        --     protocol = '...', max_message_size = N }
        -- and we hand the fd over to the WebSocket frame dispatcher.
        if type(resp) == 'table' and type(resp.websocket) == 'table' then
            local cstate = connections[conn]
            local ws, werr = xws.upgrade(conn, req, resp.websocket, {
                protocol         = resp.protocol,
                protocols        = resp.protocols,
                server_name      = server_name,
                max_message_size = resp.max_message_size or max_request_size,
                handshake_headers = resp.handshake_headers,
                on_detach        = function(c) connections[c] = nil end,
            })
            if ws then
                -- The fd now speaks WebSocket, not HTTP. Wind down the xsession
                -- session for it so on_packet stops parsing bytes as requests;
                -- on_detach clears the connections entry on socket close.
                if cstate then cstate.closing = true end
            else
                io.stderr:write('[XHTTP-WORKER] websocket upgrade failed: '
                    .. tostring(werr) .. '\n')
                codec.send_error(conn, 400, werr or 'bad websocket upgrade',
                    { server_name = server_name })
                conn:close('ws_upgrade_failed')
            end
            return
        end

        codec.send_response(conn, req, resp, {
            server_name = server_name,
            compression = compression_opts,
            hsts        = use_https and hsts_opts or nil,
        })
    end,

    on_parse_error = function(conn, err)
        local status = (err == 'request too large' or err == 'request body too large')
            and 413 or 400
        codec.send_error(conn, status, err, { server_name = server_name })
        -- HTTP/1.1 has no in-stream resync; once we've rejected the request
        -- line/headers, anything further on this conn is unparseable bytes.
        -- xsession's soft parse-error policy keeps the fd alive by default,
        -- so we explicitly close here to match standard HTTP server behavior.
        conn:close('parse_error')
    end,

    http_router = app_router,

    on_connect = function(conn, ip, port)
        conn:set_framing({ type = 'raw', max_packet = max_request_size })
        print(string.format('[XHTTP-WORKER] accepted fd=%s from %s:%s',
            tostring(conn:fd()), tostring(ip), tostring(port)))
    end,

    on_close = function(_, reason)
        print('[XHTTP-WORKER] close:', reason)
    end,

    log_prefix    = 'XHTTP-WORKER',
    max_queue_len = 256,
    connections   = connections,
})

xthread.register('xhttp_worker_start', function(script_path, max_size, name,
                                               https, cert_file, key_file, key_password,
                                               compr_enabled, compr_min_size, compr_level,
                                               req_decompress, max_decompressed,
                                               ca_file, extra)
    max_request_size = tonumber(max_size) or max_request_size
    server_name = name or server_name
    use_https = https and true or false
    if use_https then
        tls_config = {
            cert_file = cert_file,
            key_file = key_file,
            password = key_password ~= '' and key_password or nil,
            ca_file = (type(ca_file) == 'string' and ca_file ~= '') and ca_file or nil,
            max_packet = max_request_size,
        }
    else
        tls_config = nil
    end

    if compr_enabled ~= nil then compression_opts.enabled = compr_enabled and true or false end
    if compr_min_size then compression_opts.min_size = tonumber(compr_min_size) or compression_opts.min_size end
    if compr_level then compression_opts.level = tonumber(compr_level) or compression_opts.level end
    if req_decompress ~= nil then decompress_requests = req_decompress and true or false end
    if max_decompressed then max_decompressed_size = tonumber(max_decompressed) end

    extra = type(extra) == 'table' and extra or {}
    force_https = extra.force_https and true or false
    redirect_port = tonumber(extra.redirect_port) or 443
    redirect_status = tonumber(extra.redirect_status) or 301
    hsts_opts = extra.hsts

    load_app(script_path)
    print(string.format('[XHTTP-WORKER] start scheme=%s app=%s max_request=%d compress=%s/%d/L%d force_https=%s hsts=%s',
        use_https and 'https' or 'http', tostring(script_path), max_request_size,
        compression_opts.enabled and 'on' or 'off',
        compression_opts.min_size, compression_opts.level,
        tostring(force_https), hsts_opts ~= nil and 'on' or 'off'))
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
    server_handler.close_all('xhttp_worker_stop')
end)

local function __init()
    print('[XHTTP-WORKER] init')
    assert(xnet.init())
end

-- xnet.init() marks this thread as network-active; the C layer drives
-- xpoll_poll(), so enable __update only when periodic Lua work is added.
-- local function __update()
-- end

local function __uninit()
    server_handler.close_all('worker_uninit')
    xnet.uninit()
    print('[XHTTP-WORKER] uninit')
end

return {
    __init = __init,
    -- __update = __update,
    __uninit = __uninit,
    __thread_handle = router.handle,
}
