-- xproxy.lua - outbound proxy tunnels shared by the HTTP clients.
--
-- Protocols:
--   * SOCKS5 / SOCKS5h (RFC 1928 + RFC 1929 user/pass) -- socks5h delegates DNS
--     to the proxy, which is what we want when the origin is unresolvable
--     locally (e.g. reaching Google from a restricted network).
--   * HTTP CONNECT (RFC 7231) -- for HTTPS targets via an HTTP proxy.
-- Plaintext HTTP via an HTTP proxy is a plain forward proxy (absolute-form
-- request line, no tunnel); callers handle that case themselves and only use
-- M.auth_header here.
--
-- For HTTPS targets the tunnel carries raw TLS: once the proxy handshake
-- completes we surrender the plaintext fd (conn:detach) and upgrade it to a
-- client-mode TLS session with xnet.connect_tls_fd (SNI = real origin host).
-- The detach + upgrade is ALWAYS deferred to the next tick: detaching inside
-- the channel's own callback would free the channel the poll loop is mid-walk.
--
-- Usage:
--   local xproxy = dofile('scripts/core/share/xproxy.lua')
--   local proxy = assert(xproxy.parse('socks5h://127.0.0.1:1080'))
--   local tun = xproxy.open_tunnel(proxy, host, port, {
--       on_ready = function(conn, extra)
--           local c, err = xproxy.attach(conn, extra, handler, {
--               tls = true, host = host, port = port, verify = true })
--       end,
--       on_error = function(msg) end,
--   })
--   tun:close('timeout')   -- abort while the handshake is still in flight

local xutils = require('xutils')   -- base64_encode for Basic proxy auth

local M = {}

local schar = string.char
local sbyte = string.byte

-- Parse "scheme://[user:pass@]host[:port]" into a proxy table, or nil[, err].
-- nil with no error means "no proxy configured" (nil / empty string).
function M.parse(s)
    if type(s) ~= 'string' or s == '' then return nil end
    local scheme, rest = s:match('^(%a[%w+.%-]*)://(.+)$')
    if not scheme then
        return nil, 'proxy url needs a scheme (socks5://, socks5h://, http://)'
    end
    scheme = scheme:lower()
    local ptype
    if scheme == 'socks5' or scheme == 'socks' then ptype = 'socks5'
    elseif scheme == 'socks5h' then ptype = 'socks5h'
    elseif scheme == 'http' then ptype = 'http'
    else return nil, 'unsupported proxy scheme: ' .. scheme end

    local userinfo, hostport = rest:match('^([^@]*)@(.+)$')
    if not hostport then hostport = rest end
    hostport = hostport:match('^([^/]+)') or hostport     -- drop any /path

    local user, pass
    if userinfo and userinfo ~= '' then
        user, pass = userinfo:match('^([^:]*):?(.*)$')
        if pass == '' then pass = nil end
    end

    local host, port
    if hostport:sub(1, 1) == '[' then                     -- [ipv6]:port
        host, port = hostport:match('^%[([^%]]+)%]:?(%d*)$')
    else
        host, port = hostport:match('^([^:]+):?(%d*)$')
    end
    if not host or host == '' then
        return nil, 'bad proxy host: ' .. tostring(hostport)
    end
    port = tonumber(port) or (ptype == 'http' and 8080 or 1080)
    return { type = ptype, host = host, port = port, user = user, pass = pass }
end

-- Proxy URL with any password masked, safe for logs and UI labels.
function M.redact(s)
    if type(s) ~= 'string' then return s end
    return (s:gsub('^(%a[%w+.%-]*://[^:@/]*):[^@/]*@', '%1:***@'))
end

-- Value for a Proxy-Authorization header, or nil when the proxy has no creds.
function M.auth_header(proxy)
    if not proxy or not proxy.user then return nil end
    return 'Basic ' .. xutils.base64_encode((proxy.user or '') .. ':' .. (proxy.pass or ''))
end

local function u16be(n) return schar((n >> 8) & 0xff, n & 0xff) end

local function socks5_greeting(proxy)
    -- Offer no-auth, plus user/pass when creds are configured.
    if proxy.user then return schar(0x05, 0x02, 0x00, 0x02) end
    return schar(0x05, 0x01, 0x00)
end

local function socks5_auth_req(user, pass)
    user, pass = user or '', pass or ''
    if #user > 255 or #pass > 255 then return nil, 'socks5 credentials too long' end
    return schar(0x01, #user) .. user .. schar(#pass) .. pass
end

-- CONNECT request. Always sends the host as a domain (ATYP=3) so the proxy
-- resolves it, EXCEPT for a dotted-quad IPv4 literal (ATYP=1). This makes
-- socks5 and socks5h behave identically here -- both let the proxy reach hosts
-- the client can't resolve, which is the whole point.
local function socks5_connect_req(host, port)
    local a, b, c, d = host:match('^(%d+)%.(%d+)%.(%d+)%.(%d+)$')
    if a and tonumber(a) < 256 and tonumber(b) < 256
        and tonumber(c) < 256 and tonumber(d) < 256 then
        return schar(0x05, 0x01, 0x00, 0x01,
            tonumber(a), tonumber(b), tonumber(c), tonumber(d)) .. u16be(port)
    end
    if #host > 255 then return nil, 'host too long for socks5 (>255)' end
    return schar(0x05, 0x01, 0x00, 0x03, #host) .. host .. u16be(port)
end

local SOCKS5_REP = {
    [1] = 'general failure', [2] = 'connection not allowed', [3] = 'network unreachable',
    [4] = 'host unreachable', [5] = 'connection refused', [6] = 'TTL expired',
    [7] = 'command not supported', [8] = 'address type not supported',
}

-- The deferred hand-off needs a timer on this thread. Bring the pool up on
-- demand (the thread runner drives it once inited) so callers don't have to.
-- after(ms, fn) -> timer | nil
local function after(ms, fn)
    local xt = rawget(_G, 'xtimer')
    if not (type(xt) == 'table' and xt.add and xt.inited) then return nil end
    if not xt.inited() then
        if not xt.init then return nil end
        xt.init(16)
    end
    local ok, t = pcall(xt.add, ms, fn, 1)
    return ok and t or nil
end

-- A proxy that accepts the TCP connection but never answers the handshake
-- (e.g. a SOCKS client pointed at an HTTP-only port) would otherwise stall the
-- request forever -- the streaming client has no overall timeout.
M.HANDSHAKE_TIMEOUT_MS = 15000

-- open_tunnel(proxy, host, port, cb[, opts]) -> tunnel
-- Connects to the proxy and asks it to reach host:port (SOCKS5 CONNECT, or
-- HTTP CONNECT when proxy.type == 'http'). Exactly one of these fires:
--   cb.on_ready(conn, extra) -- next tick after the handshake; `conn` is the
--                               live proxy connection, `extra` any bytes the
--                               proxy sent past its reply. Pass both to attach.
--   cb.on_error(msg)
-- opts.timeout_ms bounds the proxy connect + handshake (default
-- M.HANDSHAKE_TIMEOUT_MS; 0 disables).
-- tunnel.conn is the in-flight proxy connection (nil once handed off);
-- tunnel:close(reason) aborts silently (no callback).
-- tunnel:adopt(conn) hands the tunnel the connection attach() returned, so a
-- caller holding the tunnel as its request handle can still close() the live
-- stream (and ask is_closed()) after the TCP -> TLS upgrade.
function M.open_tunnel(proxy, host, port, cb, opts)
    local tun = { done = false }
    local buf, phase = '', (proxy.type == 'http') and 'connect' or 'greet'
    local timer

    local function stop_timer()
        if timer then timer:del(); timer = nil end
    end

    local function fail(msg)
        if tun.done then return end
        tun.done = true
        stop_timer()
        local c = tun.conn
        tun.conn = nil
        if c and not c:is_closed() then c:close('proxy_error') end
        if cb.on_error then cb.on_error(msg) end
    end

    function tun:close(reason)
        local live = self.live
        if live then
            if not live:is_closed() then live:close(reason or 'cancelled') end
            return
        end
        if self.done then return end
        self.done = true
        stop_timer()
        local c = self.conn
        self.conn = nil
        if c and not c:is_closed() then c:close(reason or 'cancelled') end
    end

    function tun:is_closed()
        if self.live then return self.live:is_closed() end
        return self.done
    end

    function tun:adopt(conn)
        self.live = conn
    end

    -- Defer the hand-off out of the channel callback (see header note).
    local function schedule_ready(extra)
        phase = 'done'
        local t = after(0, function()
            if tun.done then return end
            local c = tun.conn
            if not c or c:is_closed() then return fail('proxy tunnel lost') end
            tun.done = true
            stop_timer()
            tun.conn = nil
            cb.on_ready(c, extra or '')
        end)
        if not t then fail('proxy tunnel needs xtimer on this thread') end
    end

    local h = {}

    function h.on_connect(conn)
        tun.conn = conn
        local ok, serr
        if proxy.type == 'http' then
            local target = host .. ':' .. port
            local req = { 'CONNECT ' .. target .. ' HTTP/1.1\r\n', 'Host: ' .. target .. '\r\n' }
            local auth = M.auth_header(proxy)
            if auth then req[#req + 1] = 'Proxy-Authorization: ' .. auth .. '\r\n' end
            req[#req + 1] = '\r\n'
            ok, serr = conn:send_raw(table.concat(req))
        else
            ok, serr = conn:send_raw(socks5_greeting(proxy))
        end
        if not ok then fail('proxy handshake send: ' .. tostring(serr)) end
    end

    local function on_data(conn, data)
        if tun.done or phase == 'done' then return #data end
        buf = buf .. data

        if proxy.type == 'http' then
            local hdr_end = buf:find('\r\n\r\n', 1, true)
            if not hdr_end then
                if #buf > 64 * 1024 then fail('proxy CONNECT response too large') end
                return #data
            end
            local status = buf:match('^HTTP/%d%.%d%s+(%d%d%d)')
            if not status then fail('proxy CONNECT: malformed response'); return #data end
            if status ~= '200' then fail('proxy CONNECT rejected: HTTP ' .. status); return #data end
            schedule_ready(buf:sub(hdr_end + 4))
            return #data
        end

        -- SOCKS5 state machine; loop because phases can complete back-to-back.
        while not tun.done do
            if phase == 'greet' then
                if #buf < 2 then break end
                if sbyte(buf, 1) ~= 0x05 then fail('socks5: bad version in method reply'); break end
                local method = sbyte(buf, 2)
                buf = buf:sub(3)
                if method == 0x00 then
                    local req, e = socks5_connect_req(host, port)
                    if not req then fail('socks5: ' .. e); break end
                    conn:send_raw(req); phase = 'reply'
                elseif method == 0x02 then
                    if not proxy.user then fail('socks5: proxy requires auth but no credentials given'); break end
                    local req, e = socks5_auth_req(proxy.user, proxy.pass)
                    if not req then fail('socks5: ' .. e); break end
                    conn:send_raw(req); phase = 'auth'
                else
                    fail(string.format('socks5: no acceptable auth method (0x%02x)', method)); break
                end
            elseif phase == 'auth' then
                if #buf < 2 then break end
                local status = sbyte(buf, 2)
                buf = buf:sub(3)
                if status ~= 0x00 then fail('socks5: username/password auth rejected'); break end
                local req, e = socks5_connect_req(host, port)
                if not req then fail('socks5: ' .. e); break end
                conn:send_raw(req); phase = 'reply'
            elseif phase == 'reply' then
                if #buf < 4 then break end
                if sbyte(buf, 1) ~= 0x05 then fail('socks5: bad version in connect reply'); break end
                local rep = sbyte(buf, 2)
                if rep ~= 0x00 then
                    fail('socks5: connect rejected: ' .. (SOCKS5_REP[rep] or ('rep ' .. rep))); break
                end
                local atyp, total = sbyte(buf, 4), nil
                if atyp == 0x01 then total = 10
                elseif atyp == 0x04 then total = 22
                elseif atyp == 0x03 then
                    if #buf < 5 then break end
                    total = 7 + sbyte(buf, 5)
                else fail('socks5: unexpected ATYP ' .. tostring(atyp)); break end
                if #buf < total then break end
                schedule_ready(buf:sub(total + 1))
                break
            else
                break
            end
        end
        return #data
    end
    h.on_recv = on_data
    h.on_packet = on_data

    function h.on_close(_, reason)
        fail('proxy closed before tunnel established (' .. tostring(reason) .. ')')
    end

    local timeout_ms = (opts and opts.timeout_ms) or M.HANDSHAKE_TIMEOUT_MS
    if timeout_ms > 0 then
        timer = after(timeout_ms, function()
            timer = nil
            fail(string.format('proxy handshake timed out after %dms (%s://%s:%d)',
                timeout_ms, proxy.type, proxy.host, proxy.port))
        end)
    end

    local conn, cerr = xnet.connect(proxy.host, proxy.port, h)
    if not conn then
        fail('proxy connect failed: ' .. tostring(cerr))
        return tun
    end
    if not tun.done then tun.conn = tun.conn or conn end
    return tun
end

-- attach(conn, extra, handler, opts) -> conn | nil, err
-- Turn a ready tunnel into the caller's connection. handler.on_connect fires
-- once the origin is reachable (after the TLS handshake for opts.tls), so the
-- caller's usual "send the request in on_connect" logic works unchanged.
--   opts = { tls = bool, host, port, verify, ca_file }
-- On error the tunnel connection is already closed.
function M.attach(conn, extra, handler, opts)
    extra = extra or ''
    if opts.tls then
        if #extra > 0 then
            -- Bytes after the proxy reply would corrupt the TLS record stream.
            conn:close('proxy_error')
            return nil, 'proxy sent unexpected data before TLS handshake'
        end
        if not xnet.connect_tls_fd then
            conn:close('no_tls')
            return nil, 'https not supported: xnet built without HTTPS'
        end
        local fd = conn:detach()             -- surrender fd; raw channel freed
        if not fd then return nil, 'proxy detach failed' end
        local tls, err = xnet.connect_tls_fd(fd, handler, opts.host, opts.port, {
            verify = opts.verify ~= false,
            ca_file = opts.ca_file,
            server_name = opts.host,
        })
        if not tls then return nil, 'tls upgrade failed: ' .. tostring(err) end
        return tls
    end
    -- Plaintext origin: the raw connection IS the tunnel. Swap in the caller's
    -- handler, replay the on_connect it missed, then any bytes already read.
    conn:set_handler(handler)
    if handler.on_connect then handler.on_connect(conn) end
    local on_data = handler.on_recv or handler.on_packet
    if #extra > 0 and on_data and not conn:is_closed() then on_data(conn, extra) end
    return conn
end

return M
