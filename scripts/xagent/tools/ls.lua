-- xagent/tools/ls.lua — the LS tool. Lists the immediate children of a dir.
--
-- xutils.scan_dir is recursive + files-only, so we reconstruct the immediate
-- children from the relative paths it returns (directories inferred from any
-- entry that contains a separator, marked with a trailing '/').

local xutils = require('xutils')
local path = dofile('scripts/core/share/xpath.lua')

local MAX_ENTRIES = 300

return {
    name = 'LS',
    description = 'List the immediate files and subdirectories of a directory. ' ..
        'Subdirectories are shown with a trailing "/".',
    input_schema = {
        type = 'object',
        properties = {
            path = { type = 'string', description = 'Directory to list (default: workspace root)' },
        },
        -- NOTE: no `required` key. An empty Lua table would json_pack to `{}`
        -- (object), but JSON Schema requires `required` to be an array — and the
        -- API rejects the whole request (400) if it's an object. Omit it instead.
    },
    is_read_only = function() return true end,
    is_concurrency_safe = function() return true end,

    call = function(input, ctx)
        local dir = (input.path and input.path ~= '') and path.resolve(input.path, ctx and ctx.cwd)
            or (ctx and ctx.cwd) or '.'

        local entries, err = xutils.scan_dir(dir)
        if not entries then
            return { content = 'Error: cannot list ' .. dir .. ': ' .. tostring(err), is_error = true }
        end

        -- scan_dir yields { path = <full>, rel = <relative> } tables, files-only.
        local seen, children = {}, {}
        for _, e in ipairs(entries) do
            local rel = (e.rel or ''):gsub('\\', '/')
            local first = rel:match('^([^/]+)')
            if first then
                local label = rel:find('/') and (first .. '/') or first
                if not seen[label] then seen[label] = true; children[#children + 1] = label end
            end
        end
        table.sort(children)

        if #children == 0 then return { content = '(empty) ' .. dir } end
        local extra = ''
        if #children > MAX_ENTRIES then
            local t = {}; for i = 1, MAX_ENTRIES do t[i] = children[i] end
            extra = string.format('\n...[%d more]', #children - MAX_ENTRIES)
            children = t
        end
        return { content = dir .. ':\n' .. table.concat(children, '\n') .. extra }
    end,
}
