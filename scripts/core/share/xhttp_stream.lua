-- xhttp_stream.lua — generic streaming HTTP/HTTPS client.
--
-- Non-blocking, callback-based, built on xnet.connect / xnet.connect_tls and the
-- shared event loop. Unlike xhttp_client.lua (which buffers the whole response
-- before parsing), this one parses the status + headers once and then surfaces
-- the body INCREMENTALLY: it de-chunks Transfer-Encoding: chunked on the fly and
-- feeds the decoded bytes to an SSE parser, emitting one callback per SSE event.
-- This is what makes token-by-token LLM streaming work. (The chunked decoder
-- here is stateful/incremental, unlike xhttp_codec.parse_chunked which is
-- one-shot over a complete buffer.)
--
-- Usage:
--   local stream = dofile('scripts/core/share/xhttp_stream.lua')
--   stream.request({ url = 'https://host/path', method = 'POST',
--                    headers = {...}, body = '...', verify = true }, {
--     on_headers = function(status, headers) end,
--     on_body    = function(chunk) end,          -- raw de-chunked body bytes
--     on_sse     = function(event, data) end,   -- per SSE event
--     on_done    = function(reason) end,         -- connection finished
--     on_error   = function(err) end,            -- connect/transport error
--   })
--
-- opts.proxy (optional) routes the request through a proxy: socks5://,
-- socks5h:// or http:// with optional user:pass@ (see xproxy.lua). Default is
-- a direct connection.

local codec = dofile('scripts/core/share/xhttp_codec.lua')
local sse = dofile('scripts/core/share/xsse.lua')
local xproxy = dofile('scripts/core/share/xproxy.lua')

local M = {}

local DEFAULT_USER_AGENT = 'xagent/0.1'

-- ── incremental HTTP chunked-transfer decoder ──────────────────────────────
-- new() -> object with :feed(bytes) -> decoded bytes (may be '')  and  .done
local function new_chunked()
    local self = { buf = '', need = 0, state = 'size', done = false }

    function self:feed(data)
        self.buf = self.buf .. data
        local out = {}

        while not self.done do
            if self.state == 'size' then
                local e = self.buf:find('\r\n', 1, true)
                if not e then break end
                local line = self.buf:sub(1, e - 1)
                self.buf = self.buf:sub(e + 2)
                local hex = line:match('^%x+')           -- ignore ;chunk-ext
                local n = hex and tonumber(hex, 16)
                if not n then self.done = true; break end -- malformed → stop
                if n == 0 then
                    self.state = 'trailer'
                else
                    self.need = n
                    self.state = 'data'
                end

            elseif self.state == 'data' then
                if #self.buf == 0 then break end
                local take = math.min(self.need, #self.buf)
                out[#out + 1] = self.buf:sub(1, take)
                self.buf = self.buf:sub(take + 1)
                self.need = self.need - take
                if self.need == 0 then self.state = 'data_crlf' end

            elseif self.state == 'data_crlf' then
                if #self.buf < 2 then break end
                self.buf = self.buf:sub(3)                -- drop trailing CRLF
                self.state = 'size'

            elseif self.state == 'trailer' then
                local e = self.buf:find('\r\n', 1, true)
                if not e then break end
                if e == 1 then
                    self.buf = self.buf:sub(3)            -- blank line → end
                    self.done = true
                else
                    self.buf = self.buf:sub(e + 2)        -- skip a trailer line
                end
            end
        end

        return table.concat(out)
    end

    return self
end
M._new_chunked = new_chunked

-- ── status line + headers ──────────────────────────────────────────────────
local function parse_head(head)
    local status, headers = 0, {}
    local first = true
    for line in (head .. '\r\n'):gmatch('(.-)\r\n') do
        if first then
            status = tonumber(line:match('^HTTP/%d%.%d%s+(%d+)')) or 0
            first = false
        elseif line ~= '' then
            local k, v = line:match('^([^:]+):%s*(.*)$')
            if k then headers[k:lower()] = v end
        end
    end
    return status, headers
end
M._parse_head = parse_head

-- ── request line + headers builder ─────────────────────────────────────────
local function has_header(h, name)
    local lname = name:lower()
    for k in pairs(h) do
        if tostring(k):lower() == lname then return true end
    end
    return false
end

-- extra: headers only this hop needs (Proxy-Authorization for a forward proxy).
local function build_request_bytes(opts, host, path, extra)
    local method = (opts.method or 'GET'):upper()
    local out = { method .. ' ' .. path .. ' HTTP/1.1\r\n' }

    local h = {}
    if type(opts.headers) == 'table' then
        for k, v in pairs(opts.headers) do h[k] = v end
    end
    if extra then
        for k, v in pairs(extra) do h[k] = v end
    end
    if not has_header(h, 'host') then h['Host'] = host end
    if not has_header(h, 'user-agent') then h['User-Agent'] = DEFAULT_USER_AGENT end
    if not has_header(h, 'connection') then h['Connection'] = 'close' end
    if opts.body and #opts.body > 0 and not has_header(h, 'content-length') then
        h['Content-Length'] = tostring(#opts.body)
    end

    for k, v in pairs(h) do
        out[#out + 1] = codec.clean_header(k) .. ': ' .. codec.clean_header(v) .. '\r\n'
    end
    out[#out + 1] = '\r\n'
    if opts.body and #opts.body > 0 then out[#out + 1] = opts.body end
    return table.concat(out)
end

-- ── public ─────────────────────────────────────────────────────────────────
-- Returns the connection, or the proxy tunnel handle while one is being set
-- up, or nil when the request failed synchronously (on_error already fired).
function M.request(opts, cb)
    assert(type(opts) == 'table' and opts.url, 'stream.request: opts.url required')
    cb = cb or {}

    local scheme, host, port, path = codec.parse_url(opts.url)
    if not scheme then
        if cb.on_error then cb.on_error('bad url: ' .. tostring(host)) end
        return nil
    end
    if scheme ~= 'http' and scheme ~= 'https' then
        if cb.on_error then cb.on_error('unsupported scheme: ' .. scheme) end
        return nil
    end

    local parser = sse.new()
    local header_done = false
    local hbuf = ''
    local te_chunked = false
    local chunked = nil
    local fired_done = false
    local status_code = nil
    local is_http_error = false
    local err_body = {}      -- accumulated body bytes when status >= 400

    local function finish(reason)
        if fired_done then return end
        fired_done = true
        if is_http_error and cb.on_http_error then
            cb.on_http_error(status_code, table.concat(err_body))
        elseif cb.on_done then
            cb.on_done(reason)
        end
    end

    local proxy, perr = xproxy.parse(opts.proxy)
    if perr then
        if cb.on_error then cb.on_error('proxy config: ' .. tostring(perr)) end
        return nil
    end

    -- An HTTP proxy forwards plaintext requests itself: absolute-form request
    -- line to the proxy, no tunnel. Every other proxied case is a tunnel.
    local forward = proxy and proxy.type == 'http' and scheme == 'http'
    local request_bytes
    if forward then
        local auth = xproxy.auth_header(proxy)
        request_bytes = build_request_bytes(opts, host, opts.url,
            auth and { ['Proxy-Authorization'] = auth } or nil)
    else
        request_bytes = build_request_bytes(opts, host, path)
    end

    local handler = {}

    function handler.on_connect(conn)
        local ok, err = conn:send_raw(request_bytes)
        if not ok then
            conn:close('send_failed')
            if cb.on_error then cb.on_error('send failed: ' .. tostring(err)) end
        end
    end

    local function on_data(conn, data)
        -- We buffer internally, so we always consume everything the channel
        -- handed us. This MUST be the delivered length, not the leftover body
        -- length — returning less makes the raw channel redeliver the header
        -- bytes, which then poison the chunked decoder (0 events + socket_error).
        local consumed = #data

        if not header_done then
            hbuf = hbuf .. data
            local sep = hbuf:find('\r\n\r\n', 1, true)
            if not sep then return consumed end
            local head = hbuf:sub(1, sep - 1)
            data = hbuf:sub(sep + 4)          -- leftover bytes are body
            local status, headers = parse_head(head)
            status_code = status
            is_http_error = (status >= 400)
            header_done = true
            te_chunked = ((headers['transfer-encoding'] or ''):lower():find('chunked', 1, true)) ~= nil
            if te_chunked then chunked = new_chunked() end
            if cb.on_headers then cb.on_headers(status, headers) end
        end

        local body = te_chunked and chunked:feed(data) or data
        if body and #body > 0 then
            -- raw de-chunked response body (all paths) — lets callers capture the
            -- exact bytes the server sent (the SSE stream / the error JSON)
            if cb.on_body then cb.on_body(body) end
            if is_http_error then
                err_body[#err_body + 1] = body          -- collect the error JSON
            elseif cb.on_sse then
                for _, ev in ipairs(parser:feed(body)) do
                    cb.on_sse(ev.event, ev.data)
                end
            end
        end
        return consumed
    end
    handler.on_packet = on_data
    handler.on_recv = on_data

    function handler.on_close(_, reason)
        finish(reason)
    end

    local function fail(msg)
        if cb.on_error then cb.on_error(msg) end
        return nil
    end

    if proxy and not forward then
        if scheme == 'https' and not xnet.connect_tls_fd then
            return fail('https not supported: xnet built without HTTPS')
        end
        return xproxy.open_tunnel(proxy, host, port, {
            on_ready = function(tconn, extra)
                local c, aerr = xproxy.attach(tconn, extra, handler, {
                    tls = scheme == 'https', host = host, port = port,
                    verify = opts.verify, ca_file = opts.ca_file,
                })
                if not c then fail(aerr) end
            end,
            on_error = fail,
        })
    end

    local conn, err
    if forward then
        conn, err = xnet.connect(proxy.host, proxy.port, handler)
        if not conn then return fail('proxy connect failed: ' .. tostring(err)) end
        return conn
    elseif scheme == 'https' then
        if type(rawget(_G, 'xnet')) ~= 'table' or not xnet.connect_tls then
            if cb.on_error then cb.on_error('https not supported: xnet built without HTTPS') end
            return nil
        end
        conn, err = xnet.connect_tls(host, port, handler, {
            verify = opts.verify ~= false,
            ca_file = opts.ca_file,
            server_name = host,
        })
    else
        conn, err = xnet.connect(host, port, handler)
    end

    if not conn then
        if cb.on_error then cb.on_error('connect failed: ' .. tostring(err)) end
        return nil
    end
    return conn
end

return M
