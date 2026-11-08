-- One UDP server socket, two clients, three independent datagrams per client.
-- Run from the repository root:
--   make run-lua WITH_UDP=1 SCRIPT=demo/xudp_main.lua
--   build.bat udp run-lua demo/xudp_main.lua
-- Uses loopback and OS-assigned ports. No external server is needed.
-- This demonstrates raw datagrams, not the pending reliable/security protocol.

local xnet = require('xnet')
local HOST = '127.0.0.1'
local payloads = {'hello UDP', 'binary\0\255data', ''}
local server, clients = nil, {}
local done, replies, received = false, 0, 0
local baseline

local function display(data)
    return (data:gsub('[%c\127-\255]', function(byte)
        return string.format('\\x%02X', string.byte(byte))
    end))
end

local function close_sockets()
    for _, client in ipairs(clients) do client.socket:close() end
    if server then server:close() end
end

local function finish(ok, message)
    if done then return end
    done = true
    close_sockets()
    if baseline and xnet.get_stats().fd_count ~= baseline then
        ok, message = false, 'socket registrations did not return to baseline'
    end
    print(string.format('[UDP-DEMO] %s: %s', ok and 'PASS' or 'FAIL', message))
    xthread.stop(ok and 0 or 1)
end

local function on_error(_, system_error, fatal)
    finish(false, string.format('socket error=%d fatal=%s', system_error, tostring(fatal)))
end

local function __init()
    if type(xnet.udp_bind) ~= 'function' then
        print('[UDP-DEMO] SKIP: UDP is disabled. Enable WITH_UDP=1 or use build.bat udp.')
        xthread.stop(0)
        return
    end
    assert(xnet.init())
    xtimer.init(8)
    baseline = xnet.get_stats().fd_count

    server = assert(xnet.udp_bind(HOST, 0, {
        on_datagram = function(udp, data, ip, port)
            if done then return end
            assert(udp == server, 'all clients must use the same server socket')
            local known_client = false
            for _, client in ipairs(clients) do
                if client.port == port and ip == HOST then known_client = true end
            end
            assert(known_client, 'unexpected datagram source')
            received = received + 1
            print(string.format('[SERVER] from %s:%d bytes=%d data="%s"', ip, port, #data, display(data)))
            -- Reply through the SAME socket, to this datagram's source address.
            assert(udp:sendto(data, ip, port))
        end,
        on_error = on_error,
    }, {recv_budget = 2}))
    local server_ip, server_port = server:sockname()
    assert(xnet.get_stats().udp_count == 1)
    print(string.format('[SERVER] bound %s:%d, one UDP socket for both clients', server_ip, server_port))

    for i = 1, 2 do
        local client = {seen = {}}
        client.socket = assert(xnet.udp_bind(HOST, 0, {
            on_datagram = function(_, data, ip, port)
                if done then return end
                assert(ip == server_ip and port == server_port, 'unexpected reply source')
                local expected = false
                for _, payload in ipairs(payloads) do
                    if data == payload then expected = true end
                end
                assert(expected, 'echo changed the datagram bytes')
                if client.seen[data] then return end -- duplicates add no new progress
                client.seen[data] = true
                replies = replies + 1
                print(string.format('[CLIENT %d] reply from %s:%d bytes=%d data="%s"', i, ip, port, #data, display(data)))
                if replies == #clients * #payloads then
                    local stats = server:stats()
                    assert(received >= 6 and stats.datagrams_received >= 6)
                    assert(stats.datagrams_sent >= 6)
                    finish(true, 'two clients echoed text, binary and empty datagrams through one server socket')
                end
            end,
            on_error = on_error,
        }))
        local ip
        ip, client.port = client.socket:sockname()
        clients[#clients + 1] = client
        print(string.format('[CLIENT %d] bound %s:%d', i, ip, client.port))
    end
    assert(clients[1].port ~= clients[2].port)
    assert(xnet.get_stats().udp_count == 3) -- one server + two client sockets
    assert(xnet.get_stats().fd_count == baseline + 3)

    for _, client in ipairs(clients) do
        for _, payload in ipairs(payloads) do
            assert(client.socket:sendto(payload, server_ip, server_port))
        end
    end
    xtimer.add(5000, function()
        finish(false, string.format('timeout: received %d/6 echoes', replies))
    end, 1)
end

return {
    __init = __init,
    __uninit = function()
        close_sockets()
        xnet.uninit()
    end,
    __tick_ms = 1,
}
