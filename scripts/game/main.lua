-- scripts/game/main.lua -- affinity game orchestrator.
--
-- Battle lanes match gate lanes one-for-one. Battle traffic remains on that
-- lane; non-battle traffic is posted to the owning work worker. NATS is used
-- for process discovery and game-to-game messages, not the hot data path.
--
-- Run with: ./bin/xnet scripts/game/main.lua SERVER_NAME=game1

local xnats = dofile('scripts/core/server/xnats.lua')
local xredis = dofile('scripts/core/server/xredis.lua')
local xutils = require('xutils')
local router = dofile('scripts/core/share/xrouter.lua')
local peer_codec = dofile('scripts/game/peer_codec.lua')
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
local GAME_INDEX = tonumber(xutils.get_config('GAME_INDEX', '1')) or 1
local GAME_COUNT = tonumber(xutils.get_config('GAME_COUNT', '1')) or 1
local PEER_HOST = xutils.get_config('GAME_PEER_HOST', '127.0.0.1')
local PEER_PORT = tonumber(xutils.get_config('GAME_PEER_PORT', '19190')) or 19190
local NATS_HOST = xutils.get_config('NATS_HOST', '127.0.0.1')
local NATS_PORT = tonumber(xutils.get_config('NATS_PORT', '4222')) or 4222
local NATS_PREFIX = xutils.get_config('NATS_PREFIX', 'xnet.test')
local NATS_RPC_TIMEOUT_MS = tonumber(xutils.get_config('GAME_NATS_RPC_TIMEOUT_MS', '3000')) or 3000
local HEARTBEAT_MS = tonumber(xutils.get_config('GAME_HEARTBEAT_MS', '5000')) or 5000
local REDIS_HOST = xutils.get_config('REDIS_HOST', '127.0.0.1')
local REDIS_PORT = tonumber(xutils.get_config('REDIS_PORT', '6379')) or 6379
local REDIS_DB = tonumber(xutils.get_config('REDIS_DB', '0')) or 0
local REDIS_POOL = tonumber(xutils.get_config('REDIS_POOL', '4')) or 4

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
local redis_running = false
local selected_gate
local peer_listener
local peer_admission_pending = {}    -- conn -> { ip, port }
local dialed_peers = {}              -- peer_game_id -> true (dial broadcast sent)
local heartbeat_timer

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

local function broadcast_peer_dial(peer_game, host, port)
    for lane = 1, BATTLE_COUNT do
        local tid = battle_ids[lane]
        if tid then xthread.post(tid, 'peer_dial', peer_game, host, port) end
    end
end

-- Peer discovery (§6 / §0.7): NATS carries the announce, never hot data. We dial
-- only Games with a smaller id; higher-id Games dial us (one link per pair). The
-- battle lanes dedup repeat dials, so re-broadcasting on every heartbeat is safe.
xthread.register('game_announce', function(name, peer_game, host, port, lane_count)
    peer_game = tonumber(peer_game)
    if not peer_game or peer_game >= GAME_INDEX then return end   -- self / we accept
    host = sanitize_host(host)
    port = sanitize_port(port)
    if not host or not port then return end
    if tonumber(lane_count) and tonumber(lane_count) ~= BATTLE_COUNT then
        if not dialed_peers[peer_game] then
            dialed_peers[peer_game] = true
            xthread.log_error('[GAME-MAIN] peer game=%d lanes=%s != my lanes=%d, skip',
                peer_game, tostring(lane_count), BATTLE_COUNT)
        end
        return
    end
    broadcast_peer_dial(peer_game, host, port)
    if not dialed_peers[peer_game] then
        dialed_peers[peer_game] = true
        xthread.log_system('[GAME-MAIN] dial peer game=%d at %s:%d (lanes=%d)',
            peer_game, tostring(host), port, BATTLE_COUNT)
    end
end)

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

    -- Now that every battle tid exists, hand each lane the full directory so it
    -- can xthread.post to any sibling lane (zone owner <-> player home routing).
    for lane = 1, BATTLE_COUNT do
        local ok, err = xthread.post(battle_ids[lane], 'battle_peers',
            GAME_INDEX, battle_ids, GAME_COUNT)
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

-- §19.1.4 write-through target. xredis runs a singleton REDIS service thread; the
-- work workers each dofile xredis and RPC their HGETALL/HSET to it, so the store's
-- load/write never block a battle lane. Start it before the workers so the first
-- player spawn can cold-load.
local function start_redis()
    local ok, err = xredis.start({
        host = REDIS_HOST,
        port = REDIS_PORT,
        db = REDIS_DB,
        pool_size = REDIS_POOL,
        reconnect_ms = 1000,
    })
    if not ok then
        xthread.log_error('[GAME-MAIN] xredis.start failed: %s', tostring(err))
        return
    end
    redis_running = true
    xthread.log_system('[GAME-MAIN] redis %s:%d db=%d pool=%d',
        REDIS_HOST, REDIS_PORT, REDIS_DB, REDIS_POOL)
end

local function publish_heartbeat()
    if not nats_running then return end
    xnats.publish('xadmin_announce', PROCESS_NAME)
    xnats.publish('game_announce', PROCESS_NAME, GAME_INDEX, PEER_HOST, PEER_PORT, BATTLE_COUNT)
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
    publish_heartbeat()
    heartbeat_timer = xtimer.add(HEARTBEAT_MS, publish_heartbeat, -1)
end

-- Peer admission (§6.1): mirrors the gate's single-port admission. A peer lane
-- dials here, sends a PEER HELLO, and we detach the fd to the same lane index.
local peer_admission_handler = {}

function peer_admission_handler.on_connect(conn, ip, port)
    conn:set_framing({ type = 'len16', max_packet = 64 })
    peer_admission_pending[conn] = { ip = ip, port = port }
end

function peer_admission_handler.on_packet(conn, body)
    local st = peer_admission_pending[conn]
    if not st then
        conn:close('peer_admission_extra_packet')
        return
    end
    peer_admission_pending[conn] = nil
    local peer_game, lane, err = peer_codec.decode_hello(body)
    if not peer_game then
        xthread.log_error('[GAME-MAIN] peer admission bad hello from %s:%s: %s',
            tostring(st.ip), tostring(st.port), tostring(err))
        conn:close('peer_bad_hello')
        return
    end
    if lane < 1 or lane > BATTLE_COUNT then
        xthread.log_error('[GAME-MAIN] peer admission bad lane=%d (lanes=%d)',
            lane, BATTLE_COUNT)
        conn:close('peer_lane_out_of_range')
        return
    end
    local target_tid = battle_ids[lane]
    if not target_tid then
        conn:close('peer_lane_unready')
        return
    end
    local fd = conn:detach()
    local ok, perr = xthread.post(target_tid, 'peer_accept', fd, peer_game)
    if not ok then
        xthread.log_error('[GAME-MAIN] peer admission post lane=%d failed: %s; closing fd',
            lane, tostring(perr))
        xnet.close_fd(fd)
        return
    end
    xthread.log_info('[GAME-MAIN] peer admission: game=%d lane=%d -> tid=%d',
        peer_game, lane, target_tid)
end

function peer_admission_handler.on_close(conn, reason)
    if peer_admission_pending[conn] then
        peer_admission_pending[conn] = nil
    end
end

local function listen_peers()
    if GAME_COUNT <= 1 then
        xthread.log_system('[GAME-MAIN] GAME_COUNT=1, peer mesh disabled')
        return
    end
    peer_listener = assert(xnet.listen(PEER_HOST, PEER_PORT, peer_admission_handler))
    xthread.log_system('[GAME-MAIN] peer admission %s:%d game=%d lanes=%d',
        PEER_HOST, PEER_PORT, GAME_INDEX, BATTLE_COUNT)
end

local function __init()
    xthread.log_system('[GAME-MAIN] init server=%s battles=%d works=%d ratio=1:%d',
        PROCESS_NAME, BATTLE_COUNT, WORK_COUNT, BATTLES_PER_WORK)
    assert(xnet.init())
    xtimer.init(32)
    start_redis()
    start_workers()
    start_nats()
    listen_peers()

    -- Static endpoint lets a local deployment run even without a broker.
    send_topology_to_battles(GATE_TARGET ~= '' and GATE_TARGET or 'static',
        GATE_HOST, GATE_PORT, BATTLE_COUNT)
end

local function __uninit()
    if heartbeat_timer then heartbeat_timer:del(); heartbeat_timer = nil end
    if peer_listener then peer_listener:close('uninit'); peer_listener = nil end
    for conn in pairs(peer_admission_pending) do conn:close('uninit') end
    peer_admission_pending = {}
    if nats_running then xnats.stop(true); nats_running = false end
    stop_workers()                 -- workers force-flush their stores on the way out
    if redis_running then xredis.stop(); redis_running = false end
    xnet.uninit()
    xthread.log_system('[GAME-MAIN] uninit')
end

return {
    __init = __init,
    __uninit = __uninit,
    __thread_handle = router.handle,
}
