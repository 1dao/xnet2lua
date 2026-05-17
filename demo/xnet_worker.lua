-- xnet_worker.lua -- worker thread for the xnet smoke test.
--
-- Server-side of the cmsgpack/len32 protocol used by demo/xnet_main.lua.
-- Built on scripts/core/share/xsession.lua + scripts/core/share/xrouter.lua:
--   * len32 framing, application frames are cmsgpack-packed
--   * rpc   kind -- handled serially by the per-fd session coroutine
--   * query kind -- handled by an independent side coroutine (parallel)
--   * post  kind -- fire-and-forget side coroutine, no response
--
-- Handler convention is xrouter native: function(arg1, arg2, ...) -> ret1, ret2,...
-- xsession wraps via pcall and ships (ok, rets...) to send_response.
--
-- xrouter.stubs holds both 'accepted_fd' (xthread message, dispatched via
-- __thread_handle) and the socket pts ('echo' etc., dispatched via xsession).
-- Different entry points read the same table; only same-name reuse collides.

local xsession = dofile('scripts/core/share/xsession.lua')
local xrouter  = dofile('scripts/core/share/xrouter.lua')
local cmsgpack = require 'cmsgpack'

xrouter.set_log_prefix('XNET-WORKER')

local counter  = 0
local table_pack = table.pack or function(...) return { n = select('#', ...), ... } end

-- Socket-side protocol handlers (positional, xrouter convention) -----------
-- Each handler returns ret1, ret2, ...; xsession packs them as
-- (id, ok=true, ret1, ret2, ...). A raised error becomes (id, false, errmsg).

xrouter.register('echo', function(payload)
    return payload
end)

xrouter.register('arg_count', function(...)
    return select('#', ...)
end)

xrouter.register('get_counter', function()
    return counter
end)

xrouter.register('counter_inc', function()
    counter = counter + 1
    -- No return value. Post kind: response discarded; rpc kind: client gets
    -- the canonical success-no-payload reply (id, true).
end)

xrouter.register('parallel_echo', function(payload)
    return 'q:' .. tostring(payload)
end)

-- xsession server handler --------------------------------------------------

local handler = xsession.make({
    framing = { type = 'len32', max_packet = 1 * 1024 * 1024 },

    parse_packet = function(data, pos)
        -- len32 framing -> data is one frame body, pos == 1.
        -- Wire layout: pack(id, kind, pt, arg1, arg2, ...)
        local vals = table_pack(cmsgpack.unpack(data))
        local id, kind, pt = vals[1], vals[2], vals[3]
        if id == nil then
            return nil, pos, 'bad cmsgpack'
        end
        -- Collect remaining values as positional args. Capture explicit
        -- length to survive trailing nils.
        local nargs = vals.n - 3
        if nargs < 0 then nargs = 0 end
        local args = { n = nargs }
        for i = 1, nargs do args[i] = vals[i + 3] end
        return { id = id, kind = kind, pt = pt, args = args }, #data + 1
    end,

    classify = function(req) return req.kind end,

    -- router path (positional): send_response receives (conn, req, ok, ret1, ret2, ...).
    send_response = function(conn, req, ok, ...)
        local body = cmsgpack.pack(req.id, ok and true or false, ...)
        conn:send(body)
    end,

    router = xrouter,

    on_connect = function(conn, ip, port)
        print(string.format('[XNET-WORKER] accept fd=%s from %s:%s',
            tostring(conn:fd()), tostring(ip), tostring(port)))
    end,
    on_close = function(_, reason)
        print('[XNET-WORKER] close: ' .. tostring(reason))
    end,

    log_prefix    = 'XNET-WORKER',
    max_queue_len = 256,
})

-- xthread message: accepted fd from main thread
xrouter.register('accepted_fd', function(fd, ip, port)
    print(string.format('[XNET-WORKER] attach accepted fd=%s', tostring(fd)))
    local conn, err = xnet.attach(fd, handler, ip, port)
    if not conn then
        io.stderr:write('[XNET-WORKER] attach failed: ' .. tostring(err) .. '\n')
    end
end)

return {
    __init = function()
        print('[XNET-WORKER] init')
        assert(xnet.init())
    end,
    __uninit = function()
        handler.close_all('worker_uninit')
        xnet.uninit()
        print('[XNET-WORKER] uninit')
    end,
    __thread_handle = xrouter.handle,  -- routes 'accepted_fd' (and only that, here)
}
