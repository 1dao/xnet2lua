-- xhttp_main.lua - HTTP server demo and xsession-backed HTTP smoke test.
-- Main thread owns the listener and passes accepted sockets to HTTP workers.

local xhttp  = dofile('scripts/core/server/xhttp.lua')
local codec  = dofile('scripts/core/share/xhttp_codec.lua')
local router = dofile('scripts/core/share/xrouter.lua')
local xutils = require('xutils')

router.set_log_prefix('XHTTP-MAIN')
function xthread.register(pt, h) return router.register(pt, h) end

-- The HTTP app calls this through xthread.rpc(xthread.MAIN, ...). That gives
-- xhttp_main coverage for xsession yielding inside an HTTP route without a
-- dedicated helper worker script.
xthread.register('upper', function(s)
    return string.upper(tostring(s))
end)

local CONFIG_FILE = 'xnet.cfg'
local ok_cfg, cfg_err = xutils.load_config(CONFIG_FILE)
if not ok_cfg then
    io.stderr:write('[XHTTP-MAIN] config not loaded: ' .. tostring(cfg_err) .. '\n')
end

local HOST = xutils.get_config('HTTP_HOST', '127.0.0.1')
local PORT = tonumber(xutils.get_config('HTTP_PORT', '18080')) or 18080
local WORKERS = tonumber(xutils.get_config('HTTP_WORKERS', '2')) or 2
local ENABLE = xutils.get_config('HTTP_ENABLE', '1') ~= '0'

local client_conn = nil
local finished = false
local pending_buf = ''
local expectations = {}
local cur_test_idx = 0

local form_body = 'name=alice+cat&kind=urlencoded'
local json_body = assert(xutils.json_pack({
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

local function request(method, path, headers, body)
    headers = headers or {}
    body = body or ''
    local lines = { method .. ' ' .. path .. ' HTTP/1.1' }
    if not headers.Host and not headers.host then
        lines[#lines + 1] = 'Host: localhost'
    end
    if body ~= '' and not headers['Content-Length'] and not headers['content-length']
       and not headers['Transfer-Encoding'] and not headers['transfer-encoding'] then
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
        responses = {
            { method = 'GET', status = 200, body = 'hello xnet\n' },
        },
    },
    {
        name = 'echo',
        request = request('POST', '/echo', nil, 'echo-body'),
        responses = {
            { method = 'POST', status = 200, body = 'echo-body' },
        },
    },
    {
        name = 'path param',
        request = request('GET', '/api/user/777'),
        responses = {
            { method = 'GET', status = 200, body = 'user_id=777\n' },
        },
    },
    {
        name = 'wildcard',
        request = request('GET', '/static/path/to/file.css'),
        responses = {
            { method = 'GET', status = 200, body = 'static=path/to/file.css\n' },
        },
    },
    {
        name = 'missing',
        request = request('GET', '/missing'),
        responses = {
            { method = 'GET', status = 404, body = 'not found\n' },
        },
    },
    {
        name = 'head',
        request = request('HEAD', '/head'),
        responses = {
            { method = 'HEAD', status = 200, body = '' },
        },
    },
    {
        name = 'chunked',
        request = request('POST', '/chunked',
            { ['Transfer-Encoding'] = 'chunked' },
            '5\r\nhello\r\n1\r\n!\r\n0\r\n\r\n'),
        responses = {
            { method = 'POST', status = 200, body = 'chunked:hello!' },
        },
    },
    {
        name = 'form',
        request = request('POST', '/form',
            { ['Content-Type'] = 'application/x-www-form-urlencoded' },
            form_body),
        responses = {
            { method = 'POST', status = 200, body = 'form:alice cat:urlencoded\n' },
        },
    },
    {
        name = 'json',
        request = request('POST', '/json',
            { ['Content-Type'] = 'application/json' },
            json_body),
        responses = {
            { method = 'POST', status = 200, body = 'json:demo:42:true\n' },
        },
    },
    {
        name = 'multipart',
        request = request('POST', '/multipart',
            { ['Content-Type'] = 'multipart/form-data; boundary=' .. multipart_boundary },
            multipart_body),
        responses = {
            { method = 'POST', status = 200, body = 'multipart:alice:hello.txt:file-body\n' },
        },
    },
    {
        name = 'headers',
        request = request('GET', '/headers', { ['X-Demo'] = 'demo-header' }),
        responses = {
            { method = 'GET', status = 200, body = 'demo-header\n' },
        },
    },
    {
        name = 'xthread rpc inside HTTP handler',
        request = request('GET', '/api/upper?text=hello'),
        responses = {
            { method = 'GET', status = 200, body = 'HELLO' },
        },
    },
    {
        name = 'handler error',
        request = request('GET', '/api/throw'),
        responses = {
            { method = 'GET', status = 500, body = 'internal server error\n' },
        },
    },
    {
        name = 'pipelining with mid-stream yield',
        request = table.concat({
            request('GET', '/hello?name=pipeA'),
            request('GET', '/api/upper?text=pipeb'),
            request('GET', '/hello?name=pipeC'),
        }),
        responses = {
            { method = 'GET', status = 200, body = 'hello pipeA\n' },
            { method = 'GET', status = 200, body = 'PIPEB' },
            { method = 'GET', status = 200, body = 'hello pipeC\n' },
        },
    },
    {
        name = 'malformed request',
        request = 'NOT-AN-HTTP-REQUEST\r\nHost: localhost\r\n\r\n',
        responses = {
            { method = 'GET', status = 400, any_body = true },
        },
    },
}

local function finish(ok, msg)
    if finished then return end
    finished = true
    print('[XHTTP-MAIN] finish:', ok, msg)
    if client_conn then
        client_conn:close('done')
        client_conn = nil
    end
    xhttp.stop()
    xthread.stop(ok and 0 or 1)
end

local client_handler = {}

local function start_next_test()
    cur_test_idx = cur_test_idx + 1
    local t = tests[cur_test_idx]
    if not t then
        finish(true, 'all http tests ok')
        return
    end

    print(string.format('[XHTTP-MAIN] test %d: %s', cur_test_idx, t.name))
    expectations = {}
    for i, e in ipairs(t.responses) do
        expectations[i] = {
            name = t.name,
            method = e.method,
            status = e.status,
            body = e.body,
            any_body = e.any_body,
        }
    end
    assert(client_conn:send_raw(t.request))
end

function client_handler.on_connect(conn)
    client_conn = conn
    conn:set_framing({ type = 'raw', max_packet = 1024 * 1024 })
    start_next_test()
end

function client_handler.on_packet(_, data)
    pending_buf = pending_buf .. data

    while #expectations > 0 do
        local expect = expectations[1]
        local resp, next_pos, err = codec.parse_response(pending_buf, 1,
            { method = expect.method })
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
        if not expect.any_body and resp.body ~= expect.body then
            finish(false, string.format('%s body mismatch expected=%q got=%q',
                expect.name, expect.body, resp.body))
            return #data
        end

        print(string.format('[XHTTP-MAIN] response ok: %s status=%d len=%d',
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
    print('[XHTTP-MAIN] client close:', reason)
    if not finished and #expectations > 0 then
        finish(false, string.format('connection closed with %d responses pending',
            #expectations))
    end
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
    __uninit = __uninit,
    __thread_handle = router.handle,
}
