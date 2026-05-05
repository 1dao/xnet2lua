-- NATS worker thread.
-- Uses xnet/xchannel raw mode and implements the small core NATS subset needed
-- by game process RPC and broadcast.

local cmsgpack = require('cmsgpack')
local unpack_args = table.unpack or unpack

local MAGIC = 'xnats1'

local config = {
    host = '127.0.0.1',
    port = 4222,
    name = 'game1',
    prefix = 'xnet',
    broadcast_subject = '',
    worker_threads = {},
    reconnect_ms = 1000,
    rpc_timeout_ms = 5000,
    max_packet = 64 * 1024 * 1024,
}

local conn_state = {
    conn = nil,
    connected = false,
    ready = false,
    connecting = false,
    closed = false,
    retry_at = 0,
}

local waitq = {}
local pending = {}
local subs = {}
local next_sid = 1
local next_req_id = 1
local rr_worker = 1
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
        resume_rpc(req, false, err)
    end
end

local function fail_pending(err)
    local old = pending
    pending = {}
    local seen = {}
    for _, req in pairs(old) do
        if not seen[req] then
            seen[req] = true
            fail_request(req, err)
        end
    end
end

local function fail_waiting(err)
    local old = waitq
    waitq = {}
    for _, req in ipairs(old) do
        fail_request(req, err)
    end
end

local function command_arg(v)
    local t = type(v)
    if t == 'string' then return v end
    if t == 'number' or t == 'boolean' then return tostring(v) end
    return tostring(v)
end

local function find_crlf(data, pos)
    return string.find(data, '\r\n', pos, true)
end

local function split_line(line)
    local out = {}
    for token in string.gmatch(line, '%S+') do
        out[#out + 1] = token
    end
    return out
end

local function json_escape(s)
    s = tostring(s or '')
    s = string.gsub(s, '\\', '\\\\')
    s = string.gsub(s, '"', '\\"')
    s = string.gsub(s, '\r', '\\r')
    s = string.gsub(s, '\n', '\\n')
    s = string.gsub(s, '\t', '\\t')
    return s
end

local function pack_payload(kind, ...)
    return cmsgpack.pack(MAGIC, kind, ...)
end

local function unpack_payload(payload)
    local values = pack_values(cmsgpack.unpack(payload))
    if values[1] ~= MAGIC then
        return nil, 'bad xnats payload'
    end
    return values
end

local function base_subject()
    return config.prefix or 'xnet'
end

local function broadcast_subject()
    if config.broadcast_subject and config.broadcast_subject ~= '' then
        return config.broadcast_subject
    end
    return base_subject() .. '.broadcast'
end

local function process_from_target(target)
    target = tostring(target or '')
    local proc = string.match(target, '^([^:]+):%d+$')
    return proc or target
end

local function rpc_subject_for(target)
    return base_subject() .. '.rpc.' .. process_from_target(target)
end

local function next_subscription(kind, value)
    local sid = tostring(next_sid)
    next_sid = next_sid + 1
    subs[sid] = { kind = kind, value = value }
    return sid
end

local function send_raw(data)
    local c = conn_state.conn
    if not c or conn_state.closed or c:is_closed() then
        return false, 'nats not connected'
    end
    if not c:send_raw(data) then
        return false, 'nats send failed'
    end
    return true
end

local function send_pub(subject, reply, payload)
    local header
    if reply and reply ~= '' then
        header = string.format('PUB %s %s %d\r\n', subject, reply, #payload)
    else
        header = string.format('PUB %s %d\r\n', subject, #payload)
    end
    return send_raw(header .. payload .. '\r\n')
end

local function send_sub(subject, sid)
    return send_raw(string.format('SUB %s %s\r\n', subject, sid))
end

local function send_unsub(sid, max_msgs)
    if max_msgs then
        return send_raw(string.format('UNSUB %s %d\r\n', sid, max_msgs))
    end
    return send_raw(string.format('UNSUB %s\r\n', sid))
end

local function publish_response(reply_subject, req_id, ok, ...)
    if not reply_subject or reply_subject == '' then
        return
    end
    local payload = pack_payload('rpc_res', req_id, ok and true or false, ...)
    local sent, err = send_pub(reply_subject, nil, payload)
    if not sent then
        io.stderr:write('[XNATS-WORKER] send rpc response failed: ' .. tostring(err) .. '\n')
    end
end

local function worker_count()
    return #(config.worker_threads or {})
end

local function choose_worker(target)
    local workers = config.worker_threads or {}
    if #workers == 0 then
        return nil, 'no business workers configured'
    end

    local idx = string.match(tostring(target or ''), '^[^:]+:(%d+)$')
    if idx then
        idx = tonumber(idx)
        local tid = workers[idx]
        if not tid then
            return nil, 'target worker index not found: ' .. tostring(target)
        end
        return tid
    end

    local tid = workers[rr_worker]
    rr_worker = (rr_worker % #workers) + 1
    return tid
end

local function start_incoming_rpc(msg, values)
    local req_id = values[3]
    local from = values[4]
    local target = values[5]
    local pt = values[6]

    if process_from_target(target) ~= config.name then
        return
    end

    local tid, err = choose_worker(target)
    if not tid then
        publish_response(msg.reply, req_id, false, err)
        return
    end

    local co = coroutine.create(function()
        local called = pack_values(pcall(xthread.rpc, tid, pt, 0, unpack_args(values, 7, values.n)))
        if not called[1] then
            publish_response(msg.reply, req_id, false, called[2])
            return
        end

        publish_response(msg.reply, req_id, true, unpack_args(called, 2, called.n))
        print(string.format('[XNATS-WORKER] rpc from=%s target=%s tid=%s pt=%s ok=%s',
            tostring(from), tostring(target), tostring(tid), tostring(pt), tostring(true)))
    end)

    local ok, co_err = coroutine.resume(co)
    if not ok then
        publish_response(msg.reply, req_id, false, co_err)
    end
end

local function dispatch_broadcast(values)
    local from = values[3]
    local pt = values[4]
    local workers = config.worker_threads or {}
    for _, tid in ipairs(workers) do
        local ok, err = xthread.post(tid, pt, unpack_args(values, 5, values.n))
        if not ok then
            io.stderr:write(string.format('[XNATS-WORKER] broadcast to thread %s failed: %s\n',
                tostring(tid), tostring(err)))
        end
    end
    print(string.format('[XNATS-WORKER] broadcast from=%s pt=%s workers=%d',
        tostring(from), tostring(pt), #workers))
end

local function handle_reply_msg(msg, values)
    local req_id = values[3]
    local req = pending[msg.subject]
    if not req and req_id then
        req = pending[tostring(req_id)]
    end
    if not req then
        io.stderr:write('[XNATS-WORKER] unexpected rpc reply on ' .. tostring(msg.subject) .. '\n')
        return
    end

    pending[req.reply_subject] = nil
    pending[tostring(req.req_id)] = nil
    resume_rpc(req, values[4], unpack_args(values, 5, values.n))
end

local function handle_msg(msg)
    local values, err = unpack_payload(msg.payload)
    if not values then
        io.stderr:write('[XNATS-WORKER] bad message payload: ' .. tostring(err) .. '\n')
        return
    end

    local kind = values[2]
    if kind == 'pub' then
        dispatch_broadcast(values)
    elseif kind == 'rpc_req' then
        start_incoming_rpc(msg, values)
    elseif kind == 'rpc_res' then
        handle_reply_msg(msg, values)
    else
        io.stderr:write('[XNATS-WORKER] unknown payload kind: ' .. tostring(kind) .. '\n')
    end
end

local function send_connect()
    local name = json_escape(config.name)
    local payload = string.format(
        'CONNECT {"verbose":false,"pedantic":false,"tls_required":false,"name":"%s","lang":"xnet-lua","version":"0.1"}\r\nPING\r\n',
        name)
    local ok, err = send_raw(payload)
    if not ok then
        return false, err
    end
    return true
end

local function subscribe_base_subjects()
    local bsub = broadcast_subject()
    local rsub = rpc_subject_for(config.name)
    send_sub(bsub, next_subscription('broadcast', bsub))
    send_sub(rsub, next_subscription('rpc', rsub))
    print(string.format('[XNATS-WORKER] subscribed broadcast=%s rpc=%s',
        bsub, rsub))
end

local flush_waiting

local function mark_ready()
    if conn_state.ready then return end
    subscribe_base_subjects()
    conn_state.ready = true
    print(string.format('[XNATS-WORKER] ready %s@%s:%s workers=%d',
        config.name, config.host, tostring(config.port), worker_count()))
    flush_waiting()
end

local function send_request(req)
    if not conn_state.ready then
        waitq[#waitq + 1] = req
        return true, 'queued'
    end

    if req.kind == 'publish' then
        local payload = pack_payload('pub', config.name, req.pt, unpack_args(req.args, 1, req.args.n))
        local ok, err = send_pub(broadcast_subject(), nil, payload)
        if not ok then
            return false, err
        end
        return true, 'sent'
    end

    local req_id = next_req_id
    next_req_id = next_req_id + 1
    local reply_subject = string.format('_INBOX.%s.%s.%d', base_subject(), config.name, req_id)
    local sid = next_subscription('reply', reply_subject)
    local ok, err = send_sub(reply_subject, sid)
    if not ok then
        return false, err
    end
    send_unsub(sid, 1)

    req.req_id = req_id
    req.reply_subject = reply_subject
    req.deadline = os.time() + math.max(1, math.floor((config.rpc_timeout_ms + 999) / 1000))
    pending[reply_subject] = req
    pending[tostring(req_id)] = req

    local payload = pack_payload('rpc_req', req_id, config.name, req.target, req.pt,
        unpack_args(req.args, 1, req.args.n))
    ok, err = send_pub(rpc_subject_for(req.target), reply_subject, payload)
    if not ok then
        pending[reply_subject] = nil
        pending[tostring(req_id)] = nil
        return false, err
    end
    return true, 'pending'
end

flush_waiting = function()
    while conn_state.ready and #waitq > 0 do
        local req = table.remove(waitq, 1)
        local ok, state = send_request(req)
        if not ok then
            fail_request(req, state)
        elseif req.kind == 'publish' and state == 'sent' then
            resume_rpc(req, true)
        end
    end
end

local function close_conn(reason)
    if conn_state.conn and not conn_state.conn:is_closed() then
        conn_state.conn:close(reason or 'close')
    end
end

local function parse_msg(tokens, data, payload_start)
    if #tokens ~= 4 and #tokens ~= 5 then
        return nil, payload_start, false, 'bad MSG header'
    end

    local subject = tokens[2]
    local sid = tokens[3]
    local reply
    local len_s
    if #tokens == 4 then
        len_s = tokens[4]
    else
        reply = tokens[4]
        len_s = tokens[5]
    end

    local len = tonumber(len_s)
    if not len or len < 0 then
        return nil, payload_start, false, 'bad MSG payload length'
    end
    if len > config.max_packet then
        return nil, payload_start, false, 'nats message too large'
    end

    local term = payload_start + len
    if term + 1 > #data then
        return nil, payload_start, true
    end
    if string.sub(data, term, term + 1) ~= '\r\n' then
        return nil, payload_start, false, 'bad MSG payload terminator'
    end

    return {
        subject = subject,
        sid = sid,
        reply = reply,
        payload = string.sub(data, payload_start, payload_start + len - 1),
    }, term + 2, false
end

local function handle_line(line)
    if line == '' then return end
    local tokens = split_line(line)
    local cmd = tokens[1]
    if cmd == 'INFO' then
        send_connect()
    elseif cmd == 'PING' then
        send_raw('PONG\r\n')
    elseif cmd == 'PONG' then
        mark_ready()
    elseif cmd == '+OK' then
        return
    elseif cmd == '-ERR' then
        close_conn(line)
    else
        io.stderr:write('[XNATS-WORKER] unknown line: ' .. tostring(line) .. '\n')
    end
end

local function process_packet(data)
    local pos = 1
    while pos <= #data do
        local line_end = find_crlf(data, pos)
        if not line_end then
            break
        end

        local line = string.sub(data, pos, line_end - 1)
        local next_pos = line_end + 2
        local tokens = split_line(line)
        if tokens[1] == 'MSG' then
            local msg, msg_next, incomplete, err = parse_msg(tokens, data, next_pos)
            if incomplete then
                break
            end
            if err then
                close_conn(err)
                return pos - 1
            end
            handle_msg(msg)
            pos = msg_next
        else
            handle_line(line)
            pos = next_pos
        end
    end
    return pos - 1
end

local function connect_one()
    if stopping or conn_state.connecting or conn_state.connected then return end
    conn_state.connecting = true
    conn_state.closed = false

    local handler = {}

    function handler.on_connect(conn, ip, port)
        conn_state.conn = conn
        conn_state.connected = true
        conn_state.ready = false
        conn_state.connecting = false
        conn_state.closed = false
        conn:set_framing({ type = 'raw', max_packet = config.max_packet })
        print(string.format('[XNATS-WORKER] connected %s:%s raw',
            tostring(ip), tostring(port)))
    end

    function handler.on_packet(_, data)
        return process_packet(data)
    end

    function handler.on_close(_, reason)
        conn_state.connected = false
        conn_state.ready = false
        conn_state.connecting = false
        conn_state.closed = true
        conn_state.conn = nil
        subs = {}
        fail_pending(reason or 'nats connection closed')
        if not stopping then
            conn_state.retry_at = os.time() + math.max(1, math.floor(config.reconnect_ms / 1000))
        end
        print(string.format('[XNATS-WORKER] close: %s', tostring(reason)))
    end

    local conn, err = xnet.connect(config.host, config.port, handler)
    if not conn then
        conn_state.connecting = false
        conn_state.retry_at = os.time() + math.max(1, math.floor(config.reconnect_ms / 1000))
        print('[XNATS-WORKER] connect failed: ' .. tostring(err))
        return
    end
    conn_state.conn = conn
end

local function start_nats(host, port, name, prefix, bsubject, workers, reconnect_ms, rpc_timeout_ms, max_packet)
    config.host = host or config.host
    config.port = tonumber(port) or config.port
    config.name = name or config.name
    config.prefix = prefix or config.prefix
    config.broadcast_subject = bsubject or ''
    config.worker_threads = {}
    if type(workers) == 'table' then
        for i, id in ipairs(workers) do
            config.worker_threads[i] = tonumber(id)
        end
    end
    config.reconnect_ms = tonumber(reconnect_ms) or config.reconnect_ms
    config.rpc_timeout_ms = tonumber(rpc_timeout_ms) or config.rpc_timeout_ms
    config.max_packet = tonumber(max_packet) or config.max_packet
    stopping = false
    connect_one()
end

local function stop_nats(silent)
    stopping = true
    if silent then
        waitq = {}
        pending = {}
    else
        fail_waiting('xnats stopped')
        fail_pending('xnats stopped')
    end
    close_conn('xnats stopped')
end

xthread.register('xnats_start', function(host, port, name, prefix, bsubject, workers, reconnect_ms, rpc_timeout_ms, max_packet)
    print(string.format('[XNATS-WORKER] start %s:%s name=%s prefix=%s workers=%d',
        tostring(host), tostring(port), tostring(name), tostring(prefix),
        type(workers) == 'table' and #workers or 0))
    start_nats(host, port, name, prefix, bsubject, workers, reconnect_ms, rpc_timeout_ms, max_packet)
end)

xthread.register('xnats_stop', function(silent)
    stop_nats(silent)
end)

xthread.register('xnats_publish', function(pt, ...)
    local co = coroutine.running()
    local req = rpc_context[co]
    if not req then
        req = {
            kind = 'publish',
            pt = tostring(pt),
            args = { n = select('#', ...), ... },
        }
        local ok, err = send_request(req)
        if not ok then
            print('[XNATS-WORKER] publish failed: ' .. tostring(err))
        end
        return
    end

    req.kind = 'publish'
    req.pt = tostring(pt)
    req.args = { n = select('#', ...), ... }

    local ok, state = send_request(req)
    if not ok then
        return false, state
    end
    if state == 'queued' then
        return coroutine.yield()
    end
    return true
end)

xthread.register('xnats_rpc', function(target, pt, ...)
    local co = coroutine.running()
    local req = rpc_context[co]
    if not req then
        return false, 'xnats rpc context missing'
    end

    req.kind = 'rpc'
    req.target = tostring(target)
    req.pt = tostring(pt)
    req.args = { n = select('#', ...), ... }

    local ok, err = send_request(req)
    if not ok then
        return false, err
    end
    return coroutine.yield()
end)

local function dispatch_post(k1, k2, ...)
    local h = _stubs[k1]
    if h then
        h(k2, ...)
    elseif k1 then
        io.stderr:write('[XNATS-WORKER] no post handler: ' .. tostring(k1) .. '\n')
    end
end

local function dispatch_rpc(reply_router, co_id, sk, pt, ...)
    local reply = _thread_replys[reply_router]
    if not reply then
        io.stderr:write('[XNATS-WORKER] missing reply router: ' .. tostring(reply_router) .. '\n')
        return
    end

    local h = _stubs[pt]
    if not h then
        reply(co_id, sk, pt, false, 'xnats handler not found: ' .. tostring(pt))
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
    print('[XNATS-WORKER] init')
    assert(xnet.init())
end

local function __update()
    local now = os.time()
    if not stopping and not conn_state.connected and not conn_state.connecting and conn_state.retry_at > 0 and now >= conn_state.retry_at then
        conn_state.retry_at = 0
        connect_one()
    end

    for key, req in pairs(pending) do
        if type(key) == 'string' and req.reply_subject == key and req.deadline and now >= req.deadline then
            pending[req.reply_subject] = nil
            pending[tostring(req.req_id)] = nil
            fail_request(req, 'nats rpc timeout')
        end
    end

    xnet.poll(10)
end

local function __uninit()
    stop_nats(true)
    xnet.uninit()
    print('[XNATS-WORKER] uninit')
end

return {
    __init = __init,
    __update = __update,
    __uninit = __uninit,
    __thread_handle = __thread_handle,
}
