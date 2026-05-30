-- Stage 7 spec: work-worker chat pre-processing (design §10 聊天前处理).
--
-- chatfilter.lua runs the spam gate (per-sender token bucket) and the profanity
-- mask off the battle frame, before a chat line is broadcast.
--
-- Run via: bin/xnet tests/lua/chatfilter_spec.lua

local spec = dofile('tests/lua/spec_helper.lua')
local chatfilter = dofile('scripts/game/chatfilter.lua')

spec.describe('per-sender rate limit (token bucket) (§10)', function()
    spec.it('lets a burst through then throttles', function()
        local f = chatfilter.new({ burst = 3, refill_ms = 1000 })
        spec.truthy(f:allow(1, 0), '1st in burst')
        spec.truthy(f:allow(1, 0), '2nd in burst')
        spec.truthy(f:allow(1, 0), '3rd in burst')
        spec.truthy(not f:allow(1, 0), '4th over budget -> throttled')
    end)

    spec.it('refills one token per refill_ms', function()
        local f = chatfilter.new({ burst = 3, refill_ms = 1000 })
        f:allow(1, 0); f:allow(1, 0); f:allow(1, 0)      -- drain
        spec.truthy(not f:allow(1, 0), 'drained')
        spec.truthy(f:allow(1, 1000), 'a full window later -> one token back')
        spec.truthy(not f:allow(1, 1000), 'and only one')
    end)

    spec.it('a partial window is not enough for a whole token', function()
        local f = chatfilter.new({ burst = 1, refill_ms = 1000 })
        spec.truthy(f:allow(1, 0), 'spends the only token')
        spec.truthy(not f:allow(1, 500), 'half a window -> 0.5 token, denied')
        spec.truthy(f:allow(1, 1000), 'full window -> allowed')
    end)

    spec.it('meters each sender independently', function()
        local f = chatfilter.new({ burst = 1, refill_ms = 1000 })
        spec.truthy(f:allow(1, 0))
        spec.truthy(f:allow(2, 0), 'a different sender has its own bucket')
        spec.truthy(not f:allow(1, 0))
    end)
end)

spec.describe('sensitive-word masking (§10)', function()
    spec.it('masks a banned run, preserving length, case-insensitively', function()
        local f = chatfilter.new({ banned = { 'badword' } })
        local out, changed = f:sanitize('This is BadWord here')
        spec.equal(out, 'This is ******* here', '7-char run -> 7 mask chars')
        spec.truthy(changed)
    end)

    spec.it('leaves a clean line untouched and flags no change', function()
        local f = chatfilter.new({ banned = { 'badword' } })
        local out, changed = f:sanitize('all clean here')
        spec.equal(out, 'all clean here')
        spec.truthy(not changed)
    end)

    spec.it('masks several different banned words', function()
        local f = chatfilter.new({ banned = { 'foo', 'badword' } })
        local out = f:sanitize('foo and BADWORD')
        spec.equal(out, '*** and *******')
    end)

    spec.it('masks every occurrence in the line', function()
        local f = chatfilter.new({ banned = { 'foo' } })
        spec.equal((f:sanitize('foo foo foo')), '*** *** ***')
    end)
end)

spec.describe('process(): rate gate then mask (§10)', function()
    spec.it('drops a throttled line without filtering it', function()
        local f = chatfilter.new({ burst = 1, refill_ms = 1000, banned = { 'x' } })
        spec.truthy(f:process(1, 'hello', 0).ok, 'first line ok')
        local r = f:process(1, 'hello again', 0)
        spec.truthy(not r.ok)
        spec.equal(r.reason, 'rate_limited')
        spec.nil_value(r.text, 'a dropped line carries no text')
    end)

    spec.it('forwards a sanitized line and flags whether it was filtered', function()
        local f = chatfilter.new({ burst = 5, refill_ms = 1000, banned = { 'badword' } })
        local dirty = f:process(1, 'hi badword', 0)
        spec.truthy(dirty.ok)
        spec.equal(dirty.text, 'hi *******')
        spec.truthy(dirty.filtered, 'filtered flag set when masked')

        local clean = f:process(1, 'hi there', 0)
        spec.truthy(clean.ok)
        spec.equal(clean.text, 'hi there')
        spec.truthy(not clean.filtered, 'clean line -> filtered false')
    end)
end)

local failures = spec.finish()

return {
    __init = function()
        if failures > 0 then
            os.exit(1)
        end
        xthread.stop(0)
    end,
}
