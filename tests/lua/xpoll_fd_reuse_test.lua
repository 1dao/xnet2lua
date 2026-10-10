-- xpoll_fd_reuse_test.lua — a closed socket's events must not reach the next
-- socket registered on the same fd.
--
--   Run: bin/xnet tests/lua/xpoll_fd_reuse_test.lua      (bin\xnet.exe on Windows)
--   Exit code 0 = all pass.
--
-- REGRESSION. A failed connect reports writable and error in one event. The
-- writable handler closes the connection, and a listener opened from its
-- on_close got the same fd number and, from malloc, the freed registration's
-- address. xpoll told entries apart by pointer only, so the connect's error
-- went on to the listener and closed it. Seen on Linux (epoll, glibc malloc)
-- as a service that probed its port, found it free, and then never listened.
-- Whether malloc hands back the freed address depends on the allocations in
-- between; at the default log level this fails on every run without the fix.

local fails, checks = 0, 0
local function out(s) io.write(s); io.flush() end
local function check(name, cond, detail)
    checks = checks + 1
    if cond then
        out('PASS ' .. name .. '\n')
    else
        fails = fails + 1
        out('FAIL ' .. name .. ' :: ' .. tostring(detail) .. '\n')
    end
end

local HOST        = '127.0.0.1'
local CLOSED_PORT = 19473   -- nothing listens here
local PORT        = 19474

local finished = false
local function finish()
    if finished then return end
    finished = true
    out(string.format('\n[xpoll-fd-reuse] %s (%d checks, %d failure(s))\n',
        fails == 0 and 'ALL PASS' or 'FAILED', checks, fails))
    xthread.stop(fails == 0 and 0 or 1)
end

local listener

-- Once the loop has finished the probe's dispatch, the listener must accept.
local function verify()
    local answered = false
    local conn = xnet.connect(HOST, PORT, {
        on_connect = function(c) c:send_raw('ping') end,
        on_packet = function(c, data)
            answered = data == 'pong'
            c:close('done')
            return #data
        end,
        on_close = function()
            check('the listener opened from on_close still accepts', answered, 'connection refused or closed')
            if listener then listener:close() end
            finish()
        end,
    })
    if not conn then
        check('the listener opened from on_close still accepts', false, 'connect failed')
        finish()
    end
end

-- The shape of a service start: probe the port, and listen when it is free.
local function listen()
    listener = xnet.listen(HOST, PORT, {
        on_connect = function(conn) conn:set_framing({ type = 'raw' }) end,
        on_packet = function(conn, data) conn:send_raw('pong'); return #data end,
    })
    check('listen from the failed probe\'s on_close', listener ~= nil, 'listen failed')
    if not listener then return finish() end
    xtimer.add(100, verify, 1)
end

return {
    __thread_handle = function() end,
    __init = function()
        assert(xnet.init())
        xtimer.init(16)
        local probe = xnet.connect(HOST, CLOSED_PORT, {
            on_connect = function(c) check('nothing listens on the probed port', false, 'connected'); c:close('probe') end,
            on_packet = function(_, data) return #data end,
            on_close = function() listen() end,
        })
        -- Some systems refuse a loopback connect at once; then nothing is reused.
        if not probe then out('NOTE the probe failed synchronously; fd reuse is not exercised\n'); listen() end
        xtimer.add(10000, function()
            out('FAIL watchdog: the test did not finish within 10s\n')
            xthread.stop(1)
        end, 1)
    end,
    __uninit = function() xnet.uninit() end,
}
