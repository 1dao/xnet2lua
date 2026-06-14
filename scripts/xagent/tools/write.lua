-- xagent/tools/write.lua — the Write tool. Creates or overwrites a file.

local path = dofile('scripts/core/share/xpath.lua')

return {
    name = 'Write',
    description =
        'Write content to a file, creating it or overwriting it entirely. The ' ..
        'parent directory must already exist. Prefer Edit for changing part of an ' ..
        'existing file.',
    input_schema = {
        type = 'object',
        properties = {
            file_path = { type = 'string', description = 'Absolute or relative path to write' },
            content = { type = 'string', description = 'Full file content' },
        },
        required = { 'file_path', 'content' },
    },
    is_read_only = function() return false end,

    call = function(input, ctx)
        local fp = input.file_path
        if type(fp) ~= 'string' or fp == '' then
            return { content = 'Error: file_path is required', is_error = true }
        end
        if type(input.content) ~= 'string' then
            return { content = 'Error: content is required', is_error = true }
        end
        local resolved = path.resolve(fp, ctx and ctx.cwd)

        local f, err = io.open(resolved, 'wb')
        if not f then
            return { content = 'Error: cannot open ' .. resolved .. ' for writing: ' .. tostring(err), is_error = true }
        end
        f:write(input.content)
        f:close()
        return { content = string.format('Wrote %s (%d bytes)', resolved, #input.content) }
    end,
}
