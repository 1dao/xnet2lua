-- scripts/game/work_worker.lua -- non-battle game work lane.
--
-- Battle workers delegate non-realtime operations here. Remote game process
-- messages also land on work workers through xnats, keeping battle loops free
-- of cross-process RPC handling.

local xnats = dofile('scripts/core/server/xnats.lua')
local xredis = dofile('scripts/core/server/xredis.lua')
local router = dofile('scripts/core/share/xrouter.lua')
local playerstore = dofile('scripts/game/playerstore.lua')
local playerstore_redis = dofile('scripts/game/playerstore_redis.lua')
router.set_log_prefix('GAME-WORK')

function xthread.register(pt, h) return router.register(pt, h) end

local OP_PING = 0x0002
local PERSIST_TICK_MS = 1000        -- write-through drain + disconnect-grace reap
local index = 0
local process_name = 'game1'
local persist_timer

local function now_ms()
    if xtimer and xtimer.now_ms then
        return xtimer.now_ms()
    end
    return math.floor(os.time() * 1000)
end

-- This work worker owns its lane's resident player store. Design §19.1.4 puts
-- persistent state write-through on the non-battle lane (never accumulated as dirty
-- memory on the battle frame), and reclaims a player 30s after disconnect. v1 sid
-- doubles as the player id (one connection == one player), so the store keys by sid.
--
-- load/write are backed by the Redis sink: HGETALL on cold spawn, field-level HSET
-- (fire-and-forget, off the battle frame) on flush. The REDIS service thread is
-- started once by game/main; every work worker RPCs HGETALL/HSET to it.
local store = playerstore.new(playerstore_redis.make(xredis))

xthread.register('game_work_start', function(worker_index, name)
    index = tonumber(worker_index) or 0
    process_name = tostring(name or process_name)
    router.set_log_prefix('GAME-WORK-' .. tostring(index))
    print(string.format('[GAME-WORK:%d] start process=%s', index, process_name))
end)

xthread.register('gate_announce', function(_name, _host, _port, _count) end)
xthread.register('xadmin_announce', function(_name) end)

xthread.register('from_battle', function(battle_tid, lane, sid, opcode, payload)
    if opcode == OP_PING then
        xthread.post(battle_tid, 'work_reply', sid, OP_PING, 'pong')
        return
    end
    print(string.format('[GAME-WORK:%d] lane=%s sid=%s unhandled opcode=0x%04X bytes=%d',
        index, tostring(lane), tostring(sid), tonumber(opcode) or 0, #(payload or '')))
end)

-- Player entered the world on a battle lane (§19.1.3 lifecycle spawn). v1 cold-loads
-- with no runtime hint; v2's MIGRATE recv end calls the SAME spawn with the carried
-- runtime態. Deliberately a standalone handler, not folded into a login step (§19.3 #6).
--
-- spawn() cold-loads the persistent state (HGETALL, which yields this coroutine off
-- the battle frame), so build_entity(persistent, ...) can resolve the spawn position
-- FROM Redis: a returning player spawns at the logout location we wrote through last
-- disconnect; a first-login player (no saved x/y) falls back to the coords the client
-- proposed. We reply 'spawn_at' to the requesting battle lane, which builds the live
-- entity -- the battle frame never blocks on the load.
xthread.register('battle_session_new', function(battle_tid, lane, sid, fx, fy)
    store:spawn(sid, nil, now_ms())
    -- persistent hash values round-trip as strings (playerstore_redis limitation);
    -- tonumber recovers the integer, or nil -> fall back to the client's coords.
    local x = tonumber(store:get(sid, 'x')) or fx
    local y = tonumber(store:get(sid, 'y')) or fy
    if battle_tid and x and y then
        xthread.post(battle_tid, 'spawn_at', sid, x, y)
    end
    print(string.format('[GAME-WORK:%d] lane=%s sid=%s spawn pos=%s,%s',
        index, tostring(lane), tostring(sid), tostring(x), tostring(y)))
end)

xthread.register('battle_session_gone', function(lane, sid, x, y)
    -- §19.1.4 hook (4) write-through, made non-vacuous: the battle lane hands us
    -- the player's logout position, which we mark as dirty persistent state. set()
    -- never touches Redis itself -- the persist_timer's flush() drains the dirty
    -- (x,y) to Redis via HSET within the time bound, off the battle frame. Position
    -- is a real persistent field (first-class in OP_ENTER_WORLD/OP_MOVE), not a
    -- fabricated stat, so this exercises the genuine v1 write-through path.
    local t = now_ms()
    if x ~= nil and y ~= nil then
        store:set(sid, 'x', x, t)
        store:set(sid, 'y', y, t)
    end
    -- A gone session starts the disconnect grace -- memory is kept briefly so a
    -- quick return skips the cold load, then reap() reclaims it (force-flushing any
    -- field changed in the last sub-second). v1 never reuses a sid (a returning
    -- client gets a fresh one), so the entry just ages out: the "断线 30s 没回来 →
    -- 清内存,不丢数据" path.
    store:disconnect(sid, t)
    print(string.format('[GAME-WORK:%d] lane=%s sid=%s gone pos=%s,%s',
        index, tostring(lane), tostring(sid), tostring(x), tostring(y)))
end)

-- Public game-to-game entry point. Remote calls are deliberately served on
-- work workers because NATS should not schedule work onto battle lanes.
xthread.register('game_message', function(from, topic, payload)
    print(string.format('[GAME-WORK:%d] remote from=%s topic=%s bytes=%d',
        index, tostring(from), tostring(topic), #(payload or '')))
    return true
end)

xthread.register('send_game_message', function(target, topic, payload)
    return xnats.rpc(target, 'game_message', process_name, topic, payload)
end)

local function __init()
    assert(xnet.init())
    xtimer.init(32)
    -- §19.1.4: drain dirty persistent state to Redis within a time bound and reclaim
    -- players past the disconnect grace. Runs off the battle frame, so a slow write
    -- never stalls a battle loop.
    persist_timer = xtimer.add(PERSIST_TICK_MS, function()
        local t = now_ms()
        store:flush(t, false)
        store:reap(t)
    end, -1)
end

local function __uninit()
    if persist_timer then persist_timer:del(); persist_timer = nil end
    store:flush(now_ms(), true)     -- force-flush so shutdown loses no data
    xnet.uninit()
end

return {
    __init = __init,
    __uninit = __uninit,
    __thread_handle = router.handle,
}
