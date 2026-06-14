-- xagent/skills/conditional.lua — promote `paths`-gated skills when a touched
-- file matches. Activation is one-way and sticky for the process lifetime
-- (avoids the skill flickering in/out as the model navigates files).

local registry = require('xagent.skills.registry')
local globm    = dofile('scripts/core/share/xglob.lua')
local path     = dofile('scripts/core/share/xpath.lua')

local M = {}

-- Make a cwd-relative, forward-slash path; nil if outside cwd (the glob
-- patterns are authored against in-repo paths).
local function rel_to_cwd(p, cwd)
    local abs = path.is_absolute(p) and p or path.resolve(p, cwd)
    abs = abs:gsub('\\', '/'):gsub('/+$', '')
    local base = tostring(cwd or '.'):gsub('\\', '/'):gsub('/+$', '')
    if base ~= '' then
        if abs == base then return nil end
        local prefix = base .. '/'
        if abs:sub(1, #prefix):lower() == prefix:lower() then   -- case-insensitive (Windows)
            return abs:sub(#prefix + 1)
        end
        return nil   -- outside cwd
    end
    return abs
end

-- activate_for_paths(file_paths, cwd) -> {names that just activated}
function M.activate_for_paths(file_paths, cwd)
    if not file_paths or #file_paths == 0 then return {} end
    local candidates = registry.list_conditional()
    if #candidates == 0 then return {} end

    local rels = {}
    for _, p in ipairs(file_paths) do
        local r = rel_to_cwd(p, cwd)
        if r and r ~= '' then rels[#rels + 1] = r end
    end
    if #rels == 0 then return {} end

    local activated = {}
    for _, skill in ipairs(candidates) do
        local patterns = skill.frontmatter.paths or {}
        local hit = false
        for _, pat in ipairs(patterns) do
            for _, r in ipairs(rels) do
                if globm.match(pat, r) then hit = true; break end
            end
            if hit then break end
        end
        if hit and registry.activate_conditional(skill.name) then
            activated[#activated + 1] = skill.name
        end
    end
    return activated
end

-- Pull file-path-shaped fields from a tool input (conservative: only the
-- well-known file fields, to avoid activating on irrelevant inputs).
function M.extract_tool_file_paths(tool_name, input)
    local out = {}
    if type(input) ~= 'table' then return out end
    if tool_name == 'Read' or tool_name == 'Write' or tool_name == 'Edit'
       or tool_name == 'MultiEdit' then
        if type(input.file_path) == 'string' then out[#out + 1] = input.file_path end
    elseif tool_name == 'Glob' then
        if type(input.path) == 'string' then out[#out + 1] = input.path end
    end
    return out
end

return M
