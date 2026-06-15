-- xagent/tools/grep.lua — the Grep tool. Content search via ripgrep (rg),
-- run through the thread-offloaded subprocess runner. rg gives real regex,
-- speed, and .gitignore awareness. MUST run inside the agent coroutine.

local subprocess = require('xagent.proc.subprocess')
local text = dofile('scripts/core/share/xtext.lua')

local MAX_OUTPUT = 20000

-- Double-quote an argument for the shell, escaping embedded quotes.
local function q(s)
    return '"' .. tostring(s):gsub('"', '\\"') .. '"'
end

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

        local parts = { 'rg', '-n', '--no-heading', '--color', 'never', '--max-columns', '300' }
        if input.ignore_case then parts[#parts + 1] = '-i' end
        if input.glob and input.glob ~= '' then
            parts[#parts + 1] = '-g'; parts[#parts + 1] = q(input.glob)
        end
        parts[#parts + 1] = '-e'; parts[#parts + 1] = q(input.pattern)
        parts[#parts + 1] = q((input.path and input.path ~= '') and input.path or '.')

        local r = subprocess.run({ cmd = table.concat(parts, ' '), cwd = ctx and ctx.cwd, timeout_ms = 30000 })
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
