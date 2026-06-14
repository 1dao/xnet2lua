-- xagent/tools/skill.lua — the Skill tool exposed to the model.
--
-- Looks up a SKILL.md from the registry, substitutes $ARGUMENTS /
-- ${CLAUDE_SKILL_DIR} / ${CLAUDE_SESSION_ID}, and returns the resulting prompt
-- as the tool result. The model reads it and continues the conversation
-- following the skill's instructions. context: fork and disable-model-invocation
-- skills are rejected with an explanatory error (out of scope for this stage).

local registry = require('xagent.skills.registry')

local SKILL_NAME_RE = '^[%w_%-]+$'

return {
    name = 'Skill',
    description =
        'Execute a named skill within the current conversation. Pass the skill\'s ' ..
        '`skill` name (as listed in the system-reminder block of available skills) ' ..
        'and an optional `args` string. The skill\'s instructions are returned as ' ..
        'text — read them and continue the conversation following those instructions. ' ..
        'Prefer a matching skill over improvising.',
    input_schema = {
        type = 'object',
        properties = {
            skill = { type = 'string', description = 'Name of the skill to execute (must match the registry).' },
            args  = { type = 'string', description = 'Optional argument string substituted into $ARGUMENTS.' },
        },
        required = { 'skill' },
    },
    is_read_only = function() return false end,

    call = function(input, ctx)
        local name = type(input.skill) == 'string' and input.skill:gsub('^%s+', ''):gsub('%s+$', '') or ''
        local args = type(input.args) == 'string' and input.args or ''

        if name == '' or not name:match(SKILL_NAME_RE) then
            return { content = 'Error: invalid skill name (must match ' .. SKILL_NAME_RE ..
                '). Got: ' .. tostring(input.skill), is_error = true }
        end

        local skill = registry.find(name)
        if not skill then
            return { content = 'Error: skill "' .. name .. '" not found.', is_error = true }
        end
        if skill.frontmatter.disable_model_invocation then
            return { content = 'Error: skill "' .. name .. '" has disable-model-invocation: true; ' ..
                'it can only be invoked by the user via /' .. name .. '.', is_error = true }
        end
        if skill.frontmatter.has_fork_context then
            return { content = 'Error: skill "' .. name .. '" declares context: fork, which needs ' ..
                'sub-agent execution (not implemented). Remove `context: fork` to run it inline.',
                is_error = true }
        end

        -- A skill's allowed-tools would feed the permission engine's session
        -- allow-list; harmless no-op until that engine lands.
        if ctx and ctx.add_session_allow_rules and #skill.frontmatter.allowed_tools > 0 then
            ctx.add_session_allow_rules(skill.frontmatter.allowed_tools)
        end

        local session_id = (ctx and ctx.session_id) or 'unknown-session'
        local prompt = require('xagent.skills').render_body(skill, args, session_id)

        return { content =
            'Loaded skill "' .. skill.name .. '" (' .. tostring(skill.source) .. '). ' ..
            'Follow the instructions below — they ARE your next steps for this turn.\n\n' .. prompt }
    end,
}
