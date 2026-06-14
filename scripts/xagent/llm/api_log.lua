-- xagent/llm/api_log.lua — in-memory log of LLM HTTP request/response pairs.
--
-- Records EVERY HTTP request to the model and its outcome (status, the model's
-- answer, usage, errors), so the GUI can show "what we sent / what came back".
-- Each retry attempt is its own entry, so transient drops are visible too.
--
-- Process-lifetime ONLY: never written to disk. A fresh process starts with an
-- empty log (close the app and reopen → recording restarts from scratch).
--
-- Display vs copy are DECOUPLED:
--   * the panel shows only a short preview of the answer (ANSWER_PREVIEW_BYTES);
--   * the FULL request body and FULL response are kept so the detail's copy
--     buttons can put the complete HTTP request / complete response on the
--     clipboard.
-- Memory is bounded by MAX_ENTRIES (oldest dropped) plus a per-request byte cap
-- (REQ_MAX_BYTES) that only ever bites on a giant base64 image in the prompt;
-- text requests and responses are stored in full.

local M = {}

local MAX_ENTRIES         = 100        -- ring cap: oldest entries drop off
local ANSWER_PREVIEW_BYTES = 100       -- first 100 bytes of the answer shown in the panel
local REQ_MAX_BYTES       = 2000000    -- safety cap on the stored request body (~2MB)
local ANSWER_MAX_BYTES    = 2000000    -- safety cap on the stored full answer (answers are small)

local entries = {}     -- list, oldest → newest
local seq = 0

-- Truncate `s` to at most `max` bytes WITHOUT splitting a UTF-8 sequence.
-- Returns (prefix, truncated?) where truncated is true iff bytes were dropped.
local function utf8_prefix(s, max)
    s = tostring(s or '')
    if #s <= max then return s, false end
    local cut = max
    while cut > 0 do
        local nb = s:byte(cut + 1)            -- first byte we would drop
        if not nb or nb < 0x80 or nb >= 0xC0 then break end  -- not a continuation byte → safe boundary
        cut = cut - 1
    end
    return s:sub(1, cut), true
end

-- Copy headers, masking the secret auth header so a clipboard copy of the
-- request never leaks the API key.
local function redact_headers(h)
    if type(h) ~= 'table' then return nil end
    local out = {}
    for k, v in pairs(h) do
        local lk = tostring(k):lower()
        if lk == 'x-api-key' or lk == 'authorization' then
            out[k] = '***redacted***'
        else
            out[k] = v
        end
    end
    return out
end

-- Concatenate the text blocks of an assembled assistant message and note any
-- tool calls (a turn is often pure tool_use with no prose).
local function summarize_answer(message)
    local text_parts, tool_names = {}, {}
    if message and type(message.content) == 'table' then
        for _, b in ipairs(message.content) do
            if b.type == 'text' then
                text_parts[#text_parts + 1] = b.text or ''
            elseif b.type == 'tool_use' then
                tool_names[#tool_names + 1] = tostring(b.name)
            elseif b.type == 'thinking' then
                -- skip thinking from the preview; it's not the "answer"
            end
        end
    end
    return table.concat(text_parts, ''), tool_names
end

-- Begin a record at request time. `info` = { model, url, method, body, headers }.
-- Returns the entry table; pass it back to M.finish / M.fail / M.set_status.
function M.begin(info)
    info = info or {}
    seq = seq + 1
    local body = tostring(info.body or '')
    local req_truncated = false
    if #body > REQ_MAX_BYTES then
        body = body:sub(1, REQ_MAX_BYTES)
        req_truncated = true
    end
    local rec = {
        seq           = seq,
        ts            = os.time(),
        started_clock = os.clock(),
        model         = info.model,
        method        = info.method or 'POST',
        url           = info.url,
        headers       = redact_headers(info.headers),
        request       = body,                      -- FULL request body (for copy)
        request_bytes = #tostring(info.body or ''),
        req_truncated = req_truncated,
        -- filled in later:
        done          = false,
        ok            = nil,
        status        = nil,
        answer        = '',                        -- first 100 bytes (for display)
        answer_full   = '',                        -- complete answer text (for copy)
        answer_truncated = false,                  -- did the DISPLAY preview drop bytes
        tool_calls    = nil,
        usage         = nil,
        stop_reason   = nil,
        error         = nil,
        elapsed_ms    = nil,
    }
    entries[#entries + 1] = rec
    while #entries > MAX_ENTRIES do table.remove(entries, 1) end
    return rec
end

-- Record the HTTP status code (from the response headers), if available.
function M.set_status(rec, status)
    if rec then rec.status = status end
end

-- Finalize a successful attempt. `result` is the decoder's on_done payload
-- ({ message, usage, stop_reason }).
function M.finish(rec, result)
    if not rec or rec.done then return end
    result = result or {}
    local answer, tools = summarize_answer(result.message)
    local full = utf8_prefix(answer, ANSWER_MAX_BYTES)   -- complete (safety-capped)
    local preview, truncated = utf8_prefix(answer, ANSWER_PREVIEW_BYTES)
    rec.answer_full = full
    rec.answer = preview
    rec.answer_truncated = truncated
    rec.tool_calls = (#tools > 0) and table.concat(tools, ', ') or nil
    rec.usage = result.usage
    rec.stop_reason = result.stop_reason
    rec.done = true
    rec.ok = true
    rec.elapsed_ms = math.floor((os.clock() - (rec.started_clock or 0)) * 1000 + 0.5)
end

-- Finalize a failed attempt (HTTP error, connection drop, or SSE error).
-- `info` = { error, status? }.
function M.fail(rec, info)
    if not rec or rec.done then return end
    info = info or {}
    rec.error = tostring(info.error or 'error')
    if info.status then rec.status = info.status end
    rec.done = true
    rec.ok = false
    rec.elapsed_ms = math.floor((os.clock() - (rec.started_clock or 0)) * 1000 + 0.5)
end

-- Newest-first snapshot is what the UI wants; return the raw list (oldest→newest)
-- and let callers iterate in reverse so we don't copy on every frame.
function M.list() return entries end
function M.count() return #entries end

function M.clear() entries = {}; seq = 0 end

return M
