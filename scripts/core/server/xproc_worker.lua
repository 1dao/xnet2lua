-- xproc_worker.lua — the blocking half of the xproc pool.
--
-- Runs on a dedicated xthread worker. The caller (any thread, usually MAIN)
-- reaches it with xthread.rpc(tid, 'proc_exec', timeout, spec); the blocking
-- os.execute lives HERE so it never stalls an event loop. One worker runs one
-- command at a time — concurrency comes from running several of these threads
-- (see xproc.lua's pool).
--
-- WHY os.execute AND NOT io.popen
-- -------------------------------
-- io.popen gives a pipe, and on Windows that pipe hands back console-codepage
-- (GBK) bytes: fine for text, fatal for a git packfile. os.execute + shell
-- redirection writes the child's stdout straight to a file the OS never
-- transcodes, and we read that file back in binary mode. It also gives us
-- stdin-from-a-file for free, which io.popen cannot do at all from Lua — that
-- is the whole reason git smart-HTTP is reachable from here without a new C
-- binding.
--
-- The cost is that the child's stdout must land on disk before we can look at
-- it: no streaming, and a temp file per call. A real xproc C binding with
-- pollable pipes is still the endgame; this module's API is shaped so that
-- swapping the implementation underneath it changes nothing for callers.
--
-- SPEC (table, msgpack'd across the thread boundary):
--   argv           {string,...}  argv[1] is the program; quoted per-platform
--   cmd            string        raw shell command; use INSTEAD of argv
--   cwd            string?       run here (cd /d on Windows, cd on POSIX)
--   env            {K=V,...}?    prepended as shell assignments
--   stdin_file     string?       redirect stdin from this file
--   stdout_file    string?       redirect stdout here (kept; caller owns it)
--   stderr_file    string?       redirect stderr here (kept; caller owns it)
--   capture_stdout bool?         read stdout back into the reply
--   capture_stderr bool?         read stderr back into the reply (default true)
--   max_capture    number?       cap on each captured stream (default 8 MiB)
--   timeout_ms     number?       opt-in watchdog; 0/absent = no limit
--   tmp_dir        string?       where scratch files go (default: cwd)
--
-- REPLY (table):
--   { exit_code, stdout, stderr, stdout_file, stderr_file, timed_out, err }
--
-- The handler never raises for a non-zero exit — a failed child is a normal
-- result. It raises only when the spec itself is unusable.

local router = dofile('scripts/core/share/xrouter.lua')
router.set_log_prefix('XPROC')

local SEP    = package.config:sub(1, 1)
local IS_WIN = (SEP == '\\')

local DEFAULT_MAX_CAPTURE = 8 * 1024 * 1024
local TIMEOUT_EXIT        = 124   -- sentinel: killed by the watchdog
local KILL_GRACE_S        = 5

-- ---------------------------------------------------------------------------
-- Argument quoting
-- ---------------------------------------------------------------------------

-- Both quoters leave an argument alone when it is made only of characters no
-- shell touches. That is not cosmetic: cmd.exe stops recognising its own
-- switches once they are quoted, so `cmd "/c" ...` tries to execute a program
-- called /c and fails with "The system cannot find the path specified."
local SAFE_POSIX = '^[A-Za-z0-9_@%%+=:,./-]+$'
local SAFE_WIN   = '^[A-Za-z0-9_@+=:,./\\-]+$'

-- POSIX: single-quote everything, closing and reopening around embedded
-- quotes. No character survives interpretation inside '...' except ' itself.
local function quote_posix(s)
    s = tostring(s)
    if s ~= '' and s:match(SAFE_POSIX) then return s end
    return "'" .. s:gsub("'", "'\\''") .. "'"
end

-- Windows: the MS CRT rule — a run of backslashes is doubled only when it is
-- immediately followed by the closing quote or by an embedded quote; an
-- embedded quote becomes \". Wrapping in double quotes also neutralises
-- cmd.exe's &, |, <, >, ^ and spaces.
--
-- WHAT THIS DOES NOT COVER: %VAR% expansion. cmd.exe expands it even inside
-- double quotes and `cmd /c` offers no escape, so an argument holding a literal
-- % is not safely representable here. Callers that build arguments out of user
-- input (repository names, ref names) must reject % upstream.
local function quote_win(s)
    s = tostring(s)
    if s ~= '' and s:match(SAFE_WIN) then return s end
    local out, backslashes = {}, 0
    for i = 1, #s do
        local ch = s:sub(i, i)
        if ch == '\\' then
            backslashes = backslashes + 1
            out[#out + 1] = ch
        elseif ch == '"' then
            out[#out + 1] = string.rep('\\', backslashes + 1) .. '"'
            backslashes = 0
        else
            backslashes = 0
            out[#out + 1] = ch
        end
    end
    return '"' .. table.concat(out) .. string.rep('\\', backslashes) .. '"'
end

local quote = IS_WIN and quote_win or quote_posix

-- ---------------------------------------------------------------------------
-- Small file helpers (binary, so a packfile survives the round trip)
-- ---------------------------------------------------------------------------

local function read_binary(path, max_bytes)
    if not path then return nil end
    local f = io.open(path, 'rb')
    if not f then return nil end
    local data = f:read(max_bytes or DEFAULT_MAX_CAPTURE) or ''
    f:close()
    return data
end

local function remove_quietly(path)
    if path then pcall(os.remove, path) end
end

-- ---------------------------------------------------------------------------
-- Process working directory
--
-- The shell resolves `< in` and `> out` AFTER the `cd` we prepend for spec.cwd,
-- so a redirect path written relative to the process — which is how every other
-- path in this codebase is written — would silently resolve inside the CHILD's
-- directory instead, and the caller would get an empty file with no error worth
-- reading. We rewrite relative redirect paths against the process cwd so that
-- never happens.
--
-- Lua has no getcwd, so we ask the shell once and cache it. The probe runs with
-- no `cd` of its own, so it reports exactly the directory we want; it lands in
-- the OS temp directory because the process cwd is not guaranteed writable.
-- ---------------------------------------------------------------------------
local proc_cwd = nil
local function process_cwd()
    if proc_cwd then return proc_cwd end
    -- xutils.cwd() is a C binding; see xlua/lua_xutils.c.
    --
    -- This used to shell out: `pwd` (or `cd`) redirected into a probe file in
    -- the temp directory, read back and unlinked. A process, a file, a read and
    -- an unlink for a value the OS hands over for free — and on Windows the
    -- answer arrived in whatever console code page the process had inherited,
    -- so a non-ASCII install path could come back mangled and every redirect
    -- resolved against it would then name a path that does not exist.
    local xutils = require('xutils')
    proc_cwd = xutils.cwd() or '.'
    return proc_cwd
end

local function is_absolute(p)
    if IS_WIN then
        return p:match('^%a:[/\\]') ~= nil or p:match('^[/\\][/\\]') ~= nil
    end
    return p:sub(1, 1) == '/'
end

local function resolve_against_process(p)
    if not p or p == '' or is_absolute(p) then return p end
    return process_cwd() .. SEP .. p
end

local seq = 0
local function scratch_path(tmp_dir, suffix)
    seq = seq + 1
    local dir = tmp_dir or '.'
    return string.format('%s%sxproc_%d_%d_%s', dir, SEP,
        math.floor(os.time()), seq, suffix)
end

-- ---------------------------------------------------------------------------
-- Command assembly
-- ---------------------------------------------------------------------------

local function build_command(spec)
    local parts = {}

    -- ORDER: cwd, then env, then the command.
    --
    -- The env block MUST come after the `cd`, and this is not cosmetic. A POSIX
    -- assignment prefix applies to the single command it precedes, and `cd` is a
    -- regular builtin, so `VAR=x cd /repo && git ...` sets VAR for `cd` alone —
    -- it does not persist, and git never sees it. That silently dropped
    -- GIT_PROTOCOL on Linux, degrading every clone from protocol v2 to v0 with
    -- nothing logged. Verified: `sh -c "V=hello cd /tmp && sh -c 'echo [\$V]'"`
    -- prints [], the same line with the prefix after the && prints [hello].
    --
    -- Windows works either way (`set` mutates the shell), so putting cwd first
    -- is correct on both.
    if spec.cwd then
        -- `cd /d` wants backslashes; a forward-slash path reaches it as a
        -- relative-looking argument and fails with "The system cannot find the
        -- path specified" — with the failure landing on cd, not on the command
        -- the caller was trying to run.
        local dir = IS_WIN and (spec.cwd:gsub('/', '\\')) or spec.cwd
        parts[#parts + 1] = IS_WIN
            and string.format('cd /d %s &&', quote_win(dir))
            or  string.format('cd %s &&', quote_posix(dir))
    end

    if spec.env then
        -- Sorted so the command string is deterministic: it goes into logs and,
        -- under the watchdog, into a PowerShell payload we have to reason about.
        local keys = {}
        for k in pairs(spec.env) do keys[#keys + 1] = k end
        table.sort(keys)
        for _, k in ipairs(keys) do
            if IS_WIN then
                parts[#parts + 1] = string.format('set %s=%s&&', k, tostring(spec.env[k]))
            else
                parts[#parts + 1] = string.format('%s=%s', k, quote_posix(spec.env[k]))
            end
        end
    end

    if spec.cmd then
        parts[#parts + 1] = spec.cmd
    else
        for _, a in ipairs(spec.argv) do parts[#parts + 1] = quote(a) end
    end

    if spec.stdin_file then parts[#parts + 1] = '< '  .. quote(spec.stdin_file) end
    if spec._stdout    then parts[#parts + 1] = '> '  .. quote(spec._stdout)    end
    if spec._stderr    then parts[#parts + 1] = '2> ' .. quote(spec._stderr)    end

    return table.concat(parts, ' ')
end

-- Which coreutils timeout this host has, probed once. GNU coreutils installs it
-- as `timeout` on Linux; on macOS it arrives via homebrew coreutils as
-- `gtimeout`, and a stripped container may have neither. false = looked, found
-- nothing.
local timeout_bin = nil
local warned_no_timeout = false

local function posix_timeout_bin()
    if timeout_bin ~= nil then return timeout_bin end
    for _, name in ipairs({ 'timeout', 'gtimeout' }) do
        if os.execute('command -v ' .. name .. ' >/dev/null 2>&1') then
            timeout_bin = name
            return timeout_bin
        end
    end
    timeout_bin = false
    return false
end

-- Opt-in watchdog. os.execute has no kill of its own, so a child that never
-- exits wedges this worker (and only this worker) forever. Wrapping bounds the
-- runtime and kills the process TREE, which is what actually frees us.
--   * Windows: a PowerShell host starts the command through cmd.exe, waits,
--     then `taskkill /T /F`. It costs a PowerShell start-up (~200ms) per call,
--     which is why it is off unless the caller asks for it.
--   * POSIX: GNU `timeout` (or `gtimeout` on macOS) with a SIGKILL grace. If
--     neither is present the command runs unwrapped and a warning is logged
--     once — the wedge risk returns on that host only.
-- Either way exit code TIMEOUT_EXIT means "we killed it".
local function wrap_timeout(inner, timeout_ms)
    local ms = tonumber(timeout_ms) or 0
    if ms <= 0 then return inner, nil end
    local secs = math.max(1, math.floor(ms / 1000))

    if IS_WIN then
        local xutils = require('xutils')
        -- The command travels as base64 so neither cmd.exe nor PowerShell gets
        -- a second chance to reinterpret the quoting we just built.
        local b64 = xutils.base64_encode(inner)
        local ps = string.format(
            "$c=[Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('%s'));" ..
            "$p=Start-Process cmd.exe -ArgumentList '/c',$c -PassThru -NoNewWindow;" ..
            "if(-not $p.WaitForExit(%d)){taskkill /T /F /PID $p.Id *> $null;exit %d};" ..
            "exit $p.ExitCode", b64, secs * 1000, TIMEOUT_EXIT)
        return string.format('powershell -NoProfile -NonInteractive -Command "%s"',
            (ps:gsub('"', '\\"'))), secs
    end

    local bin = posix_timeout_bin()
    if not bin then
        -- Graceful degrade: run unwrapped rather than fail the command. The
        -- wedge risk returns on this host only, and saying so once beats
        -- either failing every timed command or staying silent about it.
        if not warned_no_timeout then
            warned_no_timeout = true
            xthread.log_warn('[XPROC] neither timeout nor gtimeout is on PATH; ' ..
                'timeout_ms cannot be enforced on this host')
        end
        return inner, nil
    end
    return string.format('%s -k %d %d sh -c %s',
        bin, KILL_GRACE_S, secs, quote_posix(inner)), secs
end

-- ---------------------------------------------------------------------------
-- Handlers
-- ---------------------------------------------------------------------------

router.register('proc_exec', function(spec)
    if type(spec) ~= 'table' then error('xproc: spec must be a table', 0) end
    if not spec.cmd and type(spec.argv) ~= 'table' then
        error('xproc: spec needs argv or cmd', 0)
    end
    if spec.argv and #spec.argv == 0 then error('xproc: argv is empty', 0) end

    local max_capture = tonumber(spec.max_capture) or DEFAULT_MAX_CAPTURE
    -- stderr is captured by default: it is small, and it is the only place a
    -- failing child explains itself once its stdout has gone to a file.
    local capture_stderr = spec.capture_stderr ~= false

    -- Files the caller named are the caller's to keep and delete. Files we
    -- invent are ours, and we delete them before replying.
    local own_stdout, own_stderr = nil, nil
    spec._stdout = spec.stdout_file
    if not spec._stdout and spec.capture_stdout then
        own_stdout = scratch_path(spec.tmp_dir, 'out.bin')
        spec._stdout = own_stdout
    end
    spec._stderr = spec.stderr_file
    if not spec._stderr and capture_stderr then
        own_stderr = scratch_path(spec.tmp_dir, 'err.txt')
        spec._stderr = own_stderr
    end

    -- Redirects are process-relative by contract; the `cd` we are about to
    -- prepend would otherwise re-root them under the child's directory.
    if spec.cwd then
        spec.stdin_file = resolve_against_process(spec.stdin_file)
        spec._stdout    = resolve_against_process(spec._stdout)
        spec._stderr    = resolve_against_process(spec._stderr)
    end

    local inner = build_command(spec)
    local full, secs = wrap_timeout(inner, spec.timeout_ms)
    -- cmd.exe drops the outermost quote pair of a `/c` string and treats the
    -- rest verbatim; adding a pair keeps every quote we generated intact even
    -- when the program path itself is quoted.
    if IS_WIN then full = '"' .. full .. '"' end

    local ok, _how, code = os.execute(full)
    local exit_code = tonumber(code) or (ok and 0 or 1)
    local timed_out = (secs ~= nil and exit_code == TIMEOUT_EXIT)

    local res = {
        exit_code   = exit_code,
        stdout_file = spec.stdout_file,
        stderr_file = spec.stderr_file,
        timed_out   = timed_out or nil,
    }
    if spec.capture_stdout then
        res.stdout = read_binary(spec._stdout, max_capture) or ''
    end
    if capture_stderr then
        res.stderr = read_binary(spec._stderr, max_capture) or ''
    end
    if timed_out then
        res.err = 'timeout'
    elseif exit_code ~= 0 then
        res.err = 'exit ' .. tostring(exit_code)
    end

    remove_quietly(own_stdout)
    remove_quietly(own_stderr)
    return res
end)

-- Cheap liveness probe: lets xproc.setup() confirm a worker is really up
-- before the first real command rides on it.
router.register('proc_ping', function() return 'pong' end)

return {
    __thread_handle = router.handle,
}
