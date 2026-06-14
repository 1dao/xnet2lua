-- xagent/proc/subprocess.lua — main-thread API for running shell commands.
--
-- Offloads blocking io.popen to a dedicated worker thread (xthread.IO) so the
-- event loop keeps running. The worker is created once via setup(); run() does
-- a coroutine-yielding RPC, so it MUST be called from inside a coroutine (the
-- agent's tool.call runs in one — see core/loop.lua). The whole event loop,
-- network streaming included, keeps progressing while the command runs.
--
-- IMPORTANT: the main script that uses this must wire `xrouter`'s handler as its
-- own __thread_handle (so RPC replies route back). See test_subprocess.lua.

local M = {}

local PROC_TID = xthread.IO
local started = false

-- Create the subprocess worker thread. Idempotent. Call once at boot.
function M.setup()
    if started then return true end
    local ok, err = xthread.create_thread(
        PROC_TID, 'xagent-proc', 'scripts/xagent/proc/proc_worker.lua')
    if not ok then return false, err end
    started = true
    return true
end

-- Run a command. MUST be called from within a coroutine.
--   opts = { cmd = <string>, cwd = <string?>, timeout_ms = <number?> }
--   returns { ok, stdout, exit_code, err, timed_out }
function M.run(opts)
    opts = opts or {}
    assert(type(opts.cmd) == 'string' and opts.cmd ~= '', 'subprocess.run: cmd required')
    if not started then
        local ok, err = M.setup()
        if not ok then return { ok = false, stdout = '', exit_code = -1, err = err } end
    end

    local timeout = tonumber(opts.timeout_ms) or 0   -- 0 = wait indefinitely
    -- xthread.rpc returns: ok, <handler returns...>. One leading boolean that
    -- folds transport + handler success; on failure the next value is the error
    -- message. Our proc_run handler returns (output, exit_code, err).
    local ok, output, code, herr =
        xthread.rpc(PROC_TID, 'proc_run', timeout, opts.cmd, opts.cwd)

    if not ok then
        return { ok = false, timed_out = true, stdout = '', exit_code = -1,
                 err = 'subprocess rpc failed: ' .. tostring(output) }
    end
    return {
        ok = true,
        stdout = type(output) == 'string' and output or tostring(output or ''),
        exit_code = tonumber(code) or 0,
        err = herr,
    }
end

return M
