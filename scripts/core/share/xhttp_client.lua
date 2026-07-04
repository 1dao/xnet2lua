-- xhttp_client.lua - asynchronous HTTP/HTTPS client built on xnet + xhttp_codec.
--
-- Non-blocking and callback-based: it drives requests through the same xnet
-- event loop as the rest of the project. Plaintext uses xnet.connect; TLS uses
-- xnet.connect_tls (only present when xnet was built WITH_HTTPS=1). Responses
-- are parsed with xhttp_codec.parse_response, so Content-Length, chunked,
-- gzip/deflate and Connection: close framing are all handled.
--
-- Usage:
--   local httpc = dofile('scripts/core/share/xhttp_client.lua')
--   httpc.get('https://example.com/', function(err, resp)
--       if err then return print('error: ' .. err) end
--       print(resp.status, #resp.body)
--   end)
--
-- The callback fires exactly once with either (err) or (nil, resp), where
-- resp = { status, version, headers, header_list, body }.

local codec = dofile('scripts/core/share/xhttp_codec.lua')
local xutils = require('xutils')   -- base64_encode for HTTP CONNECT Basic auth

local M = {}
M.codec = codec
M.parse_url = codec.parse_url

local DEFAULT_MAX_REDIRECTS = 5
local DEFAULT_USER_AGENT = 'xnet-httpc/1.0'
local MAX_RESPONSE = 64 * 1024 * 1024

-- Forward declarations (these functions reference one another).
local start_connection, handle_response, make_handler, start_tunnel, finish_tunnel

local function header_present(headers, name)
    if type(headers) ~= 'table' then return false end
    local lname = name:lower()
    for k in pairs(headers) do
        if tostring(k):lower() == lname then return true end
    end
    return false
end

local function default_port(scheme)
    return scheme == 'https' and 443 or 80
end

local function authority_for(scheme, host, port)
    if port == default_port(scheme) then return host end
    return host .. ':' .. tostring(port)
end

local function build_request(req)
    local out = { req.method .. ' ' .. req.path .. ' HTTP/1.1\r\n' }

    local h = {}
    if type(req.headers) == 'table' then
        for k, v in pairs(req.headers) do h[k] = v end
    end
    if not header_present(h, 'host') then h['Host'] = req.host_hdr end
    if not header_present(h, 'user-agent') then h['User-Agent'] = DEFAULT_USER_AGENT end
    if not header_present(h, 'accept') then h['Accept'] = '*/*' end
    if req.decompress and not header_present(h, 'accept-encoding') then
        h['Accept-Encoding'] = 'gzip, deflate'
    end
    if not header_present(h, 'connection') then h['Connection'] = 'close' end
    if req.body and #req.body > 0 and not header_present(h, 'content-length') then
        h['Content-Length'] = tostring(#req.body)
    end

    for k, v in pairs(h) do
        out[#out + 1] = codec.clean_header(k) .. ': ' .. codec.clean_header(v) .. '\r\n'
    end
    out[#out + 1] = '\r\n'
    if req.body and #req.body > 0 then out[#out + 1] = req.body end
    return table.concat(out)
end

-- Resolve a (possibly relative) Location against the request's current URL.
local function resolve_url(base, loc)
    if loc:match('^%a[%w+.-]*://') then return loc end
    local scheme, host, port, path = codec.parse_url(base)
    if not scheme then return loc end
    local authority = authority_for(scheme, host, port)
    if loc:sub(1, 1) == '/' then
        return scheme .. '://' .. authority .. loc
    end
    local dir = path:match('^(.*/)[^/]*$') or '/'
    return scheme .. '://' .. authority .. dir .. loc
end

local function fire_once(state, err, resp)
    if state.done then return end
    state.done = true
    if state.timer then
        state.timer:del()
        state.timer = nil
    end
    state.cb(err, resp)
end

handle_response = function(state, resp)
    local status = resp.status
    if status >= 300 and status < 400 and state.redirects_left > 0 then
        local loc = resp.headers and resp.headers['location']
        if loc and loc ~= '' then
            state.redirects_left = state.redirects_left - 1
            local nurl = resolve_url(state.url, loc)
            local method, body = state.method, state.body
            -- 303 always becomes GET; 301/302 on POST follow common browser
            -- behaviour and switch to GET. 307/308 preserve method + body.
            if status == 303 or ((status == 301 or status == 302) and method == 'POST') then
                method, body = 'GET', nil
            end
            start_connection(state, nurl, method, body)
            return
        end
    end
    fire_once(state, nil, resp)
end

make_handler = function(state)
    local buf = ''
    local h = {}

    function h.on_connect(conn)
        local ok, serr = conn:send_raw(state.request_bytes)
        if not ok then
            conn:close('send_failed')
            fire_once(state, 'send failed: ' .. tostring(serr))
        end
    end

    local function on_data(conn, data)
        buf = buf .. data
        if #buf > MAX_RESPONSE then
            conn:close('too_large')
            fire_once(state, 'response too large')
            return #data
        end
        local resp, _, perr = codec.parse_response(buf, 1, {
            method = state.method,
            decompress = state.decompress,
        })
        if resp then
            state.parsed = true
            conn:close('done')
            handle_response(state, resp)
        elseif perr and perr ~= 'incomplete' then
            conn:close('parse_error')
            fire_once(state, 'parse error: ' .. tostring(perr))
        end
        -- Consume everything the channel handed us; we keep our own buffer.
        return #data
    end
    h.on_packet = on_data
    h.on_recv = on_data

    function h.on_close(_, reason)
        if state.done or state.parsed then return end
        -- The peer closed; if it used Connection: close framing (no length, not
        -- chunked) the body is whatever we have buffered.
        local resp = codec.parse_response(buf, 1, {
            method = state.method,
            decompress = state.decompress,
            eof = true,
        })
        if resp then
            handle_response(state, resp)
        else
            fire_once(state, 'connection closed before full response ('
                .. tostring(reason) .. ')')
        end
    end

    return h
end

-- ---------------------------------------------------------------------------
-- Proxy support (opt-in, per request via opts.proxy). Two tunnel protocols:
--   * SOCKS5 / SOCKS5h (RFC 1928 + RFC 1929 user/pass) -- socks5h delegates DNS
--     to the proxy, which is what we want when the origin is unresolvable
--     locally (e.g. reaching Google from a restricted network).
--   * HTTP CONNECT (RFC 7231) -- for HTTPS targets via an HTTP proxy.
-- Plaintext HTTP via an HTTP proxy uses absolute-form (forward proxy), no tunnel.
--
-- For HTTPS targets the tunnel carries raw TLS: once the proxy handshake
-- completes we surrender the plaintext fd (conn:detach) and upgrade it to a
-- client-mode TLS session with xnet.connect_tls_fd (SNI = real origin host).
-- The detach + upgrade is ALWAYS deferred to the next tick: detaching inside
-- the channel's own callback would free the channel the poll loop is mid-walk.
-- ---------------------------------------------------------------------------
local schar = string.char
local sbyte = string.byte

-- Parse "scheme://[user:pass@]host[:port]" into a proxy table, or nil[, err].
local function parse_proxy(s)
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
M.parse_proxy = parse_proxy

local function merge_headers(base, extra)
    if not extra then return base end
    local h = {}
    if type(base) == 'table' then for k, v in pairs(base) do h[k] = v end end
    for k, v in pairs(extra) do h[k] = v end
    return h
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

-- Connect to the proxy and run the tunnel handshake. On success, hands off to
-- finish_tunnel (deferred). Used for SOCKS5/SOCKS5h (any target) and HTTP
-- CONNECT (HTTPS target via HTTP proxy).
start_tunnel = function(state, proxy)
    local buf, phase = '', (proxy.type == 'http') and 'connect' or 'greet'

    local function fail(msg)
        local c = state.proxy_conn
        if c and not c:is_closed() then c:close('proxy_error') end
        fire_once(state, msg)
    end

    -- Defer detach/upgrade out of the channel callback (see header note).
    local function schedule_finish(extra)
        if state.done then return end
        phase = 'done'
        local xt = rawget(_G, 'xtimer')
        if not (type(xt) == 'table' and xt.inited and xt.inited()) then
            return fail('proxy tunnel needs xtimer (call xtimer.init on this thread)')
        end
        xt.add(0, function() finish_tunnel(state, extra) end, 1)
    end

    local h = {}

    function h.on_connect(conn)
        state.proxy_conn = conn
        local ok, serr
        if proxy.type == 'http' then
            local target = state.host .. ':' .. state.port
            local req = { 'CONNECT ' .. target .. ' HTTP/1.1\r\n', 'Host: ' .. target .. '\r\n' }
            if proxy.user then
                local cred = xutils.base64_encode((proxy.user or '') .. ':' .. (proxy.pass or ''))
                req[#req + 1] = 'Proxy-Authorization: Basic ' .. cred .. '\r\n'
            end
            req[#req + 1] = '\r\n'
            ok, serr = conn:send_raw(table.concat(req))
        else
            ok, serr = conn:send_raw(socks5_greeting(proxy))
        end
        if not ok then fail('proxy handshake send: ' .. tostring(serr)) end
    end

    local function on_data(conn, data)
        if state.done then return #data end
        buf = buf .. data

        if proxy.type == 'http' then
            local hdr_end = buf:find('\r\n\r\n', 1, true)
            if not hdr_end then
                if #buf > 64 * 1024 then fail('proxy CONNECT response too large') end
                return #data
            end
            local status = buf:match('^HTTP/%d%.%d%s+(%d%d%d)')
            if not status then return fail('proxy CONNECT: malformed response') end
            if status ~= '200' then return fail('proxy CONNECT rejected: HTTP ' .. status) end
            schedule_finish(buf:sub(hdr_end + 4))
            return #data
        end

        -- SOCKS5 state machine; loop because phases can complete back-to-back.
        while true do
            if phase == 'greet' then
                if #buf < 2 then break end
                if sbyte(buf, 1) ~= 0x05 then return fail('socks5: bad version in method reply') end
                local method = sbyte(buf, 2)
                buf = buf:sub(3)
                if method == 0x00 then
                    local req, e = socks5_connect_req(state.host, state.port)
                    if not req then return fail('socks5: ' .. e) end
                    conn:send_raw(req); phase = 'reply'
                elseif method == 0x02 then
                    if not proxy.user then return fail('socks5: proxy requires auth but no credentials given') end
                    local req, e = socks5_auth_req(proxy.user, proxy.pass)
                    if not req then return fail('socks5: ' .. e) end
                    conn:send_raw(req); phase = 'auth'
                else
                    return fail(string.format('socks5: no acceptable auth method (0x%02x)', method))
                end
            elseif phase == 'auth' then
                if #buf < 2 then break end
                local ok = sbyte(buf, 2)
                buf = buf:sub(3)
                if ok ~= 0x00 then return fail('socks5: username/password auth rejected') end
                local req, e = socks5_connect_req(state.host, state.port)
                if not req then return fail('socks5: ' .. e) end
                conn:send_raw(req); phase = 'reply'
            elseif phase == 'reply' then
                if #buf < 4 then break end
                if sbyte(buf, 1) ~= 0x05 then return fail('socks5: bad version in connect reply') end
                local rep = sbyte(buf, 2)
                if rep ~= 0x00 then
                    return fail('socks5: connect rejected: ' .. (SOCKS5_REP[rep] or ('rep ' .. rep)))
                end
                local atyp, total = sbyte(buf, 4), nil
                if atyp == 0x01 then total = 10
                elseif atyp == 0x04 then total = 22
                elseif atyp == 0x03 then
                    if #buf < 5 then break end
                    total = 7 + sbyte(buf, 5)
                else return fail('socks5: unexpected ATYP ' .. tostring(atyp)) end
                if #buf < total then break end
                schedule_finish(buf:sub(total + 1))
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
        if not state.done then
            fire_once(state, 'proxy closed before tunnel established (' .. tostring(reason) .. ')')
        end
    end

    local conn, cerr = xnet.connect(proxy.host, proxy.port, h)
    if not conn then
        fire_once(state, 'proxy connect failed: ' .. tostring(cerr))
        return
    end
    state.proxy_conn = conn
end

-- Tunnel is up: either upgrade the fd to TLS (HTTPS origin) or reuse the raw
-- connection (plaintext origin). Runs on a timer tick, never inside a callback.
finish_tunnel = function(state, extra)
    if state.done then return end
    extra = extra or ''
    local conn = state.proxy_conn
    if not conn or conn:is_closed() then return fire_once(state, 'proxy tunnel lost') end

    if state.scheme == 'https' then
        if #extra > 0 then
            -- Bytes after the proxy reply would corrupt the TLS record stream.
            return fire_once(state, 'proxy sent unexpected data before TLS handshake')
        end
        local fd = conn:detach()             -- surrender fd; raw channel freed
        state.proxy_conn = nil
        if not fd then return fire_once(state, 'proxy detach failed') end
        local tls, err = xnet.connect_tls_fd(fd, make_handler(state), state.host, state.port, {
            verify = state.verify,
            ca_file = state.ca_file,
            server_name = state.host,
        })
        if not tls then return fire_once(state, 'tls upgrade failed: ' .. tostring(err)) end
        state.conn = tls
        -- make_handler.on_connect fires after the TLS handshake and sends the request.
    else
        -- Plaintext origin: the raw connection IS the tunnel. Swap in the
        -- response handler (on_connect already fired) and send the request.
        local handler = make_handler(state)
        conn:set_handler(handler)
        state.conn = conn
        local ok, serr = conn:send_raw(state.request_bytes)
        if not ok then
            conn:close('send_failed')
            return fire_once(state, 'send failed: ' .. tostring(serr))
        end
        if #extra > 0 and handler.on_recv then handler.on_recv(conn, extra) end
    end
end

start_connection = function(state, url, method, body)
    state.url = url
    state.method = method
    state.body = body

    local scheme, host, port, path = codec.parse_url(url)
    if not scheme then
        fire_once(state, 'bad url: ' .. tostring(host))
        return
    end
    if scheme ~= 'http' and scheme ~= 'https' then
        fire_once(state, 'unsupported scheme: ' .. scheme)
        return
    end
    state.scheme, state.host, state.port = scheme, host, port
    state.parsed = false

    local proxy = state.proxy
    local authority = authority_for(scheme, host, port)

    -- HTTP proxy + plaintext target: classic forward proxy with absolute-form
    -- request line; no CONNECT tunnel needed.
    if proxy and proxy.type == 'http' and scheme == 'http' then
        local extra
        if proxy.user then
            extra = { ['Proxy-Authorization'] = 'Basic ' ..
                xutils.base64_encode((proxy.user or '') .. ':' .. (proxy.pass or '')) }
        end
        state.request_bytes = build_request({
            method = method,
            path = scheme .. '://' .. authority .. path,   -- absolute-form
            host_hdr = authority,
            headers = merge_headers(state.headers, extra),
            body = body,
            decompress = state.decompress,
        })
        local conn, cerr = xnet.connect(proxy.host, proxy.port, make_handler(state))
        if not conn then
            fire_once(state, 'proxy connect failed: ' .. tostring(cerr))
            return
        end
        state.conn = conn
        return
    end

    -- Origin-form request -- travels through the tunnel (proxy) or directly.
    state.request_bytes = build_request({
        method = method,
        path = path,
        host_hdr = authority,
        headers = state.headers,
        body = body,
        decompress = state.decompress,
    })

    -- Tunnelled paths: SOCKS5/SOCKS5h (any scheme) or HTTP CONNECT (https only).
    if proxy then
        if scheme == 'https'
            and (type(rawget(_G, 'xnet')) ~= 'table' or not xnet.connect_tls_fd) then
            fire_once(state, 'https not supported: xnet built without HTTPS')
            return
        end
        start_tunnel(state, proxy)
        return
    end

    -- Direct connection (no proxy).
    local handler = make_handler(state)
    local conn, cerr
    if scheme == 'https' then
        if type(rawget(_G, 'xnet')) ~= 'table' or not xnet.connect_tls then
            fire_once(state, 'https not supported: xnet built without HTTPS')
            return
        end
        conn, cerr = xnet.connect_tls(host, port, handler, {
            verify = state.verify,
            ca_file = state.ca_file,
            server_name = host,
        })
    else
        conn, cerr = xnet.connect(host, port, handler)
    end

    if not conn then
        fire_once(state, 'connect failed: ' .. tostring(cerr))
        return
    end
    state.conn = conn
end

-- httpc.request(opts, cb)
--   opts: url | (scheme/host/port/path), method, headers, body,
--         timeout_ms, max_redirects, verify (TLS, default true), ca_file,
--         decompress (default true),
--         proxy (per-request proxy URL: socks5://, socks5h://, or http://,
--                with optional user:pass@; default none = direct connect).
--   cb(err, resp)
function M.request(opts, cb)
    assert(type(opts) == 'table', 'xhttp_client.request: opts table required')
    assert(type(cb) == 'function', 'xhttp_client.request: callback required')

    local url = opts.url
    if not url then
        local scheme = opts.scheme or 'http'
        assert(opts.host, 'xhttp_client.request: opts.url or opts.host required')
        local port = opts.port or default_port(scheme)
        url = string.format('%s://%s:%d%s', scheme, opts.host, port, opts.path or '/')
    end

    local decompress = opts.decompress
    if decompress == nil then decompress = true end
    local verify = opts.verify
    if verify == nil then verify = true end

    local state = {
        cb = cb,
        headers = opts.headers,
        decompress = decompress,
        verify = verify,
        ca_file = opts.ca_file,
        timeout_ms = opts.timeout_ms,
        redirects_left = opts.max_redirects or DEFAULT_MAX_REDIRECTS,
        done = false,
    }

    -- Optional per-request proxy (opt-in; no implicit global/env source).
    if opts.proxy and opts.proxy ~= '' then
        local p, perr = parse_proxy(opts.proxy)
        if not p then
            fire_once(state, 'proxy config: ' .. tostring(perr))
            return state
        end
        state.proxy = p
    end

    -- Optional request timeout, only when the timer subsystem is running.
    local xt = rawget(_G, 'xtimer')
    if state.timeout_ms and state.timeout_ms > 0
        and type(xt) == 'table' and xt.inited and xt.inited() then
        state.timer = xt.add(state.timeout_ms, function()
            state.timer = nil
            -- Either the direct/TLS conn or the in-flight proxy conn may be live.
            local c = state.conn or state.proxy_conn
            if c and not c:is_closed() then c:close('timeout') end
            fire_once(state, 'timeout')
        end, 1)
    end

    start_connection(state, url, (opts.method or 'GET'):upper(), opts.body)
    return state
end

function M.get(url, opts, cb)
    if type(opts) == 'function' then cb, opts = opts, nil end
    opts = opts or {}
    opts.url = url
    opts.method = 'GET'
    return M.request(opts, cb)
end

function M.post(url, body, opts, cb)
    if type(opts) == 'function' then cb, opts = opts, nil end
    opts = opts or {}
    opts.url = url
    opts.method = 'POST'
    opts.body = body
    return M.request(opts, cb)
end

return M
