-- xagent/proc/proc_worker.lua — subprocess worker thread.
--
-- Runs on a dedicated xthread worker (xthread.IO). The main thread (agent
-- coroutine) reaches it via xthread.rpc(IO, 'proc_run', rpc_timeout, cmd, cwd,
-- cmd_timeout_ms); the blocking io.popen lives HERE so it never stalls the main
-- event loop. stdout and stderr are merged; the handler returns
-- (output, exit_code, err).
--
-- TIMEOUT / KILL: io.popen has no kill of its own — f:read('*a') blocks until
-- the pipe reaches EOF, i.e. until every process holding the write end has
-- exited. A hung command would therefore wedge this single, serial worker
-- forever, and *every* later command (Bash AND Grep both ride this worker)
-- would then fail with "rpc timeout". To prevent that, each command runs inside
-- a watchdog that bounds its runtime and kills the whole process TREE on
-- timeout, so the pipe closes and the worker frees itself:
--   * Windows: a PowerShell host launches the command via cmd.exe, waits up to
--     cmd_timeout, then `taskkill /T /F` (whole tree). Exit 124 on timeout.
--   * Linux/macOS: GNU `timeout` (or `gtimeout`, common on macOS via coreutils)
--     with a SIGKILL grace; exit 124 on timeout. If neither binary is present
--     the command runs unwrapped (graceful degrade — the wedge risk returns on
--     that host only).
-- Caveat (POSIX): `timeout` signals its direct child, so a command that leaves a
-- surviving backgrounded grandchild can still hold the pipe open; `taskkill /T`
-- has no such gap. The real fix is the xproc C binding (pollable pipes + kill) —
-- see xagent_design_v1.md and [[xnet2lua-no-bidirectional-subprocess]].

local router = dofile('scripts/core/share/xrouter.lua')
local text   = dofile('scripts/core/share/xtext.lua')
local xutils = require('xutils')                          -- base64 for the PS host
router.set_log_prefix('XAGENT-PROC')

local SEP = package.config:sub(1, 1)
local IS_WIN = (SEP == '\\')
local MAX_OUTPUT = 200000   -- worker-side cap; the Bash tool truncates further
local KILL_GRACE_S = 5      -- after the soft timeout, hard-kill within this long
local TIMEOUT_EXIT = 124    -- sentinel exit code meaning "killed by the watchdog"

local function quote_dir(p)
    if IS_WIN then
        return '"' .. p:gsub('/', '\\') .. '"'          -- cmd.exe wants backslashes
    end
    return "'" .. p:gsub("'", "'\\''") .. "'"            -- POSIX single-quote
end

-- The command cmd.exe / sh actually runs: cd into cwd (if any), merge stderr.
local function build_inner(cmd, cwd)
    cmd = tostring(cmd or '')
    if cwd and cwd ~= '' then
        local cd = IS_WIN and ('cd /d ' .. quote_dir(cwd)) or ('cd ' .. quote_dir(cwd))
        cmd = cd .. ' && ' .. cmd
    end
    return cmd .. ' 2>&1'                                 -- merge stderr into stdout
end

-- POSIX single-quote escaping for embedding `s` inside '...'.
local function sh_squote(s)
    return "'" .. tostring(s or ''):gsub("'", "'\\''") .. "'"
end

-- Build the PowerShell watchdog, base64(UTF-16LE)-encoded for `-EncodedCommand`
-- so it carries through cmd.exe with zero quoting concerns. The user command
-- rides inside as its own base64 literal, so the script itself stays pure ASCII.
local function win_watchdog(inner, timeout_ms)
    local inner_b64 = xutils.base64_encode(inner)
    local ps = table.concat({
        "$ErrorActionPreference='SilentlyContinue';",
        "$ProgressPreference='SilentlyContinue';",          -- no "Preparing modules" CLIXML
        "$c=[Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('", inner_b64, "'));",
        "$i=New-Object Diagnostics.ProcessStartInfo;",
        "$i.FileName=$env:ComSpec;",
        "$i.Arguments='/d /s /c \"'+$c+'\"';",            -- /s: keep $c verbatim
        "$i.UseShellExecute=$false;",
        "$i.RedirectStandardOutput=$true;",
        "$i.CreateNoWindow=$true;",
        "$p=[Diagnostics.Process]::Start($i);",
        "$out=[Console]::OpenStandardOutput();",
        -- Copy raw bytes verbatim (no text decode/re-encode) so the caller sees
        -- exactly what the child wrote — identical to a bare io.popen. Async so
        -- the pipe drains while we wait; no deadlock on a full buffer.
        "$t=$p.StandardOutput.BaseStream.CopyToAsync($out);",
        "$done=$p.WaitForExit(", tostring(math.floor(timeout_ms)), ");",
        "if(-not $done){& taskkill /T /F /PID $p.Id 2>$null|Out-Null;",
            "$p.WaitForExit(", tostring(KILL_GRACE_S * 1000), ")|Out-Null};",
        "$t.Wait();$out.Flush();",
        "if($done){exit $p.ExitCode}else{exit ", tostring(TIMEOUT_EXIT), "}",
    })
    -- -EncodedCommand wants base64 of UTF-16LE bytes. The script is pure ASCII,
    -- so UTF-16LE is just each byte followed by a NUL.
    local utf16 = ps:gsub('(.)', '%1\0')
    return 'powershell -NoProfile -NonInteractive -EncodedCommand ' .. xutils.base64_encode(utf16)
end

-- Wrap `inner` so it runs no longer than timeout_ms. Returns (command, secs)
-- where secs is the soft-timeout in seconds (nil when no limit is applied).
local function wrap_timeout(inner, timeout_ms)
    timeout_ms = tonumber(timeout_ms) or 0
    if timeout_ms <= 0 then return inner, nil end
    local secs = math.max(1, math.ceil(timeout_ms / 1000))
    if IS_WIN then
        return win_watchdog(inner, timeout_ms), secs
    end
    -- POSIX: prefer `timeout`, fall back to `gtimeout` (macOS/coreutils), else
    -- run unwrapped. `-k` forces SIGKILL if the command ignores the soft signal.
    local sq = sh_squote(inner)
    local full =
        '__t=$(command -v timeout 2>/dev/null||command -v gtimeout 2>/dev/null); ' ..
        'if [ -n "$__t" ]; then "$__t" -k ' .. KILL_GRACE_S .. ' ' .. secs ..
            ' sh -c ' .. sq .. '; ' ..
        'else sh -c ' .. sq .. '; fi'
    return full, secs
end

router.register('proc_run', function(cmd, cwd, timeout_ms)
    local inner = build_inner(cmd, cwd)
    local full, secs = wrap_timeout(inner, timeout_ms)

    local f, perr = io.popen(full, 'r')
    if not f then return '', -1, 'popen failed: ' .. tostring(perr) end

    local output = f:read('*a') or ''
    local ok, _how, code = f:close()
    -- Lua close() on a popen handle: (true|nil, "exit"|"signal", code)
    local exit_code = tonumber(code) or (ok and 0 or 1)

    local timed_out = (secs ~= nil and exit_code == TIMEOUT_EXIT)
    output = text.truncate(output, MAX_OUTPUT,
        string.format('\n...[truncated, %d bytes total]', #output))
    if timed_out then
        output = output .. string.format(
            '\n[command timed out after %ds; its process tree was terminated]', secs)
    end
    return output, exit_code, timed_out and 'timeout' or nil
end)

return {
    __thread_handle = router.handle,
}
