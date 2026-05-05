-- demo/xrouter_test.lua - unit tests for xrouter.lua (singleton + unified register)
-- Run via:  ./demo/xnet demo/xrouter_test.lua

local router = dofile('demo/xrouter.lua')

local fails = 0
local function check(ok, msg)
    if not ok then
        fails = fails + 1
        io.stderr:write('FAIL: ' .. tostring(msg) .. '\n')
    else
        print('PASS: ' .. tostring(msg))
    end
end

-- Set up a stub _thread_replys["xthread:99"] that records replies into a list,
-- so the RPC tests can dispatch and inspect what was sent back.
local function install_reply_capture(replies)
    _thread_replys = _thread_replys or {}
    _thread_replys['xthread:99'] = function(co_id, sk, pt, ok, ...)
        replies[#replies + 1] = {
            co_id = co_id, sk = sk, pt = pt, ok = ok, args = { ... }
        }
    end
end

-- ── Test 1: register + POST dispatch ───────────────────────────────────────
do
    router.reset({ log_prefix = 'T1' })
    local got
    router.register('hello', function(a, b, c) got = { a, b, c } end)
    router.handle(nil, 'hello', 'x', 'y', 'z')
    check(got and got[1] == 'x' and got[2] == 'y' and got[3] == 'z',
          'register + POST: handler receives args directly')
end

-- ── Test 2: register + RPC dispatch (SAME handler!) ────────────────────────
-- This is the key property: registration is calling-convention-agnostic.
do
    router.reset({ log_prefix = 'T2' })
    local replies = {}
    install_reply_capture(replies)

    -- A handler with NO knowledge of POST vs RPC.
    router.register('add', function(a, b) return a + b end)

    -- Caller dispatches via RPC.
    router.handle('xthread:99', 7, 0, 'add', 3, 4)
    local rep = replies[1]
    check(rep and rep.ok == true and rep.args[1] == 7,
          'register + RPC: same handler, return value forwarded as reply')
    check(rep.co_id == 7 and rep.pt == 'add',
          'RPC reply preserves co_id and pt')
end

-- ── Test 3: same pt usable via BOTH POST and RPC interchangeably ───────────
-- Verifies the registration site truly does not need to know the convention.
do
    router.reset({ log_prefix = 'T3' })
    local replies = {}
    install_reply_capture(replies)

    local post_seen = nil
    router.register('greet', function(name)
        post_seen = name           -- side effect, captured via POST
        return 'hello ' .. name    -- return value, sent on RPC
    end)

    -- POST: side effect runs, return value discarded (no reply).
    router.handle(nil, 'greet', 'alice')
    check(post_seen == 'alice', 'POST path: side effect runs')
    check(#replies == 0, 'POST path: no reply sent')

    -- RPC: side effect runs AND return value becomes reply.
    router.handle('xthread:99', 1, 0, 'greet', 'bob')
    check(post_seen == 'bob', 'RPC path: side effect also runs')
    check(replies[1] and replies[1].ok == true and replies[1].args[1] == 'hello bob',
          'RPC path: return value forwarded as reply')
end

-- ── Test 4: handler may yield (POST) ───────────────────────────────────────
do
    router.reset({ log_prefix = 'T4' })
    local stages = {}
    router.register('chain', function(arg)
        stages[#stages + 1] = 'enter:' .. tostring(arg)
        coroutine.yield('paused')
        stages[#stages + 1] = 'never_run_in_this_test'
    end)
    router.handle(nil, 'chain', 'go')
    check(stages[1] == 'enter:go',
          'POST handler runs synchronously up to first yield')
    check(stages[2] == nil,
          'POST handler stays suspended after yield (no error)')
end

-- ── Test 5: POST handler error → on_handler_error invoked ──────────────────
do
    router.reset({ log_prefix = 'T5' })
    local err_seen
    router.set_handler_error(function(pt, err) err_seen = { pt = pt, err = err } end)
    router.register('boom', function() error('explode') end)
    router.handle(nil, 'boom')
    check(err_seen and err_seen.pt == 'boom'
          and tostring(err_seen.err):find('explode', 1, true) ~= nil,
          'POST handler error captured via on_handler_error')
end

-- ── Test 6: RPC handler error → reply (false, errmsg) ──────────────────────
do
    router.reset({ log_prefix = 'T6' })
    local replies = {}
    install_reply_capture(replies)

    router.register('crash', function() error('rpc broke') end)
    router.handle('xthread:99', 1, 0, 'crash')
    local rep = replies[1]
    check(rep and rep.ok == false
          and tostring(rep.args[1]):find('rpc broke', 1, true) ~= nil,
          'RPC handler error becomes (ok=false, errmsg) reply')
end

-- ── Test 7: unknown POST → unknown_post fallback ───────────────────────────
do
    router.reset({ log_prefix = 'T7' })
    local seen
    router.set_unknown_post(function(pt, a) seen = { pt, a } end)
    router.handle(nil, 'nosuch', 'arg1')
    check(seen and seen[1] == 'nosuch' and seen[2] == 'arg1',
          'unknown_post called when no handler matches POST')
end

-- ── Test 8: unknown RPC → default reply with not-found error ───────────────
do
    router.reset({ log_prefix = 'T8' })
    local replies = {}
    install_reply_capture(replies)

    router.handle('xthread:99', 1, 0, 'mystery')
    local rep = replies[1]
    check(rep and rep.ok == false
          and tostring(rep.args[1]):find('rpc handler not found', 1, true) ~= nil,
          'unknown RPC pt produces ok=false reply by default')
end

-- ── Test 9: singleton — repeated dofile returns the SAME table ─────────────
do
    router.reset({ log_prefix = 'T9' })
    local r2 = dofile('demo/xrouter.lua')
    local r3 = dofile('demo/xrouter.lua')
    check(router == r2 and r2 == r3,
          'dofile returns the same singleton across calls')
    check(router.handle == r2.handle,
          'router.handle is the same function across dofile calls')
end

-- ── Test 10: distributed registration — multiple "files" share one router ──
do
    router.reset({ log_prefix = 'T10' })
    local hits = {}
    -- File A
    do
        local r = dofile('demo/xrouter.lua')
        r.register('msg_a', function() hits.a = true end)
    end
    -- File B (separate dofile, same router)
    do
        local r = dofile('demo/xrouter.lua')
        r.register('msg_b', function() hits.b = true end)
    end
    router.handle(nil, 'msg_a')
    router.handle(nil, 'msg_b')
    check(hits.a and hits.b,
          'handlers from different dofile sites all dispatch through the same router')
end

-- ── Test 11: re-register overwrites in place (reload semantics) ────────────
do
    router.reset({ log_prefix = 'T11' })
    local seen = {}
    router.register('greet', function() seen[#seen + 1] = 'v1' end)
    router.handle(nil, 'greet')
    -- Simulate hot reload: re-register the SAME pt with a NEW handler.
    router.register('greet', function() seen[#seen + 1] = 'v2' end)
    router.handle(nil, 'greet')
    check(seen[1] == 'v1' and seen[2] == 'v2',
          're-register overwrites handler in place')
    -- handle() reference is stable across re-dofile (this is what makes
    -- reload work without touching the C-side __thread_handle ref).
    local r2 = dofile('demo/xrouter.lua')
    check(router.handle == r2.handle,
          'router.handle is stable across re-dofile (reload-safe)')
end

-- ── Test 12: register validates inputs ─────────────────────────────────────
do
    router.reset({ log_prefix = 'T12' })
    local ok1 = pcall(router.register, 'x', nil)
    local ok2 = pcall(router.register, nil, function() end)
    check(not ok1, 'register rejects nil handler')
    check(not ok2, 'register rejects nil pt')
end

-- ── Test 13: reset() clears everything ─────────────────────────────────────
do
    router.reset({ log_prefix = 'T13' })
    router.register('x', function() end)
    router.register('y', function() end)
    check(router.stubs.x ~= nil, 'pre-reset: stub set')
    check(router.stubs.y ~= nil, 'pre-reset: stub set')

    router.reset()
    check(next(router.stubs) == nil, 'reset clears stubs')
end

-- ── Test 14: current_request — nil for POST, req for RPC ───────────────────
do
    router.reset({ log_prefix = 'T14' })
    local replies = {}
    install_reply_capture(replies)

    local mode
    router.register('introspect', function()
        if router.current_request() then
            mode = 'rpc'
            return 'rpc-result'
        else
            mode = 'post'
            return 'post-result'    -- discarded on POST
        end
    end)

    router.handle(nil, 'introspect')                         -- POST path
    check(mode == 'post',
          'current_request returns nil inside POST handler')

    router.handle('xthread:99', 1, 0, 'introspect')          -- RPC path
    check(mode == 'rpc',
          'current_request returns req inside RPC handler')
    check(replies[1] and replies[1].args[1] == 'rpc-result',
          'RPC path still sends return value as reply')
end

print(string.format('--- xrouter tests: %d failures ---', fails))

return {
    __init = function()
        if fails > 0 then
            io.stderr:write('TEST SUITE FAILED\n')
            os.exit(1)
        end
        xthread.stop(0)
    end,
    __update = function() end,
}
