-- xnet_main.lua -- end-to-end smoke test for scripts/core/share/xsession.lua
-- via the xrouter (positional) dispatcher path.
--
-- Run with:  ./bin/xnet demo/xnet_main.lua
--
-- This was previously a hand-written cmsgpack/len32 echo demo; it is now the
-- xsession + xrouter smoke test. The HTTP xsession yield/pipelining path is
-- covered by demo/xhttp_main.lua.
--
-- Topology:
--   MAIN   (this script)  -- listener + client + test driver
--   WORKER (worker id 10) -- xsession-based server (demo/xnet_worker.lua)
--
-- Wire format (cmsgpack-packed, len32-framed):
--   request  : pack(id:int, kind:string, pt:string, arg1, arg2, ...)
--                kind ∈ {'rpc','query','post'}
--   response : pack(id:int, ok:bool, ret1, ret2, ...)        (no response for 'post')

local cmsgpack = require 'cmsgpack'
local router   = dofile('scripts/core/share/xrouter.lua')
router.set_log_prefix('XNET-MAIN')

local HOST       = '127.0.0.1'
local PORT       = 19092
local WORKER_ID  = 10

local listener
local client_conn
local fails        = 0
local done         = false
local pending      = {}     -- id -> on_reply(ok, result)
local tests        = {}
local cur_test_idx = 0

local function check(cond, msg)
    if cond then
        print('PASS: ' .. msg)
    else
        fails = fails + 1
        io.stderr:write('FAIL: ' .. msg .. '\n')
    end
end

local function finish()
    if done then return end
    done = true
    print(string.format('\n--- xnet smoke test: %d failures ---', fails))
    if client_conn then client_conn:close('done'); client_conn = nil end
    if listener    then listener:close('done');    listener    = nil end
    xthread.shutdown_thread(WORKER_ID)
    xthread.stop(fails > 0 and 1 or 0)
end

local function send_frame(id, kind, pt, payload)
    assert(client_conn, 'send_frame: no client_conn yet')
    local body = cmsgpack.pack(id, kind, pt, payload)
    assert(client_conn:send(body), 'client_conn:send failed')
end

local function start_next_test()
    cur_test_idx = cur_test_idx + 1
    local t = tests[cur_test_idx]
    if not t then
        finish()
        return
    end
    print(string.format('\n[Test %d] %s', cur_test_idx, t.name))
    t.start()
end

-- ---------------------------------------------------------------------------
-- Test cases
-- ---------------------------------------------------------------------------

-- 1. basic rpc echo
tests[#tests + 1] = {
    name = 'echo',
    start = function()
        local id = 101
        pending[id] = function(ok, result)
            check(ok == true and result == 'hello1',
                  'echo: ok=true, payload roundtrips')
            start_next_test()
        end
        send_frame(id, 'rpc', 'echo', 'hello1')
    end,
}

-- 2. trailing nil survives cmsgpack unpack argument capture.
tests[#tests + 1] = {
    name = 'arg_count (trailing nil argument survives unpack)',
    start = function()
        local id = 151
        pending[id] = function(ok, result)
            check(ok == true and result == 1,
                  'arg_count: explicit nil payload is counted as one argument')
            start_next_test()
        end
        send_frame(id, 'rpc', 'arg_count', nil)
    end,
}

-- 3. three rpcs sent back-to-back; with len32 framing the server sees three
--    packet_cb calls. Validates queue + serial order.
tests[#tests + 1] = {
    name = 'batch-3 (responses in request order)',
    start = function()
        local got = {}
        local function on(idx) return function(ok, result)
            got[#got + 1] = { idx = idx, ok = ok, result = result }
            if #got == 3 then
                check(got[1].idx == 1 and got[2].idx == 2 and got[3].idx == 3,
                      'batch-3: responses arrive in request order')
                check(got[1].result == 'a' and got[2].result == 'b' and got[3].result == 'c',
                      'batch-3: payloads correct')
                start_next_test()
            end
        end end
        pending[301] = on(1)
        pending[302] = on(2)
        pending[303] = on(3)
        send_frame(301, 'rpc', 'echo', 'a')
        send_frame(302, 'rpc', 'echo', 'b')
        send_frame(303, 'rpc', 'echo', 'c')
    end,
}

-- 4. 3 posts (no response), then 1 rpc get_counter to verify side effect.
tests[#tests + 1] = {
    name = 'post + get_counter (side coroutine fire-and-forget)',
    start = function()
        send_frame(501, 'post', 'counter_inc', nil)
        send_frame(502, 'post', 'counter_inc', nil)
        send_frame(503, 'post', 'counter_inc', nil)
        local id = 504
        pending[id] = function(ok, result)
            check(ok == true and result == 3,
                  'post: 3 posts incremented counter to 3 (visible via rpc)')
            start_next_test()
        end
        send_frame(id, 'rpc', 'get_counter', nil)
    end,
}

-- 5. query kind: spawned in its own side coroutine, returns response.
tests[#tests + 1] = {
    name = 'query (side coroutine with response)',
    start = function()
        local id = 601
        pending[id] = function(ok, result)
            check(ok == true and result == 'q:hi',
                  'query: side coroutine produced response')
            start_next_test()
        end
        send_frame(id, 'query', 'parallel_echo', 'hi')
    end,
}

-- ---------------------------------------------------------------------------
-- Client connection wiring
-- ---------------------------------------------------------------------------

local client_handler = {}

function client_handler.on_connect(conn, ip, port)
    print(string.format('[XNET-MAIN] client connected %s:%s',
        tostring(ip), tostring(port)))
    conn:set_framing({ type = 'len32', max_packet = 1 * 1024 * 1024 })
    client_conn = conn
    start_next_test()
end

function client_handler.on_packet(_, body)
    local ok, id, app_ok, result = pcall(cmsgpack.unpack, body)
    if not ok or id == nil then
        check(false, 'client: bad cmsgpack response')
        return
    end
    local cb = pending[id]
    if not cb then
        check(false, 'client: unexpected response id=' .. tostring(id))
        return
    end
    pending[id] = nil
    cb(app_ok, result)
end

function client_handler.on_close(_, reason)
    print('[XNET-MAIN] client close: ' .. tostring(reason))
    if not done then
        if cur_test_idx <= #tests then
            check(false, 'client: connection closed before tests finished ('
                .. tostring(reason) .. ')')
        end
        finish()
    end
end

-- ---------------------------------------------------------------------------
-- Lifecycle
-- ---------------------------------------------------------------------------

local function start_client()
    print('[XNET-MAIN] connect ' .. HOST .. ':' .. PORT)
    local conn, err = xnet.connect(HOST, PORT, client_handler)
    if not conn then
        io.stderr:write('[XNET-MAIN] xnet.connect failed: ' .. tostring(err) .. '\n')
        finish()
    end
end

local function __init()
    print('[XNET-MAIN] init')
    assert(xnet.init())

    -- Spin up worker threads first so they're ready to receive accepted_fd.
    assert(xthread.create_thread(WORKER_ID, 'xnet-worker', 'demo/xnet_worker.lua'))

    listener = assert(xnet.listen_fd(HOST, PORT, {
        on_accept = function(_, fd, ip, port)
            local ok, err = xthread.post(WORKER_ID, 'accepted_fd', fd, ip, port)
            if not ok then
                io.stderr:write('[XNET-MAIN] post accepted_fd failed: '
                    .. tostring(err) .. '\n')
                return false
            end
            return true
        end,
        on_close = function(_, reason)
            print('[XNET-MAIN] listener closed: ' .. tostring(reason))
        end,
    }))
    print(string.format('[XNET-MAIN] listening on %s:%d', HOST, PORT))

    start_client()
end

local function __uninit()
    if client_conn then client_conn:close('uninit'); client_conn = nil end
    if listener    then listener:close('uninit');    listener    = nil end
    xnet.uninit()
    print('[XNET-MAIN] uninit')
end

return {
    __init   = __init,
    __uninit = __uninit,
    __thread_handle = router.handle,
}
