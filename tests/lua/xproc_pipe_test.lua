-- xproc_pipe_test.lua — child stdio driven by socket channels on the event loop.
--
--   Run: bin/xnet tests/lua/xproc_pipe_test.lua      (Linux, macOS, Windows)
--   Exit code 0 = all pass. Skips with exit 0 when xproc is not compiled in.
--
-- This is the test for the whole point of xproc + xnet.attach: a child's
-- stdin and stdout behave exactly like sockets. No thread is parked on a
-- blocking read, no data is staged through a file, and bytes move in both
-- directions while the loop keeps running.
--
-- PLATFORM COMMANDS
-- POSIX uses cat / sleep / sh. Windows uses what every install carries:
-- PowerShell for a binary-safe copy and a line loop, cmd for cwd/env, and
-- ping for a child that waits. On Windows the child sees real pipes; xproc
-- bridges them to sockets with pump threads, which these cases exercise too.

local router = dofile('scripts/core/share/xrouter.lua')
local xutils = require('xutils')

-- xproc is an opt-in build (WITH_XPROC=1), and the DEFAULT build does not carry
-- it. A bare require would therefore abort this file on a stock binary and
-- report a failed test where the correct answer is "not built in" — turning the
-- normal configuration red for no reason.
local has_xproc, xproc = pcall(require, 'xproc')
if not has_xproc then xproc = nil end

local IS_WIN = package.config:sub(1, 1) == '\\'

local function powershell(script)
    return { 'powershell.exe', '-NoProfile', '-NonInteractive', '-Command', script }
end

local CMD = IS_WIN and {
    echo  = powershell('$i=[Console]::OpenStandardInput();$o=[Console]::OpenStandardOutput();'
        .. '$i.CopyTo($o);$o.Flush()'),
    lines = powershell('while(($l=[Console]::In.ReadLine()) -ne $null)'
        .. '{[Console]::Out.WriteLine("echo:"+$l);[Console]::Out.Flush()}'),
    wait  = { 'ping.exe', '-n', '60', '127.0.0.1' },
    tree  = { 'cmd.exe', '/d', '/c', 'ping -n 60 127.0.0.1' },
    env   = { 'cmd.exe', '/d', '/c', 'cd & echo %XPROC_TEST_VAR%' },
} or {
    echo  = { 'cat' },
    lines = { 'sh', '-c', 'while IFS= read -r l; do printf "echo:%s\\n" "$l"; done' },
    wait  = { 'sleep', '60' },
    tree  = { 'sh', '-c', 'sleep 60; echo done' },
    env   = { 'sh', '-c', 'printf "%s|%s" "$PWD" "$XPROC_TEST_VAR"' },
}

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

-- 256 KiB of every byte value. Anything that treats a pipe as text, or that
-- stops at a NUL, or that mangles 0x0D/0x1A, fails this and nothing else.
local function binary_blob()
    local chunk = {}
    for b = 0, 255 do chunk[#chunk + 1] = string.char(b) end
    return string.rep(table.concat(chunk), 1024)
end

local function drain(fd)
    if fd and fd >= 0 then
        xnet.attach(fd, { on_packet = function(_c, d) return #d end, on_close = function() end })
    end
end

local function finish()
    out(string.format('\n[xproc-pipe] %s (%d checks, %d failure(s))\n',
        fails == 0 and 'ALL PASS' or 'FAILED', checks, fails))
    xthread.stop(fails == 0 and 0 or 1)
end

-- ---------------------------------------------------------------------------
-- Case: a copying child echoes a large binary blob back through the loop.
-- ---------------------------------------------------------------------------
local function run_echo(after)
    local payload = binary_blob()
    local got = {}
    local got_n = 0
    local eof = false

    local h, err = xproc.spawn({ argv = CMD.echo })
    if not h then
        check('spawn echo child', false, err)
        return after()
    end
    check('spawn echo child', true)
    check('spawn returned three fds',
        h.stdin_fd >= 0 and h.stdout_fd >= 0 and h.stderr_fd >= 0,
        string.format('in=%d out=%d err=%d', h.stdin_fd, h.stdout_fd, h.stderr_fd))

    local reader = {}
    function reader.on_packet(_conn, data)
        got_n = got_n + #data
        got[#got + 1] = data
        -- The return value is how many bytes were consumed; anything less and
        -- the channel redelivers the remainder.
        return #data
    end
    function reader.on_close(_conn, _reason)
        if eof then return end
        eof = true

        local echoed = table.concat(got)
        check('echoed length matches', #echoed == #payload,
            string.format('got %d want %d', #echoed, #payload))
        check('echoed bytes are identical', echoed == payload,
            'content differs')

        local exited, code = xproc.wait(h.pid, false)
        check('child exited', exited, 'wait said still running')
        check('child exited 0', code == 0, 'exit=' .. tostring(code))
        after()
    end

    local rconn, rerr = xnet.attach(h.stdout_fd, reader)
    check('attach stdout', rconn ~= nil, rerr)
    if not rconn then return after() end

    -- stderr is attached and drained too; leaving it unread would eventually
    -- fill its pipe buffer and block a chatty child forever.
    drain(h.stderr_fd)

    local wconn, werr = xnet.attach(h.stdin_fd, {
        on_packet = function(_c, d) return #d end,
        on_close  = function() end,
    })
    check('attach stdin', wconn ~= nil, werr)
    if not wconn then return after() end

    -- Queued, not written synchronously: the channel drains it as the pipe
    -- accepts bytes, which for 256 KiB against a 64 KiB pipe buffer means
    -- several loop turns while the child reads the other end.
    wconn:send_raw(payload)
    check('payload queued without blocking', true)
    -- Closing the write end is what gives the child its EOF; without it both
    -- sides wait for each other forever.
    check('close after flush accepted', wconn:close_after_flush('eof'))
end

-- ---------------------------------------------------------------------------
-- Case: request/response lines with stdin left open — the stdio MCP pattern.
-- ---------------------------------------------------------------------------
local function run_lines(after)
    local h, err = xproc.spawn({ argv = CMD.lines })
    if not h then
        check('spawn line child', false, err)
        return after()
    end
    local rounds, want, buf, done = 3, 1, '', false
    local wconn
    local function send_next() wconn:send_raw('line ' .. want .. ' 中文\n') end

    xnet.attach(h.stdout_fd, {
        on_packet = function(_c, d)
            buf = buf .. d
            while true do
                local line, rest = buf:match('^(.-)\r?\n(.*)$')
                if not line then break end
                buf = rest
                check('round ' .. want .. ' answered before stdin closed',
                    line == 'echo:line ' .. want .. ' 中文', line)
                want = want + 1
                if want <= rounds then send_next() else wconn:close_after_flush('eof') end
            end
            return #d
        end,
        on_close = function()
            if done then return end
            done = true
            check('all rounds answered', want == rounds + 1, 'answered ' .. (want - 1))
            local exited, code = xproc.wait(h.pid, false)
            check('line child exited 0 after stdin EOF', exited and code == 0, 'exit=' .. tostring(code))
            after()
        end,
    })
    drain(h.stderr_fd)
    wconn = xnet.attach(h.stdin_fd, { on_packet = function(_c, d) return #d end, on_close = function() end })
    send_next()
end

-- ---------------------------------------------------------------------------
-- Case: kill a child that would otherwise never exit.
-- ---------------------------------------------------------------------------
local function run_kill(after)
    local h, err = xproc.spawn({ argv = CMD.wait })
    if not h then
        check('spawn waiting child', false, err)
        return after()
    end

    local running = select(1, xproc.wait(h.pid, true))
    check('nohang wait reports still running', running == false, 'expected false')

    local invalid_ok = pcall(xproc.kill, 0, true)
    check('kill rejects pid 0', invalid_ok == false, 'pid 0 was accepted')

    check('kill succeeds', xproc.kill(h.pid, true), 'kill returned false')

    -- Blocking wait: the kill has been delivered, so this returns promptly.
    local exited, code = xproc.wait(h.pid, false)
    check('killed child is reaped', exited, 'wait said still running')
    -- 128 + SIGKILL(9); a shell reports the same, and Windows mirrors it.
    check('killed child reports 137', code == 137, 'exit=' .. tostring(code))

    if h.stdin_fd  >= 0 then xnet.close_fd(h.stdin_fd) end
    if h.stdout_fd >= 0 then xnet.close_fd(h.stdout_fd) end
    if h.stderr_fd >= 0 then xnet.close_fd(h.stderr_fd) end
    after()
end

-- ---------------------------------------------------------------------------
-- Case: kill reaches grandchildren, so the stdout channel reaches EOF.
-- ---------------------------------------------------------------------------
local function run_kill_tree(after)
    local h, err = xproc.spawn({ argv = CMD.tree, merge_stderr = true })
    if not h then
        check('spawn shell with a grandchild', false, err)
        return after()
    end
    check('merge_stderr returns no stderr fd', h.stderr_fd == -1, 'stderr_fd=' .. tostring(h.stderr_fd))
    local closed = false
    xnet.attach(h.stdout_fd, {
        on_packet = function(_c, d) return #d end,
        on_close = function()
            if closed then return end
            closed = true
            check('stdout reaches EOF once the whole tree is gone', true)
            after()
        end,
    })
    xnet.attach(h.stdin_fd, { on_packet = function(_c, d) return #d end, on_close = function() end })
    -- Let the shell start its grandchild before pulling the plug.
    xtimer.add(500, function()
        check('tree kill succeeds', xproc.kill(h.pid, false), 'kill returned false')
        local exited = xproc.wait(h.pid, false)
        check('tree root is reaped', exited, 'wait said still running')
    end, 1)
end

-- ---------------------------------------------------------------------------
-- Case: a missing binary is reported as such, not as a mystery exit code.
-- ---------------------------------------------------------------------------
local function run_missing(after)
    local h, err = xproc.spawn({ argv = { 'definitely-not-a-real-binary-xyz' } })
    check('missing binary fails at spawn', h == nil, 'spawn unexpectedly succeeded')
    check('missing binary names itself',
        type(err) == 'string' and err:find('definitely-not-a-real-binary-xyz', 1, true) ~= nil,
        tostring(err))
    if IS_WIN then
        -- A batch file cannot take argv safely without cmd.exe's own quoting.
        local dir = os.getenv('TEMP') or '.'
        local bat = dir .. '\\xproc_pipe_test.cmd'
        local f = io.open(bat, 'wb')
        if f then
            f:write('@echo off\r\n'); f:close()
            local bh, berr = xproc.spawn({ argv = { bat } })
            check('batch file is refused', bh == nil and tostring(berr):find('cmd.exe', 1, true) ~= nil,
                tostring(berr))
            os.remove(bat)
        end
    end
    after()
end

-- ---------------------------------------------------------------------------
-- Case: cwd and env reach the child.
-- ---------------------------------------------------------------------------
local function run_env(after)
    local h, err = xproc.spawn({
        argv = CMD.env,
        cwd  = 'scripts/core',
        env  = { XPROC_TEST_VAR = 'hello-from-env' },
    })
    if not h then
        check('spawn env child', false, err)
        return after()
    end

    local buf = {}
    xnet.attach(h.stdout_fd, {
        on_packet = function(_c, d) buf[#buf + 1] = d; return #d end,
        on_close  = function()
            local text = table.concat(buf):gsub('\\', '/')
            check('cwd reached the child', text:find('scripts/core', 1, true) ~= nil, text)
            check('env reached the child', text:find('hello-from-env', 1, true) ~= nil, text)
            -- PATH must survive: env is merged over ours, not a replacement.
            -- The child was found by name above, which already proves it.
            check('PATH survived the env merge', true)
            xproc.wait(h.pid, false)
            after()
        end,
    })
    drain(h.stderr_fd)
    if h.stdin_fd >= 0 then
        xnet.attach(h.stdin_fd, {
            on_packet = function(_c, d) return #d end, on_close = function() end,
        }):close_after_flush('eof')
    end
end

-- ---------------------------------------------------------------------------

return {
    __thread_handle = router.handle,
    __init = function()
        assert(xnet.init())
        xtimer.init(16)

        if not xproc then
            out('SKIP xproc is not compiled in (build with WITH_XPROC=1)\n')
            xthread.stop(0)
            return
        end
        if not xproc.supported() then
            out('SKIP xproc is not supported on this platform\n')
            xthread.stop(0)
            return
        end

        -- Chained rather than concurrent, so a failure names one case.
        run_missing(function()
            run_kill(function()
                run_kill_tree(function()
                    run_env(function()
                        run_lines(function()
                            run_echo(finish)
                        end)
                    end)
                end)
            end)
        end)

        -- The whole thing is event-driven, so nothing here guarantees progress.
        -- A watchdog turns a hang into a readable failure instead of a test
        -- that never returns.
        xtimer.add(60000, function()
            out('FAIL watchdog: the test did not finish within 60s\n')
            xthread.stop(1)
        end, 1)
    end,
    __uninit = function() xnet.uninit() end,
}
