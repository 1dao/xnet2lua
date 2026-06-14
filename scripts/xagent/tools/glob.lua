-- xagent/tools/glob.lua — the Glob tool. Find files matching a glob pattern.
-- Uses xutils.scan_dir (recursive, files-only) + glob matching. Sorted by path
-- (mtime sort would need a stat the scanner doesn't return — alphabetical for now).

local xutils = require('xutils')
local globm = dofile('scripts/core/share/xglob.lua')
local path = dofile('scripts/core/share/xpath.lua')

local MAX_RESULTS = 200

return {
    name = 'Glob',
    description =
        'Find files whose path matches a glob pattern (e.g. "**/*.lua", ' ..
        '"src/*.c"). Searches under `path` (default the workspace). Returns ' ..
        'matching file paths.',
    input_schema = {
        type = 'object',
        properties = {
            pattern = { type = 'string', description = 'Glob pattern, e.g. **/*.lua' },
            path = { type = 'string', description = 'Directory to search under (default: workspace root)' },
        },
        required = { 'pattern' },
    },
    is_read_only = function() return true end,
    is_concurrency_safe = function() return true end,

    call = function(input, ctx)
        if type(input.pattern) ~= 'string' or input.pattern == '' then
            return { content = 'Error: pattern is required', is_error = true }
        end
        local base = (input.path and input.path ~= '') and path.resolve(input.path, ctx and ctx.cwd)
            or (ctx and ctx.cwd) or '.'

        local entries, err = xutils.scan_dir(base)
        if not entries then
            return { content = 'Error: cannot scan ' .. base .. ': ' .. tostring(err), is_error = true }
        end

        -- scan_dir yields { path = <full>, rel = <relative> } tables, files-only.
        local matches = {}
        for _, e in ipairs(entries) do
            local rel = e.rel
            if rel and globm.match(input.pattern, rel) then
                matches[#matches + 1] = rel
            end
        end
        table.sort(matches)

        if #matches == 0 then
            return { content = 'No files matching ' .. input.pattern .. ' under ' .. base }
        end
        local shown = matches
        local extra = ''
        if #matches > MAX_RESULTS then
            shown = {}
            for i = 1, MAX_RESULTS do shown[i] = matches[i] end
            extra = string.format('\n...[%d more]', #matches - MAX_RESULTS)
        end
        return { content = string.format('%d match(es) under %s:\n%s%s',
            #matches, base, table.concat(shown, '\n'), extra) }
    end,
}
