-- xproc.lua — caller-side API for a pool of blocking process-runner threads.
--
-- NOT the module you get from require('xproc'). That name belongs to the C
-- binding (xproc.c / xlua/lua_xproc.c), which has real pollable pipes but is
-- compiled in only with WITH_XPROC=1 and so is absent from a stock bin/xnet.
-- This file is the pure-Lua fallback that works on any build: the same job done
-- by blocking os.execute on a worker thread instead of by pipes on the event
-- loop. Load it by path with dofile, never with require.
--
-- Pairs with xproc_worker.lua. setup() spawns N worker threads once at boot;
-- exec() dispatches one command to the least-busy worker over a coroutine RPC,
-- so the calling event loop keeps running while the child process does its
-- thing. exec() MUST therefore be called from inside a coroutine.
--
--     local xproc = dofile('scripts/core/server/xproc.lua')
--     xproc.setup({ workers = 4, tmp_dir = 'tmp' })        -- main state, at boot
--     ...
--     local r = xproc.exec({ argv = { 'git', 'rev-parse', 'HEAD' },
--                            cwd = repo, capture_stdout = true })
--     if r.ok then print(r.stdout) end
--
-- The caller's script must route replies back by exposing xrouter's handler as
-- its own __thread_handle — the same requirement every xthread.rpc client has.
--
-- WHY A POOL AND NOT ONE WORKER
-- One worker runs one os.execute at a time and blocks for its whole duration. A
-- single worker would serialise every concurrent request behind the slowest
-- child (a big clone, say). Workers are picked by least-outstanding-calls, so a
-- long-running command parks on one thread and short ones flow around it.

local M = {}

local DEFAULT_WORKERS = 4
local DEFAULT_SCRIPT  = 'scripts/core/server/xproc_worker.lua'
-- Extra time allowed on the RPC beyond the child's own watchdog deadline, so a
-- killed command comes back as a real result (exit 124) instead of a transport
-- error that loses the stderr with it.
local RPC_GRACE_MS    = 10000

local pool = {}          -- { { tid, busy } , ... }
local started = false
local defaults = {}

-- ---------------------------------------------------------------------------
-- setup
-- ---------------------------------------------------------------------------

-- opts:
--   workers   number?  pool size (default 4)
--   base_tid  number?  first thread id (default xthread.WORKER_GRP1)
--   name      string?  thread-name prefix, for logs (default 'xproc')
--   script    string?  worker script path
--   tmp_dir   string?  default spec.tmp_dir for every exec()
--   timeout_ms number? default spec.timeout_ms for every exec()
--
-- Idempotent: calling it twice is a no-op. Returns true, or false plus the
-- error from the thread that failed to come up.
function M.setup(opts)
    if started then return true end
    opts = opts or {}

    local count    = tonumber(opts.workers) or DEFAULT_WORKERS
    local base_tid = tonumber(opts.base_tid) or xthread.WORKER_GRP1
    local name     = opts.name or 'xproc'
    local script   = opts.script or DEFAULT_SCRIPT

    defaults = {
        tmp_dir    = opts.tmp_dir,
        timeout_ms = tonumber(opts.timeout_ms) or 0,
    }

    for i = 1, count do
        local tid = base_tid + (i - 1)
        local ok, err = xthread.create_thread(tid, string.format('%s-%d', name, i), script)
        if not ok then
            return false, string.format('xproc: worker %d (tid %d) failed: %s',
                i, tid, tostring(err))
        end
        pool[#pool + 1] = { tid = tid, busy = 0 }
    end

    started = true
    return true
end

function M.running() return started end
function M.size()    return #pool end

-- ---------------------------------------------------------------------------
-- exec
-- ---------------------------------------------------------------------------

local function pick_worker()
    local best = pool[1]
    for i = 2, #pool do
        if pool[i].busy < best.busy then best = pool[i] end
    end
    return best
end

-- Run one command. Coroutine-only. See xproc_worker.lua for the full spec
-- shape. Returns a result table, never raises:
--   { ok, exit_code, stdout, stderr, stdout_file, stderr_file, timed_out, err }
-- ok is true when the child exited 0. A non-zero exit is a normal result with
-- ok=false and err set; only a transport failure sets exit_code = -1.
function M.exec(spec)
    spec = spec or {}
    if not started then
        return { ok = false, exit_code = -1, err = 'xproc: setup() not called' }
    end

    if spec.tmp_dir == nil then spec.tmp_dir = defaults.tmp_dir end
    if spec.timeout_ms == nil then spec.timeout_ms = defaults.timeout_ms end

    -- RPC deadline. Default 0 (wait indefinitely): without spec.timeout_ms the
    -- worker has no way to kill a hung child, so a finite RPC timeout would
    -- only abandon the reply while the worker stayed wedged anyway. Bounding
    -- the CHILD (spec.timeout_ms) is the control that actually works; the RPC
    -- deadline then just has to outlast it.
    local rpc_timeout = tonumber(spec.rpc_timeout_ms) or 0
    if rpc_timeout == 0 and (tonumber(spec.timeout_ms) or 0) > 0 then
        rpc_timeout = spec.timeout_ms + RPC_GRACE_MS
    end
    spec.rpc_timeout_ms = nil

    local w = pick_worker()
    w.busy = w.busy + 1
    local ok, res = xthread.rpc(w.tid, 'proc_exec', rpc_timeout, spec)
    w.busy = w.busy - 1

    if not ok then
        return { ok = false, exit_code = -1,
                 err = 'xproc rpc failed: ' .. tostring(res) }
    end
    if type(res) ~= 'table' then
        return { ok = false, exit_code = -1,
                 err = 'xproc: malformed reply ' .. tostring(res) }
    end
    res.ok = (res.exit_code == 0)
    return res
end

-- Round-trip a ping through every worker. Coroutine-only. Use once at boot to
-- turn "the threads were created" into "the threads actually answer".
function M.selftest()
    for i, w in ipairs(pool) do
        local ok, reply = xthread.rpc(w.tid, 'proc_ping', 5000)
        if not ok or reply ~= 'pong' then
            return false, string.format('xproc: worker %d (tid %d) did not answer: %s',
                i, w.tid, tostring(reply))
        end
    end
    return true
end

return M
