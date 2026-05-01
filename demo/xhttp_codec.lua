-- xhttp_codec.lua - HTTP/1.x parsing helpers shared by demos and workers.

local M = {}

-- ============================================================================
-- Status and Basic Helpers
-- ============================================================================

M.STATUS_TEXT = {
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

function M.trim(s)
    return tostring(s or ''):gsub('^%s+', ''):gsub('%s+$', '')
end

function M.lower(s)
    return string.lower(tostring(s or ''))
end

function M.clean_header(s)
    return tostring(s or ''):gsub('[\r\n]', ' ')
end

local function add_named_value(t, name, value)
    if not name or name == '' then return end
    local old = t[name]
    if old == nil then
        t[name] = value
    elseif type(old) == 'table' and old._multi == true then
        old[#old + 1] = value
    else
        t[name] = { old, value, _multi = true }
    end
end

function M.uri_decode(s)
    s = tostring(s or ''):gsub('+', ' ')
    return (s:gsub('%%(%x%x)', function(hex)
        return string.char(tonumber(hex, 16))
    end))
end

function M.parse_query(qs)
    local out = {}
    if not qs or qs == '' then return out end
    for part in string.gmatch(qs, '([^&]+)') do
        local eq = part:find('=', 1, true)
        local k, v
        if eq then
            k = M.uri_decode(part:sub(1, eq - 1))
            v = M.uri_decode(part:sub(eq + 1))
        else
            k = M.uri_decode(part)
            v = true
        end
        out[k] = v
    end
    return out
end

function M.parse_content_type(value)
    local s = tostring(value or '')
    local first, rest = s:match('^%s*([^;]*)%s*(.*)$')
    local mime = M.lower(M.trim(first or ''))
    local params = {}

    rest = rest or ''
    while rest ~= '' do
        rest = rest:gsub('^%s*;%s*', '')
        if rest == '' then break end

        local key, value_part, next_rest
        key, value_part, next_rest = rest:match('^([^=;%s]+)%s*=%s*"([^"]*)"%s*(.*)$')
        if not key then
            key, value_part, next_rest = rest:match('^([^=;%s]+)%s*=%s*([^;]*)%s*(.*)$')
        end
        if not key then break end
        params[M.lower(M.trim(key))] = M.trim(value_part or '')
        rest = next_rest or ''
    end

    return mime, params
end

function M.split_lines(s)
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

function M.parse_target(target)
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
    return path, query_string, M.parse_query(query_string)
end

function M.parse_chunked(data, pos)
    local chunks = {}
    local len = #data

    while true do
        local line_end = data:find('\r\n', pos, true)
        if not line_end then return nil, nil, 'incomplete' end

        local size_line = M.trim(data:sub(pos, line_end - 1))
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

-- ============================================================================
-- HTTP Message Parsers
-- ============================================================================

function M.parse_request(data, start_pos, opts)
    opts = opts or {}
    start_pos = start_pos or 1
    local max_request_size = opts.max_request_size or (16 * 1024 * 1024)
    local state = opts.state

    local header_end = data:find('\r\n\r\n', start_pos, true)
    if not header_end then
        if #data - start_pos + 1 > max_request_size then
            return nil, nil, 'request too large'
        end
        return nil, nil, 'incomplete'
    end

    local header_block = data:sub(start_pos, header_end - 1)
    local lines = M.split_lines(header_block)
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
            local name = M.lower(M.trim(line:sub(1, colon - 1)))
            local value = M.trim(line:sub(colon + 1))
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
    local transfer_encoding = M.lower(headers['transfer-encoding'])
    if transfer_encoding:find('chunked', 1, true) then
        local chunk_body, chunk_next, chunk_err = M.parse_chunked(data, body_start)
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

    local path, query_string, query = M.parse_target(target)
    local connection = M.lower(headers['connection'])
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

function M.parse_response(data, pos, opts)
    opts = opts or {}
    pos = pos or 1

    local header_end = data:find('\r\n\r\n', pos, true)
    if not header_end then return nil, nil, 'incomplete' end

    local lines = M.split_lines(data:sub(pos, header_end - 1))
    local version, status = (lines[1] or ''):match('^(HTTP/%d%.%d)%s+(%d%d%d)')
    status = tonumber(status)
    if not version or not status then
        return nil, nil, 'bad response line'
    end

    local headers = {}
    local header_list = {}
    for i = 2, #lines do
        local line = lines[i]
        local colon = line:find(':', 1, true)
        if colon then
            local name = M.lower(M.trim(line:sub(1, colon - 1)))
            local value = M.trim(line:sub(colon + 1))
            header_list[#header_list + 1] = { name = name, value = value }
            if headers[name] then
                headers[name] = headers[name] .. ', ' .. value
            else
                headers[name] = value
            end
        end
    end

    local body_start = header_end + 4
    local body_len = tonumber(headers['content-length'] or '0') or 0
    if opts.method == 'HEAD' then body_len = 0 end
    if body_len < 0 then return nil, nil, 'bad content length' end
    if #data < body_start + body_len - 1 then
        return nil, nil, 'incomplete'
    end

    local body = body_len > 0 and data:sub(body_start, body_start + body_len - 1) or ''
    return {
        version = version,
        status = status,
        headers = headers,
        header_list = header_list,
        body = body,
    }, body_start + body_len
end

-- ============================================================================
-- Body Decoders
-- ============================================================================

function M.form(req)
    local body = type(req) == 'table' and req.body or req
    return M.parse_query(tostring(body or ''))
end

local JSON_NULL = {}
M.JSON_NULL = JSON_NULL

local function json_error(pos, msg)
    return nil, string.format('json parse error at %d: %s', pos, msg)
end

local function json_skip_ws(s, pos)
    while true do
        local ch = s:sub(pos, pos)
        if ch ~= ' ' and ch ~= '\t' and ch ~= '\r' and ch ~= '\n' then
            return pos
        end
        pos = pos + 1
    end
end

local function json_parse_string(s, pos)
    pos = pos + 1
    local out = {}
    while pos <= #s do
        local ch = s:sub(pos, pos)
        if ch == '"' then
            return table.concat(out), pos + 1
        end
        if ch == '\\' then
            local esc = s:sub(pos + 1, pos + 1)
            if esc == '"' or esc == '\\' or esc == '/' then
                out[#out + 1] = esc
                pos = pos + 2
            elseif esc == 'b' then
                out[#out + 1] = '\b'
                pos = pos + 2
            elseif esc == 'f' then
                out[#out + 1] = '\f'
                pos = pos + 2
            elseif esc == 'n' then
                out[#out + 1] = '\n'
                pos = pos + 2
            elseif esc == 'r' then
                out[#out + 1] = '\r'
                pos = pos + 2
            elseif esc == 't' then
                out[#out + 1] = '\t'
                pos = pos + 2
            elseif esc == 'u' then
                local hex = s:sub(pos + 2, pos + 5)
                local code = tonumber(hex, 16)
                if not code then return json_error(pos, 'bad unicode escape') end
                if code < 128 then
                    out[#out + 1] = string.char(code)
                elseif utf8 and utf8.char then
                    out[#out + 1] = utf8.char(code)
                else
                    out[#out + 1] = '?'
                end
                pos = pos + 6
            else
                return json_error(pos, 'bad escape')
            end
        else
            out[#out + 1] = ch
            pos = pos + 1
        end
    end
    return json_error(pos, 'unterminated string')
end

local json_parse_value

local function json_parse_array(s, pos)
    local out = {}
    pos = json_skip_ws(s, pos + 1)
    if s:sub(pos, pos) == ']' then return out, pos + 1 end

    while true do
        local value
        value, pos = json_parse_value(s, pos)
        if pos == nil then return nil, value end
        out[#out + 1] = value

        pos = json_skip_ws(s, pos)
        local ch = s:sub(pos, pos)
        if ch == ']' then return out, pos + 1 end
        if ch ~= ',' then return json_error(pos, 'expected array comma or close') end
        pos = json_skip_ws(s, pos + 1)
    end
end

local function json_parse_object(s, pos)
    local out = {}
    pos = json_skip_ws(s, pos + 1)
    if s:sub(pos, pos) == '}' then return out, pos + 1 end

    while true do
        if s:sub(pos, pos) ~= '"' then
            return json_error(pos, 'expected object key')
        end
        local key
        key, pos = json_parse_string(s, pos)
        if pos == nil then return nil, key end

        pos = json_skip_ws(s, pos)
        if s:sub(pos, pos) ~= ':' then
            return json_error(pos, 'expected object colon')
        end

        local value
        value, pos = json_parse_value(s, json_skip_ws(s, pos + 1))
        if pos == nil then return nil, value end
        out[key] = value

        pos = json_skip_ws(s, pos)
        local ch = s:sub(pos, pos)
        if ch == '}' then return out, pos + 1 end
        if ch ~= ',' then return json_error(pos, 'expected object comma or close') end
        pos = json_skip_ws(s, pos + 1)
    end
end

local function json_parse_number(s, pos)
    local e = pos
    while s:sub(e, e):match('[%+%-%d%.eE]') do
        e = e + 1
    end
    local raw = s:sub(pos, e - 1)
    local n = tonumber(raw)
    if not n then return json_error(pos, 'bad number') end
    return n, e
end

function json_parse_value(s, pos)
    pos = json_skip_ws(s, pos)
    local ch = s:sub(pos, pos)
    if ch == '"' then return json_parse_string(s, pos) end
    if ch == '{' then return json_parse_object(s, pos) end
    if ch == '[' then return json_parse_array(s, pos) end
    if ch == '-' or ch:match('%d') then return json_parse_number(s, pos) end
    if s:sub(pos, pos + 3) == 'true' then return true, pos + 4 end
    if s:sub(pos, pos + 4) == 'false' then return false, pos + 5 end
    if s:sub(pos, pos + 3) == 'null' then return JSON_NULL, pos + 4 end
    return json_error(pos, 'unexpected token')
end

function M.json(req)
    local body = type(req) == 'table' and req.body or req
    local s = tostring(body or '')
    local value, pos = json_parse_value(s, 1)
    if pos == nil then return nil, value end
    pos = json_skip_ws(s, pos)
    if pos <= #s then
        return nil, string.format('json parse error at %d: trailing data', pos)
    end
    return value
end

local function parse_header_block(block)
    local headers = {}
    local header_list = {}
    for _, line in ipairs(M.split_lines(block or '')) do
        local colon = line:find(':', 1, true)
        if colon then
            local name = M.lower(M.trim(line:sub(1, colon - 1)))
            local value = M.trim(line:sub(colon + 1))
            header_list[#header_list + 1] = { name = name, value = value }
            if headers[name] then
                headers[name] = headers[name] .. ', ' .. value
            else
                headers[name] = value
            end
        end
    end
    return headers, header_list
end

local function parse_disposition(value)
    local kind, params = M.parse_content_type(value)
    return kind, params
end

function M.multipart(req)
    local body = type(req) == 'table' and req.body or ''
    local headers = type(req) == 'table' and req.headers or {}
    local mime, params = M.parse_content_type(headers['content-type'] or '')
    if mime ~= 'multipart/form-data' then
        return nil, 'content-type is not multipart/form-data'
    end
    local boundary = params.boundary
    if not boundary or boundary == '' then
        return nil, 'missing multipart boundary'
    end

    local marker = '--' .. boundary
    local pos = body:find(marker, 1, true)
    if not pos then return nil, 'multipart boundary not found' end
    pos = pos + #marker

    local out = { fields = {}, files = {}, parts = {} }
    while pos <= #body do
        local trailer = body:sub(pos, pos + 1)
        if trailer == '--' then
            return out
        end
        if trailer ~= '\r\n' then
            return nil, 'bad multipart boundary'
        end
        pos = pos + 2

        local header_end = body:find('\r\n\r\n', pos, true)
        if not header_end then return nil, 'incomplete multipart header' end

        local part_headers, part_header_list = parse_header_block(body:sub(pos, header_end - 1))
        local data_start = header_end + 4
        local next_boundary = body:find('\r\n' .. marker, data_start, true)
        if not next_boundary then return nil, 'multipart closing boundary not found' end

        local data = body:sub(data_start, next_boundary - 1)
        local _, disp_params = parse_disposition(part_headers['content-disposition'] or '')
        local name = disp_params.name
        local filename = disp_params.filename
        local part = {
            headers = part_headers,
            header_list = part_header_list,
            name = name,
            filename = filename,
            content_type = part_headers['content-type'],
            data = data,
            size = #data,
        }

        out.parts[#out.parts + 1] = part
        if filename and filename ~= '' then
            add_named_value(out.files, name, part)
        else
            add_named_value(out.fields, name, data)
        end

        pos = next_boundary + 2 + #marker
    end

    return nil, 'unterminated multipart body'
end

-- ============================================================================
-- Response Normalization and Sending
-- ============================================================================

local function read_file(path)
    local f = io.open(path, 'rb')
    if not f then return nil end
    local data = f:read('*a')
    f:close()
    return data
end

function M.normalize_response(req, resp, opts)
    opts = opts or {}
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
            headers[M.clean_header(k)] = M.clean_header(v)
        end
    end

    headers['Server'] = headers['Server'] or opts.server_name or 'xnet-http'
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

function M.send_response(conn, req, resp, opts)
    local status, body, headers, file_path = M.normalize_response(req, resp, opts)
    local reason = M.STATUS_TEXT[status] or 'Status'
    local out = { string.format('HTTP/1.1 %d %s\r\n', status, reason) }
    for k, v in pairs(headers) do
        out[#out + 1] = M.clean_header(k) .. ': ' .. M.clean_header(v) .. '\r\n'
    end
    out[#out + 1] = '\r\n'
    local header = table.concat(out)

    if file_path and req.method ~= 'HEAD' then
        if type(conn.send_file_response) == 'function' and conn:send_file_response(header, file_path) then
            return true
        end
        local data = read_file(file_path)
        if data then
            conn:send_raw(header .. data)
            return true
        end
    end

    out = { header }
    if req.method ~= 'HEAD' and not file_path then
        out[#out + 1] = body
    end
    conn:send_raw(table.concat(out))
    return true
end

function M.send_error(conn, status, message, opts)
    local body = tostring(message or M.STATUS_TEXT[status] or 'error') .. '\n'
    return M.send_response(conn, {
        method = 'GET',
        keep_alive = false,
    }, {
        status = status,
        body = body,
        headers = {
            ['Content-Type'] = 'text/plain; charset=utf-8',
            ['Connection'] = 'close',
        },
    }, opts)
end

return M
