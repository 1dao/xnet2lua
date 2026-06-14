-- xagent/tools/edit_core.lua — pure string-edit logic + preview.
-- Apply + preview; quote-normalize omitted for M1. No I/O — unit-testable.

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

-- apply_edit(content, { old_string, new_string, replace_all }) ->
--   { content = <new>, replacements = <n> }   (raises a string error on failure)
function M.apply_edit(content, opts)
    local old = opts.old_string or ''
    local new = opts.new_string or ''
    if old == '' then error('old_string must not be empty') end
    if old == new then error('old_string and new_string are identical') end

    local count = count_occurrences(content, old)
    if count == 0 then
        error('old_string not found in file')
    end
    if count > 1 and not opts.replace_all then
        error(string.format(
            'old_string is not unique (%d matches) — add more surrounding context, or set replace_all=true',
            count))
    end
    return { content = plain_replace_all(content, old, new), replacements = count }
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
