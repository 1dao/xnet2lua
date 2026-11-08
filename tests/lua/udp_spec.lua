-- Runs in both builds: disabled builds must expose no UDP API or metatable.
local spec = dofile('tests/lua/spec_helper.lua')
local xnet = require('xnet')
local enabled = type(xnet.udp_bind) == 'function'

-- Reuse this file as a worker fixture; intentionally omit close and __uninit.
if xthread.current_id() ~= 1 then
    return {__init = function()
        assert(xnet.init())
        local u = assert(xnet.udp_bind('127.0.0.1', 0, {on_datagram = function() end}))
        local _, port = u:sockname()
        assert(xthread.post(1, 'udp_worker_ready', port))
    end}
end

local function collect()
    collectgarbage('collect')
    collectgarbage('collect')
end

local function pump(done)
    for _ = 1, 100 do
        xnet.poll(5)
        if done() then return end
    end
    assert(done(), 'UDP loopback receive timeout')
end

spec.describe('UDP build isolation', function()
    spec.it('has no sockets on module load and no disabled placeholders', function()
        local expected = os.getenv('XNET_TEST_WITH_UDP')
        if expected then spec.equal(enabled, expected == '1', 'UDP build flag/API mismatch') end
        if enabled then
            spec.equal(xnet.get_stats().udp_count, 0)
            spec.equal(xnet.get_stats().udp_object_count, 0)
        else
            spec.equal(xnet.udp_bind, nil)
            spec.equal(xnet.get_stats().udp_count, nil)
            spec.equal(debug.getregistry()['xnet.udp'], nil)
        end
    end)
end)

if enabled then
    assert(xnet.init())
    local baseline = xnet.get_stats().fd_count
    spec.describe('UDP binding', function()
        spec.it('preserves binary/empty datagrams, sources and receive budget', function()
            local packets = {}
            local server = assert(xnet.udp_bind('127.0.0.1', 0, {
                on_datagram = function(_, data, ip, port)
                    packets[#packets + 1] = {data, ip, port}
                end,
            }, {max_datagram = 8, recv_budget = 2}))
            local host, port = server:sockname()
            spec.equal(host, '127.0.0.1')
            assert(port > 0)
            local function client()
                return assert(xnet.udp_bind('127.0.0.1', 0, {on_datagram = function() end}))
            end
            local a, b = client(), client()
            local _, a_port = a:sockname()
            local _, b_port = b:sockname()
            assert(a:sendto('a\0b', host, port))
            assert(a:sendto('', host, port))
            assert(a:sendto(string.rep('x', 20), host, port))
            assert(b:sendto('end', host, port))
            xnet.poll(100)
            spec.equal(#packets, 2)
            pump(function() return #packets == 3 end)
            spec.equal(packets[1][1], 'a\0b')
            spec.equal(packets[1][3], a_port)
            spec.equal(packets[2][1], '')
            spec.equal(packets[3][1], 'end')
            spec.equal(packets[3][2], host)
            spec.equal(packets[3][3], b_port)
            spec.equal(server:stats().dropped_oversize, 1)
            assert(server:stats().budget_yields >= 1)
            local ok, err = server:sendto(string.rep('x', 9), host, port)
            spec.equal(ok, false)
            spec.equal(err, 'too_large')
            ok, err = a:sendto('', 'bad-address', port)
            spec.equal(ok, false)
            spec.equal(err, 'invalid_address')
            server:close(); server:close()
            spec.equal(server:is_closed(), true)
            ok, err = server:sendto('', host, port)
            spec.equal(ok, false)
            spec.equal(err, 'closed')
            a:close(); b:close()
            spec.equal(xnet.get_stats().fd_count, baseline)
        end)

        spec.it('pins callback userdata across close, fd reuse and collection', function()
            collect()
            local objects = xnet.get_stats().udp_object_count
            local calls, replacement = 0, nil
            local server = assert(xnet.udp_bind('127.0.0.1', 0, {
                on_datagram = function(u)
                    calls = calls + 1
                    u:close()
                    replacement = assert(xnet.udp_bind('127.0.0.1', 0, {
                        on_datagram = function() calls = calls + 1 end,
                    }))
                    collect()
                end,
            }))
            local ip, port = server:sockname()
            assert(server:sendto('close', ip, port))
            assert(server:sendto('queued-old-packet', ip, port))
            server = nil -- only the runtime root remains
            pump(function() return calls == 1 end)
            collect()
            spec.equal(replacement:is_closed(), false)
            ip, port = replacement:sockname()
            assert(replacement:sendto('new', ip, port))
            pump(function() return calls == 2 end)
            replacement:close()
            replacement = nil
            collect()
            spec.equal(xnet.get_stats().udp_count, 0)
            spec.equal(xnet.get_stats().udp_object_count, objects)
        end)

        spec.it('cleans sockets on uninit and can immediately bind the same port', function()
            local forgotten = assert(xnet.udp_bind(nil, 0, {on_datagram = function() end}))
            local _, port = forgotten:sockname()
            xnet.uninit()
            spec.equal(forgotten:is_closed(), true)
            spec.equal(xnet.get_stats().udp_count, 0)
            assert(xnet.init())
            local rebound = assert(xnet.udp_bind('0.0.0.0', port, {on_datagram = function() end}))
            rebound:close()
        end)

        spec.it('rejects invalid options before allocating sockets', function()
            local before = xnet.get_stats().fd_count
            local handler = {on_datagram = function() end}
            spec.equal(pcall(xnet.udp_bind, nil, 0, handler, {recv_budget = 0}), false)
            spec.equal(pcall(xnet.udp_bind, nil, 0, handler, {max_datagram = 65508}), false)
            spec.equal(pcall(xnet.udp_bind, nil, 65536, handler), false)
            spec.equal(pcall(xnet.udp_bind, nil, 0, {}), false)
            spec.equal(xnet.udp_bind('::1', 0, handler), nil)
            collect()
            spec.equal(xnet.get_stats().fd_count, before)
        end)
    end)
    xnet.uninit()
    collect()
    assert(xnet.get_stats().udp_object_count == 0)
end

local function finish()
    xthread.stop(spec.finish() > 0 and 1 or 0)
end

return {
    __init = function()
        if not enabled or spec.failed > 0 then return finish() end
        assert(xnet.init())
        xtimer.init(4)
        assert(xthread.create_thread(197, 'udp-cleanup', 'tests/lua/udp_spec.lua'))
        xtimer.add(5000, function() xthread.stop(1) end, 1)
    end,
    __thread_handle = function(_, pt, port)
        if pt ~= 'udp_worker_ready' then return end
        spec.it('closes forgotten sockets before destroying a worker state', function()
            assert(xthread.shutdown_thread(197))
            local u = assert(xnet.udp_bind('127.0.0.1', port, {on_datagram = function() end}))
            u:close()
            u = nil
            collect()
            spec.equal(xnet.get_stats().udp_count, 0)
            spec.equal(xnet.get_stats().udp_object_count, 0)
        end)
        finish()
    end,
    __uninit = function() xnet.uninit() end,
}
