-- xagent/llm/anthropic.lua — Anthropic Messages API: request build + SSE decode.
--
-- Turns the raw SSE event stream (message_start / content_block_* /
-- message_delta / message_stop) into assembled assistant content blocks, while
-- surfacing incremental text/tool events as they arrive. Transport is delegated
-- to llm/stream.lua.
--
-- Config (cfg): { api_key, base_url?, model?, verify?, ca_file?, auth_style? }
--   auth_style: 'x-api-key' (default) or 'bearer' (some compatible endpoints).

local stream = dofile('scripts/core/share/xhttp_stream.lua')
local xutils = require('xutils')

local M = {}

local DEFAULT_BASE = 'https://api.anthropic.com'
local DEFAULT_MAX_TOKENS = 4096
local ANTHROPIC_VERSION = '2023-06-01'

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

    local payload = {
        model = params.model or cfg.model,
        max_tokens = params.max_tokens or cfg.max_tokens or DEFAULT_MAX_TOKENS,
        messages = params.messages,
        stream = true,
    }
    if params.system then payload.system = params.system end
    if params.tools and #params.tools > 0 then payload.tools = params.tools end
    if params.tool_choice then payload.tool_choice = params.tool_choice end

    local body = xutils.json_pack(payload)
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
                local acc = self.tool_json[i] or ''
                if acc ~= '' then
                    local ok2, parsed = pcall(xutils.json_unpack, acc)
                    b.input = (ok2 and type(parsed) == 'table') and parsed or { _raw = acc }
                end
            end

        elseif t == 'message_delta' then
            if ev.usage and ev.usage.output_tokens then
                self.usage.output_tokens = ev.usage.output_tokens
            end
            if ev.delta and ev.delta.stop_reason then
                self.stop_reason = ev.delta.stop_reason
            end

        elseif t == 'message_stop' then
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

local function format_http_error(status, body)
    local msg = body or ''
    local ok, parsed = pcall(xutils.json_unpack, body or '')
    if ok and type(parsed) == 'table' and parsed.error and parsed.error.message then
        msg = parsed.error.message
    end
    if #tostring(msg) > 500 then msg = tostring(msg):sub(1, 500) .. '...' end
    return string.format('HTTP %s: %s', tostring(status), msg)
end

-- ── one streaming request, with retry on transient failures ────────────────
-- stream_message(cfg, params, cb) — cb same shape as new_decoder's cb.
--   params = { messages, system?, tools?, model?, max_tokens?, tool_choice? }
-- Retries (up to cfg.max_retries, default 2) when the connection drops before
-- ANY content is surfaced — a connection reset, a 5xx, or a 429. This is safe
-- because nothing was shown yet, so a re-run can't duplicate visible output.
-- A 4xx (other than 429) is a real client error and is surfaced immediately.
function M.stream_message(cfg, params, cb)
    cb = cb or {}
    local max_retries = tonumber(cfg.max_retries) or 2

    local attempt
    attempt = function(n)
        local ok, req = pcall(M.build_request, cfg, params)
        if not ok then
            if cb.on_error then cb.on_error(tostring(req)) end
            return
        end

        local got_content = false
        local function retry_or_fail(msg, transient)
            if transient and not got_content and n < max_retries then
                attempt(n + 1)            -- immediate re-attempt (fresh connection)
            elseif cb.on_error then
                cb.on_error(msg)
            end
        end

        local decoder = M.new_decoder({
            on_text = function(t) got_content = true; if cb.on_text then cb.on_text(t) end end,
            on_tool_use_start = function(id, name)
                got_content = true
                if cb.on_tool_use_start then cb.on_tool_use_start(id, name) end
            end,
            on_tool_input = cb.on_tool_input,
            on_done = function(r) if cb.on_done then cb.on_done(r) end end,
            -- decoder errors include the "connection closed before any data"
            -- case (got_any=false) and SSE `error` events — both transient.
            on_error = function(m) retry_or_fail(m, true) end,
        })

        stream.request({
            url = req.url, method = 'POST', headers = req.headers, body = req.body,
            verify = cfg.verify, ca_file = cfg.ca_file,
        }, {
            on_sse = function(event, data) decoder:on_sse(event, data) end,
            on_done = function() decoder:finish() end,   -- close before message_stop
            on_error = function(err) retry_or_fail('connection error: ' .. tostring(err), true) end,
            on_http_error = function(status, body)
                local transient = (status == 429 or status >= 500)
                retry_or_fail(format_http_error(status, body), transient)
            end,
        })
    end

    attempt(0)
end

return M
