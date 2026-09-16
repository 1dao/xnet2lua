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
-- io.popen gives a pipe, and Lua opens it in TEXT mode on Windows: CRLF is
-- rewritten and a literal 0x1A byte ends the stream early, so binary output is
-- silently corrupted. It also cannot feed stdin at all from Lua. os.execute plus
-- shell redirection writes the child's stdout straight to a file the OS never
-- touches, and we read that file back in binary mode; stdin redirection comes
-- free with it.
--
-- The cost is that the child's stdout must land on disk before we can look at
-- it: no streaming, and a temp file per call. The real xproc C binding
-- (require('xproc'), pollable pipes) is the endgame for streaming, but it is
-- POSIX-only — xproc.supported() is false on Windows — so this module stays the
-- portable path. Its API is shaped so swapping the implementation underneath
-- changes nothing for callers.
--
-- SPEC (table, msgpack'd across the thread boundary):
--   argv           {string,...}  argv[1] is the program; quoted per-platform
--   cmd            string        raw shell command; use INSTEAD of argv
--   cwd            string?       run here (cd /d on Windows, cd on POSIX)
--   env            {K=V,...}?    prepended as shell assignments
--   stdin_file     string?       redirect stdin from this file
--   stdout_file    string?       redirect stdout here (kept; caller owns it)
--   stderr_file    string?       redirect stderr here (kept; caller owns it)
--   merge_stderr   bool?         send stderr down the stdout stream (2>&1);
--                                overrides stderr_file / capture_stderr
--   capture_stdout bool?         read stdout back into the reply
--   capture_stderr bool?         read stderr back into the reply (default true,
--                                forced off by merge_stderr)
--   max_capture    number?       cap on each captured stream (default 8 MiB)
--   timeout_ms     number?       opt-in watchdog; 0/absent = no limit
--   tmp_dir        string?       where scratch files go (default: cwd)
--
-- REPLY (table):
--   { exit_code, stdout, stderr, stdout_bytes, stderr_bytes,
--     stdout_file, stderr_file, timed_out, timeout_s, err }
-- stdout_bytes is the stream's FULL size on disk even when max_capture cut the
-- returned string short, so a caller can report an honest "truncated, N total".
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
-- % is not safely representable here. Callers that build arguments out of
-- untrusted input (repository or ref names, a model's search pattern) must
-- reject % before it gets here.
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

-- Returns (data, total_bytes). total_bytes is the file's real size, which is
-- what makes a truncation notice truthful when max_bytes cut `data` short.
local function read_binary(path, max_bytes)
    if not path then return nil, 0 end
    local f = io.open(path, 'rb')
    if not f then return nil, 0 end
    local total = f:seek('end') or 0
    f:seek('set', 0)
    local data = f:read(max_bytes or DEFAULT_MAX_CAPTURE) or ''
    f:close()
    return data, total
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
-- ---------------------------------------------------------------------------
local proc_cwd = nil
local function process_cwd()
    if proc_cwd then return proc_cwd end
    -- xutils.cwd() is a C binding; see xlua/lua_xutils.c. Shelling out for this
    -- (`pwd`/`cd` into a probe file) costs a process, a write, a read and an
    -- unlink for a value the OS hands over free — and on Windows the answer
    -- arrives in the inherited console code page, so a non-ASCII install path
    -- comes back mangled and every redirect resolved against it then names a
    -- path that does not exist.
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

-- The null device is a name the shell resolves itself, not a path. Re-rooting it
-- would turn NUL into C:\...\NUL, which happens to still work on Windows and
-- would quietly stop working the day that quirk does.
local NULL_DEVICE = IS_WIN and 'NUL' or '/dev/null'

local function resolve_against_process(p)
    if not p or p == '' or is_absolute(p) then return p end
    if p == NULL_DEVICE or p:upper() == 'NUL' then return p end
    return process_cwd() .. SEP .. p
end

-- Scratch names carry the worker's thread id AND a tag drawn once at load.
--
-- A <time>_<seq> name — which is what this used to be — is not unique. Every
-- worker starts seq at 0 and they stay in step, so two of them landing in the
-- same os.time() second pick the SAME file, and one command's output surfaces in
-- another's reply. Measured on a pool of 4 before this fix: 30 of 40 concurrent
-- calls got someone else's stdout.
--
-- The tid is what actually makes it deterministic — the pool hands every worker a
-- distinct one, so tid+seq needs no coordination at all: no lock, no shared
-- counter, no boot ordering. The random tag covers the case tid cannot, two xnet
-- PROCESSES sharing a tmp_dir (two instances started from one checkout).
local seq = 0
local my_tid = (xthread.current_id and xthread.current_id()) or 0

-- xnet.random_bytes is the same CSPRNG gitloom's util_rand_hex uses, and it works
-- on a worker thread without xnet.init(). The fallback only has to separate
-- processes, never workers, so a weaker source there is fine.
local function boot_tag()
    local ok, raw = pcall(function() return xnet.random_bytes(4) end)
    if ok and type(raw) == 'string' and #raw == 4 then
        return (require('xutils').hex_encode(raw))
    end
    math.randomseed(os.time() * 1000 + my_tid + math.floor((os.clock() or 0) * 1e6))
    return string.format('%04x%04x', math.random(0, 0xffff), math.random(0, 0xffff))
end
local TAG = boot_tag()

local function scratch_path(tmp_dir, suffix)
    seq = seq + 1
    local dir = tmp_dir or '.'
    return string.format('%s%sxproc_%s_t%d_%d_%s', dir, SEP,
        TAG, my_tid, seq, suffix)
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
    -- it does not persist, and the command never sees it. Windows works either
    -- way (`set` mutates the shell), so putting cwd first is correct on both.
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

    if spec.stdin_file then parts[#parts + 1] = '< ' .. quote(spec.stdin_file) end
    if spec._stdout    then parts[#parts + 1] = '> ' .. quote(spec._stdout)    end
    -- 2>&1 must come AFTER the stdout redirect: it duplicates whatever fd 1 is
    -- at that point. Placed before it, stderr would follow the ORIGINAL stdout.
    if spec.merge_stderr then
        parts[#parts + 1] = '2>&1'
    elseif spec._stderr then
        parts[#parts + 1] = '2> ' .. quote(spec._stderr)
    end

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

-- Build the Windows PowerShell watchdog, base64(UTF-16LE)-encoded for
-- -EncodedCommand so it carries through cmd.exe with zero quoting concerns. The
-- inner command rides inside as its own base64 literal, so the script itself
-- stays pure ASCII and neither shell gets a second chance to reinterpret the
-- quoting we just built.
--
-- Note there is no stdout plumbing here: the inner command already redirects to
-- the caller's files, so the PowerShell host has nothing to relay. That also
-- keeps powershell.exe's own CLIXML progress/error chatter out of the captured
-- output — it goes to OUR stderr, never into the child's stream. (A host that
-- relays the child's bytes down a pipe is exactly how CLIXML ends up mixed into
-- captured output.)
local function win_watchdog(inner, timeout_ms)
    local xutils = require('xutils')
    local ps = table.concat({
        "$ErrorActionPreference='SilentlyContinue';",
        "$ProgressPreference='SilentlyContinue';",
        "$c=[Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('",
            xutils.base64_encode(inner), "'));",
        "$i=New-Object Diagnostics.ProcessStartInfo;",
        "$i.FileName=$env:ComSpec;",
        "$i.Arguments='/d /s /c \"'+$c+'\"';",     -- /s: keep $c verbatim
        "$i.UseShellExecute=$false;",
        "$i.CreateNoWindow=$true;",
        "$p=[Diagnostics.Process]::Start($i);",
        "$done=$p.WaitForExit(", tostring(math.floor(timeout_ms)), ");",
        "if(-not $done){& taskkill /T /F /PID $p.Id 2>$null|Out-Null;",
            "$p.WaitForExit(", tostring(KILL_GRACE_S * 1000), ")|Out-Null};",
        "if($done){exit $p.ExitCode}else{exit ", tostring(TIMEOUT_EXIT), "}",
    })
    -- -EncodedCommand wants base64 of UTF-16LE bytes. The script is pure ASCII,
    -- so UTF-16LE is just each byte followed by a NUL.
    local utf16 = ps:gsub('(.)', '%1\0')
    return 'powershell -NoProfile -NonInteractive -EncodedCommand ' ..
        xutils.base64_encode(utf16)
end

-- Opt-in watchdog. os.execute has no kill of its own, so a child that never
-- exits wedges this worker (and only this worker) forever. Wrapping bounds the
-- runtime and kills the process TREE, which is what actually frees us.
--   * Windows: the PowerShell host above. It costs a PowerShell start-up
--     (~200ms measured on this hardware) per call, which is why it is opt-in.
--   * POSIX: GNU `timeout` (or `gtimeout` on macOS) with a SIGKILL grace. If
--     neither is present the command runs unwrapped and a warning is logged
--     once — the wedge risk returns on that host only.
-- Either way exit code TIMEOUT_EXIT means "we killed it".
local function wrap_timeout(inner, timeout_ms)
    local ms = tonumber(timeout_ms) or 0
    if ms <= 0 then return inner, nil end
    -- ceil, not floor: a 1500ms budget must allow 2s of `timeout` granularity,
    -- and a sub-second budget must not round down to "no limit at all".
    local secs = math.max(1, math.ceil(ms / 1000))

    if IS_WIN then return win_watchdog(inner, ms), secs end

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
    -- failing child explains itself once its stdout has gone to a file. With
    -- merge_stderr there is no separate stream left to capture.
    local capture_stderr = (not spec.merge_stderr) and spec.capture_stderr ~= false

    -- Files the caller named are the caller's to keep and delete. Files we
    -- invent are ours, and we delete them before replying.
    local own_stdout, own_stderr = nil, nil
    spec._stdout = spec.stdout_file
    if not spec._stdout and spec.capture_stdout then
        own_stdout = scratch_path(spec.tmp_dir, 'out.bin')
        spec._stdout = own_stdout
    end
    if not spec.merge_stderr then
        spec._stderr = spec.stderr_file
        if not spec._stderr and capture_stderr then
            own_stderr = scratch_path(spec.tmp_dir, 'err.txt')
            spec._stderr = own_stderr
        end
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
        timeout_s   = timed_out and secs or nil,
    }
    if spec.capture_stdout then
        local data, total = read_binary(spec._stdout, max_capture)
        res.stdout, res.stdout_bytes = data or '', total
    end
    if capture_stderr then
        local data, total = read_binary(spec._stderr, max_capture)
        res.stderr, res.stderr_bytes = data or '', total
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
