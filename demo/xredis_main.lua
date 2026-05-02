-- Main thread for the Lua xredis demo.
-- Main starts Redis service thread plus business workers in __init, and closes
-- them in __uninit. Business workers issue Redis operations.

local xredis = dofile('demo/xredis.lua')
local xutils = require('xutils')

local CONFIG_FILE = 'demo/xnet.cfg'
local ok_cfg, cfg_err = xutils.load_config(CONFIG_FILE)
if not ok_cfg then
    io.stderr:write('[XREDIS-MAIN] config not loaded: ' .. tostring(cfg_err) .. '\n')
end

local HOST = xutils.get_config('REDIS_HOST', '127.0.0.1')
local PORT = tonumber(xutils.get_config('REDIS_PORT', '6379')) or 6379
local DB = tonumber(xutils.get_config('REDIS_DB', '1')) or 1

local BUSINESS_THREADS = {
    { id = xthread.WORKER_GRP1, name = 'redis-biz-1', label = 'biz-1' },
    { id = xthread.WORKER_GRP1 + 1, name = 'redis-biz-2', label = 'biz-2' },
}

local business_running = {}
local done_count = 0
local final_ok = true
local finished = false

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
                io.stderr:write('[XREDIS-MAIN] shutdown business failed: ' .. tostring(err) .. '\n')
            end
            business_running[spec.id] = nil
        end
    end
end

local function request_stop(ok, msg)
    if finished then return end
    finished = true
    final_ok = ok
    print('[XREDIS-MAIN] finish:', ok, msg)
    xthread.stop(ok and 0 or 1)
end

xthread.register('xredis_business_done', function(thread_id, ok, msg)
    print(string.format('[XREDIS-MAIN] business done thread=%s ok=%s msg=%s',
        tostring(thread_id), tostring(ok), tostring(msg)))

    done_count = done_count + 1
    if not ok then
        final_ok = false
    end

    if done_count >= #BUSINESS_THREADS then
        request_stop(final_ok, final_ok and 'all business redis tests ok' or 'some business redis tests failed')
    end
end)

local function __thread_handle(reply_router, k1, k2, k3, ...)
    if reply_router then
        io.stderr:write('[XREDIS-MAIN] unexpected RPC message: ' .. tostring(k3) .. '\n')
        return
    end

    local h = _stubs[k1]
    if h then
        h(k2, k3, ...)
    elseif k1 then
        io.stderr:write('[XREDIS-MAIN] no handler for pt=' .. tostring(k1) .. '\n')
    end
end

local function __init()
    print(string.format('[XREDIS-MAIN] init redis=%s:%d db=%d business=%d',
        HOST, PORT, DB, #BUSINESS_THREADS))

    local ok, err = xredis.start({
        host = HOST,
        port = PORT,
        db = DB,
        pool_size = 2,
        reconnect_ms = 100,
        max_reply_size = 1024 * 1024,
    })
    if not ok then
        error(err)
    end

    for _, spec in ipairs(BUSINESS_THREADS) do
        ok, err = xthread.create_thread(spec.id, spec.name, 'demo/xredis_business.lua')
        if not ok then
            error(err)
        end
        business_running[spec.id] = true
    end

    for _, spec in ipairs(BUSINESS_THREADS) do
        ok, err = xthread.post(spec.id, 'run_redis_test', spec.label)
        if not ok then
            error(err)
        end
    end
end

local function __update()
end

local function __uninit()
    shutdown_business()
    xredis.stop()
    print('[XREDIS-MAIN] uninit')
end

return {
    __init = __init,
    __update = __update,
    __uninit = __uninit,
    __thread_handle = __thread_handle,
}
