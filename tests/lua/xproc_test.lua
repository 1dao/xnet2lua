-- xproc_test.lua — integration test for the xproc worker pool.
--
-- Not a *_spec: xproc's calls are coroutine RPCs into real worker threads, so
-- this needs a live event loop rather than the synchronous spec harness.
--
--   Run: bin/xnet.exe tests/lua/xproc_test.lua
--   Exit code 0 = all pass. (print goes to the log file; results go to stdout
--   via io.write, so piping this is meaningful.)
--
-- The binary round-trip cases deliberately use `git hash-object --stdin` and
-- `git cat-file blob`: they exercise stdin-from-a-file and stdout-to-a-file with
-- data that must survive byte-for-byte, which is exactly the property git
-- smart-HTTP depends on. They are skipped when git is not on PATH.

local router = dofile('scripts/core/share/xrouter.lua')
local xproc  = dofile('scripts/core/server/xproc.lua')
local xfs    = dofile('scripts/core/share/xfs.lua')
local xutils = require('xutils')

local IS_WIN = (package.config:sub(1, 1) == '\\')
local TMP    = 'tmp/xproc_test'

local fails = 0
local function out(s) io.write(s); io.flush() end
local function check(name, cond, detail)
    if cond then
        out('PASS ' .. name .. '\n')
    else
        fails = fails + 1
        out('FAIL ' .. name .. ' :: ' .. tostring(detail) .. '\n')
    end
end
local function trim(s) return (tostring(s or ''):gsub('%s+$', '')) end

-- 64 KiB covering every byte value, including the ones a text-mode pipe or a
-- codepage conversion would corrupt (0x00, 0x0A, 0x0D, 0x1A, 0x80-0xFF).
local function binary_blob()
    local chunk = {}
    for b = 0, 255 do chunk[#chunk + 1] = string.char(b) end
    return string.rep(table.concat(chunk), 256)
end

local function run_tests()
    local ok, err = xproc.selftest()
    check('pool answers ping', ok, err)
    if not ok then xthread.stop(1); return end

    -- 1) argv quoting + stdout capture
    local r = xproc.exec({ argv = { IS_WIN and 'cmd' or 'sh',
                                    IS_WIN and '/c' or '-c',
                                    'echo hello-xproc' },
                           capture_stdout = true })
    check('echo exits 0', r.ok, 'exit=' .. tostring(r.exit_code) .. ' err=' .. tostring(r.err))
    check('echo stdout captured', trim(r.stdout) == 'hello-xproc', trim(r.stdout))

    -- 2) an argument containing spaces must arrive as ONE argument
    local spaced = 'a b  c'
    r = xproc.exec({ argv = { IS_WIN and 'cmd' or 'sh', IS_WIN and '/c' or '-c',
                              'echo ' .. (IS_WIN and ('"' .. spaced .. '"') or ("'" .. spaced .. "'")) },
                     capture_stdout = true })
    check('spaces preserved', trim(r.stdout):find(spaced, 1, true) ~= nil, trim(r.stdout))

    -- 3) non-zero exit is a RESULT, not an error, and stderr comes back with it
    r = xproc.exec({ argv = { IS_WIN and 'cmd' or 'sh', IS_WIN and '/c' or '-c',
                              'echo boom 1>&2 & exit 3' },
                     capture_stdout = true })
    check('nonzero exit reported', r.ok == false and r.exit_code ~= 0,
        'ok=' .. tostring(r.ok) .. ' exit=' .. tostring(r.exit_code))
    check('stderr captured', trim(r.stderr):find('boom', 1, true) ~= nil, trim(r.stderr))

    -- 4) cwd is honoured
    r = xproc.exec({ argv = { IS_WIN and 'cmd' or 'sh', IS_WIN and '/c' or '-c',
                              IS_WIN and 'cd' or 'pwd' },
                     cwd = 'scripts/core', capture_stdout = true })
    check('cwd honoured', trim(r.stdout):lower():find('core', 1, true) ~= nil, trim(r.stdout))

    -- 5) a bad spec raises on the worker and surfaces as a transport failure,
    --    not a crash
    r = xproc.exec({ argv = {} })
    check('empty argv rejected', r.ok == false and r.err ~= nil, tostring(r.err))

    -- ── binary round trip through both redirects ──────────────────────────
    local have_git = xproc.exec({ argv = { 'git', '--version' }, capture_stdout = true }).ok
    if not have_git then
        out('SKIP binary round trip (git not on PATH)\n')
    else
        xfs.mkdirp(TMP)
        local repo = TMP .. '/t.git'
        r = xproc.exec({ argv = { 'git', 'init', '--bare', '-q', repo } })
        check('git init --bare', r.ok, tostring(r.err) .. ' ' .. trim(r.stderr))

        local data = binary_blob()
        check('blob written', xfs.write_file(TMP .. '/in.bin', data) == true, 'write failed')

        -- stdin_file: git reads the blob from the file we redirect in and prints
        -- its object id. We can predict that id independently, so a match proves
        -- every byte arrived intact.
        r = xproc.exec({ argv = { 'git', 'hash-object', '-w', '--stdin' },
                         cwd = repo,
                         stdin_file = TMP .. '/in.bin',
                         capture_stdout = true })
        local got_sha  = trim(r.stdout)
        local want_sha = xutils.sha1_hex('blob ' .. #data .. '\0' .. data)
        check('stdin_file round trip', got_sha == want_sha,
            string.format('got=%s want=%s err=%s', got_sha, want_sha, trim(r.stderr)))

        -- stdout_file: the blob comes back out to a file we then read in binary
        -- mode. This is the packfile path in miniature.
        if got_sha == want_sha then
            local out_path = TMP .. '/out.bin'
            r = xproc.exec({ argv = { 'git', 'cat-file', 'blob', got_sha },
                             cwd = repo,
                             stdout_file = out_path })
            check('git cat-file exits 0', r.ok, tostring(r.err) .. ' ' .. trim(r.stderr))
            local back = xfs.read_file(out_path)
            check('stdout_file byte-identical', back == data,
                string.format('len got=%s want=%d', back and #back or 'nil', #data))
        end
    end

    -- 6) watchdog: a long child is killed and the worker survives it
    local long = IS_WIN and 'ping -n 30 127.0.0.1' or 'sleep 30'
    local t0 = os.time()
    r = xproc.exec({ cmd = long, timeout_ms = 3000, capture_stdout = true })
    local elapsed = os.time() - t0
    check('timeout exit 124', r.exit_code == 124 and r.timed_out == true,
        'exit=' .. tostring(r.exit_code) .. ' timed_out=' .. tostring(r.timed_out))
    check('timeout killed promptly', elapsed < 15, 'elapsed=' .. elapsed .. 's')
    r = xproc.exec({ argv = { IS_WIN and 'cmd' or 'sh', IS_WIN and '/c' or '-c',
                              'echo still-alive' }, capture_stdout = true })
    check('pool survives a timeout', trim(r.stdout) == 'still-alive', trim(r.stdout))

    out(string.format('\n[xproc] %s (%d failure(s))\n',
        fails == 0 and 'ALL PASS' or 'FAILED', fails))
    xthread.stop(fails == 0 and 0 or 1)
end

return {
    __thread_handle = router.handle,
    __init = function()
        local ok, err = xproc.setup({ workers = 3, tmp_dir = TMP })
        if not ok then
            out('xproc.setup failed: ' .. tostring(err) .. '\n')
            xthread.stop(2)
            return
        end
        xfs.mkdirp(TMP)
        local co = coroutine.create(run_tests)
        local rok, rerr = coroutine.resume(co)
        if not rok then
            io.stderr:write('test coroutine error: ' .. tostring(rerr) .. '\n')
            xthread.stop(1)
        end
    end,
}
