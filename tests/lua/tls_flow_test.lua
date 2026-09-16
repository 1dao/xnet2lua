-- tls_flow_test.lua — flow control on a TLS connection, in both directions.
--
--   Run: bin/xnet tests/lua/tls_flow_test.lua      (bin\xnet.exe on Windows)
--   Exit code 0 = all pass. Skips with exit 0 when the build has no HTTPS.
--
-- Both cases here are regressions, and both were invisible below a few MiB —
-- which is why a TLS server could serve a small page perfectly and still be
-- unable to carry a git clone:
--
--   * INBOUND. tls_read_plain drains the socket into inbuf and only then hands
--     it to the handler, so a peer that keeps the socket readable pushes inbuf
--     past max_packet before the handler — which would have consumed every
--     byte — has been called once. The cap used to be checked before the
--     dispatch, so the connection was closed with no reply and the peer saw an
--     empty one. It now bounds UNCONSUMED bytes, which is what it was for.
--
--   * OUTBOUND. send_file_response used to push the whole file into the send
--     queue in one synchronous loop. Everything past max_send was refused, the
--     loop gave up, and the connection was left open holding a truncated body
--     — so a response larger than the queue cap did not fail, it hung.
--
-- The sizes below are deliberately several times the caps, and the caps are
-- deliberately small: the point is to cross them many times over in one test
-- rather than to move a lot of bytes.

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

local HOST      = '127.0.0.1'
local PORT_BULK = 18962
local PORT_CAP  = 18963
local CERT      = 'demo/certs/server.crt'
local KEY       = 'demo/certs/server.key'
local TMPFILE   = 'tls_flow_test.tmp.bin'

local MAX_PACKET   = 64 * 1024        -- server + client inbound cap
local SRV_MAX_SEND = 256 * 1024       -- server out-queue cap
local UPLOAD_SIZE  = 4 * 1024 * 1024  -- 64x the inbound cap
local FILE_SIZE    = 3 * 1024 * 1024  -- 12x the out-queue cap

-- Every byte value, so anything that treats the stream as text or stops at a
-- NUL fails this and nothing else.
local function blob(n)
    local unit = {}
    for b = 0, 255 do unit[#unit + 1] = string.char(b) end
    unit = table.concat(unit)
    return string.sub(string.rep(unit, math.ceil(n / #unit)), 1, n)
end

local function file_readable(path)
    local f = io.open(path, 'rb')
    if not f then return false end
    f:close()
    return true
end

local upload_payload = nil
local file_payload = nil

local function finish()
    os.remove(TMPFILE)
    out(string.format('\n[tls-flow] %s (%d checks, %d failure(s))\n',
        fails == 0 and 'ALL PASS' or 'FAILED', checks, fails))
    xthread.stop(fails == 0 and 0 or 1)
end

-- ---------------------------------------------------------------------------
-- Case 1: an upload far larger than max_packet, answered by a file response far
-- larger than max_send, on a connection the server then closes after flush.
--
-- One connection covers all three because each depends on the one before it:
-- the response only happens if the whole upload arrived, and the tail of the
-- response only arrives if close_after_flush waits for the file rather than
-- for the queue.
-- ---------------------------------------------------------------------------
local function run_bulk(after)
    local header = 'HTTP/1.1 200 OK\r\nContent-Length: ' .. FILE_SIZE .. '\r\n\r\n'
    local expect_reply = header .. file_payload

    local srv_got, srv_n = {}, 0
    local srv_replied = false
    local cli_got, cli_n = {}, 0
    local cli_closed = false
    local listener = nil

    local server = {}
    function server.on_packet(conn, data)
        srv_got[#srv_got + 1] = data
        srv_n = srv_n + #data
        if not srv_replied and srv_n >= UPLOAD_SIZE then
            srv_replied = true
            check('server received the whole upload past max_packet',
                table.concat(srv_got) == upload_payload,
                string.format('%d of %d byte(s)', srv_n, UPLOAD_SIZE))

            local ok = conn:send_file_response(header, TMPFILE)
            check('send_file_response accepts a file larger than max_send', ok == true,
                tostring(ok))
            -- Must not truncate the body: the file is still draining here.
            conn:close_after_flush('done')
        end
        return #data
    end

    local client = {}
    function client.on_connect(conn)
        local ok = conn:send_raw(upload_payload)
        check('client queued the upload', ok == true, tostring(ok))
    end
    function client.on_packet(_conn, data)
        cli_got[#cli_got + 1] = data
        cli_n = cli_n + #data
        return #data
    end
    function client.on_close(_conn, _reason)
        if cli_closed then return end
        cli_closed = true
        local got = table.concat(cli_got)
        check('client received the whole file response',
            #got == #expect_reply,
            string.format('%d of %d byte(s)', #got, #expect_reply))
        check('the file response is byte-identical', got == expect_reply,
            'content differs')
        if listener then listener:close() end
        after()
    end

    listener = xnet.listen_fd(HOST, PORT_BULK, {
        on_accept = function(_, fd, ip, port)
            local conn, err = xnet.attach_tls(fd, server, ip, port, {
                cert_file  = CERT,
                key_file   = KEY,
                max_packet = MAX_PACKET,
                max_send   = SRV_MAX_SEND,
            })
            if not conn then
                check('server attach_tls', false, err)
                return false
            end
            return true
        end,
    })
    if not listener then
        check('listen on ' .. PORT_BULK, false, 'listen failed')
        return after()
    end

    local conn, cerr = xnet.connect_tls(HOST, PORT_BULK, client, {
        verify      = false,
        server_name = 'localhost',
        max_packet  = MAX_PACKET,
    })
    check('client connect_tls', conn ~= nil, cerr)
    if not conn then
        listener:close()
        return after()
    end
end

-- ---------------------------------------------------------------------------
-- Case 2: max_packet still bounds a peer that sends a frame nobody consumes.
--
-- The inbound fix moves the ceiling; it must not remove it. A handler that
-- consumes nothing is the shape that used to be conflated with a fast one, and
-- it is the one the cap actually exists for.
-- ---------------------------------------------------------------------------
local function run_cap(after)
    local CAP = 32 * 1024
    local closed_reason = nil
    local listener = nil
    local done = false

    local function settle()
        if done then return end
        done = true
        check('an unconsumed frame past max_packet still closes the connection',
            closed_reason ~= nil, 'the connection stayed open')
        if listener then listener:close() end
        after()
    end

    local server = {}
    function server.on_packet(_conn, _data)
        return 0          -- consumes nothing, ever
    end

    local client = {}
    function client.on_connect(conn)
        conn:send_raw(blob(CAP * 4))
    end
    function client.on_packet(_conn, data) return #data end
    function client.on_close(_conn, reason)
        closed_reason = reason or 'closed'
        settle()
    end

    listener = xnet.listen_fd(HOST, PORT_CAP, {
        on_accept = function(_, fd, ip, port)
            local conn = xnet.attach_tls(fd, server, ip, port, {
                cert_file  = CERT,
                key_file   = KEY,
                max_packet = CAP,
            })
            return conn ~= nil
        end,
    })
    if not listener then
        check('listen on ' .. PORT_CAP, false, 'listen failed')
        return after()
    end

    local conn, cerr = xnet.connect_tls(HOST, PORT_CAP, client, {
        verify = false, server_name = 'localhost',
    })
    if not conn then
        check('client connect_tls (cap case)', false, cerr)
        listener:close()
        return after()
    end

    -- A peer that is refused may be dropped without a TLS alert reaching us as
    -- an on_close, depending on how the reset lands; settle on a deadline too
    -- so the case reports rather than hangs.
    xtimer.add(5000, settle, 1)
end

return {
    __thread_handle = router.handle,
    __init = function()
        assert(xnet.init())
        xtimer.init(16)

        if type(xnet.attach_tls) ~= 'function' then
            out('SKIP this build has no HTTPS (build with WITH_HTTPS=1)\n')
            xthread.stop(0)
            return
        end
        if not (file_readable(CERT) and file_readable(KEY)) then
            out('SKIP ' .. CERT .. ' / ' .. KEY .. ' not found\n')
            xthread.stop(0)
            return
        end

        upload_payload = blob(UPLOAD_SIZE)
        file_payload = blob(FILE_SIZE)
        local f = io.open(TMPFILE, 'wb')
        if not f then
            out('SKIP cannot write ' .. TMPFILE .. '\n')
            xthread.stop(0)
            return
        end
        f:write(file_payload)
        f:close()

        -- Chained rather than concurrent, so a failure names one case.
        run_bulk(function()
            run_cap(finish)
        end)

        -- Event-driven, so nothing above guarantees progress. The watchdog is
        -- what turns the exact hang this test is about into a readable failure.
        xtimer.add(60000, function()
            out('FAIL watchdog: the test did not finish within 60s\n')
            os.remove(TMPFILE)
            xthread.stop(1)
        end, 1)
    end,
    __uninit = function() xnet.uninit() end,
}
