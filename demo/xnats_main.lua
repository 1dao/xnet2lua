-- Main thread for the Lua xnats demo.
-- Main starts one NATS service thread plus business workers in __init.

local xnats = dofile('demo/xnats.lua')
local xutils = require('xutils')

local CONFIG_FILE = 'demo/xnet.cfg'
local ok_cfg, cfg_err = xutils.load_config(CONFIG_FILE)
if not ok_cfg then
    io.stderr:write('[XNATS-MAIN] config not loaded: ' .. tostring(cfg_err) .. '\n')
end

local HOST = xutils.get_config('NATS_HOST', '127.0.0.1')
local PORT = tonumber(xutils.get_config('NATS_PORT', '4222')) or 4222
local PROCESS_NAME = XNET_PROCESS_NAME or xutils.get_config('SERVER_NAME', 'game1')
local PREFIX = xutils.get_config('NATS_PREFIX', 'xnet.test')
local TEST_DELAY_SEC = tonumber(xutils.get_config('NATS_TEST_DELAY_SEC', '5')) or 5
local TIMEOUT_SEC = tonumber(xutils.get_config('NATS_TEST_TIMEOUT_SEC', '30')) or 30
local PEER_PROCESS = xutils.get_config('NATS_TEST_PEER', '')
if PEER_PROCESS == 'auto' then
    if PROCESS_NAME == 'game1' then
        PEER_PROCESS = 'game2'
    elseif PROCESS_NAME == 'game2' then
        PEER_PROCESS = 'game1'
    else
        PEER_PROCESS = ''
    end
end
local hold_cfg = xutils.get_config('NATS_TEST_HOLD_SEC')
local TEST_HOLD_SEC = tonumber(hold_cfg)
if not TEST_HOLD_SEC then
    TEST_HOLD_SEC = (PEER_PROCESS ~= '' and 10 or 0)
end

local BUSINESS_THREADS = {
    { id = xthread.WORKER_GRP2, name = 'nats-biz-1', label = 'biz-1' },
    { id = xthread.WORKER_GRP2 + 1, name = 'nats-biz-2', label = 'biz-2' },
}

local business_running = {}
local broadcast_seen = {}
local broadcast_seen_count = 0
local business_done = false
local business_ok = false
local finished = false
local final_ok = true
local started_at = os.time()
local test_started = false
local holding = false
local hold_started_at = 0

_stubs = {}
_thread_replys = {}

function xthread.register(pt, h)
    _stubs[pt] = h
end

local function worker_ids()
    local out = {}
    for i, spec in ipairs(BUSINESS_THREADS) do
        out[i] = spec.id
    end
    return out
end

local function shutdown_business()
    for _, spec in ipairs(BUSINESS_THREADS) do
        if business_running[spec.id] then
            local ok, err = xthread.shutdown_thread(spec.id)
            if not ok then
                io.stderr:write('[XNATS-MAIN] shutdown business failed: ' .. tostring(err) .. '\n')
            end
            business_running[spec.id] = nil
        end
    end
end

local function request_stop(ok, msg)
    if finished then return end
    finished = true
    final_ok = ok
    print('[XNATS-MAIN] finish:', ok, msg)
    xthread.stop(ok and 0 or 1)
end

local function start_business_test()
    if test_started then return end
    test_started = true

    print(string.format('[XNATS-MAIN] start delayed test after %ds peer=%s',
        TEST_DELAY_SEC, PEER_PROCESS ~= '' and PEER_PROCESS or '(none)'))

    local ok, err = xthread.post(BUSINESS_THREADS[1].id, 'run_xnats_test',
        BUSINESS_THREADS[1].label, PROCESS_NAME, PEER_PROCESS)
    if not ok then
        error(err)
    end
end

local function check_done()
    if business_done and business_ok and broadcast_seen_count >= #BUSINESS_THREADS then
        if TEST_HOLD_SEC > 0 and not holding then
            holding = true
            hold_started_at = os.time()
            print(string.format('[XNATS-MAIN] tests ok, hold %ds for peer requests', TEST_HOLD_SEC))
        elseif TEST_HOLD_SEC <= 0 then
            request_stop(true, 'all nats tests ok')
        end
    elseif business_done and not business_ok then
        request_stop(false, 'business nats test failed')
    end
end

xthread.register('xnats_broadcast_seen', function(thread_id, from, text)
    print(string.format('[XNATS-MAIN] broadcast seen thread=%s from=%s text=%s',
        tostring(thread_id), tostring(from), tostring(text)))
    if not broadcast_seen[thread_id] then
        broadcast_seen[thread_id] = true
        broadcast_seen_count = broadcast_seen_count + 1
    end
    check_done()
end)

xthread.register('xnats_business_done', function(thread_id, ok, msg)
    print(string.format('[XNATS-MAIN] business done thread=%s ok=%s msg=%s',
        tostring(thread_id), tostring(ok), tostring(msg)))
    business_done = true
    business_ok = ok and true or false
    if not ok then
        final_ok = false
    end
    check_done()
end)

local function __thread_handle(reply_router, k1, k2, k3, ...)
    if reply_router then
        io.stderr:write('[XNATS-MAIN] unexpected RPC message: ' .. tostring(k3) .. '\n')
        return
    end

    local h = _stubs[k1]
    if h then
        h(k2, k3, ...)
    elseif k1 then
        io.stderr:write('[XNATS-MAIN] no handler for pt=' .. tostring(k1) .. '\n')
    end
end

local function __init()
    started_at = os.time()
    print(string.format('[XNATS-MAIN] init nats=%s:%d name=%s prefix=%s business=%d',
        HOST, PORT, PROCESS_NAME, PREFIX, #BUSINESS_THREADS))

    local ok, err = xnats.start({
        host = HOST,
        port = PORT,
        name = PROCESS_NAME,
        prefix = PREFIX,
        workers = worker_ids(),
        reconnect_ms = 100,
        rpc_timeout_ms = 5000,
    })
    if not ok then
        error(err)
    end

    for _, spec in ipairs(BUSINESS_THREADS) do
        ok, err = xthread.create_thread(spec.id, spec.name, 'demo/xnats_business.lua')
        if not ok then
            error(err)
        end
        business_running[spec.id] = true
    end

    if TEST_DELAY_SEC <= 0 then
        start_business_test()
    end
end

local function __update()
    if not finished and not test_started and os.time() - started_at >= TEST_DELAY_SEC then
        start_business_test()
    end

    if not finished and os.time() - started_at > TIMEOUT_SEC then
        request_stop(false, 'nats test timeout')
    end

    if not finished and holding and os.time() - hold_started_at >= TEST_HOLD_SEC then
        request_stop(true, 'all nats tests ok')
    end
end

local function __uninit()
    xnats.stop(not final_ok)
    shutdown_business()
    print('[XNATS-MAIN] uninit')
end

return {
    __init = __init,
    __update = __update,
    __uninit = __uninit,
    __thread_handle = __thread_handle,
}
