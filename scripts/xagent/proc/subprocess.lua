-- xagent/proc/subprocess.lua — main-thread API for running shell commands.
--
-- A thin adapter over the xproc worker POOL (scripts/core/server/xproc.lua).
-- Blocking process work happens on worker threads, so the event loop — network
-- streaming included — keeps progressing while a command runs. run() does a
-- coroutine-yielding RPC, so it MUST be called from inside a coroutine (the
-- agent's tool.call runs in one — see core/loop.lua).
--
-- WHY A POOL. This used to be ONE worker on xthread.IO, and every Bash, every
-- Grep and the GUI's folder dialog queued on it. Two GUI tabs running turns at
-- once serialised all of their commands; the folder picker (a 5-minute RPC while
-- a modal dialog sits open) blocked every tool call in every tab behind it.
--
-- TWO LANES:
--   run()    — the shared pool (PROC_WORKERS threads). Agent tools live here.
--   run_ui() — a reserved single worker, created only when setup{ ui_lane=true }.
--              For commands that block on a HUMAN (the folder dialog): they hold
--              a worker for minutes, and must not eat a pool slot to do it.
--
-- IMPORTANT: the main script that uses this must wire `xrouter`'s handler as its
-- own __thread_handle (so RPC replies route back). See test_subprocess.lua.

local xutils = require('xutils')

-- Two INDEPENDENT pool instances: dofile does not cache, so each call builds its
-- own module state (pool list, defaults). require would hand back one shared
-- instance and the UI lane could not exist.
local xproc    = dofile('scripts/core/server/xproc.lua')
local xproc_ui = dofile('scripts/core/server/xproc.lua')

local M = {}

local DEFAULT_WORKERS = 4
local UI_TID          = xthread.IO     -- the reserved human-blocking lane
local POOL_BASE_TID   = xthread.WORKER_GRP1
local TMP_DIR         = 'tmp'          -- scratch for stdout staging
-- Worker-side cap on what comes back over the RPC. The Bash/Grep tools truncate
-- further for the model; this bounds the msgpack payload.
local MAX_OUTPUT      = 200000
local IS_WIN          = (package.config:sub(1, 1) == '\\')
-- Every command gets stdin from the null device. The commonest way an agent
-- wedges a worker is not a runaway loop, it is a child that WAITS for input that
-- will never come — `git commit` with no -m, `npm init`, anything that prompts.
-- With EOF on stdin those exit immediately instead of blocking until the
-- watchdog kills them, which is both faster and cheaper than the watchdog.
local NULL_DEVICE     = IS_WIN and 'NUL' or '/dev/null'
-- Grace added to the RPC deadline when the child-side watchdog is switched off,
-- so the CALLER still gets a timely answer even though the worker cannot be
-- freed. See watchdog_enabled().
local RPC_GRACE_MS    = 10000

local started = false
local ui_started = false

-- How many pool workers. XAGENT_PROC_WORKERS in xnet.cfg / xagent.local.cfg
-- overrides the default; 1 restores the old serial behaviour for debugging.
local function worker_count()
    local n = tonumber(xutils.get_config('XAGENT_PROC_WORKERS') or '')
    if not n or n < 1 then return DEFAULT_WORKERS end
    if n > 16 then return 16 end
    return math.floor(n)
end

-- Is the child-side timeout watchdog on? Default yes, and it should stay yes:
-- it is what makes the timeout this module advertises actually true.
--
-- The cost is a PowerShell start-up per timed call on Windows — measured at
-- +315ms against 22ms for an unwrapped `echo`. XAGENT_PROC_WATCHDOG=0 buys that
-- back, and the trade is explicit: a command that never exits then holds its
-- worker until the process dies. The caller still gets a timeout error (the RPC
-- deadline below), so the agent keeps working with one fewer worker.
local function watchdog_enabled()
    local v = xutils.get_config('XAGENT_PROC_WATCHDOG')
    return not (v == '0' or v == 'false' or v == 'off')
end

-- Create the worker threads. Idempotent. Call once at boot.
--   opts.ui_lane = true  also reserves the single UI worker (GUI only).
function M.setup(opts)
    opts = opts or {}
    if not started then
        -- The worker stages stdout through files here; a crash mid-command can
        -- leave one behind, so it must be a directory we own, not the repo root.
        xutils.mkdir_p(TMP_DIR)
        local ok, err = xproc.setup({
            workers  = worker_count(),
            base_tid = POOL_BASE_TID,
            name     = 'xagent-proc',
            tmp_dir  = TMP_DIR,
        })
        if not ok then return false, err end
        started = true
    end
    if opts.ui_lane and not ui_started then
        local ok, err = xproc_ui.setup({
            workers  = 1,
            base_tid = UI_TID,
            name     = 'xagent-proc-ui',
            tmp_dir  = TMP_DIR,
        })
        if not ok then return false, err end
        ui_started = true
    end
    return true
end

-- Ping every worker. Turns "the threads were created" into "the threads answer".
-- Coroutine-only; returns true, or false plus which worker went missing.
function M.selftest()
    local ok, err = xproc.selftest()
    if not ok then return false, err end
    if ui_started then return xproc_ui.selftest() end
    return true
end

function M.size() return xproc.size() end

-- Join both lanes' worker threads. Call from the entry script's __uninit: the
-- runtime closes the main Lua state before it joins leftover threads, and a
-- worker alive in that gap can crash the process on exit (see xproc.shutdown).
-- Idempotent.
function M.shutdown()
    if ui_started then xproc_ui.shutdown(); ui_started = false end
    if started    then xproc.shutdown();    started    = false end
end

-- Shape an xproc reply into the result table this module has always returned.
--
-- NOTE the `ok` convention, which differs from xproc.exec's on purpose: here ok
-- means "the RPC came back", NOT "the child exited 0". Callers (tools/bash.lua,
-- tools/grep.lua) treat a non-zero exit as a normal result they format for the
-- model, and only `not ok` as a runner failure.
local function shape(r, label)
    -- Transport failure: no child ever ran, or its reply was lost. Matched on
    -- the 'xproc:'/'xproc rpc' prefix xproc.exec puts on its OWN errors, not on
    -- exit_code == -1 alone — a child is free to exit with -1 itself.
    if not r.ok and type(r.err) == 'string' and r.err:match('^xproc') then
        return { ok = false, timed_out = true, stdout = '', exit_code = -1,
                 err = label .. ': ' .. r.err }
    end

    local out = r.stdout or ''
    local total = r.stdout_bytes or #out
    -- Decide "was it cut short?" on the RAW byte counts, before normalising —
    -- CRLF folding shrinks the string and would otherwise look like truncation.
    local truncated = total > #out
    -- Normalise CRLF. The old runner read through io.popen, which Lua opens in
    -- TEXT mode on Windows and which therefore stripped the CR for free; staging
    -- through a file in binary mode does not, and every cmd.exe child ends its
    -- lines with CRLF. Without this, tool output reaching the model (and the
    -- transcript) would suddenly be full of stray \r.
    if IS_WIN then out = out:gsub('\r\n', '\n') end
    if truncated then
        out = out .. string.format('\n...[truncated, %d bytes total]', total)
    end
    if r.timed_out then
        out = out .. string.format(
            '\n[command timed out after %ds; its process tree was terminated]',
            r.timeout_s or 0)
    end

    return {
        ok         = true,
        stdout     = out,
        exit_code  = r.exit_code or 0,
        err        = r.timed_out and 'timeout' or nil,
        timed_out  = r.timed_out,
    }
end

-- Build the spec both lanes share.
--   opts = { cmd = <string> | argv = {string,...}, cwd = <string?>,
--            timeout_ms = <number?> }
-- timeout_ms bounds how long the COMMAND may run (the worker kills its process
-- tree past it); 0/absent means no limit.
local function spec_of(opts)
    assert(type(opts) == 'table', 'subprocess: opts table required')
    if opts.argv ~= nil then
        assert(type(opts.argv) == 'table' and #opts.argv > 0,
            'subprocess.run: argv must be a non-empty array')
    else
        assert(type(opts.cmd) == 'string' and opts.cmd ~= '',
            'subprocess.run: cmd or argv required')
    end
    local cmd_timeout = tonumber(opts.timeout_ms) or 0
    local spec = {
        cmd            = opts.cmd,
        argv           = opts.argv,
        cwd            = opts.cwd,
        stdin_file     = opts.stdin_file or NULL_DEVICE,
        timeout_ms     = cmd_timeout,
        capture_stdout = true,
        -- One interleaved stream is what an agent wants to read: a command's
        -- error lines belong next to the output that led to them.
        merge_stderr   = true,
        max_capture    = MAX_OUTPUT,
    }
    if cmd_timeout > 0 and not watchdog_enabled() then
        -- No child-side kill, but still a bounded wait for the caller.
        spec.timeout_ms     = 0
        spec.rpc_timeout_ms = cmd_timeout + RPC_GRACE_MS
    end
    return spec
end

-- Run a command on the shared pool. MUST be called from within a coroutine.
-- Returns { ok, stdout, exit_code, err, timed_out } — exit_code is 124 and err
-- is 'timeout' when the watchdog killed it.
function M.run(opts)
    if not started then
        local ok, err = M.setup()
        if not ok then return { ok = false, stdout = '', exit_code = -1, err = err } end
    end
    return shape(xproc.exec(spec_of(opts)), 'subprocess rpc failed')
end

-- Run a command on the reserved UI worker. For dialogs that block on a human;
-- never for agent tools. Falls back to the shared pool if no UI lane was set up.
function M.run_ui(opts)
    if not ui_started then return M.run(opts) end
    return shape(xproc_ui.exec(spec_of(opts)), 'subprocess ui rpc failed')
end

return M
