-- xhttp_client_main.lua - end-to-end self-test for the async HTTP client.
--
-- Run with:  bin/xnet demo/xhttp_client_main.lua
--
-- Spins up a minimal loopback HTTP/1.1 server (the same xnet.listen + xhttp_codec
-- glue as demo/xhttpd_main.lua) and drives it through scripts/core/share/
-- xhttp_client.lua, exercising Content-Length, body echo, redirect following,
-- chunked transfer-encoding and gzip Content-Encoding. Exits 0 on success, 1 on
-- the first mismatch. HTTP only -- no network, fully deterministic.

local codec  = dofile('scripts/core/share/xhttp_codec.lua')
local httpc  = dofile('scripts/core/share/xhttp_client.lua')
local xcompress = require('xcompress')

local HOST = '127.0.0.1'
local PORT = 18097
local BASE = string.format('http://%s:%d', HOST, PORT)
local MAX_REQUEST = 1 * 1024 * 1024

-- ---------------------------------------------------------------------------
-- Minimal in-thread HTTP server. Handlers return either a value send_response
-- understands, or { raw = <bytes> } to emit an exact wire response (used for
-- the chunked / gzip cases the high-level serializer won't produce verbatim).
-- ---------------------------------------------------------------------------
local function make_server(routes)
    local resp_opts  = { server_name = 'xnet-httpc-demo' }
    local parse_opts = { max_request_size = MAX_REQUEST }
    local bufs = setmetatable({}, { __mode = 'k' })
    local h = {}

    function h.on_connect(conn)
        conn:set_framing({ type = 'raw', max_packet = MAX_REQUEST })
        bufs[conn] = ''
    end

    function h.on_packet(conn, data)
        local buf = (bufs[conn] or '') .. data
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

            local by_path = routes[string.upper(req.method)]
            local handler = by_path and by_path[req.path]
            local resp = handler and handler(req) or nil

            if type(resp) == 'table' and resp.raw then
                conn:send_raw(resp.raw)
                bufs[conn] = nil
                conn:close('done')
                return #data
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

    function h.on_close(conn)
        bufs[conn] = nil
    end

    return h
end

local ROUTES = { GET = {}, POST = {} }
ROUTES.GET['/hello'] = function(req)
    return 'hello ' .. tostring(req.query.name or 'world')
end
ROUTES.POST['/echo'] = function(req)
    return { status = 200, body = req.body }
end
ROUTES.GET['/redirect'] = function()
    return { status = 302, headers = { Location = '/hello?name=redir' }, body = '' }
end
ROUTES.GET['/chunked'] = function()
    return { raw = 'HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n'
        .. 'Connection: close\r\n\r\n'
        .. '5\r\nhello\r\n6\r\n world\r\n0\r\n\r\n' }
end
ROUTES.GET['/gzip'] = function()
    local plain = string.rep('compress-me; ', 32)
    local gz = assert(xcompress.gzip(plain))
    return { raw = 'HTTP/1.1 200 OK\r\nContent-Encoding: gzip\r\n'
        .. 'Content-Length: ' .. tostring(#gz) .. '\r\nConnection: close\r\n\r\n'
        .. gz, _plain = plain }
end

-- ---------------------------------------------------------------------------
-- Test driver
-- ---------------------------------------------------------------------------
local server
local finished = false

local function finish(ok, msg)
    if finished then return end
    finished = true
    print('[XHTTPC-MAIN] finish:', ok, msg)
    if server then server:close('done'); server = nil end
    xthread.stop(ok and 0 or 1)
end

local GZIP_PLAIN = string.rep('compress-me; ', 32)

local tests = {}
local function add(name, fn) tests[#tests + 1] = { name = name, fn = fn } end

add('GET content-length', function(next)
    httpc.get(BASE .. '/hello?name=xnet', function(err, resp)
        if err then return finish(false, 'hello: ' .. err) end
        if resp.status ~= 200 then return finish(false, 'hello status ' .. resp.status) end
        if resp.body ~= 'hello xnet' then return finish(false, 'hello body=' .. resp.body) end
        next()
    end)
end)

add('POST echo', function(next)
    httpc.post(BASE .. '/echo', 'round-trip-body', function(err, resp)
        if err then return finish(false, 'echo: ' .. err) end
        if resp.body ~= 'round-trip-body' then return finish(false, 'echo body=' .. resp.body) end
        next()
    end)
end)

add('redirect following', function(next)
    httpc.get(BASE .. '/redirect', function(err, resp)
        if err then return finish(false, 'redirect: ' .. err) end
        if resp.status ~= 200 then return finish(false, 'redirect status ' .. resp.status) end
        if resp.body ~= 'hello redir' then return finish(false, 'redirect body=' .. resp.body) end
        next()
    end)
end)

add('chunked response', function(next)
    httpc.get(BASE .. '/chunked', function(err, resp)
        if err then return finish(false, 'chunked: ' .. err) end
        if resp.body ~= 'hello world' then return finish(false, 'chunked body=' .. resp.body) end
        next()
    end)
end)

add('gzip decompress', function(next)
    httpc.get(BASE .. '/gzip', function(err, resp)
        if err then return finish(false, 'gzip: ' .. err) end
        if resp.body ~= GZIP_PLAIN then return finish(false, 'gzip body mismatch') end
        if resp.content_encoding ~= 'gzip' then return finish(false, 'gzip not decoded') end
        next()
    end)
end)

add('no-redirect budget', function(next)
    httpc.request({ url = BASE .. '/redirect', max_redirects = 0 }, function(err, resp)
        if err then return finish(false, 'no-redirect: ' .. err) end
        if resp.status ~= 302 then return finish(false, 'expected 302 got ' .. resp.status) end
        next()
    end)
end)

local idx = 0
local function run_next()
    idx = idx + 1
    local t = tests[idx]
    if not t then return finish(true, 'all http client tests ok') end
    print(string.format('[XHTTPC-MAIN] test %d: %s', idx, t.name))
    t.fn(run_next)
end

local function __init()
    print('[XHTTPC-MAIN] init ' .. BASE)
    assert(xnet.init())
    local s, err = xnet.listen(HOST, PORT, make_server(ROUTES))
    if not s then error(err) end
    server = s
    run_next()
end

local function __uninit()
    if server then server:close('uninit'); server = nil end
    xnet.uninit()
    print('[XHTTPC-MAIN] uninit')
end

return {
    __init = __init,
    __uninit = __uninit,
}
