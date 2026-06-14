-- xagent/tools/edit.lua — the Edit tool. Find-and-replace in a file.

local path = dofile('scripts/core/share/xpath.lua')
local edit_core = require('xagent.tools.edit_core')

return {
    name = 'Edit',
    description =
        'Replace a string in a file. By default old_string must match exactly ' ..
        'once; set replace_all=true to replace every occurrence (e.g. renaming a ' ..
        'symbol). Read the file first so old_string matches verbatim.',
    input_schema = {
        type = 'object',
        properties = {
            file_path = { type = 'string', description = 'Path to the file to edit' },
            old_string = { type = 'string', description = 'Existing text to replace (must be unique unless replace_all)' },
            new_string = { type = 'string', description = 'Replacement text' },
            replace_all = { type = 'boolean', description = 'Replace all occurrences (default false)' },
        },
        required = { 'file_path', 'old_string', 'new_string' },
    },
    is_read_only = function() return false end,

    call = function(input, ctx)
        if type(input.file_path) ~= 'string' or input.file_path == ''
            or type(input.old_string) ~= 'string' or type(input.new_string) ~= 'string' then
            return { content = 'Error: file_path, old_string and new_string are required', is_error = true }
        end
        local resolved = path.resolve(input.file_path, ctx and ctx.cwd)

        local f, oerr = io.open(resolved, 'rb')
        if not f then
            return { content = 'Error: cannot open ' .. resolved .. ': ' .. tostring(oerr), is_error = true }
        end
        local original = f:read('*a') or ''
        f:close()

        local ok, result = pcall(edit_core.apply_edit, original, {
            old_string = input.old_string,
            new_string = input.new_string,
            replace_all = input.replace_all == true,
        })
        if not ok then
            return { content = 'Error: ' .. tostring(result) .. ' (' .. resolved .. ')', is_error = true }
        end

        local wf, werr = io.open(resolved, 'wb')
        if not wf then
            return { content = 'Error: cannot write ' .. resolved .. ': ' .. tostring(werr), is_error = true }
        end
        wf:write(result.content)
        wf:close()

        local note = result.replacements > 1 and (' (' .. result.replacements .. ' occurrences)') or ''
        return {
            content = 'Updated ' .. resolved .. note .. '\n' ..
                edit_core.build_preview(input.old_string, input.new_string),
        }
    end,
}
