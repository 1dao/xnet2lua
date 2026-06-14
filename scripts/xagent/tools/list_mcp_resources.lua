-- xagent/tools/list_mcp_resources.lua — list resources from connected MCP servers.
--
-- MCP servers can expose `resources` (db schemas, docs, file:// URIs) alongside
-- tools. This surfaces them; ReadMcpResource fetches one by URI. Registered only
-- when at least one connected server advertises the resources capability (see
-- mcp/bootstrap.lua). Runs inside the agent coroutine (it awaits resources/list).
--
-- Reference: ../easy-agent/src/tools/listMcpResourcesTool.ts.

local mcp_registry = require('xagent.mcp.registry')
local xutils = require('xutils')

return {
    name = 'ListMcpResources',
    description =
        'List resources available from connected MCP servers. Optionally filter ' ..
        'to a single server by name. Returns resource URIs you can read with ' ..
        'ReadMcpResource.',
    input_schema = {
        type = 'object',
        properties = {
            server = { type = 'string', description = 'Optional MCP server name to filter by' },
        },
    },
    is_read_only = function() return true end,
    is_concurrency_safe = function() return true end,

    call = function(input)
        local all = mcp_registry.connected()
        local targets = all
        if input.server and input.server ~= '' then
            targets = {}
            for _, c in ipairs(all) do
                if c.name == input.server then targets[#targets + 1] = c end
            end
            if #targets == 0 then
                local avail = {}
                for _, c in ipairs(all) do avail[#avail + 1] = c.name end
                return { content = 'Error: MCP server "' .. input.server ..
                    '" not connected. Available: ' ..
                    (#avail > 0 and table.concat(avail, ', ') or '(none)'), is_error = true }
            end
        end

        local entries = {}
        for _, c in ipairs(targets) do
            if c.capabilities and c.capabilities.resources then
                local res = c:list_resources()    -- one server's failure: skip it
                if res then
                    for _, r in ipairs(res) do
                        entries[#entries + 1] = {
                            uri = r.uri, name = r.name or r.uri,
                            mimeType = r.mimeType, description = r.description,
                            server = c.name,
                        }
                    end
                end
            end
        end

        if #entries == 0 then
            return { content = 'No MCP resources found. Servers may still provide tools even with no resources.' }
        end
        return { content = xutils.json_pack(entries) or '[]' }
    end,
}
