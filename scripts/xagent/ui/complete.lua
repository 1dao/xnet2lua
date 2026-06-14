-- xagent/ui/complete.lua — input autocomplete logic for the chat box.
--
-- Two trigger tokens, both filtered live as the user types (no network, no
-- raygui — pure string work so it's unit-testable; gui.lua renders the popup
-- and feeds keyboard/mouse events):
--   /<query>      slash commands (built-ins + user-invocable skills). Only at
--                 the very start of the input, single token.
--   …@<path>      file/directory references. The '@' must sit at the start or
--                 after whitespace (so emails like a@b don't trigger). Drills
--                 into subdirectories: '@core/se' lists core/ filtered by 'se'.
--
-- compute(input, deps) returns a menu { kind, items, prefix } or nil. apply()
-- turns a chosen item back into the new input text + caret byte offset.
--
-- deps = {
--   slash_items = function() -> { { name=, desc= }, ... },   -- command catalog
--   list_dir    = function(rel_dir) -> { 'name', 'sub/' },   -- immediate kids,
--                 names of subdirectories carry a trailing '/'. rel_dir is ''
--                 for the working-dir root, else like 'core/' (always ends '/').
-- }

local M = {}

local MAX_ITEMS = 50   -- cap a directory/command list so the popup stays bounded

-- ── token detection ────────────────────────────────────────────────────────
-- Returns a descriptor for the active token at the END of the input, or nil.
function M.detect(input)
    input = tostring(input or '')

    -- slash: whole input is "/" + a single command-ish token (no spaces yet).
    local sq = input:match('^/([%w%-_:]*)$')
    if sq then return { kind = 'slash', query = sq } end

    -- at: the last "@<path>" run, anchored to the input end, where '@' begins
    -- the line or follows whitespace.
    local at_pos, partial = input:match('()@([^%s@]*)$')
    if at_pos then
        local before = (at_pos > 1) and input:sub(at_pos - 1, at_pos - 1) or ''
        if before == '' or before:match('%s') then
            local dir_part, leaf = partial:match('^(.*[/\\])([^/\\]*)$')
            if not dir_part then dir_part, leaf = '', partial end
            return {
                kind = 'at',
                partial = partial,
                dir_part = dir_part,         -- '' | 'core/' | 'a/b/'
                leaf = leaf,                 -- the part being filtered
                -- text to keep verbatim when a candidate is chosen (everything
                -- up to and including '@' plus the resolved directory prefix)
                prefix = input:sub(1, at_pos) .. dir_part,
            }
        end
    end
    return nil
end

-- ── ranking helpers ─────────────────────────────────────────────────────────
-- Stable order: prefix matches before mid-string matches, then alphabetical.
local function by_rank(a, b)
    if a._rank ~= b._rank then return a._rank < b._rank end
    return a._key < b._key
end

-- ── slash candidates ────────────────────────────────────────────────────────
function M.filter_slash(items, query)
    local q = tostring(query or ''):lower()
    local out = {}
    for _, it in ipairs(items or {}) do
        local nl = tostring(it.name):lower()
        local pos = (q == '') and 1 or nl:find(q, 1, true)
        if pos then
            out[#out + 1] = {
                label = '/' .. it.name,
                name = it.name,
                desc = it.desc or '',
                insert = '/' .. it.name .. ' ',   -- trailing space: Enter then runs it
                _rank = (pos == 1) and 0 or 1,
                _key = nl,
            }
        end
    end
    table.sort(out, by_rank)
    return out
end

-- ── @ path candidates ───────────────────────────────────────────────────────
function M.filter_at(desc, deps)
    local children = (deps.list_dir and deps.list_dir(desc.dir_part)) or {}
    local leaf = tostring(desc.leaf or ''):lower()
    local want_hidden = desc.leaf:sub(1, 1) == '.'   -- only show dotfiles if asked
    local out = {}
    for _, name in ipairs(children) do
        local is_dir = name:sub(-1) == '/'
        local bare = is_dir and name:sub(1, -2) or name
        if want_hidden or bare:sub(1, 1) ~= '.' then
            local bl = bare:lower()
            local pos = (leaf == '') and 1 or bl:find(leaf, 1, true)
            if pos then
                out[#out + 1] = {
                    label = name,
                    name = name,
                    is_dir = is_dir,
                    -- directories sort first; prefix matches before substring
                    _rank = (is_dir and 0 or 2) + ((pos == 1) and 0 or 1),
                    _key = bl,
                }
            end
        end
    end
    table.sort(out, by_rank)
    return out
end

-- ── public entry points ─────────────────────────────────────────────────────
-- Build the live menu for the current input, or nil when nothing applies.
function M.compute(input, deps)
    local desc = M.detect(input)
    if not desc then return nil end

    local items
    if desc.kind == 'slash' then
        items = M.filter_slash(deps.slash_items and deps.slash_items() or {}, desc.query)
    else
        items = M.filter_at(desc, deps)
    end
    if #items == 0 then return nil end
    if #items > MAX_ITEMS then
        local t = {}
        for i = 1, MAX_ITEMS do t[i] = items[i] end
        items = t
        items.truncated = true
    end
    return { kind = desc.kind, items = items, prefix = desc.prefix }
end

-- Apply a chosen item; returns the replacement input text and the caret byte
-- offset to place after it.
function M.apply(menu, item)
    if not menu or not item then return nil end
    if menu.kind == 'slash' then
        return item.insert, #item.insert
    end
    -- a directory keeps the caret right after the '/' so typing keeps drilling;
    -- a file gets a trailing space so the reference is complete.
    local new = (menu.prefix or '') .. item.name .. (item.is_dir and '' or ' ')
    return new, #new
end

return M
