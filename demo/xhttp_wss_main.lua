-- xhttp_wss_main.lua - Secure WebSocket (wss://) over the HTTPS worker pool.
--
-- This proves WebSocket rides transparently on top of TLS: the only difference
-- from demo/xhttp_ws_main.lua is the server starts with https=true (so the
-- worker attaches each fd with xnet.attach_tls) and the loopback client uses
-- xnet.connect_tls. The upgrade handshake + frames flow inside the TLS tunnel;
-- no WebSocket-specific TLS code is needed. Exits 0 on success, 1 on mismatch.
--
-- Run with:  bin\xnet.exe demo/xhttp_wss_main.lua   (needs WITH_HTTPS=1)

local xhttp  = dofile('scripts/core/server/xhttp.lua')
local codec  = dofile('scripts/core/share/xhttp_codec.lua')
local ws     = dofile('scripts/core/share/xwebsocket.lua')
local xutils = require('xutils')

local HOST = xutils.get_config('HTTP_HOST', '127.0.0.1')
local PORT = tonumber(xutils.get_config('WSS_PORT', '18095')) or 18095
local WORKERS = tonumber(xutils.get_config('HTTP_WORKERS', '2')) or 2
local CERT = xutils.get_config('HTTPS_CERT', 'demo/certs/server.crt')
local KEY  = xutils.get_config('HTTPS_KEY', 'demo/certs/server.key')

local CLIENT_KEY = 'dGhlIHNhbXBsZSBub25jZQ=='
local EXPECT_ACCEPT = 's3pPLMBiTxaQ9kYGzzhZRbK+xOo='
local MAX = 1024 * 1024

local client_conn = nil
local finished = false
local buf = ''
local phase = 'handshake'   -- handshake -> welcome -> echo -> closing
local started_at = nil

local function finish(ok, msg)
    if finished then return end
    finished = true
    print('[XHTTP-WSS] finish:', ok, msg)
    if client_conn then client_conn:close('done'); client_conn = nil end
    xhttp.stop()
    xthread.stop(ok and 0 or 1)
end

local function client_frame(opcode, payload)
    return ws.encode(opcode, payload, { mask = true })
end

local function client_close(code, reason)
    return ws.encode(ws.OP_CLOSE, ws.close_frame(code, reason):sub(3), { mask = true })
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
        print('[XHTTP-WSS] TLS handshake + WS handshake ok')
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
                print('[XHTTP-WSS] welcome ok (over TLS)')
                phase = 'echo'
                client_conn:send_raw(client_frame(ws.OP_TEXT, 'secure-hi'))
            elseif phase == 'echo' then
                if frame.payload ~= 'echo:secure-hi' then
                    finish(false, 'bad echo: ' .. frame.payload); return #data
                end
                print('[XHTTP-WSS] encrypted echo ok')
                phase = 'closing'
                client_conn:send_raw(client_close(ws.CLOSE_NORMAL, 'bye'))
            end
        elseif frame.opcode == ws.OP_CLOSE then
            if phase == 'closing' then
                finish(true, 'wss lifecycle ok')
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
            finish(true, 'wss lifecycle ok (closed by peer)')
        else
            finish(false, 'closed early in phase ' .. phase .. ': ' .. tostring(reason))
        end
    end
end

local function __init()
    print(string.format('[XHTTP-WSS] init wss %s:%d workers=%d cert=%s', HOST, PORT, WORKERS, CERT))
    if XNET_WITH_HTTPS == false then
        error('xnet was built without HTTPS support; rebuild with WITH_HTTPS=1')
    end
    assert(xnet.init())

    local ok, err = xhttp.start({
        host = HOST,
        port = PORT,
        https = true,
        cert_file = CERT,
        key_file = KEY,
        worker_count = WORKERS,
        worker_base = xthread.WORKER_GRP3,
        worker_name = 'xhttp-wss-worker',
        app_script = 'demo/xhttp_app.lua',
        max_request_size = MAX,
        server_name = 'xnet-wss-demo',
        -- HSTS on the secure listener: every HTTP(S) response advertises it.
        hsts = { max_age = 31536000 },
    })
    if not ok then error(err) end

    -- Self-signed demo cert -> verify=false. In production drop verify (defaults
    -- to true) and let the bundled CA / ca_file validate the chain.
    local conn, cerr = xnet.connect_tls(HOST, PORT, client_handler, {
        verify = false,
        server_name = HOST,
    })
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
    print('[XHTTP-WSS] uninit')
end

return {
    __init = __init,
    __update = __update,
    __uninit = __uninit,
    __thread_handle = function() end,
}
