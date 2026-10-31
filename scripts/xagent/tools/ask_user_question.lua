-- Structured questions are host interactions, independent of write permission.
local json = require('xutils')
local M = {
    name = 'AskUserQuestion',
    description = 'Ask the user for missing information or a decision and wait for their answer. ' ..
        'Provide 1-4 questions, optionally with 2-6 choices; multi_select allows multiple choices. ' ..
        'Single-choice clicks and free-text Enter immediately advance to the next question. ' ..
        'The user can always type their own answer. Omit options for free text. ' ..
        'The user may skip a question; skipped=true means they supplied no answer, so do not invent one. ' ..
        'Use only when the answer materially affects the task; never guess an answer or use this for tool permissions.',
    input_schema = {
        type = 'object',
        properties = {
            questions = {
                type = 'array', minItems = 1, maxItems = 4,
                items = {
                    type = 'object',
                    properties = {
                        id = { type = 'string', description = 'Unique stable question identifier' },
                        question = { type = 'string', description = 'A concise, self-contained question' },
                        options = {
                            type = 'array', minItems = 2, maxItems = 6,
                            items = {
                                type = 'object',
                                properties = {
                                    label = { type = 'string' },
                                    description = { type = 'string' },
                                },
                                required = { 'label' },
                            },
                        },
                        multi_select = { type = 'boolean', description = 'Default false' },
                    },
                    required = { 'id', 'question' },
                },
            },
        },
        required = { 'questions' },
    },
    is_read_only = function() return true end,
    is_concurrency_safe = function() return false end,
}

local function nonblank(s, limit)
    return type(s) == 'string' and #s <= limit and s:find('%S') ~= nil
end

local function array_size(v)
    if type(v) ~= 'table' then return nil end
    local n = #v
    for k in pairs(v) do
        if type(k) ~= 'number' or k % 1 ~= 0 or k < 1 or k > n then return nil end
    end
    return n
end

function M.validate(input)
    local qs = type(input) == 'table' and input.questions
    local n = array_size(qs)
    if not n or n < 1 or n > 4 then return nil, 'questions must contain 1-4 questions' end
    local ids, questions = {}, {}
    for _, q in ipairs(qs) do
        if type(q) ~= 'table' or not nonblank(q.id, 80) or ids[q.id] then
            return nil, 'each question needs a unique non-empty id (max 80 bytes)'
        end
        if not nonblank(q.question, 2000) then return nil, 'question must be non-empty (max 2000 bytes)' end
        if q.multi_select ~= nil and type(q.multi_select) ~= 'boolean' then return nil, 'multi_select must be boolean' end
        ids[q.id] = true
        local options, labels = {}, {}
        if q.options ~= nil then
            local count = array_size(q.options)
            if not count or count < 2 or count > 6 then return nil, 'options must contain 2-6 choices, or be omitted' end
            for _, option in ipairs(q.options) do
                if type(option) ~= 'table' or not nonblank(option.label, 300) or labels[option.label] then
                    return nil, 'option labels must be non-empty and unique (max 300 bytes)'
                end
                if option.description ~= nil and (type(option.description) ~= 'string' or #option.description > 1000) then
                    return nil, 'option description must be text (max 1000 bytes)'
                end
                labels[option.label] = true
                options[#options + 1] = { label = option.label, description = option.description or '' }
            end
        end
        questions[#questions + 1] = { id = q.id, question = q.question, options = options,
            multi_select = q.multi_select == true }
    end
    return { questions = questions }
end

-- Validate host replies too: empty/invalid selections must never become consent.
function M.validate_answers(request, answers)
    if type(answers) ~= 'table' then return nil, 'answers are required' end
    local result = {}
    for _, q in ipairs(request.questions) do
        local a = answers[q.id]
        if type(a) ~= 'table' then return nil, '请回答：' .. q.question end
        if a.skipped == true then
            result[q.id] = { skipped = true, selected = setmetatable({}, json.json_array_mt), text = '' }
        else
            local selected = a.selected or {}
            local n = array_size(selected)
            if not n or (not q.multi_select and n > 1) then return nil, '选择数量无效' end
            local allowed, seen, values = {}, {}, setmetatable({}, json.json_array_mt)
            for _, o in ipairs(q.options) do allowed[o.label] = true end
            for _, label in ipairs(selected) do
                if not allowed[label] or seen[label] then return nil, '选项无效' end
                seen[label] = true; values[#values + 1] = label
            end
            local value = a.text or ''
            if type(value) ~= 'string' or #value > 16000 then return nil, '输入内容过长（最多 16000 字节）' end
            if n == 0 and not value:find('%S') then return nil, '请选择选项或输入回答' end
            result[q.id] = { selected = values, text = value }
        end
    end
    return result
end

function M.call(input, ctx)
    local request, err = M.validate(input)
    if not request then return { content = 'Error: ' .. err, is_error = true } end
    if not ctx or type(ctx.request_user_input) ~= 'function' then
        return { content = 'Error: user input is unavailable in this host. Ask in your final response and wait for a new user message.', is_error = true }
    end
    local reply = ctx.request_user_input(request)
    if not reply or reply.cancelled then
        return { content = '{"cancelled":true}', is_error = true }
    end
    local answers, answer_err = M.validate_answers(request, reply.answers)
    if not answers then return { content = 'Error: ' .. answer_err, is_error = true } end
    return { content = assert(json.json_pack({ answers = answers })) }
end

return M
