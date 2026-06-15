-- xagent/test_mcp_loopback.lua — end-to-end MCP over REAL xnet sockets, no
-- network and no external server. An in-process loopback HTTP server speaks the
-- MCP Streamable HTTP protocol (initialize / notifications/initialized /
-- tools/list / tools/call / resources/list / resources/read); the real MCP
-- client (mcp/client.lua) + tool adapter (mcp/fetch_tools.lua) drive it through
-- a full handshake → discover → call → resource read, asserting the results.
-- Exits 0 on success, 1 on the first mismatch.
--
-- Run: bin/xnet scripts/xagent/test_mcp_loopback.lua

package.path = 'scripts/?.lua;' .. package.path

local xutils      = require('xutils')
local mcp_client  = require('xagent.mcp.client')
local fetch_tools = require('xagent.mcp.fetch_tools')

local HOST, PORT = '127.0.0.1', 18242
local BASE = string.format('http://%s:%d', HOST, PORT)

local function out(s) io.write(s); io.flush() end

local server, finished
local function finish(ok, msg)
    if finished then return end
    finished = true
    out('[mcp-loopback] ' .. (ok and 'OK ' or 'FAIL ') .. tostring(msg) .. '\n')
    if server then server:close('done'); server = nil end
    xthread.stop(ok and 0 or 1)
end

-- ── loopback MCP server ─────────────────────────────────────────────────────
local function rpc_result(id, result)
    return xutils.json_pack({ jsonrpc = '2.0', id = id, result = result })
end
local function rpc_error(id, code, message)
    return xutils.json_pack({ jsonrpc = '2.0', id = id, error = { code = code, message = message } })
end

-- Returns (body, extra_header_lines) for a decoded JSON-RPC request, or nil for
-- a notification (no response body).
local function dispatch(req)
    local id, method, params = req.id, req.method, req.params or {}
    if id == nil then return nil end                  -- notification: 202, no body
    if method == 'initialize' then
        return rpc_result(id, {
            protocolVersion = '2025-06-18',
            capabilities = { tools = {}, resources = {} },
            serverInfo = { name = 'loopback-mcp', version = '0.0.1' },
        }), 'Mcp-Session-Id: sess-abc\r\n'
    elseif method == 'tools/list' then
        return rpc_result(id, { tools = { {
            name = 'echo', description = 'Echo a message back',
            inputSchema = { type = 'object', properties = { msg = { type = 'string' } }, required = { 'msg' } },
        } } })
    elseif method == 'tools/call' then
        if params.name == 'echo' then
            return rpc_result(id, { content = { { type = 'text', text = 'echo: ' .. tostring((params.arguments or {}).msg) } }, isError = false })
        end
        return rpc_error(id, -32602, 'unknown tool: ' .. tostring(params.name))
    elseif method == 'resources/list' then
        return rpc_result(id, { resources = { { uri = 'mem://greeting', name = 'greeting', mimeType = 'text/plain' } } })
    elseif method == 'resources/read' then
        return rpc_result(id, { contents = { { uri = params.uri, mimeType = 'text/plain', text = 'hello from resource' } } })
    end
    return rpc_error(id, -32601, 'method not found: ' .. tostring(method))
end

local function make_server()
    local bufs = setmetatable({}, { __mode = 'k' })
    local h = {}
    function h.on_connect(conn)
        conn:set_framing({ type = 'raw', max_packet = 1024 * 1024 })
        bufs[conn] = ''
    end
    function h.on_packet(conn, data)
        local buf = (bufs[conn] or '') .. data
        local sep = buf:find('\r\n\r\n', 1, true)
        if not sep then bufs[conn] = buf; return #data end
        local head = buf:sub(1, sep - 1)
        local clen = tonumber(head:lower():match('content%-length:%s*(%d+)')) or 0
        local body_start = sep + 4
        if #buf < body_start + clen - 1 then bufs[conn] = buf; return #data end   -- body incomplete
        bufs[conn] = nil

        local body = buf:sub(body_start, body_start + clen - 1)
        local ok, req = pcall(xutils.json_unpack, body)
        local resp_body, extra
        if ok and type(req) == 'table' then resp_body, extra = dispatch(req) end

        if resp_body then
            conn:send_raw('HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n' ..
                (extra or '') .. 'Content-Length: ' .. #resp_body ..
                '\r\nConnection: close\r\n\r\n' .. resp_body)
        else
            conn:send_raw('HTTP/1.1 202 Accepted\r\nContent-Length: 0\r\nConnection: close\r\n\r\n')
        end
        conn:close('done')
        return #data
    end
    function h.on_close(conn) bufs[conn] = nil end
    return h
end

-- ── client: drive the real MCP stack inside a coroutine ─────────────────────
local function run_client()
    local co = coroutine.create(function()
        local c = mcp_client.new('echo', { type = 'http', url = BASE })

        local ok, err = c:connect()
        if not ok then return finish(false, 'connect: ' .. tostring(err)) end
        if c.status ~= 'connected' then return finish(false, 'status=' .. tostring(c.status)) end
        if not (c.capabilities and c.capabilities.tools and c.capabilities.resources) then
            return finish(false, 'missing capabilities')
        end
        if c.transport.session_id ~= 'sess-abc' then
            return finish(false, 'session_id=' .. tostring(c.transport.session_id))
        end
        if not (c.server_info and c.server_info.name == 'loopback-mcp') then
            return finish(false, 'serverInfo bad')
        end

        -- tools/list → adapt → call through the bridged adapter (mcp__echo__echo)
        local tools, terr = fetch_tools.fetch(c)
        if not tools then return finish(false, 'fetch: ' .. tostring(terr)) end
        if #tools ~= 1 then return finish(false, 'tools=' .. #tools) end
        if tools[1].name ~= 'mcp__echo__echo' then return finish(false, 'tool name=' .. tools[1].name) end

        local r = tools[1].call({ msg = 'hi' })
        if r.is_error then return finish(false, 'tool is_error') end
        if r.content ~= 'echo: hi' then return finish(false, 'tool content=' .. tostring(r.content)) end

        -- resources
        local res, rerr = c:list_resources()
        if not res then return finish(false, 'list_resources: ' .. tostring(rerr)) end
        if #res ~= 1 or res[1].uri ~= 'mem://greeting' then return finish(false, 'resources bad') end

        local rr, rrerr = c:read_resource('mem://greeting')
        if not rr then return finish(false, 'read_resource: ' .. tostring(rrerr)) end
        local first = rr.contents and rr.contents[1]
        if not (first and first.text == 'hello from resource') then return finish(false, 'resource read bad') end

        finish(true, 'handshake + tools/list + tools/call + resources over real sockets')
    end)
    local ok, err = coroutine.resume(co)
    if not ok then finish(false, 'coroutine: ' .. tostring(err)) end
end

local function __init()
    assert(xnet.init())
    local s, e = xnet.listen(HOST, PORT, make_server())
    if not s then return finish(false, 'listen: ' .. tostring(e)) end
    server = s
    run_client()
end

local function __uninit()
    if server then server:close('uninit'); server = nil end
    xnet.uninit()
end

return { __tick_ms = 5, __thread_handle = function() end, __init = __init, __uninit = __uninit }
