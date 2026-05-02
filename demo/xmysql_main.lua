-- Main thread for the Lua xmysql demo.
-- Main starts MySQL service thread plus business workers in __init, and closes
-- them in __uninit. Business workers issue MySQL operations.

local xmysql = dofile('demo/xmysql.lua')
local xutils = require('xutils')

local CONFIG_FILE = 'demo/xnet.cfg'
local ok_cfg, cfg_err = xutils.load_config(CONFIG_FILE)
if not ok_cfg then
    io.stderr:write('[XMYSQL-MAIN] config not loaded: ' .. tostring(cfg_err) .. '\n')
end

local HOST = xutils.get_config('MYSQL_HOST', '127.0.0.1')
local PORT = tonumber(xutils.get_config('MYSQL_PORT', '3306')) or 3306
local USER = xutils.get_config('MYSQL_USER', 'chib')
local PASSWORD = xutils.get_config('MYSQL_PASSWORD', 'xqb111')
local DATABASE = xutils.get_config('MYSQL_DATABASE', '')

local BUSINESS_THREADS = {
    { id = xthread.WORKER_GRP2, name = 'mysql-biz-1', label = 'biz-1' },
    { id = xthread.WORKER_GRP2 + 1, name = 'mysql-biz-2', label = 'biz-2' },
}

local business_running = {}
local done_count = 0
local final_ok = true
local finished = false
local started_at = os.time()
local TIMEOUT_SEC = 10

_stubs = {}
_thread_replys = {}

function xthread.register(pt, h)
    _stubs[pt] = h
end

local function shutdown_business()
    for _, spec in ipairs(BUSINESS_THREADS) do
        if business_running[spec.id] then
            local ok, err = xthread.shutdown_thread(spec.id)
            if not ok then
                io.stderr:write('[XMYSQL-MAIN] shutdown business failed: ' .. tostring(err) .. '\n')
            end
            business_running[spec.id] = nil
        end
    end
end

local function request_stop(ok, msg)
    if finished then return end
    finished = true
    final_ok = ok
    print('[XMYSQL-MAIN] finish:', ok, msg)
    xthread.stop(ok and 0 or 1)
end

xthread.register('xmysql_business_done', function(thread_id, ok, msg)
    print(string.format('[XMYSQL-MAIN] business done thread=%s ok=%s msg=%s',
        tostring(thread_id), tostring(ok), tostring(msg)))

    done_count = done_count + 1
    if not ok then
        final_ok = false
    end

    if done_count >= #BUSINESS_THREADS then
        request_stop(final_ok, final_ok and 'all business mysql tests ok' or 'some business mysql tests failed')
    end
end)

local function __thread_handle(reply_router, k1, k2, k3, ...)
    if reply_router then
        io.stderr:write('[XMYSQL-MAIN] unexpected RPC message: ' .. tostring(k3) .. '\n')
        return
    end

    local h = _stubs[k1]
    if h then
        h(k2, k3, ...)
    elseif k1 then
        io.stderr:write('[XMYSQL-MAIN] no handler for pt=' .. tostring(k1) .. '\n')
    end
end

local function __init()
    started_at = os.time()
    print(string.format('[XMYSQL-MAIN] init mysql=%s:%d user=%s db=%s business=%d',
        HOST, PORT, USER, DATABASE ~= '' and DATABASE or '(none)', #BUSINESS_THREADS))

    local ok, err = xmysql.start({
        host = HOST,
        port = PORT,
        user = USER,
        password = PASSWORD,
        database = DATABASE,
        pool_size = 2,
        reconnect_ms = 100,
        max_reply_size = 1024 * 1024,
    })
    if not ok then
        error(err)
    end

    for _, spec in ipairs(BUSINESS_THREADS) do
        ok, err = xthread.create_thread(spec.id, spec.name, 'demo/xmysql_business.lua')
        if not ok then
            error(err)
        end
        business_running[spec.id] = true
    end

    for _, spec in ipairs(BUSINESS_THREADS) do
        ok, err = xthread.post(spec.id, 'run_mysql_test', spec.label)
        if not ok then
            error(err)
        end
    end
end

local function __update()
    if not finished and os.time() - started_at > TIMEOUT_SEC then
        request_stop(false, 'mysql test timeout')
    end
end

local function __uninit()
    xmysql.stop(not final_ok)
    shutdown_business()
    print('[XMYSQL-MAIN] uninit')
end

return {
    __init = __init,
    __update = __update,
    __uninit = __uninit,
    __thread_handle = __thread_handle,
}
