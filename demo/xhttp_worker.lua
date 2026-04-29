-- xhttp_worker.lua - worker-side HTTP parser and dispatcher.
-- Connections use xchannel raw framing. The return value from on_packet is the
-- number of bytes consumed from the stream buffer.

local MAIN_ID = xthread.MAIN

local app = nil
local app_script = nil
local max_request_size = 16 * 1024 * 1024
local server_name = 'xnet-http'
local use_https = false
local tls_config = nil
local connections = {}

_stubs = {}
_thread_replys = {}

function xthread.register(pt, h)
    _stubs[pt] = h
end

local function __thread_handle(reply_router, k1, k2, k3, ...)
    if reply_router then
        io.stderr:write('[XHTTP-WORKER] unexpected RPC message: ' .. tostring(k3) .. '\n')
        return
    end

    local h = _stubs[k1]
    if h then
        h(k2, k3, ...)
    elseif k1 then
        io.stderr:write('[XHTTP-WORKER] no handler for pt=' .. tostring(k1) .. '\n')
    end
end

local function trim(s)
    return (s:gsub('^%s+', ''):gsub('%s+$', ''))
end

local function lower(s)
    return string.lower(s or '')
end

local function uri_decode(s)
    s = tostring(s or ''):gsub('+', ' ')
    return (s:gsub('%%(%x%x)', function(hex)
        return string.char(tonumber(hex, 16))
    end))
end

local function parse_query(qs)
    local out = {}
    if not qs or qs == '' then return out end
    for part in string.gmatch(qs, '([^&]+)') do
        local eq = part:find('=', 1, true)
        local k, v
        if eq then
            k = uri_decode(part:sub(1, eq - 1))
            v = uri_decode(part:sub(eq + 1))
        else
            k = uri_decode(part)
            v = true
        end
        out[k] = v
    end
    return out
end

local function split_lines(s)
    local lines = {}
    local pos = 1
    while true do
        local e = s:find('\r\n', pos, true)
        if not e then
            lines[#lines + 1] = s:sub(pos)
            break
        end
        lines[#lines + 1] = s:sub(pos, e - 1)
        pos = e + 2
    end
    return lines
end

local function parse_target(target)
    local t = target or '/'
    if t:find('://', 1, true) then
        t = t:match('^https?://[^/]*(/.*)$') or '/'
    end

    local path = t
    local query_string = ''
    local q = t:find('?', 1, true)
    if q then
        path = t:sub(1, q - 1)
        query_string = t:sub(q + 1)
    end
    if path == '' then path = '/' end
    return path, query_string, parse_query(query_string)
end

local function parse_chunked(data, pos)
    local chunks = {}
    local len = #data

    while true do
        local line_end = data:find('\r\n', pos, true)
        if not line_end then return nil, nil, 'incomplete' end

        local size_line = trim(data:sub(pos, line_end - 1))
        local hex = size_line:match('^([0-9a-fA-F]+)')
        local size = hex and tonumber(hex, 16)
        if not size then return nil, nil, 'bad chunk size' end

        pos = line_end + 2
        if size == 0 then
            if data:sub(pos, pos + 1) == '\r\n' then
                return table.concat(chunks), pos + 2
            end
            local trailer_end = data:find('\r\n\r\n', pos, true)
            if not trailer_end then return nil, nil, 'incomplete' end
            return table.concat(chunks), trailer_end + 4
        end

        if len < pos + size + 1 then
            return nil, nil, 'incomplete'
        end

        chunks[#chunks + 1] = data:sub(pos, pos + size - 1)
        pos = pos + size

        if data:sub(pos, pos + 1) ~= '\r\n' then
            return nil, nil, 'bad chunk terminator'
        end
        pos = pos + 2
    end
end

local function parse_one_request(data, start_pos, state)
    local header_end = data:find('\r\n\r\n', start_pos, true)
    if not header_end then
        if #data - start_pos + 1 > max_request_size then
            return nil, nil, 'request too large'
        end
        return nil, nil, 'incomplete'
    end

    local header_block = data:sub(start_pos, header_end - 1)
    local lines = split_lines(header_block)
    local request_line = lines[1] or ''
    local method, target, version = request_line:match('^(%S+)%s+(%S+)%s+(HTTP/%d%.%d)$')
    if not method then
        return nil, nil, 'bad request line'
    end

    local headers = {}
    local header_list = {}
    for i = 2, #lines do
        local line = lines[i]
        if line ~= '' then
            local colon = line:find(':', 1, true)
            if not colon then
                return nil, nil, 'bad header'
            end
            local name = lower(trim(line:sub(1, colon - 1)))
            local value = trim(line:sub(colon + 1))
            header_list[#header_list + 1] = { name = name, value = value }
            if headers[name] then
                headers[name] = headers[name] .. ', ' .. value
            else
                headers[name] = value
            end
        end
    end

    local body_start = header_end + 4
    local body = ''
    local next_pos = body_start
    local transfer_encoding = lower(headers['transfer-encoding'])
    if transfer_encoding:find('chunked', 1, true) then
        local chunk_body, chunk_next, chunk_err = parse_chunked(data, body_start)
        if chunk_err == 'incomplete' then return nil, nil, 'incomplete' end
        if chunk_err then return nil, nil, chunk_err end
        body = chunk_body
        next_pos = chunk_next
    else
        local content_length = tonumber(headers['content-length'] or '0') or 0
        if content_length < 0 then
            return nil, nil, 'bad content length'
        end
        if content_length > max_request_size then
            return nil, nil, 'request body too large'
        end
        if #data < body_start + content_length - 1 then
            return nil, nil, 'incomplete'
        end
        if content_length > 0 then
            body = data:sub(body_start, body_start + content_length - 1)
        end
        next_pos = body_start + content_length
    end

    if next_pos - start_pos > max_request_size then
        return nil, nil, 'request too large'
    end

    local path, query_string, query = parse_target(target)
    local connection = lower(headers['connection'])
    local keep_alive = version == 'HTTP/1.1'
    if connection:find('close', 1, true) then
        keep_alive = false
    elseif connection:find('keep%-alive') or connection:find('keep-alive', 1, true) then
        keep_alive = true
    end

    return {
        method = method,
        target = target,
        path = path,
        query_string = query_string,
        query = query,
        version = version,
        headers = headers,
        header_list = header_list,
        body = body,
        keep_alive = keep_alive,
        peer_ip = state and state.ip or nil,
        peer_port = state and state.port or nil,
    }, next_pos
end

local STATUS_TEXT = {
    [200] = 'OK',
    [201] = 'Created',
    [202] = 'Accepted',
    [204] = 'No Content',
    [301] = 'Moved Permanently',
    [302] = 'Found',
    [304] = 'Not Modified',
    [400] = 'Bad Request',
    [404] = 'Not Found',
    [405] = 'Method Not Allowed',
    [413] = 'Payload Too Large',
    [500] = 'Internal Server Error',
    [501] = 'Not Implemented',
}

local function clean_header(s)
    return tostring(s or ''):gsub('[\r\n]', ' ')
end

local function normalize_response(req, resp)
    if resp == nil then
        resp = { status = 404, body = 'not found\n' }
    elseif type(resp) == 'string' or type(resp) == 'number' or type(resp) == 'boolean' then
        resp = { status = 200, body = tostring(resp) }
    elseif type(resp) ~= 'table' then
        resp = { status = 500, body = 'invalid response\n' }
    end

    local status = tonumber(resp.status or resp.code or 200) or 200
    local file_path = resp.file or resp.file_path
    local body = resp.body
    if body == nil then body = '' end
    if type(body) ~= 'string' then body = tostring(body) end

    local headers = {}
    if type(resp.headers) == 'table' then
        for k, v in pairs(resp.headers) do
            headers[clean_header(k)] = clean_header(v)
        end
    end

    headers['Server'] = headers['Server'] or server_name
    headers['Connection'] = headers['Connection'] or (req.keep_alive and 'keep-alive' or 'close')

    if file_path then
        local f = io.open(file_path, 'rb')
        if not f then
            status = 404
            body = 'file not found\n'
            file_path = nil
        else
            local size = f:seek('end') or 0
            f:close()
            headers['Content-Length'] = tostring(size)
            if not headers['Content-Type'] then
                headers['Content-Type'] = resp.content_type or 'application/octet-stream'
            end
        end
    end

    if not file_path then
        headers['Content-Length'] = tostring(#body)
        if body ~= '' and not headers['Content-Type'] then
            headers['Content-Type'] = 'text/plain; charset=utf-8'
        end
    end

    return status, body, headers, file_path
end

local function read_file(path)
    local f = io.open(path, 'rb')
    if not f then return nil end
    local data = f:read('*a')
    f:close()
    return data
end

local function send_response(conn, req, resp)
    local status, body, headers, file_path = normalize_response(req, resp)
    local reason = STATUS_TEXT[status] or 'Status'
    local out = { string.format('HTTP/1.1 %d %s\r\n', status, reason) }
    for k, v in pairs(headers) do
        out[#out + 1] = clean_header(k) .. ': ' .. clean_header(v) .. '\r\n'
    end
    out[#out + 1] = '\r\n'
    local header = table.concat(out)

    if file_path and req.method ~= 'HEAD' then
        if type(conn.send_file_response) == 'function' and conn:send_file_response(header, file_path) then
            return
        end
        local data = read_file(file_path)
        if data then
            conn:send_raw(header .. data)
            return
        end
    end

    out = { header }
    if req.method ~= 'HEAD' and not file_path then
        out[#out + 1] = body
    end
    conn:send_raw(table.concat(out))
end

local function send_error(conn, status, message)
    local body = tostring(message or STATUS_TEXT[status] or 'error') .. '\n'
    send_response(conn, {
        method = 'GET',
        keep_alive = false,
    }, {
        status = status,
        body = body,
        headers = { ['Content-Type'] = 'text/plain; charset=utf-8', ['Connection'] = 'close' },
    })
end

local function load_app(path)
    app_script = path
    local loaded = dofile(path)
    if type(loaded) == 'function' then
        app = { handle = loaded }
    elseif type(loaded) == 'table' then
        app = loaded
    else
        error('app script must return a table or function')
    end
end

local function dispatch_request(req)
    if app and type(app.handle) == 'function' then
        return app.handle(req)
    end

    local routes = app and app.routes
    if type(routes) == 'table' then
        local key = req.method .. ' ' .. req.path
        local h = routes[key] or routes[req.path]
        if type(h) == 'function' then
            return h(req)
        end
        if type(h) == 'table' then
            return h
        end
    end

    return { status = 404, body = 'not found\n' }
end

local server_handler = {}

function server_handler.on_connect(conn, ip, port)
    connections[conn] = { ip = ip, port = port }
    conn:set_framing({ type = 'raw', max_packet = max_request_size })
    print(string.format('[XHTTP-WORKER] accepted fd=%s from %s:%s',
        tostring(conn:fd()), tostring(ip), tostring(port)))
end

function server_handler.on_packet(conn, data)
    local state = connections[conn]
    local pos = 1
    local consumed = 0
    local data_len = #data

    while pos <= data_len do
        local req, next_pos, err = parse_one_request(data, pos, state)
        if not req then
            if err == 'incomplete' then
                break
            end
            send_error(conn, err == 'request body too large' and 413 or 400, err)
            return data_len
        end

        local ok, resp = pcall(dispatch_request, req)
        if ok then
            send_response(conn, req, resp)
        else
            io.stderr:write('[XHTTP-WORKER] app error: ' .. tostring(resp) .. '\n')
            send_error(conn, 500, 'internal server error')
        end

        consumed = next_pos - 1
        pos = next_pos
    end

    return consumed
end

function server_handler.on_close(conn, reason)
    connections[conn] = nil
    print('[XHTTP-WORKER] close:', reason)
end

xthread.register('xhttp_worker_start', function(script_path, max_size, name,
                                               https, cert_file, key_file, key_password)
    max_request_size = tonumber(max_size) or max_request_size
    server_name = name or server_name
    use_https = https and true or false
    if use_https then
        tls_config = {
            cert_file = cert_file,
            key_file = key_file,
            password = key_password ~= '' and key_password or nil,
            max_packet = max_request_size,
        }
    else
        tls_config = nil
    end
    load_app(script_path)
    print(string.format('[XHTTP-WORKER] start scheme=%s app=%s max_request=%d',
        use_https and 'https' or 'http', tostring(script_path), max_request_size))
end)

xthread.register('xhttp_accept', function(fd, ip, port)
    local conn, err
    if use_https then
        conn, err = xnet.attach_tls(fd, server_handler, ip, port, tls_config)
    else
        conn, err = xnet.attach(fd, server_handler, ip, port)
    end
    if not conn then
        io.stderr:write('[XHTTP-WORKER] attach failed: ' .. tostring(err) .. '\n')
    end
end)

xthread.register('xhttp_worker_stop', function()
    for conn in pairs(connections) do
        conn:close('xhttp_worker_stop')
    end
end)

local function __init()
    print('[XHTTP-WORKER] init')
    assert(xnet.init())
end

local function __update()
    xnet.poll(10)
end

local function __uninit()
    for conn in pairs(connections) do
        conn:close('worker_uninit')
    end
    connections = {}
    xnet.uninit()
    print('[XHTTP-WORKER] uninit')
end

return {
    __init = __init,
    __update = __update,
    __uninit = __uninit,
    __thread_handle = __thread_handle,
}
