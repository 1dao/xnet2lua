-- xtimer_test_main.lua - smoke-test the xtimer Lua binding.

local count = 0
local handles = {}

local function __init()
    print('[XTIMER-TEST] init, now_ms=' .. xtimer.now_ms() .. ' formatted=' .. xtimer.format())
    xtimer.init(32)

    -- one-shot
    handles.once = xtimer.add(50, function(self)
        print('[XTIMER-TEST] once fired, active=' .. tostring(self:active()))
    end, 1)

    -- repeat 3 times
    handles.three = xtimer.add(80, function()
        count = count + 1
        print('[XTIMER-TEST] three #' .. count)
    end, 3)

    -- infinite, will be cancelled after a few ticks
    handles.tick = xtimer.add(120, function()
        print('[XTIMER-TEST] tick at ' .. xtimer.now_ms())
    end, -1)

    -- delay(): one-shot convenience; cancel the infinite timer and stop.
    xtimer.delay(500, function()
        print('[XTIMER-TEST] cancelling tick & stopping')
        if handles.tick then handles.tick:del() end
        xthread.stop(0)
    end)
end

-- No __update / __uninit needed: once xtimer.init() has been called the
-- runtime auto-drives xtimer.update() each tick and auto-runs xtimer.uninit()
-- on shutdown.

return {
    __init = __init,
    __tick_ms = 10,
}
