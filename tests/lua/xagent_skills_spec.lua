-- Unit specs for the Skills subsystem: frontmatter parsing, registry
-- dynamic/conditional split, discovery budget, conditional activation, the
-- Skill tool, and on-disk loading. All offline (no network).
-- Run via: bin/xnet tests/lua/xagent_skills_spec.lua

package.path = 'scripts/?.lua;' .. package.path

local spec    = dofile('tests/lua/spec_helper.lua')
local fm      = require('xagent.skills.frontmatter')
local registry = require('xagent.skills.registry')
local budget  = require('xagent.skills.budget')
local cond    = require('xagent.skills.conditional')
local loader  = require('xagent.skills.loader')
local skills  = require('xagent.skills')
local skill_tool = require('xagent.tools.skill')

local function mkskill(name, fields)
    fields = fields or {}
    return {
        name = name, description = fields.description or (name .. ' desc'),
        when_to_use = fields.when_to_use, body = fields.body or 'do the thing',
        file_path = '/x/' .. name .. '/SKILL.md', base_dir = '/x/' .. name,
        source = fields.source or 'user',
        frontmatter = {
            name = name, description = fields.description, allowed_tools = fields.allowed_tools or {},
            paths = fields.paths, disable_model_invocation = fields.disabled or false,
            has_fork_context = fields.fork or false, raw = {},
        },
    }
end

spec.describe('frontmatter.split', function()
    spec.it('splits frontmatter from body', function()
        local r = fm.split('---\nname: foo\ndescription: a tool\n---\n# Body\nhello')
        spec.equal(r.raw.name, 'foo')
        spec.equal(r.raw.description, 'a tool')
        spec.contains(r.body, 'hello')
        spec.nil_value(r.parse_error)
    end)
    spec.it('returns whole content as body when no frontmatter', function()
        local r = fm.split('no frontmatter here')
        spec.equal(r.body, 'no frontmatter here')
    end)
    spec.it('parses inline + block lists and CSV', function()
        local r = fm.split('---\nallowed-tools: [Read, Grep]\npaths:\n  - "*.lua"\n  - src/**\n---\nbody')
        local f = fm.normalize(r.raw, r.body)
        spec.equal(#f.allowed_tools, 2)
        spec.equal(f.allowed_tools[1], 'Read')
        spec.equal(#f.paths, 2)
        spec.equal(f.paths[2], 'src/**')
    end)
    spec.it('CSV allowed-tools + bool + fork', function()
        local r = fm.split('---\nallowed-tools: Read, Write\ndisable-model-invocation: true\ncontext: fork\n---\nb')
        local f = fm.normalize(r.raw, r.body)
        spec.equal(#f.allowed_tools, 2)
        spec.equal(f.disable_model_invocation, true)
        spec.equal(f.has_fork_context, true)
    end)
end)

spec.describe('frontmatter.extract_fallback_description', function()
    spec.it('skips leading headings, takes first paragraph', function()
        spec.equal(fm.extract_fallback_description('# Title\n\nThe real desc.\n\nMore.'), 'The real desc.')
    end)
end)

spec.describe('skills.registry', function()
    spec.it('splits dynamic vs conditional and excludes disabled from model view', function()
        registry.set_skills({
            mkskill('always'),
            mkskill('hidden', { disabled = true }),
            mkskill('cond1', { paths = { '*.lua' } }),
        })
        local vis = registry.get_model_visible()
        local names = {}; for _, s in ipairs(vis) do names[s.name] = true end
        spec.truthy(names['always'], 'always visible')
        spec.truthy(not names['hidden'], 'hidden excluded from model view')
        spec.truthy(not names['cond1'], 'conditional not visible until activated')
        spec.equal(#registry.list_conditional(), 1)
        -- user-invocable includes hidden + conditional
        spec.equal(#registry.all_user_invocable(), 3)
    end)
    spec.it('activates a conditional skill', function()
        registry.set_skills({ mkskill('c', { paths = { '*.md' } }) })
        spec.equal(registry.activate_conditional('c'), true)
        spec.equal(registry.activate_conditional('c'), false)   -- already activated
        spec.equal(#registry.get_model_visible(), 1)
    end)
end)

spec.describe('skills.budget', function()
    spec.it('formats a listing with descriptions', function()
        local out = budget.format({ mkskill('a', { description = 'aaa' }), mkskill('b', { description = 'bbb' }) })
        spec.contains(out, '- a: aaa')
        spec.contains(out, '- b: bbb')
    end)
    spec.it('system reminder wraps the listing', function()
        local r = budget.format_system_reminder({ mkskill('a') })
        spec.contains(r, '<system-reminder>')
        spec.contains(r, 'Skill(skill=')
        spec.contains(r, '- a:')
    end)
    spec.it('empty when no skills', function()
        spec.equal(budget.format_system_reminder({}), '')
    end)
end)

spec.describe('skills.conditional', function()
    spec.it('extracts file paths per tool', function()
        spec.equal(cond.extract_tool_file_paths('Read', { file_path = 'a.lua' })[1], 'a.lua')
        spec.equal(cond.extract_tool_file_paths('Glob', { path = 'src' })[1], 'src')
        spec.equal(#cond.extract_tool_file_paths('Bash', { command = 'ls' }), 0)
    end)
    spec.it('activates a conditional skill when a touched path matches', function()
        registry.set_skills({ mkskill('luae', { paths = { '*.lua' } }) })
        local activated = cond.activate_for_paths({ 'foo.lua' }, '.')
        spec.equal(activated[1], 'luae')
        -- now visible to the model
        spec.equal(#registry.get_model_visible(), 1)
    end)
    spec.it('does not activate on a non-match', function()
        registry.set_skills({ mkskill('luae', { paths = { '*.lua' } }) })
        spec.equal(#cond.activate_for_paths({ 'foo.txt' }, '.'), 0)
    end)
end)

spec.describe('skills facade + Skill tool', function()
    spec.it('render_body substitutes the variables', function()
        local s = mkskill('s', { body = 'dir=${CLAUDE_SKILL_DIR} sid=${CLAUDE_SESSION_ID} args=$ARGUMENTS' })
        local out = skills.render_body(s, 'hello', 'sess7')
        spec.contains(out, 'args=hello')
        spec.contains(out, 'sid=sess7')
        spec.contains(out, 'dir=/x/s')
    end)
    spec.it('find_invocable is case-insensitive', function()
        registry.set_skills({ mkskill('Code-Review') })
        spec.truthy(skills.find_invocable('code-review'))
    end)
    spec.it('Skill tool returns the body for a valid skill', function()
        registry.set_skills({ mkskill('go', { body = 'STEP ONE' }) })
        local r = skill_tool.call({ skill = 'go' }, { cwd = '.', session_id = 'x' })
        spec.truthy(not r.is_error)
        spec.contains(r.content, 'STEP ONE')
    end)
    spec.it('Skill tool rejects unknown / fork / disabled', function()
        registry.set_skills({ mkskill('forky', { fork = true }), mkskill('hush', { disabled = true }) })
        spec.equal(skill_tool.call({ skill = 'nope' }, {}).is_error, true)
        spec.equal(skill_tool.call({ skill = 'forky' }, {}).is_error, true)
        spec.equal(skill_tool.call({ skill = 'hush' }, {}).is_error, true)
        spec.equal(skill_tool.call({ skill = 'bad name!' }, {}).is_error, true)
    end)
end)

spec.describe('skills.loader (on disk)', function()
    spec.it('discovers <cwd>/.xagent/skills/<name>/SKILL.md', function()
        local dir = './_skills_test'
        local sk = dir .. '/.xagent/skills/greet'
        os.execute('mkdir "' .. sk .. '" 2>nul || mkdir -p "' .. sk .. '"')
        local f = io.open(sk .. '/SKILL.md', 'wb')
        f:write('---\nname: greet\ndescription: say hi\n---\nGreet the user.\n'); f:close()

        local res = loader.load_all(dir)
        local found
        for _, s in ipairs(res.skills) do if s.name == 'greet' then found = s end end
        spec.truthy(found, 'greet skill discovered')
        spec.equal(found.description, 'say hi')
        spec.contains(found.body, 'Greet the user')

        os.remove(sk .. '/SKILL.md')
        os.execute('rmdir "' .. sk .. '" 2>nul; rmdir "' .. dir .. '/.xagent/skills" 2>nul; ' ..
                   'rmdir "' .. dir .. '/.xagent" 2>nul; rmdir "' .. dir .. '" 2>nul')
    end)
end)

return {
    __init = function()
        local failed = spec.finish()
        if failed > 0 then os.exit(1) end
        xthread.stop(0)
    end,
}
