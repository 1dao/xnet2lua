-- xagent/tools/registry.lua — the tool registry.
--
-- A tool is a plain table:
--   { name, description, input_schema (JSON-Schema table),
--     is_read_only = function() -> bool,
--     is_concurrency_safe = function(input) -> bool,   (optional)
--     call = function(input, ctx) -> { content = <string>, is_error = <bool?> } }

local M = {}

local tools = {}        -- name -> tool
local order = {}        -- registration order (stable api list)

function M.register(tool)
    assert(type(tool) == 'table' and type(tool.name) == 'string', 'register: bad tool')
    assert(type(tool.call) == 'function', 'register: tool.call required')
    if not tools[tool.name] then order[#order + 1] = tool.name end
    tools[tool.name] = tool
    return tool
end

function M.find(name)
    return tools[name]
end

function M.all()
    local list = {}
    for _, name in ipairs(order) do list[#list + 1] = tools[name] end
    return list
end

-- Convert registered tools to the Anthropic `tools` request param.
function M.to_api_params()
    local params = {}
    for _, name in ipairs(order) do
        local t = tools[name]
        params[#params + 1] = {
            name = t.name,
            description = t.description,
            input_schema = t.input_schema,
        }
    end
    return params
end

return M
