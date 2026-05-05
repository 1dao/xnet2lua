-- xlua_thread.lua - COMPUTE thread Lua script
-- Now returned as a definition table for xthread.create_thread
-- When dynamically created from Lua, this module returns:
--   {
--     __init = function() end,        -- called after thread starts
--     __update = function() end,      -- called each xthread_update
--     __uninit = function() end,      -- called before thread exit
--     __thread_handle = function() end -- message handler
--   }

print('[COMPUTE] Current thread id = ' .. xthread.current_id())

-- Cross-thread message dispatch is provided by xrouter (per-Lua-state
-- singleton); the script keeps its usual return-table shape and just plugs
-- router.handle into __thread_handle.
local router = dofile('demo/xrouter.lua')
router.set_log_prefix('COMPUTE')

-- Handler: just print the received message. Called via POST in this demo,
-- but the registration is calling-convention-agnostic.
router.register('print_message', function(text)
    print('[COMPUTE] Received POST: ' .. text)
end)

-- Handler: add two numbers. Called via RPC in this demo; return values become
-- the reply.
router.register('add', function(a, b)
    print('[COMPUTE] add() called: a=', a, 'b=', b)
    return a + b, "1", "2", "3", "4"
end)

-- Handler: deliberately blocks this worker for a short time. Used by the
-- main-thread RPC timeout smoke test.
router.register('sleep_ms', function(ms)
    ms = tonumber(ms) or 0
    local deadline = xtimer.now_ms() + ms
    while xtimer.now_ms() < deadline do
    end
    return 'slept:' .. tostring(ms)
end)

-- Handler: multiply, then call back to main thread via RPC. All handlers run
-- in a coroutine, so xthread.rpc can yield freely.
router.register('multiply_and_callback', function(a, b)
    print('[COMPUTE] multiply_and_callback() called: a=', a, 'b=', b)
    local product = a * b
    -- RPC back to MAIN thread to verify reverse call works
    local main_id = xthread.MAIN
    local ok, reversed = xthread.rpc(main_id, 'reverse_string', 0, tostring(product))
    if ok then
        print('[COMPUTE] Reverse result from MAIN: ' .. tostring(reversed))
        return product, reversed
    else
        print('[COMPUTE] RPC to MAIN failed: ' .. tostring(reversed))
        return nil
    end
end)

-- -----------------------------------------------------------------------------
-- Lifecycle callbacks for dynamic thread creation
-- -----------------------------------------------------------------------------

local function __init()
    print('[COMPUTE] __init: thread starting')
    -- xthread.init will be called automatically by the dynamic creation
    -- We just do any additional thread-specific initialization here
    print('[COMPUTE] All handlers registered')
end

local function __update()
    -- Process pending messages - xthread already handles this via xthread_update
    -- We don't need to do anything here unless we have per-frame processing
end

local function __uninit()
    print('[COMPUTE] __uninit: thread shutting down')
end

-- -----------------------------------------------------------------------------
-- Return the definition table for xthread.create_thread. router.handle is
-- exported by xrouter as the dispatcher closure for __thread_handle.
-- -----------------------------------------------------------------------------
return {
    __init = __init,
    __update = __update,
    __uninit = __uninit,
    __thread_handle = router.handle,
}
