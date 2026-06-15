-- xagent/context/tokens.lua — rough token estimation + context-window budgeting.
--
-- We never have a real tokenizer locally, so we estimate from byte/char counts
-- and anchor on the model's REAL usage when we have it: the
-- newest API response tells us the exact token count up to the last assistant
-- message; everything appended after that (fresh tool_result turns) is estimated
-- and added on top. The budget snapshot drives auto-compaction and the GUI meter.

local xutils = require('xutils')

local M = {}

-- Window / buffer constants (tokens). The buffers are headroom reserved below
-- the window for the model's own output + safety; auto-compaction fires when the
-- estimate crosses (effective_window - autocompact_buffer).
M.MODEL_CONTEXT_WINDOW_DEFAULT  = 200000
M.MAX_OUTPUT_TOKENS_FOR_SUMMARY = 20000
M.AUTOCOMPACT_BUFFER_TOKENS     = 13000
M.WARNING_THRESHOLD_BUFFER_TOKENS = 20000
M.MANUAL_COMPACT_BUFFER_TOKENS  = 3000

local TEXT_CHARS_PER_TOKEN     = 4
local JSON_CHARS_PER_TOKEN     = 2
local MESSAGE_OVERHEAD_TOKENS  = 12
local TOOL_BLOCK_OVERHEAD_TOKENS = 24
local FIXED_BINARY_BLOCK_TOKENS = 2000

-- A small known-model map; unknown models fall back to the default window.
-- DeepSeek's compatible endpoint advertises a 128K window, so list it here so
-- the meter/thresholds are right when pointed at DeepSeek.
local MODEL_CONTEXT_WINDOWS = {
    ['claude-opus-4-20250514']   = 200000,
    ['claude-sonnet-4-20250514'] = 200000,
    ['claude-sonnet-4-5']        = 200000,
    ['claude-3-5-sonnet']        = 200000,
    ['deepseek-v4-pro']          = 128000,
    ['deepseek-chat']            = 128000,
    ['deepseek-reasoner']        = 128000,
}

-- Optional explicit override (cfg.context_window or XAGENT_MAX_CONTEXT_TOKENS),
-- mirroring source's EASY_AGENT_MAX_CONTEXT_TOKENS env override.
function M.get_context_window_for_model(model, override)
    override = override or tonumber(os.getenv('XAGENT_MAX_CONTEXT_TOKENS'))
    if override and override > 0 then return math.floor(override) end
    model = tostring(model or '')
    if MODEL_CONTEXT_WINDOWS[model] then return MODEL_CONTEXT_WINDOWS[model] end
    for key, value in pairs(MODEL_CONTEXT_WINDOWS) do
        if model:find(key, 1, true) or key:find(model, 1, true) then return value end
    end
    return M.MODEL_CONTEXT_WINDOW_DEFAULT
end

function M.get_effective_context_window_size(model, override)
    local w = M.get_context_window_for_model(model, override)
    local reserved = math.min(M.MAX_OUTPUT_TOKENS_FOR_SUMMARY, math.floor(w * 0.2))
    return w - reserved
end

local function rough(content, chars_per_token)
    chars_per_token = chars_per_token or TEXT_CHARS_PER_TOKEN
    return math.max(1, math.floor(#tostring(content or '') / chars_per_token + 0.5))
end

local function estimate_unknown_object_tokens(value)
    local ok, s = pcall(xutils.json_pack, value)
    return rough((ok and s) or tostring(value), JSON_CHARS_PER_TOKEN)
end

local function estimate_content_block_tokens(content)
    if type(content) == 'string' then return rough(content) end
    if type(content) ~= 'table' then return 0 end
    local total = 0
    for _, block in ipairs(content) do
        local bt = block.type
        if bt == 'text' then
            total = total + rough(block.text)
        elseif bt == 'thinking' then
            total = total + rough(block.thinking)
        elseif bt == 'tool_use' then
            total = total + TOOL_BLOCK_OVERHEAD_TOKENS + rough(block.name)
                  + estimate_unknown_object_tokens(block.input)
        elseif bt == 'tool_result' then
            local s = block.content
            if type(s) ~= 'string' then local ok, j = pcall(xutils.json_pack, s); s = (ok and j) or '' end
            total = total + TOOL_BLOCK_OVERHEAD_TOKENS + rough(s, JSON_CHARS_PER_TOKEN)
        elseif bt == 'image' or bt == 'document' then
            total = total + FIXED_BINARY_BLOCK_TOKENS
        else
            total = total + estimate_unknown_object_tokens(block)
        end
    end
    return total
end

function M.estimate_message_tokens(message)
    return MESSAGE_OVERHEAD_TOKENS + estimate_content_block_tokens(message.content)
end

function M.rough_token_count_for_messages(messages)
    local raw = 0
    for _, m in ipairs(messages or {}) do raw = raw + M.estimate_message_tokens(m) end
    return math.ceil(raw * 4 / 3)
end

function M.estimate_system_prompt_tokens(system)
    if not system or system == '' then return 0 end
    return rough(system) + MESSAGE_OVERHEAD_TOKENS
end

function M.get_token_count_from_usage(usage)
    if not usage then return 0 end
    return (usage.input_tokens or 0)
         + (usage.cache_creation_input_tokens or 0)
         + (usage.cache_read_input_tokens or 0)
         + (usage.output_tokens or 0)
end

-- Estimate total conversation tokens. With a real `usage` + `usage_anchor_index`
-- (the index of the last message that usage covers), trust the exact count and
-- only estimate the suffix appended since.
-- opts: { usage?, usage_anchor_index?, system? }
function M.token_count_with_estimation(messages, opts)
    opts = opts or {}
    local sys_tokens = opts.system and M.estimate_system_prompt_tokens(opts.system) or 0
    local anchor = opts.usage_anchor_index
    if opts.usage and anchor and anchor >= 0 then
        local suffix = {}
        for i = anchor + 1, #messages do suffix[#suffix + 1] = messages[i] end
        return M.get_token_count_from_usage(opts.usage)
             + M.rough_token_count_for_messages(suffix) + sys_tokens
    end
    return M.rough_token_count_for_messages(messages) + sys_tokens
end

-- For windows smaller than the 200K reference, scale the fixed buffers down so
-- the ratios stay sensible (e.g. on DeepSeek's 128K window).
local function scale_buffer(buffer, effective_window)
    local reference = 180000
    if effective_window >= reference then return buffer end
    return math.floor(buffer * (effective_window / reference) + 0.5)
end
M.scale_buffer = scale_buffer

function M.get_auto_compact_threshold(model, override)
    local eff = M.get_effective_context_window_size(model, override)
    return math.max(0, eff - scale_buffer(M.AUTOCOMPACT_BUFFER_TOKENS, eff))
end

function M.get_blocking_limit(model, override)
    local eff = M.get_effective_context_window_size(model, override)
    return math.max(0, eff - scale_buffer(M.MANUAL_COMPACT_BUFFER_TOKENS, eff))
end

-- { estimated, context_window, effective_context_window, auto_compact_threshold,
--   manual_compact_threshold, warning_threshold, percent, state }
function M.build_budget_snapshot(messages, opts)
    opts = opts or {}
    local model, override = opts.model, opts.context_window
    local estimated = M.token_count_with_estimation(messages, opts)
    local window    = M.get_context_window_for_model(model, override)
    local eff       = M.get_effective_context_window_size(model, override)
    local auto      = M.get_auto_compact_threshold(model, override)
    local manual    = M.get_blocking_limit(model, override)
    local warning   = math.max(0, eff - scale_buffer(M.WARNING_THRESHOLD_BUFFER_TOKENS, eff))

    local state = 'normal'
    if estimated >= manual then state = 'blocking'
    elseif estimated >= auto then state = 'error'
    elseif estimated >= warning then state = 'warning' end

    return {
        estimated = estimated,
        context_window = window,
        effective_context_window = eff,
        auto_compact_threshold = auto,
        manual_compact_threshold = manual,
        warning_threshold = warning,
        percent = window > 0 and (estimated / window) or 0,
        state = state,
    }
end

return M
