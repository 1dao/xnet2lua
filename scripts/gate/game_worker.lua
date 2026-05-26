-- scripts/gate/game_worker.lua -- gate's game-facing worker.
--
-- Owns the single game connection (plain LEN16). Receives forward requests
-- from client_worker and posts game replies back. Game wire format:
--   [session_id:4BE][opcode:2BE][payload:N]

local router = dofile('scripts/core/share/xrouter.lua')
router.set_log_prefix('GATE-GAME')

function xthread.register(pt, h) return router.register(pt, h) end

local client_worker_id = nil
local game_conn        = nil

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

local function notify_client_worker(status)
    if client_worker_id then
        xthread.post(client_worker_id, 'game_status', status)
    end
end

-- ============================================================================
-- Game connection handler
-- ============================================================================
local game_handler = {}

function game_handler.on_connect(conn, ip, port)
    if game_conn then
        print(string.format('[GATE-GAME] already have a game; dropping %s:%s',
            tostring(ip), tostring(port)))
        conn:close('duplicate_game')
        return
    end
    conn:set_framing({ type = 'len16', max_packet = 64 * 1024 })
    game_conn = conn
    print(string.format('[GATE-GAME] game connected from %s:%s', tostring(ip), tostring(port)))
    notify_client_worker(true)
end

function game_handler.on_packet(conn, body)
    if conn ~= game_conn then return end
    if #body < 6 then
        print('[GATE-GAME] short game packet, dropping')
        return
    end
    local sid = r32be(body, 1)
    -- Strip the 4-byte session_id; forward [opcode:2B][payload] to client_worker.
    local client_body = string.sub(body, 5)
    if client_worker_id then
        xthread.post(client_worker_id, 'forward_to_client', sid, client_body)
    end
end

function game_handler.on_close(conn, reason)
    if conn == game_conn then
        game_conn = nil
        print('[GATE-GAME] game disconnected: ' .. tostring(reason))
        notify_client_worker(false)
    end
end

-- ============================================================================
-- Cross-thread message handlers
-- ============================================================================

xthread.register('gate_set_peer', function(client_id)
    client_worker_id = client_id
    print('[GATE-GAME] paired with client worker id=' .. tostring(client_id))
    -- Tell the client worker our current state in case it raced past us.
    notify_client_worker(game_conn ~= nil)
end)

xthread.register('game_accept', function(fd, ip, port)
    local conn, err = xnet.attach(fd, game_handler, ip, port)
    if not conn then
        io.stderr:write('[GATE-GAME] attach failed: ' .. tostring(err) .. '\n')
    end
end)

xthread.register('forward_to_game', function(sid, body)
    if not game_conn then return end    -- backend gone; drop
    local ok, err = game_conn:send(u32be(sid) .. body)
    if not ok then
        print(string.format('[GATE-GAME] sid=%d forward to game failed: %s',
            sid, tostring(err)))
    end
end)

xthread.register('session_gone', function(sid)
    if not game_conn then return end
    local SESSION_GONE = 0xFFFE
    local ok, err = game_conn:send(u32be(sid) .. u16be(SESSION_GONE))
    if not ok then
        print(string.format('[GATE-GAME] sid=%d session-gone notify failed: %s',
            sid, tostring(err)))
    end
end)

local function __init()
    print('[GATE-GAME] init')
    assert(xnet.init())
end

local function __uninit()
    if game_conn then game_conn:close('uninit'); game_conn = nil end
    xnet.uninit()
    print('[GATE-GAME] uninit')
end

return {
    __init = __init,
    __uninit = __uninit,
    __thread_handle = router.handle,
}
