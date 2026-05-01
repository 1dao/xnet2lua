-- xhttp_router.lua - Lua-state singleton router for xhttp apps.

local ROUTER_KEY = '__xnet_xhttp_router'
local M = rawget(_G, ROUTER_KEY)
if M then return M end

M = {
    routes = {},
    log_prefix = 'XHTTP',
}
rawset(_G, ROUTER_KEY, M)

local CONTENT_TYPES = {
    css = 'text/css; charset=utf-8',
    gif = 'image/gif',
    html = 'text/html; charset=utf-8',
    ico = 'image/x-icon',
    jpg = 'image/jpeg',
    jpeg = 'image/jpeg',
    js = 'application/javascript; charset=utf-8',
    json = 'application/json; charset=utf-8',
    map = 'application/json; charset=utf-8',
    pac = 'application/x-ns-proxy-autoconfig; charset=utf-8',
    png = 'image/png',
    svg = 'image/svg+xml',
    txt = 'text/plain; charset=utf-8',
    webp = 'image/webp',
}

local function lower(s)
    return string.lower(tostring(s or ''))
end

local function normalize_static_rel(rel)
    rel = tostring(rel or ''):gsub('\\', '/'):gsub('^/+', '')
    local parts = {}
    for part in rel:gmatch('[^/]+') do
        if part == '..' or part:find('%z') then
            return nil
        end
        if part ~= '' and part ~= '.' then
            parts[#parts + 1] = part
        end
    end
    if #parts == 0 then return nil end
    return table.concat(parts, '/')
end

local function join_route(prefix, rel)
    prefix = tostring(prefix or ''):gsub('\\', '/')
    rel = tostring(rel or ''):gsub('\\', '/')
    if prefix == '' or prefix == '/' then
        return '/' .. rel:gsub('^/+', '')
    end
    return '/' .. prefix:gsub('^/+', ''):gsub('/+$', '') .. '/' .. rel:gsub('^/+', '')
end

function M.content_type_for(path)
    local ext = tostring(path or ''):match('%.([^.\\/]+)$')
    return CONTENT_TYPES[lower(ext or '')] or 'application/octet-stream'
end

function M.file_response(path, content_type)
    return {
        status = 200,
        file = path,
        headers = {
            ['Content-Type'] = content_type or M.content_type_for(path),
        },
    }
end

local default_file_response = M.file_response

function M.reset(opts)
    opts = opts or {}
    M.routes = {}
    M.not_found = opts.not_found
    M.file_response = opts.file_response or default_file_response
    M.log_prefix = opts.log_prefix or 'XHTTP'
    return M
end

function M.config(opts)
    opts = opts or {}
    if opts.not_found ~= nil then M.not_found = opts.not_found end
    if opts.file_response ~= nil then M.file_response = opts.file_response end
    if opts.log_prefix ~= nil then M.log_prefix = opts.log_prefix end
    return M
end

function M.reg(method, path, handler)
    method = string.upper(tostring(method or ''))
    M.routes[method] = M.routes[method] or {}
    M.routes[method][path] = handler
    return M
end

M.route = M.reg

function M.get(path, handler)
    return M.reg('GET', path, handler)
end

function M.post(path, handler)
    return M.reg('POST', path, handler)
end

function M.head(path, handler)
    return M.reg('HEAD', path, handler)
end

function M.reg_static_file(rel, path, opts)
    opts = opts or {}
    local route_path = join_route(opts.prefix, rel)
    local content_type = opts.content_type or M.content_type_for(path)
    M.get(route_path, function()
        return M.file_response(path, content_type)
    end)
    return M
end

function M.reg_path(root, opts)
    opts = opts or {}
    local files, err = xnet.scan_dir(root)
    if not files then
        io.stderr:write(string.format('[%s] scan static dir failed: %s\n',
            M.log_prefix, tostring(err)))
        return 0
    end

    table.sort(files, function(a, b)
        return tostring(a.rel or '') < tostring(b.rel or '')
    end)

    local count = 0
    local index = opts.index or 'index.html'
    local index_route = opts.index_route or '/'
    for _, item in ipairs(files) do
        local rel = normalize_static_rel(item.rel)
        if rel then
            M.reg_static_file(rel, item.path, opts)
            if rel == index then
                local content_type = M.content_type_for(item.path)
                local index_path = item.path
                M.get(index_route, function()
                    return M.file_response(index_path, content_type)
                end)
            end
            count = count + 1
        end
    end

    print(string.format('[%s] registered %d static files from %s',
        M.log_prefix, count, tostring(root)))
    return count
end

M.static_dir = M.reg_path

function M.handle(self_or_req, maybe_req)
    local req = maybe_req or self_or_req
    local method_routes = M.routes[string.upper(tostring(req.method or ''))]
    local handler = method_routes and method_routes[req.path]
    if handler then
        return handler(req)
    end
    if M.not_found then
        return M.not_found(req)
    end
    return {
        status = 404,
        body = 'not found\n',
        headers = { ['Content-Type'] = 'text/plain; charset=utf-8' },
    }
end

function M.new(opts)
    return M.reset(opts)
end

return M
