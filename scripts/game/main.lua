-- scripts/game/main.lua -- affinity game orchestrator.
--
-- Battle lanes match gate lanes one-for-one. Battle traffic remains on that
-- lane; non-battle traffic is posted to the owning work worker. NATS is used
-- for process discovery and game-to-game messages, not the hot data path.
--
-- Run with: ./bin/xnet scripts/game/main.lua SERVER_NAME=game1

local xnats = dofile('scripts/core/server/xnats.lua')
local xutils = require('xutils')
local router = dofile('scripts/core/share/xrouter.lua')
router.set_log_prefix('GAME-MAIN')

local ok_cfg, cfg_err = xutils.load_config('xnet.cfg')
if not ok_cfg then
    xthread.log_info('[GAME-MAIN] config not loaded: %s (using defaults)', tostring(cfg_err))
end

local PROCESS_NAME = XNET_PROCESS_NAME or xutils.get_config('SERVER_NAME', 'game1')
local GATE_TARGET = xutils.get_config('GAME_GATE_TARGET', '')
local GATE_HOST = xutils.get_config('GAME_GATE_HOST', '127.0.0.1')
local GATE_PORT = tonumber(xutils.get_config('GAME_GATE_PORT', '19181')) or 19181
local BATTLE_COUNT = tonumber(xutils.get_config('GAME_BATTLE_WORKERS', '6')) or 6
local WORK_COUNT = tonumber(xutils.get_config('GAME_WORK_WORKERS', '2')) or 2
local NATS_HOST = xutils.get_config('NATS_HOST', '127.0.0.1')
local NATS_PORT = tonumber(xutils.get_config('NATS_PORT', '4222')) or 4222
local NATS_PREFIX = xutils.get_config('NATS_PREFIX', 'xnet.test')
local NATS_RPC_TIMEOUT_MS = tonumber(xutils.get_config('GAME_NATS_RPC_TIMEOUT_MS', '3000')) or 3000

local MAIN_ID = xthread.MAIN
local BATTLE_BASE = xthread.WORKER_GRP1
local WORK_BASE = xthread.WORKER_GRP2
local BATTLE_SCRIPT = 'scripts/game/battle_worker.lua'
local WORK_SCRIPT = 'scripts/game/work_worker.lua'

assert(BATTLE_COUNT >= 1 and BATTLE_COUNT <= 20, 'GAME_BATTLE_WORKERS must be in [1,20]')
assert(WORK_COUNT >= 1 and WORK_COUNT <= 20, 'GAME_WORK_WORKERS must be in [1,20]')
assert(BATTLE_COUNT % WORK_COUNT == 0, 'battle/work worker counts must divide evenly')
local BATTLES_PER_WORK = BATTLE_COUNT / WORK_COUNT
assert(BATTLES_PER_WORK == 3 or BATTLES_PER_WORK == 4,
    'game work:battle ratio must be 1:3 or 1:4')

function xthread.register(pt, h) return router.register(pt, h) end

local battle_ids = {}
local work_ids = {}
local nats_running = false
local selected_gate

local function sanitize_host(v)
    local value = tostring(v or '')
    return value ~= '' and value or nil
end

local function sanitize_port(v)
    local value = tonumber(v)
    if not value or value < 1 or value > 65535 then return nil end
    return value
end

local function sanitize_count(v)
    local value = tonumber(v)
    if not value or value < 1 or value > 20 then return nil end
    return value
end

local function send_topology_to_battles(gate_name, host, base_port, gate_count)
    host = sanitize_host(host)
    base_port = sanitize_port(base_port)
    if not host or not base_port then
        xthread.log_error('[GAME-MAIN] invalid gate topology gate=%s host=%s port=%s',
            tostring(gate_name), tostring(host), tostring(base_port))
        return false
    end

    if gate_count ~= BATTLE_COUNT then
        xthread.log_error('[GAME-MAIN] gate=%s lanes=%s but battle lanes=%d',
            tostring(gate_name), tostring(gate_count), BATTLE_COUNT)
        return false
    end
    selected_gate = gate_name
    -- Single-port admission: every battle dials the same port and identifies
    -- its lane in the HELLO payload.
    for lane = 1, BATTLE_COUNT do
        local ok, err = xthread.post(battle_ids[lane], 'battle_set_gate',
            gate_name, host, base_port, gate_count)
        if not ok then
            xthread.log_error('[GAME-MAIN] lane=%d set gate failed: %s',
                lane, tostring(err))
            return false
        end
    end
    xthread.log_system('[GAME-MAIN] gate=%s endpoint=%s:%d lanes=%d',
        tostring(gate_name), host, base_port, gate_count)
    return true
end

local function query_gate_topology(name)
    if not nats_running then return nil, nil, nil, 'nats not started' end
    local ok, app_ok, host, port, count = xnats.rpc(name, 'gate_get_topology')
    if ok and app_ok == true then
        return sanitize_host(host), sanitize_port(port), sanitize_count(count)
    end
    ok, app_ok, host, port, count = xnats.rpc(name, 'gate_get_internal_addr')
    if ok and app_ok == true then
        return sanitize_host(host), sanitize_port(port),
            sanitize_count(count) or BATTLE_COUNT
    end
    return nil, nil, nil, tostring(host or app_ok or 'gate topology query failed')
end

xthread.register('gate_announce', function(name, host, base_port, worker_count)
    name = tostring(name or '')
    if name == '' then return end
    if GATE_TARGET ~= '' and name ~= GATE_TARGET then return end
    if selected_gate and selected_gate ~= 'static'
        and selected_gate ~= name and GATE_TARGET == '' then return end

    host = sanitize_host(host)
    base_port = sanitize_port(base_port)
    worker_count = sanitize_count(worker_count)
    if not host or not base_port or not worker_count then
        local qhost, qport, qcount, err = query_gate_topology(name)
        if not qhost then
            xthread.log_error('[GAME-MAIN] gate=%s topology query failed: %s',
                name, tostring(err))
            return
        end
        host, base_port, worker_count = qhost, qport, qcount
    end
    send_topology_to_battles(name, host, base_port, worker_count)
end)

xthread.register('xadmin_announce', function(_name) end)

local next_remote_work = 0
xthread.register('game_message', function(from, topic, payload)
    if #work_ids == 0 then
        return false, 'game work workers are not ready'
    end
    next_remote_work = (next_remote_work % #work_ids) + 1
    local ok, handled = xthread.rpc(work_ids[next_remote_work],
        'game_message', NATS_RPC_TIMEOUT_MS, from, topic, payload)
    if not ok then return false, handled end
    return handled
end)

local function start_workers()
    for i = 1, WORK_COUNT do
        local tid = WORK_BASE + i - 1
        local ok, err = xthread.create_thread(tid,
            string.format('game-work-%02d', i), WORK_SCRIPT)
        assert(ok, err)
        work_ids[i] = tid
        ok, err = xthread.post(tid, 'game_work_start', i, PROCESS_NAME)
        assert(ok, err)
    end

    for lane = 1, BATTLE_COUNT do
        local tid = BATTLE_BASE + lane - 1
        local work_index = math.floor((lane - 1) / BATTLES_PER_WORK) + 1
        local ok, err = xthread.create_thread(tid,
            string.format('game-battle-%02d', lane), BATTLE_SCRIPT)
        assert(ok, err)
        battle_ids[lane] = tid
        ok, err = xthread.post(tid, 'battle_start',
            lane, BATTLE_COUNT, work_ids[work_index], work_index)
        assert(ok, err)
    end
end

local function stop_workers()
    for lane = #battle_ids, 1, -1 do
        xthread.shutdown_thread(battle_ids[lane])
        battle_ids[lane] = nil
    end
    for i = #work_ids, 1, -1 do
        xthread.shutdown_thread(work_ids[i])
        work_ids[i] = nil
    end
end

local function start_nats()
    local routed_workers = { MAIN_ID }
    for i = 1, #work_ids do routed_workers[#routed_workers + 1] = work_ids[i] end
    local ok, err = xnats.start({
        host = NATS_HOST,
        port = NATS_PORT,
        name = PROCESS_NAME,
        prefix = NATS_PREFIX,
        workers = routed_workers,
        reconnect_ms = 1000,
        rpc_timeout_ms = NATS_RPC_TIMEOUT_MS,
    })
    if not ok then
        xthread.log_error('[GAME-MAIN] xnats.start failed: %s', tostring(err))
        return
    end
    nats_running = true
    xnats.bind_workers(work_ids)
    xnats.publish('xadmin_announce', PROCESS_NAME)
end

local function __init()
    xthread.log_system('[GAME-MAIN] init server=%s battles=%d works=%d ratio=1:%d',
        PROCESS_NAME, BATTLE_COUNT, WORK_COUNT, BATTLES_PER_WORK)
    assert(xnet.init())
    xtimer.init(32)
    start_workers()
    start_nats()

    -- Static endpoint lets a local deployment run even without a broker.
    send_topology_to_battles(GATE_TARGET ~= '' and GATE_TARGET or 'static',
        GATE_HOST, GATE_PORT, BATTLE_COUNT)
end

local function __uninit()
    if nats_running then xnats.stop(true); nats_running = false end
    stop_workers()
    xnet.uninit()
    xthread.log_system('[GAME-MAIN] uninit')
end

return {
    __init = __init,
    __uninit = __uninit,
    __thread_handle = router.handle,
}
