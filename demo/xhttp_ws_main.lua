-- xhttp_ws_main.lua - WebSocket over the worker-pool HTTP server.
--
-- Same topology as xhttp_main.lua: the main thread owns the listener and hands
-- accepted sockets to xhttp workers. The workers run demo/xhttp_app.lua, whose
-- GET /ws route returns a { websocket = ... } spec; the worker completes the
-- RFC 6455 handshake and the fd then speaks WebSocket. The main thread drives a
-- loopback WebSocket client through handshake -> welcome -> text echo ->
-- binary echo -> close. Exits 0 on success, 1 on the first mismatch.
--
-- Run with:  bin\xnet.exe demo/xhttp_ws_main.lua

local xhttp  = dofile('scripts/core/server/xhttp.lua')
local codec  = dofile('scripts/core/share/xhttp_codec.lua')
local ws     = dofile('scripts/core/share/xwebsocket.lua')
local xutils = require('xutils')

local HOST = xutils.get_config('HTTP_HOST', '127.0.0.1')
local PORT = tonumber(xutils.get_config('WS_PORT', '18093')) or 18093
local WORKERS = tonumber(xutils.get_config('HTTP_WORKERS', '2')) or 2

local CLIENT_KEY = 'dGhlIHNhbXBsZSBub25jZQ=='
local EXPECT_ACCEPT = 's3pPLMBiTxaQ9kYGzzhZRbK+xOo='
local MAX = 1024 * 1024

local client_conn = nil
local finished = false
local buf = ''
local phase = 'handshake'   -- handshake -> welcome -> echo -> binecho -> closing
local started_at = nil

local function finish(ok, msg)
    if finished then return end
    finished = true
    print('[XHTTP-WS] finish:', ok, msg)
    if client_conn then client_conn:close('done'); client_conn = nil end
    xhttp.stop()
    xthread.stop(ok and 0 or 1)
end

local function client_frame(opcode, payload)
    return ws.encode(opcode, payload, { mask = true })
end

local function client_close(code, reason)
    local payload = ws.close_frame(code, reason):sub(3)
    return ws.encode(ws.OP_CLOSE, payload, { mask = true })
end

local client_handler = {}

function client_handler.on_connect(conn)
    client_conn = conn
    conn:set_framing({ type = 'raw', max_packet = MAX })
    local req = table.concat({
        'GET /ws HTTP/1.1',
        'Host: ' .. HOST,
        'Upgrade: websocket',
        'Connection: Upgrade',
        'Sec-WebSocket-Key: ' .. CLIENT_KEY,
        'Sec-WebSocket-Version: 13',
        'Sec-WebSocket-Protocol: echo',
        '', '',
    }, '\r\n')
    assert(conn:send_raw(req))
end

function client_handler.on_packet(_, data)
    buf = buf .. data

    if phase == 'handshake' then
        local resp, next_pos, err = codec.parse_response(buf, 1, { method = 'GET' })
        if not resp then
            if err == 'incomplete' then return #data end
            finish(false, 'handshake parse failed: ' .. tostring(err)); return #data
        end
        if resp.status ~= 101 then
            finish(false, 'expected 101 got ' .. tostring(resp.status)); return #data
        end
        if resp.headers['sec-websocket-accept'] ~= EXPECT_ACCEPT then
            finish(false, 'bad accept key'); return #data
        end
        if resp.headers['sec-websocket-protocol'] ~= 'echo' then
            finish(false, 'bad protocol: ' .. tostring(resp.headers['sec-websocket-protocol']))
            return #data
        end
        print('[XHTTP-WS] handshake ok')
        buf = buf:sub(next_pos)
        phase = 'welcome'
    end

    while #buf > 0 do
        local frame, next_pos, derr = ws.decode(buf, 1, { max_frame_size = MAX })
        if not frame then
            if derr == 'incomplete' then break end
            finish(false, 'frame decode error: ' .. tostring(derr)); return #data
        end
        buf = buf:sub(next_pos)

        if frame.opcode == ws.OP_TEXT then
            if phase == 'welcome' then
                if frame.payload ~= 'welcome' then
                    finish(false, 'bad welcome: ' .. frame.payload); return #data
                end
                print('[XHTTP-WS] welcome ok')
                phase = 'echo'
                client_conn:send_raw(client_frame(ws.OP_TEXT, 'hi'))
            elseif phase == 'echo' then
                if frame.payload ~= 'echo:hi' then
                    finish(false, 'bad echo: ' .. frame.payload); return #data
                end
                print('[XHTTP-WS] text echo ok')
                phase = 'binecho'
                client_conn:send_raw(client_frame(ws.OP_BIN, 'bin\0data'))
            end
        elseif frame.opcode == ws.OP_BIN then
            if phase == 'binecho' then
                if frame.payload ~= 'bin\0data' then
                    finish(false, 'bad binary echo'); return #data
                end
                print('[XHTTP-WS] binary echo ok')
                phase = 'closing'
                client_conn:send_raw(client_close(ws.CLOSE_NORMAL, 'bye'))
            end
        elseif frame.opcode == ws.OP_CLOSE then
            if phase == 'closing' then
                finish(true, 'worker websocket lifecycle ok')
            else
                finish(false, 'unexpected close in phase ' .. phase)
            end
            return #data
        end
    end
    return #data
end

function client_handler.on_close(_, reason)
    if not finished then
        if phase == 'closing' then
            finish(true, 'worker websocket lifecycle ok (closed by peer)')
        else
            finish(false, 'closed early in phase ' .. phase .. ': ' .. tostring(reason))
        end
    end
end

local function __init()
    print(string.format('[XHTTP-WS] init ws-over-http %s:%d workers=%d', HOST, PORT, WORKERS))
    if XNET_WITH_HTTP == false then
        error('xnet was built without HTTP support')
    end
    assert(xnet.init())

    local ok, err = xhttp.start({
        host = HOST,
        port = PORT,
        worker_count = WORKERS,
        worker_base = xthread.WORKER_GRP3,
        worker_name = 'xhttp-ws-worker',
        app_script = 'demo/xhttp_app.lua',
        max_request_size = MAX,
        server_name = 'xnet-ws-demo',
    })
    if not ok then error(err) end

    local conn, cerr = xnet.connect(HOST, PORT, client_handler)
    if not conn then error(cerr) end
    started_at = os.time()
end

local function __update()
    if not finished and started_at and os.time() - started_at >= 10 then
        finish(false, 'timeout')
    end
end

local function __uninit()
    if client_conn then client_conn:close('uninit'); client_conn = nil end
    xhttp.stop()
    xnet.uninit()
    print('[XHTTP-WS] uninit')
end

return {
    __init = __init,
    __update = __update,
    __uninit = __uninit,
    __thread_handle = function() end,
}
