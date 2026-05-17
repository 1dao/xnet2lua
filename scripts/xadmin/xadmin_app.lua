-- xadmin_app.lua - HTTP routes for the xadmin console.
--
-- Each fd has one session coroutine managed by xadmin_worker/xsession.
-- That means routes can call yielding APIs (notably xnats.rpc/xthread.rpc) and just
-- `return` the response synchronously; xnats.rpc routes self-targeted calls
-- straight to the local business worker (caller-side short-circuit) and
-- only goes over NATS for cross-process targets.
--
-- xnats.rpc unified return shape (used here):
--   channel_ok = false   → (false, channel_err)
--   channel_ok = true    → (true, app_ok, app_ret1, app_ret2, ...)

local router = dofile('scripts/core/share/xhttp_router.lua')
local xutils = require('xutils')

local STATIC_DIR = xutils.get_config('XADMIN_STATIC_DIR', 'scripts/xadmin/static')
local TOKEN = xutils.get_config('XADMIN_TOKEN', '')

local M = {}

-- Worker-local context populated by xadmin_worker via M.setup. Routes read
-- through this table at call time so that hot-reload of xadmin_worker can
-- refresh the helpers without needing to re-register the routes.
local ctx = {
    self_name      = '',
    token_required = TOKEN ~= '',
    alive_peers    = function() return {} end,
    now_ms         = function() return math.floor(os.time() * 1000) end,
}

function M.setup(c)
    if type(c) ~= 'table' then return end
    for k, v in pairs(c) do ctx[k] = v end
end

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------
local unpack_args = table.unpack or unpack

local function pack_values(...)
    return { n = select('#', ...), ... }
end

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

-- "name" or "name:idx" → "name:idx" (default idx=1).
local function resolve_rpc_target(name)
    name = tostring(name or '')
    if name == '' or name == 'self' then name = ctx.self_name or '' end
    if name == '' then return nil, 'no target' end
    if name:match(':%d+$') then return name end
    return name .. ':1', nil, name
end

-- ---------------------------------------------------------------------------
-- Router setup
-- ---------------------------------------------------------------------------
router.reset({
    file_response = file_response,
    log_prefix = 'XADMIN',
    not_found = function() return plain(404, 'not found\n') end,
})

M.route = router.reg
M.router = router

router.reg_path(STATIC_DIR, { index = 'index.html', index_route = '/' })

-- ---------------------------------------------------------------------------
-- Pure local queries (no yielding RPC)
-- ---------------------------------------------------------------------------
router.reg('get', '/api/peers', function()
    return json(200, {
        self = ctx.self_name or '',
        peers = ctx.alive_peers and ctx.alive_peers() or {},
        token_required = ctx.token_required and true or false,
    })
end)

router.reg('get', '/api/stats', function()
    local threads = xthread.all_stats and xthread.all_stats() or {}
    if type(threads) ~= 'table' then threads = {} end

    local summary = {
        thread_count          = #threads,
        queue_depth_total     = 0,
        queue_max_total       = 0,
        peak_queue_depth      = 0,
        peak_queue_thread_id  = 0,
        peak_queue_thread_name = '',
    }
    for _, st in ipairs(threads) do
        local qd = tonumber(st.queue_depth) or 0
        local qm = tonumber(st.queue_max) or 0
        summary.queue_depth_total = summary.queue_depth_total + qd
        summary.queue_max_total = summary.queue_max_total + qm
        if qd > summary.peak_queue_depth then
            summary.peak_queue_depth = qd
            summary.peak_queue_thread_id = tonumber(st.id) or 0
            summary.peak_queue_thread_name = tostring(st.name or '')
        end
    end

    return json(200, {
        self = ctx.self_name or '',
        at_ms = ctx.now_ms and ctx.now_ms() or math.floor(os.time() * 1000),
        peers = ctx.alive_peers and ctx.alive_peers() or {},
        threads = threads,
        summary = summary,
        token_required = ctx.token_required and true or false,
    })
end)

-- ---------------------------------------------------------------------------
-- Cross-process operations (yields inside xnats.rpc)
-- ---------------------------------------------------------------------------
router.reg('post', '/api/exec', function(req)
    if not check_token(req) then
        return json(401, { ok = false, error = 'invalid or missing X-Xadmin-Token' })
    end
    local body, perr = xutils.json_unpack(req.body or '')
    if not body or type(body) ~= 'table' then
        return json(400, { ok = false, error = 'invalid json: ' .. tostring(perr or 'expected object') })
    end
    local script = tostring(body.script or '')
    if script == '' then
        return json(400, { ok = false, error = 'script is empty' })
    end

    local rpc_target, terr, label = resolve_rpc_target(body.target or 'self')
    if not rpc_target then
        return json(400, { ok = false, error = terr or 'target unresolved' })
    end
    label = label or rpc_target

    -- xnats.rpc → (channel_ok, app_ok, stdout, result) on success;
    --             (false, channel_err) on channel failure.
    local rets = pack_values(xnats.rpc(rpc_target, '@run_script', script))
    local channel_ok = rets[1] and true or false
    if not channel_ok then
        return json(502, {
            ok = false, target = label,
            stdout = '',
            error = 'rpc failed: ' .. tostring(rets[2]),
        })
    end

    local app_ok = rets[2] and true or false
    return json(app_ok and 200 or 500, {
        ok       = app_ok,
        target   = label,
        stdout   = tostring(rets[3] or ''),
        result   = tostring(rets[4] or ''),
    })
end)

router.reg('post', '/api/reload', function(req)
    if not check_token(req) then
        return json(401, { ok = false, error = 'invalid or missing X-Xadmin-Token' })
    end
    local body, perr = xutils.json_unpack(req.body or '')
    if not body or type(body) ~= 'table' then
        return json(400, { ok = false, error = 'invalid json: ' .. tostring(perr or 'expected object') })
    end
    local target = tostring(body.target or 'all')
    if target == '' then target = 'all' end

    -- Build the list of process-name targets.
    local names = {}
    local seen = {}
    local label = target
    if target == 'all' then
        if ctx.self_name and ctx.self_name ~= '' then
            names[#names + 1] = ctx.self_name; seen[ctx.self_name] = true
        end
        for _, p in ipairs(ctx.alive_peers and ctx.alive_peers() or {}) do
            local nm = tostring(p.name or '')
            if nm ~= '' and not seen[nm] then
                names[#names + 1] = nm; seen[nm] = true
            end
        end
    elseif target == 'self' then
        names[1] = ctx.self_name or ''
        label = ctx.self_name or ''
    else
        names[1] = target
    end

    if #names == 0 or names[1] == '' then
        return json(500, {
            ok = false, target = label,
            results = { { target = label, ok = false, result = 'no reload target available' } },
        })
    end

    local self_id = xthread.current_id and xthread.current_id() or 0
    local results = {}
    local all_ok = true

    for _, name in ipairs(names) do
        local rpc_target = name:match(':%d+$') and name or (name .. ':1')
        local rets
        if name == ctx.self_name then
            rets = pack_values(xnats.rpc(rpc_target, '@reload', self_id))
        else
            rets = pack_values(xnats.rpc(rpc_target, '@reload'))
        end

        local channel_ok = rets[1] and true or false
        local ok, msg
        if not channel_ok then
            ok, msg = false, 'rpc error: ' .. tostring(rets[2])
        else
            ok = rets[2] and true or false
            msg = tostring(rets[3] or '')
        end
        if not ok then all_ok = false end
        results[#results + 1] = { target = name, ok = ok, result = msg }
    end

    return json(all_ok and 200 or 500, {
        ok = all_ok, target = label, results = results,
    })
end)

function M.handle(req)
    return router.handle(req)
end

return M
