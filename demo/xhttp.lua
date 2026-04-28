-- xhttp.lua - HTTP server manager.
-- Main thread owns listen_fd and passes accepted sockets to worker threads.
-- HTTP parsing lives in demo/xhttp_worker.lua.

local M = {}

local DEFAULT_WORKER_SCRIPT = 'demo/xhttp_worker.lua'
local DEFAULT_APP_SCRIPT = 'demo/xhttp_app.lua'

local running = false
local listener = nil
local workers = {}
local rr_index = 0

local function to_bool(v, default)
    if v == nil then return default end
    if v == true or v == 1 or v == '1' or v == 'true' or v == 'yes' or v == 'on' then
        return true
    end
    if v == false or v == 0 or v == '0' or v == 'false' or v == 'no' or v == 'off' then
        return false
    end
    return default
end

local function build_workers(cfg)
    if type(cfg.workers) == 'table' and #cfg.workers > 0 then
        local out = {}
        for i, id in ipairs(cfg.workers) do
            out[i] = tonumber(id)
        end
        return out
    end

    local base = tonumber(cfg.worker_base) or xthread.WORKER_GRP3
    local count = tonumber(cfg.worker_count or cfg.workers or 2) or 2
    if count < 1 then count = 1 end

    local out = {}
    for i = 1, count do
        out[i] = base + i - 1
    end
    return out
end

local function normalize_config(cfg)
    cfg = cfg or {}
    return {
        host = cfg.host or '127.0.0.1',
        port = tonumber(cfg.port) or 18080,
        https = to_bool(cfg.https, false),
        server_name = cfg.server_name or cfg.name or 'xnet-http',
        worker_script = cfg.worker_script or DEFAULT_WORKER_SCRIPT,
        app_script = cfg.app_script or DEFAULT_APP_SCRIPT,
        max_request_size = tonumber(cfg.max_request_size) or 16 * 1024 * 1024,
        workers = build_workers(cfg),
    }
end

local function pick_worker()
    if #workers == 0 then return nil end
    rr_index = (rr_index % #workers) + 1
    return workers[rr_index]
end

local function shutdown_workers()
    for i = #workers, 1, -1 do
        local id = workers[i]
        local ok, err = xthread.shutdown_thread(id)
        if not ok then
            io.stderr:write('[XHTTP] shutdown worker failed: ' .. tostring(id) .. ' ' .. tostring(err) .. '\n')
        end
        workers[i] = nil
    end
end

function M.start(cfg)
    if running then
        return true
    end
    if XNET_WITH_HTTP == false then
        return false, 'xnet was built without HTTP support'
    end

    local conf = normalize_config(cfg)
    if conf.https and XNET_WITH_HTTPS == false then
        return false, 'HTTPS support is not compiled in; rebuild with WITH_HTTPS=1'
    end
    if conf.https then
        return false, 'HTTPS transport is not implemented yet'
    end

    workers = {}
    rr_index = 0

    for i, id in ipairs(conf.workers) do
        local ok, err = xthread.create_thread(id, 'xhttp-worker-' .. tostring(i), conf.worker_script)
        if not ok then
            shutdown_workers()
            return false, err
        end
        workers[#workers + 1] = id

        ok, err = xthread.post(id, 'xhttp_worker_start',
            conf.app_script, conf.max_request_size, conf.server_name)
        if not ok then
            shutdown_workers()
            return false, err
        end
    end

    local l, err = xnet.listen_fd(conf.host, conf.port, {
        on_accept = function(_, fd, ip, port)
            local id = pick_worker()
            if not id then
                io.stderr:write('[XHTTP] no worker for accepted fd\n')
                return false
            end

            local ok, post_err = xthread.post(id, 'xhttp_accept', fd, ip, port)
            if not ok then
                io.stderr:write('[XHTTP] post accepted fd failed: ' .. tostring(post_err) .. '\n')
                return false
            end
            return true
        end,
        on_close = function(_, reason)
            print('[XHTTP] listener closed:', reason)
        end,
    })
    if not l then
        shutdown_workers()
        return false, err
    end

    listener = l
    running = true
    print(string.format('[XHTTP] listening on %s:%d workers=%d', conf.host, conf.port, #workers))
    return true
end

function M.stop()
    if listener then
        listener:close('xhttp_stop')
        listener = nil
    end
    shutdown_workers()
    running = false
    return true
end

function M.running()
    return running
end

function M.worker_ids()
    local out = {}
    for i, id in ipairs(workers) do out[i] = id end
    return out
end

_G.xhttp = M
return M
