-- scripts/gate/client_worker.lua -- gate's client-facing worker.
--
-- Owns every client connection, the session_id table, the salt handshake,
-- and the AEAD transform install. All bodies destined for the game backend
-- are forwarded via xthread.post(game_worker, 'forward_to_game', sid, body).

local router = dofile('scripts/core/share/xrouter.lua')
router.set_log_prefix('GATE-CLIENT')

-- xhttp_worker.lua-style override: any xthread.register() call below routes
-- through xrouter, and incoming posts arrive via __thread_handle = router.handle.
function xthread.register(pt, h) return router.register(pt, h) end

-- Pre-shared AEAD keys (v0 placeholder; ECDH would derive these per session).
local K_C2S = string.rep('\1', 32)
local K_S2C = string.rep('\2', 32)

-- LEN16 wire is capped at 65535 B; AEAD adds seq(8) + tag(16) = 24 B overhead.
local CLIENT_MAX_BODY = 65535 - 24

local game_worker_id = nil
local game_up        = false

local sessions    = {}   -- sid -> conn
local conn_to_sid = {}   -- conn -> sid
local conn_state  = {}   -- conn -> { ready = bool, gate_salt = string }
local next_sid    = 1

-- ============================================================================
-- Client connection handler
-- ============================================================================
local client_handler = {}

function client_handler.on_connect(conn, ip, port)
    local sid = next_sid; next_sid = next_sid + 1
    sessions[sid] = conn
    conn_to_sid[conn] = sid
    conn_state[conn] = { ready = false, gate_salt = xnet.random_bytes(4) }
    conn:set_framing({ type = 'len16', max_packet = 64 * 1024 })
    print(string.format('[GATE-CLIENT] sid=%d connect %s:%s (awaiting salt)',
        sid, tostring(ip), tostring(port)))
end

function client_handler.on_packet(conn, body)
    local sid = conn_to_sid[conn]
    if not sid then return end
    local st = conn_state[conn]
    if not st then return end

    if not st.ready then
        -- Handshake: client sends its 4-byte send_salt, gate replies with its
        -- own, then both flip AEAD on with swapped salts.
        if #body ~= 4 then
            print(string.format('[GATE-CLIENT] sid=%d bad handshake len=%d, closing',
                sid, #body))
            conn:close('bad_handshake')
            return
        end
        local client_salt = body
        local ok, err = conn:send(st.gate_salt)
        if not ok then
            print(string.format('[GATE-CLIENT] sid=%d handshake reply failed: %s',
                sid, tostring(err)))
            conn:close('handshake_send_failed')
            return
        end
        conn:enable_aead(K_S2C, K_C2S, st.gate_salt, client_salt)
        st.ready = true
        print(string.format('[GATE-CLIENT] sid=%d handshake done, AEAD on', sid))
        return
    end

    if not game_up then
        -- Backend known to be down; close immediately so the client's on_close
        -- handler fires rather than letting the request sit forever.
        print(string.format('[GATE-CLIENT] sid=%d closing: game down', sid))
        conn:close('no_backend')
        return
    end

    if #body < 2 then
        print(string.format('[GATE-CLIENT] sid=%d short packet (%d bytes)', sid, #body))
        return
    end

    local ok, err = xthread.post(game_worker_id, 'forward_to_game', sid, body)
    if not ok then
        print(string.format('[GATE-CLIENT] sid=%d post forward_to_game failed: %s',
            sid, tostring(err)))
        conn:close('forward_failed')
    end
end

function client_handler.on_close(conn, reason)
    local sid = conn_to_sid[conn]
    if not sid then return end
    sessions[sid]    = nil
    conn_to_sid[conn] = nil
    conn_state[conn]  = nil
    print(string.format('[GATE-CLIENT] sid=%d closed: %s', sid, tostring(reason)))
    if game_worker_id and game_up then
        xthread.post(game_worker_id, 'session_gone', sid)
    end
end

-- ============================================================================
-- Cross-thread message handlers
-- ============================================================================

xthread.register('gate_set_peer', function(game_id)
    game_worker_id = game_id
    print('[GATE-CLIENT] paired with game worker id=' .. tostring(game_id))
end)

xthread.register('client_accept', function(fd, ip, port)
    local conn, err = xnet.attach(fd, client_handler, ip, port)
    if not conn then
        io.stderr:write('[GATE-CLIENT] attach failed: ' .. tostring(err) .. '\n')
    end
end)

xthread.register('forward_to_client', function(sid, body)
    local conn = sessions[sid]
    if not conn then return end   -- client disconnected; silently drop
    if #body > CLIENT_MAX_BODY then
        print(string.format('[GATE-CLIENT] sid=%d reply too large (%d > %d)',
            sid, #body, CLIENT_MAX_BODY))
        conn:close('reply_too_large')
        return
    end
    local ok, err = conn:send(body)
    if not ok then
        print(string.format('[GATE-CLIENT] sid=%d send to client failed: %s',
            sid, tostring(err)))
        conn:close('client_send_failed')
    end
end)

xthread.register('game_status', function(up)
    game_up = up and true or false
    print('[GATE-CLIENT] game ' .. (game_up and 'up' or 'down'))
    if not game_up then
        -- Optional: tear down outstanding clients on game-down. Keep them
        -- alive here; their next packet will close itself via on_packet.
    end
end)

local function __init()
    print('[GATE-CLIENT] init')
    assert(xnet.init())
end

local function __uninit()
    for _, c in pairs(sessions) do c:close('uninit') end
    sessions = {}; conn_to_sid = {}; conn_state = {}
    xnet.uninit()
    print('[GATE-CLIENT] uninit')
end

return {
    __init = __init,
    __uninit = __uninit,
    __thread_handle = router.handle,
}
