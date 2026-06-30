-- xagent/core/loop.lua — the agentic loop (coroutine form).
--
-- One call to run() drives a full user turn to completion: stream the model,
-- collect the assistant message, and while stop_reason == 'tool_use' run the
-- tools and feed results back. MUST run inside a coroutine (it awaits the
-- streaming client and, via tools, the subprocess RPC).

local async = dofile('scripts/core/share/xasync.lua')
local anthropic = require('xagent.llm.anthropic')
local tools_run = require('xagent.core.tools_run')
local compaction = require('xagent.context.compaction')
local tokens = require('xagent.context.tokens')

local M = {}

M.MAX_TURNS = 50
local DEFAULT_MAX_TOKENS = 4096

-- Upper bound for the max_tokens auto-escalation (see the streaming loop in
-- M.run). max_tokens is a ceiling billed on ACTUAL output, not a reservation, so
-- raising it costs nothing until the model actually produces more — but it MUST
-- stay at or below the model's hard output limit or the API rejects the request.
-- 32000 is safe for current Opus/Sonnet; override per-call via opts.max_tokens_ceiling.
M.MAX_TOKENS_CEILING = 32000

-- One streaming turn. Streams text out via on_text; returns (result, err).
local function stream_turn(cfg, params, on_text, on_tool_use_start)
    return async.await(function(resolve)
        anthropic.stream_message(cfg, params, {
            on_text = on_text,
            on_tool_use_start = on_tool_use_start,
            on_done = function(result) resolve(result, nil) end,
            on_error = function(err) resolve(nil, err) end,
        })
    end)
end

-- opts:
--   cfg          LLM config (api_key, base_url, model, ...)
--   messages     message array (mutated in place as the turn progresses)
--   system       system prompt string
--   tools        Anthropic tools param (from registry.to_api_params())
--   ctx          tool context ({ cwd, ... })
--   max_tokens   per-call cap (default 4096)
--   on_event     fn(event) — text|tool_use|tool_result|assistant|usage|done|error
-- Returns: { stop_reason, usage, turns }
-- Before a turn, fold the history down if it's near the context window. Anchors
-- the estimate on the last real usage we saw. Replaces `messages` in place (so
-- a session holding the same table reference sees the compacted history) and
-- emits a 'compact' event when anything changed.
local function maybe_compact(opts, messages, emit, last_usage, anchor)
    local res = compaction.auto_compact_if_needed({
        messages = messages, cfg = opts.cfg, system = opts.system,
        usage = last_usage, usage_anchor_index = anchor,
        notify = function() emit({ type = 'compact_start' }) end,
    })
    if res.did_compact or res.did_micro then
        compaction.replace_in_place(messages, res.messages)
        emit({ type = 'compact', did_compact = res.did_compact, did_micro = res.did_micro,
               summary = res.summary, kept_tail = res.kept_tail, estimated = res.estimated })
        if res.did_compact then return true end   -- history reshaped: anchor is now stale
    end
    return false
end

-- Emit the current context-budget snapshot (drives the GUI meter).
local function emit_budget(opts, messages, emit, last_usage, anchor)
    local snap = tokens.build_budget_snapshot(messages, {
        model = opts.cfg and opts.cfg.model,
        context_window = opts.cfg and opts.cfg.context_window,
        usage = last_usage, usage_anchor_index = anchor, system = opts.system,
    })
    emit({ type = 'budget', budget = snap })
end

function M.run(opts)
    local messages = opts.messages
    local function emit(ev) if opts.on_event then opts.on_event(ev) end end

    local total_in, total_out = 0, 0
    -- Anchor the token estimate on the model's real usage: after each turn the
    -- newest response gives an exact count up to the assistant message; the only
    -- tokens we estimate are tool_result turns appended afterward.
    local last_usage, anchor = opts.last_usage, opts.usage_anchor_index

    for turn = 1, (opts.max_turns or M.MAX_TURNS) do
        -- Cancellation point: checked at the turn boundary, where the history is
        -- in a clean state (any tool_use already has its paired tool_result), so
        -- a cancelled session can be saved and resumed without a dangling pair.
        if opts.should_stop and opts.should_stop() then
            emit({ type = 'done', stop_reason = 'cancelled' })
            return { stop_reason = 'cancelled',
                     usage = { input_tokens = total_in, output_tokens = total_out },
                     last_usage = last_usage, usage_anchor_index = anchor, turns = turn }
        end

        if maybe_compact(opts, messages, emit, last_usage, anchor) then
            last_usage, anchor = nil, nil   -- post-compaction: re-estimate from scratch
        end

        -- Stream the turn, escalating max_tokens if the model gets cut off
        -- mid-output (stop_reason == 'max_tokens'). A tool_use whose JSON argument
        -- is truncated can't be parsed (→ a broken _raw input); a truncated text
        -- answer is just incomplete. Either way we DISCARD the truncated attempt
        -- and re-stream with a doubled cap, up to the model's output ceiling. The
        -- cost is only the (rare) wasted attempt, since max_tokens bills on actual
        -- output. The 'truncated_retry' event lets the UI drop the partial output
        -- so the re-stream doesn't duplicate it.
        local eff_max = opts.max_tokens or DEFAULT_MAX_TOKENS
        local ceiling = math.max(eff_max, opts.max_tokens_ceiling or M.MAX_TOKENS_CEILING)
        local result, err
        while true do
            result, err = stream_turn(
                opts.cfg,
                {
                    messages = messages,
                    system = opts.system,
                    tools = opts.tools,
                    max_tokens = eff_max,
                },
                function(delta) emit({ type = 'text', text = delta }) end,
                function(id, name) emit({ type = 'tool_use_start', id = id, name = name }) end
            )
            if err or result.stop_reason ~= 'max_tokens' or eff_max >= ceiling then break end
            local new_max = math.min(eff_max * 2, ceiling)
            emit({ type = 'truncated_retry', from = eff_max, to = new_max, turn = turn })
            eff_max = new_max
        end

        if err then
            emit({ type = 'error', error = err })
            return { stop_reason = 'error', usage = { input_tokens = total_in, output_tokens = total_out }, turns = turn }
        end

        local assistant = result.message
        messages[#messages + 1] = assistant
        total_in = total_in + (result.usage.input_tokens or 0)
        total_out = total_out + (result.usage.output_tokens or 0)
        emit({ type = 'assistant', message = assistant, usage = result.usage })

        -- The response's usage covers system + every message up to (and
        -- including) this assistant turn; anchor future estimates on it.
        last_usage, anchor = result.usage, #messages
        emit_budget(opts, messages, emit, last_usage, anchor)

        if result.stop_reason ~= 'tool_use' then
            emit({ type = 'done', stop_reason = result.stop_reason,
                   usage = { input_tokens = total_in, output_tokens = total_out },
                   last_usage = last_usage, usage_anchor_index = anchor })
            return { stop_reason = result.stop_reason,
                     usage = { input_tokens = total_in, output_tokens = total_out },
                     last_usage = last_usage, usage_anchor_index = anchor, turns = turn }
        end

        -- Run the requested tools and append their results as a user turn.
        local tool_results = tools_run.run(assistant.content, opts.ctx, opts.on_event)
        messages[#messages + 1] = { role = 'user', content = tool_results }
    end

    emit({ type = 'done', stop_reason = 'max_turns' })
    return { stop_reason = 'max_turns',
             usage = { input_tokens = total_in, output_tokens = total_out }, turns = opts.max_turns or M.MAX_TURNS }
end

return M
