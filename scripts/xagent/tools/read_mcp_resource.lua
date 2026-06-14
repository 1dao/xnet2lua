-- xagent/tools/read_mcp_resource.lua — read one MCP resource by server + URI.
--
-- Text resources are returned inline. Binary (blob) resources are acknowledged
-- with a note rather than decoded (multimodal persistence is out of scope here).
-- Runs inside the agent coroutine (it awaits resources/read).
--
-- Reference: ../easy-agent/src/tools/readMcpResourceTool.ts.

local mcp_registry = require('xagent.mcp.registry')
local xutils = require('xutils')

local function find_connected(name)
    for _, c in ipairs(mcp_registry.connected()) do
        if c.name == name then return c end
    end
end

return {
    name = 'ReadMcpResource',
    description =
        'Read the contents of a specific MCP resource by server name and URI ' ..
        '(discover URIs with ListMcpResources).',
    input_schema = {
        type = 'object',
        properties = {
            server = { type = 'string', description = 'The MCP server name' },
            uri = { type = 'string', description = 'The resource URI to read' },
        },
        required = { 'server', 'uri' },
    },
    is_read_only = function() return true end,
    is_concurrency_safe = function() return true end,

    call = function(input)
        if not input.server or input.server == '' or not input.uri or input.uri == '' then
            return { content = 'Error: server and uri are required', is_error = true }
        end

        local c = find_connected(input.server)
        if not c then
            local avail = {}
            for _, x in ipairs(mcp_registry.connected()) do avail[#avail + 1] = x.name end
            return { content = 'Error: MCP server "' .. input.server ..
                '" not connected. Available: ' ..
                (#avail > 0 and table.concat(avail, ', ') or '(none)'), is_error = true }
        end
        if not (c.capabilities and c.capabilities.resources) then
            return { content = 'Error: server "' .. input.server .. '" does not support resources',
                     is_error = true }
        end

        local result, err = c:read_resource(input.uri)
        if not result then
            return { content = 'Error reading resource "' .. input.uri .. '" from "' ..
                input.server .. '": ' .. tostring(err), is_error = true }
        end

        local contents = {}
        for _, item in ipairs(result.contents or {}) do
            if type(item.text) == 'string' then
                contents[#contents + 1] = { uri = item.uri, mimeType = item.mimeType, text = item.text }
            elseif type(item.blob) == 'string' then
                contents[#contents + 1] = { uri = item.uri, mimeType = item.mimeType,
                    note = '[binary resource: ' .. (item.mimeType or '?') .. ', ' ..
                        #item.blob .. ' base64 chars — not rendered as text]' }
            else
                contents[#contents + 1] = { uri = item.uri, mimeType = item.mimeType, note = '[empty resource]' }
            end
        end
        return { content = xutils.json_pack({ contents = contents }) or '{"contents":[]}' }
    end,
}
