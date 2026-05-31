-- scripts/gate/worker.lua -- one affinity lane for client and battle sockets.
--
-- A worker owns its client sessions and exactly one matching battle
-- connection. Packet forwarding therefore stays on this OS/Lua thread.

local router = dofile('scripts/core/share/xrouter.lua')
router.set_log_prefix('GATE-WORKER')

-- SID bit layout lives in exactly one place (design §19.1 hook 7).
local sidcodec = dofile('scripts/gate/sid.lua')

function xthread.register(pt, h) return router.register(pt, h) end

local K_C2S = string.rep('\1', 32)
local K_S2C = string.rep('\2', 32)
local CLIENT_MAX_BODY = 65535 - 24
local SESSION_GONE = 0xFFFE
local BATTLE_ACK = string.char(0x01)    -- single-byte ACK sent right after attach
local CLIENT_PROCEED = string.char(0x01) -- 1-byte ack to an admitted client: your fd
                                         -- landed on its owning lane, begin handshake

local lane = 0
local lane_count = 0
local next_local_sid = 1
local battle_conn
local sessions = {}
local conn_to_sid = {}
local conn_state = {}
local admit_account_by_fd = {}   -- fd -> account_id, carried from client_admit into
                                 -- admit_handler.on_connect (attach takes no extras)

local function u16be(n)
    return string.char(math.floor(n / 256) % 256, n % 256)
end

local function u32be(n)
    return string.char(
        math.floor(n / 16777216) % 256,
        math.floor(n / 65536) % 256,
        math.floor(n / 256) % 256,
        n % 256)
end

local function r32be(s, i)
    local b1, b2, b3, b4 = string.byte(s, i, i + 3)
    return b1 * 16777216 + b2 * 65536 + b3 * 256 + b4
end

local function alloc_sid()
    local sid = sidcodec.encode(lane, next_local_sid)   -- single-site SID layout
    if not sid then return nil end                       -- lane<1 or seq exhausted
    next_local_sid = next_local_sid + 1
    return sid
end

local client_handler = {}

function client_handler.on_connect(conn, ip, port)
    local sid = alloc_sid()
    if not sid then
        conn:close('session_id_exhausted')
        return
    end
    sessions[sid] = conn
    conn_to_sid[conn] = sid
    conn_state[conn] = { ready = false, gate_salt = xnet.random_bytes(4) }
    conn:set_framing({ type = 'len16', max_packet = 64 * 1024 })
    print(string.format('[GATE-WORKER:%d] sid=%d client %s:%s awaiting salt',
        lane, sid, tostring(ip), tostring(port)))
end

function client_handler.on_packet(conn, body)
    local sid = conn_to_sid[conn]
    local state = conn_state[conn]
    if not sid or not state then return end

    if not state.ready then
        if #body ~= 4 then
            conn:close('bad_handshake')
            return
        end
        local ok, err = conn:send(state.gate_salt)
        if not ok then
            print(string.format('[GATE-WORKER:%d] sid=%d handshake send failed: %s',
                lane, sid, tostring(err)))
            conn:close('handshake_send_failed')
            return
        end
        conn:enable_aead(K_S2C, K_C2S, state.gate_salt, body)
        state.ready = true
        return
    end

    if not battle_conn then
        conn:close('no_battle_backend')
        return
    end
    if #body < 2 then return end

    local ok, err = battle_conn:send(u32be(sid) .. body)
    if not ok then
        print(string.format('[GATE-WORKER:%d] sid=%d battle send failed: %s',
            lane, sid, tostring(err)))
        conn:close('battle_send_failed')
    end
end

function client_handler.on_close(conn, reason)
    local sid = conn_to_sid[conn]
    if not sid then return end
    sessions[sid] = nil
    conn_to_sid[conn] = nil
    conn_state[conn] = nil
    print(string.format('[GATE-WORKER:%d] sid=%d closed: %s',
        lane, sid, tostring(reason)))
    if battle_conn then
        battle_conn:send(u32be(sid) .. u16be(SESSION_GONE))
    end
end

-- Admitted-client lane (weak-auth scheme, design §4/§19.0). The auth lane
-- (auth_worker.lua) already resolved this fd to a permanent account_id and chose
-- THIS lane = hash(account_id)%T; it surrenders the bare fd (no AEAD state exists
-- yet). We ack PROCEED, then run the SAME salt/AEAD handshake + forwarding as a
-- directly-accepted client -- sharing on_packet/on_close keeps one code path.
local admit_handler = {}

function admit_handler.on_connect(conn, ip, port)
    local fd = conn:fd()
    local account_id = admit_account_by_fd[fd]
    admit_account_by_fd[fd] = nil
    local sid = alloc_sid()
    if not sid then
        conn:close('session_id_exhausted')
        return
    end
    sessions[sid] = conn
    conn_to_sid[conn] = sid
    -- account_id is the permanent player_id; recorded as the seam the gate->battle
    -- session bind will read (it replaces the client-sent OP_LOGIN player_id).
    conn_state[conn] = {
        ready = false, gate_salt = xnet.random_bytes(4), account_id = account_id,
    }
    conn:set_framing({ type = 'len16', max_packet = 64 * 1024 })
    -- PROCEED must be sent from HERE (post-attach, on the owning lane), never from
    -- the auth lane: a client that pipelined its salt would otherwise drop those
    -- bytes into the auth lane's framing buffer, which detach() discards.
    local ok, err = conn:send(CLIENT_PROCEED)
    if not ok then
        print(string.format('[GATE-WORKER:%d] sid=%d proceed send failed: %s',
            lane, sid, tostring(err)))
        conn:close('proceed_send_failed')
        return
    end
    print(string.format('[GATE-WORKER:%d] sid=%d admit account=%s %s:%s awaiting salt',
        lane, sid, tostring(account_id), tostring(ip), tostring(port)))
end

-- After PROCEED the handshake + forwarding are identical to a direct accept.
admit_handler.on_packet = client_handler.on_packet
admit_handler.on_close  = client_handler.on_close

local battle_handler = {}

function battle_handler.on_connect(conn, ip, port)
    if battle_conn then
        conn:close('duplicate_battle_lane')
        return
    end
    conn:set_framing({ type = 'len16', max_packet = 64 * 1024 })
    battle_conn = conn
    -- ACK tells the battle side that admission has handed us the fd
    -- and the lane is ready for business traffic.
    local ok, err = conn:send(BATTLE_ACK)
    if not ok then
        print(string.format('[GATE-WORKER:%d] battle ack send failed: %s',
            lane, tostring(err)))
        conn:close('ack_send_failed')
        return
    end
    print(string.format('[GATE-WORKER:%d] battle connected %s:%s (ack sent)',
        lane, tostring(ip), tostring(port)))
end

function battle_handler.on_packet(conn, body)
    if conn ~= battle_conn or #body < 6 then return end
    local sid = r32be(body, 1)
    local client = sessions[sid]
    if not client then return end
    local client_body = string.sub(body, 5)
    if #client_body > CLIENT_MAX_BODY then
        client:close('reply_too_large')
        return
    end
    local ok, err = client:send(client_body)
    if not ok then
        print(string.format('[GATE-WORKER:%d] sid=%d client send failed: %s',
            lane, sid, tostring(err)))
        client:close('client_send_failed')
    end
end

function battle_handler.on_close(conn, reason)
    if conn == battle_conn then
        battle_conn = nil
        print(string.format('[GATE-WORKER:%d] battle closed: %s',
            lane, tostring(reason)))
    end
end

xthread.register('gate_worker_start', function(index, total)
    lane = tonumber(index) or 0
    lane_count = tonumber(total) or 0
    router.set_log_prefix('GATE-WORKER-' .. tostring(lane))
    print(string.format('[GATE-WORKER:%d] start lanes=%d', lane, lane_count))
end)

xthread.register('client_accept', function(fd, ip, port)
    local conn, err = xnet.attach(fd, client_handler, ip, port)
    if not conn then
        io.stderr:write('[GATE-WORKER] client attach failed: ' .. tostring(err) .. '\n')
    end
end)

xthread.register('battle_accept', function(fd, ip, port)
    local conn, err = xnet.attach(fd, battle_handler, ip, port)
    if not conn then
        io.stderr:write('[GATE-WORKER] battle attach failed: ' .. tostring(err) .. '\n')
    end
end)

-- The auth lane hands us a weak-auth-admitted fd plus its resolved account_id.
xthread.register('client_admit', function(fd, ip, port, account_id)
    admit_account_by_fd[fd] = account_id
    local conn, err = xnet.attach(fd, admit_handler, ip, port)
    if not conn then
        admit_account_by_fd[fd] = nil
        xnet.close_fd(fd)
        io.stderr:write('[GATE-WORKER] client_admit attach failed: '
            .. tostring(err) .. '\n')
    end
end)

local function __init()
    assert(xnet.init())
end

local function __uninit()
    for _, conn in pairs(sessions) do conn:close('uninit') end
    sessions = {}
    conn_to_sid = {}
    conn_state = {}
    if battle_conn then battle_conn:close('uninit'); battle_conn = nil end
    xnet.uninit()
end

return {
    __init = __init,
    __uninit = __uninit,
    __thread_handle = router.handle,
}
