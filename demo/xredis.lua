-- Business-side Redis API.
-- Redis I/O lives in demo/xredis_worker.lua and uses xnet/xchannel raw mode.

local M = {}

local REDIS_ID = xthread.REDIS
local DEFAULT_SCRIPT = 'demo/xredis_worker.lua'

local running = false

local unpack_args = table.unpack or unpack

local function normalize_config(cfg)
    cfg = cfg or {}
    return {
        host = cfg.host or '127.0.0.1',
        port = cfg.port or 6379,
        db = cfg.db or 0,
        pool_size = cfg.pool_size or cfg.pool or 4,
        reconnect_ms = cfg.reconnect_ms or 1000,
        max_packet = cfg.max_packet or cfg.max_reply_size or 64 * 1024 * 1024,
        script_path = cfg.script_path or DEFAULT_SCRIPT,
    }
end

function M.start(cfg)
    if running then
        return true
    end

    local conf = normalize_config(cfg)

    local ok, err = xthread.create_thread(REDIS_ID, 'xredis-worker', conf.script_path)
    if not ok then
        return false, err
    end

    running = true
    ok, err = xthread.post(REDIS_ID, 'xredis_start',
        conf.host, conf.port, conf.db, conf.pool_size, conf.reconnect_ms, conf.max_packet)
    if not ok then
        running = false
        xthread.shutdown_thread(REDIS_ID)
        return false, err
    end

    return true
end

function M.call(cmd, ...)
    return xthread.rpc(REDIS_ID, 'xredis_call', cmd, ...)
end

function M.post(cb, cmd, ...)
    if type(cb) ~= 'function' then
        cmd = cb
        cb = nil
    end

    local args = { n = select('#', ...) + 1, cmd, ... }
    local co = coroutine.create(function()
        local ok, value = M.call(unpack_args(args, 1, args.n))
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

function M.stop()
    if not running then
        return true
    end

    xthread.post(REDIS_ID, 'xredis_stop')
    local ok, err = xthread.shutdown_thread(REDIS_ID)
    running = false
    if not ok then
        return false, err
    end
    return true
end

function M.running()
    return running
end

_G.xredis = M
return M
