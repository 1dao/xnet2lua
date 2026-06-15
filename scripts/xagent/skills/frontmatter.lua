-- xagent/skills/frontmatter.lua — split + normalize SKILL.md frontmatter.
--
-- A SKILL.md is `---\n<yaml>\n---\n<markdown body>`. minilua has no YAML
-- library, but skill frontmatter is shallow (flat key: value, simple lists), so
-- a small line-based parser covers it. Never throws — invalid frontmatter is
-- reported via parse_error so the loader can warn + skip rather than crash.

local M = {}

local function lines_of(s)
    local t = {}
    for line in (s .. '\n'):gmatch('(.-)\n') do t[#t + 1] = (line:gsub('\r$', '')) end
    -- drop the trailing empty element the final newline adds
    if t[#t] == '' then t[#t] = nil end
    return t
end

local function strip_quotes(v)
    v = v:gsub('^%s+', ''):gsub('%s+$', '')
    local q = v:sub(1, 1)
    if (q == '"' or q == "'") and #v >= 2 and v:sub(-1) == q then return v:sub(2, -2) end
    return v
end

-- Minimal YAML: `key: scalar`, `key: [a, b]` (inline list), and block lists
-- (`key:` then indented `- item` lines). Comment lines (#…) and blanks skipped.
-- Scalars stored as strings, lists as arrays — normalize() handles both shapes.
local function parse_yaml(L)
    local raw = {}
    local i = 1
    while i <= #L do
        local line = L[i]
        if line:match('^%s*$') or line:match('^%s*#') then
            i = i + 1
        else
            local key, val = line:match('^%s*([%w_%-]+):%s*(.*)$')
            if not key then
                i = i + 1   -- lenient: skip lines we don't understand
            else
                val = (val:gsub('%s+$', ''))
                if val == '' then
                    -- possible block list on the following indented lines
                    local list = {}
                    local j = i + 1
                    while j <= #L do
                        local item = L[j]:match('^%s*%-%s+(.+)$')
                        if item then list[#list + 1] = strip_quotes(item); j = j + 1
                        else break end
                    end
                    if #list > 0 then raw[key] = list; i = j
                    else raw[key] = ''; i = i + 1 end
                elseif val:sub(1, 1) == '[' then
                    local inner = val:match('^%[(.*)%]') or ''
                    local list = {}
                    for item in inner:gmatch('[^,]+') do
                        local s = strip_quotes(item)
                        if s ~= '' then list[#list + 1] = s end
                    end
                    raw[key] = list
                    i = i + 1
                else
                    raw[key] = strip_quotes(val)
                    i = i + 1
                end
            end
        end
    end
    return raw
end

-- split(content) -> { raw = <table>, body = <string>, parse_error? = <string> }
function M.split(content)
    content = (content or ''):gsub('^\239\187\191', '')   -- strip UTF-8 BOM
    local L = lines_of(content)
    if L[1] ~= '---' then return { raw = {}, body = content } end
    local close
    for k = 2, #L do if L[k] == '---' then close = k; break end end
    if not close then return { raw = {}, body = content } end

    local yaml_lines = {}
    for k = 2, close - 1 do yaml_lines[#yaml_lines + 1] = L[k] end
    local body_lines = {}
    for k = close + 1, #L do body_lines[#body_lines + 1] = L[k] end

    local ok, raw = pcall(parse_yaml, yaml_lines)
    if not ok then
        return { raw = {}, body = table.concat(body_lines, '\n'), parse_error = tostring(raw) }
    end
    return { raw = raw, body = table.concat(body_lines, '\n') }
end

-- ── field coercion ───────────────────────────────────────────────────────
local function as_string(v)
    if type(v) == 'string' then
        local t = v:gsub('^%s+', ''):gsub('%s+$', '')
        return t ~= '' and t or nil
    end
    return nil
end

local function as_string_array(v)
    if type(v) == 'table' then
        local out = {}
        for _, item in ipairs(v) do
            if type(item) == 'string' then
                local t = item:gsub('^%s+', ''):gsub('%s+$', '')
                if t ~= '' then out[#out + 1] = t end
            end
        end
        return out
    end
    if type(v) == 'string' then   -- CSV: "Read, Grep, Glob"
        local out = {}
        for item in v:gmatch('[^,]+') do
            local t = item:gsub('^%s+', ''):gsub('%s+$', '')
            if t ~= '' then out[#out + 1] = t end
        end
        return out
    end
    return {}
end

local function as_bool(v)
    if type(v) == 'boolean' then return v end
    if type(v) == 'string' then
        local s = v:lower():gsub('%s+', '')
        return s == 'true' or s == 'yes' or s == '1'
    end
    return false
end

-- First non-empty paragraph of the body, with leading headings skipped. Used
-- when frontmatter has no `description`.
function M.extract_fallback_description(body)
    local buf = {}
    for raw in ((body or '') .. '\n'):gmatch('(.-)\n') do
        local line = raw:gsub('^%s+', ''):gsub('%s+$', '')
        if line == '' then
            if #buf > 0 then break end
        elseif #buf == 0 and line:sub(1, 1) == '#' then
            -- skip leading heading (redundant with the skill name)
        else
            buf[#buf + 1] = line
        end
    end
    return (table.concat(buf, ' '):gsub('%s+', ' '):gsub('^%s+', ''):gsub('%s+$', ''))
end

-- normalize(raw, body) -> a frontmatter table with coerced, known fields.
-- Unknown keys stay in `.raw` for future use.
function M.normalize(raw, body)
    local paths = as_string_array(raw['paths'])
    return {
        name = as_string(raw['name']),
        description = as_string(raw['description']),
        when_to_use = as_string(raw['when_to_use'] or raw['whenToUse']),
        allowed_tools = as_string_array(raw['allowed-tools'] or raw['allowedTools']),
        argument_hint = as_string(raw['argument-hint'] or raw['argumentHint']),
        disable_model_invocation = as_bool(raw['disable-model-invocation'] or raw['disableModelInvocation']),
        paths = (#paths > 0) and paths or nil,
        has_fork_context = as_string(raw['context']) == 'fork',
        raw = raw,
    }
end

return M
