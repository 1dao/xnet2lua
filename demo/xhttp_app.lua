-- xhttp_app.lua - demo HTTP application used by xhttp_main.lua.

local M = {}

local function text(status, body, headers)
    headers = headers or {}
    headers['Content-Type'] = headers['Content-Type'] or 'text/plain; charset=utf-8'
    return { status = status, body = body, headers = headers }
end

function M.handle(req)
    if req.path == '/hello' then
        local name = req.query.name or 'xnet'
        return text(200, 'hello ' .. tostring(name) .. '\n')
    end

    if req.path == '/echo' and req.method == 'POST' then
        return text(200, req.body)
    end

    if req.path == '/chunked' and req.method == 'POST' then
        return text(200, 'chunked:' .. req.body)
    end

    if req.path == '/headers' then
        return text(200, tostring(req.headers['x-demo'] or '') .. '\n')
    end

    if req.path == '/head' and req.method == 'HEAD' then
        return text(200, 'head-body-not-sent')
    end

    return text(404, 'not found\n')
end

return M
