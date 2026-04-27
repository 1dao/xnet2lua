-- Redis worker thread.
-- Uses xnet/xchannel raw mode so RESP bulk strings remain binary-safe.

local unpack_args = table.unpack or unpack

local config = {
    host = '127.0.0.1',
    port = 6379,
    db = 0,
    pool_size = 4,
    reconnect_ms = 1000,
    max_packet = 64 * 1024 * 1024,
}

local conns = {}
local waitq = {}
local rr = 1
local stopping = false
local rpc_context = {}

_stubs = {}
_thread_replys = {}

function xthread.register(pt, h)
    _stubs[pt] = h
end

local function pack_values(...)
    return { n = select('#', ...), ... }
end

local function resume_rpc(req, ...)
    local results = pack_values(coroutine.resume(req.co, ...))
    local resumed = results[1]
    if not resumed then
        rpc_context[req.co] = nil
        req.reply(req.co_id, req.sk, req.pt, false, results[2])
        return
    end

    if coroutine.status(req.co) == 'dead' then
        rpc_context[req.co] = nil
        req.reply(req.co_id, req.sk, req.pt, unpack_args(results, 2, results.n))
    end
end

local function fail_request(req, err)
    if req then
        if req.internal then
            req.internal(false, err)
        else
            resume_rpc(req, false, err)
        end
    end
end

local function find_crlf(data, pos)
    return string.find(data, '\r\n', pos, true)
end

local function parse_line(data, pos)
    local p = find_crlf(data, pos)
    if not p then
        return nil, pos, true
    end
    return string.sub(data, pos, p - 1), p + 2, false
end

local function parse_resp(data, pos, depth)
    depth = depth or 0
    if depth > 64 then
        return nil, pos, false, 'RESP nesting too deep'
    end
    if pos > #data then
        return nil, pos, true
    end

    local prefix = string.sub(data, pos, pos)
    pos = pos + 1

    if prefix == '+' then
        local line, next_pos, incomplete = parse_line(data, pos)
        if incomplete then return nil, pos - 1, true end
        return { kind = 'string', value = line }, next_pos, false
    end

    if prefix == '-' then
        local line, next_pos, incomplete = parse_line(data, pos)
        if incomplete then return nil, pos - 1, true end
        return { kind = 'error', value = line }, next_pos, false
    end

    if prefix == ':' then
        local line, next_pos, incomplete = parse_line(data, pos)
        if incomplete then return nil, pos - 1, true end
        local n = tonumber(line)
        if not n then
            return nil, pos - 1, false, 'bad RESP integer'
        end
        return { kind = 'integer', value = n }, next_pos, false
    end

    if prefix == '$' then
        local line, next_pos, incomplete = parse_line(data, pos)
        if incomplete then return nil, pos - 1, true end
        local len = tonumber(line)
        if not len or len < -1 then
            return nil, pos - 1, false, 'bad RESP bulk length'
        end
        if len == -1 then
            return { kind = 'nil' }, next_pos, false
        end

        local bulk_start = next_pos
        local bulk_end = bulk_start + len - 1
        local after = bulk_end + 3
        if after - 1 > #data then
            return nil, pos - 1, true
        end
        if string.sub(data, bulk_end + 1, bulk_end + 2) ~= '\r\n' then
            return nil, pos - 1, false, 'bad RESP bulk terminator'
        end
        return {
            kind = 'string',
            value = string.sub(data, bulk_start, bulk_end),
        }, after, false
    end

    if prefix == '*' then
        local line, next_pos, incomplete = parse_line(data, pos)
        if incomplete then return nil, pos - 1, true end
        local count = tonumber(line)
        if not count or count < -1 then
            return nil, pos - 1, false, 'bad RESP array length'
        end
        if count == -1 then
            return { kind = 'nil' }, next_pos, false
        end

        local arr = {}
        pos = next_pos
        for i = 1, count do
            local item, item_next, item_incomplete, item_err = parse_resp(data, pos, depth + 1)
            if item_incomplete or item_err then
                return nil, pos, item_incomplete, item_err
            end
            arr[i] = item
            pos = item_next
        end
        return { kind = 'array', value = arr }, pos, false
    end

    return nil, pos - 1, false, 'unknown RESP prefix: ' .. tostring(prefix)
end

local function reply_to_lua(reply)
    if not reply or reply.kind == 'nil' then
        return nil
    end
    if reply.kind == 'array' then
        local out = {}
        for i, item in ipairs(reply.value) do
            if item.kind == 'error' then
                out[i] = { err = item.value }
            else
                out[i] = reply_to_lua(item)
            end
        end
        return out
    end
    return reply.value
end

local function command_arg(v)
    local t = type(v)
    if t == 'string' then return v end
    if t == 'number' or t == 'boolean' then return tostring(v) end
    return tostring(v)
end

local function pack_command(args)
    local parts = { '*' .. args.n .. '\r\n' }
    for i = 1, args.n do
        local s = command_arg(args[i])
        parts[#parts + 1] = '$' .. #s .. '\r\n'
        parts[#parts + 1] = s
        parts[#parts + 1] = '\r\n'
    end
    return table.concat(parts)
end

local function choose_conn()
    if #conns == 0 then return nil end
    for i = 1, #conns do
        local idx = ((rr + i - 2) % #conns) + 1
        local c = conns[idx]
        if c.connected and c.ready and c.conn and not c.closed then
            rr = (idx % #conns) + 1
            return c
        end
    end
    return nil
end

local function send_on_conn(c, req)
    c.pending[#c.pending + 1] = req
    local ok = c.conn and c.conn:send_raw(req.packet)
    if not ok then
        table.remove(c.pending)
        fail_request(req, 'redis send failed')
        return false
    end
    return true
end

local function send_internal(c, args, cb)
    local req = {
        internal = cb,
        args = args,
        packet = pack_command(args),
    }
    return send_on_conn(c, req)
end

local flush_waiting

local function enqueue(req)
    req.packet = pack_command(req.args)
    local c = choose_conn()
    if not c then
        waitq[#waitq + 1] = req
        return true
    end
    return send_on_conn(c, req)
end

flush_waiting = function()
    while #waitq > 0 do
        local c = choose_conn()
        if not c then return end
        local req = table.remove(waitq, 1)
        send_on_conn(c, req)
    end
end

local function fail_conn_pending(c, err)
    local pending = c.pending
    c.pending = {}
    for _, req in ipairs(pending) do
        fail_request(req, err)
    end
end

local function close_conn(c, reason)
    if c.conn and not c.conn:is_closed() then
        c.conn:close(reason or 'close')
    end
end

local function connect_one(c)
    if stopping or c.connecting or c.connected then return end
    c.connecting = true
    c.closed = false

    local handler = {}

    function handler.on_connect(conn, ip, port)
        c.conn = conn
        c.connected = true
        c.ready = false
        c.connecting = false
        c.closed = false
        conn:set_framing({ type = 'raw', max_packet = config.max_packet })
        print(string.format('[XREDIS-WORKER] connected[%d] %s:%s raw',
            c.index, tostring(ip), tostring(port)))

        if config.db > 0 then
            send_internal(c, { n = 2, 'SELECT', config.db }, function(ok, result)
                if not ok then
                    close_conn(c, 'select db failed: ' .. tostring(result))
                    return
                end
                c.ready = true
                print(string.format('[XREDIS-WORKER] selected db[%d]=%d',
                    c.index, config.db))
                flush_waiting()
            end)
        else
            c.ready = true
            flush_waiting()
        end
    end

    function handler.on_packet(_, data)
        local pos = 1
        while pos <= #data do
            local reply, next_pos, incomplete, err = parse_resp(data, pos, 0)
            if incomplete then
                break
            end
            if err then
                fail_conn_pending(c, err)
                close_conn(c, err)
                return pos - 1
            end

            local req = table.remove(c.pending, 1)
            if not req then
                close_conn(c, 'unexpected redis reply')
                return next_pos - 1
            end

            if reply.kind == 'error' then
                fail_request(req, reply.value)
            elseif req.internal then
                req.internal(true, reply_to_lua(reply))
            else
                resume_rpc(req, true, reply_to_lua(reply))
            end

            pos = next_pos
        end
        return pos - 1
    end

    function handler.on_close(_, reason)
        c.connected = false
        c.ready = false
        c.connecting = false
        c.closed = true
        c.conn = nil
        fail_conn_pending(c, reason or 'redis connection closed')
        if not stopping then
            c.retry_at = os.time() + math.max(1, math.floor(config.reconnect_ms / 1000))
        end
        print(string.format('[XREDIS-WORKER] close[%d]: %s', c.index, tostring(reason)))
    end

    local conn, err = xnet.connect(config.host, config.port, handler)
    if not conn then
        c.connecting = false
        c.retry_at = os.time() + math.max(1, math.floor(config.reconnect_ms / 1000))
        print(string.format('[XREDIS-WORKER] connect[%d] failed: %s', c.index, tostring(err)))
        return
    end
    c.conn = conn
end

local function start_pool(host, port, db, pool_size, reconnect_ms, max_packet)
    config.host = host or config.host
    config.port = port or config.port
    config.db = tonumber(db) or 0
    config.pool_size = math.max(1, tonumber(pool_size) or config.pool_size)
    config.reconnect_ms = tonumber(reconnect_ms) or config.reconnect_ms
    config.max_packet = tonumber(max_packet) or config.max_packet
    stopping = false

    for i = 1, config.pool_size do
        local c = {
            index = i,
            conn = nil,
            connected = false,
            ready = false,
            connecting = false,
            closed = false,
            retry_at = 0,
            pending = {},
        }
        conns[i] = c
        connect_one(c)
    end
end

local function stop_pool()
    stopping = true
    local q = waitq
    waitq = {}
    for _, req in ipairs(q) do
        fail_request(req, 'xredis stopped')
    end
    for _, c in ipairs(conns) do
        fail_conn_pending(c, 'xredis stopped')
        close_conn(c, 'xredis stopped')
    end
    conns = {}
end

xthread.register('xredis_start', function(host, port, db, pool_size, reconnect_ms, max_packet)
    print(string.format('[XREDIS-WORKER] start %s:%s db=%s pool=%s',
        tostring(host), tostring(port), tostring(db), tostring(pool_size)))
    start_pool(host, port, db, pool_size, reconnect_ms, max_packet)
end)

xthread.register('xredis_stop', function()
    stop_pool()
end)

xthread.register('xredis_call', function(cmd, ...)
    local co = coroutine.running()
    local req = rpc_context[co]
    if not req then
        return false, 'xredis rpc context missing'
    end
    req.args = { n = select('#', ...) + 1, cmd, ... }
    enqueue(req)
    return coroutine.yield()
end)

local function dispatch_post(k1, k2, ...)
    local h = _stubs[k1]
    if h then
        h(k2, ...)
    elseif k1 then
        io.stderr:write('[XREDIS-WORKER] no post handler: ' .. tostring(k1) .. '\n')
    end
end

local function dispatch_rpc(reply_router, co_id, sk, pt, ...)
    local reply = _thread_replys[reply_router]
    if not reply then
        io.stderr:write('[XREDIS-WORKER] missing reply router: ' .. tostring(reply_router) .. '\n')
        return
    end

    local h = _stubs[pt]
    if not h then
        reply(co_id, sk, pt, false, 'xredis handler not found: ' .. tostring(pt))
        return
    end

    local req = {
        co_id = co_id,
        sk = sk,
        pt = pt,
        reply = reply,
        co = coroutine.create(function(...)
            return h(...)
        end),
    }
    rpc_context[req.co] = req
    resume_rpc(req, ...)
end

local function __thread_handle(reply_router, k1, k2, k3, ...)
    if reply_router then
        dispatch_rpc(reply_router, k1, k2, k3, ...)
    else
        dispatch_post(k1, k2, k3, ...)
    end
end

local function __init()
    print('[XREDIS-WORKER] init')
    assert(xnet.init())
end

local function __update()
    local now = os.time()
    for _, c in ipairs(conns) do
        if not stopping and not c.connected and not c.connecting and c.retry_at > 0 and now >= c.retry_at then
            c.retry_at = 0
            connect_one(c)
        end
    end
    xnet.poll(10)
end

local function __uninit()
    stop_pool()
    xnet.uninit()
    print('[XREDIS-WORKER] uninit')
end

return {
    __init = __init,
    __update = __update,
    __uninit = __uninit,
    __thread_handle = __thread_handle,
}
