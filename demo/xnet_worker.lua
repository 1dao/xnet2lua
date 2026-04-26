-- xnet_worker.lua - worker thread for the xnet/xchannel demo.
-- Owns both client and accepted server-side connections.

local cmsgpack = require 'cmsgpack'

local MAIN_ID = xthread.MAIN

local client_conn
local server_conn
local finished = false

_stubs = {}
_thread_replys = {}
_net_stubs = {}

local unpack_args = table.unpack or unpack

function xthread.register(pt, h)
    _stubs[pt] = h
end

function xnet.register(pt, h)
    _net_stubs[pt] = h
end

local function __thread_handle(reply_router, k1, k2, k3, ...)
    if reply_router then
        io.stderr:write('[XNET-WORKER] unexpected RPC message: ' .. tostring(k3) .. '\n')
        return
    end

    local h = _stubs[k1]
    if h then
        h(k2, k3, ...)
    elseif k1 then
        io.stderr:write('[XNET-WORKER] no handler for pt=' .. tostring(k1) .. '\n')
    end
end

local function send_packet(conn, pt, ...)
    local body = cmsgpack.pack(pt, ...)
    assert(conn:send(body), 'conn:send failed')
end

local function finish(ok, msg)
    if finished then return end
    finished = true
    print('[XNET-WORKER] finish:', ok, msg)
    xthread.post(MAIN_ID, 'xnet_done', ok, msg)
end

local function pack_args(...)
    return { n = select('#', ...), ... }
end

local function dispatch_net_packet(side, conn, body)
    local args = pack_args(cmsgpack.unpack(body))
    local pt = args[1]
    print('[XNET-WORKER] ' .. side .. ' recv:', unpack_args(args, 1, args.n))

    local h = _net_stubs[pt]
    if not h then
        finish(false, side .. ' unknown pt=' .. tostring(pt))
        return
    end

    print(string.format('[XNET-WORKER] %s dispatch stub: %s', side, tostring(pt)))
    h(side, conn, unpack_args(args, 2, args.n))
end

local server_handler = {}

function server_handler.on_connect(conn, ip, port)
    server_conn = conn
    print(string.format('[XNET-WORKER] server-side fd attached from %s:%s', tostring(ip), tostring(port)))
    conn:set_framing({ type = 'len32', max_packet = 1024 * 1024 })
    print('[XNET-WORKER] server framing: len32')
end

function server_handler.on_packet(conn, body)
    dispatch_net_packet('server', conn, body)
end

function server_handler.on_close(_, reason)
    print('[XNET-WORKER] server-side close:', reason)
end

local client_handler = {}

function client_handler.on_connect(conn, ip, port)
    client_conn = conn
    print(string.format('[XNET-WORKER] client connected to %s:%s', tostring(ip), tostring(port)))
    conn:set_framing({ type = 'len32', max_packet = 1024 * 1024 })
    print('[XNET-WORKER] client framing: len32')
    send_packet(conn, 'hello', 'from-client', 17, 25)
end

function client_handler.on_packet(conn, body)
    dispatch_net_packet('client', conn, body)
end

function client_handler.on_close(_, reason)
    print('[XNET-WORKER] client close:', reason)
end

xthread.register('accepted_fd', function(fd, ip, port)
    print(string.format('[XNET-WORKER] attach accepted fd=%s', tostring(fd)))
    local conn, err = xnet.attach(fd, server_handler, ip, port)
    if not conn then
        finish(false, 'xnet.attach failed: ' .. tostring(err))
    end
end)

xthread.register('start_client', function(host, port)
    print(string.format('[XNET-WORKER] connect to %s:%s', tostring(host), tostring(port)))
    local conn, err = xnet.connect(host, port, client_handler)
    if not conn then
        finish(false, 'xnet.connect failed: ' .. tostring(err))
    end
end)

xnet.register('hello', function(side, conn, arg1, arg2, arg3)
    if side ~= 'server' then
        finish(false, 'hello arrived on ' .. side)
        return
    end
    if arg1 ~= 'from-client' or arg2 ~= 17 or arg3 ~= 25 then
        finish(false, 'server received invalid hello')
        return
    end
    send_packet(conn, 'pong', 'from-server', arg2 + arg3, 'ok')
end)

xnet.register('pong', function(side, conn, arg1, arg2, arg3)
    if side ~= 'client' then
        finish(false, 'pong arrived on ' .. side)
        return
    end
    if arg1 ~= 'from-server' or arg2 ~= 42 or arg3 ~= 'ok' then
        finish(false, 'client received invalid pong')
        return
    end
    send_packet(conn, 'done', 'client-ok', arg2, arg3)
end)

xnet.register('done', function(side, _, arg1, arg2, arg3)
    if side ~= 'server' then
        finish(false, 'done arrived on ' .. side)
        return
    end
    if arg1 == 'client-ok' and arg2 == 42 and arg3 == 'ok' then
        finish(true, 'len32 cmsgpack exchange ok')
    else
        finish(false, 'server received invalid done')
    end
end)

local function __init()
    print('[XNET-WORKER] init')
    assert(xnet.init())
end

local function __update()
    xnet.poll(10)
end

local function __uninit()
    if client_conn then client_conn:close('worker_uninit') end
    if server_conn then server_conn:close('worker_uninit') end
    xnet.uninit()
    print('[XNET-WORKER] uninit')
end

return {
    __init = __init,
    __update = __update,
    __uninit = __uninit,
    __thread_handle = __thread_handle,
}
