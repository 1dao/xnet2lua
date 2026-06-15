-- xagent/tools/todo_write.lua — session task list the agent maintains while
-- working through a multi-step task. Each call REPLACES the whole list. The
-- formatted list is returned (and shown in the transcript); the current list is
-- also exposed via M.current() for the UI.

local M = {
    todos = {},   -- { { content, status, activeForm } }
}

local MARK = { pending = '[ ]', in_progress = '[~]', completed = '[x]' }

local function format(todos)
    if #todos == 0 then return '(no todos)' end
    local out = {}
    for _, t in ipairs(todos) do
        out[#out + 1] = (MARK[t.status] or '[ ]') .. ' ' .. tostring(t.content or '')
    end
    return table.concat(out, '\n')
end

M.tool = {
    name = 'TodoWrite',
    description =
        'Create or update the task list for the current work. Pass the FULL list ' ..
        'each time (it replaces the previous one). Use it to plan and track multi-' ..
        'step tasks: mark exactly one item in_progress, complete items as you go.',
    input_schema = {
        type = 'object',
        properties = {
            todos = {
                type = 'array',
                description = 'The full task list',
                items = {
                    type = 'object',
                    properties = {
                        content = { type = 'string', description = 'The task (imperative)' },
                        status = { type = 'string', description = 'pending | in_progress | completed' },
                        activeForm = { type = 'string', description = 'Present-continuous form shown while active' },
                    },
                    required = { 'content', 'status' },
                },
            },
        },
        required = { 'todos' },
    },
    is_read_only = function() return false end,

    call = function(input)
        if type(input.todos) ~= 'table' then
            return { content = 'Error: todos array is required', is_error = true }
        end
        local list = {}
        for _, t in ipairs(input.todos) do
            list[#list + 1] = {
                content = tostring(t.content or ''),
                status = t.status or 'pending',
                activeForm = t.activeForm,
            }
        end
        M.todos = list
        return { content = 'Todos updated:\n' .. format(list) }
    end,
}

function M.current() return M.todos end

return M
