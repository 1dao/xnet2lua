-- xagent/tools/memory_write.lua — let the agent persist a project memory.
-- Appends a titled section to <cwd>/AGENT.md (created if absent), which the
-- system prompt re-reads next session (see context/project_md.lua). Append-only
-- so it never clobbers existing notes.

local path = dofile('scripts/core/share/xpath.lua')
local fs = dofile('scripts/core/share/xfs.lua')
local text = dofile('scripts/core/share/xtext.lua')

return {
    name = 'MemoryWrite',
    description =
        'Save a durable project memory (a fact, convention, or decision worth ' ..
        'remembering across sessions). It is appended to AGENT.md and re-loaded ' ..
        'into context next time. Use for non-obvious project knowledge, not for ' ..
        'things already in the code or this conversation.',
    input_schema = {
        type = 'object',
        properties = {
            name = { type = 'string', description = 'Short memory title' },
            description = { type = 'string', description = 'One-line summary' },
            type = { type = 'string', description = 'user | feedback | project | reference' },
            content = { type = 'string', description = 'The memory body' },
        },
        required = { 'name', 'content' },
    },
    is_read_only = function() return false end,

    call = function(input, ctx)
        if type(input.name) ~= 'string' or input.name == '' or type(input.content) ~= 'string' then
            return { content = 'Error: name and content are required', is_error = true }
        end
        local file = path.resolve('AGENT.md', ctx and ctx.cwd)
        local existing = fs.read_file(file) or ''

        local section = string.format('\n\n## %s%s\n%s\n',
            text.valid_utf8(input.name),
            input.description and (' — ' .. text.valid_utf8(input.description)) or '',
            text.valid_utf8(input.content))

        local ok, err = fs.write_file(file, existing .. section)
        if not ok then
            return { content = 'Error writing memory: ' .. tostring(err), is_error = true }
        end
        return { content = 'Saved memory "' .. input.name .. '" to ' .. file }
    end,
}
