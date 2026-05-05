-- Business-side MySQL API.
-- MySQL I/O lives in demo/xmysql_worker.lua and uses xnet/xchannel raw mode.

local M = {}

local MYSQL_ID = xthread.MYSQL
local DEFAULT_SCRIPT = 'demo/xmysql_worker.lua'

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

function M.query(sql)
    return xthread.rpc(MYSQL_ID, 'xmysql_query', 0, sql)
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
