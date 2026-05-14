-- xrouter.lua - per-Lua-state singleton message router for xthread workers.
--
-- Replaces the per-script copy of `_stubs / _thread_replys / __thread_handle`
-- with a single unified registration API.
--
-- Design choice: only one `register(pt, h)`. The registration site does NOT
-- know -- and should not need to know -- whether the caller will reach this pt
-- via POST (`xthread.post`) or RPC (`xthread.rpc`). That decision belongs to
-- the caller. Dispatch handles both shapes:
--
--   * Caller used POST -- handler runs in a coroutine; return values are
--     discarded.
--   * Caller used RPC  -- handler runs in a coroutine; return values become
--     the reply `(ok=true, ret1, ret2, ...)`. A raised error becomes
--     `(ok=false, errmsg)`. The handler may yield (e.g. RPC out via
--     `xthread.rpc`) -- the reply is sent when the coroutine eventually returns.
--
-- The router is a SINGLETON per Lua state (mirrors xhttp_router): every
-- `dofile('scripts/core/share/xrouter.lua')` in the same thread returns the SAME table, so
-- registrations spread across many files all accumulate into one router.
--
-- Standard worker-script shape:
--
--     local router = dofile('scripts/core/share/xrouter.lua')
--     router.set_log_prefix('MYAPP')                    -- optional
--
--     router.register('hello', function(name) print('hi', name) end)
--     router.register('add',   function(a, b) return a + b end)
--     dofile('scripts/core/share/handlers/extra.lua')     -- registers more on the same router
--
--     return {
--         __init   = function() assert(xnet.init())     end,
--         -- __update = function() ... end, -- only for periodic Lua work
--         __uninit = function() xnet.uninit()            end,
--         __thread_handle = router.handle,    -- only line that changes
--     }
--
-- Reload model: re-running the worker script overwrites handlers in place on
-- the existing singleton, while the router table and any in-flight rpc_context
-- survive intact. The script returns the current `router.handle`, so the C-side
-- __thread_handle ref is refreshed during runtime reload.

local ROUTER_KEY = '__xnet_xrouter'
local M = rawget(_G, ROUTER_KEY)

local unpack_args = table.unpack or unpack
local coroutine_create = coroutine.create
local coroutine_resume = coroutine.resume
local coroutine_running = coroutine.running
local coroutine_status = coroutine.status
local debug_traceback = debug and debug.traceback

local function pack_values(...)
    return { n = select('#', ...), ... }
end

local function coroutine_error(req, err)
    if debug_traceback and type(req) == 'table' and type(req.co) == 'thread' then
        local ok, tb = pcall(debug_traceback, req.co, tostring(err))
        if ok and tb then return tb end
    end
    return tostring(err)
end

local function format_error(prefix, fmt, ...)
    return string.format('[%s] ' .. fmt, prefix, ...)
end

if type(M) ~= 'table' then
    M = {
        log_prefix       = 'XROUTER',
        stubs            = {},   -- pt -> handler  (single unified table)
        rpc_context      = {},   -- co -> req      (in-flight RPC requests)
        unknown_post     = nil,  -- function(pt, ...) when no handler matches a POST
        unknown_rpc      = nil,  -- function(reply_router, co_id, sk, pt, ...) for RPC misses
        on_handler_error = nil,  -- function(pt, err) for POST-side coroutine top-level error
        builtins = {},
    }
    rawset(_G, ROUTER_KEY, M)
else
    M.log_prefix = M.log_prefix or 'XROUTER'
    if type(M.stubs) ~= 'table' then M.stubs = {} end
    if type(M.rpc_context) ~= 'table' then M.rpc_context = {} end
    if type(M.builtins) ~= 'table' then M.builtins = {} end
end
M.builtins['@run_script'] = M.builtins['@run_script'] or {}
M.builtins['@reload'] = M.builtins['@reload'] or {}
M.builtins['@reload_thread'] = M.builtins['@reload_thread'] or {}

local function log_err(fmt, ...)
    io.stderr:write(format_error(M.log_prefix, fmt, ...) .. '\n')
end

-- -------------------------------------------------------------------------
-- Configuration
-- -------------------------------------------------------------------------

-- Builtin: @run_script
--
-- Executes a Lua chunk and captures printed output plus return values:
--   return ok, output, result
--
-- opts:
--   max_output_bytes: cap captured stdout size (default 256KB)
--   allow_globals   : when false, run in a closed env
--   extra_env       : extra symbols injected into env
--   before_execute  : callback(src) -> false to reject
local function run_script_impl(opts, src)
    opts = opts or {}
    src = tostring(src or '')

    local is_lua51 = (_VERSION == 'Lua 5.1')
    local max_output = tonumber(opts.max_output_bytes) or (256 * 1024)

    local function compile(code, env)
        if is_lua51 then
            local fn, err = loadstring(code, '=router_builtin_run_script')
            if fn then setfenv(fn, env) end
            return fn, err
        end
        return load(code, '=router_builtin_run_script', 't', env)
    end

    local function tostring_safe(v)
        local ok, s = pcall(tostring, v)
        if ok then return s end
        return '<tostring error>'
    end

    local out = {}
    local out_size = 0
    local truncated = false

    local function append_line(s)
        if truncated then return end
        s = tostring(s or '')
        local next_size = out_size + #s + 1
        if next_size > max_output then
            local remain = max_output - out_size
            if remain > 0 then
                out[#out + 1] = string.sub(s, 1, remain)
            end
            out[#out + 1] = '\n...[truncated]'
            truncated = true
            out_size = max_output
            return
        end
        out[#out + 1] = s
        out_size = next_size
    end

    local env = {
        print = function(...)
            local n = select('#', ...)
            local parts = {}
            for i = 1, n do
                parts[i] = tostring_safe(select(i, ...))
            end
            append_line(table.concat(parts, '\t'))
        end,
    }

    local extra_env = opts.extra_env
    if type(extra_env) == 'table' then
        for k, v in pairs(extra_env) do
            env[k] = v
        end
    end

    if opts.allow_globals == false then
        setmetatable(env, nil)
    else
        setmetatable(env, { __index = _G })
    end

    local before = opts.before_execute
    if type(before) == 'function' then
        local ok, verdict = pcall(before, src)
        if not ok then
            return false, '', 'before_execute error: ' .. tostring_safe(verdict)
        end
        if verdict == false then
            return false, '', 'script rejected by before_execute'
        end
    end

    local fn, perr = compile(src, env)
    if not fn then
        return false, '', 'compile error: ' .. tostring_safe(perr)
    end

    local rets = pack_values(pcall(fn))
    if not rets[1] then
        return false, table.concat(out, '\n'), 'runtime error: ' .. tostring_safe(rets[2])
    end

    local vals = {}
    for i = 2, rets.n do
        vals[#vals + 1] = tostring_safe(rets[i])
    end
    return true, table.concat(out, '\n'), table.concat(vals, '\t')
end

local function install_builtin_run_script(opts)
    M.builtins['@run_script'] = opts or M.builtins['@run_script'] or {}
    M.stubs['@run_script'] = function(src)
        return run_script_impl(M.builtins['@run_script'], src)
    end
end

local function call_reload()
    if not xnet or type(xnet.__reload) ~= 'function' then
        return false, 'xnet.__reload builtin is not available'
    end
    local rets = pack_values(pcall(xnet.__reload))
    if not rets[1] then
        return false, tostring(rets[2])
    end
    if rets[2] == false then
        return false, tostring(rets[3] or 'reload failed')
    end
    return true, tostring(rets[3] or rets[2] or 'reloaded')
end

local function reply_router_thread_id(req)
    if type(req) ~= 'table' then return nil end
    local router = tostring(req.reply_router or '')
    local id = router:match('^xthread:(%d+)$')
    return id and tonumber(id) or nil
end

local function add_unique_id(list, seen, value)
    local id = tonumber(value)
    if not id or id <= 0 or seen[id] then return end
    seen[id] = true
    list[#list + 1] = id
end

local function schedule_deferred_reload(ids)
    if #ids == 0 then return end
    local delay_ms = 20
    local function post_all()
        for _, id in ipairs(ids) do
            local ok, err = xthread.post(id, '@reload_thread')
            if not ok then
                log_err('deferred reload post failed thread=%s err=%s',
                        tostring(id), tostring(err))
            end
        end
    end

    if xtimer and xtimer.inited and xtimer.init and xtimer.add then
        if not xtimer.inited() then xtimer.init(16) end
        local ok = pcall(xtimer.add, delay_ms, post_all, 1)
        if ok then return end
    end
    post_all()
end

local function reload_process_impl(opts, explicit_defer_id)
    local _ = opts
    local current_id = xthread and xthread.current_id and xthread.current_id() or 0
    local stats = xthread and xthread.all_stats and xthread.all_stats() or {}
    local req = M.current_request()
    local defer_seen = {}
    local defer_ids = {}
    add_unique_id(defer_ids, defer_seen, reply_router_thread_id(req))
    add_unique_id(defer_ids, defer_seen, explicit_defer_id)
    if req then
        add_unique_id(defer_ids, defer_seen, current_id)
    end
    local notified = {}
    local deferred = {}
    local errors = {}

    for _, st in ipairs(stats) do
        local id = tonumber(st.id)
        if id and id > 0 then
            if defer_seen[id] then
                deferred[#deferred + 1] = id
            else
                local ok, err = xthread.post(id, '@reload_thread')
                if ok then
                    notified[#notified + 1] = id
                else
                    errors[#errors + 1] = string.format('%s:%s', tostring(id), tostring(err))
                end
            end
        end
    end

    if req and #deferred > 0 then
        local previous = req.after_reply
        req.after_reply = function()
            if previous then previous() end
            schedule_deferred_reload(deferred)
        end
    elseif #deferred > 0 then
        schedule_deferred_reload(deferred)
    end

    local ok = #errors == 0
    local msg = string.format('current=%s notified=%d deferred=%d%s%s',
        tostring(current_id), #notified, #deferred,
        #errors > 0 and ' errors=' or '',
        #errors > 0 and table.concat(errors, ',') or '')
    return ok, msg
end

local function install_builtin_reload(opts)
    M.builtins['@reload'] = opts or M.builtins['@reload'] or {}
    M.stubs['@reload'] = function(explicit_defer_id)
        return reload_process_impl(M.builtins['@reload'], explicit_defer_id)
    end
    M.builtins['@reload_thread'] = M.builtins['@reload_thread'] or {}
    M.stubs['@reload_thread'] = function()
        return call_reload()
    end
end

local function install_builtins()
    install_builtin_run_script(M.builtins['@run_script'])
    install_builtin_reload(M.builtins['@reload'])
end

-- Enable or reconfigure a builtin protocol handler.
function M.enable_builtin(name, opts)
    name = tostring(name or '')
    if name == '@run_script' then
        install_builtin_run_script(opts)
        return true
    end
    if name == '@reload' or name == '@reload_thread' then
        install_builtin_reload(opts)
        return true
    end
    return false, 'unknown builtin: ' .. name
end

-- Wipe ALL handlers and reset config. Useful for tests and explicit teardown.
-- For hot reload, you usually do NOT want this -- just let re-running the
-- worker script overwrite handlers in place (in-flight rpc_context survives).
-- If `keep_builtins=true`, builtins are reinstalled after reset.
function M.reset(opts)
    opts = opts or {}
    M.stubs            = {}
    M.rpc_context      = {}
    M.unknown_post     = opts.unknown_post
    M.unknown_rpc      = opts.unknown_rpc
    M.on_handler_error = opts.on_handler_error
    M.log_prefix       = opts.log_prefix or 'XROUTER'
    if opts.keep_builtins then
        install_builtins()
    end
    return M
end

function M.set_log_prefix(prefix)
    M.log_prefix = tostring(prefix or M.log_prefix)
    return M
end

function M.set_unknown_post(fn)
    M.unknown_post = fn
    return M
end

function M.set_unknown_rpc(fn)
    M.unknown_rpc = fn
    return M
end

function M.set_handler_error(fn)
    M.on_handler_error = fn
    return M
end

-- -------------------------------------------------------------------------
-- Registration
-- -------------------------------------------------------------------------

-- Register a handler for protocol `pt`. The handler signature is the same
-- regardless of whether the caller dispatches via POST or RPC:
--
--     function(arg1, arg2, ...) [return ret1, ret2, ...] end
--
-- Re-registering an existing pt overwrites in place (reload-safe).
function M.register(pt, handler)
    assert(type(pt) ~= 'nil', 'register: pt is required')
    assert(type(handler) == 'function', 'register: handler must be a function')
    M.stubs[pt] = handler
    return M
end

-- Resolve the request currently being served on the calling coroutine.
-- Returns the req for RPC handlers, or nil for POST handlers (since POST
-- has no reply path). Useful when a handler needs to know if it must reply.
function M.current_request()
    local co = coroutine_running()
    return co and M.rpc_context[co] or nil
end

-- -------------------------------------------------------------------------
-- Internals
-- -------------------------------------------------------------------------

-- Resume the initial RPC coroutine. The reply itself is sent from inside
-- the coroutine body (see dispatch_rpc) so that subsequent C-driven
-- `@async_resume` resumptions -- which bypass this function entirely --
-- still cause a reply to be sent when the handler finally returns.
local function resume_rpc(req, ...)
    local called = pack_values(pcall(coroutine_resume, req.co, ...))
    if not called[1] then
        local err = coroutine_error(req, called[2])
        M.rpc_context[req.co] = nil
        req.reply(req.co_id, req.sk, req.pt, false, err)
        return
    end

    local ok, err = called[2], called[3]
    if not ok then
        M.rpc_context[req.co] = nil
        -- Coroutine raised before the in-body pcall could catch it (very
        -- rare; mostly happens if create itself failed). Send an error
        -- reply so the caller doesn't hang.
        req.reply(req.co_id, req.sk, req.pt, false, coroutine_error(req, err))
        return
    end
    if coroutine_status(req.co) == 'dead' then
        M.rpc_context[req.co] = nil
    end
end

-- Resume a previously yielded RPC request coroutine.
-- Returns true on successful resume, or false + err when resume itself fails.
-- Reply emission stays in the coroutine body assembled by dispatch_rpc.
function M.resume_request(req, ...)
    if type(req) ~= 'table' or type(req.co) ~= 'thread' then
        return false, 'resume_request: invalid request'
    end
    local called = pack_values(pcall(coroutine_resume, req.co, ...))
    if not called[1] then
        M.rpc_context[req.co] = nil
        local err = coroutine_error(req, called[2])
        if req.reply and req.co_id and req.pt then
            req.reply(req.co_id, req.sk, req.pt, false, err)
        end
        return false, err
    end

    local ok, err = called[2], called[3]
    if not ok then
        M.rpc_context[req.co] = nil
        if req.reply and req.co_id and req.pt then
            req.reply(req.co_id, req.sk, req.pt, false, coroutine_error(req, err))
        end
        return false, coroutine_error(req, err)
    end
    if coroutine_status(req.co) == 'dead' then
        M.rpc_context[req.co] = nil
    end
    return true
end

function M.fail_request(req, err)
    return M.resume_request(req, false, err)
end

local function dispatch_post(k1, k2, k3, ...)
    local h = M.stubs[k1]
    if not h then
        if M.unknown_post then
            M.unknown_post(k1, k2, k3, ...)
            return
        end
        if k1 ~= nil then
            log_err('no handler for POST pt=%s', tostring(k1))
        end
        return
    end

    -- Always coroutine-wrap so the handler may freely yield (e.g. xthread.rpc
    -- out into another thread). Return values are discarded for POST.
    local nrest = select('#', ...)
    local args = { n = nrest + 2, k2, k3, ... }
    local pt = k1
    local co = coroutine_create(function()
        h(unpack_args(args, 1, args.n))
    end)
    local ok, err = coroutine_resume(co)
    if not ok then
        if M.on_handler_error then
            M.on_handler_error(pt, err)
        else
            log_err('handler error pt=%s: %s', tostring(pt), tostring(err))
        end
    end
end

local function run_after_reply(req)
    local fn = req and req.after_reply
    if type(fn) ~= 'function' then return end
    req.after_reply = nil
    local ok, err = pcall(fn)
    if not ok then
        log_err('after_reply failed pt=%s: %s', tostring(req.pt), tostring(err))
    end
end

local function dispatch_rpc(reply_router, co_id, sk, pt, ...)
    -- reply_router is the key into _thread_replys; the C runtime auto
    -- creates a closure that, when invoked, sends the reply back to the
    -- caller's thread.
    local reply = _thread_replys and _thread_replys[reply_router]
    if not reply then
        log_err('missing reply router: %s', tostring(reply_router))
        return
    end

    local h = M.stubs[pt]
    if not h then
        if M.unknown_rpc then
            M.unknown_rpc(reply_router, co_id, sk, pt, ...)
            return
        end
        reply(co_id, sk, pt, false,
              format_error(M.log_prefix, 'rpc handler not found: %s', tostring(pt)))
        return
    end

    local req = {
        co_id = co_id,
        sk = sk,
        pt = pt,
        reply_router = reply_router,
        reply = reply,
    }

    -- The coroutine body itself sends the reply on completion. This is
    -- required because nested xthread.rpc calls yield, and the C runtime
    -- resumes us via `@async_resume` interception -- bypassing our own
    -- resume_rpc wrapper. So whatever sends the reply MUST live inside
    -- the coroutine, not around it.
    --
    -- Note we look up M.stubs[pt] OUTSIDE the coroutine; the captured `h`
    -- is the handler at registration time. If you re-register `pt`
    -- mid-call, in-flight invocations finish with the OLD handler and only
    -- subsequent dispatches see the NEW one -- this is the safe semantics.
    req.co = coroutine_create(function(...)
        local function call_handler(...) return h(...) end
        local rets = pack_values(pcall(call_handler, ...))
        M.rpc_context[req.co] = nil
        if rets[1] then
            -- pcall returned (true, <handler returns...>). Forward the
            -- handler returns as `(ok=true, ret1, ret2, ...)`.
            local ok = req.reply(req.co_id, req.sk, req.pt, true,
                                 unpack_args(rets, 2, rets.n))
            if not ok then
                log_err('rpc reply route failed: pt=%s', tostring(req.pt))
            end
            run_after_reply(req)
        else
            local ok = req.reply(req.co_id, req.sk, req.pt, false, tostring(rets[2]))
            if not ok then
                log_err('rpc error reply route failed: pt=%s', tostring(req.pt))
            end
            run_after_reply(req)
        end
    end)

    M.rpc_context[req.co] = req
    resume_rpc(req, ...)
end

-- Plug this directly into the thread-def table as `__thread_handle`.
-- Signature matches what the C runtime delivers:
--   (reply_router, k1, k2, k3, ...)
--
-- Stable across reloads because M itself is the singleton stored in _G.
function M.handle(reply_router, k1, k2, k3, ...)
    if reply_router then
        dispatch_rpc(reply_router, k1, k2, k3, ...)
    else
        dispatch_post(k1, k2, k3, ...)
    end
end

-- Builtins are enabled by default.
install_builtins()

return M
