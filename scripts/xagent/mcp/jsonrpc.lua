-- xagent/mcp/jsonrpc.lua — minimal JSON-RPC 2.0 framing for MCP.
--
-- MCP speaks JSON-RPC 2.0 over whatever transport carries the bytes. This module
-- is the pure message layer: build request/notification envelopes, encode them,
-- and validate a decoded response (turning a JSON-RPC `error` object into a plain
-- Lua error string). It knows nothing about HTTP/stdio — the transport owns that.

local xutils = require('xutils')

local M = {}

-- Per-process monotonic id. JSON-RPC ids only need to be unique within a single
-- connection's lifetime; a global counter is more than enough.
local counter = 0
function M.next_id()
    counter = counter + 1
    return counter
end

-- A request expects a response (carries an id). `params` is optional.
function M.request(id, method, params)
    local msg = { jsonrpc = '2.0', id = id, method = method }
    if params ~= nil then msg.params = params end
    return msg
end

-- A notification is fire-and-forget (no id, no response). `params` is optional.
function M.notification(method, params)
    local msg = { jsonrpc = '2.0', method = method }
    if params ~= nil then msg.params = params end
    return msg
end

-- Encode an envelope to a JSON string. Returns nil, err on failure (yyjson
-- returns nil on invalid UTF-8 / non-encodable values — surface it, don't ship
-- an empty body).
function M.encode(msg)
    local s = xutils.json_pack(msg)
    if not s or s == '' then
        return nil, 'json encode failed (non-encodable value in params?)'
    end
    return s
end

-- Validate a single response. `obj` may be a decoded table or a JSON string.
-- Returns (result, nil) on success, or (nil, err) on a JSON-RPC error / bad shape.
function M.parse_response(obj)
    if type(obj) == 'string' then
        local ok, d = pcall(xutils.json_unpack, obj)
        if not ok or type(d) ~= 'table' then return nil, 'invalid JSON-RPC response' end
        obj = d
    end
    if type(obj) ~= 'table' then return nil, 'invalid JSON-RPC response' end
    if obj.error ~= nil then
        local e = obj.error
        if type(e) == 'table' then
            local code = e.code and (' ' .. tostring(e.code)) or ''
            return nil, string.format('JSON-RPC error%s: %s', code, tostring(e.message or 'unknown'))
        end
        return nil, 'JSON-RPC error: ' .. tostring(e)
    end
    -- A result of JSON null decodes to xutils.json_null; callers that index it
    -- get nil fields, which is fine. Most MCP results are objects.
    return obj.result, nil
end

return M
