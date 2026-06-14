-- xagent/test_session.lua — multi-turn conversation + persistence demo.
-- Turn 1 plants a codeword; turn 2 asks for it back WITHOUT tools (proving the
-- agent remembers earlier turns); then the session is saved and reloaded.
-- Run: bin/xnet scripts/xagent/test_session.lua

package.path = 'scripts/?.lua;' .. package.path

local router        = dofile('scripts/core/share/xrouter.lua')
local config        = require('xagent.config')
local registry      = require('xagent.tools.registry')
local system_prompt = require('xagent.context.system_prompt')
local project_md    = require('xagent.context.project_md')
local subprocess    = require('xagent.proc.subprocess')
local session       = require('xagent.session.session')

registry.register(require('xagent.tools.read'))
registry.register(require('xagent.tools.bash'))

local IS_WIN = (package.config:sub(1, 1) == '\\')
local function out(s) io.write(s); io.flush() end

local function printer(ev)
    if ev.type == 'text' then out(ev.text)
    elseif ev.type == 'tool_use' then out('\n> ' .. ev.name .. '\n')
    elseif ev.type == 'done' then out('\n')
    elseif ev.type == 'error' then out('\nERROR: ' .. tostring(ev.error) .. '\n') end
end

local function __init()
    local cfg = config.load()
    if not cfg.api_key or cfg.api_key == '' then
        io.stderr:write('ERROR: no token in xagent.local.cfg\n'); xthread.stop(2); return
    end
    assert(xnet.init())
    assert(subprocess.setup())

    local co = coroutine.create(function()
        local r = subprocess.run({ cmd = IS_WIN and 'cd' or 'pwd' })
        local cwd = (r.stdout or '.'):gsub('%s+$', '')
        local pmd, pmd_path = project_md.load(cwd)
        local sys = system_prompt.build({ cwd = cwd, project_md = pmd })

        out('project memory: ' .. (pmd_path or '(none)') .. '\n')

        local s = session.new({
            cfg = cfg, cwd = cwd, tools = registry.to_api_params(),
            system = sys, max_tokens = 600,
        })

        out('\n=== turn 1 ===\n')
        s:add_user('Remember this codeword for later: BANANA-42. Reply with just a brief acknowledgement, no tools.')
        s:run(printer)

        out('\n=== turn 2 (memory recall, no tools) ===\n')
        s:add_user('What codeword did I ask you to remember? Answer in one short sentence.')
        s:run(printer)

        out('\nmessages in history: ' .. #s.messages .. '\n')
        local path, serr = s:save()
        out('saved: ' .. tostring(path) .. (serr and (' err=' .. serr) or '') .. '\n')

        local s2, lerr = session.load(path, { cfg = cfg })
        if s2 then
            out('reloaded ok: id=' .. s2.id .. ' messages=' .. #s2.messages ..
                ' usage_in=' .. s2.usage.input_tokens .. '\n')
            local pass = (#s2.messages == #s.messages) and (s2.id == s.id)
            out('[session] ' .. (pass and 'PERSIST OK' or 'PERSIST MISMATCH') .. '\n')
            xthread.stop(pass and 0 or 1)
        else
            out('reload failed: ' .. tostring(lerr) .. '\n'); xthread.stop(1)
        end
    end)

    local ok, err = coroutine.resume(co)
    if not ok then io.stderr:write('coroutine error: ' .. tostring(err) .. '\n'); xthread.stop(1) end
end

return {
    __tick_ms = 10,
    __thread_handle = router.handle,
    __init = __init,
    __uninit = function() if xnet and xnet.uninit then xnet.uninit() end end,
}
