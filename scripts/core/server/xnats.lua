-- Business-side NATS API.
-- NATS I/O lives in scripts/core/server/xnats_worker.lua and uses xnet/xchannel raw mode.
--
-- xnats.rpc has two paths (transparent to the caller):
--   * Local short-circuit: when target's process name matches state.self_name and
--     this thread has been bind_local'd, the call dispatches directly to the
--     local business worker via xthread.rpc, bypassing the NATS thread entirely.
--   * Remote: routed through the NATS thread (xthread.rpc(NATS_ID, 'xnats_rpc',...))
--     which serialises onto the wire.
--
-- Return shape (unified for both paths):
--   * Channel failure  → (false, channel_err)
--   * Channel success  → (true, app_ok, app_ret1, app_ret2, ...)

local M = rawget(_G, 'xnats')
if type(M) ~= 'table' then M = {} end

local NATS_ID = xthread.NATS
local DEFAULT_SCRIPT = 'scripts/core/server/xnats_worker.lua'

local STATE_KEY = '__xnet_xnats_state'
local state = rawget(_G, STATE_KEY)
if type(state) ~= 'table' then
    state = {}
    rawset(_G, STATE_KEY, state)
end
if state.running == nil then state.running = false end
-- Caller-side routing info (per-thread, persisted across reload).
-- Populated by M.bind_local on this thread; M.bind_workers fans out to others.
if state.self_name == nil then state.self_name = nil end
if type(state.worker_threads) ~= 'table' then state.worker_threads = {} end
if state.rr_local == nil then state.rr_local = 1 end

local unpack_args = table.unpack or unpack

local function pack_values(...)
    return { n = select('#', ...), ... }
end

-- Self-install routing-bind handler on this thread's xrouter so any thread
-- that dofile()s this module can receive xnats_bind_local posts.
local _router = dofile('scripts/core/share/xrouter.lua')

local function copy_workers(workers)
    local out = {}
    if type(workers) == 'table' then
        for i, id in ipairs(workers) do
            out[i] = tonumber(id)
        end
    end
    return out
end

local function normalize_config(cfg)
    cfg = cfg or {}
    return {
        host = cfg.host or '127.0.0.1',
        port = cfg.port or 4222,
        name = cfg.name or cfg.process_name or 'game1',
        prefix = cfg.prefix or 'xnet',
        broadcast_subject = cfg.broadcast_subject or '',
        worker_threads = copy_workers(cfg.worker_threads or cfg.workers),
        reconnect_ms = cfg.reconnect_ms or 1000,
        rpc_timeout_ms = cfg.rpc_timeout_ms or 5000,
        max_packet = cfg.max_packet or cfg.max_reply_size or 64 * 1024 * 1024,
        script_path = cfg.script_path or DEFAULT_SCRIPT,
    }
end

-- Populate this thread's caller-side routing info (synchronous, no I/O).
function M.bind_local(opts)
    opts = opts or {}
    if type(opts.name) == 'string' and opts.name ~= '' then
        state.self_name = opts.name
    end
    if type(opts.worker_threads) == 'table' or type(opts.workers) == 'table' then
        state.worker_threads = copy_workers(opts.worker_threads or opts.workers)
    end
    -- Keep rr cursor in range when worker count changes.
    local n = #state.worker_threads
    if n == 0 then
        state.rr_local = 1
    elseif state.rr_local < 1 or state.rr_local > n then
        state.rr_local = 1
    end
    return true
end

-- Fan out the current bind_local info to other worker threads via POST.
-- Caller is responsible for ordering: the target threads must already be
-- alive (i.e. xthread.create_thread has returned). xnats.start cannot do
-- this for HTTP workers because they typically don't exist yet at start.
function M.bind_workers(worker_ids)
    if not state.self_name or state.self_name == '' then
        return false, 'xnats.bind_local must be called first'
    end
    local self_id = xthread.current_id and xthread.current_id() or 0
    local list = worker_ids
    if type(list) ~= 'table' then list = state.worker_threads end
    for _, tid in ipairs(list or {}) do
        tid = tonumber(tid)
        if tid and tid > 0 and tid ~= self_id and tid ~= NATS_ID then
            local ok, err = xthread.post(tid, 'xnats_bind_local',
                state.self_name, state.worker_threads)
            if not ok then
                io.stderr:write(string.format(
                    '[XNATS] bind_workers post to %s failed: %s\n',
                    tostring(tid), tostring(err)))
            end
        end
    end
    return true
end

if _router and type(_router.register) == 'function' then
    _router.register('xnats_bind_local', function(name, worker_threads)
        M.bind_local({ name = name, worker_threads = worker_threads })
    end)
end

function M.start(cfg)
    if state.running then
        return true
    end

    local conf = normalize_config(cfg)
    if not xthread.NATS then
        return false, 'xthread.NATS is not defined'
    end

    -- Bind on the calling thread immediately so that xnats.rpc on this
    -- thread can short-circuit before any NATS I/O is up.
    M.bind_local({ name = conf.name, worker_threads = conf.worker_threads })

    local ok, err = xthread.create_thread(NATS_ID, 'xnats-worker', conf.script_path)
    if not ok then
        return false, err
    end

    state.running = true
    ok, err = xthread.post(NATS_ID, 'xnats_start',
        conf.host, conf.port, conf.name, conf.prefix, conf.broadcast_subject,
        conf.worker_threads, conf.reconnect_ms, conf.rpc_timeout_ms, conf.max_packet)
    if not ok then
        state.running = false
        xthread.shutdown_thread(NATS_ID)
        return false, err
    end

    return true
end

function M.publish(pt, ...)
    return xthread.post(NATS_ID, 'xnats_publish', pt, ...)
end

M.broadcast = M.publish

-- Parse "name" or "name:idx" into (process_name, idx_or_nil).
local function parse_target(target)
    local s = tostring(target or '')
    local name, idx = string.match(s, '^([^:]+):(%d+)$')
    if name then return name, tonumber(idx) end
    return s, nil
end

-- Choose a local business worker thread id given an optional explicit idx.
-- Mirrors xnats_worker.choose_worker so caller-side short-circuit follows
-- the same routing semantics as the inbound NATS path.
local function pick_local_tid(idx)
    local workers = state.worker_threads
    if type(workers) ~= 'table' or #workers == 0 then
        return nil, 'xnats: no local worker_threads (call xnats.bind_local)'
    end
    if idx then
        local tid = workers[idx]
        if not tid then
            return nil, 'xnats: local worker idx out of range: ' .. tostring(idx)
        end
        return tid
    end
    local tid = workers[state.rr_local]
    state.rr_local = (state.rr_local % #workers) + 1
    return tid
end

-- Same-thread degenerate case: directly invoke the registered stub. Avoids
-- a self-RPC deadlock and dodges an extra post round-trip.
local function invoke_local_stub(pt, ...)
    local router = rawget(_G, '__xnet_xrouter')
    local h = router and router.stubs and router.stubs[pt]
    if type(h) ~= 'function' then
        return false, 'xnats: no local handler for pt=' .. tostring(pt)
    end
    local rets = pack_values(pcall(h, ...))
    if not rets[1] then
        -- pcall failure: surface as a channel error.
        return false, tostring(rets[2])
    end
    -- pcall success: rets[2..] are handler return values, typically (ok, ...).
    return true, unpack_args(rets, 2, rets.n)
end

function M.rpc(target, pt, ...)
    -- Caller-side local short-circuit: when target's process name matches
    -- this thread's bound self_name, hit the business worker directly and
    -- skip the NATS thread.
    local self_name = state.self_name
    if self_name and self_name ~= '' then
        local tname, tidx = parse_target(target)
        if tname == self_name then
            local tid, perr = pick_local_tid(tidx)
            if not tid then
                return false, perr
            end

            -- Same-thread RPC would deadlock the framework; resolve in-place.
            if xthread.current_id and tid == xthread.current_id() then
                return invoke_local_stub(pt, ...)
            end

            -- Cross-thread same-process: xthread.rpc returns
            --   (true, handler_ret1, handler_ret2, ...)  on success
            --   (false, err)                              on channel failure
            -- Handler convention is (ok, ...), so the caller sees
            -- (true, app_ok, app_ret1, ...) which matches the remote shape.
            local rets = pack_values(xthread.rpc(tid, pt, 0, ...))
            if not rets[1] then
                return false, rets[2]
            end
            return true, unpack_args(rets, 2, rets.n)
        end
    end

    -- Remote: route through the NATS thread.
    --
    -- The wire payload from start_incoming_rpc on the receiver is
    --   (wire_rpc_ok, handler_ok, handler_ret2, ...)
    -- where wire_rpc_ok is the channel_ok of the receiver's inner xthread.rpc
    -- (so it tracks "NATS-side channel succeeded" rather than "app succeeded").
    -- xthread.rpc(NATS_ID, ...) wraps that again with its own channel_ok, giving
    --   rets = (xthread_ok, wire_rpc_ok, handler_ok, handler_ret2, ...)
    -- We peel both layers so the caller sees the same shape as the local path:
    --   (channel_ok, handler_ok, handler_ret2, ...)
    local rets = pack_values(xthread.rpc(NATS_ID, 'xnats_rpc', 0, target, pt, ...))
    if not rets[1] then
        return false, rets[2]
    end
    if rets[2] == false then
        -- NATS-side channel failure (timeout / not connected / remote not present).
        return false, tostring(rets[3] or 'xnats: remote channel error')
    end
    return true, unpack_args(rets, 3, rets.n)
end

function M.post(cb, target, pt, ...)
    if type(cb) ~= 'function' then
        target, pt = cb, target
        cb = nil
    end

    local args = { n = select('#', ...) + 2, target, pt, ... }
    local co = coroutine.create(function()
        -- M.rpc unified shape: (channel_ok, app_ok, ...) or (false, err)
        local rets = pack_values(M.rpc(unpack_args(args, 1, args.n)))
        if cb then
            cb(unpack_args(rets, 1, rets.n))
        end
    end)

    local ok, err = coroutine.resume(co)
    if not ok then
        return false, err
    end
    return true
end

function M.stop(silent)
    if not state.running then
        return true
    end

    xthread.post(NATS_ID, 'xnats_stop', silent and true or false)
    local ok, err = xthread.shutdown_thread(NATS_ID)
    state.running = false
    if not ok then
        return false, err
    end
    return true
end

function M.running()
    return state.running
end

_G.xnats = M
return M
