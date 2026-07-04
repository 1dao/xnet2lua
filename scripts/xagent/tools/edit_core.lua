-- xagent/tools/edit_core.lua — pure string-edit logic + preview.
-- Apply + preview; line-ending tolerant. No I/O — unit-testable.

local M = {}

-- Raised on a non-applicable edit (0 matches, or >1 without replace_all).
M.EditError = 'EditError'

local function count_occurrences(s, sub)
    local count, init = 0, 1
    while true do
        local a, b = s:find(sub, init, true)   -- plain (non-pattern) search
        if not a then break end
        count = count + 1
        init = b + 1
    end
    return count
end

-- Replace every plain (non-pattern) occurrence of `old` with `new`.
local function plain_replace_all(s, old, new)
    local out, init = {}, 1
    while true do
        local a, b = s:find(old, init, true)
        if not a then out[#out + 1] = s:sub(init); break end
        out[#out + 1] = s:sub(init, a - 1)
        out[#out + 1] = new
        init = b + 1
    end
    return table.concat(out)
end

-- Coerce every newline in `s` to one style ('lf' | 'crlf'). Normalizes to LF
-- first so a string that already mixes \n and \r\n collapses cleanly.
local function to_eol(s, style)
    local lf = s:gsub('\r\n', '\n')
    if style == 'crlf' then return (lf:gsub('\n', '\r\n')) end
    return lf
end

-- Candidate (old, new) pairs to try, in match-preference order: the bytes as the
-- model sent them, then with newlines coerced to CRLF, then to LF. The Read tool
-- LF-normalizes what the model sees (xtext.split_lines strips trailing \r), so a
-- multi-line old_string copied from a CRLF file arrives as LF and a literal
-- search never finds it in the raw \r\n bytes. Retrying with CRLF newlines
-- recovers that (and LF covers the reverse: a CRLF needle against an LF file).
-- Whichever variant matches is used for BOTH old and new, so the replacement
-- keeps the file's existing line-ending style. Duplicate `old` forms (e.g. a
-- single-line string with no newline to coerce) are skipped.
local function eol_candidates(old, new)
    local cands, seen = { { old = old, new = new } }, { [old] = true }
    for _, style in ipairs({ 'crlf', 'lf' }) do
        local o = to_eol(old, style)
        if not seen[o] then
            seen[o] = true
            cands[#cands + 1] = { old = o, new = to_eol(new, style) }
        end
    end
    return cands
end

-- apply_edit(content, { old_string, new_string, replace_all }) ->
--   { content = <new>, replacements = <n> }   (raises a string error on failure)
-- Errors are raised at level 0 (no Lua "file:line:" prefix) so the message the
-- tool feeds back to the model is clean and actionable.
function M.apply_edit(content, opts)
    local old = opts.old_string or ''
    local new = opts.new_string or ''
    if old == '' then error('old_string must not be empty', 0) end
    if old == new then error('old_string and new_string are identical', 0) end

    for _, c in ipairs(eol_candidates(old, new)) do
        local count = count_occurrences(content, c.old)
        if count > 1 and not opts.replace_all then
            error(string.format(
                'old_string is not unique (%d matches) — add more surrounding context, or set replace_all=true',
                count), 0)
        elseif count >= 1 then
            return { content = plain_replace_all(content, c.old, c.new), replacements = count }
        end
    end

    error('old_string not found in file — re-read the file and copy the target text exactly, ' ..
          'including indentation and surrounding whitespace (the content may have changed since ' ..
          'you last read it)', 0)
end

-- A compact -/+ preview of the change.
function M.build_preview(old, new)
    local function fmt(prefix, s)
        s = tostring(s or ''):gsub('\r', '')
        if #s > 400 then s = s:sub(1, 400) .. '\n…[truncated]' end
        local t = {}
        for line in (s .. '\n'):gmatch('(.-)\n') do t[#t + 1] = prefix .. line end
        if #t > 0 and t[#t] == prefix then t[#t] = nil end
        return table.concat(t, '\n')
    end
    return fmt('- ', old) .. '\n' .. fmt('+ ', new)
end

return M
