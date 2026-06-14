-- xagent/main.lua — headless entry (M1 vertical slice: Read + Bash + loop).
--
-- Runs one user turn to completion against the configured LLM, with the Read and
-- Bash tools wired in. The model streams text, calls tools, observes results,
-- and continues until it stops. Output goes to real stdout via io.write.
--
-- Run (PowerShell):
--   .\bin\xnet.exe scripts\xagent\main.lua
--   .\bin\xnet.exe scripts\xagent\main.lua "PROMPT=read scripts\core\share\xsse.lua and summarize it"
--   .\bin\xnet.exe scripts\xagent\main.lua MODEL=deepseek-v4-pro MAX_TOKENS=4096

package.path = 'scripts/?.lua;' .. package.path

local router      = dofile('scripts/core/share/xrouter.lua')   -- main needs the handler for subprocess RPC replies
local xutils      = require('xutils')
local config      = require('xagent.config')
local registry    = require('xagent.tools.registry')
local loop        = require('xagent.core.loop')
local system_prompt = require('xagent.context.system_prompt')
local subprocess  = require('xagent.proc.subprocess')

-- Register the M1 tools.
registry.register(require('xagent.tools.read'))
registry.register(require('xagent.tools.write'))
registry.register(require('xagent.tools.edit'))
registry.register(require('xagent.tools.ls'))
registry.register(require('xagent.tools.glob'))
registry.register(require('xagent.tools.grep'))
registry.register(require('xagent.tools.bash'))
registry.register(require('xagent.tools.multi_edit'))
registry.register(require('xagent.tools.web_fetch'))
registry.register(require('xagent.tools.memory_write'))
registry.register(require('xagent.tools.todo_write').tool)
registry.register(require('xagent.tools.skill'))
local skills = require('xagent.skills')

local IS_WIN = (package.config:sub(1, 1) == '\\')
local function out(s) io.write(s); io.flush() end

-- argv KEY=VALUE overrides.
local argv = {}
if type(arg) == 'table' then
    for _, it in ipairs(arg) do
        local k, v = tostring(it):match('^([%w_]+)=(.*)$'); if k then argv[k] = v end
    end
end

local DEFAULT_PROMPT =
    'Use the Bash tool to list the files in scripts/core/share, then use the Read ' ..
    'tool to read scripts/core/share/xsse.lua, and summarize in one sentence what ' ..
    'that file does.'

local function compact(v)
    local ok, s = pcall(xutils.json_pack, v)
    if not ok then return tostring(v) end
    if #s > 200 then s = s:sub(1, 200) .. '...' end
    return s
end

-- Headless event printer.
local function make_printer()
    local streaming = false
    return function(ev)
        if ev.type == 'text' then
            streaming = true
            out(ev.text)
        elseif ev.type == 'tool_use' then
            if streaming then out('\n'); streaming = false end
            out('\n\27[36m> ' .. ev.name .. '\27[0m ' .. compact(ev.input) .. '\n')
        elseif ev.type == 'tool_result' then
            local c = ev.result and ev.result.content or ''
            if type(c) ~= 'string' then c = '[non-text result]' end
            local preview = c:gsub('\r', '')
            if #preview > 500 then preview = preview:sub(1, 500) .. '\n  ...' end
            preview = preview:gsub('\n', '\n  ')
            out('  ' .. preview .. (ev.result and ev.result.is_error and '  \27[31m[error]\27[0m' or '') .. '\n')
        elseif ev.type == 'compact_start' then
            if streaming then out('\n'); streaming = false end
            out('\27[35m[compacting context…]\27[0m\n')
        elseif ev.type == 'compact' then
            if streaming then out('\n'); streaming = false end
            local kind = ev.did_compact and 'summarized' or (ev.did_micro and 'micro-compacted' or 'noop')
            out('\27[35m[context ' .. kind ..
                (ev.kept_tail and (', kept ' .. ev.kept_tail .. ' recent') or '') .. ']\27[0m\n')
        elseif ev.type == 'budget' then
            local b = ev.budget
            if b and b.state ~= 'normal' then
                out(string.format('\27[90m[context ~%d/%d tok (%.0f%%) %s]\27[0m\n',
                    b.estimated, b.context_window, b.percent * 100, b.state))
            end
        elseif ev.type == 'done' then
            if streaming then out('\n'); streaming = false end
            out('\n\27[90m--- done (' .. tostring(ev.stop_reason) .. ') ---\27[0m\n')
        elseif ev.type == 'error' then
            out('\n\27[31mERROR: ' .. tostring(ev.error) .. '\27[0m\n')
        end
    end
end

local function __init()
    local cfg = config.load()
    if not cfg.api_key or cfg.api_key == '' then
        io.stderr:write('ERROR: no token — set XAGENT_AUTH_TOKEN in xagent.local.cfg\n')
        xthread.stop(2); return
    end
    if argv.MODEL then cfg.model = argv.MODEL end

    assert(xnet.init())
    local ok, err = subprocess.setup()
    if not ok then io.stderr:write('subprocess setup failed: ' .. tostring(err) .. '\n'); xthread.stop(2); return end

    -- Prompt resolution. On Windows, non-ASCII argv is mangled by the console
    -- code page (GBK), so Chinese/Unicode prompts MUST come from a UTF-8 file
    -- via PROMPT_FILE=path (or wait for the GUI, which is UTF-8 native).
    local prompt
    local pfile = argv.PROMPT_FILE or os.getenv('PROMPT_FILE')
    if pfile and pfile ~= '' then
        local f, ferr = io.open(pfile, 'rb')
        if not f then
            io.stderr:write('ERROR: cannot read PROMPT_FILE ' .. pfile .. ': ' .. tostring(ferr) .. '\n')
            xthread.stop(2); return
        end
        prompt = (f:read('*a') or ''):gsub('^\239\187\191', ''):gsub('%s+$', '')  -- strip UTF-8 BOM + trailing ws
        f:close()
    end
    prompt = prompt or argv.PROMPT or os.getenv('PROMPT') or DEFAULT_PROMPT
    local max_tokens = tonumber(argv.MAX_TOKENS) or 4096

    local co = coroutine.create(function()
        -- Resolve the absolute cwd once (used by tools + the system prompt).
        local r = subprocess.run({ cmd = IS_WIN and 'cd' or 'pwd' })
        local cwd = (r.stdout or '.'):gsub('%s+$', '')

        skills.bootstrap(cwd)
        local ctx = { cwd = cwd }
        local sys = system_prompt.build({ cwd = cwd })
        local rem = skills.reminder()
        if rem ~= '' then sys = sys .. '\n\n' .. rem end
        local messages = { { role = 'user', content = prompt } }

        out('\27[90m# ' .. cfg.model .. ' @ ' .. cfg.base_url .. '\27[0m\n')
        out('\27[1m> ' .. prompt .. '\27[0m\n\n')

        local res = loop.run({
            cfg = cfg,
            messages = messages,
            system = sys,
            tools = registry.to_api_params(),
            ctx = ctx,
            max_tokens = max_tokens,
            on_event = make_printer(),
        })

        out(string.format('\27[90m[usage] in=%d out=%d turns=%d\27[0m\n',
            res.usage.input_tokens, res.usage.output_tokens, res.turns))
        xthread.stop(res.stop_reason == 'error' and 1 or 0)
    end)

    local rok, rerr = coroutine.resume(co)
    if not rok then
        io.stderr:write('agent coroutine error: ' .. tostring(rerr) .. '\n')
        xthread.stop(1)
    end
end

return {
    __tick_ms = 10,
    __thread_handle = router.handle,
    __init = __init,
    __uninit = function() if xnet and xnet.uninit then xnet.uninit() end end,
}
