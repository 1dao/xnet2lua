-- xnet_main.lua - main thread for the xnet/xchannel demo.
-- This thread only listens and passes accepted fds to the worker thread.

local WORKER_ID = 42
local HOST = '127.0.0.1'
local PORT = 19091

local listener
local worker_running = false
local done = false

_stubs = {}
_thread_replys = {}

function xthread.register(pt, h)
    _stubs[pt] = h
end

local function __main_handle(reply_router, k1, k2, k3, ...)
    if reply_router then
        io.stderr:write('[XNET-MAIN] unexpected RPC message: ' .. tostring(k3) .. '\n')
        return
    end

    local h = _stubs[k1]
    if h then
        h(k2, k3, ...)
    elseif k1 then
        io.stderr:write('[XNET-MAIN] no handler for pt=' .. tostring(k1) .. '\n')
    end
end

local function shutdown_worker()
    if not worker_running then return true end
    local ok, err = xthread.shutdown_thread(WORKER_ID)
    if not ok then
        io.stderr:write('[XNET-MAIN] shutdown worker failed: ' .. tostring(err) .. '\n')
        return false
    end
    worker_running = false
    return true
end

xthread.register('xnet_done', function(ok, msg)
    if done then return end
    done = true
    print('[XNET-MAIN] worker result:', ok, msg)
    if listener then
        listener:close('done')
        listener = nil
    end
    shutdown_worker()
    xthread.stop(ok and 0 or 1)
end)

local function __init()
    print('[XNET-MAIN] init')
    assert(xnet.init())

    listener = assert(xnet.listen_fd(HOST, PORT, {
        on_accept = function(_, fd, ip, port)
            print(string.format('[XNET-MAIN] accepted fd=%s from %s:%s', tostring(fd), tostring(ip), tostring(port)))
            local ok, err = xthread.post(WORKER_ID, 'accepted_fd', fd, ip, port)
            if not ok then
                io.stderr:write('[XNET-MAIN] post accepted fd failed: ' .. tostring(err) .. '\n')
                return false
            end
            return true
        end,
        on_close = function(_, reason)
            print('[XNET-MAIN] listener closed:', reason)
        end,
    }))
    print(string.format('[XNET-MAIN] listening on %s:%d', HOST, PORT))

    local ok, err = xthread.create_thread(WORKER_ID, 'xnet-worker', 'demo/xnet_worker.lua')
    if not ok then error(err) end
    worker_running = true

    ok, err = xthread.post(WORKER_ID, 'start_client', HOST, PORT)
    if not ok then error(err) end
end

local function __update()
    xnet.poll(10)
end

local function __uninit()
    if listener then
        listener:close('uninit')
        listener = nil
    end
    shutdown_worker()
    xnet.uninit()
    print('[XNET-MAIN] uninit')
end

return {
    __init = __init,
    __update = __update,
    __uninit = __uninit,
    __thread_handle = __main_handle,
}
