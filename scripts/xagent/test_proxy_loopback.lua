-- xagent/test_proxy_loopback.lua — proxy tunnels end-to-end over REAL xnet
-- sockets, no network and no API key. Three loopback servers:
--   * an origin that answers every request with a chunked Anthropic SSE stream
--   * a SOCKS5 proxy (optionally demanding user/pass)
--   * an HTTP proxy that does both CONNECT tunnels and absolute-form forwarding
-- The proxies are tiny Lua relays that pipe bytes to the origin. Each case runs
-- the real client stack through one of them and asserts the reassembled result.
-- HTTPS-through-tunnel is not covered here (no local TLS origin); it uses the
-- same xproxy.attach path with tls=true.
-- Exits 0 on success, 1 on the first failure.
--
-- Run: bin/xnet scripts/xagent/test_proxy_loopback.lua

package.path = 'scripts/?.lua;' .. package.path
local anthropic = require('xagent.llm.anthropic')
local httpc = dofile('scripts/core/share/xhttp_client.lua')
local xproxy = dofile('scripts/core/share/xproxy.lua')
local stream = dofile('scripts/core/share/xhttp_stream.lua')
local xutils = require('xutils')

local HOST = '127.0.0.1'
local ORIGIN_PORT, SOCKS_PORT, SOCKS_AUTH_PORT, HTTP_PORT, SILENT_PORT = 18241, 18242, 18243, 18244, 18245
local ORIGIN = string.format('http://%s:%d', HOST, ORIGIN_PORT)
local sbyte, schar = string.byte, string.char

local function out(s) io.write(s); io.flush() end

-- ── canned Anthropic SSE ────────────────────────────────────────────────────
local function ev(name, obj) return 'event: ' .. name .. '\ndata: ' .. xutils.json_pack(obj) .. '\n\n' end
local SSE = table.concat({
    ev('message_start',      { type = 'message_start', message = { id = 'msg_px', usage = { input_tokens = 3, output_tokens = 0 } } }),
    ev('content_block_start', { type = 'content_block_start', index = 0, content_block = { type = 'text', text = '' } }),
    ev('content_block_delta', { type = 'content_block_delta', index = 0, delta = { type = 'text_delta', text = 'via ' } }),
    ev('content_block_delta', { type = 'content_block_delta', index = 0, delta = { type = 'text_delta', text = 'proxy' } }),
    ev('content_block_stop',  { type = 'content_block_stop', index = 0 }),
    ev('message_delta',       { type = 'message_delta', delta = { stop_reason = 'end_turn' }, usage = { output_tokens = 2 } }),
    ev('message_stop',        { type = 'message_stop' }),
})

-- What the origin and proxies saw, for assertions.
local seen = {}

local servers = {}
local finished
local function finish(ok, msg)
    if finished then return end
    finished = true
    out('[proxy] ' .. (ok and 'OK ' or 'FAIL ') .. tostring(msg) .. '\n')
    for _, s in ipairs(servers) do s:close('done') end
    servers = {}
    xthread.stop(ok and 0 or 1)
end

-- ── origin: one request per connection, answered with chunked SSE ──────────
local holding = {}      -- origin connections serving an open-ended /hold stream

local function origin_handler()
    local bufs = setmetatable({}, { __mode = 'k' })
    local h = {}
    function h.on_connect(conn)
        conn:set_framing({ type = 'raw', max_packet = 1024 * 1024 })
        bufs[conn] = ''
    end
    function h.on_packet(conn, data)
        local buf = (bufs[conn] or '') .. data
        if not buf:find('\r\n\r\n', 1, true) then bufs[conn] = buf; return #data end
        bufs[conn] = nil
        seen.origin_line = buf:match('^([^\r]*)')
        seen.origin_proxy_auth = buf:match('\r\n[Pp]roxy%-[Aa]uthorization:%s*([^\r]*)')
        if seen.origin_line:find(' /hold ', 1, true) then
            -- A stream that never ends on its own: only the client can close it.
            holding[conn] = true
            conn:send_raw('HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\n' ..
                'Transfer-Encoding: chunked\r\n\r\n')
            local part = 'event: ping\ndata: {}\n\n'
            conn:send_raw(string.format('%x\r\n%s\r\n', #part, part))
            return #data
        end
        conn:send_raw('HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\n' ..
            'Transfer-Encoding: chunked\r\nConnection: close\r\n\r\n')
        local i = 1
        while i <= #SSE do
            local part = SSE:sub(i, i + 49)
            conn:send_raw(string.format('%x\r\n%s\r\n', #part, part))
            i = i + 50
        end
        conn:send_raw('0\r\n\r\n')
        conn:close('done')
        return #data
    end
    function h.on_close(conn)
        bufs[conn] = nil
        if holding[conn] then
            holding[conn] = nil
            if seen.on_hold_closed then seen.on_hold_closed() end
        end
    end
    return h
end

-- ── relay: pipe a client connection to host:port once the proxy says so ────
-- first: bytes to send upstream right after connecting (forward proxy);
-- reply: bytes to send the client once upstream is up (tunnel success).
local function relay(client, host, port, first, reply)
    local up = {}
    function up.on_connect(uconn)
        if reply then client:send_raw(reply) end
        if first and #first > 0 then uconn:send_raw(first) end
    end
    local function on_data(_, data) client:send_raw(data); return #data end
    up.on_recv, up.on_packet = on_data, on_data
    function up.on_close() if not client:is_closed() then client:close('upstream_closed') end end
    return xnet.connect(host, port, up)
end

-- ── SOCKS5 proxy (RFC 1928, user/pass per RFC 1929 when creds are given) ────
local function socks_handler(user, pass)
    local st = setmetatable({}, { __mode = 'k' })
    local h = {}
    function h.on_connect(conn)
        conn:set_framing({ type = 'raw', max_packet = 1024 * 1024 })
        st[conn] = { buf = '', phase = 'greet' }
    end
    function h.on_packet(conn, data)
        local s = st[conn]
        if not s then return #data end
        if s.phase == 'pipe' then s.up:send_raw(data); return #data end
        s.buf = s.buf .. data
        while true do
            local b = s.buf
            if s.phase == 'greet' then
                if #b < 2 or #b < 2 + sbyte(b, 2) then break end
                local methods = b:sub(3, 2 + sbyte(b, 2))
                s.buf = b:sub(3 + sbyte(b, 2))
                if user then
                    if not methods:find(schar(0x02), 1, true) then conn:send_raw(schar(5, 0xff)); break end
                    conn:send_raw(schar(5, 2)); s.phase = 'auth'
                else
                    conn:send_raw(schar(5, 0)); s.phase = 'req'
                end
            elseif s.phase == 'auth' then
                if #b < 2 then break end
                local ul = sbyte(b, 2)
                if #b < 3 + ul then break end
                local pl = sbyte(b, 3 + ul)
                if #b < 3 + ul + pl then break end
                local u, p = b:sub(3, 2 + ul), b:sub(4 + ul, 3 + ul + pl)
                s.buf = b:sub(4 + ul + pl)
                seen.socks_user = u
                if u ~= user or p ~= pass then conn:send_raw(schar(1, 1)); break end
                conn:send_raw(schar(1, 0)); s.phase = 'req'
            elseif s.phase == 'req' then
                if #b < 5 then break end
                local atyp, host, rest = sbyte(b, 4), nil, nil
                if atyp == 1 then
                    if #b < 10 then break end
                    host = string.format('%d.%d.%d.%d', sbyte(b, 5, 8)); rest = 9
                elseif atyp == 3 then
                    local n = sbyte(b, 5)
                    if #b < 7 + n then break end
                    host = b:sub(6, 5 + n); rest = 6 + n
                else break end
                local port = (sbyte(b, rest) << 8) | sbyte(b, rest + 1)
                seen.socks_target = host .. ':' .. port
                s.buf = b:sub(rest + 2)
                s.phase = 'pipe'
                s.up = relay(conn, host, port, s.buf,
                    schar(5, 0, 0, 1, 127, 0, 0, 1, 0, 0))
                s.buf = ''
                break
            else
                break
            end
        end
        return #data
    end
    function h.on_close(conn)
        local s = st[conn]
        st[conn] = nil
        if s and s.up and not s.up:is_closed() then s.up:close('client_closed') end
    end
    return h
end

-- ── HTTP proxy: CONNECT tunnels + absolute-form forwarding ─────────────────
local function http_proxy_handler()
    local st = setmetatable({}, { __mode = 'k' })
    local h = {}
    function h.on_connect(conn)
        conn:set_framing({ type = 'raw', max_packet = 1024 * 1024 })
        st[conn] = { buf = '' }
    end
    function h.on_packet(conn, data)
        local s = st[conn]
        if not s then return #data end
        if s.up then s.up:send_raw(data); return #data end
        s.buf = s.buf .. data
        local e = s.buf:find('\r\n\r\n', 1, true)
        if not e then return #data end
        local line = s.buf:match('^([^\r]*)')
        seen.http_line = line
        seen.http_proxy_auth = s.buf:match('\r\n[Pp]roxy%-[Aa]uthorization:%s*([^\r]*)')
        local target = line:match('^CONNECT (%S+) ')
        if target then
            local host, port = target:match('^(.+):(%d+)$')
            s.up = relay(conn, host, tonumber(port), s.buf:sub(e + 4),
                'HTTP/1.1 200 Connection established\r\n\r\n')
        else
            local host, port = line:match('^%u+ http://([^/:]+):?(%d*)')
            s.up = relay(conn, host, tonumber(port) or 80, s.buf)
        end
        s.buf = ''
        return #data
    end
    function h.on_close(conn)
        local s = st[conn]
        st[conn] = nil
        if s and s.up and not s.up:is_closed() then s.up:close('client_closed') end
    end
    return h
end

-- ── cases ──────────────────────────────────────────────────────────────────
local function llm_case(name, proxy, check)
    return function(next_case)
        seen = {}
        local streamed = {}
        anthropic.stream_message(
            { api_key = 'unused', base_url = ORIGIN, model = 'test', max_retries = 0, proxy = proxy },
            { messages = { { role = 'user', content = 'hi' } } },
            {
                on_text = function(t) streamed[#streamed + 1] = t end,
                on_error = function(e) finish(false, name .. ' on_error: ' .. tostring(e)) end,
                on_done = function(r)
                    local text = table.concat(streamed)
                    if text ~= 'via proxy' then return finish(false, name .. ': text=' .. text) end
                    if not r or r.stop_reason ~= 'end_turn' then return finish(false, name .. ': bad result') end
                    local problem = check and check()
                    if problem then return finish(false, name .. ': ' .. problem) end
                    out('[proxy] ' .. name .. ' ok\n')
                    next_case()
                end,
            })
    end
end

local function httpc_case(name, proxy, check)
    return function(next_case)
        seen = {}
        httpc.get(ORIGIN .. '/plain', { proxy = proxy, timeout_ms = 5000 }, function(err, resp)
            if err then return finish(false, name .. ': ' .. tostring(err)) end
            if resp.status ~= 200 or not resp.body:find('via ', 1, true) then
                return finish(false, name .. ': status=' .. tostring(resp.status))
            end
            local problem = check and check()
            if problem then return finish(false, name .. ': ' .. problem) end
            out('[proxy] ' .. name .. ' ok\n')
            next_case()
        end)
    end
end

-- Drive xproxy directly: an HTTP CONNECT tunnel to a plaintext origin (the
-- clients only use CONNECT for https, which needs a TLS origin).
local function connect_tunnel_case(next_case)
    seen = {}
    local name = 'xproxy CONNECT tunnel'
    local proxy = assert(xproxy.parse('http://u:p@' .. HOST .. ':' .. HTTP_PORT))
    local buf = ''
    local h = {}
    function h.on_connect(conn)
        conn:send_raw('GET /t HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n')
    end
    local function on_data(_, data) buf = buf .. data; return #data end
    h.on_recv, h.on_packet = on_data, on_data
    function h.on_close()
        if not buf:find('^HTTP/1.1 200') or not buf:find('via ', 1, true) then
            return finish(false, name .. ': got ' .. buf:sub(1, 80))
        end
        if seen.http_line ~= 'CONNECT ' .. HOST .. ':' .. ORIGIN_PORT .. ' HTTP/1.1' then
            return finish(false, name .. ': line=' .. tostring(seen.http_line))
        end
        if seen.http_proxy_auth ~= xproxy.auth_header(proxy) then
            return finish(false, name .. ': auth=' .. tostring(seen.http_proxy_auth))
        end
        out('[proxy] ' .. name .. ' ok\n')
        next_case()
    end
    xproxy.open_tunnel(proxy, HOST, ORIGIN_PORT, {
        on_ready = function(conn, extra)
            local c, err = xproxy.attach(conn, extra, h, { tls = false })
            if not c then finish(false, name .. ': ' .. tostring(err)) end
        end,
        on_error = function(e) finish(false, name .. ': ' .. tostring(e)) end,
    })
end

-- A proxy that accepts the connection but never answers must not hang.
local function handshake_timeout_case(next_case)
    local name = 'handshake timeout'
    local proxy = assert(xproxy.parse('socks5://' .. HOST .. ':' .. SILENT_PORT))
    xproxy.open_tunnel(proxy, HOST, ORIGIN_PORT, {
        on_ready = function() finish(false, name .. ': silent proxy became ready') end,
        on_error = function(e)
            if not tostring(e):find('timed out', 1, true) then
                return finish(false, name .. ': error=' .. tostring(e))
            end
            out('[proxy] ' .. name .. ' ok\n')
            next_case()
        end,
    }, { timeout_ms = 200 })
end

-- The handle xhttp_stream returns for a proxied request must still close the
-- stream after the tunnel handed off (Android cancels and times out requests
-- through it). The origin only closes /hold when the client does.
local function close_after_tunnel_case(next_case)
    seen = {}
    local name = 'stream close after tunnel'
    local handle, closed = nil, false
    seen.on_hold_closed = function()
        if not handle:is_closed() then return finish(false, name .. ': handle not closed') end
        out('[proxy] ' .. name .. ' ok\n')
        next_case()
    end
    handle = stream.request({
        url = ORIGIN .. '/hold', method = 'POST', body = '{}',
        headers = { ['content-type'] = 'application/json' },
        proxy = 'socks5://' .. HOST .. ':' .. SOCKS_PORT,
    }, {
        on_body = function()
            if closed then return end
            closed = true
            handle:close('cancelled')
        end,
        on_error = function(e) if not closed then finish(false, name .. ': ' .. tostring(e)) end end,
    })
    if not handle then finish(false, name .. ': no handle') end
end

local function expect_error_case(name, proxy, want)
    return function(next_case)
        anthropic.stream_message(
            { api_key = 'unused', base_url = ORIGIN, model = 'test', max_retries = 0, proxy = proxy },
            { messages = { { role = 'user', content = 'hi' } } },
            {
                on_error = function(e)
                    if not tostring(e):find(want, 1, true) then
                        return finish(false, name .. ': error=' .. tostring(e))
                    end
                    out('[proxy] ' .. name .. ' ok\n')
                    next_case()
                end,
                on_done = function() finish(false, name .. ': expected an error') end,
            })
    end
end

local CASES = {
    llm_case('stream via socks5', 'socks5://' .. HOST .. ':' .. SOCKS_PORT, function()
        if seen.socks_target ~= HOST .. ':' .. ORIGIN_PORT then return 'target=' .. tostring(seen.socks_target) end
        if seen.origin_line ~= 'POST /v1/messages HTTP/1.1' then return 'origin line=' .. tostring(seen.origin_line) end
    end),
    llm_case('stream via socks5h with auth', 'socks5h://alice:s3cret@' .. HOST .. ':' .. SOCKS_AUTH_PORT, function()
        if seen.socks_user ~= 'alice' then return 'user=' .. tostring(seen.socks_user) end
    end),
    llm_case('stream via http forward proxy', 'http://u:p@' .. HOST .. ':' .. HTTP_PORT, function()
        local want = 'POST ' .. ORIGIN .. '/v1/messages HTTP/1.1'
        if seen.http_line ~= want then return 'line=' .. tostring(seen.http_line) end
        if seen.http_proxy_auth ~= 'Basic ' .. xutils.base64_encode('u:p') then return 'no proxy auth' end
    end),
    expect_error_case('socks5 wrong password', 'socks5://alice:nope@' .. HOST .. ':' .. SOCKS_AUTH_PORT, 'auth rejected'),
    expect_error_case('bad proxy url', 'localhost:1080', 'proxy config'),
    httpc_case('httpc via socks5', 'socks5://' .. HOST .. ':' .. SOCKS_PORT, function()
        if seen.origin_line ~= 'GET /plain HTTP/1.1' then return 'origin line=' .. tostring(seen.origin_line) end
    end),
    httpc_case('httpc via http forward proxy', 'http://' .. HOST .. ':' .. HTTP_PORT, function()
        if seen.http_line ~= 'GET ' .. ORIGIN .. '/plain HTTP/1.1' then return 'line=' .. tostring(seen.http_line) end
    end),
    connect_tunnel_case,
    handshake_timeout_case,
    close_after_tunnel_case,
}

local function run_case(i)
    local case = CASES[i]
    if not case then return finish(true, 'all proxy paths reassembled over real sockets') end
    case(function() run_case(i + 1) end)
end

local function __init()
    assert(xnet.init())
    local listeners = {
        { ORIGIN_PORT, origin_handler() },
        { SOCKS_PORT, socks_handler() },
        { SOCKS_AUTH_PORT, socks_handler('alice', 's3cret') },
        { HTTP_PORT, http_proxy_handler() },
        { SILENT_PORT, { on_connect = function(conn) conn:set_framing({ type = 'raw' }) end,
                         on_packet = function(_, data) return #data end } },
    }
    for _, l in ipairs(listeners) do
        local s, e = xnet.listen(HOST, l[1], l[2])
        if not s then return finish(false, 'listen ' .. l[1] .. ': ' .. tostring(e)) end
        servers[#servers + 1] = s
    end
    xtimer.init(16)
    xtimer.add(10000, function() finish(false, 'timed out') end, 1)
    run_case(1)
end

local function __uninit()
    for _, s in ipairs(servers) do s:close('uninit') end
    servers = {}
    xnet.uninit()
end

return { __tick_ms = 5, __thread_handle = function() end, __init = __init, __uninit = __uninit }
