-- xagent/context/compaction.lua — keep a long conversation inside the context
-- window.
--
-- Two mechanisms, cheapest first:
--   1. micro-compaction — clear the bodies of OLD, heavy tool results (Read/
--      Grep/Bash/…) outside a recent window. Cheap, lossy-but-safe, no API call.
--   2. full compaction — when the estimate still crosses the auto-compact
--      threshold, ask the model to summarize the conversation, then replace the
--      history with [summary] + a verbatim recent tail (kept tool-pair-safe).
--
-- auto_compact_if_needed() is the entry point the loop calls before each turn.
-- The summarization step makes an LLM call, so it MUST run inside the agent
-- coroutine (it awaits anthropic.stream_message).

local async     = dofile('scripts/core/share/xasync.lua')
local anthropic = require('xagent.llm.anthropic')
local tokens    = require('xagent.context.tokens')
local text      = dofile('scripts/core/share/xtext.lua')

local M = {}

M.OLD_TOOL_RESULT_PLACEHOLDER = '[Old tool result content cleared]'
M.MAX_CONSECUTIVE_FAILURES = 3
-- Cap on the summary generation itself. (MAX_OUTPUT_TOKENS_FOR_SUMMARY in
-- tokens.lua is the WINDOW reserve, a different number — don't reuse it here:
-- a 20k-token summary call is needlessly slow and feels like a freeze.)
M.SUMMARY_MAX_TOKENS = 8000

local MICROCOMPACT_MIN_MESSAGES    = 10
local MICROCOMPACT_KEEP_RECENT     = 8
local DESIRED_TAIL_COUNT           = 8
-- Heavy, regenerable tool outputs whose old bodies are safe to drop. Stateful
-- tools (TodoWrite) and small notes (MemoryWrite) are intentionally excluded.
local COMPACTABLE_TOOLS = {
    Read = true, Grep = true, Glob = true, Bash = true, Edit = true,
    Write = true, MultiEdit = true, WebFetch = true, LS = true,
}

local consecutive_failures = 0
function M.reset_failures() consecutive_failures = 0 end

local NO_TOOLS_PREAMBLE = [[CRITICAL: Respond with TEXT ONLY. Do NOT call any tools.

- You already have all the context you need in the conversation above.
- Your entire response must be plain text: an <analysis> block followed by a <summary> block.
]]

local BASE_COMPACT_PROMPT = [[Your task is to create a detailed summary of the conversation so far, paying close attention to the user's explicit requests and your previous actions.
This summary should be thorough in capturing technical details, code patterns, and architectural decisions that would be essential for continuing development work without losing context.

Before providing your final summary, wrap your analysis in <analysis> tags to organize your thoughts. Chronologically analyze each section: the user's explicit requests and intents, your approach, key decisions and code patterns, specific details (file names, code snippets, function signatures, edits), errors and how you fixed them, and especially any user feedback that told you to do something differently.

Your summary should include the following sections:

1. Primary Request and Intent: all of the user's explicit requests and intents in detail.
2. Key Technical Concepts: all important technical concepts, technologies, and frameworks.
3. Files and Code Sections: specific files and code examined, modified, or created, with snippets and why each matters.
4. Errors and fixes: errors you ran into and how you fixed them, plus user feedback.
5. Problem Solving: problems solved and ongoing troubleshooting.
6. All user messages: list ALL user messages that are not tool results.
7. Pending Tasks: tasks you have explicitly been asked to work on.
8. Current Work: precisely what was being worked on immediately before this summary, with file names and snippets.
9. Optional Next Step: the next step related to the most recent work.

Provide your summary based on the conversation so far, with precision and thoroughness.]]

-- ── helpers ────────────────────────────────────────────────────────────────

local function is_blocks(content) return type(content) == 'table' end

-- Map tool_use_id -> tool name across the whole history (tool_result blocks
-- only carry the id, but we gate micro-compaction on the producing tool).
local function build_tool_name_map(messages)
    local map = {}
    for _, m in ipairs(messages) do
        if is_blocks(m.content) then
            for _, b in ipairs(m.content) do
                if b.type == 'tool_use' and b.id then map[b.id] = b.name end
            end
        end
    end
    return map
end

local function collect_tool_use_ids(message, set)
    if not is_blocks(message.content) then return end
    for _, b in ipairs(message.content) do
        if b.type == 'tool_use' and b.id then set[b.id] = true end
    end
end

local function collect_tool_result_ids(message, list)
    if not is_blocks(message.content) then return end
    for _, b in ipairs(message.content) do
        if b.type == 'tool_result' and b.tool_use_id then list[#list + 1] = b.tool_use_id end
    end
end

-- Replace the contents of `dst` with `src` (keeps the table identity so callers
-- holding a reference — e.g. session.messages — see the new history).
function M.replace_in_place(dst, src)
    for i = #dst, 1, -1 do dst[i] = nil end
    for i = 1, #src do dst[i] = src[i] end
    return dst
end

-- ── micro-compaction ────────────────────────────────────────────────────────

local function micro_compact_message(message, name_map, compacted_ids)
    if not is_blocks(message.content) then return message end
    local changed = false
    local next_content = {}
    for _, b in ipairs(message.content) do
        if b.type == 'image' then
            next_content[#next_content + 1] = { type = 'text', text = '[image]' }
            changed = true
        elseif b.type == 'tool_result' and type(b.content) == 'string'
               and COMPACTABLE_TOOLS[name_map[b.tool_use_id] or '']
               and b.content ~= M.OLD_TOOL_RESULT_PLACEHOLDER then
            local nb = {}
            for k, v in pairs(b) do nb[k] = v end
            nb.content = M.OLD_TOOL_RESULT_PLACEHOLDER
            next_content[#next_content + 1] = nb
            compacted_ids[#compacted_ids + 1] = b.tool_use_id
            changed = true
        else
            next_content[#next_content + 1] = b
        end
    end
    if not changed then return message end
    local nm = {}
    for k, v in pairs(message) do nm[k] = v end
    nm.content = next_content
    return nm
end

-- Clear old heavy tool-result bodies; keep the last KEEP_RECENT messages intact.
-- Returns { messages, compacted_ids, changed }.
function M.micro_compact(messages)
    if #messages < MICROCOMPACT_MIN_MESSAGES then
        return { messages = messages, compacted_ids = {}, changed = false }
    end
    local name_map = build_tool_name_map(messages)
    local compacted_ids = {}
    local out = {}
    local keep_from = #messages - MICROCOMPACT_KEEP_RECENT
    local changed = false
    for i, m in ipairs(messages) do
        if i > keep_from then
            out[i] = m
        else
            local nm = micro_compact_message(m, name_map, compacted_ids)
            out[i] = nm
            if nm ~= m then changed = true end
        end
    end
    return { messages = out, compacted_ids = compacted_ids, changed = changed }
end

-- Walk back from the desired tail size until the tail has no tool_result whose
-- matching tool_use is above it (a dangling result the API would reject).
local function find_preserved_tail_start(messages, desired)
    local start = math.max(1, #messages - desired + 1)
    while start > 1 do
        local uses, results = {}, {}
        for i = start, #messages do
            collect_tool_use_ids(messages[i], uses)
            collect_tool_result_ids(messages[i], results)
        end
        local dangling = false
        for _, id in ipairs(results) do if not uses[id] then dangling = true; break end end
        if not dangling then return start end
        start = start - 1
    end
    return 1
end

-- ── full (LLM) summarization ────────────────────────────────────────────────

-- Render the history to a compact, readable transcript for the summarizer. We
-- avoid JSON here: it bloats the request and trips json_pack on any stray bad
-- byte (tool output). Plain text is cheaper and robust.
local function render_for_summary(messages)
    local parts = {}
    for _, m in ipairs(messages) do
        local role = m.role or '?'
        if type(m.content) == 'string' then
            parts[#parts + 1] = role .. ': ' .. m.content
        elseif is_blocks(m.content) then
            for _, b in ipairs(m.content) do
                if b.type == 'text' then
                    parts[#parts + 1] = role .. ': ' .. (b.text or '')
                elseif b.type == 'thinking' then
                    parts[#parts + 1] = role .. ' (thinking): ' .. (b.thinking or '')
                elseif b.type == 'tool_use' then
                    local ok, j = pcall(require('xutils').json_pack, b.input)
                    parts[#parts + 1] = role .. ' → tool ' .. tostring(b.name) ..
                        ' ' .. ((ok and j) or '')
                elseif b.type == 'tool_result' then
                    local c = b.content
                    if type(c) ~= 'string' then c = '[non-text result]' end
                    if #c > 4000 then c = c:sub(1, 4000) .. '…[truncated]' end
                    parts[#parts + 1] = 'tool_result: ' .. c
                end
            end
        end
    end
    return text.valid_utf8(table.concat(parts, '\n'))
end

-- summarize_messages(cfg, messages, focus) -> summary, err. Runs inside coroutine.
function M.summarize_messages(cfg, messages, focus)
    local system = NO_TOOLS_PREAMBLE .. BASE_COMPACT_PROMPT
    if focus and focus ~= '' then
        system = system .. '\n\n## Compact Instructions\n' .. focus
    end
    local convo = render_for_summary(messages)

    local acc = {}
    local result, err = async.await(function(resolve)
        anthropic.stream_message(cfg, {
            system = system,
            messages = { { role = 'user', content = 'Conversation to summarize:\n' .. convo } },
            max_tokens = M.SUMMARY_MAX_TOKENS,
            -- no tools on purpose
        }, {
            on_text = function(t) acc[#acc + 1] = t end,
            on_done = function(r) resolve(r, nil) end,
            on_error = function(e) resolve(nil, e) end,
        })
    end)
    if err then return nil, err end

    -- Prefer streamed text; fall back to reassembled blocks.
    local summary = table.concat(acc)
    if summary == '' and result and result.message then
        for _, b in ipairs(result.message.content or {}) do
            if b.type == 'text' then summary = summary .. b.text end
        end
    end
    return (summary:gsub('^%s+', ''):gsub('%s+$', '')), nil
end

local CONTINUE_PREFIX =
    'This session is being continued from a previous conversation that ran out ' ..
    'of context. The summary below covers the earlier portion of the conversation.\n\n'

-- Build the compacted message list: [summary] + verbatim recent tail.
local function build_compacted(messages, summary, focus)
    local tail_start = (#messages <= DESIRED_TAIL_COUNT) and (#messages + 1)
        or find_preserved_tail_start(messages, DESIRED_TAIL_COUNT)
    local tail = {}
    for i = tail_start, #messages do tail[#tail + 1] = messages[i] end

    local body = CONTINUE_PREFIX .. summary
    if #tail > 0 then body = body .. '\n\nRecent messages are preserved verbatim.' end

    local out = { { role = 'user', content = body } }
    for _, m in ipairs(tail) do out[#out + 1] = m end
    return out, #tail
end

-- ── orchestration ───────────────────────────────────────────────────────────

-- opts: { messages, cfg, system?, usage?, usage_anchor_index?, focus?,
--         force?, query_source? }
-- Returns: { messages, did_compact, did_micro, summary?, estimated, threshold }
function M.auto_compact_if_needed(opts)
    local messages = opts.messages
    local cfg = opts.cfg
    local model = cfg and cfg.model
    local override = cfg and cfg.context_window

    -- query_source guard + circuit breaker (mirrors source).
    local blocked_source = (opts.query_source == 'compact' or opts.query_source == 'session_memory')
    if consecutive_failures >= M.MAX_CONSECUTIVE_FAILURES then blocked_source = true end

    local threshold = tokens.get_auto_compact_threshold(model, override)

    -- Estimate on the RAW history. Below the threshold we leave the conversation
    -- completely untouched. Micro-compaction (shedding OLD tool-result bodies) is
    -- a near-the-limit measure, NOT continuous per-turn housekeeping: this runs
    -- before every tool turn, so clearing 8-message-old tool outputs while
    -- there's plenty of budget both loses context the model may still need
    -- within one task and spams a "cleared old tool output" notice on any long,
    -- tool-heavy answer.
    local raw_estimate = tokens.token_count_with_estimation(messages, {
        usage = opts.usage, usage_anchor_index = opts.usage_anchor_index, system = opts.system,
    })
    if not opts.force and raw_estimate < threshold then
        return {
            messages = messages, did_compact = false, did_micro = false,
            estimated = raw_estimate, threshold = threshold,
        }
    end

    -- Near the limit (or forced): shed old heavy tool outputs first (cheap),
    -- then re-estimate.
    local micro = M.micro_compact(messages)
    local working = micro.messages
    local estimated = tokens.token_count_with_estimation(working, {
        usage = opts.usage, usage_anchor_index = opts.usage_anchor_index, system = opts.system,
    })

    local need_full = opts.force or (not blocked_source and estimated >= threshold)
    if not need_full then
        return {
            messages = working, did_compact = false, did_micro = micro.changed,
            estimated = estimated, threshold = threshold,
        }
    end

    -- 3. full compaction via summarization. Signal first — the summary call is
    -- a full (slow) model round-trip with no streamed text, so the UI must say
    -- it's compacting or it looks frozen.
    if opts.notify then opts.notify() end
    local summary, err = M.summarize_messages(cfg, working, opts.focus)
    if err or not summary or summary == '' then
        consecutive_failures = consecutive_failures + 1
        return {
            messages = working, did_compact = false, did_micro = micro.changed,
            error = err or 'empty summary', estimated = estimated, threshold = threshold,
        }
    end
    consecutive_failures = 0

    local compacted, tail_n = build_compacted(working, summary, opts.focus)
    return {
        messages = compacted, did_compact = true, did_micro = micro.changed,
        summary = summary, kept_tail = tail_n,
        estimated = estimated, threshold = threshold,
    }
end

return M
