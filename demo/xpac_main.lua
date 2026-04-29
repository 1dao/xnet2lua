-- xpac_main.lua - browser test entry for editing ./proxy.pac.

local xhttp = dofile('demo/xhttp.lua')

local CONFIG_FILE = 'demo/xnet.cfg'
local ok_cfg, cfg_err = xnet.load_config(CONFIG_FILE)
if not ok_cfg then
    io.stderr:write('[XPAC-MAIN] config not loaded: ' .. tostring(cfg_err) .. '\n')
end

local HOST = xnet.get_config('PAC_WEB_HOST', '127.0.0.1')
local PORT = tonumber(xnet.get_config('PAC_WEB_PORT', '18090')) or 18090

_stubs = {}
_thread_replys = {}

function xthread.register(pt, h)
    _stubs[pt] = h
end

local function __thread_handle(reply_router, k1, k2, k3, ...)
    if reply_router then
        io.stderr:write('[XPAC-MAIN] unexpected RPC message: ' .. tostring(k3) .. '\n')
        return
    end

    local h = _stubs[k1]
    if h then
        h(k2, k3, ...)
    elseif k1 then
        io.stderr:write('[XPAC-MAIN] no handler for pt=' .. tostring(k1) .. '\n')
    end
end

local function __init()
    print(string.format('[XPAC-MAIN] init http=%s:%d pac=%s',
        HOST, PORT, xnet.get_config('PAC_FILE', 'proxy.pac')))
    assert(xnet.init())

    local ok, err = xhttp.start({
        host = HOST,
        port = PORT,
        worker_count = 1,
        worker_base = xthread.WORKER_GRP3,
        app_script = 'demo/xpac_app.lua',
        max_request_size = 1024 * 1024,
        server_name = 'xnet-pac-demo',
    })
    if not ok then error(err) end

    print(string.format('[XPAC-MAIN] open http://%s:%d/', HOST, PORT))
end

local function __update()
    xnet.poll(10)
end

local function __uninit()
    xhttp.stop()
    xnet.uninit()
    print('[XPAC-MAIN] uninit')
end

return {
    __init = __init,
    __update = __update,
    __uninit = __uninit,
    __thread_handle = __thread_handle,
}
