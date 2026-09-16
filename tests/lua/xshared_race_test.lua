-- xshared_race_test.lua — concurrent get-or-create on the shared registry.
--
--   Run: bin/xnet tests/lua/xshared_race_test.lua
--   Exit code 0 = all pass.
--
-- WHAT THIS IS GUARDING
-- xshared.create used to be MAIN-thread-at-boot only, and the registry was an
-- unlocked list: lookup, then prepend, with no critical section between them.
-- Two threads creating the same name would both look, both miss, both build, and
-- each would walk away holding a DIFFERENT dict — one of them unreachable and
-- leaked — which is exactly the "each thread sees only its own slice" bug this
-- module exists to prevent. Now find and create share one lock.
--
-- HOW IT PROVES THAT
-- WORKERS threads walk the same list of NAMES fresh names in the same order,
-- released from a wall-clock barrier so they are inside xshared.create at the
-- same moment. Then:
--   * every name must have exactly ONE creator, so the created counts summed
--     over all workers equal NAMES, and
--   * every worker's incr on every name must land on the same dict, so each
--     name's counter reads exactly WORKERS.
-- A forked registry breaks both at once: two creators for a name, and a counter
-- that is short by however many workers landed on the other copy.
--
-- This is verified to FAIL against a build whose lookup sits outside the lock.

local WORKERS = 6
local NAMES   = 400
local BASE_TID = 20
local WORKER_SCRIPT = 'tests/lua/xshared_race_worker.lua'
local BARRIER_MS = 250      -- head start, so every worker is spinning before go

local router = dofile('scripts/core/share/xrouter.lua')
local xtimer = require('xtimer')

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

-- Join every worker BEFORE stopping. Each worker's ThreadData lives in this
-- (main) Lua state, and the runner closes that state before it joins workers --
-- so stopping with workers still alive lets a worker's next update tick read
-- freed memory, a segfault on exit roughly one run in five. demo/xnet_main.lua
-- shuts its worker down the same way.
local started = 0
local function finish(code)
    for i = 1, started do xthread.shutdown_thread(BASE_TID + i - 1) end
    started = 0
    xthread.stop(code)
end

-- Name validation: module_function, lowercase. Enforced because with lazy
-- creation a typo silently forks the dict instead of failing.
local function check_names()
    local bad = { 'nounderscore', 'Bad_Name', '_leading', 'trailing_',
                  'ab', 'has space_x', 'dash-name_x', '' }
    for _, n in ipairs(bad) do
        local ok = pcall(xshared.create, n, 4096, 2)
        check("rejects bad name '" .. n .. "'", not ok, 'was accepted')
    end
    for _, n in ipairs({ 'test_ok', 'test_ok2', 'proc_scratch_seq', 'a_b' }) do
        local ok, d = pcall(xshared.create, n, 4096, 2)
        check("accepts '" .. n .. "'", ok and d ~= nil, 'was rejected')
    end
end

local function check_created_flag()
    local d1, c1 = xshared.create('test_flagcheck', 4096, 2)
    local d2, c2 = xshared.create('test_flagcheck', 4096, 2)
    check('first create reports created=true', c1 == true, tostring(c1))
    check('second create reports created=false', c2 == false, tostring(c2))
    check('both creates return a dict', d1 ~= nil and d2 ~= nil, 'nil dict')
    -- The same dict, not merely two equal handles: a write through one has to be
    -- visible through the other.
    d1:set('probe', 'v')
    check('the two handles address one dict', d2:get('probe') == 'v', tostring(d2:get('probe')))
end

-- Every racing name must hold exactly WORKERS increments. Short means the name
-- forked and some workers counted on a copy the registry no longer points at.
local function check_all_counters()
    local worst_name, worst_hits, missing = nil, nil, 0
    for k = 1, NAMES do
        local name = 'test_race' .. k
        local d = xshared.dict(name)
        local hits = d and d:get('hits') or nil
        if hits ~= WORKERS then
            missing = missing + 1
            if not worst_name then worst_name, worst_hits = name, hits end
        end
    end
    check('every worker landed on one dict per name', missing == 0,
        string.format('%d/%d names wrong, e.g. %s had hits=%s (expected %d)',
            missing, NAMES, tostring(worst_name), tostring(worst_hits), WORKERS))
end

local function run()
    check_names()
    check_created_flag()

    -- Fire every worker before waiting on any of them, then let the barrier
    -- inside them line up the actual create calls.
    local start_ms = xtimer.now_ms() + BARRIER_MS
    local done, total_created, first_err = 0, 0, nil

    for i = 1, WORKERS do
        local co = coroutine.create(function()
            local ok, mine, werr = xthread.rpc(BASE_TID + i - 1, 'race', 60000,
                                               start_ms, NAMES)
            if not ok then
                first_err = first_err or ('rpc failed: ' .. tostring(mine))
            else
                total_created = total_created + (tonumber(mine) or 0)
                if werr then first_err = first_err or werr end
            end
            done = done + 1
            if done < WORKERS then return end

            check('no worker reported an error', first_err == nil, first_err)
            check('each name had exactly one creator', total_created == NAMES,
                string.format('%d creates reported across %d names', total_created, NAMES))
            check_all_counters()

            out(string.format('\n[xshared-race] %s (%d checks, %d failures)\n',
                fails == 0 and 'ALL PASS' or 'FAILED', checks, fails))
            finish(fails == 0 and 0 or 1)
        end)
        local ok, err = coroutine.resume(co)
        if not ok then check('worker ' .. i .. ' dispatch', false, err) end
    end
end

return {
    __thread_handle = router.handle,
    __init = function()
        for i = 1, WORKERS do
            local ok, err = xthread.create_thread(BASE_TID + i - 1,
                'xs-race-' .. i, WORKER_SCRIPT)
            if not ok then
                out('FAIL could not start worker ' .. i .. ': ' .. tostring(err) .. '\n')
                finish(1); return
            end
            started = i
        end

        local co = coroutine.create(run)
        local ok, err = coroutine.resume(co)
        if not ok then out('FAIL test coroutine: ' .. tostring(err) .. '\n'); finish(1) end

        -- Everything here is event-driven; a watchdog turns a hang into a
        -- readable failure instead of a test that never returns. It stops
        -- WITHOUT joining: a wedged worker would make shutdown_thread block
        -- forever, and the exit code is non-zero either way.
        xtimer.add(90000, function()
            out('FAIL watchdog: the test did not finish within 90s\n')
            xthread.stop(1)
        end, 1)
    end,
    __uninit = function() end,
}
