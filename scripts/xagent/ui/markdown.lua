-- xagent/ui/markdown.lua — light-weight Markdown styling for the transcript.
--
-- Renders an assistant message into a list of "logical lines", each carrying a
-- color (and optional background for code blocks). The transcript then wraps and
-- draws each logical line (single color per line keeps wrapping exact and avoids
-- inter-glyph spacing drift). Inline markers (**, `, [..](..)) are stripped so
-- the output reads clean; block elements (#, ```, -, |, ---) are colored.
--
-- Palette hues nod to the user's reference screenshot (blue headings, distinct
-- code), adapted for the dark transcript background.

local xtext = dofile('scripts/core/share/xtext.lua')

local M = {}

M.palette = {
    text    = { 214, 210, 224, 255 },   -- body
    heading = { 120, 175, 255, 255 },   -- # headings → blue
    code    = { 140, 210, 160, 255 },   -- code → green
    bullet  = { 150, 160, 200, 255 },   -- list lines
    quote   = { 160, 165, 178, 255 },   -- > blockquote
    hr      = { 90, 90, 104, 255 },     -- --- rule
    table   = { 196, 192, 210, 255 },   -- | table | rows
}
M.code_bg = { 34, 36, 42, 255 }

-- Strip inline markup down to its visible text.
local function strip_inline(s)
    s = s:gsub('%[(.-)%]%((.-)%)', '%1')   -- [text](url) -> text
    s = s:gsub('%*%*(.-)%*%*', '%1')       -- **bold** -> bold
    s = s:gsub('__(.-)__', '%1')           -- __bold__ -> bold
    s = s:gsub('`([^`]*)`', '%1')          -- `code` -> code
    return s
end

local function classify(line, P)
    if line == '' then return { text = '', color = P.text } end

    local hashes, htext = line:match('^(#+)%s+(.*)$')
    if hashes then return { text = strip_inline(htext), color = P.heading } end

    if line:match('^%s*[%-%*_]%s*[%-%*_]%s*[%-%*_][%s%-%*_]*$') then
        return { text = string.rep('─', 48), color = P.hr }   -- horizontal rule
    end

    local q = line:match('^%s*>%s?(.*)$')
    if q then return { text = '┃ ' .. strip_inline(q), color = P.quote } end

    local ind, _, rest = line:match('^(%s*)([%-%*%+])%s+(.*)$')
    if rest then return { text = ind .. '• ' .. strip_inline(rest), color = P.bullet } end

    local ind2, num, rest2 = line:match('^(%s*)(%d+[%.%)])%s+(.*)$')
    if rest2 then return { text = ind2 .. num .. ' ' .. strip_inline(rest2), color = P.bullet } end

    if line:match('^%s*|.*|%s*$') then
        return { text = line, color = P.table }                -- keep table pipes
    end

    return { text = strip_inline(line), color = P.text }
end

-- render(text) -> list of { text, color, bg? }
function M.render(text)
    local P = M.palette
    local out = {}
    local in_code = false
    for _, line in ipairs(xtext.split_lines(text)) do
        if line:match('^%s*```') then
            in_code = not in_code                              -- fence: hidden
        elseif in_code then
            out[#out + 1] = { text = line, color = P.code, bg = M.code_bg }
        else
            out[#out + 1] = classify(line, P)
        end
    end
    return out
end

M.strip_inline = strip_inline   -- exposed for tests

return M
