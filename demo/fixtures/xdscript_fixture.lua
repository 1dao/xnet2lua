-- Test fixture for demo/xdscript_test.lua.
--
-- Top-level code runs once EVERY time this file is dofile'd, so
-- _G.__XDSCRIPT_FIXTURE_LOADS counts how many times it was actually re-read
-- from disk versus served out of xdscript's module cache.
_G.__XDSCRIPT_FIXTURE_LOADS = (_G.__XDSCRIPT_FIXTURE_LOADS or 0) + 1

return {
    on_enter = function(ctx, extra)
        return 'entered', ctx and ctx.player, extra and extra.reward
    end,
    on_leave = function(ctx)
        return 'left', ctx and ctx.player
    end,
    -- Used to verify xdscript.call() isolates a handler error via pcall.
    on_broken = function()
        error('boom: designer script bug')
    end,
}
