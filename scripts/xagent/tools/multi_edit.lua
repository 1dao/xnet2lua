-- xagent/tools/multi_edit.lua — apply several string edits to one file in one
-- call. Edits are applied sequentially (each sees the previous result), and the
-- whole batch is atomic: if any edit fails, the file is left untouched.

local path = dofile('scripts/core/share/xpath.lua')
local edit_core = require('xagent.tools.edit_core')

return {
    name = 'MultiEdit',
    description =
        'Make several find-and-replace edits to a single file in one call. Edits ' ..
        'apply in order (each operates on the result of the previous). All-or-' ..
        'nothing: if any edit fails to match, the file is not changed.',
    input_schema = {
        type = 'object',
        properties = {
            file_path = { type = 'string', description = 'Path to the file to edit' },
            edits = {
                type = 'array',
                description = 'List of edits to apply in order',
                items = {
                    type = 'object',
                    properties = {
                        old_string = { type = 'string', description = 'Text to replace (unique unless replace_all)' },
                        new_string = { type = 'string', description = 'Replacement text' },
                        replace_all = { type = 'boolean', description = 'Replace all occurrences (default false)' },
                    },
                    required = { 'old_string', 'new_string' },
                },
            },
        },
        required = { 'file_path', 'edits' },
    },
    is_read_only = function() return false end,

    call = function(input, ctx)
        if type(input.file_path) ~= 'string' or input.file_path == '' or type(input.edits) ~= 'table' then
            return { content = 'Error: file_path and edits are required', is_error = true }
        end
        local resolved = path.resolve(input.file_path, ctx and ctx.cwd)

        local f, oerr = io.open(resolved, 'rb')
        if not f then
            return { content = 'Error: cannot open ' .. resolved .. ': ' .. tostring(oerr), is_error = true }
        end
        local content = f:read('*a') or ''
        f:close()

        local total = 0
        for i, e in ipairs(input.edits) do
            local ok, res = pcall(edit_core.apply_edit, content, {
                old_string = e.old_string, new_string = e.new_string,
                replace_all = e.replace_all == true,
            })
            if not ok then
                return { content = string.format('Error in edit #%d: %s (file unchanged)', i, tostring(res)), is_error = true }
            end
            content = res.content
            total = total + res.replacements
        end

        local wf, werr = io.open(resolved, 'wb')
        if not wf then
            return { content = 'Error: cannot write ' .. resolved .. ': ' .. tostring(werr), is_error = true }
        end
        wf:write(content)
        wf:close()
        return { content = string.format('Applied %d edit(s) to %s (%d replacement(s))',
            #input.edits, resolved, total) }
    end,
}
