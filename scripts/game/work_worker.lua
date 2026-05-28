-- scripts/game/work_worker.lua -- non-battle game work lane.
--
-- Battle workers delegate non-realtime operations here. Remote game process
-- messages also land on work workers through xnats, keeping battle loops free
-- of cross-process RPC handling.

local xnats = dofile('scripts/core/server/xnats.lua')
local router = dofile('scripts/core/share/xrouter.lua')
router.set_log_prefix('GAME-WORK')

function xthread.register(pt, h) return router.register(pt, h) end

local OP_PING = 0x0002
local index = 0
local process_name = 'game1'

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

xthread.register('battle_session_gone', function(lane, sid)
    print(string.format('[GAME-WORK:%d] lane=%s sid=%s gone',
        index, tostring(lane), tostring(sid)))
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
end

local function __uninit()
    xnet.uninit()
end

return {
    __init = __init,
    __uninit = __uninit,
    __thread_handle = router.handle,
}
