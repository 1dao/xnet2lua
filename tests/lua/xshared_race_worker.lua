-- xshared_race_worker.lua — the worker half of xshared_race_test.lua.
--
-- Every worker walks the SAME list of never-before-seen names, in the same
-- order, starting at the same instant. Each name is therefore its own race: one
-- worker should build the dict and the rest should find it.
--
-- THE BARRIER MATTERS. An earlier version of this test just fired the RPCs
-- together and let the workers start whenever they woke up. That was enough
-- stagger for the first worker to finish creating before the others even looked,
-- so the test passed against a deliberately racy build — it proved nothing.
-- Spinning to a shared wall-clock deadline puts every worker inside
-- xshared.create within microseconds of the others.

local router = dofile('scripts/core/share/xrouter.lua')
local xtimer = require('xtimer')
router.set_log_prefix('XS-RACE')

-- Returns (created_count, err). created_count is how many of the `count` names
-- THIS worker was the one to build; summed across workers it must come to
-- exactly `count` — one creator per name, no more.
router.register('race', function(start_ms, count)
    count = tonumber(count) or 200
    local mine = 0

    while xtimer.now_ms() < start_ms do end          -- barrier

    for k = 1, count do
        local name = 'test_race' .. k
        local d, created = xshared.create(name, 4096, 2)
        if not d then return 0, 'create returned nil for ' .. name end
        if created then mine = mine + 1 end
        -- Every worker increments every name. If a name ever forked into two
        -- dicts, the one the main thread resolves afterwards comes up short.
        d:incr('hits', 1, 0)
    end

    return mine, nil
end)

return {
    __thread_handle = router.handle,
}
