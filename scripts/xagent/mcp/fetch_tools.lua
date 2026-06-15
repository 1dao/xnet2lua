-- xagent/mcp/fetch_tools.lua — adapt MCP tools into xagent registry tools.
--
-- Each MCP tool becomes a normal registry tool whose `call` forwards to the
-- server via `client:call_tool`. The local name is `mcp__<server>__<tool>` so
-- the agent loop routes it back here; the server is always called with its OWN
-- tool name (captured in the closure), not the prefixed alias.
--
-- Reference: ../easy-agent/src/services/mcp/fetchTools.ts.

local names = require('xagent.mcp.names')

local M = {}

-- OpenAPI-derived servers can ship enormous descriptions; cap to keep the system
-- prompt / tools param sane (same value as the reference).
local MAX_DESC = 2048

-- Flatten an MCP tools/call `content` array into a single string for the
-- tool_result. Text passes through; images/resources are acknowledged with a
-- placeholder (vision/blob persistence is out of scope here, matching §16).
function M.stringify_content(content)
    if type(content) ~= 'table' then return '' end
    local parts = {}
    for _, block in ipairs(content) do
        local bt = type(block) == 'table' and block.type
        if bt == 'text' then
            parts[#parts + 1] = block.text or ''
        elseif bt == 'image' then
            parts[#parts + 1] = string.format('[image: %s, %d base64 chars]',
                block.mimeType or '?', #(block.data or ''))
        elseif bt == 'resource' then
            local r = block.resource or {}
            parts[#parts + 1] = r.text or ('[resource: ' .. tostring(r.uri or '<no uri>') .. ']')
        else
            parts[#parts + 1] = '[' .. tostring(bt or 'unknown') .. ' block]'
        end
    end
    return table.concat(parts, '\n')
end

local function truncate_desc(d)
    d = tostring(d or '')
    if #d <= MAX_DESC then return d end
    return d:sub(1, MAX_DESC) .. '… [truncated]'
end

-- Build one registry tool from a connected client + an MCP tool descriptor.
function M.build_adapter(client, mcp_tool)
    local full = names.build(client.name, mcp_tool.name)
    local schema = mcp_tool.inputSchema
    if type(schema) ~= 'table' then schema = { type = 'object', properties = {} } end

    local read_only = false
    if type(mcp_tool.annotations) == 'table' and mcp_tool.annotations.readOnlyHint then
        read_only = true
    end

    return {
        name = full,
        description = truncate_desc(mcp_tool.description),
        input_schema = schema,
        -- metadata (ignored by to_api_params; handy for /mcp + the permission
        -- engine later)
        mcp = { server = client.name, tool = mcp_tool.name },
        is_read_only = function() return read_only end,
        call = function(input)
            local result, err = client:call_tool(mcp_tool.name, input or {})
            if not result then
                return { content = string.format("MCP tool '%s' failed: %s", full, tostring(err)),
                         is_error = true }
            end
            return { content = M.stringify_content(result.content),
                     is_error = result.isError == true }
        end,
    }
end

-- Discover + adapt every tool for a connected client. Returns (tools, err).
function M.fetch(client)
    local list, err = client:list_tools()
    if not list then return {}, err end
    local out = {}
    for _, mt in ipairs(list) do
        if type(mt) == 'table' and type(mt.name) == 'string' then
            out[#out + 1] = M.build_adapter(client, mt)
        end
    end
    return out
end

return M
