-- xadmin_app.lua - HTTP routes for the xadmin console.
-- All long-running endpoints (peer query, stats, script exec) return an async
-- marker that scripts/xadmin/xadmin_worker.lua completes locally.

local router = dofile('scripts/core/share/xhttp_router.lua')
local xutils = require('xutils')

local STATIC_DIR = xutils.get_config('XADMIN_STATIC_DIR', 'scripts/xadmin/static')
local TOKEN = xutils.get_config('XADMIN_TOKEN', '')

local M = {}

local function plain(status, body, content_type)
    return {
        status = status,
        body = body or '',
        headers = {
            ['Content-Type'] = content_type or 'text/plain; charset=utf-8',
            ['Cache-Control'] = 'no-store',
        },
    }
end

local function json(status, payload)
    local body, err = xutils.json_pack(payload)
    if not body then return plain(500, 'json pack failed: ' .. tostring(err)) end
    return {
        status = status,
        body = body,
        headers = {
            ['Content-Type'] = 'application/json; charset=utf-8',
            ['Cache-Control'] = 'no-store',
        },
    }
end

local function file_response(path, content_type)
    return {
        status = 200,
        file = path,
        headers = {
            ['Content-Type'] = content_type or 'application/octet-stream',
            ['Cache-Control'] = 'no-store',
        },
    }
end

local function header_get(req, name)
    local h = req.headers or {}
    -- xhttp_codec lowercases header names; tolerate both anyway.
    return h[name] or h[name:lower()] or h[name:upper()]
end

local function check_token(req)
    if TOKEN == '' then return true end
    local got = header_get(req, 'X-Xadmin-Token') or header_get(req, 'x-xadmin-token')
    if got == TOKEN then return true end
    return false
end

router.reset({
    file_response = file_response,
    log_prefix = 'XADMIN',
    not_found = function() return plain(404, 'not found\n') end,
})

M.route = router.reg
M.router = router

router.reg_path(STATIC_DIR, { index = 'index.html', index_route = '/' })

-- Peer list (async: worker-local peer cache).
router.reg('get', '/api/peers', function()
    return { async = true, action = 'xadmin_query_peers', args = {} }
end)

-- Runtime thread stats (async: worker-local aggregation).
router.reg('get', '/api/stats', function()
    return { async = true, action = 'xadmin_query_stats', args = {} }
end)

-- Script execution. Body is JSON: { target = "self"|"name", script = "..." }.
router.reg('post', '/api/exec', function(req)
    if not check_token(req) then
        return json(401, { ok = false, error = 'invalid or missing X-Xadmin-Token' })
    end
    local body, perr = xutils.json_unpack(req.body or '')
    if not body or type(body) ~= 'table' then
        return json(400, { ok = false, error = 'invalid json: ' .. tostring(perr or 'expected object') })
    end
    local target = tostring(body.target or 'self')
    local script = tostring(body.script or '')
    if script == '' then
        return json(400, { ok = false, error = 'script is empty' })
    end
    return { async = true, action = 'xadmin_run_script', args = { target, script } }
end)

function M.handle(req)
    return router.handle(req)
end

return M
