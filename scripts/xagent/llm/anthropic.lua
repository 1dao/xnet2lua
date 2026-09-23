-- xagent/llm/anthropic.lua — Anthropic Messages API: request build + SSE decode.
--
-- Turns the raw SSE event stream (message_start / content_block_* /
-- message_delta / message_stop) into assembled assistant content blocks, while
-- surfacing incremental text/tool events as they arrive. Transport and retry
-- live in llm/common.lua.
--
-- Config (cfg): { api_key, base_url?, model?, verify?, ca_file?, auth_style? }
--   auth_style: 'x-api-key' (default) or 'bearer' (some compatible endpoints).

local xutils = require('xutils')
local common = require('xagent.llm.common')

local M = {}

local DEFAULT_BASE = 'https://api.anthropic.com'
local DEFAULT_MAX_TOKENS = 4096
local ANTHROPIC_VERSION = '2023-06-01'

-- History may hold tool_use blocks decoded by the OpenAI codec, which keeps
-- Gemini's thought signature on them as `extra_content` (a tab can switch
-- models mid-conversation). Anthropic rejects unknown block fields, so send a
-- copy without it; untouched messages are passed through as-is.
local function wire_messages(messages)
    local out = {}
    for i, m in ipairs(messages or {}) do
        local c = m.content
        if type(c) == 'table' then
            local nc
            for j, b in ipairs(c) do
                if type(b) == 'table' and b.extra_content ~= nil then
                    nc = nc or table.move(c, 1, #c, 1, {})
                    local nb = {}
                    for k, v in pairs(b) do nb[k] = v end
                    nb.extra_content = nil
                    nc[j] = nb
                end
            end
            if nc then
                local nm = {}
                for k, v in pairs(m) do nm[k] = v end
                nm.content = nc
                m = nm
            end
        end
        out[i] = m
    end
    return out
end
M._wire_messages = wire_messages

-- ── prompt caching ─────────────────────────────────────────────────────────
-- Every tool round-trip resends system + tools + the whole history, so the
-- cached-prefix price is what a long session really costs. Endpoints that cache
-- only on request (Anthropic, Qwen on Bailian) need explicit breakpoints; ones
-- that cache automatically (DeepSeek) ignore the field. Two breakpoints: the
-- system prompt (covers tools too — they render before it) and the newest
-- message, whose cached prefix the next turn reads back via lookback.
-- cfg.prompt_cache == false turns this off for a gateway that rejects the field.
local EPHEMERAL = { type = 'ephemeral' }

local function cached_system(system)
    if type(system) == 'string' then
        if system == '' then return system end
        return { { type = 'text', text = system, cache_control = EPHEMERAL } }
    end
    return system
end

-- Blocks that may not carry cache_control.
local UNCACHEABLE = { thinking = true, redacted_thinking = true }

-- Copy of `messages` with a breakpoint on the last cacheable block of the final
-- message. Earlier messages are shared untouched; the history is never mutated.
local function cache_last_message(messages)
    local n = #messages
    if n == 0 then return messages end
    local last = messages[n]
    local content = last.content
    if type(content) == 'string' then
        if content == '' then return messages end
        content = { { type = 'text', text = content } }
    elseif type(content) ~= 'table' or #content == 0 then
        return messages
    end
    local k = #content
    while k > 0 and (type(content[k]) ~= 'table' or UNCACHEABLE[content[k].type]) do k = k - 1 end
    if k == 0 then return messages end

    local nc = table.move(content, 1, #content, 1, {})
    local nb = {}
    for key, v in pairs(content[k]) do nb[key] = v end
    nb.cache_control = EPHEMERAL
    nc[k] = nb
    local nm = {}
    for key, v in pairs(last) do nm[key] = v end
    nm.content = nc
    local out = table.move(messages, 1, n - 1, 1, {})
    out[n] = nm
    return out
end
M._cache_last_message = cache_last_message

-- Build { url, headers, body } for a streaming Messages request.
function M.build_request(cfg, params)
    local base = (cfg.base_url or DEFAULT_BASE):gsub('/+$', '')
    local headers = {
        ['anthropic-version'] = ANTHROPIC_VERSION,
        ['content-type'] = 'application/json',
        ['accept'] = 'text/event-stream',
    }
    if (cfg.auth_style or 'x-api-key') == 'bearer' then
        headers['authorization'] = 'Bearer ' .. tostring(cfg.api_key)
    else
        headers['x-api-key'] = cfg.api_key
    end

    local cache = cfg.prompt_cache ~= false
    local messages = wire_messages(params.messages)
    if cache then messages = cache_last_message(messages) end
    local payload = {
        model = params.model or cfg.model,
        max_tokens = params.max_tokens or cfg.max_tokens or DEFAULT_MAX_TOKENS,
        messages = messages,
        stream = true,
    }
    if params.system then
        payload.system = cache and cached_system(params.system) or params.system
    end
    if params.tools and #params.tools > 0 then payload.tools = params.tools end
    if params.tool_choice then payload.tool_choice = params.tool_choice end

    local body = common.json_encode(payload)   -- sorted keys: a stable, cacheable prefix
    if not body or body == '' then
        -- yyjson returns nil on invalid UTF-8 (or other non-encodable data).
        -- Surfacing this beats sending an empty body and getting a cryptic 400.
        error('json_pack produced an empty body (invalid UTF-8 or non-encodable value in messages)')
    end
    return {
        url = base .. '/v1/messages',
        headers = headers,
        body = body,
    }
end

-- ── SSE → assistant-message reassembler ────────────────────────────────────
-- new_decoder(cb) -> object with :on_sse(event, data) and :finish()
--   cb = { on_text(delta), on_tool_use_start(id, name), on_tool_input(id, frag),
--          on_done(result), on_error(msg) }
--   result = { message = {role='assistant', content={...}}, usage, stop_reason, id }
function M.new_decoder(cb)
    cb = cb or {}
    local self = {
        blocks = {},          -- index(0-based) -> content block
        tool_json = {},       -- index -> accumulated input_json string
        max_index = -1,
        usage = { input_tokens = 0, output_tokens = 0 },
        stop_reason = '',
        message_id = '',
        errored = false,
        finished = false,
        got_any = false,    -- did we see any real stream event?
    }

    local function note_index(i)
        if i and i > self.max_index then self.max_index = i end
    end

    function self:on_sse(event, data)
        if self.finished or self.errored then return end
        if not data or data == '' then return end
        local ok, ev = pcall(xutils.json_unpack, data)
        if not ok or type(ev) ~= 'table' then return end
        local t = ev.type

        self.got_any = true

        if t == 'message_start' then
            local m = ev.message
            if m then
                self.message_id = m.id or ''
                local u = m.usage
                if u then
                    self.usage.input_tokens = u.input_tokens or 0
                    self.usage.output_tokens = u.output_tokens or 0
                    self.usage.cache_creation_input_tokens = u.cache_creation_input_tokens
                    self.usage.cache_read_input_tokens = u.cache_read_input_tokens
                end
            end

        elseif t == 'content_block_start' then
            local i = ev.index
            note_index(i)
            local b = ev.content_block or {}
            if b.type == 'text' then
                self.blocks[i] = { type = 'text', text = '' }
            elseif b.type == 'thinking' then
                self.blocks[i] = { type = 'thinking', thinking = b.thinking or '' }
            elseif b.type == 'tool_use' then
                self.blocks[i] = { type = 'tool_use', id = b.id, name = b.name, input = {} }
                self.tool_json[i] = ''
                if cb.on_tool_use_start then cb.on_tool_use_start(b.id, b.name) end
            end

        elseif t == 'content_block_delta' then
            local i = ev.index
            local d = ev.delta or {}
            if d.type == 'text_delta' then
                local b = self.blocks[i]
                if b then b.text = (b.text or '') .. (d.text or '') end
                if cb.on_text then cb.on_text(d.text or '') end
            elseif d.type == 'input_json_delta' then
                self.tool_json[i] = (self.tool_json[i] or '') .. (d.partial_json or '')
                local b = self.blocks[i]
                if b and cb.on_tool_input then cb.on_tool_input(b.id, d.partial_json or '') end
            elseif d.type == 'thinking_delta' then
                local b = self.blocks[i]
                if b then b.thinking = (b.thinking or '') .. (d.thinking or '') end
            elseif d.type == 'signature_delta' then
                local b = self.blocks[i]
                if b then b.signature = (b.signature or '') .. (d.signature or '') end
            end

        elseif t == 'content_block_stop' then
            local i = ev.index
            local b = self.blocks[i]
            if b and b.type == 'tool_use' then
                b.input = common.parse_tool_input(self.tool_json[i], b.name)
            end

        elseif t == 'message_delta' then
            if ev.usage and ev.usage.output_tokens then
                self.usage.output_tokens = ev.usage.output_tokens
            end
            if ev.delta and ev.delta.stop_reason then
                self.stop_reason = ev.delta.stop_reason
            end

        elseif t == 'message_stop' then
            self.got_stop = true
            self:finish()

        elseif t == 'error' then
            self.errored = true
            local msg = (ev.error and ev.error.message) or 'api error'
            if cb.on_error then cb.on_error(msg) end
        end
    end

    function self:finish()
        if self.finished or self.errored then return end
        self.finished = true
        if not self.got_any then
            -- Stream closed without delivering a single event — almost always a
            -- connection reset (malformed request, bad bytes, network drop).
            if cb.on_error then
                cb.on_error('no response from model: the connection closed before any data ' ..
                    '(possible malformed request, bad UTF-8 in the prompt, or network error)')
            end
            return
        end
        -- Closed mid-response: no message_stop and no stop_reason (message_delta)
        -- — some gateways skip message_stop, so either one counts as complete.
        -- Without this, truncated text would end the turn as if normal, and a
        -- tool_use whose input may be cut off would be executed.
        if not self.got_stop and self.stop_reason == '' then
            self.errored = true
            if cb.on_error then
                cb.on_error('stream ended before the response completed (no stop_reason); ' ..
                    'the connection was probably dropped')
            end
            return
        end
        local content = {}
        for i = 0, self.max_index do
            if self.blocks[i] then content[#content + 1] = self.blocks[i] end
        end
        if cb.on_done then
            cb.on_done({
                message = { role = 'assistant', content = content },
                usage = self.usage,
                stop_reason = self.stop_reason,
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
