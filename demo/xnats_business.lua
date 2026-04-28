-- Business worker for the Lua xnats demo.
-- NATS requests are routed to normal xthread protocol handlers.

local xnats = dofile('demo/xnats.lua')

local MAIN_ID = xthread.MAIN

_stubs = {}
_thread_replys = {}

local unpack_args = table.unpack or unpack
local rpc_context = {}

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

local function dispatch_rpc(reply_router, co_id, sk, pt, ...)
    local reply = _thread_replys[reply_router]
    if not reply then
        io.stderr:write('[XNATS-BIZ] missing reply router: ' .. tostring(reply_router) .. '\n')
        return
    end

    local h = _stubs[pt]
    if not h then
        reply(co_id, sk, pt, false, 'xnats business handler not found: ' .. tostring(pt))
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
        return
    end

    local h = _stubs[k1]
    if not h then
        if k1 then
            io.stderr:write('[XNATS-BIZ] no handler for pt=' .. tostring(k1) .. '\n')
        end
        return
    end

    local args = { n = select('#', ...) + 2, k2, k3, ... }
    local co = coroutine.create(function()
        h(unpack_args(args, 1, args.n))
    end)
    local ok, err = coroutine.resume(co)
    if not ok then
        xthread.post(MAIN_ID, 'xnats_business_done', xthread.current_id(), false, tostring(err))
    end
end

local function finish(ok, msg)
    xthread.post(MAIN_ID, 'xnats_business_done', xthread.current_id(), ok, msg)
end

xthread.register('xnats_broadcast_test', function(from, text)
    print(string.format('[XNATS-BIZ:%d] broadcast from=%s text=%s',
        xthread.current_id(), tostring(from), tostring(text)))
    xthread.post(MAIN_ID, 'xnats_broadcast_seen', xthread.current_id(), from, text)
end)

xthread.register('xnats_rpc_echo', function(label, mode)
    local tid = xthread.current_id()
    print(string.format('[XNATS-BIZ:%d] rpc echo label=%s mode=%s',
        tid, tostring(label), tostring(mode)))
    return tid, 'reply:' .. tostring(label) .. ':' .. tostring(mode)
end)

local function test_rpc_target(name, target_base, suffix)
    local mode = suffix .. '-random'
    local rpc_ok, tid, reply = xnats.rpc(target_base, 'xnats_rpc_echo', name, mode)
    print(string.format('[XNATS-BIZ:%s] rpc %s random %s tid=%s reply=%s',
        name, target_base, tostring(rpc_ok), tostring(tid), tostring(reply)))
    if not rpc_ok or not tonumber(tid) or reply ~= 'reply:' .. name .. ':' .. mode then
        return false, 'random rpc failed: ' .. target_base
    end

    local target_one = target_base .. ':1'
    mode = suffix .. '-thread-1'
    rpc_ok, tid, reply = xnats.rpc(target_one, 'xnats_rpc_echo', name, mode)
    print(string.format('[XNATS-BIZ:%s] rpc %s %s tid=%s reply=%s',
        name, target_one, tostring(rpc_ok), tostring(tid), tostring(reply)))
    if not rpc_ok or tonumber(tid) ~= xthread.WORKER_GRP2 or reply ~= 'reply:' .. name .. ':' .. mode then
        return false, 'targeted rpc thread-1 failed: ' .. target_one
    end

    local target_two = target_base .. ':2'
    mode = suffix .. '-thread-2'
    rpc_ok, tid, reply = xnats.rpc(target_two, 'xnats_rpc_echo', name, mode)
    print(string.format('[XNATS-BIZ:%s] rpc %s %s tid=%s reply=%s',
        name, target_two, tostring(rpc_ok), tostring(tid), tostring(reply)))
    if not rpc_ok or tonumber(tid) ~= xthread.WORKER_GRP2 + 1 or reply ~= 'reply:' .. name .. ':' .. mode then
        return false, 'targeted rpc thread-2 failed: ' .. target_two
    end

    return true
end

xthread.register('run_xnats_test', function(name, process_name, peer_process)
    name = tostring(name or ('biz-' .. tostring(xthread.current_id())))
    process_name = tostring(process_name or 'game1')
    peer_process = tostring(peer_process or '')
    print(string.format('[XNATS-BIZ:%s] start nats test process=%s peer=%s',
        name, process_name, peer_process ~= '' and peer_process or '(none)'))

    local ok, err = xnats.publish('xnats_broadcast_test', name, 'hello-broadcast')
    print(string.format('[XNATS-BIZ:%s] publish broadcast %s', name, tostring(ok)))
    if not ok then
        finish(false, name .. ' publish failed: ' .. tostring(err))
        return
    end

    local rpc_ok, rpc_err = test_rpc_target(name, process_name, 'local')
    if not rpc_ok then
        finish(false, name .. ' local ' .. tostring(rpc_err))
        return
    end

    if peer_process ~= '' and peer_process ~= process_name then
        rpc_ok, rpc_err = test_rpc_target(name, peer_process, 'peer')
        if not rpc_ok then
            finish(false, name .. ' peer ' .. tostring(rpc_err))
            return
        end
    end

    finish(true, name .. ' nats ok')
end)

local function __init()
    print(string.format('[XNATS-BIZ:%d] init', xthread.current_id()))
end

local function __update()
end

local function __uninit()
    print(string.format('[XNATS-BIZ:%d] uninit', xthread.current_id()))
end

return {
    __init = __init,
    __update = __update,
    __uninit = __uninit,
    __thread_handle = __thread_handle,
}
