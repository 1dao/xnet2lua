-- xagent/llm/common.lua — pieces shared by every wire-protocol adapter.
--
-- Each adapter (anthropic.lua, openai.lua) is a "codec": build_request(cfg,
-- params) -> { url, headers, body } and new_decoder(cb) -> { on_sse, finish }.
-- The decoder always reports an Anthropic-shaped result (content blocks,
-- stop_reason 'end_turn'|'tool_use'|'max_tokens', usage.input_tokens/...),
-- which is the one internal format the loop, session and tools understand.
-- This module owns what doesn't depend on the protocol: the retry policy, the
-- API-log bookkeeping, and turning an accumulated tool-argument string into an
-- input table.

local stream = dofile('scripts/core/share/xhttp_stream.lua')
local xutils = require('xutils')
local api_log = require('xagent.llm.api_log')

local M = {}

-- ── canonical request JSON ─────────────────────────────────────────────────
-- json_pack emits object keys in Lua hash order, and LuaJIT seeds its string
-- hash per process: the same tools schema or history block serializes with a
-- different key order after every restart, so the provider's prompt cache
-- (keyed on the exact prefix) misses the whole conversation on the first
-- request. Encode request bodies with object keys sorted instead. Leaves still
-- go through json_pack, so numbers/strings are byte-identical to before and
-- invalid UTF-8 still fails the encode (nil) exactly as json_pack does. Table
-- shape follows json_pack: consecutive integer keys 1..n (n > 0) are an
-- array, anything else (including {}) an object; json_null is null.
local json_null = xutils.json_null

local function encode(v, out)
    if v == json_null then out[#out + 1] = 'null'; return true end
    if type(v) ~= 'table' then
        local s = xutils.json_pack(v)
        if not s then return false end
        out[#out + 1] = s
        return true
    end
    local n, count, array = #v, 0, true
    for k in pairs(v) do
        count = count + 1
        if type(k) ~= 'number' or k < 1 or k > n or k % 1 ~= 0 then array = false end
    end
    if array and n > 0 and count == n then
        out[#out + 1] = '['
        for i = 1, n do
            if i > 1 then out[#out + 1] = ',' end
            if not encode(v[i], out) then return false end
        end
        out[#out + 1] = ']'
        return true
    end
    local keys = {}
    for k in pairs(v) do keys[#keys + 1] = tostring(k) end
    table.sort(keys)
    local lookup = {}
    for k, val in pairs(v) do lookup[tostring(k)] = val end
    out[#out + 1] = '{'
    for i, k in ipairs(keys) do
        if i > 1 then out[#out + 1] = ',' end
        local ks = xutils.json_pack(k)
        if not ks then return false end
        out[#out + 1] = ks
        out[#out + 1] = ':'
        if not encode(lookup[k], out) then return false end
    end
    out[#out + 1] = '}'
    return true
end

-- json_encode(value) -> string | nil. Deterministic json_pack (sorted keys).
function M.json_encode(value)
    local out = {}
    if not encode(value, out) then return nil end
    return table.concat(out)
end

-- Parse a tool call's accumulated JSON arguments. On failure, DON'T swallow the
-- reason: json_unpack returns (nil, "json unpack error at <pos>: <msg>"); a
-- raised error comes back as parsed. Keep both _raw and _error so tools_run can
-- surface the real cause to the model instead of a misleading "X is required"
-- (which the model just blindly retries → infinite loop).
function M.parse_tool_input(acc, tool_name)
    if acc == nil or acc == '' then return {} end
    local ok, parsed, perr = pcall(xutils.json_unpack, acc)
    if ok and type(parsed) == 'table' then return parsed end
    local reason = (not ok) and tostring(parsed) or tostring(perr or 'invalid json')
    -- Diagnostic dump (latest failure) for root-causing: the offending byte
    -- region around err.pos reveals invalid UTF-8 vs. an unescaped control char
    -- vs. truncation.
    pcall(function()
        local f = io.open('tool_json_fail.txt', 'wb')
        if not f then return end
        f:write('tool: ', tostring(tool_name), '\n')
        f:write('error: ', reason, '\n')
        f:write('acc_len: ', tostring(#acc), '\n')
        local pos = tonumber(reason:match('at (%d+)'))
        if pos and pos >= 1 then
            local a = math.max(1, pos - 80)
            local z = math.min(#acc, pos + 80)
            f:write('context[', a, '..', z, ']:\n', acc:sub(a, z), '\n')
            f:write('hex around pos ', pos, ':\n')
            for k = math.max(1, pos - 16), math.min(#acc, pos + 16) do
                f:write(string.format('%02X ', acc:byte(k)))
            end
            f:write('\n')
        end
        f:write('--- full acc ---\n', acc, '\n')
        f:close()
    end)
    return { _raw = acc, _error = reason }
end

-- Both Anthropic and OpenAI wrap HTTP errors as { error = { message = ... } };
-- Gemini's OpenAI-compat layer wraps that object in a one-element array.
function M.format_http_error(status, body)
    local msg = body or ''
    local ok, parsed = pcall(xutils.json_unpack, body or '')
    if ok and type(parsed) == 'table' and type(parsed[1]) == 'table' and parsed.error == nil then
        parsed = parsed[1]
    end
    if ok and type(parsed) == 'table' and type(parsed.error) == 'table'
        and type(parsed.error.message) == 'string' then
        msg = parsed.error.message
    end
    if #tostring(msg) > 500 then msg = tostring(msg):sub(1, 500) .. '...' end
    return string.format('HTTP %s: %s', tostring(status), msg)
end

-- ── one streaming request, with retry on transient failures ────────────────
-- stream_message(codec, cfg, params, cb)
--   cb = { on_text(delta), on_tool_use_start(id, name), on_tool_input(id, frag),
--          on_done(result), on_error(msg) }
--   params = { messages, system?, tools?, model?, max_tokens?, tool_choice? }
-- Retries (up to cfg.max_retries, default 2) when the connection drops before
-- ANY content is surfaced — a connection reset, a 5xx, or a 429. This is safe
-- because nothing was shown yet, so a re-run can't duplicate visible output.
-- A 4xx (other than 429) is a real client error and is surfaced immediately.
function M.stream_message(codec, cfg, params, cb)
    cb = cb or {}
    local max_retries = tonumber(cfg.max_retries) or 2

    local attempt
    attempt = function(n)
        local ok, req = pcall(codec.build_request, cfg, params)
        if not ok then
            if cb.on_error then cb.on_error(tostring(req)) end
            return
        end

        -- Record this HTTP attempt (in-memory, for the GUI's "API 记录" panel).
        -- Each attempt is its own entry, so retried/dropped requests show up too.
        local rec = api_log.begin({
            model = params.model or cfg.model, url = req.url, method = 'POST',
            body = req.body, headers = req.headers,
        })

        local got_content = false
        local function retry_or_fail(msg, transient)
            api_log.fail(rec, { error = msg })
            if transient and not got_content and n < max_retries then
                attempt(n + 1)            -- immediate re-attempt (fresh connection)
            elseif cb.on_error then
                cb.on_error(msg)
            end
        end

        local decoder = codec.new_decoder({
            on_text = function(t) got_content = true; if cb.on_text then cb.on_text(t) end end,
            on_tool_use_start = function(id, name)
                got_content = true
                if cb.on_tool_use_start then cb.on_tool_use_start(id, name) end
            end,
            on_tool_input = cb.on_tool_input,
            on_done = function(r) api_log.finish(rec, r); if cb.on_done then cb.on_done(r) end end,
            -- decoder errors include the "connection closed before any data"
            -- case (got_any=false) and in-stream error events — both transient.
            on_error = function(m) retry_or_fail(m, true) end,
        })

        stream.request({
            url = req.url, method = 'POST', headers = req.headers, body = req.body,
            verify = cfg.verify, ca_file = cfg.ca_file, proxy = cfg.proxy,
        }, {
            on_headers = function(status) api_log.set_status(rec, status) end,
            on_body = function(chunk) api_log.append_raw(rec, chunk) end,
            on_sse = function(event, data) decoder:on_sse(event, data) end,
            on_done = function() decoder:finish() end,   -- close before the end marker
            on_error = function(err) retry_or_fail('connection error: ' .. tostring(err), true) end,
            on_http_error = function(status, body)
                local transient = (status == 429 or status >= 500)
                api_log.set_status(rec, status)
                retry_or_fail(M.format_http_error(status, body), transient)
            end,
        })
    end

    attempt(0)
end

return M
