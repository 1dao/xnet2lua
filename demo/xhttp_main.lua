-- xhttp_main.lua - HTTP server demo.
-- Main thread owns the listener and passes accepted sockets to HTTP workers.

local xhttp = dofile('demo/xhttp.lua')
local codec = dofile('demo/xhttp_codec.lua')
local xjson = require('xutils').json

local CONFIG_FILE = 'demo/xnet.cfg'
local ok_cfg, cfg_err = xnet.load_config(CONFIG_FILE)
if not ok_cfg then
    io.stderr:write('[XHTTP-MAIN] config not loaded: ' .. tostring(cfg_err) .. '\n')
end

local HOST = xnet.get_config('HTTP_HOST', '127.0.0.1')
local PORT = tonumber(xnet.get_config('HTTP_PORT', '18080')) or 18080
local WORKERS = tonumber(xnet.get_config('HTTP_WORKERS', '2')) or 2
local ENABLE = xnet.get_config('HTTP_ENABLE', '1') ~= '0'

local client_conn = nil
local finished = false

_stubs = {}
_thread_replys = {}

function xthread.register(pt, h)
    _stubs[pt] = h
end

local function __thread_handle(reply_router, k1, k2, k3, ...)
    if reply_router then
        io.stderr:write('[XHTTP-MAIN] unexpected RPC message: ' .. tostring(k3) .. '\n')
        return
    end

    local h = _stubs[k1]
    if h then
        h(k2, k3, ...)
    elseif k1 then
        io.stderr:write('[XHTTP-MAIN] no handler for pt=' .. tostring(k1) .. '\n')
    end
end

local form_body = 'name=alice+cat&kind=urlencoded'
local json_body = assert(xjson.pack({
    pt = 'demo',
    arg1 = 42,
    ok = true,
}))
local multipart_boundary = '----xnetdemo'
local multipart_body = table.concat({
    '--' .. multipart_boundary,
    'Content-Disposition: form-data; name="name"',
    '',
    'alice',
    '--' .. multipart_boundary,
    'Content-Disposition: form-data; name="upload"; filename="hello.txt"',
    'Content-Type: text/plain',
    '',
    'file-body',
    '--' .. multipart_boundary .. '--',
    '',
}, '\r\n')

local tests = {
    {
        name = 'hello',
        method = 'GET',
        request = 'GET /hello?name=xnet HTTP/1.1\r\nHost: localhost\r\nConnection: keep-alive\r\n\r\n',
        status = 200,
        body = 'hello xnet\n',
    },
    {
        name = 'echo',
        method = 'POST',
        request = 'POST /echo HTTP/1.1\r\nHost: localhost\r\nContent-Length: 9\r\nConnection: keep-alive\r\n\r\necho-body',
        status = 200,
        body = 'echo-body',
    },
    {
        name = 'chunked',
        method = 'POST',
        request = 'POST /chunked HTTP/1.1\r\nHost: localhost\r\nTransfer-Encoding: chunked\r\nConnection: keep-alive\r\n\r\n5\r\nhello\r\n1\r\n!\r\n0\r\n\r\n',
        status = 200,
        body = 'chunked:hello!',
    },
    {
        name = 'form',
        method = 'POST',
        request = 'POST /form HTTP/1.1\r\nHost: localhost\r\nContent-Type: application/x-www-form-urlencoded\r\nContent-Length: ' .. tostring(#form_body) .. '\r\nConnection: keep-alive\r\n\r\n' .. form_body,
        status = 200,
        body = 'form:alice cat:urlencoded\n',
    },
    {
        name = 'json',
        method = 'POST',
        request = 'POST /json HTTP/1.1\r\nHost: localhost\r\nContent-Type: application/json\r\nContent-Length: ' .. tostring(#json_body) .. '\r\nConnection: keep-alive\r\n\r\n' .. json_body,
        status = 200,
        body = 'json:demo:42:true\n',
    },
    {
        name = 'multipart',
        method = 'POST',
        request = 'POST /multipart HTTP/1.1\r\nHost: localhost\r\nContent-Type: multipart/form-data; boundary=' .. multipart_boundary .. '\r\nContent-Length: ' .. tostring(#multipart_body) .. '\r\nConnection: keep-alive\r\n\r\n' .. multipart_body,
        status = 200,
        body = 'multipart:alice:hello.txt:file-body\n',
    },
    {
        name = 'headers',
        method = 'GET',
        request = 'GET /headers HTTP/1.1\r\nHost: localhost\r\nX-Demo: demo-header\r\nConnection: keep-alive\r\n\r\n',
        status = 200,
        body = 'demo-header\n',
    },
    {
        name = 'head',
        method = 'HEAD',
        request = 'HEAD /head HTTP/1.1\r\nHost: localhost\r\nConnection: keep-alive\r\n\r\n',
        status = 200,
        body = '',
    },
    {
        name = 'missing',
        method = 'GET',
        request = 'GET /missing HTTP/1.1\r\nHost: localhost\r\nConnection: keep-alive\r\n\r\n',
        status = 404,
        body = 'not found\n',
    },
}

local next_response = 1

local function finish(ok, msg)
    if finished then return end
    finished = true
    print('[XHTTP-MAIN] finish:', ok, msg)
    if client_conn then
        client_conn:close('done')
        client_conn = nil
    end
    xthread.stop(ok and 0 or 1)
end

local client_handler = {}

function client_handler.on_connect(conn)
    client_conn = conn
    conn:set_framing({ type = 'raw', max_packet = 1024 * 1024 })
    local out = {}
    for _, t in ipairs(tests) do
        out[#out + 1] = t.request
    end
    assert(conn:send_raw(table.concat(out)))
end

function client_handler.on_packet(_, data)
    local pos = 1
    local consumed = 0
    while pos <= #data and next_response <= #tests do
        local expect = tests[next_response]
        local resp, next_pos, err = codec.parse_response(data, pos, { method = expect.method })
        if not resp then
            if err == 'incomplete' then break end
            finish(false, 'client parse failed: ' .. tostring(err))
            return #data
        end

        if resp.status ~= expect.status then
            finish(false, string.format('%s status expected %d got %d',
                expect.name, expect.status, resp.status))
            return next_pos - 1
        end
        if resp.body ~= expect.body then
            finish(false, string.format('%s body mismatch expected=%q got=%q',
                expect.name, expect.body, resp.body))
            return next_pos - 1
        end

        print(string.format('[XHTTP-MAIN] response ok: %s status=%d len=%d',
            expect.name, resp.status, #resp.body))
        next_response = next_response + 1
        consumed = next_pos - 1
        pos = next_pos
    end

    -- -- if tests finished, exit
    -- if next_response > #tests then
    --     finish(true, 'all http tests ok')
    -- end
    return consumed
end

function client_handler.on_close(_, reason)
    print('[XHTTP-MAIN] client close:', reason)
end

local function __init()
    print(string.format('[XHTTP-MAIN] init http=%s:%d workers=%d', HOST, PORT, WORKERS))
    if not ENABLE then
        error('HTTP_ENABLE=0')
    end
    if XNET_WITH_HTTP == false then
        error('xnet was built without HTTP support')
    end
    assert(xnet.init())

    local ok, err = xhttp.start({
        host = HOST,
        port = PORT,
        worker_count = WORKERS,
        worker_base = xthread.WORKER_GRP3,
        app_script = 'demo/xhttp_app.lua',
        max_request_size = 1024 * 1024,
        server_name = 'xnet-http-demo',
    })
    if not ok then error(err) end

    local conn, cerr = xnet.connect(HOST, PORT, client_handler)
    if not conn then
        error(cerr)
    end
end

local function __update()
    xnet.poll(10)
end

local function __uninit()
    if client_conn then
        client_conn:close('uninit')
        client_conn = nil
    end
    xhttp.stop()
    xnet.uninit()
    print('[XHTTP-MAIN] uninit')
end

return {
    __init = __init,
    __update = __update,
    __uninit = __uninit,
    __thread_handle = __thread_handle,
}
