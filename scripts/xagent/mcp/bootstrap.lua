-- xagent/mcp/bootstrap.lua — bring up configured MCP servers, bridge their tools.
--
-- Flow (mirrors ../easy-agent/src/services/mcp/bootstrap.ts, minus React):
--   1. load + validate `mcpServers` (mcp/config.lua)
--   2. connect each server in turn (handshake; serial — each awaits the network)
--   3. for each connected server, fetch tools/list and register the adapters
--      into the global tool registry as `mcp__<server>__<tool>`
--   4. if any server exposes resources, register the ListMcpResources /
--      ReadMcpResource tools once
--
-- MUST run inside the agent coroutine (every connect/list awaits). Best-effort:
-- one server failing or timing out never blocks the others or throws.

local config       = require('xagent.mcp.config')
local client       = require('xagent.mcp.client')
local fetch_tools  = require('xagent.mcp.fetch_tools')
local mcp_registry = require('xagent.mcp.registry')
local tool_registry = require('xagent.tools.registry')

local M = {}

local resource_tools_registered = false

-- bootstrap(cwd, opts) where opts may carry { verify = <bool for TLS> }.
-- Returns a summary:
--   { connected, failed, unsupported, tool_count, errors = {...},
--     servers = { { name, status, tools, error }, ... } }
function M.bootstrap(cwd, opts)
    opts = opts or {}
    local servers, errors = config.load(cwd)

    mcp_registry.clear()
    local summary = {
        connected = 0, failed = 0, unsupported = 0, tool_count = 0,
        errors = errors, servers = {},
    }

    -- Deterministic order (config.load returns an unordered map).
    local names_list = {}
    for name in pairs(servers) do names_list[#names_list + 1] = name end
    table.sort(names_list)

    local any_resources = false
    for _, name in ipairs(names_list) do
        local cfg = servers[name]
        if opts.verify ~= nil and cfg.verify == nil then cfg.verify = opts.verify end

        local c = client.new(name, cfg)
        local ok = c:connect()
        local tools = {}
        if ok then
            summary.connected = summary.connected + 1
            local fetched, ferr = fetch_tools.fetch(c)
            tools = fetched or {}
            if ferr then summary.errors[#summary.errors + 1] = name .. ': ' .. tostring(ferr) end
            for _, t in ipairs(tools) do tool_registry.register(t) end
            summary.tool_count = summary.tool_count + #tools
            if c.capabilities and c.capabilities.resources then any_resources = true end
        elseif c.status == 'unsupported' then
            summary.unsupported = summary.unsupported + 1
            if c.error then summary.errors[#summary.errors + 1] = name .. ': ' .. tostring(c.error) end
        else
            summary.failed = summary.failed + 1
            if c.error then summary.errors[#summary.errors + 1] = name .. ': ' .. tostring(c.error) end
        end

        mcp_registry.set(name, c, tools)
        summary.servers[#summary.servers + 1] =
            { name = name, status = c.status, tools = #tools, error = c.error }
    end

    -- Register the resource tools lazily — only when a server actually advertises
    -- resources, so the tool list stays lean otherwise. Idempotent.
    if any_resources and not resource_tools_registered then
        tool_registry.register(require('xagent.tools.list_mcp_resources'))
        tool_registry.register(require('xagent.tools.read_mcp_resource'))
        resource_tools_registered = true
    end

    return summary
end

return M
