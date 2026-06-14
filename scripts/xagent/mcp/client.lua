-- xagent/mcp/client.lua — one MCP server connection + the protocol calls.
--
-- A Client wraps a transport and performs the MCP handshake (initialize +
-- notifications/initialized), then exposes tools/resources requests. All methods
-- that touch the network (`connect`, `request`, and the typed helpers) MUST run
-- inside the agent coroutine — they await the transport.
--
-- Transports: `http` and `sse` configs use the Streamable HTTP transport
-- (transport_http). `stdio` is recognized but unsupported on this runtime — it
-- needs a long-lived bidirectional child-process pipe, which xnet2lua has no
-- binding for yet (the one-shot io.popen worker can't keep stdin+stdout open).
-- Such a server is marked `unsupported` with an actionable message instead of
-- crashing the bootstrap.
--
-- Reference: ../easy-agent/src/services/mcp/client.ts + fetchTools.ts.

local http = require('xagent.mcp.transport_http')

local M = {}

local Client = {}
Client.__index = Client
M.Client = Client

local CLIENT_INFO = { name = 'xagent', version = '0.1.0' }
-- Advertise the latest spec we target; we then adopt whatever version the server
-- echoes back for the MCP-Protocol-Version header on subsequent requests.
local CLIENT_PROTOCOL_VERSION = '2025-06-18'

-- new(name, config) — config from mcp/config.lua (carries an explicit `type`).
function M.new(name, config)
    return setmetatable({
        name = name,
        config = config,
        status = 'pending',      -- pending | connected | failed | unsupported
        error = nil,
        capabilities = nil,
        server_info = nil,
        transport = nil,
    }, Client)
end

-- Run the initialize handshake. Returns (true) on success, or (false, err).
function Client:connect()
    local cfg = self.config

    if cfg.type == 'stdio' then
        self.status = 'unsupported'
        self.error = 'stdio transport is not available on this runtime ' ..
            '(needs a bidirectional child-process pipe); use an http/sse MCP server'
        return false, self.error
    end

    self.transport = {
        url = cfg.url,
        headers = cfg.headers,
        verify = cfg.verify,
        ca_file = cfg.ca_file,
        timeout_ms = cfg.timeout_ms,
        session_id = nil,
        protocol_version = nil,
    }

    local result, err = http.rpc(self.transport, 'initialize', {
        protocolVersion = CLIENT_PROTOCOL_VERSION,
        capabilities = {},               -- we expose no client capabilities yet
        clientInfo = CLIENT_INFO,
    })
    if not result then
        self.status = 'failed'
        self.error = err
        return false, err
    end

    self.capabilities = (type(result.capabilities) == 'table') and result.capabilities or {}
    self.server_info = result.serverInfo
    self.transport.protocol_version = result.protocolVersion or CLIENT_PROTOCOL_VERSION

    -- Tell the server we're ready. Best-effort: a notify failure here doesn't
    -- invalidate an otherwise-good session (some servers don't require it).
    http.notify(self.transport, 'notifications/initialized', nil)

    self.status = 'connected'
    return true
end

-- Raw request passthrough (used by the resource tools). Returns (result, err).
function Client:request(method, params)
    if self.status ~= 'connected' then return nil, 'MCP server "' .. self.name .. '" not connected' end
    return http.rpc(self.transport, method, params)
end

-- tools/list. Returns ({tool, ...}, nil), or ({}, nil) if no tools capability,
-- or (nil, err) on failure.
function Client:list_tools()
    if not (self.capabilities and self.capabilities.tools) then return {} end
    local result, err = self:request('tools/list', {})
    if not result then return nil, err end
    return result.tools or {}
end

-- tools/call. Returns (result, err); result = { content = {...}, isError? }.
function Client:call_tool(tool_name, args)
    return self:request('tools/call', { name = tool_name, arguments = args or {} })
end

function Client:list_resources()
    if not (self.capabilities and self.capabilities.resources) then return {} end
    local result, err = self:request('resources/list', {})
    if not result then return nil, err end
    return result.resources or {}
end

function Client:read_resource(uri)
    return self:request('resources/read', { uri = uri })
end

return M
