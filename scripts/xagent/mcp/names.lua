-- xagent/mcp/names.lua — MCP tool-name <-> (server, tool) mapping.
--
-- A bridged MCP tool is exposed to the model as `mcp__<server>__<tool>` so the
-- agent loop, the registry, and (later) the permission system can route a call
-- back to the right server unambiguously. Double underscore is the delimiter;
-- a server name that itself contains `__` would split wrong, so we normalize
-- both halves to the API-legal tool-name charset first (`[A-Za-z0-9_-]`).
--
-- Reference: ../easy-agent/src/services/mcp/mcpStringUtils.ts.

local M = {}

local PREFIX = 'mcp__'

-- Anthropic + MCP tool names must match ^[A-Za-z0-9_-]+$. Replace anything else
-- (dots, slashes, spaces, CJK, …) with '_' so the assembled name is API-legal.
function M.normalize(name)
    return (tostring(name or ''):gsub('[^%w_-]', '_'))
end

-- Build the fully qualified bridged tool name.
function M.build(server, tool)
    return PREFIX .. M.normalize(server) .. '__' .. M.normalize(tool)
end

-- Cheap predicate: does this look like a bridged MCP tool name?
function M.is_mcp(name)
    return type(name) == 'string' and name:sub(1, #PREFIX) == PREFIX
end

-- Parse `mcp__server__tool` back into (server, tool). Returns nil if the string
-- isn't MCP-shaped. A tool name that contained `__` is rejoined.
function M.parse(full)
    if not M.is_mcp(full) then return nil end
    local parts = {}
    for p in (full .. '__'):gmatch('(.-)__') do parts[#parts + 1] = p end
    if #parts < 3 or parts[1] ~= 'mcp' or parts[2] == '' then return nil end
    local server = parts[2]
    local tool = table.concat(parts, '__', 3)
    return server, tool
end

return M
