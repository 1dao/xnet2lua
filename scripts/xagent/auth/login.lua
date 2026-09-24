-- Tick-driven loopback login shared by desktop and Android hosts.
local auth = require('xagent.auth.chatgpt')
local codec = dofile('scripts/core/share/xhttp_codec.lua')
local M = {}
local active
function M.cancel()
    local a = active; active = nil; auth.cancel()
    if a then
        if a.server then a.server:close('OAuth finished') end
    end
end
function M.start(opts)
    assert(not active, 'A ChatGPT login is already running')
    opts = opts or {}
    local a = { clients = {}, expires = os.time() + 300, on_done = opts.on_done }
    local handler = {}
    function handler.on_connect(conn)
        conn:set_framing({ type = 'raw', max_packet = 16384 }); a.clients[conn] = ''
    end
    function handler.on_close(conn) a.clients[conn] = nil end
    function handler.on_packet(conn, data)
        local buffer = (a.clients[conn] or '') .. data
        if #buffer > 16384 then conn:close('request too large'); return #data end
        a.clients[conn] = buffer
        if not buffer:find('\r\n\r\n', 1, true) then return #data end
        local target = buffer:match('^GET ([^ ]+) HTTP/1%.[01]\r\n')
        local path, query
        if target then path, query = target:match('^([^?]+)%??(.*)$') end
        local function reply(status, text)
            conn:send_raw('HTTP/1.1 ' .. status .. '\r\nContent-Type: text/plain; charset=utf-8\r\nCache-Control: no-store\r\nContent-Length: ' .. #text .. '\r\nConnection: close\r\n\r\n' .. text)
            conn:close('OAuth callback')
        end
        if path ~= '/auth/callback' or a.exchanging then reply('404 Not Found', 'Not found'); return #data end
        local q = codec.parse_query(query or '')
        if q.state ~= a.state then reply('400 Bad Request', 'Invalid OAuth state'); return #data end
        a.exchanging = true
        -- The UI reports success only after exchange and durable storage succeed.
        local co = coroutine.create(function()
            local ok, result = pcall(auth.finish, q)
            if active == a then
                local callback = a.on_done
                M.cancel()
                if callback then callback(ok, ok and nil or tostring(result)) end
            end
        end)
        local ok, err = coroutine.resume(co)
        -- Start token exchange before closing the callback socket. Some native
        -- event-loop backends defer new socket registration during close.
        reply('200 OK', 'Return to Codua to see the login result.')
        if not ok then
            local callback = a.on_done
            M.cancel()
            if callback then callback(false, tostring(err)) end
        end
        return #data
    end
    local server, err = xnet.listen('127.0.0.1', 1455, handler)
    assert(server, 'Cannot listen on localhost:1455: ' .. tostring(err))
    a.server = server; active = a
    local ok, url = pcall(auth.begin, opts.proxy)
    if not ok then M.cancel(); error(url) end
    a.state = codec.parse_query(url:match('%?(.*)$')).state
    return url
end
function M.tick()
    if active and os.time() >= active.expires then
        local cb = active.on_done; M.cancel(); if cb then cb(false, 'ChatGPT login timed out') end
    end
end
function M.running() return active ~= nil end
return M
