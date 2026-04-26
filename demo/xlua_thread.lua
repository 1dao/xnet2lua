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

-- Default sync thread message handler
-- This handles POST and RPC dispatch to registered stubs
-- All handlers run in coroutines so they can yield for nested RPC calls
_stubs = {}
_thread_replys = {}

function xthread.register(pt, h)
    _stubs[pt] = h
end

local function __thread_handle(reply_router, k1, k2, k3, ...)
    if not reply_router then
        -- POST形式消息 [k1:pt]
        local h = _stubs[k1]
        if not h then
            if not k1 then return end -- quit signal
            io.stderr:write('[COMPUTE] thread message pt handle not found! pt: ' .. tostring(k1) .. '\n')
        else
            -- Run POST handler in coroutine so it can do RPC if needed
            local co = coroutine.create(function(...)
                h(k2, k3, ...)
            end)
            coroutine.resume(co, ...)
        end
        return
    end

    -- RPC形式消息 [k1:co, k2:sk, k3:pt]
    local reply = _thread_replys[reply_router]
    if not reply then
        io.stderr:write('[COMPUTE] thread message reply_router not found! reply_router: ' .. tostring(reply_router) .. ' pt: ' .. tostring(k3) .. '\n')
        return
    end
    local h = _stubs[k3]
    if not h then
        io.stderr:write('[COMPUTE] thread message pt handle not found! reply_router: ' .. tostring(reply_router) .. ' pt: ' .. tostring(k3) .. '\n')
        if not reply(k1, k2, k3, false, 'pt handle not found!') then
            io.stderr:write('[COMPUTE] thread message route failed!\n')
        end
        return
    end

    -- Run RPC handler in coroutine so it can do nested RPC calls (which require yield)
    local co = coroutine.create(function(...)
        -- Capture all results from pcall
        if not reply(k1, k2, k3, pcall(h, ...)) then
            io.stderr:write('[COMPUTE] thread message route failed! reply_router: ' .. tostring(reply_router) .. ' pt: ' .. tostring(k3) .. '\n')
        end
    end)
    coroutine.resume(co, ...)
end

-- POST handler: just print the received message
xthread.register('print_message', function(text)
    print('[COMPUTE] Received POST: ' .. text)
end)

-- RPC handler: add two numbers
xthread.register('add', function(a, b)
    print('[COMPUTE] add() called: a=', a, 'b=', b)
    return a + b, "1", "2", "3", "4"
end)

-- RPC handler: multiply, then call back to main thread
-- Thanks to coroutine wrapping in __thread_handle, this can do RPC
-- calls that yield just fine
xthread.register('multiply_and_callback', function(a, b)
    print('[COMPUTE] multiply_and_callback() called: a=', a, 'b=', b)
    local product = a * b
    -- RPC back to MAIN thread to verify reverse call works
    local main_id = xthread.MAIN
    local ok, reversed = xthread.rpc(main_id, 'reverse_string', tostring(product))
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
-- Return the definition table for xthread.create_thread
-- This includes all callbacks following the Lua script convention
-- -----------------------------------------------------------------------------
local function sinking()
    return {
        __init = __init,
        __update = __update,
        __uninit = __uninit,
        __thread_handle = __thread_handle,
    }
end

-- sinking
do return sinking() end
