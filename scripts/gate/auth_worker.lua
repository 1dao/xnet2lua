-- scripts/gate/auth_worker.lua -- the gate's weak-auth admission lane.
--
-- Recv end of the "weak-auth first, strong-AEAD after migration" placement scheme
-- (design §4 / §19.0 身份 ≠ 位置). A client connects HERE first and sends one login
-- frame (a ticket, optionally a claimed account_id). This lane:
--   1. resolves the frame to a STABLE account_id (auth.lua; mock verifier in v1),
--   2. derives the owning shard lane = hash(account_id)%T via zone_def's single
--      affinity hash site, so it equals the player's battle home lane exactly,
--   3. hands the raw fd to that lane's gate worker -- the same admission handoff
--      gate/main.lua already uses for battle connections. NOTHING but (fd,
--      account_id) travels, because no AEAD state exists yet; the worker runs the
--      AEAD handshake AFTER the fd lands, so the heavy crypto happens once, on the
--      lane the session will actually live on.
--
-- The decision lives in admit.lua (pure, unit-tested by admit_spec). This file is the
-- socket glue around it.
--
-- The RECV half of the handoff is done: gate/worker.lua handles 'client_admit'
-- (attach, send the 1-byte PROCEED ack, then run the existing AEAD handshake). The
-- whole login-frame -> admit -> fd-handoff -> PROCEED path is exercised over real
-- sockets by demo/gate_admit_main.lua.
--
-- NOT YET ON THE LIVE ACCEPT PATH. The cutover's remaining steps change the client
-- login protocol, so they need live/manual verification and are kept out until then:
--   * gate/main.lua: start this thread and route new client accepts to 'auth_accept'
--     here, instead of the round-robin pick_client_worker.
--   * the client: send the login ticket first and await PROCEED before the salt, so
--     no AEAD-handshake bytes are pipelined into this lane's framing buffer (which
--     detach() would drop).
--   * gate/worker.lua: bind the battle session under the carried account_id (the
--     permanent player_id), replacing the client-sent OP_LOGIN -- the seam the admit
--     handler records on conn_state today.

local router = dofile('scripts/core/share/xrouter.lua')
local auth = dofile('scripts/gate/auth.lua')
local admit = dofile('scripts/gate/admit.lua')
local zone_def = dofile('scripts/game/zone_def.lua')
router.set_log_prefix('GATE-AUTH')

function xthread.register(pt, h) return router.register(pt, h) end

local TOKEN_FRAME_MAX = 4096          -- a login ticket is small; cap the pre-auth buffer
local worker_base = 0
local worker_count = 0
local resolver = auth.new({})         -- v1: mock verifier (random-but-stable id per token)
local pending = {}                    -- conn -> { ip, port }

-- The shard is the LANE component of the permanent home (game, lane). The gate fronts
-- one game's T lanes, and GATE_WORKERS must equal zone_def.LANE_COUNT so a lane maps
-- 1:1 onto a worker. Single player-affinity hash site (design §19.1 hook 2).
local function lane_for(account_id)
    return (select(2, zone_def.resolve_player_home(account_id)))
end

local client_handler = {}

function client_handler.on_connect(conn, ip, port)
    conn:set_framing({ type = 'len16', max_packet = TOKEN_FRAME_MAX })
    pending[conn] = { ip = ip, port = port }
end

function client_handler.on_packet(conn, body)
    local st = pending[conn]
    if not st then conn:close('auth_extra_packet'); return end
    pending[conn] = nil          -- one login frame per connection on this lane

    local d = admit.decide(body, { resolver = resolver, lane_for = lane_for })
    if not d.ok then
        print(string.format('[GATE-AUTH] reject %s:%s reason=%s',
            tostring(st.ip), tostring(st.port), tostring(d.reason)))
        conn:close('auth_' .. tostring(d.reason))
        return
    end

    local target = worker_base + d.lane - 1
    -- Surrender the fd (conn dies, fd stays open) and hand it to the owning lane.
    -- No AEAD state exists yet, so this is a bare fd move -- the cheap migration the
    -- scheme buys. The worker establishes AEAD after re-attaching.
    local fd = conn:detach()
    local ok, err = xthread.post(target, 'client_admit', fd, st.ip, st.port, d.account_id)
    if not ok then
        print(string.format('[GATE-AUTH] handoff lane=%d tid=%d failed: %s; closing fd',
            d.lane, target, tostring(err)))
        xnet.close_fd(fd)
        return
    end
    print(string.format('[GATE-AUTH] %s:%s account=%d -> lane=%d (src=%s)',
        tostring(st.ip), tostring(st.port), d.account_id, d.lane, tostring(d.src)))
end

function client_handler.on_close(conn, reason)
    if pending[conn] then
        pending[conn] = nil
        print(string.format('[GATE-AUTH] closed pre-auth: %s', tostring(reason)))
    end
end

-- worker_base is the tid of lane 1 (xthread.WORKER_GRP1 in gate/main); lane L's
-- worker is worker_base + L - 1, the same arithmetic gate/main uses to spawn them.
xthread.register('gate_auth_start', function(base, count)
    worker_base = tonumber(base) or 0
    worker_count = tonumber(count) or 0
    print(string.format('[GATE-AUTH] start worker_base=%d count=%d',
        worker_base, worker_count))
end)

xthread.register('auth_accept', function(fd, ip, port)
    local conn, err = xnet.attach(fd, client_handler, ip, port)
    if not conn then
        io.stderr:write('[GATE-AUTH] client attach failed: ' .. tostring(err) .. '\n')
    end
end)

local function __init()
    assert(xnet.init())
end

local function __uninit()
    for conn in pairs(pending) do conn:close('uninit') end
    pending = {}
    xnet.uninit()
end

return {
    __init = __init,
    __uninit = __uninit,
    __thread_handle = router.handle,
}
