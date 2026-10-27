-- A stopped network worker must leave the main thread's sockets usable.
-- Run from xnet2lua: bin/xnet tests/lua/xnet_thread_lifecycle_test.lua LOG_FILE=0
local worker = 'tests/lua/xnet_thread_lifecycle_worker.lua'
local pass, alive = 0, false
local function start()
    assert(xthread.create_thread(20, 'NET', worker))
    alive = true
end
return {
    __init = function()
        assert(xnet.init())
        assert(xnet.init())
        xtimer.init(16)
        xtimer.add(5000, function() xthread.stop(1) end, 1)
        start()
    end,
    __thread_handle = function(_, op)
        if op ~= 'ready' then return end
        local ok, err = pcall(function()
            assert(xthread.shutdown_thread(20))
            alive = false
            local listener, why = xnet.listen('127.0.0.1', 0, {})
            assert(listener, why)
            listener:close()
            pass = pass + 1
            if pass < 3 then start()
            else io.write('PASS network survives 3 worker shutdowns\n'); xthread.stop(0) end
        end)
        if not ok then io.stderr:write(tostring(err), '\n'); xthread.stop(1) end
    end,
    __uninit = function()
        if alive then xthread.shutdown_thread(20) end
        xnet.uninit()
    end,
}
