-- Offline specs for M2: session JSON round-trip (incl. tool blocks) and project
-- memory loading. No network. Run via: bin/xnet tests/lua/xagent_session_spec.lua

package.path = 'scripts/?.lua;' .. package.path

local spec = dofile('tests/lua/spec_helper.lua')
local session = require('xagent.session.session')
local project_md = require('xagent.context.project_md')
local fs = dofile('scripts/core/share/xfs.lua')

spec.describe('session persistence', function()
    spec.it('round-trips messages with tool_use/tool_result through JSON', function()
        local s = session.new({ cfg = { model = 'mdl' }, cwd = '/work' })
        s:add_user('hello')
        s.messages[#s.messages + 1] = {
            role = 'assistant',
            content = {
                { type = 'text', text = 'hi' },
                { type = 'tool_use', id = 't1', name = 'Read', input = { file_path = 'a.lua' } },
            },
        }
        s.messages[#s.messages + 1] = {
            role = 'user',
            content = { { type = 'tool_result', tool_use_id = 't1', content = 'data', is_error = true } },
        }
        s.usage.input_tokens = 123

        local path = assert(s:save('.'))           -- writes ./<id>.json
        local s2 = assert(session.load(path, { cfg = { model = 'mdl' } }))
        os.remove(path)

        spec.equal(s2.id, s.id)
        spec.equal(#s2.messages, 3)
        spec.equal(s2.messages[1].content, 'hello')
        spec.equal(s2.messages[2].content[2].name, 'Read')
        spec.equal(s2.messages[2].content[2].input.file_path, 'a.lua')
        spec.equal(s2.messages[3].content[1].is_error, true)
        spec.equal(s2.usage.input_tokens, 123)
    end)
end)

spec.describe('project_md', function()
    spec.it('loads AGENT.md from a directory', function()
        local dir = '_xa_pmtest'
        fs.mkdirp(dir)
        assert(fs.write_file(dir .. '/AGENT.md', '# memory\nrule-alpha\n'))

        local content, found = project_md.load(dir)
        spec.truthy(found, 'found a memory file')
        spec.contains(content or '', 'rule-alpha')

        os.remove(dir .. '/AGENT.md')
        if package.config:sub(1, 1) == '\\' then os.execute('rmdir "' .. dir .. '" >nul 2>nul')
        else os.execute('rmdir "' .. dir .. '" >/dev/null 2>&1') end
    end)

    spec.it('returns nil when no memory file exists', function()
        local content = project_md.load('_xa_definitely_missing_dir_zzz')
        spec.nil_value(content)
    end)
end)

return {
    __init = function()
        local failed = spec.finish()
        if failed > 0 then os.exit(1) end
        xthread.stop(0)
    end,
}
