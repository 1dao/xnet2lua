-- xagent/mcp/registry.lua — in-memory map of MCP servers and their bridged tools.
--
-- bootstrap.lua fills this as it connects each server; the `/mcp` status surface
-- and the ListMcpResources/ReadMcpResource tools read it to find live clients.
-- Pull-based and dependency-free — no event wiring needed.

local M = {}

local entries = {}      -- name -> { connection = <client>, tools = { <tool> } }
local order = {}        -- registration order (stable listing)

function M.set(name, connection, tools)
    if not entries[name] then order[#order + 1] = name end
    entries[name] = { connection = connection, tools = tools or {} }
end

function M.get(name)
    return entries[name]
end

-- All entries in registration order: { { connection, tools }, ... }.
function M.all()
    local list = {}
    for _, n in ipairs(order) do
        if entries[n] then list[#list + 1] = entries[n] end
    end
    return list
end

-- Just the client objects (any status), in registration order.
function M.connections()
    local list = {}
    for _, n in ipairs(order) do
        if entries[n] then list[#list + 1] = entries[n].connection end
    end
    return list
end

-- Only the successfully connected clients.
function M.connected()
    local list = {}
    for _, c in ipairs(M.connections()) do
        if c.status == 'connected' then list[#list + 1] = c end
    end
    return list
end

function M.clear()
    entries = {}
    order = {}
end

return M
