-- xagent/tools/bash.lua — the Bash tool. Runs a shell command via the
-- thread-offloaded subprocess runner (proc/subprocess.lua). stderr is merged
-- into stdout; a nonzero exit is reported and marks the result as an error.
--
-- MUST be called from within the agent coroutine (subprocess.run yields).

local subprocess = require('xagent.proc.subprocess')
local text = dofile('scripts/core/share/xtext.lua')

local DEFAULT_TIMEOUT_MS = 120000
local MAX_OUTPUT = 30000

return {
    name = 'Bash',
    description =
        'Run a shell command in the workspace and return its merged stdout/stderr ' ..
        'and exit code. Use for builds, tests, git, and other shell tasks. Prefer ' ..
        'the Read tool for reading files.',
    input_schema = {
        type = 'object',
        properties = {
            command = { type = 'string', description = 'The shell command to run' },
            timeout = { type = 'number', description = 'Timeout in seconds (default 120)' },
        },
        required = { 'command' },
    },
    is_read_only = function() return false end,

    call = function(input, ctx)
        local cmd = input.command
        if type(cmd) ~= 'string' or cmd == '' then
            return { content = 'Error: command is required', is_error = true }
        end
        local timeout_ms = (tonumber(input.timeout) and tonumber(input.timeout) * 1000) or DEFAULT_TIMEOUT_MS

        local r = subprocess.run({ cmd = cmd, cwd = ctx and ctx.cwd, timeout_ms = timeout_ms })
        if not r.ok then
            return { content = 'Error: ' .. tostring(r.err), is_error = true }
        end

        local out = r.stdout or ''
        out = text.truncate(out, MAX_OUTPUT, string.format('\n...[truncated, %d bytes total]', #out))
        if out == '' then out = '(no output)' end
        if r.exit_code ~= 0 then
            out = out .. '\n[exit code: ' .. tostring(r.exit_code) .. ']'
        end
        return { content = out, is_error = r.exit_code ~= 0 }
    end,
}
