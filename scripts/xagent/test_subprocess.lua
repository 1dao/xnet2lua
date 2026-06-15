-- xagent/test_subprocess.lua — exercise the thread-offloaded subprocess runner.
-- Runs a few commands through the worker and checks output/exit-code handling.
-- Run: bin/xnet scripts/xagent/test_subprocess.lua
--
-- The main thread wires xrouter.handle as __thread_handle so the worker's RPC
-- replies route back here.

package.path = 'scripts/?.lua;' .. package.path
local router = dofile('scripts/core/share/xrouter.lua')
local subprocess = require('xagent.proc.subprocess')

local IS_WIN = (package.config:sub(1, 1) == '\\')
local function out(s) io.write(s); io.flush() end
local function trim(s) return (tostring(s or ''):gsub('%s+$', '')) end

local function run_tests()
    local fails = 0
    local function check(name, cond, detail)
        if cond then out('PASS ' .. name .. '\n')
        else fails = fails + 1; out('FAIL ' .. name .. ' :: ' .. tostring(detail) .. '\n') end
    end

    -- 1) simple echo → stdout + exit 0
    local r1 = subprocess.run({ cmd = 'echo hello-from-subprocess' })
    check('echo ok', r1.ok and r1.exit_code == 0, 'ok=' .. tostring(r1.ok) .. ' exit=' .. tostring(r1.exit_code))
    check('echo stdout', r1.stdout:find('hello-from-subprocess', 1, true) ~= nil, trim(r1.stdout))

    -- 2) nonzero exit + stderr merged: a missing command makes the shell print
    --    an error to STDERR; our 2>&1 merge must capture it into stdout.
    local r2 = subprocess.run({ cmd = 'this_command_does_not_exist_xyz123' })
    check('missing cmd nonzero exit', r2.exit_code ~= 0, 'exit=' .. tostring(r2.exit_code))
    check('stderr merged into stdout', #trim(r2.stdout) > 0, 'stdout=' .. trim(r2.stdout))

    -- 3) cwd honored
    local pwd = IS_WIN and 'cd' or 'pwd'
    local r3 = subprocess.run({ cmd = pwd, cwd = 'scripts/xagent' })
    check('cwd honored', trim(r3.stdout):lower():find('xagent', 1, true) ~= nil, trim(r3.stdout))

    out(string.format('\n[subprocess] %s (%d failures)\n', fails == 0 and 'ALL PASS' or 'FAILED', fails))
    xthread.stop(fails == 0 and 0 or 1)
end

local function __init()
    local ok, err = subprocess.setup()
    if not ok then out('setup failed: ' .. tostring(err) .. '\n'); xthread.stop(2); return end
    local co = coroutine.create(run_tests)
    local rok, rerr = coroutine.resume(co)
    if not rok then io.stderr:write('test coroutine error: ' .. tostring(rerr) .. '\n'); xthread.stop(1) end
end

return {
    __thread_handle = router.handle,
    __init = __init,
    __uninit = function() end,
}
