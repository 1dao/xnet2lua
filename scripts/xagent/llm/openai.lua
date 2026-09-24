-- xagent/llm/openai.lua — OpenAI Chat Completions API: request build + SSE decode.
--
-- The rest of xagent speaks Anthropic Messages (content blocks: text / image /
-- tool_use / tool_result / thinking), so this adapter translates at the wire:
-- build_request maps the history onto chat-completions messages, and the
-- decoder reassembles `chat.completion.chunk` deltas back into an
-- Anthropic-shaped result. Everything above the codec (loop, session, tools,
-- token budget) is unaware of which protocol ran.
--
-- Also covers the many "OpenAI-compatible" endpoints (DeepSeek, Qwen/DashScope,
-- Kimi, Zhipu, OpenRouter, vLLM, Ollama …), including their non-standard
-- `reasoning_content` stream, which becomes a `thinking` block.
--
-- Gemini (generativelanguage.googleapis.com/…/openai/) attaches a thought
-- signature to the first tool call of each step, at
-- tool_calls[i].extra_content.google.thought_signature, and rejects the next
-- request (HTTP 400) unless it comes back on that call. The decoder keeps it on
-- the tool_use block as `extra_content`; convert_assistant echoes it to Gemini
-- endpoints only (other servers never see the field).
--
-- Config (cfg): { api_key, base_url?, model?, auth_style?, max_tokens_param?,
--                 echo_reasoning? }
--   auth_style:       'bearer' (default) | 'api-key' (Azure) | 'x-api-key'
--   max_tokens_param: 'max_tokens' | 'max_completion_tokens' (default: by model)
--   echo_reasoning:   false to never send reasoning_content back in history

local xutils = require('xutils')
local common = require('xagent.llm.common')

local M = {}

local DEFAULT_BASE = 'https://api.openai.com/v1'
local DEFAULT_MAX_TOKENS = 4096

-- Resolve the chat-completions URL. Users paste base URLs in every shape, so
-- accept all of them:
--   …/chat/completions         → used as-is
--   …/v1, …/api/paas/v4, …/v3  → already versioned: append /chat/completions
--   https://host               → append /v1/chat/completions
-- A query string (Azure's ?api-version=…) is split off first and re-appended,
-- so the path is never glued onto the end of it.
function M.endpoint(base_url)
    local raw = base_url or DEFAULT_BASE
    local path, query = raw:match('^([^?#]*)(.*)$')
    local base = path:gsub('/+$', '')
    if base:find('/chat/completions$') then return base .. query end
    if base:find('/v%d+[%w%.]*$') then return base .. '/chat/completions' .. query end
    return base .. '/v1/chat/completions' .. query
end

-- OpenAI's reasoning models (o1/o3/o4…, gpt-5) reject `max_tokens` and require
-- `max_completion_tokens`; most compatible servers only know `max_tokens`.
local function max_tokens_field(cfg, model)
    if cfg.max_tokens_param and cfg.max_tokens_param ~= '' then return cfg.max_tokens_param end
    local m = tostring(model or ''):lower():gsub('^openai/', '')
    if m:find('^o%d') or m:find('^gpt%-5') then return 'max_completion_tokens' end
    return 'max_tokens'
end

local function blocks_of(content)
    if type(content) == 'string' then return { { type = 'text', text = content } } end
    if type(content) == 'table' then return content end
    return {}
end

local function image_part(block)
    local src = block.source or {}
    local url
    if src.type == 'base64' then
        url = 'data:' .. tostring(src.media_type or 'image/png') .. ';base64,' .. tostring(src.data or '')
    elseif src.type == 'url' then
        url = src.url
    end
    if not url then return nil end
    return { type = 'image_url', image_url = { url = url } }
end

-- Collapse an all-text parts list to a plain string. Many compatible servers
-- (and every text-only model) accept only string content, so use the array form
-- only when an image forces it.
local function finish_parts(parts)
    local texts = {}
    for _, p in ipairs(parts) do
        if p.type ~= 'text' then return parts end
        texts[#texts + 1] = p.text
    end
    return table.concat(texts, '\n')
end

-- A tool_result's content is a string or an array of text/image blocks. Tool
-- messages are text-only on most servers, so images are returned separately and
-- carried into the user message that follows.
local function tool_result_text(block)
    local c = block.content
    local images = {}
    local text
    if type(c) == 'string' then
        text = c
    else
        local texts = {}
        for _, b in ipairs(blocks_of(c)) do
            if b.type == 'text' then
                texts[#texts + 1] = b.text or ''
            elseif b.type == 'image' then
                local ip = image_part(b)
                if ip then images[#images + 1] = ip end
                texts[#texts + 1] = '[image attached below]'
            end
        end
        text = table.concat(texts, '\n')
    end
    if block.is_error then text = 'Error: ' .. text end
    return text, images
end

-- Append one Anthropic user message as chat messages. tool_result blocks become
-- role='tool' messages and MUST directly follow the assistant's tool_calls, so
-- they go first; any text/images in the same turn follow as one user message.
local function convert_user(out, msg)
    local parts = {}
    local tool_images = {}
    for _, b in ipairs(blocks_of(msg.content)) do
        if b.type == 'tool_result' then
            local text, images = tool_result_text(b)
            out[#out + 1] = { role = 'tool', tool_call_id = b.tool_use_id, content = text }
            for _, ip in ipairs(images) do tool_images[#tool_images + 1] = ip end
        elseif b.type == 'text' then
            parts[#parts + 1] = { type = 'text', text = b.text or '' }
        elseif b.type == 'image' then
            local ip = image_part(b)
            if ip then parts[#parts + 1] = ip end
        end
    end
    for _, ip in ipairs(tool_images) do parts[#parts + 1] = ip end
    if #parts > 0 then
        out[#out + 1] = { role = 'user', content = finish_parts(parts) }
    end
end

-- Gemini's documented placeholder for a tool call it did not sign itself
-- (history from before signatures were kept, or from another model).
local GEMINI_DUMMY_SIGNATURE = 'skip_thought_signature_validator'

function M.is_gemini(cfg, model)
    local url = tostring(cfg and cfg.base_url or ''):lower()
    local m = tostring(model or (cfg and cfg.model) or ''):lower()
    return url:find('generativelanguage%.googleapis%.com') ~= nil
        or url:find('aiplatform%.googleapis%.com') ~= nil
        or m:find('gemini', 1, true) ~= nil
end

local function has_signature(extra)
    return type(extra) == 'table' and type(extra.google) == 'table'
        and type(extra.google.thought_signature) == 'string'
end

local function convert_assistant(out, msg, cfg)
    local texts, calls, reasoning = {}, {}, {}
    local gemini = cfg._gemini
    for _, b in ipairs(blocks_of(msg.content)) do
        if b.type == 'text' then
            texts[#texts + 1] = b.text or ''
        elseif b.type == 'tool_use' then
            local call = {
                id = b.id, type = 'function',
                ['function'] = { name = b.name, arguments = common.json_encode(b.input or {}) or '{}' },
            }
            if gemini then
                -- Only the first call of a step must carry the signature.
                if has_signature(b.extra_content) then
                    call.extra_content = b.extra_content
                elseif #calls == 0 then
                    call.extra_content = { google = { thought_signature = GEMINI_DUMMY_SIGNATURE } }
                end
            end
            calls[#calls + 1] = call
        elseif b.type == 'thinking' and not b.responses_item and not b.signature and b.thinking and b.thinking ~= '' then
            -- Unsigned thinking came from a compatible server's reasoning_content
            -- (Anthropic's own thinking is always signed). DeepSeek's thinking
            -- mode rejects a tool-call continuation that omits it, so echo it
            -- back; signed blocks are meaningless to an OpenAI endpoint.
            reasoning[#reasoning + 1] = b.thinking
        end
    end
    local m = { role = 'assistant' }
    local text = table.concat(texts)
    if #calls > 0 then
        m.tool_calls = calls
        m.content = (text ~= '') and text or xutils.json_null
    else
        m.content = text
    end
    if #reasoning > 0 and cfg.echo_reasoning ~= false then
        m.reasoning_content = table.concat(reasoning, '\n')
    end
    out[#out + 1] = m
end

local function system_text(system)
    if type(system) == 'string' then return system end
    local texts = {}
    for _, b in ipairs(blocks_of(system)) do
        if b.type == 'text' then texts[#texts + 1] = b.text or '' end
    end
    return table.concat(texts, '\n')
end

-- Anthropic tools param → OpenAI function tools.
function M.convert_tools(tools)
    local out = {}
    for _, t in ipairs(tools or {}) do
        out[#out + 1] = {
            type = 'function',
            ['function'] = {
                name = t.name, description = t.description,
                parameters = t.input_schema or { type = 'object', properties = {} },
            },
        }
    end
    return out
end

local function convert_tool_choice(tc)
    if type(tc) ~= 'table' then return nil end
    if tc.type == 'auto' then return 'auto' end
    if tc.type == 'any' then return 'required' end
    if tc.type == 'none' then return 'none' end
    if tc.type == 'tool' then return { type = 'function', ['function'] = { name = tc.name } } end
    return nil
end

-- Anthropic-shaped history → chat-completions messages array.
function M.convert_messages(messages, system, cfg)
    cfg = cfg or {}
    cfg = setmetatable({ _gemini = M.is_gemini(cfg) }, { __index = cfg })
    local out = {}
    local sys = system and system_text(system) or ''
    if sys ~= '' then out[1] = { role = 'system', content = sys } end
    for _, msg in ipairs(messages or {}) do
        if msg.role == 'assistant' then
            convert_assistant(out, msg, cfg)
        else
            convert_user(out, msg)
        end
    end
    return out
end

-- Build { url, headers, body } for a streaming chat-completions request.
function M.build_request(cfg, params)
    local headers = {
        ['content-type'] = 'application/json',
        ['accept'] = 'text/event-stream',
    }
    local style = cfg.auth_style or 'bearer'
    if style == 'api-key' then
        headers['api-key'] = cfg.api_key
    elseif style == 'x-api-key' then
        headers['x-api-key'] = cfg.api_key
    else
        headers['authorization'] = 'Bearer ' .. tostring(cfg.api_key)
    end

    local model = params.model or cfg.model
    local payload = {
        model = model,
        messages = M.convert_messages(params.messages, params.system, cfg),
        stream = true,
        -- Without this the stream carries no usage at all, which blinds the
        -- context-budget anchor and compaction.
        stream_options = { include_usage = true },
    }
    payload[max_tokens_field(cfg, model)] = params.max_tokens or cfg.max_tokens or DEFAULT_MAX_TOKENS
    -- Omit (never send an empty table): json_pack encodes {} as an object.
    if params.tools and #params.tools > 0 then payload.tools = M.convert_tools(params.tools) end
    local tc = convert_tool_choice(params.tool_choice)
    if tc then payload.tool_choice = tc end

    local body = common.json_encode(payload)   -- sorted keys: a stable, cacheable prefix
    if not body or body == '' then
        -- yyjson returns nil on invalid UTF-8 (or other non-encodable data).
        error('json_pack produced an empty body (invalid UTF-8 or non-encodable value in messages)')
    end
    return { url = M.endpoint(cfg.base_url), headers = headers, body = body }
end

local STOP_REASONS = {
    stop = 'end_turn',
    tool_calls = 'tool_use',
    function_call = 'tool_use',
    length = 'max_tokens',
    content_filter = 'refusal',
}

-- JSON null decodes to a sentinel userdata; treat it (and anything non-string)
-- as absent.
local function str(v) return type(v) == 'string' and v or nil end

-- ── SSE → assistant-message reassembler ────────────────────────────────────
-- Same contract as anthropic.new_decoder: cb = { on_text, on_tool_use_start,
-- on_tool_input, on_done, on_error }; result = { message, usage, stop_reason, id }.
function M.new_decoder(cb)
    cb = cb or {}
    local self = {
        blocks = {},          -- content blocks in arrival order
        text_block = nil,     -- current text block (appended to)
        think_block = nil,    -- current thinking block
        tools = {},           -- tool_calls index -> { block, args, started }
        tool_order = {},      -- tool_calls indices in arrival order
        tool_ids = {},        -- server call id -> index (for deltas without one)
        last_tool = nil,      -- index of the most recent call
        usage = { input_tokens = 0, output_tokens = 0 },
        got_usage = false,    -- did the server report usage at all?
        stop_reason = '',
        got_done = false,     -- saw the `data: [DONE]` terminator
        message_id = '',
        errored = false,
        finished = false,
        got_any = false,
    }

    local function fail(msg)
        self.errored = true
        if cb.on_error then cb.on_error(msg) end
    end

    local function set_usage(u)
        self.got_usage = true
        local prompt = tonumber(u.prompt_tokens) or 0
        -- OpenAI reports cache hits under prompt_tokens_details; DeepSeek uses
        -- its own field. Both are INCLUDED in prompt_tokens, so split them out:
        -- the budget sums input + cache_read, and must not count them twice.
        local details = type(u.prompt_tokens_details) == 'table' and u.prompt_tokens_details or {}
        local cached = tonumber(details.cached_tokens) or tonumber(u.prompt_cache_hit_tokens) or 0
        self.usage.input_tokens = math.max(0, prompt - cached)
        self.usage.output_tokens = tonumber(u.completion_tokens) or 0
        self.usage.cache_read_input_tokens = (cached > 0) and cached or nil
    end

    -- Slot for a delta that has no `index`. Gemini omits it and sends each
    -- parallel call whole in its own delta, so calls are told apart by id; an
    -- id-less fragment continues the latest call. Defaulting every such delta
    -- to slot 0 would glue the calls' arguments into invalid JSON.
    local function index_without(tc, pos)
        local id = str(tc.id)
        if id and id ~= '' then
            if self.tool_ids[id] then return self.tool_ids[id] end
            return #self.tool_order
        end
        if pos == 1 and self.last_tool then return self.last_tool end
        return #self.tool_order
    end

    local function on_tool_delta(tc, pos)
        local i = tonumber(tc.index) or index_without(tc, pos)
        local fn = type(tc['function']) == 'table' and tc['function'] or {}
        local slot = self.tools[i]
        if not slot then
            -- A few servers (Gemini's compat layer, some vLLM builds) send an
            -- empty id; the id only has to pair tool_use with tool_result.
            local id = str(tc.id)
            if id and id ~= '' then self.tool_ids[id] = i end
            if not id or id == '' then id = 'call_' .. i .. '_' .. tostring(os.time()) end
            slot = { block = { type = 'tool_use', id = id, name = '', input = {} }, args = {} }
            self.tools[i] = slot
            self.tool_order[#self.tool_order + 1] = i
            self.blocks[#self.blocks + 1] = slot.block
            self.text_block, self.think_block = nil, nil
        end
        self.last_tool = i
        if type(tc.extra_content) == 'table' then slot.block.extra_content = tc.extra_content end
        local name = str(fn.name)
        if name and name ~= '' and slot.block.name == '' then slot.block.name = name end
        if not slot.started and slot.block.name ~= '' then
            slot.started = true
            if cb.on_tool_use_start then cb.on_tool_use_start(slot.block.id, slot.block.name) end
        end
        local frag = str(fn.arguments)
        if frag and frag ~= '' then
            slot.args[#slot.args + 1] = frag
            if cb.on_tool_input then cb.on_tool_input(slot.block.id, frag) end
        end
    end

    function self:on_sse(_event, data)
        if self.finished or self.errored then return end
        if not data or data == '' then return end
        if data == '[DONE]' then self.got_done = true; return self:finish() end
        local ok, ev = pcall(xutils.json_unpack, data)
        if not ok or type(ev) ~= 'table' then return end

        if type(ev.error) == 'table' or str(ev.error) then
            local e = ev.error
            return fail(type(e) == 'table' and (str(e.message) or 'api error') or e)
        end
        self.got_any = true
        if str(ev.id) and self.message_id == '' then self.message_id = ev.id end
        if type(ev.usage) == 'table' then set_usage(ev.usage) end

        local choices = type(ev.choices) == 'table' and ev.choices or {}
        local choice = choices[1]
        if type(choice) ~= 'table' then return end
        local d = type(choice.delta) == 'table' and choice.delta or {}

        local reasoning = str(d.reasoning_content) or str(d.reasoning)
        if reasoning and reasoning ~= '' then
            if not self.think_block then
                self.think_block = { type = 'thinking', thinking = '' }
                self.blocks[#self.blocks + 1] = self.think_block
                self.text_block = nil
            end
            self.think_block.thinking = self.think_block.thinking .. reasoning
        end

        -- A refusal streams in its own field instead of content; show it like
        -- text rather than ending the turn with an empty reply.
        local refusal = str(d.refusal)
        if refusal and refusal ~= '' then self.refused = true end
        local text = str(d.content)
        if refusal and refusal ~= '' then text = (text or '') .. refusal end
        if text and text ~= '' then
            if not self.text_block then
                self.text_block = { type = 'text', text = '' }
                self.blocks[#self.blocks + 1] = self.text_block
                self.think_block = nil
            end
            self.text_block.text = self.text_block.text .. text
            if cb.on_text then cb.on_text(text) end
        end

        if type(d.tool_calls) == 'table' then
            for pos, tc in ipairs(d.tool_calls) do
                if type(tc) == 'table' then on_tool_delta(tc, pos) end
            end
        end

        local fr = str(choice.finish_reason)
        if fr then
            self.got_finish = true
            self.stop_reason = STOP_REASONS[fr] or fr
        end
        -- Don't finish on finish_reason: the usage chunk (include_usage) comes
        -- AFTER it, and [DONE] after that.
    end

    function self:finish()
        if self.finished or self.errored then return end
        self.finished = true
        if not self.got_any then
            if cb.on_error then
                cb.on_error('no response from model: the connection closed before any data ' ..
                    '(possible malformed request, bad UTF-8 in the prompt, or network error)')
            end
            return
        end
        -- The connection closed mid-response (neither a finish_reason nor
        -- [DONE] arrived). Reporting that as a normal end would hand the loop
        -- truncated text, or worse, tool calls whose arguments may be cut off
        -- and would then be EXECUTED. Fail instead; the runner retries if
        -- nothing was surfaced yet.
        if not self.got_finish and not self.got_done then
            self.finished = false
            self.errored = true
            if cb.on_error then
                cb.on_error('stream ended before the response completed (no finish_reason); ' ..
                    'the connection was probably dropped')
            end
            return
        end
        for _, i in ipairs(self.tool_order) do
            local slot = self.tools[i]
            slot.block.input = common.parse_tool_input(table.concat(slot.args), slot.block.name)
        end
        -- Some servers answer finish_reason='stop' even when they emitted tool
        -- calls; the loop keys on 'tool_use', so trust the calls themselves.
        local reason = self.stop_reason
        if #self.tool_order > 0 and reason ~= 'max_tokens' then reason = 'tool_use' end
        if self.refused and reason == 'end_turn' then reason = 'refusal' end
        if reason == '' then reason = 'end_turn' end
        if cb.on_done then
            cb.on_done({
                message = { role = 'assistant', content = self.blocks },
                usage = self.usage,
                -- Some compatible servers ignore stream_options.include_usage.
                -- Zeros here are "unknown", not "empty": the loop must not
                -- anchor the context budget on them.
                usage_missing = (not self.got_usage) or nil,
                stop_reason = reason,
                id = self.message_id,
            })
        end
    end

    return self
end

-- stream_message(cfg, params, cb) — see common.stream_message for cb/params.
function M.stream_message(cfg, params, cb)
    return common.stream_message(M, cfg, params, cb)
end

return M
