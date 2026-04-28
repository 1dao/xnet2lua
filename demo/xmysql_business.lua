-- Business worker for the Lua xmysql demo.
-- Each business thread calls MySQL through the shared XTHR_MYSQL service thread.

local xmysql = dofile('demo/xmysql.lua')

local MAIN_ID = xthread.MAIN

_stubs = {}
_thread_replys = {}

local unpack_args = table.unpack or unpack

function xthread.register(pt, h)
    _stubs[pt] = h
end

local function __thread_handle(reply_router, k1, k2, k3, ...)
    if reply_router then
        io.stderr:write('[XMYSQL-BIZ] unexpected RPC message: ' .. tostring(k3) .. '\n')
        return
    end

    local h = _stubs[k1]
    if not h then
        if k1 then
            io.stderr:write('[XMYSQL-BIZ] no handler for pt=' .. tostring(k1) .. '\n')
        end
        return
    end

    local args = { n = select('#', ...) + 2, k2, k3, ... }
    local co = coroutine.create(function()
        h(unpack_args(args, 1, args.n))
    end)
    local ok, err = coroutine.resume(co)
    if not ok then
        xthread.post(MAIN_ID, 'xmysql_business_done', xthread.current_id(), false, tostring(err))
    end
end

local function finish(ok, msg)
    xthread.post(MAIN_ID, 'xmysql_business_done', xthread.current_id(), ok, msg)
end

local function first_row(result)
    return result and result.rows and result.rows[1]
end

local function sql_quote(value)
    value = tostring(value or '')
    value = string.gsub(value, '\\', '\\\\')
    value = string.gsub(value, '\0', '\\0')
    value = string.gsub(value, '\n', '\\n')
    value = string.gsub(value, '\r', '\\r')
    value = string.gsub(value, "'", "\\'")
    value = string.gsub(value, '"', '\\"')
    value = string.gsub(value, '\26', '\\Z')
    return "'" .. value .. "'"
end

local function run_query(name, label, sql)
    local ok, result = xmysql.query(sql)
    print(string.format('[XMYSQL-BIZ:%s] %s %s', name, label, tostring(ok)))
    if not ok then
        return false, label .. ' failed: ' .. tostring(result)
    end
    return true, result
end

local function run_crud_test(name)
    local db = 'xnet_lua_test'
    local table_name = '`' .. db .. '`.`xmysql_crud_test`'
    local qname = sql_quote(name)

    local ok, r = run_query(name, 'CREATE DATABASE',
        'CREATE DATABASE IF NOT EXISTS `' .. db .. '` DEFAULT CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci')
    if not ok then return false, r end

    ok, r = run_query(name, 'CREATE TABLE',
        'CREATE TABLE IF NOT EXISTS ' .. table_name .. ' (' ..
        'id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT PRIMARY KEY,' ..
        'biz VARCHAR(64) NOT NULL,' ..
        'item VARCHAR(64) NOT NULL,' ..
        'value_text VARCHAR(255) NOT NULL,' ..
        'score INT NOT NULL DEFAULT 0,' ..
        'created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,' ..
        'updated_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,' ..
        'UNIQUE KEY uk_biz_item (biz, item)' ..
        ') ENGINE=InnoDB DEFAULT CHARSET=utf8mb4')
    if not ok then return false, r end

    ok, r = run_query(name, 'CLEAN OLD ROWS',
        'DELETE FROM ' .. table_name .. ' WHERE biz = ' .. qname)
    if not ok then return false, r end

    ok, r = run_query(name, 'INSERT ROW 1',
        'INSERT INTO ' .. table_name .. ' (biz, item, value_text, score) VALUES (' ..
        qname .. ", 'insert-key-1', 'insert-value-1', 10)")
    if not ok or not r.ok or tonumber(r.affected_rows or 0) ~= 1 then
        return false, 'INSERT ROW 1 affected_rows failed'
    end

    ok, r = run_query(name, 'INSERT ROW 2',
        'INSERT INTO ' .. table_name .. ' (biz, item, value_text, score) VALUES (' ..
        qname .. ", 'insert-key-2', 'insert-value-2', 20)")
    if not ok or not r.ok or tonumber(r.affected_rows or 0) ~= 1 then
        return false, 'INSERT ROW 2 affected_rows failed'
    end

    ok, r = run_query(name, 'SELECT AFTER INSERT',
        'SELECT COUNT(*) AS cnt, SUM(score) AS total_score FROM ' .. table_name ..
        ' WHERE biz = ' .. qname)
    local row = first_row(r)
    if not ok or not row or row.cnt ~= '2' or row.total_score ~= '30' then
        return false, 'SELECT AFTER INSERT failed'
    end

    ok, r = run_query(name, 'UPDATE ROW',
        'UPDATE ' .. table_name .. " SET value_text = 'updated-value', score = score + 5 " ..
        'WHERE biz = ' .. qname .. " AND item = 'insert-key-1'")
    if not ok or not r.ok or tonumber(r.affected_rows or 0) ~= 1 then
        return false, 'UPDATE ROW affected_rows failed'
    end

    ok, r = run_query(name, 'SELECT AFTER UPDATE',
        'SELECT value_text, score FROM ' .. table_name ..
        ' WHERE biz = ' .. qname .. " AND item = 'insert-key-1'")
    row = first_row(r)
    if not ok or not row or row.value_text ~= 'updated-value' or row.score ~= '15' then
        return false, 'SELECT AFTER UPDATE failed'
    end

    ok, r = run_query(name, 'DELETE ROW',
        'DELETE FROM ' .. table_name ..
        ' WHERE biz = ' .. qname .. " AND item = 'insert-key-2'")
    if not ok or not r.ok or tonumber(r.affected_rows or 0) ~= 1 then
        return false, 'DELETE ROW affected_rows failed'
    end

    ok, r = run_query(name, 'SELECT AFTER DELETE',
        'SELECT COUNT(*) AS cnt FROM ' .. table_name .. ' WHERE biz = ' .. qname)
    row = first_row(r)
    if not ok or not row or row.cnt ~= '1' then
        return false, 'SELECT AFTER DELETE failed'
    end

    return true
end

xthread.register('run_mysql_test', function(name)
    name = tostring(name or ('biz-' .. tostring(xthread.current_id())))
    print(string.format('[XMYSQL-BIZ:%s] start mysql test', name))

    local ok, r = xmysql.query("SELECT 1 AS one, 'hello' AS word")
    print(string.format('[XMYSQL-BIZ:%s] SELECT constants %s', name, tostring(ok)))
    local row = first_row(r)
    if not ok or not row or row.one ~= '1' or row.word ~= 'hello' then
        finish(false, name .. ' SELECT constants failed')
        return
    end

    ok, r = xmysql.query("SELECT 1 AS id, 'alice' AS name UNION ALL SELECT 2, 'bob'")
    print(string.format('[XMYSQL-BIZ:%s] SELECT union %s', name, tostring(ok)))
    if not ok or not r.rows or #r.rows ~= 2 or r.rows[1].id ~= '1' or r.rows[2].name ~= 'bob' then
        finish(false, name .. ' SELECT union failed')
        return
    end

    ok, r = xmysql.query("SELECT CONCAT('line', CHAR(13,10), 'body') AS payload")
    print(string.format('[XMYSQL-BIZ:%s] SELECT crlf %s', name, tostring(ok)))
    row = first_row(r)
    if not ok or not row or row.payload ~= 'line\r\nbody' then
        finish(false, name .. ' SELECT crlf failed')
        return
    end

    ok, r = xmysql.query('SELECT CONNECTION_ID() AS cid')
    print(string.format('[XMYSQL-BIZ:%s] SELECT connection_id %s', name, tostring(ok)))
    row = first_row(r)
    if not ok or not row or not tonumber(row.cid) then
        finish(false, name .. ' SELECT connection_id failed')
        return
    end

    local crud_ok, crud_err = run_crud_test(name)
    if not crud_ok then
        finish(false, name .. ' CRUD failed: ' .. tostring(crud_err))
        return
    end

    local posted, err = xmysql.post(function(post_ok, result)
        local post_row = first_row(result)
        print(string.format('[XMYSQL-BIZ:%s] POST SELECT %s', name, tostring(post_ok)))
        if post_ok and post_row and post_row.msg == 'post-ok' then
            finish(true, name .. ' mysql ok')
        else
            finish(false, name .. ' POST SELECT failed')
        end
    end, "SELECT 'post-ok' AS msg")

    if not posted then
        finish(false, name .. ' post failed: ' .. tostring(err))
    end
end)

local function __init()
    print(string.format('[XMYSQL-BIZ:%d] init', xthread.current_id()))
end

local function __update()
end

local function __uninit()
    print(string.format('[XMYSQL-BIZ:%d] uninit', xthread.current_id()))
end

return {
    __init = __init,
    __update = __update,
    __uninit = __uninit,
    __thread_handle = __thread_handle,
}
