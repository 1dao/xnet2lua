-- conn_close_leak_test.lua — a closed connection must give its channel back.
--
--   Run: bin/xnet tests/lua/conn_close_leak_test.lua      (bin\xnet.exe on Windows)
--   Exit code 0 = all pass.
--
-- REGRESSION. lua_conn_close_cb cleared c->ch without dropping the owner
-- reference xchannel_create hands out, and close_internal never drops it
-- either, so l_conn_gc -- which only destroys a channel it can still see --
-- had nothing left to free. Every connection that closed leaked its xChannel
-- and both buffers (8 KiB+ of receive buffer alone). Nothing failed: an HTTP
-- service with Connection: close clients just grew by ~25 KiB per request,
-- found at 1.2 GB after four weeks.
--
-- xnet.get_stats().channel_count counts channels not yet freed, so the check
-- is exact rather than a guess from RSS: after the conns are collected it
-- must be back where it started.

local router = dofile('scripts/core/share/xrouter.lua')

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

local HOST   = '127.0.0.1'
local PORT   = 19471
local ROUNDS = 300

local function channels() return xnet.get_stats().channel_count end

local function finish()
    out(string.format('\n[conn-close-leak] %s (%d checks, %d failure(s))\n',
        fails == 0 and 'ALL PASS' or 'FAILED', checks, fails))
    xthread.stop(fails == 0 and 0 or 1)
end

-- Sequential request/close rounds, the shape of an HTTP server answering
-- Connection: close clients: the server closes after replying (the explicit
-- conn:close path) and the client then sees EOF (the read_eof path). Both
-- sides' channels have to come back.
local function run(baseline)
    local listener
    local done, kept = 0, nil

    local server = {}
    function server.on_packet(conn, data)
        conn:send_raw('pong')
        conn:close('done')
        return #data
    end

    local next_round
    local function client_for(i)
        local h = {}
        function h.on_connect(conn) conn:send_raw('ping ' .. i) end
        function h.on_packet(_conn, data) return #data end
        function h.on_close(conn, _reason)
            -- Keep the last conn alive past its close so the methods can be
            -- exercised on a closed conn: its channel is now retained until
            -- the conn is collected rather than dropped at close.
            if i == ROUNDS then kept = conn end
            done = done + 1
            next_round()
        end
        return h
    end

    next_round = function()
        if done < ROUNDS then
            local conn, err = xnet.connect(HOST, PORT, client_for(done + 1))
            if not conn then
                check('connect round ' .. (done + 1), false, err)
                listener:close()
                return finish()
            end
            return
        end

        listener:close()
        -- Not from here: this runs inside the last conn's on_close, which
        -- still has that conn on its stack (so it cannot be collected) and
        -- has not yet marked it closed. A timer runs on the main state once
        -- the callback has returned.
        xtimer.add(10, function()
            local closed, sent, fd = kept:is_closed(), kept:send_raw('x'), kept:fd()
            check('a closed conn still answers its methods safely',
                closed == true and sent == false and fd == nil,
                string.format('is_closed=%s send_raw=%s fd=%s',
                    tostring(closed), tostring(sent), tostring(fd)))
            kept = nil

            -- Twice: a collection can leave finalizers for the next cycle.
            collectgarbage('collect')
            collectgarbage('collect')
            local leaked = channels() - baseline
            check(string.format('every channel freed after %d closed connections', ROUNDS),
                leaked == 0,
                string.format('%d channel(s) still allocated', leaked))
            finish()
        end, 1)
    end

    listener = xnet.listen(HOST, PORT, {
        on_connect = function(conn) conn:set_framing({ type = 'raw' }) end,
        on_packet  = server.on_packet,
    })
    if not listener then
        check('listen on ' .. PORT, false, 'listen failed')
        return finish()
    end
    next_round()
end

return {
    __thread_handle = router.handle,
    __init = function()
        assert(xnet.init())
        xtimer.init(16)

        if xnet.get_stats().channel_count == nil then
            check('xnet.get_stats() reports channel_count', false, 'missing')
            return finish()
        end
        collectgarbage('collect')
        run(channels())

        xtimer.add(30000, function()
            out('FAIL watchdog: the test did not finish within 30s\n')
            xthread.stop(1)
        end, 1)
    end,
    __uninit = function() xnet.uninit() end,
}
