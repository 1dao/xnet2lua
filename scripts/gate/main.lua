-- scripts/gate/main.lua -- gate skeleton (no crypto)
--
-- Two listeners:
--   - client port: accepts game clients (LEN16 framed)
--                   wire body: [opcode:2BE][payload:N]
--   - internal port: accepts game services (LEN16 framed)
--                   wire body: [session_id:4BE][opcode:2BE][payload:N]
--
-- Gate is stateless about gameplay. It owns session_id <-> client_conn,
-- and forwards bytes in both directions. payload is opaque.
--
-- v0 routing: a single game connection handles every non-zero opcode.
-- Adds multi-game routing later by reading opcode-range tables.
--
-- Run with:  ./bin/xnet scripts/gate/main.lua

local CLIENT_HOST   = '127.0.0.1'
local CLIENT_PORT   = 19180
local INTERNAL_HOST = '127.0.0.1'
local INTERNAL_PORT = 19181

-- Pre-shared AEAD keys for client<->gate. v0 placeholder until ECDH
-- handshake lands; replace with derived keys per session at that point.
local K_C2S = string.rep('\1', 32)  -- client -> gate (gate's recv key)
local K_S2C = string.rep('\2', 32)  -- gate   -> client (gate's send key)

local client_listener
local game_listener

-- session_id -> client_conn
local sessions = {}
-- client_conn -> session_id (reverse for cleanup)
local conn_to_sid = {}
local next_sid = 1

-- single game conn for v0
local game_conn = nil

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

-- =========================================================================
-- Client side: gate <- client
-- =========================================================================
local client_handler = {}

function client_handler.on_connect(conn, ip, port)
    local sid = next_sid
    next_sid = next_sid + 1
    sessions[sid] = conn
    conn_to_sid[conn] = sid
    conn:set_framing({ type = 'len16', max_packet = 64 * 1024 })
    conn:enable_aead(K_S2C, K_C2S)  -- send=S2C, recv=C2S
    print(string.format('[GATE] client sid=%d connected from %s:%s (AEAD on)',
        sid, tostring(ip), tostring(port)))
end

function client_handler.on_packet(conn, body)
    local sid = conn_to_sid[conn]
    if not sid then return end  -- not registered yet
    if not game_conn then
        -- no backend, drop and log
        print(string.format('[GATE] sid=%d packet dropped: no game connected', sid))
        return
    end
    if #body < 2 then
        print(string.format('[GATE] sid=%d short packet (%d bytes), dropping', sid, #body))
        return
    end
    -- prepend session_id (4B) to the [opcode:2B][payload] frame
    local out = u32be(sid) .. body
    game_conn:send(out)
end

function client_handler.on_close(conn, reason)
    local sid = conn_to_sid[conn]
    if not sid then return end
    sessions[sid] = nil
    conn_to_sid[conn] = nil
    print(string.format('[GATE] client sid=%d closed: %s', sid, tostring(reason)))
    -- Notify game so it can drop player state. session_gone opcode = 0xFFFE.
    if game_conn then
        local SESSION_GONE = 0xFFFE
        game_conn:send(u32be(sid) .. u16be(SESSION_GONE))
    end
end

-- =========================================================================
-- Game side: gate <- game
-- =========================================================================
local game_handler = {}

function game_handler.on_connect(conn, ip, port)
    if game_conn then
        print(string.format('[GATE] already have a game; dropping new conn from %s:%s',
            tostring(ip), tostring(port)))
        conn:close('duplicate_game')
        return
    end
    conn:set_framing({ type = 'len16', max_packet = 64 * 1024 })
    game_conn = conn
    print(string.format('[GATE] game connected from %s:%s', tostring(ip), tostring(port)))
end

function game_handler.on_packet(conn, body)
    if conn ~= game_conn then return end
    if #body < 6 then
        print('[GATE] game packet too short, dropping')
        return
    end
    local sid = r32be(body, 1)
    local client = sessions[sid]
    if not client then
        -- client gone; silently drop (this is normal during disconnects)
        return
    end
    -- strip the session_id prefix, forward [opcode:2B][payload] to client
    client:send(string.sub(body, 5))
end

function game_handler.on_close(conn, reason)
    if conn == game_conn then
        game_conn = nil
        print('[GATE] game disconnected: ' .. tostring(reason))
    end
end

-- =========================================================================
-- lifecycle
-- =========================================================================
local function __init()
    print('[GATE] init')
    assert(xnet.init())

    client_listener = assert(xnet.listen(CLIENT_HOST, CLIENT_PORT, client_handler))
    print(string.format('[GATE] client listener %s:%d', CLIENT_HOST, CLIENT_PORT))

    game_listener = assert(xnet.listen(INTERNAL_HOST, INTERNAL_PORT, game_handler))
    print(string.format('[GATE] internal listener %s:%d', INTERNAL_HOST, INTERNAL_PORT))
end

local function __uninit()
    if client_listener then client_listener:close('uninit'); client_listener = nil end
    if game_listener   then game_listener:close('uninit');   game_listener   = nil end
    for _, c in pairs(sessions) do c:close('uninit') end
    sessions    = {}
    conn_to_sid = {}
    if game_conn then game_conn:close('uninit'); game_conn = nil end
    xnet.uninit()
    print('[GATE] uninit')
end

return { __init = __init, __uninit = __uninit }
