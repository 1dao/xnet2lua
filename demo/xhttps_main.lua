-- xhttps_main.lua - HTTPS server demo.
-- Starts the same Lua HTTP app over TLS. Use openssl/curl to verify it.

local xhttp = dofile('demo/xhttp.lua')

local CONFIG_FILE = 'demo/xnet.cfg'
local ok_cfg, cfg_err = xnet.load_config(CONFIG_FILE)
if not ok_cfg then
    io.stderr:write('[XHTTPS-MAIN] config not loaded: ' .. tostring(cfg_err) .. '\n')
end

local HOST = xnet.get_config('HTTP_HOST', '127.0.0.1')
local PORT = tonumber(xnet.get_config('HTTPS_PORT', '18443')) or 18443
local WORKERS = tonumber(xnet.get_config('HTTP_WORKERS', '2')) or 2
local CERT = xnet.get_config('HTTPS_CERT', 'demo/certs/server.crt')
local KEY = xnet.get_config('HTTPS_KEY', 'demo/certs/server.key')
local TEST_SECONDS = tonumber(xnet.get_config('HTTPS_TEST_SECONDS', '15')) or 15

local started_at = nil
local stopped = false

_stubs = {}
_thread_replys = {}

function xthread.register(pt, h)
    _stubs[pt] = h
end

local function __thread_handle(reply_router, k1, k2, k3, ...)
    if reply_router then
        io.stderr:write('[XHTTPS-MAIN] unexpected RPC message: ' .. tostring(k3) .. '\n')
        return
    end

    local h = _stubs[k1]
    if h then
        h(k2, k3, ...)
    elseif k1 then
        io.stderr:write('[XHTTPS-MAIN] no handler for pt=' .. tostring(k1) .. '\n')
    end
end

local function now_sec()
    return os.time()
end

local function __init()
    print(string.format('[XHTTPS-MAIN] init https=%s:%d workers=%d cert=%s',
        HOST, PORT, WORKERS, CERT))
    if XNET_WITH_HTTPS == false then
        error('xnet was built without HTTPS support; rebuild with WITH_HTTPS=1')
    end
    assert(xnet.init())

    local ok, err = xhttp.start({
        host = HOST,
        port = PORT,
        https = true,
        worker_count = WORKERS,
        worker_base = xthread.WORKER_GRP3,
        app_script = 'demo/xhttp_app.lua',
        cert_file = CERT,
        key_file = KEY,
        max_request_size = 1024 * 1024,
        server_name = 'xnet-https-demo',
    })
    if not ok then error(err) end

    started_at = now_sec()
    print(string.format('[XHTTPS-MAIN] ready; auto-stop in %ds', TEST_SECONDS))
end

local function __update()
    xnet.poll(10)
    if not stopped and started_at and now_sec() - started_at >= TEST_SECONDS then
        stopped = true
        print('[XHTTPS-MAIN] finish: true https server demo timeout reached')
        xthread.stop(0)
    end
end

local function __uninit()
    xhttp.stop()
    xnet.uninit()
    print('[XHTTPS-MAIN] uninit')
end

return {
    __init = __init,
    __update = __update,
    __uninit = __uninit,
    __thread_handle = __thread_handle,
}
