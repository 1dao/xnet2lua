-- xagent/test_subprocess.lua — exercise the thread-offloaded subprocess pool.
-- Covers output/exit-code handling, the timeout watchdog, argv quoting, and the
-- two things the pool exists for: concurrency, and a UI lane that a human can
-- hold open without blocking agent tools.
-- Run: bin/xnet scripts/xagent/test_subprocess.lua
--
-- The main thread wires xrouter.handle as __thread_handle so the workers' RPC
-- replies route back here.

package.path = 'scripts/?.lua;' .. package.path
local router = dofile('scripts/core/share/xrouter.lua')
local xtimer = require('xtimer')
local subprocess = require('xagent.proc.subprocess')

local IS_WIN = (package.config:sub(1, 1) == '\\')
local function out(s) io.write(s); io.flush() end
local function trim(s) return (tostring(s or ''):gsub('%s+$', '')) end

-- A command that takes about `secs` seconds without needing an external binary.
local function slow_cmd(secs)
    if IS_WIN then return 'ping -n ' .. (secs + 1) .. ' 127.0.0.1' end
    return 'sleep ' .. secs
end

-- NOTE ON WAITING. The concurrency tests below are written as continuations —
-- the coroutine that finishes LAST calls the next stage — rather than polling a
-- "sleep". A timer-based sleep is not available to us: xtimer's wheel is not
-- pumped for a headless script that only has __init, so an xtimer.delay created
-- inside a coroutine never fires and the test would hang instead of failing.
local function run_tests()
    local fails = 0
    local function check(name, cond, detail)
        if cond then out('PASS ' .. name .. '\n')
        else fails = fails + 1; out('FAIL ' .. name .. ' :: ' .. tostring(detail) .. '\n') end
    end

    -- 0) the workers answer at all
    local sok, serr = subprocess.selftest()
    check('pool selftest', sok, tostring(serr))
    check('pool has >1 worker', subprocess.size() > 1, 'size=' .. tostring(subprocess.size()))

    -- 1) simple echo → stdout + exit 0
    local r1 = subprocess.run({ cmd = 'echo hello-from-subprocess' })
    check('echo ok', r1.ok and r1.exit_code == 0, 'ok=' .. tostring(r1.ok) .. ' exit=' .. tostring(r1.exit_code))
    check('echo stdout', r1.stdout:find('hello-from-subprocess', 1, true) ~= nil, trim(r1.stdout))

    -- 2) nonzero exit + stderr merged: a missing command makes the shell print
    --    an error to STDERR; merge_stderr must fold it into stdout.
    local r2 = subprocess.run({ cmd = 'this_command_does_not_exist_xyz123' })
    check('missing cmd nonzero exit', r2.exit_code ~= 0, 'exit=' .. tostring(r2.exit_code))
    check('stderr merged into stdout', #trim(r2.stdout) > 0, 'stdout=' .. trim(r2.stdout))

    -- 3) cwd honored
    local pwd = IS_WIN and 'cd' or 'pwd'
    local r3 = subprocess.run({ cmd = pwd, cwd = 'scripts/xagent' })
    check('cwd honored', trim(r3.stdout):lower():find('xagent', 1, true) ~= nil, trim(r3.stdout))

    -- 4) timeout: a long command must be killed at the soft timeout and come
    --    back as a real result (exit 124), not a transport "rpc timeout".
    local t0 = xtimer.now_ms()
    local r4 = subprocess.run({ cmd = slow_cmd(30), timeout_ms = 3000 })
    local elapsed = (xtimer.now_ms() - t0) / 1000
    check('timeout returns a result', r4.ok, 'ok=' .. tostring(r4.ok) .. ' err=' .. tostring(r4.err))
    check('timeout exit 124', r4.exit_code == 124, 'exit=' .. tostring(r4.exit_code))
    check('timeout killed promptly', elapsed < 12, 'elapsed=' .. elapsed .. 's')
    check('timeout noted in output', r4.stdout:find('timed out', 1, true) ~= nil, trim(r4.stdout))

    -- 5) the worker survives a timeout (it used to wedge for the whole session).
    local r5 = subprocess.run({ cmd = 'echo still-alive' })
    check('worker survives timeout', r5.ok and r5.stdout:find('still-alive', 1, true) ~= nil,
        'ok=' .. tostring(r5.ok) .. ' out=' .. trim(r5.stdout))

    -- 6) argv is quoted, not interpolated. The old code wrapped each argument in
    --    double quotes, which a POSIX shell happily looks inside: $(...) ran.
    local r6 = subprocess.run({ argv = { 'echo', 'a$(echo INJECTED)b' } })
    check('argv reaches child literally',
        r6.stdout:find('a$(echo INJECTED)b', 1, true) ~= nil, trim(r6.stdout))
    check('argv did not substitute',
        r6.stdout:find('aINJECTEDb', 1, true) == nil, trim(r6.stdout))

    -- 7) a metacharacter in an argument must not chain a second command.
    local r7 = subprocess.run({ argv = { 'echo', 'x&echo CHAINED' } })
    check('argv & is not a separator',
        r7.exit_code == 0 and r7.stdout:find('x&echo CHAINED', 1, true) ~= nil, trim(r7.stdout))

    -- 7b) stdin is the null device, so a command that reads it sees EOF and
    --     exits instead of waiting forever for input nobody will type. The
    --     generous timeout is a safety net: the assertion is that we came back
    --     fast and were NOT killed.
    local t7 = xtimer.now_ms()
    local r7b = subprocess.run({ cmd = IS_WIN and 'sort' or 'cat', timeout_ms = 15000 })
    local stdin_ms = xtimer.now_ms() - t7
    check('stdin reader gets EOF, not a hang',
        not r7b.timed_out and stdin_ms < 3000,
        string.format('timed_out=%s in %dms', tostring(r7b.timed_out), stdin_ms))

    local function report()
        out(string.format('\n[subprocess] %s (%d failures)\n',
            fails == 0 and 'ALL PASS' or 'FAILED', fails))
        xthread.stop(fails == 0 and 0 or 1)
    end

    -- 9) the UI lane is a worker of its own: a dialog-length command on it must
    --    not delay a pool command queued behind it. Both RPCs are in flight
    --    before either can answer, so finish ORDER is the assertion.
    local function ui_lane_test()
        local order = {}
        local function note(who)
            order[#order + 1] = who
            if #order < 2 then return end
            check('ui lane does not block the pool', order[1] == 'pool',
                'finish order: ' .. table.concat(order, ','))
            report()
        end
        -- The UI command is dispatched first and holds its worker for ~3s.
        assert(coroutine.resume(coroutine.create(function()
            subprocess.run_ui({ cmd = slow_cmd(3), timeout_ms = 20000 })
            note('ui')
        end)))
        assert(coroutine.resume(coroutine.create(function()
            subprocess.run({ cmd = 'echo quick' })
            note('pool')
        end)))
    end

    -- 8) THE POINT OF THE POOL: four ~2s commands, launched together, must
    --    finish in about 2s, not 8s. One worker would serialise them.
    local n, done = 4, 0
    local c0 = xtimer.now_ms()
    for _ = 1, n do
        local co = coroutine.create(function()
            subprocess.run({ cmd = slow_cmd(2), timeout_ms = 20000 })
            done = done + 1
            if done < n then return end
            local par = xtimer.now_ms() - c0
            check('pool runs commands in parallel', par < 5000,
                string.format('%d commands took %dms (serial would be ~%dms)',
                    n, par, n * 2000))
            ui_lane_test()
        end)
        local ok, err = coroutine.resume(co)
        if not ok then check('concurrent launch', false, tostring(err)) end
    end
end

local function __init()
    local ok, err = subprocess.setup({ ui_lane = true })
    if not ok then out('setup failed: ' .. tostring(err) .. '\n'); xthread.stop(2); return end
    local co = coroutine.create(run_tests)
    local rok, rerr = coroutine.resume(co)
    if not rok then io.stderr:write('test coroutine error: ' .. tostring(rerr) .. '\n'); xthread.stop(1) end
end

return {
    __thread_handle = router.handle,
    __init = __init,
    __uninit = function()
        -- Join the process workers while this state is still alive (see xproc.shutdown).
        subprocess.shutdown()
    end,
}
