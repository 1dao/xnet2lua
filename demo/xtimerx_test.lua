-- demo/xtimerx_test.lua - end-to-end tests for demo/xtimerx.lua
-- Run via:  ./demo/xnet demo/xtimerx_test.lua
--
-- Covers:
--   1. timer_every fires repeatedly
--   2. timer_once fires exactly once and is auto-cleaned
--   3. Re-declare with same params is idempotent (no replacement)
--   4. Re-declare with changed interval immediately replaces old timer
--   5. Module reload via __reload + require: callbacks resolve to new fns
--   6. Module reload that DROPS a timer: old timer self-deletes lazily
--      (this is the test that exercises xtimer.c firing-time-safe destroy)
--   7. timer_cancel removes a timer
--   8. cancel_module wipes all timers belonging to a module
--   9. __uninit clears all state
--
-- The test drives time forward by scheduling phase callbacks via xtimer.delay
-- and exits cleanly via xthread.stop.

local xtimer  = require('xtimer')
local xtimerx = dofile('demo/xtimerx.lua')

-- ── Test infra ──────────────────────────────────────────────────────────────

local fails = 0
local checks = 0
local function check(ok, msg)
    checks = checks + 1
    if not ok then
        fails = fails + 1
        io.stderr:write('FAIL: ' .. tostring(msg) .. '\n')
    else
        print('PASS: ' .. tostring(msg))
    end
end

-- Stand-in for require()'d business modules. Each "module" is a plain table
-- registered into package.loaded under a name; xtimerx.resolve_fn reads from
-- there to find callback functions.
local function install_module(name, mod)
    package.loaded[name] = mod
    return mod
end

local function uninstall_module(name)
    package.loaded[name] = nil
end

-- Internal-state introspection: xtimerx stores its bookkeeping in
-- _G.__XTIMERX so reload survives module-table identity churn. We poke at
-- it directly to assert "the rec was actually deleted", not just that
-- callbacks stopped firing.
local function get_rec(module_name, timer_name)
    local XT = rawget(_G, '__XTIMERX')
    if not XT or not XT.timers then return nil end
    return XT.timers[module_name .. '::' .. timer_name]
end

local function count_module_timers(module_name)
    local XT = rawget(_G, '__XTIMERX')
    if not XT or not XT.timers then return 0 end
    local n = 0
    for _, rec in pairs(XT.timers) do
        if rec.module_name == module_name and not rec.deleted then
            n = n + 1
        end
    end
    return n
end

local function total_live_timers()
    local XT = rawget(_G, '__XTIMERX')
    if not XT or not XT.timers then return 0 end
    local n = 0
    for _, rec in pairs(XT.timers) do
        if not rec.deleted then n = n + 1 end
    end
    return n
end

-- ── Build module v1 ─────────────────────────────────────────────────────────

local function build_module_v1(counters)
    local M = xtimerx('testmod')

    function M:on_tick()    counters.tick    = counters.tick    + 1 end
    function M:on_burst()   counters.burst   = counters.burst   + 1 end
    function M:on_oneshot() counters.oneshot = counters.oneshot + 1 end
    function M:on_dropme()  counters.dropme  = counters.dropme  + 1 end
    function M:on_mut()     counters.mut     = counters.mut     + 1 end

    M.timer_every('tick',     40, 'on_tick')
    M.timer_every('burst',    35, 'on_burst', 3)
    M.timer_once ('oneshot',  60, 'on_oneshot')
    M.timer_every('dropme',   45, 'on_dropme')   -- v2 will not redeclare this
    M.timer_every('mut',      50, 'on_mut')      -- v2 redeclares with diff params

    return M
end

-- v2 keeps 'tick' identical (no-op re-declare path), changes 'burst' AND 'mut'
-- params (replace path), drops 'oneshot' and 'dropme' (lazy stale cleanup).
-- Note: on_mut deliberately NOT defined here so that if the OLD 'mut' timer
-- somehow survived the replace and tried to fire, resolve_fn would fail and
-- counters.mut would not increment regardless.
local function build_module_v2(counters)
    local M = xtimerx('testmod')

    function M:on_tick()        counters.tick        = counters.tick        + 1 end
    function M:on_tick_v2()     counters.tick_v2     = counters.tick_v2     + 1 end
    function M:on_burst_v2()    counters.burst_v2    = counters.burst_v2    + 1 end
    function M:on_mut_v2()      counters.mut_v2      = counters.mut_v2      + 1 end

    -- 'tick' kept identical params so that re-declare is a no-op (keep ticking)
    M.timer_every('tick',  40, 'on_tick')

    -- 'burst' params changed: function name + interval. Old timer must be
    -- cancelled and replaced.
    M.timer_every('burst', 25, 'on_burst_v2', 3)

    -- 'mut' is alive (infinite repeat) at reload time → exercises the replace
    -- path against an actively-firing timer, not a finished one.
    M.timer_every('mut',   30, 'on_mut_v2')

    -- 'dropme' and 'oneshot' deliberately not redeclared.

    return M
end

-- Counters captured by closures; we reset between phases as needed.
local counters = {
    tick = 0, burst = 0, oneshot = 0, dropme = 0, mut = 0,
    tick_v2 = 0, burst_v2 = 0, mut_v2 = 0,
}

-- ── Phase scheduling ────────────────────────────────────────────────────────

local function phase1_setup()
    print('\n=== PHASE 1: install v1, observe initial firing ===')
    install_module('testmod', {})  -- empty stub; build_module_v1 will populate
    -- v1's M is a NEW table returned by xtimerx; we attach methods AND store
    -- the table back into package.loaded so resolve_fn can find on_*.
    local mod = build_module_v1(counters)
    install_module('testmod', mod)
end

local function phase1_check()
    print('\n=== PHASE 1 CHECK (after ~150ms) ===')
    -- After 150ms we expect:
    --   tick (40ms repeat): ~3 fires
    --   burst (35ms, 3 reps): exactly 3 fires
    --   oneshot (60ms): exactly 1 fire
    --   dropme (45ms repeat): ~3 fires
    --   mut (50ms repeat): ~2 fires
    check(counters.tick    >= 2, ('tick fired at least 2x (got %d)'):format(counters.tick))
    check(counters.burst   == 3, ('burst fired exactly 3x (got %d)'):format(counters.burst))
    check(counters.oneshot == 1, ('oneshot fired exactly 1x (got %d)'):format(counters.oneshot))
    check(counters.dropme  >= 2, ('dropme fired at least 2x (got %d)'):format(counters.dropme))
    check(counters.mut     >= 2, ('mut fired at least 2x (got %d)'):format(counters.mut))

    -- Bookkeeping: finite-repeat timers that have completed (burst, oneshot)
    -- must be removed from XT.timers via finish_rec; the three infinite-repeat
    -- timers (tick, dropme, mut) must still be there.
    check(get_rec('testmod', 'burst')   == nil, 'finished burst rec removed from XT.timers')
    check(get_rec('testmod', 'oneshot') == nil, 'finished oneshot rec removed from XT.timers')
    check(get_rec('testmod', 'tick')    ~= nil, 'live tick rec still in XT.timers')
    check(get_rec('testmod', 'dropme')  ~= nil, 'live dropme rec still in XT.timers')
    check(get_rec('testmod', 'mut')     ~= nil, 'live mut rec still in XT.timers')
    check(count_module_timers('testmod') == 3,
          ('exactly 3 live testmod timers after phase 1 (got %d)')
              :format(count_module_timers('testmod')))
end

local function phase2_reload()
    print('\n=== PHASE 2: reload to v2 (drop dropme/oneshot, change burst+mut) ===')

    -- Snapshot baselines so we can measure deltas after reload.
    counters._tick_at_reload   = counters.tick
    counters._dropme_at_reload = counters.dropme
    counters._mut_at_reload    = counters.mut

    -- Capture the rec tokens BEFORE reload so we can prove which entries were
    -- replaced (token changed) vs kept (token unchanged) after re-declare.
    counters._tick_token_before = (get_rec('testmod', 'tick') or {}).token
    counters._mut_token_before  = (get_rec('testmod', 'mut')  or {}).token

    -- Standard reload protocol per xtimerx docs:
    xtimerx.__reload()                -- 1. clear callback cache
    uninstall_module('testmod')       -- 2. drop the module
    local mod = build_module_v2(counters)
    install_module('testmod', mod)    --    re-load with v2 (bumps generation)

    -- Same-params re-declare for 'tick' must be a no-op: same rec, same token.
    local tick_rec = get_rec('testmod', 'tick')
    check(tick_rec and tick_rec.token == counters._tick_token_before,
          'same-params re-declare of tick is a no-op (token unchanged)')

    -- Changed-params re-declare for 'mut' must replace the rec: new token.
    local mut_rec = get_rec('testmod', 'mut')
    check(mut_rec and mut_rec.token ~= counters._mut_token_before,
          ('changed-params re-declare of mut replaced the rec '
              .. '(old=%s, new=%s)'):format(
              tostring(counters._mut_token_before),
              tostring(mut_rec and mut_rec.token)))
end

local function phase2_check()
    print('\n=== PHASE 2 CHECK (after ~250ms more) ===')

    -- 'tick' (40ms) was kept identical → keeps firing across reload.
    check(counters.tick > counters._tick_at_reload,
          ('tick keeps firing after reload (delta=%d)')
              :format(counters.tick - counters._tick_at_reload))

    -- 'burst_v2' (25ms, 3 reps) is the NEW handler. It is a brand-new key 'burst'
    -- with changed interval, so old burst timer was destroyed and a new one
    -- created. After 250ms with 25ms interval × 3 reps it fires exactly 3 times.
    check(counters.burst_v2 == 3,
          ('burst_v2 fired exactly 3x after replacement (got %d)')
              :format(counters.burst_v2))

    -- 'mut' was infinite + alive at reload, params changed → replace path.
    -- After reload, the OLD on_mut handler must NEVER fire again, only on_mut_v2.
    local extra_mut = counters.mut - counters._mut_at_reload
    check(extra_mut == 0,
          ('OLD on_mut never called after replace (extra=%d)'):format(extra_mut))
    check(counters.mut_v2 >= 3,
          ('mut_v2 (30ms repeat) fires repeatedly after reload (got %d)')
              :format(counters.mut_v2))

    -- 'dropme' was not redeclared in v2. The old C-side timer is still in the
    -- heap, it WILL fire one more time; the trampoline will detect the stale
    -- generation and call t:del() from INSIDE the firing callback. xtimer.c
    -- must handle that safely (firing flag → cancelled → released after).
    -- Net effect: dropme should fire AT MOST once more, then stop forever.
    local extra_dropme = counters.dropme - counters._dropme_at_reload
    check(extra_dropme <= 1,
          ('dropme fires at most once after drop (extra=%d)'):format(extra_dropme))

    -- 'oneshot' was already done in phase 1 — should still be exactly 1.
    check(counters.oneshot == 1, 'oneshot still 1 after reload')

    -- After lazy cleanup: dropme rec must have been removed by the trampoline.
    check(get_rec('testmod', 'dropme') == nil,
          'lazy stale-cleanup removed dropme rec from XT.timers')

    -- Live testmod timers at this point: tick + mut (burst_v2 done, oneshot
    -- done, dropme deleted). Exactly 2.
    check(count_module_timers('testmod') == 2,
          ('exactly 2 live testmod timers after phase 2 (got %d)')
              :format(count_module_timers('testmod')))
end

local function phase3_cancel()
    print('\n=== PHASE 3: timer_cancel + cancel_module ===')

    counters._tick_before_cancel = counters.tick
    counters._mut_v2_before_cancel = counters.mut_v2

    local mod = package.loaded['testmod']

    -- Boundary: cancelling an unregistered name returns false.
    check(mod.timer_cancel('does_not_exist') == false,
          'timer_cancel on unknown name returns false')

    -- Cancel just the 'tick' timer.
    local cancelled = mod.timer_cancel('tick')
    check(cancelled == true, 'timer_cancel returned true on first call')

    -- Idempotent: cancelling again returns false.
    check(mod.timer_cancel('tick') == false,
          'timer_cancel on already-cancelled returns false')

    -- After tick cancel, the rec must be gone from bookkeeping.
    check(get_rec('testmod', 'tick') == nil,
          'cancelled tick rec removed from XT.timers')

    -- Live testmod timers now: only 'mut' remains.
    check(count_module_timers('testmod') == 1,
          ('exactly 1 live testmod timer after cancelling tick (got %d)')
              :format(count_module_timers('testmod')))

    -- cancel_module must return the EXACT number of timers it cancelled (1).
    local n = xtimerx.cancel_module('testmod')
    check(n == 1,
          ('cancel_module returned exactly 1 (the remaining mut, got %s)')
              :format(tostring(n)))

    -- Module-wide cancel: all testmod recs gone.
    check(count_module_timers('testmod') == 0,
          'no testmod recs remain after cancel_module')

    -- Re-running cancel_module on an empty module returns 0.
    check(xtimerx.cancel_module('testmod') == 0,
          'cancel_module on emptied module returns 0')
end

local function phase3_check()
    print('\n=== PHASE 3 CHECK (after ~150ms more) ===')

    local extra_tick = counters.tick - counters._tick_before_cancel
    -- Allow at most one stale fire (a tick already in-flight at cancel time).
    check(extra_tick <= 1,
          ('tick stops firing after cancel (extra=%d)'):format(extra_tick))

    local extra_mut_v2 = counters.mut_v2 - counters._mut_v2_before_cancel
    check(extra_mut_v2 <= 1,
          ('mut_v2 stops firing after cancel_module (extra=%d)')
              :format(extra_mut_v2))
end

local function phase4_uninit()
    print('\n=== PHASE 4: __uninit clears state ===')

    xtimerx.__uninit()

    -- After __uninit there must be ZERO live timers in xtimerx bookkeeping
    -- (including any leftover from prior phases).
    check(total_live_timers() == 0,
          ('__uninit leaves no live timers (got %d)'):format(total_live_timers()))

    -- Re-installing a module after __uninit must work cleanly.
    counters.fresh = 0
    local fresh_mod = xtimerx('freshmod')
    function fresh_mod:on_fresh() counters.fresh = counters.fresh + 1 end
    fresh_mod.timer_once('one', 30, 'on_fresh')
    install_module('freshmod', fresh_mod)

    check(get_rec('freshmod', 'one') ~= nil,
          'fresh module rec registered after __uninit')
end

local function phase4_check()
    print('\n=== PHASE 4 CHECK ===')
    check(counters.fresh == 1,
          ('fresh module timer fired after __uninit + new module (got %d)')
              :format(counters.fresh))
end

-- ── Final ──────────────────────────────────────────────────────────────────

local function finish()
    print(('\n--- xtimerx tests: %d/%d passed, %d failed ---')
              :format(checks - fails, checks, fails))
    if fails > 0 then
        io.stderr:write('TEST SUITE FAILED\n')
        os.exit(1)
    end
    xthread.stop(0)
end

-- ── Lifecycle ──────────────────────────────────────────────────────────────

local function __init()
    print('[TEST_XTIMERX] init')

    -- Drive the entire test scenario via a tree of one-shot delays so phases
    -- run on the auto-driven timer loop. xnet doesn't need to be brought up:
    -- the main runner auto-inits xpoll if xtimer is alive and xnet isn't.
    phase1_setup()

    xtimer.delay(150, function()
        phase1_check()
        phase2_reload()
    end)

    xtimer.delay(400, function()
        phase2_check()
        phase3_cancel()
    end)

    xtimer.delay(550, function()
        phase3_check()
        phase4_uninit()
    end)

    xtimer.delay(620, function()
        phase4_check()
        finish()
    end)
end

return {
    __init    = __init,
    __tick_ms = 10,
}
