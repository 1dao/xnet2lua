-- xagent/skills.lua — Skills facade. Loads SKILL.md files from disk, exposes
-- the model-visible listing for the system prompt, and promotes conditional
-- (paths-gated) skills as files are touched.
--
-- A skill is a `<dir>/<name>/SKILL.md` with YAML frontmatter (name, description,
-- when_to_use, allowed-tools, paths, …) + a markdown body. The model runs one
-- via the Skill tool (tools/skill.lua); the body is returned as instructions.

local loader      = require('xagent.skills.loader')
local registry    = require('xagent.skills.registry')
local budget       = require('xagent.skills.budget')
local conditional = require('xagent.skills.conditional')

local M = {
    registry = registry,
    conditional = conditional,
}

-- Load skills for `cwd` into the registry. Returns { skill_count,
-- conditional_count, warnings }. Warnings go to stderr (xlog).
function M.bootstrap(cwd)
    local res = loader.load_all(cwd)
    registry.set_skills(res.skills)
    for _, w in ipairs(res.warnings) do io.stderr:write('[xagent] ' .. w .. '\n') end

    local cond = 0
    for _, s in ipairs(res.skills) do
        if s.frontmatter.paths and #s.frontmatter.paths > 0 then cond = cond + 1 end
    end
    return { skill_count = #res.skills - cond, conditional_count = cond, warnings = res.warnings }
end

-- The <system-reminder> listing block to append to the system prompt ('' when
-- no skills are visible). Recompute each turn so conditional activations show.
function M.reminder()
    return budget.format_system_reminder(registry.get_model_visible())
end

function M.find(name) return registry.find(name) end
function M.all_user_invocable() return registry.all_user_invocable() end

-- Case-insensitive lookup across all user-invocable skills (slash commands may
-- arrive lower-cased; skill names can have any case).
function M.find_invocable(name)
    local exact = registry.find(name)
    if exact then return exact end
    local lname = tostring(name):lower()
    for _, s in ipairs(registry.all_user_invocable()) do
        if s.name:lower() == lname then return s end
    end
    return nil
end

-- Render a skill body with $ARGUMENTS / ${CLAUDE_SKILL_DIR} / ${CLAUDE_SESSION_ID}
-- substituted, prefixed with the base-dir line. Shared by the Skill tool and
-- user /<name> invocation.
function M.render_body(skill, args, session_id)
    local dir = (tostring(skill.base_dir or ''):gsub('[\\/]+', '/'))
    local function repl(s, needle, val)
        return (s:gsub(needle, (tostring(val):gsub('%%', '%%%%'))))
    end
    local body = skill.body or ''
    body = repl(body, '%${CLAUDE_SKILL_DIR}', dir)
    body = repl(body, '%${CLAUDE_SESSION_ID}', session_id or 'unknown-session')
    body = repl(body, '%$ARGUMENTS', args or '')
    return 'Base directory for this skill: ' .. dir .. '\n\n' .. body
end

-- Called after a tool runs: if its file paths match a conditional skill's
-- `paths`, promote it. Returns the names that just activated.
function M.note_tool_use(tool_name, input, cwd)
    local paths = conditional.extract_tool_file_paths(tool_name, input)
    if #paths == 0 then return {} end
    return conditional.activate_for_paths(paths, cwd)
end

return M
