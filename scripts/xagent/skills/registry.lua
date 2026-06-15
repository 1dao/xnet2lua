-- xagent/skills/registry.lua — in-memory state for loaded skills.
--
-- Two sets mirror the always-on vs conditionally-activated split:
--   dynamic     : visible to the model now (listed in the system prompt).
--   conditional : declared with a `paths` frontmatter; promoted into `dynamic`
--                 when a touched file matches (see skills/conditional.lua).
-- Each set keeps a name→skill map plus an insertion-order array for stable
-- listing (Lua string-keyed tables have no order guarantee).

local M = {}

local dyn, cond = {}, {}
local dyn_order, cond_order = {}, {}
local initialized = false

local function add(map, order, skill)
    if not map[skill.name] then order[#order + 1] = skill.name end
    map[skill.name] = skill
end

local function remove_order(order, name)
    for i, nm in ipairs(order) do if nm == name then table.remove(order, i); return end end
end

local function values(map, order)
    local t = {}
    for _, nm in ipairs(order) do if map[nm] then t[#t + 1] = map[nm] end end
    return t
end

-- Replace the registry with a freshly-loaded set (called once at bootstrap).
function M.set_skills(skills)
    dyn, cond, dyn_order, cond_order = {}, {}, {}, {}
    for _, s in ipairs(skills or {}) do
        if s.frontmatter.paths and #s.frontmatter.paths > 0 then
            add(cond, cond_order, s)
        else
            add(dyn, dyn_order, s)
        end
    end
    initialized = true
end

function M.is_initialized() return initialized end

-- Skills the model may invoke — drives the system-prompt listing. Excludes
-- disable-model-invocation skills (user-only).
function M.get_model_visible()
    local t = {}
    for _, s in ipairs(values(dyn, dyn_order)) do
        if not s.frontmatter.disable_model_invocation then t[#t + 1] = s end
    end
    return t
end

-- Everything a user could trigger via /<name> (incl. hidden + still-conditional).
function M.all_user_invocable()
    local t = values(dyn, dyn_order)
    for _, s in ipairs(values(cond, cond_order)) do t[#t + 1] = s end
    return t
end

function M.find(name) return dyn[name] or cond[name] end

-- Promote a conditional skill into the visible set. Returns true if it was
-- previously latent (so the caller can surface "activated skill X").
function M.activate_conditional(name)
    local s = cond[name]
    if not s then return false end
    cond[name] = nil
    remove_order(cond_order, name)
    add(dyn, dyn_order, s)
    return true
end

function M.list_conditional() return values(cond, cond_order) end

function M.clear()
    dyn, cond, dyn_order, cond_order = {}, {}, {}, {}
    initialized = false
end

return M
