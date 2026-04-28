-- Business-side NATS API.
-- NATS I/O lives in demo/xnats_worker.lua and uses xnet/xchannel raw mode.

local M = {}

local NATS_ID = xthread.NATS
local DEFAULT_SCRIPT = 'demo/xnats_worker.lua'

local running = false

local unpack_args = table.unpack or unpack

local function copy_workers(workers)
    local out = {}
    if type(workers) == 'table' then
        for i, id in ipairs(workers) do
            out[i] = tonumber(id)
        end
    end
    return out
end

local function normalize_config(cfg)
    cfg = cfg or {}
    return {
        host = cfg.host or '127.0.0.1',
        port = cfg.port or 4222,
        name = cfg.name or cfg.process_name or 'game1',
        prefix = cfg.prefix or 'xnet',
        broadcast_subject = cfg.broadcast_subject or '',
        worker_threads = copy_workers(cfg.worker_threads or cfg.workers),
        reconnect_ms = cfg.reconnect_ms or 1000,
        rpc_timeout_ms = cfg.rpc_timeout_ms or 5000,
        max_packet = cfg.max_packet or cfg.max_reply_size or 64 * 1024 * 1024,
        script_path = cfg.script_path or DEFAULT_SCRIPT,
    }
end

function M.start(cfg)
    if running then
        return true
    end

    local conf = normalize_config(cfg)
    if not xthread.NATS then
        return false, 'xthread.NATS is not defined'
    end

    local ok, err = xthread.create_thread(NATS_ID, 'xnats-worker', conf.script_path)
    if not ok then
        return false, err
    end

    running = true
    ok, err = xthread.post(NATS_ID, 'xnats_start',
        conf.host, conf.port, conf.name, conf.prefix, conf.broadcast_subject,
        conf.worker_threads, conf.reconnect_ms, conf.rpc_timeout_ms, conf.max_packet)
    if not ok then
        running = false
        xthread.shutdown_thread(NATS_ID)
        return false, err
    end

    return true
end

function M.publish(pt, ...)
    return xthread.rpc(NATS_ID, 'xnats_publish', pt, ...)
end

M.broadcast = M.publish

function M.rpc(target, pt, ...)
    return xthread.rpc(NATS_ID, 'xnats_rpc', target, pt, ...)
end

function M.post(cb, target, pt, ...)
    if type(cb) ~= 'function' then
        target, pt = cb, target
        cb = nil
    end

    local args = { n = select('#', ...) + 2, target, pt, ... }
    local co = coroutine.create(function()
        local ok, value = M.rpc(unpack_args(args, 1, args.n))
        if cb then
            cb(ok, value)
        end
    end)

    local ok, err = coroutine.resume(co)
    if not ok then
        return false, err
    end
    return true
end

function M.stop(silent)
    if not running then
        return true
    end

    xthread.post(NATS_ID, 'xnats_stop', silent and true or false)
    local ok, err = xthread.shutdown_thread(NATS_ID)
    running = false
    if not ok then
        return false, err
    end
    return true
end

function M.running()
    return running
end

_G.xnats = M
return M
