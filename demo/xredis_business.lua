-- Business worker for the Lua xredis demo.
-- Each business thread calls Redis through the shared XTHR_REDIS service thread.

local xredis = dofile('demo/xredis.lua')
local router = dofile('demo/xrouter.lua')
router.set_log_prefix('XREDIS-BIZ')

local MAIN_ID = xthread.MAIN

local function finish(ok, msg)
    xthread.post(MAIN_ID, 'xredis_business_done', xthread.current_id(), ok, msg)
end

-- Surface coroutine-top-level errors as a failed business result so the main
-- thread always gets a `xredis_business_done` POST.
router.set_handler_error(function(_, err) finish(false, tostring(err)) end)

-- Mirror the legacy `xthread.register(pt, h)` API onto router.register so
-- existing handlers below don't change shape.
xthread.register = router.register

local function array_equals(actual, expected)
    if type(actual) ~= 'table' or #actual ~= #expected then
        return false
    end
    for i = 1, #expected do
        if actual[i] ~= expected[i] then
            return false
        end
    end
    return true
end

local function array_contains(actual, value)
    if type(actual) ~= 'table' then
        return false
    end
    for _, item in ipairs(actual) do
        if item == value then
            return true
        end
    end
    return false
end

local function array_to_map(actual)
    local out = {}
    if type(actual) ~= 'table' then
        return out
    end
    for i = 1, #actual, 2 do
        out[actual[i]] = actual[i + 1]
    end
    return out
end

xthread.register('run_redis_test', function(name)
    name = tostring(name or ('biz-' .. tostring(xthread.current_id())))

    print(string.format('[XREDIS-BIZ:%s] start redis test', name))

    local ok, r = xredis.call('PING')
    print(string.format('[XREDIS-BIZ:%s] PING %s %s', name, tostring(ok), tostring(r)))
    if not ok or r ~= 'PONG' then
        finish(false, name .. ' PING failed')
        return
    end

    ok, r = xredis.call('INCR', 'xredis:test:seq')
    print(string.format('[XREDIS-BIZ:%s] INCR seq %s %s', name, tostring(ok), tostring(r)))
    if not ok or type(r) ~= 'number' then
        finish(false, name .. ' INCR seq failed')
        return
    end

    local prefix = string.format('xredis:test:%s:%d', name, r)
    local key_string = prefix .. ':string:strkey'
    local key_counter = prefix .. ':string:counter'
    local key_list = prefix .. ':list:lkey'
    local key_hash = prefix .. ':hash:hkey'
    local key_hash_multi = prefix .. ':hash:hmkey'
    local key_set = prefix .. ':set:setkey'
    local key_zset = prefix .. ':zset:zkey'
    local key_bitmap = prefix .. ':bitmap:bkey'
    local key_hll = prefix .. ':hll:pfkey'
    local key_geo = prefix .. ':geo:gkey'
    local key_stream = prefix .. ':stream:xkey'
    local value = 'hello\r\nfrom ' .. name .. '\r\nseq=' .. tostring(r)

    print(string.format('[XREDIS-BIZ:%s] key prefix: %s', name, prefix))

    ok, r = xredis.call('SET', key_string, value)
    print(string.format('[XREDIS-BIZ:%s] SET %s %s', name, tostring(ok), tostring(r)))
    if not ok or r ~= 'OK' then
        finish(false, name .. ' SET failed')
        return
    end

    ok, r = xredis.call('GET', key_string)
    print(string.format('[XREDIS-BIZ:%s] GET %s %q', name, tostring(ok), tostring(r)))
    if not ok or r ~= value then
        finish(false, name .. ' GET failed')
        return
    end

    ok, r = xredis.call('STRLEN', key_string)
    print(string.format('[XREDIS-BIZ:%s] STRLEN %s %s', name, tostring(ok), tostring(r)))
    if not ok or r ~= #value then
        finish(false, name .. ' STRLEN failed')
        return
    end

    ok, r = xredis.call('INCRBY', key_counter, 7)
    print(string.format('[XREDIS-BIZ:%s] INCRBY %s %s', name, tostring(ok), tostring(r)))
    if not ok or r ~= 7 then
        finish(false, name .. ' INCRBY failed')
        return
    end

    ok, r = xredis.call('INCR', key_counter)
    print(string.format('[XREDIS-BIZ:%s] INCR %s %s', name, tostring(ok), tostring(r)))
    if not ok or r ~= 8 then
        finish(false, name .. ' INCR failed')
        return
    end

    ok, r = xredis.call('RPUSH', key_list, 'alpha', 'beta', 'gamma')
    print(string.format('[XREDIS-BIZ:%s] RPUSH %s %s', name, tostring(ok), tostring(r)))
    if not ok or r ~= 3 then
        finish(false, name .. ' RPUSH failed')
        return
    end

    ok, r = xredis.call('LRANGE', key_list, 0, -1)
    print(string.format('[XREDIS-BIZ:%s] LRANGE %s', name, tostring(ok)))
    if not ok or not array_equals(r, { 'alpha', 'beta', 'gamma' }) then
        finish(false, name .. ' LRANGE failed')
        return
    end

    ok, r = xredis.call('HSET', key_hash, 'payload', value)
    print(string.format('[XREDIS-BIZ:%s] HSET %s %s', name, tostring(ok), tostring(r)))
    if not ok or r ~= 1 then
        finish(false, name .. ' HSET failed')
        return
    end

    ok, r = xredis.call('HGET', key_hash, 'payload')
    print(string.format('[XREDIS-BIZ:%s] HGET %s %q', name, tostring(ok), tostring(r)))
    if not ok or r ~= value then
        finish(false, name .. ' HGET failed')
        return
    end

    ok, r = xredis.call('HSET', key_hash_multi, 'name', name, 'payload', value, 'kind', 'hmkey')
    print(string.format('[XREDIS-BIZ:%s] HSET hmkey %s %s', name, tostring(ok), tostring(r)))
    if not ok or r ~= 3 then
        finish(false, name .. ' HSET hmkey failed')
        return
    end

    ok, r = xredis.call('HMGET', key_hash_multi, 'name', 'payload')
    print(string.format('[XREDIS-BIZ:%s] HMGET %s', name, tostring(ok)))
    if not ok or not array_equals(r, { name, value }) then
        finish(false, name .. ' HMGET failed')
        return
    end

    ok, r = xredis.call('HGETALL', key_hash_multi)
    local hash = array_to_map(r)
    print(string.format('[XREDIS-BIZ:%s] HGETALL %s', name, tostring(ok)))
    if not ok or hash.name ~= name or hash.payload ~= value or hash.kind ~= 'hmkey' then
        finish(false, name .. ' HGETALL failed')
        return
    end

    ok, r = xredis.call('SADD', key_set, 'red', 'green', 'blue')
    print(string.format('[XREDIS-BIZ:%s] SADD %s %s', name, tostring(ok), tostring(r)))
    if not ok or r ~= 3 then
        finish(false, name .. ' SADD failed')
        return
    end

    ok, r = xredis.call('SISMEMBER', key_set, 'green')
    print(string.format('[XREDIS-BIZ:%s] SISMEMBER %s %s', name, tostring(ok), tostring(r)))
    if not ok or r ~= 1 then
        finish(false, name .. ' SISMEMBER failed')
        return
    end

    ok, r = xredis.call('SMEMBERS', key_set)
    print(string.format('[XREDIS-BIZ:%s] SMEMBERS %s', name, tostring(ok)))
    if not ok or not array_contains(r, 'red') or not array_contains(r, 'green') or not array_contains(r, 'blue') then
        finish(false, name .. ' SMEMBERS failed')
        return
    end

    ok, r = xredis.call('ZADD', key_zset, 1, 'one', 2, 'two')
    print(string.format('[XREDIS-BIZ:%s] ZADD %s %s', name, tostring(ok), tostring(r)))
    if not ok or r ~= 2 then
        finish(false, name .. ' ZADD failed')
        return
    end

    ok, r = xredis.call('ZRANGE', key_zset, 0, -1, 'WITHSCORES')
    print(string.format('[XREDIS-BIZ:%s] ZRANGE %s', name, tostring(ok)))
    if not ok or not array_equals(r, { 'one', '1', 'two', '2' }) then
        finish(false, name .. ' ZRANGE failed')
        return
    end

    ok, r = xredis.call('SETBIT', key_bitmap, 7, 1)
    print(string.format('[XREDIS-BIZ:%s] SETBIT %s %s', name, tostring(ok), tostring(r)))
    if not ok or r ~= 0 then
        finish(false, name .. ' SETBIT failed')
        return
    end

    ok, r = xredis.call('GETBIT', key_bitmap, 7)
    print(string.format('[XREDIS-BIZ:%s] GETBIT %s %s', name, tostring(ok), tostring(r)))
    if not ok or r ~= 1 then
        finish(false, name .. ' GETBIT failed')
        return
    end

    ok, r = xredis.call('PFADD', key_hll, 'alice', 'bob', 'alice')
    print(string.format('[XREDIS-BIZ:%s] PFADD %s %s', name, tostring(ok), tostring(r)))
    if not ok or r ~= 1 then
        finish(false, name .. ' PFADD failed')
        return
    end

    ok, r = xredis.call('PFCOUNT', key_hll)
    print(string.format('[XREDIS-BIZ:%s] PFCOUNT %s %s', name, tostring(ok), tostring(r)))
    if not ok or r ~= 2 then
        finish(false, name .. ' PFCOUNT failed')
        return
    end

    ok, r = xredis.call('GEOADD', key_geo,
        116.397128, 39.916527, 'beijing',
        121.473701, 31.230416, 'shanghai')
    print(string.format('[XREDIS-BIZ:%s] GEOADD %s %s', name, tostring(ok), tostring(r)))
    if not ok or r ~= 2 then
        finish(false, name .. ' GEOADD failed')
        return
    end

    ok, r = xredis.call('GEODIST', key_geo, 'beijing', 'shanghai', 'km')
    print(string.format('[XREDIS-BIZ:%s] GEODIST %s %s', name, tostring(ok), tostring(r)))
    if not ok or not tonumber(r) or tonumber(r) <= 1000 then
        finish(false, name .. ' GEODIST failed')
        return
    end

    ok, r = xredis.call('XADD', key_stream, '*', 'type', 'login', 'user', name)
    print(string.format('[XREDIS-BIZ:%s] XADD %s %s', name, tostring(ok), tostring(r)))
    if not ok or type(r) ~= 'string' then
        finish(false, name .. ' XADD failed')
        return
    end

    ok, r = xredis.call('XLEN', key_stream)
    print(string.format('[XREDIS-BIZ:%s] XLEN %s %s', name, tostring(ok), tostring(r)))
    if not ok or r ~= 1 then
        finish(false, name .. ' XLEN failed')
        return
    end

    ok, r = xredis.call('XRANGE', key_stream, '-', '+')
    print(string.format('[XREDIS-BIZ:%s] XRANGE %s', name, tostring(ok)))
    if not ok or type(r) ~= 'table' or not r[1] or type(r[1]) ~= 'table' then
        finish(false, name .. ' XRANGE failed')
        return
    end

    -- Cleanup is intentionally disabled so redis-cli can inspect the keys.
    -- Enable this block manually after verification if you want the test to clean up.
    -- xredis.call('DEL',
    --     key_string, key_counter, key_list, key_hash, key_hash_multi, key_set, key_zset,
    --     key_bitmap, key_hll, key_geo, key_stream)

    local posted, err = xredis.post(function(post_ok, typ)
        print(string.format('[XREDIS-BIZ:%s] POST TYPE %s %s', name, tostring(post_ok), tostring(typ)))
        if post_ok and typ == 'string' then
            finish(true, name .. ' redis ok prefix=' .. prefix)
        else
            finish(false, name .. ' TYPE failed')
        end
    end, 'TYPE', key_string)

    if not posted then
        finish(false, name .. ' post failed: ' .. tostring(err))
    end
end)

local function __init()
    print(string.format('[XREDIS-BIZ:%d] init', xthread.current_id()))
end

local function __update()
end

local function __uninit()
    print(string.format('[XREDIS-BIZ:%d] uninit', xthread.current_id()))
end

return {
    __init = __init,
    __update = __update,
    __uninit = __uninit,
    __thread_handle = router.handle,
}
