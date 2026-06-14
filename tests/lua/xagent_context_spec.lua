-- Unit specs for the offline-testable context-management logic: token
-- estimation / budgeting (context/tokens.lua) and conversation compaction
-- (context/compaction.lua). The LLM summarization call is stubbed — only the
-- micro-compaction, tail-preservation, and orchestration logic is exercised here
-- (the live summarize path is covered by real agent runs).
-- Run via: bin/xnet tests/lua/xagent_context_spec.lua

package.path = 'scripts/?.lua;' .. package.path

local spec   = dofile('tests/lua/spec_helper.lua')
local tokens = require('xagent.context.tokens')
local comp   = require('xagent.context.compaction')

local BIG = string.rep('x', 4000)

spec.describe('tokens.estimation', function()
    spec.it('grows with message size', function()
        local small = tokens.rough_token_count_for_messages({ { role = 'user', content = 'hi' } })
        local big   = tokens.rough_token_count_for_messages({ { role = 'user', content = BIG } })
        spec.truthy(big > small * 10, 'big should dwarf small')
    end)

    spec.it('anchors on real usage and only estimates the suffix', function()
        local msgs = { { role = 'user', content = 'a' }, { role = 'assistant', content = 'b' },
                       { role = 'user', content = BIG } }
        local n = tokens.token_count_with_estimation(msgs,
            { usage = { input_tokens = 5000, output_tokens = 100 }, usage_anchor_index = 2, system = 'sys' })
        spec.truthy(n > 5000 and n < 6500, 'expected ~5000+suffix, got ' .. n)
    end)
end)

spec.describe('tokens.budget', function()
    spec.it('uses the model window (DeepSeek = 128K)', function()
        local s = tokens.build_budget_snapshot({ { role = 'user', content = BIG } }, { model = 'deepseek-v4-pro' })
        spec.equal(s.context_window, 128000)
    end)

    spec.it('orders warning < auto-compact < manual thresholds', function()
        local s = tokens.build_budget_snapshot({}, { model = 'deepseek-v4-pro' })
        spec.truthy(s.warning_threshold < s.auto_compact_threshold, 'warning < auto')
        spec.truthy(s.auto_compact_threshold < s.manual_compact_threshold, 'auto < manual')
    end)

    spec.it('honors an explicit context_window override', function()
        local s = tokens.build_budget_snapshot({}, { model = 'whatever', context_window = 64000 })
        spec.equal(s.context_window, 64000)
    end)
end)

-- Build a history long enough to trigger micro-compaction, with both a
-- compactable (Read) and a non-compactable (TodoWrite) old tool result, plus a
-- recent Read result that must be preserved.
local function make_history()
    local m = {}
    m[#m + 1] = { role = 'user', content = 'start' }
    m[#m + 1] = { role = 'assistant', content = { { type = 'tool_use', id = 't1', name = 'Read' } } }
    m[#m + 1] = { role = 'user', content = { { type = 'tool_result', tool_use_id = 't1', content = BIG } } }
    m[#m + 1] = { role = 'assistant', content = { { type = 'tool_use', id = 't2', name = 'TodoWrite' } } }
    m[#m + 1] = { role = 'user', content = { { type = 'tool_result', tool_use_id = 't2', content = '[ ] a\n[~] b' } } }
    for i = 6, 11 do m[#m + 1] = { role = (i % 2 == 0) and 'assistant' or 'user', content = 'filler ' .. i } end
    m[#m + 1] = { role = 'assistant', content = { { type = 'tool_use', id = 't3', name = 'Read' } } }
    m[#m + 1] = { role = 'user', content = { { type = 'tool_result', tool_use_id = 't3', content = BIG } } }
    return m
end

local function no_dangling(ms)
    local uses = {}
    for _, m in ipairs(ms) do
        if type(m.content) == 'table' then
            for _, b in ipairs(m.content) do if b.type == 'tool_use' then uses[b.id] = true end end
        end
    end
    for _, m in ipairs(ms) do
        if type(m.content) == 'table' then
            for _, b in ipairs(m.content) do
                if b.type == 'tool_result' and not uses[b.tool_use_id] then return false end
            end
        end
    end
    return true
end

spec.describe('compaction.micro_compact', function()
    spec.it('clears old heavy tool results but keeps recent + stateful ones', function()
        local mc = comp.micro_compact(make_history())
        spec.truthy(mc.changed, 'should have changed')
        spec.equal(mc.messages[3].content[1].content, comp.OLD_TOOL_RESULT_PLACEHOLDER) -- old Read cleared
        spec.equal(mc.messages[5].content[1].content, '[ ] a\n[~] b')                   -- TodoWrite kept
        spec.equal(mc.messages[13].content[1].content, BIG)                             -- recent Read kept
    end)

    spec.it('is a no-op for short histories', function()
        spec.equal(comp.micro_compact({ { role = 'user', content = 'x' } }).changed, false)
    end)
end)

spec.describe('compaction.replace_in_place', function()
    spec.it('keeps table identity while swapping contents', function()
        local t = { 1, 2, 3 }; local id = t
        comp.replace_in_place(t, { 9, 8 })
        spec.truthy(id == t and t[1] == 9 and t[2] == 8 and t[3] == nil)
    end)
end)

spec.describe('compaction.auto_compact_if_needed', function()
    spec.it('does nothing below the threshold', function()
        comp.reset_failures()
        local r = comp.auto_compact_if_needed({
            messages = { { role = 'user', content = 'hi' }, { role = 'assistant', content = 'yo' } },
            cfg = { model = 'deepseek-v4-pro' } })
        spec.equal(r.did_compact, false)
        spec.equal(r.did_micro, false)
    end)

    spec.it('summarizes + preserves a tool-pair-safe tail when forced', function()
        local saved = comp.summarize_messages
        comp.summarize_messages = function() return 'CANNED SUMMARY', nil end
        local r = comp.auto_compact_if_needed({ messages = make_history(),
            cfg = { model = 'deepseek-v4-pro' }, force = true })
        comp.summarize_messages = saved
        spec.equal(r.did_compact, true)
        spec.equal(r.messages[1].role, 'user')
        spec.contains(r.messages[1].content, 'CANNED SUMMARY')
        spec.truthy(no_dangling(r.messages), 'compacted tail must not dangle a tool_result')
    end)
end)

return {
    __init = function()
        local failed = spec.finish()
        if failed > 0 then os.exit(1) end
        xthread.stop(0)
    end,
}
