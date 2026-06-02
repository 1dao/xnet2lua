-- xhttpd_main.lua - a minimal, fully main-thread HTTP/1.1 server in pure Lua,
-- plus a self-test for it.
--
-- Run with:  bin\xnet.exe demo/xhttpd_main.lua
--
-- The server (make_server below) accepts and serves every connection in-thread
-- via xnet.listen -- parsing, your handler, and the response all run on the
-- main thread's event loop. No worker threads, no HTTP build flag, no C
-- changes: it is just glue over the shared xhttp_codec parser/serializer, small
-- enough to live right here. Keep-alive and HTTP pipelining are honoured.
--
-- The bottom half drives a loopback client that fires a handful of requests and
-- checks the responses. Exits 0 on success, 1 on the first mismatch.

local codec = dofile('scripts/core/share/xhttp_codec.lua')

local HOST = '127.0.0.1'
local PORT = 18091

-- ===========================================================================
-- The HTTP server: xnet.listen handler that parses requests with xhttp_codec
-- and calls handler(req) -> response. handler may return a string/number, or a
-- table { status=, body=, headers=, file=, content_type= }; nil yields 404, a
-- raised error yields 500, malformed bytes yield 400 + close.
-- ===========================================================================
local MAX_REQUEST = 1 * 1024 * 1024

local function make_server(handler, server_name)
    local resp_opts  = { server_name = server_name or 'xnet-httpd' }
    local parse_opts = { max_request_size = MAX_REQUEST }
    local bufs = setmetatable({}, { __mode = 'k' })  -- per-conn receive buffer

    local h = {}

    function h.on_connect(conn)
        conn:set_framing({ type = 'raw', max_packet = MAX_REQUEST })
        bufs[conn] = ''
    end

    function h.on_packet(conn, data)
        local buf = (bufs[conn] or '') .. data

        -- Drain as many whole requests as the buffer holds (HTTP pipelining).
        while #buf > 0 do
            local req, next_pos, err = codec.parse_request(buf, 1, parse_opts)
            if not req then
                if err == 'incomplete' then break end
                codec.send_error(conn, 400, err, resp_opts)
                bufs[conn] = nil
                conn:close('bad request')
                return #data
            end

            buf = buf:sub(next_pos)

            local ok, resp = pcall(handler, req)
            if not ok then
                xthread.log_error('[XHTTPD] handler error: %s', tostring(resp))
                resp = {
                    status = 500,
                    body = 'internal server error\n',
                    headers = { ['Content-Type'] = 'text/plain; charset=utf-8' },
                }
            end
            codec.send_response(conn, req, resp, resp_opts)

            if not req.keep_alive then
                bufs[conn] = nil
                conn:close('done')
                return #data
            end
        end

        bufs[conn] = buf
        return #data
    end

    function h.on_close(conn, _)
        bufs[conn] = nil
    end

    return h
end

-- ===========================================================================
-- Routing: a global table you register handlers into, instead of a hardcoded
-- switch. ROUTES[METHOD][path] = function(req) -> response. The dispatcher
-- (app) is what gets handed to make_server; an unregistered path yields 404.
-- ===========================================================================
ROUTES = ROUTES or {}

local function route(method, path, handler)
    method = string.upper(method)
    ROUTES[method] = ROUTES[method] or {}
    ROUTES[method][path] = handler
end

local function app(req)
    local by_path = ROUTES[string.upper(req.method)]
    local handler = by_path and by_path[req.path]
    if handler then return handler(req) end
    return nil  -- -> 404 not found
end

route('GET',  '/hello', function(req)
    return 'hello ' .. tostring(req.query.name or 'world') .. '\n'
end)
route('POST', '/echo', function(req)
    return { status = 200, body = req.body }
end)
route('HEAD', '/head', function()
    return { status = 200, body = 'should-not-see-this-body' }
end)
route('GET',  '/api/throw', function()
    error('boom')
end)

-- ===========================================================================
-- Client-side test driver
-- ===========================================================================
local function request(method, path, headers, body)
    headers = headers or {}
    body = body or ''
    local lines = { method .. ' ' .. path .. ' HTTP/1.1' }
    if not headers.Host and not headers.host then
        lines[#lines + 1] = 'Host: localhost'
    end
    if body ~= '' and not headers['Content-Length'] and not headers['content-length'] then
        headers['Content-Length'] = tostring(#body)
    end
    for k, v in pairs(headers) do
        lines[#lines + 1] = k .. ': ' .. tostring(v)
    end
    lines[#lines + 1] = 'Connection: keep-alive'
    return table.concat(lines, '\r\n') .. '\r\n\r\n' .. body
end

local tests = {
    {
        name = 'hello',
        request = request('GET', '/hello?name=xnet'),
        responses = { { method = 'GET', status = 200, body = 'hello xnet\n' } },
    },
    {
        name = 'echo',
        request = request('POST', '/echo', nil, 'echo-body'),
        responses = { { method = 'POST', status = 200, body = 'echo-body' } },
    },
    {
        name = 'missing',
        request = request('GET', '/missing'),
        responses = { { method = 'GET', status = 404, body = 'not found\n' } },
    },
    {
        name = 'head (no body)',
        request = request('HEAD', '/head'),
        responses = { { method = 'HEAD', status = 200, body = '' } },
    },
    {
        name = 'handler error -> 500',
        request = request('GET', '/api/throw'),
        responses = { { method = 'GET', status = 500, body = 'internal server error\n' } },
    },
    {
        name = 'keep-alive pipelining',
        request = request('GET', '/hello?name=A') .. request('GET', '/hello?name=B'),
        responses = {
            { method = 'GET', status = 200, body = 'hello A\n' },
            { method = 'GET', status = 200, body = 'hello B\n' },
        },
    },
}

local server
local client_conn
local finished = false
local pending_buf = ''
local expectations = {}
local cur_test_idx = 0

local function finish(ok, msg)
    if finished then return end
    finished = true
    print('[XHTTPD-MAIN] finish:', ok, msg)
    if client_conn then client_conn:close('done'); client_conn = nil end
    if server then server:close('done'); server = nil end
    xthread.stop(ok and 0 or 1)
end

local function start_next_test()
    cur_test_idx = cur_test_idx + 1
    local t = tests[cur_test_idx]
    if not t then
        finish(true, 'all xhttpd tests ok')
        return
    end
    print(string.format('[XHTTPD-MAIN] test %d: %s', cur_test_idx, t.name))
    expectations = {}
    for i, e in ipairs(t.responses) do
        expectations[i] = { name = t.name, method = e.method, status = e.status, body = e.body }
    end
    assert(client_conn:send_raw(t.request))
end

local client_handler = {}

function client_handler.on_connect(conn)
    client_conn = conn
    conn:set_framing({ type = 'raw', max_packet = 1024 * 1024 })
    start_next_test()
end

function client_handler.on_packet(_, data)
    pending_buf = pending_buf .. data
    while #expectations > 0 do
        local expect = expectations[1]
        local resp, next_pos, err = codec.parse_response(pending_buf, 1, { method = expect.method })
        if not resp then
            if err == 'incomplete' then break end
            finish(false, 'client parse failed: ' .. tostring(err))
            return #data
        end
        if resp.status ~= expect.status then
            finish(false, string.format('%s status expected %d got %d',
                expect.name, expect.status, resp.status))
            return #data
        end
        if resp.body ~= expect.body then
            finish(false, string.format('%s body mismatch expected=%q got=%q',
                expect.name, expect.body, resp.body))
            return #data
        end
        print(string.format('[XHTTPD-MAIN] response ok: %s status=%d len=%d',
            expect.name, resp.status, #resp.body))
        pending_buf = pending_buf:sub(next_pos)
        table.remove(expectations, 1)
    end
    if #expectations == 0 and not finished then
        start_next_test()
    end
    return #data
end

function client_handler.on_close(_, reason)
    if not finished and #expectations > 0 then
        finish(false, 'connection closed with responses pending: ' .. tostring(reason))
    end
end

-- ===========================================================================
-- Lifecycle
-- ===========================================================================
local function __init()
    print(string.format('[XHTTPD-MAIN] init http=%s:%d', HOST, PORT))
    assert(xnet.init())

    local s, err = xnet.listen(HOST, PORT, make_server(app, 'xnet-httpd-demo'))
    if not s then error(err) end
    server = s

    local conn, cerr = xnet.connect(HOST, PORT, client_handler)
    if not conn then error(cerr) end
end

local function __uninit()
    if client_conn then client_conn:close('uninit'); client_conn = nil end
    if server then server:close('uninit'); server = nil end
    xnet.uninit()
    print('[XHTTPD-MAIN] uninit')
end

return {
    __init = __init,
    __uninit = __uninit,
}
