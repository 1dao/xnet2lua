-- xagent/proc/proc_worker.lua — subprocess worker thread.
--
-- Runs on a dedicated xthread worker (xthread.IO). The main thread (agent
-- coroutine) reaches it via xthread.rpc(IO, 'proc_run', timeout, cmd, cwd); the
-- blocking io.popen lives HERE so it never stalls the main event loop. stdout
-- and stderr are merged; the handler returns (output, exit_code, err).
--
-- Method-B baseline (see xagent_design_v1.md): io.popen has no kill/stream/
-- cancel. A hung command blocks this worker until it exits; the caller's rpc
-- timeout unblocks the caller but the worker stays stuck. The xproc C binding
-- (later) replaces this with pollable pipes + timeout-kill.

local router = dofile('scripts/core/share/xrouter.lua')
local text = dofile('scripts/core/share/xtext.lua')
router.set_log_prefix('XAGENT-PROC')

local SEP = package.config:sub(1, 1)
local IS_WIN = (SEP == '\\')
local MAX_OUTPUT = 200000   -- worker-side cap; the Bash tool truncates further

local function quote_dir(p)
    if IS_WIN then
        return '"' .. p:gsub('/', '\\') .. '"'          -- cmd.exe wants backslashes
    end
    return "'" .. p:gsub("'", "'\\''") .. "'"            -- POSIX single-quote
end

local function build_command(cmd, cwd)
    cmd = tostring(cmd or '')
    if cwd and cwd ~= '' then
        local cd = IS_WIN and ('cd /d ' .. quote_dir(cwd)) or ('cd ' .. quote_dir(cwd))
        cmd = cd .. ' && ' .. cmd
    end
    return cmd .. ' 2>&1'                                 -- merge stderr into stdout
end

router.register('proc_run', function(cmd, cwd)
    local full = build_command(cmd, cwd)
    local f, perr = io.popen(full, 'r')
    if not f then return '', -1, 'popen failed: ' .. tostring(perr) end

    local output = f:read('*a') or ''
    local ok, _how, code = f:close()
    output = text.truncate(output, MAX_OUTPUT,
        string.format('\n...[truncated, %d bytes total]', #output))
    -- Lua close() on a popen handle: (true|nil, "exit"|"signal", code)
    local exit_code = tonumber(code) or (ok and 0 or 1)
    return output, exit_code, nil
end)

return {
    __thread_handle = router.handle,
}
