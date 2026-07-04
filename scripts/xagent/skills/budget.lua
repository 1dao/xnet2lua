-- xagent/skills/budget.lua — render the skill discovery listing for the system
-- prompt, under a character budget so a large skill collection can't bloat the
-- prompt. Three-tier degradation: full descriptions → shrunk → names-only.
-- (Budget is in CHARACTERS; ~4 chars/token, so 8000 ≈ 2000 tokens.)

local M = {}

M.MAX_LISTING_DESC_CHARS = 250
local MIN_DESC_CHARS_PER_SKILL = 20
local DEFAULT_BUDGET_CHARS = 8000

function M.char_budget()
    local env = tonumber(os.getenv('XAGENT_SKILL_CHAR_BUDGET'))
    if env and env > 0 then return math.floor(env) end
    return DEFAULT_BUDGET_CHARS
end

-- Truncate to `max` CHARACTERS (not bytes). Must cut on a UTF-8 boundary: a
-- byte-offset cut can split a multibyte char (e.g. CJK = 3 bytes), and the
-- resulting invalid UTF-8 makes the whole prompt fail to JSON-encode (empty
-- body → opaque 400). See [[json-pack-nil-on-invalid-utf8]].
local function truncate(desc, max)
    desc = tostring(desc or '')
    local nchars = utf8 and utf8.len(desc) or nil
    if not nchars then
        -- Not valid UTF-8 (or no utf8 lib): fall back to a byte cut, but keep
        -- only the leading bytes that are themselves ASCII so we can't split a
        -- multibyte sequence.
        if #desc <= max then return desc end
        if max <= 1 then return '…' end
        local s = desc:sub(1, max - 1):gsub('[\128-\255]+$', '')
        return (s:gsub('%s+$', '')) .. '…'
    end
    if nchars <= max then return desc end
    if max <= 1 then return '…' end
    local cut = utf8.offset(desc, max) or (#desc + 1)   -- byte start of char #max
    return (desc:sub(1, cut - 1):gsub('%s+$', '')) .. '…'
end

local function line_for(skill, desc_max)
    local cap = math.min(desc_max, M.MAX_LISTING_DESC_CHARS)
    local full = skill.when_to_use
        and (skill.description .. ' — ' .. skill.when_to_use)
        or skill.description
    return '- ' .. skill.name .. ': ' .. truncate(full, cap)
end

local function total_len(lines)
    local n = 0
    for _, l in ipairs(lines) do n = n + #l + 1 end
    return n
end

-- format(skills [, budget]) -> listing string ('' when no skills).
function M.format(skills, budget)
    if #skills == 0 then return '' end
    budget = budget or M.char_budget()

    -- Tier 1: full descriptions (each capped at MAX_LISTING_DESC_CHARS).
    local tier1 = {}
    for _, s in ipairs(skills) do tier1[#tier1 + 1] = line_for(s, M.MAX_LISTING_DESC_CHARS) end
    if total_len(tier1) <= budget then return table.concat(tier1, '\n') end

    -- Tier 2: split the remaining budget evenly across descriptions.
    local prefix_cost = 0
    for _, s in ipairs(skills) do prefix_cost = prefix_cost + #('- ' .. s.name .. ': ') + 1 end
    local desc_budget = budget - prefix_cost
    if desc_budget >= #skills * MIN_DESC_CHARS_PER_SKILL then
        local per = math.max(MIN_DESC_CHARS_PER_SKILL, math.floor(desc_budget / #skills))
        local tier2 = {}
        for _, s in ipairs(skills) do tier2[#tier2 + 1] = line_for(s, per) end
        if total_len(tier2) <= budget then return table.concat(tier2, '\n') end
    end

    -- Tier 3: names only (accept overshoot — the model still sees every name).
    local tier3 = {}
    for _, s in ipairs(skills) do tier3[#tier3 + 1] = '- ' .. s.name end
    return table.concat(tier3, '\n')
end

-- The <system-reminder> block injected into the system prompt ('' when empty).
function M.format_system_reminder(skills)
    if #skills == 0 then return '' end
    local listing = M.format(skills)
    if listing == '' then return '' end
    return table.concat({
        '<system-reminder>',
        'Available skills you can invoke via the `Skill` tool. Each line is `- <name>: <description>`.',
        'Call Skill(skill="<name>", args="<optional args>") when the user\'s request matches one of these.',
        '',
        listing,
        '</system-reminder>',
    }, '\n')
end

return M
