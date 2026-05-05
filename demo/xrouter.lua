-- xrouter.lua - per-Lua-state singleton message router for xthread workers.
--
-- Replaces the per-script copy of `_stubs / _thread_replys / __thread_handle`
-- with a single unified registration API.
--
-- Design choice: only one `register(pt, h)`. The registration site does NOT
-- know — and should not need to know — whether the caller will reach this pt
-- via POST (`xthread.post`) or RPC (`xthread.rpc`). That decision belongs to
-- the caller. Dispatch handles both shapes:
--
--   * Caller used POST → handler runs in a coroutine; return values are
--     discarded.
--   * Caller used RPC  → handler runs in a coroutine; return values become
--     the reply `(ok=true, ret1, ret2, ...)`. A raised error becomes
--     `(ok=false, errmsg)`. The handler may yield (e.g. RPC out via
--     xthread.rpc) — the reply is sent when the coroutine eventually returns.
--
-- The router is a SINGLETON per Lua state (mirrors xhttp_router): every
-- `dofile('demo/xrouter.lua')` in the same thread returns the SAME table, so
-- registrations spread across many files all accumulate into one router.
--
-- Standard worker-script shape:
--
--     local router = dofile('demo/xrouter.lua')
--     router.set_log_prefix('MYAPP')                    -- optional
--
--     router.register('hello', function(name) print('hi', name) end)
--     router.register('add',   function(a, b) return a + b end)
--     dofile('demo/handlers/extra.lua')                 -- registers more on the same router
--
--     return {
--         __init   = function() assert(xnet.init())     end,
--         __update = function() xnet.poll(10)            end,
--         __uninit = function() xnet.uninit()            end,
--         __thread_handle = router.handle,    -- ← only line that changes
--     }
--
-- Reload model: re-running the worker script overwrites handlers in place on
-- the existing singleton, while `router.handle` (referenced by the C-side
-- __thread_handle ref) and any in-flight rpc_context survive intact.

local ROUTER_KEY = '__xnet_xrouter'
local M = rawget(_G, ROUTER_KEY)
if M then return M end

local unpack_args = table.unpack or unpack

local function pack_values(...)
    return { n = select('#', ...), ... }
end

local function format_error(prefix, fmt, ...)
    return string.format('[%s] ' .. fmt, prefix, ...)
end

M = {
    log_prefix       = 'XROUTER',
    stubs            = {},   -- pt -> handler  (single unified table)
    rpc_context      = {},   -- co -> req      (in-flight RPC requests)
    unknown_post     = nil,  -- function(pt, ...) when no handler matches a POST
    unknown_rpc      = nil,  -- function(reply_router, co_id, sk, pt, ...) for RPC misses
    on_handler_error = nil,  -- function(pt, err) — POST-side coroutine top-level error
}
rawset(_G, ROUTER_KEY, M)

local function log_err(fmt, ...)
    io.stderr:write(format_error(M.log_prefix, fmt, ...) .. '\n')
end

-- ── Configuration ──────────────────────────────────────────────────────────

-- Wipe ALL handlers and reset config. Useful for tests and explicit teardown.
-- For hot reload, you usually do NOT want this — just let re-running the
-- worker script overwrite handlers in place (in-flight rpc_context survives).
function M.reset(opts)
    opts = opts or {}
    M.stubs            = {}
    M.rpc_context      = {}
    M.unknown_post     = opts.unknown_post
    M.unknown_rpc      = opts.unknown_rpc
    M.on_handler_error = opts.on_handler_error
    M.log_prefix       = opts.log_prefix or 'XROUTER'
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

-- ── Registration ───────────────────────────────────────────────────────────

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
    local co = coroutine.running()
    return co and M.rpc_context[co] or nil
end

-- ── Internals ──────────────────────────────────────────────────────────────

-- Resume the initial RPC coroutine. The reply itself is sent from inside
-- the coroutine body (see dispatch_rpc) so that subsequent C-driven
-- `@async_resume` resumptions — which bypass this function entirely —
-- still cause a reply to be sent when the handler finally returns.
local function resume_rpc(req, ...)
    local ok, err = coroutine.resume(req.co, ...)
    if not ok then
        M.rpc_context[req.co] = nil
        -- Coroutine raised before the in-body pcall could catch it (very
        -- rare; mostly happens if create itself failed). Send an error
        -- reply so the caller doesn't hang.
        req.reply(req.co_id, req.sk, req.pt, false, tostring(err))
        return
    end
    if coroutine.status(req.co) == 'dead' then
        M.rpc_context[req.co] = nil
    end
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
    local co = coroutine.create(function()
        h(unpack_args(args, 1, args.n))
    end)
    local ok, err = coroutine.resume(co)
    if not ok then
        if M.on_handler_error then
            M.on_handler_error(pt, err)
        else
            log_err('handler error pt=%s: %s', tostring(pt), tostring(err))
        end
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
        sk    = sk,
        pt    = pt,
        reply = reply,
    }
    -- The coroutine body itself sends the reply on completion. This is
    -- required because nested xthread.rpc calls yield, and the C runtime
    -- resumes us via `@async_resume` interception — bypassing our own
    -- resume_rpc wrapper. So whatever sends the reply MUST live inside
    -- the coroutine, not around it.
    --
    -- Note we look up M.stubs[pt] OUTSIDE the coroutine; the captured `h`
    -- is the handler at registration time. If you re-register `pt`
    -- mid-call, in-flight invocations finish with the OLD handler and only
    -- subsequent dispatches see the NEW one — this is the safe semantics.
    req.co = coroutine.create(function(...)
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
        else
            local ok = req.reply(req.co_id, req.sk, req.pt, false, tostring(rets[2]))
            if not ok then
                log_err('rpc error reply route failed: pt=%s', tostring(req.pt))
            end
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

return M
