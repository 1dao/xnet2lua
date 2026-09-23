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

spec.describe('tokens.cache usage', function()
    spec.it('counts cache hits and writes as input and reports the hit ratio', function()
        local u = { input_tokens = 100, cache_read_input_tokens = 800, cache_creation_input_tokens = 100 }
        spec.equal(tokens.total_input_tokens(u), 1000)
        spec.equal(tokens.cache_hit_ratio(u), 0.8)
        spec.nil_value(tokens.cache_hit_ratio({ output_tokens = 5 }))
    end)

    spec.it('sums usage including the cache counters', function()
        local acc = { input_tokens = 0, output_tokens = 0 }
        tokens.add_usage(acc, { input_tokens = 10, output_tokens = 2, cache_read_input_tokens = 90 })
        tokens.add_usage(acc, { input_tokens = 5, output_tokens = 1, cache_creation_input_tokens = 7 })
        spec.equal(acc.input_tokens, 15)
        spec.equal(acc.output_tokens, 3)
        spec.equal(acc.cache_read_input_tokens, 90)
        spec.equal(acc.cache_creation_input_tokens, 7)
    end)

    spec.it('loop.run reports the turn total across tool round-trips', function()
        local provider = require('xagent.llm.provider')
        local loop = require('xagent.core.loop')
        local saved, n = provider.stream_message, 0
        provider.stream_message = function(_, _, cb)
            n = n + 1
            local content = (n == 1)
                and { { type = 'tool_use', id = 'u1', name = 'NoSuchTool', input = {} } }
                or { { type = 'text', text = 'done' } }
            cb.on_done({ message = { role = 'assistant', content = content },
                stop_reason = (n == 1) and 'tool_use' or 'end_turn',
                usage = { input_tokens = 10, output_tokens = 1, cache_read_input_tokens = 100 } })
        end
        local res
        local co = coroutine.create(function()
            res = loop.run({ cfg = { model = 'm' }, messages = { { role = 'user', content = 'go' } },
                             system = 'SYS', tools = {}, ctx = {} })
        end)
        local ok, err = coroutine.resume(co)
        provider.stream_message = saved
        assert(ok, err)
        spec.equal(res.usage.input_tokens, 20)
        spec.equal(res.usage.cache_read_input_tokens, 200)
        spec.equal(res.usage.output_tokens, 2)
    end)
end)

spec.describe('loop.run usage accounting', function()
    local provider = require('xagent.llm.provider')
    local loop = require('xagent.core.loop')
    local U = { input_tokens = 100, output_tokens = 5, cache_read_input_tokens = 50 }

    -- Run loop.run against canned replies (stop_reason per call); returns the
    -- result and every emitted 'done' event.
    local function run_with(stops, opts)
        local saved, n = provider.stream_message, 0
        provider.stream_message = function(_, _, cb)
            n = n + 1
            local stop = stops[math.min(n, #stops)]
            local content = (stop == 'tool_use')
                and { { type = 'tool_use', id = 'u' .. n, name = 'NoSuchTool', input = {} } }
                or { { type = 'text', text = 'x' } }
            cb.on_done({ message = { role = 'assistant', content = content }, stop_reason = stop, usage = U })
        end
        local res, dones = nil, {}
        local o = { cfg = { model = 'm' }, messages = { { role = 'user', content = 'go' } },
                    system = 'SYS', tools = {}, ctx = {},
                    on_event = function(ev) if ev.type == 'done' then dones[#dones + 1] = ev end end }
        for k, v in pairs(opts or {}) do o[k] = v end
        local co = coroutine.create(function() res = loop.run(o) end)
        local ok, err = coroutine.resume(co)
        provider.stream_message = saved
        assert(ok, err)
        return res, dones, n
    end

    spec.it('counts the discarded attempt of a max_tokens retry', function()
        local res, dones, calls = run_with({ 'max_tokens', 'end_turn' }, { max_tokens = 1000 })
        spec.equal(calls, 2)
        spec.equal(res.usage.input_tokens, 200)
        spec.equal(res.usage.output_tokens, 10)
        spec.equal(res.usage.cache_read_input_tokens, 100)
        spec.equal(dones[1].usage.input_tokens, 200)
    end)

    spec.it('reports usage on a cancelled turn', function()
        local stopped = false
        local res, dones = run_with({ 'tool_use' }, {
            should_stop = function() local s = stopped; stopped = true; return s end })
        spec.equal(res.stop_reason, 'cancelled')
        spec.equal(dones[1].usage.input_tokens, 100)
    end)

    spec.it('reports usage and keeps the anchor at the turn limit', function()
        local res, dones = run_with({ 'tool_use' }, { max_turns = 2 })
        spec.equal(res.stop_reason, 'max_turns')
        spec.equal(dones[1].usage.input_tokens, 200)
        spec.truthy(res.last_usage ~= nil and res.usage_anchor_index ~= nil, 'anchor kept')
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

spec.describe('compaction.build_cached_summary_messages', function()
    spec.it('keeps the history prefix and folds the instruction into a trailing user turn', function()
        local h = make_history()
        local out = comp.build_cached_summary_messages(h, 'SUMMARIZE')
        spec.equal(#out, #h)
        for i = 1, #h - 1 do spec.truthy(out[i] == h[i], 'prefix message ' .. i .. ' must be shared') end
        local last = out[#out].content
        spec.equal(last[1].type, 'tool_result')
        spec.equal(last[#last].text, 'SUMMARIZE')
        spec.equal(#h[#h].content, 1, 'the real history must not be mutated')
    end)

    spec.it('appends a new user turn after an assistant message', function()
        local h = { { role = 'user', content = 'q' }, { role = 'assistant', content = 'a' } }
        local out = comp.build_cached_summary_messages(h, 'SUMMARIZE')
        spec.equal(#out, 3)
        spec.equal(out[3].role, 'user')
        spec.equal(out[3].content, 'SUMMARIZE')
    end)
end)

spec.describe('compaction.format_summary', function()
    spec.it('drops the analysis scratchpad and unwraps the summary', function()
        spec.equal(comp.format_summary('<analysis>long notes</analysis>\n<summary>\nKEEP\n</summary>'), 'KEEP')
        spec.equal(comp.format_summary('plain text'), 'plain text')
    end)
end)

spec.describe('compaction.summarize_messages', function()
    local provider = require('xagent.llm.provider')

    -- Run fn in a coroutine with provider.stream_message answering from `reply`
    -- (fn(params) -> text or nil for an error); returns the captured requests.
    local function with_provider(reply, fn)
        local saved, calls = provider.stream_message, {}
        provider.stream_message = function(_, params, cb)
            calls[#calls + 1] = params
            local t = reply(params, #calls)
            if t then
                cb.on_text(t)
                cb.on_done({ message = { role = 'assistant', content = { { type = 'text', text = t } } } })
            else
                cb.on_error('boom')
            end
        end
        local co = coroutine.create(fn)
        local ok, err = coroutine.resume(co)
        provider.stream_message = saved
        assert(ok, err)
        return calls
    end

    spec.it('replays the sent request (system, tools, raw history) for a cache hit', function()
        local h = make_history()
        local tools = { { name = 'Read' } }
        local got
        local calls = with_provider(function() return '<summary>S</summary>' end, function()
            got = comp.summarize_messages({}, {}, nil, { system = 'SYS', tools = tools, cached_messages = h })
        end)
        spec.equal(got, 'S')
        spec.equal(#calls, 1)
        spec.equal(calls[1].system, 'SYS')
        spec.truthy(calls[1].tools == tools, 'tools must be the same as the loop sends')
        spec.truthy(calls[1].messages[1] == h[1], 'history prefix must be replayed as-is')
    end)

    spec.it('falls back to a transcript request when the replay fails', function()
        local got
        local calls = with_provider(function(_, n) if n == 2 then return 'FALLBACK' end end, function()
            got = comp.summarize_messages({}, make_history(), nil, { system = 'SYS' })
        end)
        spec.equal(got, 'FALLBACK')
        spec.equal(#calls, 2)
        spec.nil_value(calls[2].tools)
        spec.contains(calls[2].messages[1].content, 'Conversation to summarize')
    end)
end)

return {
    __init = function()
        local failed = spec.finish()
        if failed > 0 then os.exit(1) end
        xthread.stop(0)
    end,
}
