-- xtext.lua — text hygiene + small string helpers shared across modules.
-- Dependency-free and stateless; any thread can `dofile` it.

---@class xtext
local M = {}

local REPLACEMENT = '\239\191\189'   -- U+FFFD as UTF-8

-- Return a copy of `s` that is valid UTF-8: any byte that isn't part of a
-- well-formed sequence is replaced with U+FFFD. This is required before any
-- string from arbitrary sources (file contents, command output) goes into an
-- LLM request — yyjson's json_pack returns nil on invalid UTF-8, which would
-- send an empty body and get a "400 ... EOF while parsing" from the server.
--
-- "Well-formed" here means RFC 3629 / Unicode Table 3-7, not just "continuation
-- bytes are 0x80–0xBF": the second-byte range is narrowed for the E0/ED/F0/F4
-- leads so that overlong encodings (E0 80.., F0 80..), UTF-16 surrogates
-- (ED A0.. → U+D800–U+DFFF) and out-of-range code points (F4 90.. → > U+10FFFF)
-- are rejected. yyjson rejects all of those, so a looser check would let bytes
-- through that still produce an empty body (e.g. when Read returns a binary PDF).
function M.valid_utf8(s)
    if type(s) ~= 'string' then return s end
    local n = #s
    local out, oi = {}, 0
    local i = 1
    local clean = true
    while i <= n do
        local b = s:byte(i)
        local seq_len, ok
        if b < 0x80 then
            seq_len, ok = 1, true
        elseif b >= 0xC2 and b <= 0xDF then
            seq_len = 2
            local b2 = s:byte(i + 1)
            ok = b2 and b2 >= 0x80 and b2 <= 0xBF
        elseif b >= 0xE0 and b <= 0xEF then
            seq_len = 3
            -- E0: 2nd byte A0–BF (no overlong); ED: 80–9F (no surrogate).
            local lo = (b == 0xE0) and 0xA0 or 0x80
            local hi = (b == 0xED) and 0x9F or 0xBF
            local b2, b3 = s:byte(i + 1), s:byte(i + 2)
            ok = b2 and b3 and b2 >= lo and b2 <= hi
                and b3 >= 0x80 and b3 <= 0xBF
        elseif b >= 0xF0 and b <= 0xF4 then
            seq_len = 4
            -- F0: 2nd byte 90–BF (no overlong); F4: 80–8F (<= U+10FFFF).
            local lo = (b == 0xF0) and 0x90 or 0x80
            local hi = (b == 0xF4) and 0x8F or 0xBF
            local b2, b3, b4 = s:byte(i + 1), s:byte(i + 2), s:byte(i + 3)
            ok = b2 and b3 and b4 and b2 >= lo and b2 <= hi
                and b3 >= 0x80 and b3 <= 0xBF and b4 >= 0x80 and b4 <= 0xBF
        else
            seq_len, ok = 1, false
        end

        if ok then
            oi = oi + 1; out[oi] = s:sub(i, i + seq_len - 1)
            i = i + seq_len
        else
            oi = oi + 1; out[oi] = REPLACEMENT
            i = i + 1
            clean = false
        end
    end
    if clean then return s end   -- avoid rebuilding when already valid
    return table.concat(out)
end

-- Split `s` into lines on '\n'. A trailing '\r' is stripped from each line
-- (CRLF-safe), and the single empty segment produced by a final newline is
-- dropped, so a file ending in "\n" yields exactly its logical lines.
function M.split_lines(s)
    local lines = {}
    for line in (tostring(s or '') .. '\n'):gmatch('(.-)\n') do
        lines[#lines + 1] = (line:gsub('\r$', ''))
    end
    -- gmatch on s.."\n" yields one extra empty trailing element; drop it.
    if #lines > 0 and lines[#lines] == '' then lines[#lines] = nil end
    return lines
end

-- If `s` is longer than `max` bytes, return its first `max` bytes followed by
-- `marker` (default "\n...[truncated]"); otherwise return `s` unchanged. For a
-- byte-count marker, pass it pre-formatted, e.g.
--   text.truncate(out, MAX, string.format('\n...[truncated, %d bytes total]', #out))
function M.truncate(s, max, marker)
    s = tostring(s or '')
    if #s <= max then return s end
    return s:sub(1, max) .. (marker or '\n...[truncated]')
end

return M
