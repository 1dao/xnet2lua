-- xagent/mcp/transport_http.lua — MCP Streamable HTTP transport.
--
-- The modern remote MCP transport: every JSON-RPC message is one HTTP POST to
-- the server URL. The server answers with either
--   • Content-Type: application/json      → a single JSON-RPC response, or
--   • Content-Type: text/event-stream     → an SSE stream carrying the
--     response (and possibly server-initiated notifications) as `message`
--     events, closed once this request's response has been delivered.
-- We send `Connection: close`, so the buffered-response HTTP client (which
-- parses on socket close) handles both shapes; no persistent socket is needed —
-- the session is carried by the `Mcp-Session-Id` header, not the connection.
--
-- This reuses the runtime's async HTTP/TLS stack (the same one that streams the
-- Anthropic API), so `rpc`/`notify` MUST run inside the agent coroutine: they
-- await the request callback, which the event loop fires between ticks.
--
-- A `conn` table is the transport state:
--   { url, headers?, verify?, ca_file?, timeout_ms?, session_id?, protocol_version? }
--
-- Reference: ../easy-agent/src/services/mcp/client.ts (createHttpTransport).

local async = dofile('scripts/core/share/xasync.lua')
local httpc = dofile('scripts/core/share/xhttp_client.lua')
local sse = dofile('scripts/core/share/xsse.lua')
local jsonrpc = require('xagent.mcp.jsonrpc')
local xutils = require('xutils')

local M = {}

local DEFAULT_TIMEOUT_MS = 30000

local function build_headers(conn)
    local h = {
        ['Content-Type'] = 'application/json',
        -- Streamable HTTP requires the client to accept both response shapes.
        ['Accept'] = 'application/json, text/event-stream',
    }
    -- After initialize, echo the negotiated protocol + session so the server
    -- can route us to the right session (spec: both are client→server headers).
    if conn.session_id then h['Mcp-Session-Id'] = conn.session_id end
    if conn.protocol_version then h['MCP-Protocol-Version'] = conn.protocol_version end
    if conn.headers then
        for k, v in pairs(conn.headers) do h[k] = v end   -- static auth headers, etc.
    end
    return h
end

local function format_http_error(resp)
    local body = resp.body or ''
    local ok, d = pcall(xutils.json_unpack, body)
    if ok and type(d) == 'table' and type(d.error) == 'table' and d.error.message then
        return string.format('HTTP %s: %s', tostring(resp.status), tostring(d.error.message))
    end
    if #body > 300 then body = body:sub(1, 300) .. '...' end
    return string.format('HTTP %s: %s', tostring(resp.status),
        body ~= '' and body or '(no body)')
end

-- Parse a response body into a list of decoded JSON-RPC objects. Exposed for
-- offline tests. Returns (objs, nil) or (nil, err).
function M.parse_body(content_type, body)
    content_type = tostring(content_type or ''):lower()
    body = body or ''
    if content_type:find('text/event-stream', 1, true) then
        -- Feed a trailing blank line so a final event with no terminator still
        -- dispatches. Each `data:` payload is one JSON-RPC message.
        local events = sse.new():feed(body .. '\n\n')
        local objs = {}
        for _, ev in ipairs(events) do
            if ev.data and ev.data ~= '' then
                local ok, d = pcall(xutils.json_unpack, ev.data)
                if ok and type(d) == 'table' then objs[#objs + 1] = d end
            end
        end
        return objs
    end
    if body == '' then return {} end
    local ok, d = pcall(xutils.json_unpack, body)
    if not ok or type(d) ~= 'table' then return nil, 'invalid JSON body' end
    if d[1] ~= nil then return d end       -- a JSON-RPC batch (array of responses)
    return { d }
end

local function do_post(conn, payload)
    return async.await(function(resolve)
        httpc.request({
            url = conn.url,
            method = 'POST',
            headers = build_headers(conn),
            body = payload,
            timeout_ms = conn.timeout_ms or DEFAULT_TIMEOUT_MS,
            verify = conn.verify ~= false,
            ca_file = conn.ca_file,
            decompress = true,
        }, function(e, r) resolve(e, r) end)
    end)
end

-- Send a request and await the matching response. Returns (result, nil) or
-- (nil, err). Captures the session id from the response headers (initialize).
function M.rpc(conn, method, params)
    local id = jsonrpc.next_id()
    local payload, perr = jsonrpc.encode(jsonrpc.request(id, method, params))
    if not payload then return nil, perr end

    local err, resp = do_post(conn, payload)
    if err then return nil, 'transport error: ' .. tostring(err) end
    if resp.headers then
        local sid = resp.headers['mcp-session-id']
        if sid and sid ~= '' then conn.session_id = sid end
    end
    if resp.status and resp.status >= 400 then
        return nil, format_http_error(resp)
    end

    local objs, berr = M.parse_body(resp.headers and resp.headers['content-type'], resp.body)
    if not objs then return nil, berr end
    for _, o in ipairs(objs) do
        if o.id == id then return jsonrpc.parse_response(o) end
    end
    -- Tolerate a server that omits/normalizes the id but returns exactly one
    -- response object (some minimal servers stringify the id, etc.).
    if #objs == 1 and objs[1].id ~= nil then return jsonrpc.parse_response(objs[1]) end
    return nil, 'no matching JSON-RPC response for id ' .. tostring(id)
end

-- Fire a notification (no response expected). Returns (true) or (nil, err).
-- The server replies 202 Accepted with an empty body; we ignore the body.
function M.notify(conn, method, params)
    local payload, perr = jsonrpc.encode(jsonrpc.notification(method, params))
    if not payload then return nil, perr end
    local err = do_post(conn, payload)
    if err then return nil, 'transport error: ' .. tostring(err) end
    return true
end

return M
