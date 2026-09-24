-- Responses wire codec. Internal history stays in the agent's block format.
local json = require('xutils')
local common = require('xagent.llm.common')
local M = {}

function M.endpoint(base)
    base = (base or 'https://api.openai.com/v1'):gsub('/+$', '')
    if base:match('/responses$') then return base end
    if base:match('/v%d+$') then return base .. '/responses' end
    return base .. '/v1/responses'
end

local function blocks(value)
    if type(value) == 'string' then return {{ type = 'text', text = value }} end
    return type(value) == 'table' and value or {}
end

local function text_of(value)
    if type(value) == 'string' then return value end
    local out = {}
    for _, b in ipairs(blocks(value)) do
        if b.type == 'text' then out[#out + 1] = b.text or '' end
    end
    return table.concat(out, '\n')
end

local function image_part(b)
    local s = b.source or {}
    local url = s.type == 'url' and s.url
        or (s.type == 'base64' and ('data:' .. (s.media_type or 'image/png') .. ';base64,' .. (s.data or '')))
    if url then return { type = 'input_image', image_url = url } end
end

function M.convert_messages(messages)
    local out = {}
    for _, msg in ipairs(messages or {}) do
        local parts = {}
        local function flush()
            if #parts > 0 then
                out[#out + 1] = { role = msg.role, content = parts }
                parts = {}
            end
        end
        for _, b in ipairs(blocks(msg.content)) do
            if b.type == 'text' then
                parts[#parts + 1] = { type = msg.role == 'assistant' and 'output_text' or 'input_text', text = b.text or '' }
            elseif b.type == 'image' and msg.role == 'user' then
                local p = image_part(b); if p then parts[#parts + 1] = p end
            elseif b.type == 'tool_use' then
                flush()
                out[#out + 1] = { type = 'function_call', call_id = b.id, name = b.name,
                    arguments = json.json_pack(b.input or {}) }
            elseif b.type == 'tool_result' then
                flush()
                out[#out + 1] = { type = 'function_call_output', call_id = b.tool_use_id,
                    output = text_of(b.content) }
                for _, p in ipairs(blocks(b.content)) do
                    if p.type == 'image' then
                        local img = image_part(p)
                        if img then out[#out + 1] = { role = 'user', content = {img} } end
                    end
                end
            elseif b.type == 'thinking' and type(b.responses_item) == 'table' then
                flush()
                out[#out + 1] = b.responses_item
            end
        end
        flush()
    end
    return out
end

function M.build_request(cfg, params)
    local codex = cfg.auth_type == 'chatgpt'
    local body = { model = params.model or cfg.model, input = M.convert_messages(params.messages),
        instructions = text_of(params.system), stream = true, store = false,
        include = { 'reasoning.encrypted_content' } }
    if not codex then body.max_output_tokens = params.max_tokens or cfg.max_tokens or 4096 end
    if cfg.reasoning_effort and cfg.reasoning_effort ~= '' then body.reasoning = { effort = cfg.reasoning_effort } end
    if params.tools and #params.tools > 0 then
        body.tools = {}
        for _, t in ipairs(params.tools) do
            body.tools[#body.tools + 1] = { type = 'function', name = t.name, description = t.description,
                parameters = t.input_schema, strict = false }
        end
        body.parallel_tool_calls = true
    end
    local choice = params.tool_choice
    if type(choice) == 'table' then
        if choice.type == 'tool' then body.tool_choice = { type = 'function', name = choice.name }
        elseif choice.type == 'any' then body.tool_choice = 'required'
        else body.tool_choice = choice.type end
    end
    local headers = { ['Content-Type'] = 'application/json', Accept = 'text/event-stream',
        Authorization = 'Bearer ' .. tostring(cfg.api_key or '') }
    if cfg.account_id then headers['ChatGPT-Account-Id'] = cfg.account_id end
    -- Lua's JSON codec encodes an empty table as {}. Responses requires arrays
    -- for input and reasoning.summary, including after a history reload.
    local encode = common.json_encode or json.json_pack
    local input = {}
    for _, value in ipairs(body.input) do
        if value.type == 'reasoning' and (not value.summary or #value.summary == 0) then
            local copy = {}; for k, v in pairs(value) do if k ~= 'summary' then copy[k] = v end end
            input[#input + 1] = assert(encode(copy)):sub(1, -2) .. ',"summary":[]}'
        else input[#input + 1] = assert(encode(value)) end
    end
    body.input = nil
    local encoded = assert(encode(body)):sub(1, -2) .. ',"input":[' .. table.concat(input, ',') .. ']}'
    return { url = codex and 'https://chatgpt.com/backend-api/codex/responses' or M.endpoint(cfg.base_url),
        headers = headers, body = encoded }
end

function M.new_decoder(cb)
    cb = cb or {}
    local self = { slots = {}, closed = false }
    local function fail(message)
        if self.closed then return end
        self.closed = true
        if cb.on_error then cb.on_error(message) end
    end
    local function slot(index)
        index = tonumber(index) or 0
        if not self.slots[index] then self.slots[index] = { texts = {}, args = '' } end
        return self.slots[index]
    end
    local function item(index, value)
        local s = slot(index)
        s.item = value
        if value.type == 'function_call' and not s.started then
            s.started = true
            if cb.on_tool_use_start then cb.on_tool_use_start(value.call_id, value.name) end
        end
        return s
    end
    local function complete(r, incomplete)
        -- Final output is authoritative; also handles servers that omit deltas.
        for i, value in ipairs(r.output or {}) do item(i - 1, value) end
        local content, keys, tools = {}, {}, false
        for k in pairs(self.slots) do keys[#keys + 1] = k end
        table.sort(keys)
        for _, k in ipairs(keys) do
            local s = self.slots[k]
            local v = s.item or {}
            if v.type == 'function_call' then
                if type(v.call_id) ~= 'string' or v.call_id == '' or type(v.name) ~= 'string' or v.name == '' then
                    return fail('Responses returned an invalid tool call')
                end
                tools = true
                content[#content + 1] = { type = 'tool_use', id = v.call_id, name = v.name,
                    input = common.parse_tool_input((v.arguments and v.arguments ~= '') and v.arguments or s.args, v.name) }
            elseif v.type == 'reasoning' then
                local summary = {}
                for _, p in ipairs(v.summary or {}) do summary[#summary + 1] = p.text or '' end
                content[#content + 1] = { type = 'thinking', thinking = table.concat(summary, '\n'),
                    responses_item = v }
            else
                local parts = v.content or {}
                if #parts == 0 then
                    local indices = {}; for n in pairs(s.texts) do indices[#indices + 1] = n end
                    table.sort(indices)
                    for _, n in ipairs(indices) do parts[#parts + 1] = { text = s.texts[n] } end
                end
                for n, p in ipairs(parts) do
                    local text = p.text or p.refusal or ''
                    content[#content + 1] = { type = 'text', text = text }
                    local streamed = s.texts[n - 1] or ''
                    if #text > #streamed and text:sub(1, #streamed) == streamed and cb.on_text then
                        cb.on_text(text:sub(#streamed + 1))
                    end
                end
            end
        end
        local u = r.usage or {}
        local cached = (u.input_tokens_details or {}).cached_tokens or 0
        self.closed = true
        if cb.on_done then cb.on_done({ message = { role = 'assistant', content = content }, id = r.id,
            stop_reason = incomplete and 'max_tokens' or (tools and 'tool_use' or 'end_turn'),
            usage_missing = not r.usage or nil,
            usage = { input_tokens = math.max(0, (u.input_tokens or 0) - cached), output_tokens = u.output_tokens or 0,
                cache_read_input_tokens = cached > 0 and cached or nil } }) end
    end
    function self:on_sse(event, data)
        if self.closed or data == '[DONE]' then return end
        local ok, e = pcall(json.json_unpack, data or '')
        if not ok or type(e) ~= 'table' then return fail('Invalid Responses stream JSON') end
        local kind = e.type or event
        if kind == 'response.output_item.added' or kind == 'response.output_item.done' then
            if type(e.item) == 'table' then item(e.output_index, e.item) end
        elseif kind == 'response.output_text.delta' or kind == 'response.refusal.delta' then
            local s, n = slot(e.output_index), e.content_index or 0
            s.texts[n] = (s.texts[n] or '') .. (e.delta or '')
            if cb.on_text then cb.on_text(e.delta or '') end
        elseif kind == 'response.function_call_arguments.delta' then
            local s = slot(e.output_index); s.args = s.args .. (e.delta or '')
            if s.item and cb.on_tool_input then cb.on_tool_input(s.item.call_id, e.delta or '') end
        elseif kind == 'response.function_call_arguments.done' then
            local s = slot(e.output_index); s.args = e.arguments or s.args
            if s.item then s.item.arguments = s.args end
        elseif kind == 'response.completed' then complete(e.response or {})
        elseif kind == 'response.incomplete' then
            local r = e.response or {}
            if (r.incomplete_details or {}).reason == 'max_output_tokens' then complete(r, true)
            else fail('Responses incomplete: ' .. tostring((r.incomplete_details or {}).reason)) end
        elseif kind == 'response.failed' or kind == 'error' then
            local err = e.error or (e.response or {}).error or e
            fail(type(err) == 'table' and (err.message or 'Responses request failed') or tostring(err))
        end
    end
    function self:finish()
        if not self.closed then fail('Responses stream ended before completion; tool calls were not executed') end
    end
    return self
end

function M.stream_message(cfg, params, cb)
    return common.stream_message(M, cfg, params, cb)
end
return M
