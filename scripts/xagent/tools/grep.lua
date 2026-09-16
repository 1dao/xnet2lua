-- xagent/tools/grep.lua — the Grep tool. Content search via ripgrep (rg),
-- run through the thread-offloaded subprocess pool. rg gives real regex,
-- speed, and .gitignore awareness. MUST run inside the agent coroutine.
--
-- Arguments go out as ARGV, never as a hand-quoted command string. This used to
-- wrap each one in double quotes, which does not protect a POSIX shell's $,
-- backtick or backslash: searching for `$(id)` or a literal `$HOME` made the
-- shell substitute or expand it, so the pattern the model asked for was not the
-- pattern rg received. subprocess.run{ argv = ... } quotes per-platform with the
-- real rules (see xproc_worker.lua).

local subprocess = require('xagent.proc.subprocess')
local text = dofile('scripts/core/share/xtext.lua')

local MAX_OUTPUT = 20000
local IS_WIN = (package.config:sub(1, 1) == '\\')

return {
    name = 'Grep',
    description =
        'Search file contents with a regular expression (ripgrep). Returns ' ..
        'matching lines with file:line prefixes. Use `glob` to restrict to ' ..
        'matching files (e.g. "*.lua") and `path` to scope the search.',
    input_schema = {
        type = 'object',
        properties = {
            pattern = { type = 'string', description = 'Regular expression to search for' },
            path = { type = 'string', description = 'File or directory to search (default: workspace)' },
            glob = { type = 'string', description = 'Only search files matching this glob (e.g. *.lua)' },
            ignore_case = { type = 'boolean', description = 'Case-insensitive search' },
        },
        required = { 'pattern' },
    },
    is_read_only = function() return true end,
    is_concurrency_safe = function() return true end,

    call = function(input, ctx)
        if type(input.pattern) ~= 'string' or input.pattern == '' then
            return { content = 'Error: pattern is required', is_error = true }
        end
        -- The one thing per-platform quoting cannot cover: cmd.exe expands
        -- %VAR% even inside double quotes, and `cmd /c` has no escape for it.
        -- Refusing beats silently searching for something else.
        if IS_WIN then
            for _, v in ipairs({ input.pattern, input.path, input.glob }) do
                if type(v) == 'string' and v:match('%%[A-Za-z_][A-Za-z0-9_]*%%') then
                    return { content = 'Error: %VAR% cannot be passed through cmd.exe ' ..
                        'safely on Windows; escape or rephrase the pattern.', is_error = true }
                end
            end
        end

        local argv = { 'rg', '-n', '--no-heading', '--color', 'never', '--max-columns', '300' }
        if input.ignore_case then argv[#argv + 1] = '-i' end
        if input.glob and input.glob ~= '' then
            argv[#argv + 1] = '-g'; argv[#argv + 1] = input.glob
        end
        -- -e guards a pattern that starts with '-' from being read as a flag;
        -- '--' then does the same for the path.
        argv[#argv + 1] = '-e'; argv[#argv + 1] = input.pattern
        argv[#argv + 1] = '--'
        argv[#argv + 1] = (input.path and input.path ~= '') and input.path or '.'

        local r = subprocess.run({ argv = argv, cwd = ctx and ctx.cwd, timeout_ms = 30000 })
        if not r.ok then
            return { content = 'Error: ' .. tostring(r.err), is_error = true }
        end
        -- rg exit codes: 0 = matches, 1 = no matches, >=2 = error.
        if r.exit_code == 1 then
            return { content = 'No matches found.' }
        end
        if r.exit_code ~= 0 then
            return { content = 'Error (rg exit ' .. tostring(r.exit_code) .. '): ' .. (r.stdout or ''), is_error = true }
        end

        local out = text.truncate(r.stdout or '', MAX_OUTPUT)
        return { content = out }
    end,
}
