-- timer_coroutine_test.lua — a timer armed inside a coroutine must outlive it.
--
--   Run: bin/xnet tests/lua/timer_coroutine_test.lua      (bin\xnet.exe on Windows)
--   Exit code 0 = all pass. Most telling under an ASAN build.
--
-- REGRESSION. xtimer_create_lua stored the calling lua_State, so a timer armed
-- from a coroutine ran its callback on that coroutine's state. Two ways that
-- broke, both covered here:
--
--   * The coroutine finished and was collected before the timer fired: the
--     callback then ran on freed memory -- a delayed segfault with nothing in
--     the log. Any xhttp_client request made from a request coroutine arms
--     such a timer.
--
--   * The coroutine was suspended in a yield when the timer fired, which is
--     exactly how xthread.rpc waits out its timeout: the callback was pcall'd
--     on a yielded coroutine, which Lua does not allow.
--
-- Timers now run their callbacks on the thread's main coroutine -- same
-- thread, same VM, a stack that lives as long as the thread does.

local router = dofile('scripts/core/share/xrouter.lua')

local fails, checks = 0, 0
local function out(s) io.write(s); io.flush() end
local function check(name, cond, detail)
    checks = checks + 1
    if cond then
        out('PASS ' .. name .. '\n')
    else
        fails = fails + 1
        out('FAIL ' .. name .. ' :: ' .. tostring(detail) .. '\n')
    end
end

local function finish()
    out(string.format('\n[timer-coroutine] %s (%d checks, %d failure(s))\n',
        fails == 0 and 'ALL PASS' or 'FAILED', checks, fails))
    xthread.stop(fails == 0 and 0 or 1)
end

-- Churn the allocator so freed coroutine memory is handed out again before
-- the timer fires; without this a dangling state can look intact by luck.
local function churn()
    collectgarbage('collect')
    collectgarbage('collect')
    local junk = {}
    for i = 1, 2000 do junk[i] = coroutine.create(function() end) end
    for i = 1, 2000 do junk[i] = string.rep('x', 64) .. i end
    junk = nil
    collectgarbage('collect')
end

-- Case 1: the arming coroutine is dead and collected when the timer fires.
local function run_dead(after)
    local fired, weak = false, setmetatable({}, { __mode = 'v' })
    local co = coroutine.create(function()
        xtimer.add(50, function() fired = true end, 1)
    end)
    weak[1] = co
    local ok, err = coroutine.resume(co)
    check('arming a timer inside a coroutine', ok, err)
    co = nil
    churn()
    check('the arming coroutine was collected', weak[1] == nil,
        'still reachable, so this case proves nothing')
    xtimer.add(200, function()
        check('timer fires after its coroutine is gone', fired, 'never fired')
        after()
    end, 1)
end

-- Case 2: the timer resumes the coroutine that armed it and is still
-- suspended in a yield -- the rpc_wait timeout shape.
local function run_suspended(after)
    local got
    local co
    co = coroutine.create(function()
        xtimer.add(30, function()
            local ok, err = coroutine.resume(co, 'timeout')
            if not ok then got = 'resume failed: ' .. tostring(err) end
        end, 1)
        got = coroutine.yield()
    end)
    local ok, err = coroutine.resume(co)
    check('coroutine armed a timer and yielded', ok and coroutine.status(co) == 'suspended',
        tostring(err))
    xtimer.add(200, function()
        check('timer resumes the suspended coroutine that armed it',
            got == 'timeout' and coroutine.status(co) == 'dead', tostring(got))
        after()
    end, 1)
end

-- Case 3: a repeating timer keeps firing after its coroutine is gone, then
-- is cancelled from the main state.
local function run_repeat(after)
    local n, t = 0, nil
    local co = coroutine.create(function()
        t = xtimer.add(20, function() n = n + 1 end, -1)
    end)
    coroutine.resume(co)
    co = nil
    churn()
    xtimer.add(150, function()
        t:del()
        local seen = n
        check('repeating timer kept firing after its coroutine died', seen >= 3,
            string.format('%d tick(s)', seen))
        xtimer.add(100, function()
            check('del() stops it', n == seen, string.format('%d -> %d', seen, n))
            after()
        end, 1)
    end, 1)
end

return {
    __thread_handle = router.handle,
    __init = function()
        xtimer.init(64)
        run_dead(function()
            run_suspended(function()
                run_repeat(finish)
            end)
        end)
        xtimer.add(10000, function()
            out('FAIL watchdog: the test did not finish within 10s\n')
            xthread.stop(1)
        end, 1)
    end,
}
