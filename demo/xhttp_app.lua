-- xhttp_app.lua - demo HTTP application used by xhttp_main.lua.

local codec = dofile('demo/xhttp_codec.lua')
local router = dofile('demo/xhttp_router.lua')

-- Setup JSON pack/unpack alias using xutils.json if available
-- We expose the interface to use xjson_pack/xjson_unpack in this module.
local xjson_pack, xjson_unpack
do
  local ok, xutils = pcall(require, "xutils")
  if ok and xutils and type(xutils.json) == "table" then
    xjson_pack, xjson_unpack = xutils.json.pack, xutils.json.unpack
  end
end

local M = {}

local function text(status, body, headers)
    headers = headers or {}
    headers['Content-Type'] = headers['Content-Type'] or 'text/plain; charset=utf-8'
    return { status = status, body = body, headers = headers }
end

router.reset({
    not_found = function()
        return text(404, 'not found\n')
    end,
})

M.route = router.reg
M.router = router

router.reg('get', '/hello', function(req)
    local name = req.query.name or 'xnet'
    return text(200, 'hello ' .. tostring(name) .. '\n')
end)

router.reg('post', '/echo', function(req)
    return text(200, req.body)
end)

router.reg('post', '/chunked', function(req)
    return text(200, 'chunked:' .. req.body)
end)

router.reg('post', '/form', function(req)
    local form = codec.form(req)
    return text(200, string.format('form:%s:%s\n',
        tostring(form.name or ''), tostring(form.kind or '')))
end)

router.reg('post', '/json', function(req)
    local data, err
    if xjson_unpack then
        local ok, res = pcall(function() return xjson_unpack(req.body) end)
        if not ok then
            return text(400, tostring(res) .. '\n')
        end
        data = res
    else
        data, err = codec.json(req)
        if not data then
            return text(400, tostring(err) .. '\n')
        end
    end
    -- Use the decoded table (or value) to format the response
    return text(200, string.format('json:%s:%s:%s\n',
        tostring((data and data.pt) or ''), tostring((data and data.arg1) or ''), tostring((data and data.ok) or '')))
end)

router.reg('post', '/multipart', function(req)
    local mp, err = codec.multipart(req)
    if not mp then
        return text(400, tostring(err) .. '\n')
    end
    local upload = mp.files.upload
    return text(200, string.format('multipart:%s:%s:%s\n',
        tostring(mp.fields.name or ''),
        tostring(upload and upload.filename or ''),
        tostring(upload and upload.data or '')))
end)

router.reg('get', '/headers', function(req)
    return text(200, tostring(req.headers['x-demo'] or '') .. '\n')
end)

router.reg('head', '/head', function()
    return text(200, 'head-body-not-sent')
end)

function M.handle(req)
    return router.handle(req)
end

return M
