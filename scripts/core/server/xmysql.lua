-- Business-side MySQL API.
-- MySQL I/O lives in scripts/core/server/xmysql_worker.lua and uses xnet/xchannel raw mode.

local M = {}

local MYSQL_ID = xthread.MYSQL
local DEFAULT_SCRIPT = 'scripts/core/server/xmysql_worker.lua'

local running = false

local unpack_args = table.unpack or unpack

local function normalize_config(cfg)
    cfg = cfg or {}
    return {
        host = cfg.host or '127.0.0.1',
        port = cfg.port or 3306,
        user = cfg.user or 'root',
        password = cfg.password or '',
        database = cfg.database or cfg.db or '',
        pool_size = cfg.pool_size or cfg.pool or 4,
        reconnect_ms = cfg.reconnect_ms or 1000,
        max_packet = cfg.max_packet or cfg.max_reply_size or 64 * 1024 * 1024,
        charset = cfg.charset or 45,
        script_path = cfg.script_path or DEFAULT_SCRIPT,
    }
end

function M.start(cfg)
    if running then
        return true
    end

    local conf = normalize_config(cfg)

    local ok, err = xthread.create_thread(MYSQL_ID, 'xmysql-worker', conf.script_path)
    if not ok then
        return false, err
    end

    running = true
    ok, err = xthread.post(MYSQL_ID, 'xmysql_start',
        conf.host, conf.port, conf.user, conf.password, conf.database,
        conf.pool_size, conf.reconnect_ms, conf.max_packet, conf.charset)
    if not ok then
        running = false
        xthread.shutdown_thread(MYSQL_ID)
        return false, err
    end

    return true
end

-- xthread.rpc yields back three values: (channel_ok, app_ok, result).
--   channel_ok == false -> the RPC itself failed; app_ok holds the reason.
--   channel_ok == true  -> the xmysql_query handler returned (app_ok, result),
--                          where result is the row set / OK-packet table, or an
--                          error string when app_ok is false.
-- Collapse that to the documented (ok, result) so callers don't accidentally
-- read the channel flag as the result (which surfaced as queries returning
-- boolean `true` and "attempt to index a boolean value" downstream).
function M.query(sql)
    local channel_ok, app_ok, result = xthread.rpc(MYSQL_ID, 'xmysql_query', 0, sql)
    if not channel_ok then
        return false, tostring(app_ok or 'mysql rpc failed')
    end
    return app_ok and true or false, result
end

M.call = M.query
M.execute = M.query

function M.post(cb, sql)
    if type(cb) ~= 'function' then
        sql = cb
        cb = nil
    end

    local args = { n = 1, sql }
    local co = coroutine.create(function()
        local ok, value = M.query(unpack_args(args, 1, args.n))
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

-- Re-point the *running* pool at new credentials without tearing down the
-- worker thread. Calling xthread.shutdown_thread on the live MySQL thread
-- corrupts the shared poll state of other threads (they spin on closed fds), so
-- code that changes DB settings at runtime (e.g. the xadmin setup flow) MUST
-- use this rather than stop() + start(). Falls back to start() if not running.
function M.reconfigure(cfg)
    if not running then
        return M.start(cfg)
    end
    local conf = normalize_config(cfg)
    local ok, err = xthread.post(MYSQL_ID, 'xmysql_restart',
        conf.host, conf.port, conf.user, conf.password, conf.database,
        conf.pool_size, conf.reconnect_ms, conf.max_packet, conf.charset)
    if not ok then
        return false, err
    end
    return true
end

function M.stop(silent)
    if not running then
        return true
    end

    xthread.post(MYSQL_ID, 'xmysql_stop', silent and true or false)
    local ok, err = xthread.shutdown_thread(MYSQL_ID)
    running = false
    if not ok then
        return false, err
    end
    return true
end

function M.running()
    return running
end

_G.xmysql = M
return M
