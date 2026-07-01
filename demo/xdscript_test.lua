-- demo/xdscript_test.lua - regression tests for scripts/core/share/xdscript.lua
-- Run via:  ./bin/xnet demo/xdscript_test.lua
--
-- Covers:
--   1. call() on a module that fails to load -> nil (logged)
--   2. call() on a missing func name -> nil (logged)
--   3. call() success: args forwarded, return values forwarded, true returned
--   4. lazy load + cache: repeated call on the same module does not re-read disk
--   5. cache is keyed by module_path, shared across different func names
--   6. broken designer script errors are caught by pcall -> false (logged)
--   7. invalidate() forces a fresh disk read on the next call
--   8. reset() drops the entire cache
--   9. reload model: re-dofile'ing xdscript.lua itself reuses the SAME
--      singleton but clears the script cache

local xdscript = dofile('scripts/core/share/xdscript.lua')

local fails = 0
local function check(ok, msg)
    if not ok then
        fails = fails + 1
        io.stderr:write('FAIL: ' .. tostring(msg) .. '\n')
    else
        print('PASS: ' .. tostring(msg))
    end
end

local FIXTURE = 'demo/fixtures/xdscript_fixture.lua'
local MISSING_FIXTURE = 'demo/fixtures/xdscript_does_not_exist.lua'

_G.__XDSCRIPT_FIXTURE_LOADS = 0

-- ── Test 1: module fails to load ────────────────────────────────────────────
do
    local ret = xdscript.call(MISSING_FIXTURE, 'on_enter')
    check(ret == nil, 'call() on a module that fails to load returns nil')
end

-- ── Test 2: missing func name ────────────────────────────────────────────────
do
    local ret = xdscript.call(FIXTURE, 'on_does_not_exist')
    check(ret == nil, 'call() with a missing func name returns nil')
    check(_G.__XDSCRIPT_FIXTURE_LOADS == 1, 'module was still loaded once to check for the func')
end

-- ── Test 3: success, args + return values forwarded ─────────────────────────
do
    local ok, a, b, c = xdscript.call(FIXTURE, 'on_enter', { player = 'p1' }, { reward = 42 })
    check(ok == true, 'call() on a valid func returns true')
    check(a == 'entered' and b == 'p1' and c == 42,
          'call() forwards args in and return values out')
    check(_G.__XDSCRIPT_FIXTURE_LOADS == 1, 'module cached from test 2, not re-read')
end

-- ── Test 4: cache hit on repeated call ───────────────────────────────────────
do
    local ok = xdscript.call(FIXTURE, 'on_enter', { player = 'p2' }, {})
    check(ok == true, 'second call on same module succeeds')
    check(_G.__XDSCRIPT_FIXTURE_LOADS == 1, 'cached module NOT re-read from disk on second call')
end

-- ── Test 5: cache shared across different func names, same module ──────────
do
    local ok, a = xdscript.call(FIXTURE, 'on_leave', { player = 'p3' })
    check(ok == true and a == 'left', 'calling a different func on an already-cached module works')
    check(_G.__XDSCRIPT_FIXTURE_LOADS == 1,
          'module cache is shared across different func names for the same module_path')
end

-- ── Test 6: broken designer script is isolated ──────────────────────────────
do
    local ret = xdscript.call(FIXTURE, 'on_broken')
    check(ret == false, 'broken designer script error is caught and returns false, not raised')
    check(_G.__XDSCRIPT_FIXTURE_LOADS == 1,
          'calling the broken func still hits the same cached module (no extra load)')
end

-- ── Test 7: invalidate() forces a fresh disk read ───────────────────────────
do
    xdscript.invalidate(FIXTURE)
    local ok = xdscript.call(FIXTURE, 'on_enter', { player = 'p4' }, {})
    check(ok == true, 'call after invalidate succeeds')
    check(_G.__XDSCRIPT_FIXTURE_LOADS == 2,
          'invalidate forces the module to be re-read from disk on next call')
end

-- ── Test 8: reset() drops the entire cache ──────────────────────────────────
do
    local loads_before_reset = _G.__XDSCRIPT_FIXTURE_LOADS

    xdscript.reset()

    local ok = xdscript.call(FIXTURE, 'on_enter', { player = 'p5' }, {})
    check(ok == true, 'call after reset() succeeds')
    check(_G.__XDSCRIPT_FIXTURE_LOADS == loads_before_reset + 1,
          'reset() drops the whole cache, forcing a fresh disk read on next call')
end

-- ── Test 9: reload model -- re-dofile clears cache ──────────────────────────
do
    local loads_before_reload = _G.__XDSCRIPT_FIXTURE_LOADS

    -- Simulate the reload model: xdscript.lua gets re-dofile'd as part of a
    -- worker reload (xrouter's model: re-running the worker script re-runs
    -- every dofile reachable from it).
    local xdscript2 = dofile('scripts/core/share/xdscript.lua')
    check(xdscript2 == xdscript, 'xdscript is a singleton across re-dofile (same table identity)')

    local ok = xdscript.call(FIXTURE, 'on_enter', { player = 'p6' }, {})
    check(ok == true, 'call still works right after a re-dofile reload')
    check(_G.__XDSCRIPT_FIXTURE_LOADS == loads_before_reload + 1,
          'script cache is cleared on re-dofile reload, forcing a fresh disk read')
end

print(string.format('--- xdscript tests: %d failures ---', fails))

return {
    __init = function()
        if fails > 0 then
            io.stderr:write('TEST SUITE FAILED\n')
            os.exit(1)
        end
        xthread.stop(0)
    end,
}
