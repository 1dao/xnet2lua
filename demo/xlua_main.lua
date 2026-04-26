-- xlua_main.lua - MAIN thread Lua script
-- Called by xlua_test C main program
-- Now follows the same pattern as dynamically created threads:
-- Returns a definition table with lifecycle callbacks and message handler
-- All tests run in a coroutine from __init, exits via xthread.stop() when done

local COMPUTE_THREAD_ID = 99 -- Keep below XTHR_MAX
local compute_thread_running = false

print('[MAIN] Current thread id = ' .. xthread.current_id())

-- Default sync thread message handler (copied from thread_router.lua)
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
            io.stderr:write('[MAIN] thread message pt handle not found! pt: ' .. tostring(k1) .. '\n')
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
        io.stderr:write('[MAIN] thread message reply_router not found! reply_router: ' .. tostring(reply_router) .. ' pt: ' .. tostring(k3) .. '\n')
        return
    end
    local h = _stubs[k3]
    if not h then
        io.stderr:write('[MAIN] thread message pt handle not found! reply_router: ' .. tostring(reply_router) .. ' pt: ' .. tostring(k3) .. '\n')
        if not reply(k1, k2, k3, false, 'pt handle not found!') then
            io.stderr:write('[MAIN] thread message route failed!\n')
        end
        return
    end

    -- Run RPC handler in coroutine so it can do nested RPC calls (which require yield)
    local co = coroutine.create(function(...)
        -- Capture all results from pcall
        if not reply(k1, k2, k3, pcall(h, ...)) then
            io.stderr:write('[MAIN] thread message route failed! reply_router: ' .. tostring(reply_router) .. ' pt: ' .. tostring(k3) .. '\n')
        end
    end)
    coroutine.resume(co, ...)
end

-- RPC handler: reverse a string (called back from COMPUTE)
xthread.register('reverse_string', function(s)
    print('[MAIN] reverse_string() called: ' .. s)
    local reversed = string.reverse(s)
    return reversed
    -- return 'aa', 'bb', 12345
end)

local check_results

local function shutdown_compute_thread()
    if not compute_thread_running then
        return true
    end

    local ok, err = xthread.shutdown_thread(COMPUTE_THREAD_ID)
    if not ok then
        io.stderr:write('[MAIN] Failed to shutdown compute thread: ' .. tostring(err) .. '\n')
        return false
    end

    compute_thread_running = false
    print('[MAIN] Compute thread shutdown complete')
    return true
end

-- Test function that runs all tests
local function run_tests()
    print('\n===== Starting tests =====')

    -- Test 1: POST fire-and-forget
    print('\n[Test 1] POST from MAIN to COMPUTE')
    local ok, err = xthread.post(COMPUTE_THREAD_ID, 'print_message', 'Hello from MAIN (dynamically created)!')
    if not ok then
        print('[MAIN] POST failed: ' .. err)
    else
        print('[MAIN] POST succeeded')
    end

    -- Test 2: RPC add
    print('\n[Test 2] RPC add(123, 456) from MAIN to COMPUTE')
    do
        print("[MAIN] multi result:", xthread.rpc(COMPUTE_THREAD_ID, 'add', 123, 456))
        local ok, result = xthread.rpc(COMPUTE_THREAD_ID, 'add', 123, 456)
        if ok then
            print('[MAIN] RPC result: 123 + 456 = ' .. result)
            TEST_add_result = result
        else
            print('[MAIN] RPC failed: ' .. tostring(result))
            TEST_add_result = nil
        end
    end

    -- Test 3: RPC with callback back to MAIN
    print('\n[Test 3] RPC multiply_and_callback(12, 34) from MAIN to COMPUTE')
    do
        local ok, product, reversed = xthread.rpc(COMPUTE_THREAD_ID, 'multiply_and_callback', 12, 34)
        if ok then
            print('[MAIN] RPC result: 12 * 34 = ' .. product)
            print('[MAIN] Reversed product from MAIN: ' .. reversed)
            TEST_multiply_result = product
            TEST_callback_result = reversed
        else
            print('[MAIN] RPC failed: ' .. tostring(product))
            TEST_multiply_result = nil
        end
    end

    -- Check and print results
    local all_ok = check_results()
    local shutdown_ok = shutdown_compute_thread()

    -- Tell C to exit
    print('[MAIN] All tests completed, requesting exit...')
    xthread.stop((all_ok and shutdown_ok) and 0 or 1)
end

-- Check test results
function check_results()
    print('\n===== Test Results =====')
    local all_ok = true

    if TEST_add_result == 123 + 456 then
        print('✓ Test 1 (RPC add) PASSED, result = ' .. TEST_add_result)
    else
        print('✗ Test 1 (RPC add) FAILED, expected 579, got ' .. tostring(TEST_add_result))
        all_ok = false
    end

    if TEST_multiply_result == 12 * 34 then
        print('✓ Test 2 (RPC multiply) PASSED, result = ' .. TEST_multiply_result)
    else
        print('✗ Test 2 (RPC multiply) FAILED, expected 408, got ' .. tostring(TEST_multiply_result))
        all_ok = false
    end

    if TEST_callback_result == '804' then
        print('✓ Test 3 (Callback to MAIN) PASSED, reversed = ' .. TEST_callback_result)
    else
        print('✗ Test 3 (Callback to MAIN) FAILED, expected "804", got "' .. tostring(TEST_callback_result) .. '"')
        all_ok = false
    end

    print('\n' .. (all_ok and '✅ ALL TESTS PASSED!' or '❌ SOME TESTS FAILED'))
    return all_ok
end

-- -----------------------------------------------------------------------------
-- Lifecycle callbacks for main thread (following same pattern as dynamic threads)
-- -----------------------------------------------------------------------------

local function __init()
    print('[MAIN] __init: thread starting')

    -- Create compute thread dynamically from Lua
    -- This creates a new OS thread with its own independent Lua state
    -- The script will be loaded and executed in the new thread's own Lua state
    print('[MAIN] Creating compute thread dynamically via xthread.create_thread...')
    local ok, err = xthread.create_thread(COMPUTE_THREAD_ID, 'dynamic-compute', 'demo/xlua_thread.lua')

    if not ok then
        error('[MAIN] Failed to create compute thread: ' .. tostring(err))
    end
    compute_thread_running = true
    print('[MAIN] Compute thread created successfully, waiting for it to initialize...')

    -- Launch once; xthread.rpc will yield and C will resume it on reply.
    _test_coroutine = coroutine.create(run_tests)
    local ok, err = coroutine.resume(_test_coroutine)
    if not ok then
        io.stderr:write('[MAIN] test coroutine error: ' .. tostring(err) .. '\n')
        shutdown_compute_thread()
        xthread.stop(1)
    end
end

local function __update()
end

local function __uninit()
    shutdown_compute_thread()
    print('[MAIN] __uninit: thread shutting down')
end

-- -----------------------------------------------------------------------------
-- Return the definition table following the same convention as xlua_thread.lua
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
