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

local M = {}
M.codec = codec
M.parse_url = codec.parse_url

local DEFAULT_MAX_REDIRECTS = 5
local DEFAULT_USER_AGENT = 'xnet-httpc/1.0'
local MAX_RESPONSE = 64 * 1024 * 1024

-- Forward declarations (these functions reference one another).
local start_connection, handle_response, make_handler

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

    state.request_bytes = build_request({
        method = method,
        path = path,
        host_hdr = authority_for(scheme, host, port),
        headers = state.headers,
        body = body,
        decompress = state.decompress,
    })
    state.parsed = false

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
--         decompress (default true).
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

    -- Optional request timeout, only when the timer subsystem is running.
    local xt = rawget(_G, 'xtimer')
    if state.timeout_ms and state.timeout_ms > 0
        and type(xt) == 'table' and xt.inited and xt.inited() then
        state.timer = xt.add(state.timeout_ms, function()
            state.timer = nil
            if state.conn and not state.conn:is_closed() then
                state.conn:close('timeout')
            end
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
