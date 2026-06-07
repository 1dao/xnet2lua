-- xwebsocket.lua - RFC 6455 WebSocket codec + server-side upgrade helper.
--
-- The handshake's SHA-1 + base64 come from the C xutils module (mbedTLS-backed,
-- linked on every build); the frame codec is pure Lua. Requires Lua 5.3+ (native
-- bit ops, string.pack); the bundled minilua is Lua 5.5.
--
-- Two layers:
--   1. Pure codec  -- accept_key / handshake / encode / decode / mask. Usable
--      on its own (e.g. to drive a client, or to unit-test the wire format).
--   2. M.upgrade(conn, req, handlers, opts) -- takes a live xnet HTTP
--      connection that just delivered a WebSocket upgrade request, completes
--      the 101 handshake, then swaps the connection's handler (conn:set_handler)
--      to a frame dispatcher. From then on the fd speaks WebSocket, not HTTP.
--
-- The xhttp worker wires layer 2 in for you: an app route returns
--   { websocket = { on_open=, on_message=, on_close= }, protocol = '...' }
-- and the worker calls M.upgrade. See scripts/core/server/xhttp_worker.lua and
-- demo/xhttp_ws_main.lua.

local M = {}

local xutils = require('xutils')   -- C-backed sha1 + base64 (always linked)
local xmisc  = dofile('scripts/core/share/xmisc.lua')

local spack   = string.pack
local sunpack = string.unpack
local schar   = string.char
local sbyte   = string.byte

-- ===========================================================================
-- Constants
-- ===========================================================================

-- RFC 6455 magic GUID, concatenated with the client key before SHA-1.
M.GUID = '258EAFA5-E914-47DA-95CA-C5AB0DC85B11'

M.OP_CONT  = 0x0
M.OP_TEXT  = 0x1
M.OP_BIN   = 0x2
M.OP_CLOSE = 0x8
M.OP_PING  = 0x9
M.OP_PONG  = 0xA

-- Common close codes (RFC 6455 §7.4.1).
M.CLOSE_NORMAL          = 1000
M.CLOSE_GOING_AWAY      = 1001
M.CLOSE_PROTOCOL_ERROR  = 1002
M.CLOSE_UNSUPPORTED     = 1003
M.CLOSE_POLICY          = 1008
M.CLOSE_TOO_LARGE       = 1009
M.CLOSE_INTERNAL        = 1011

local DEFAULT_MAX_MESSAGE = 4 * 1024 * 1024

local lower = xmisc.lower
local trim  = xmisc.trim

-- ===========================================================================
-- SHA-1 + base64 (handshake only)
--
-- Provided by the C xutils module (mbedTLS-backed SHA-1, plus base64), which is
-- linked on every build. Exposed here too so callers/tests can reach them
-- through the websocket module.
-- ===========================================================================

M.sha1   = xutils.sha1
M.base64 = xutils.base64_encode

-- Sec-WebSocket-Accept = base64(SHA1(key .. GUID)).
function M.accept_key(key)
    return xutils.base64_encode(xutils.sha1(tostring(key or '') .. M.GUID))
end

-- ===========================================================================
-- Handshake
-- ===========================================================================

-- True when req looks like a valid WebSocket upgrade (Connection: Upgrade,
-- Upgrade: websocket, and a Sec-WebSocket-Key present).
function M.is_upgrade(req)
    local h = req and req.headers
    if not h then return false end
    local upg  = lower(h['upgrade'])
    local conn = lower(h['connection'])
    return upg:find('websocket', 1, true) ~= nil
        and conn:find('upgrade', 1, true) ~= nil
        and h['sec-websocket-key'] ~= nil
        and h['sec-websocket-key'] ~= ''
end

-- Choose a subprotocol the server supports from the client's offered list.
-- `supported` may be an array {'chat','echo'} or a set {chat=true}. Returns the
-- chosen protocol name (server's spelling) or nil if none match.
function M.select_protocol(req, supported)
    if not supported then return nil end
    local offered = req and req.headers and req.headers['sec-websocket-protocol']
    if not offered or offered == '' then return nil end

    local set = {}
    if supported[1] ~= nil then
        for _, s in ipairs(supported) do set[lower(s)] = s end
    else
        for k, v in pairs(supported) do
            set[lower(k)] = (type(v) == 'string' and v) or k
        end
    end
    for p in offered:gmatch('([^,]+)') do
        local hit = set[lower(trim(p))]
        if hit then return hit end
    end
    return nil
end

-- Build the raw "101 Switching Protocols" response bytes for req.
-- opts.protocol      -- selected subprotocol (optional)
-- opts.server_name   -- Server header (optional)
-- opts.headers       -- extra response headers (optional)
-- Returns the response string, or nil + error if the key is missing.
function M.handshake(req, opts)
    opts = opts or {}
    local key = req and req.headers and req.headers['sec-websocket-key']
    if not key or key == '' then return nil, 'missing Sec-WebSocket-Key' end

    local lines = {
        'HTTP/1.1 101 Switching Protocols',
        'Upgrade: websocket',
        'Connection: Upgrade',
        'Sec-WebSocket-Accept: ' .. M.accept_key(key),
    }
    if opts.protocol and opts.protocol ~= '' then
        lines[#lines + 1] = 'Sec-WebSocket-Protocol: ' .. tostring(opts.protocol)
    end
    if opts.server_name and opts.server_name ~= '' then
        lines[#lines + 1] = 'Server: ' .. tostring(opts.server_name)
    end
    if type(opts.headers) == 'table' then
        for k, v in pairs(opts.headers) do
            lines[#lines + 1] = tostring(k) .. ': ' .. tostring(v)
        end
    end
    return table.concat(lines, '\r\n') .. '\r\n\r\n'
end

-- ===========================================================================
-- Frame masking (XOR with a 4-byte key; symmetric, so this both masks and
-- unmasks). Processes 4 bytes at a time via string.pack for speed.
-- ===========================================================================
function M.mask(payload, key)
    payload = payload or ''
    if payload == '' then return payload end
    local n = #payload
    local mk = sunpack('>I4', key)
    local parts = {}
    local pi = 0
    local i = 1
    while i + 3 <= n do
        local word = sunpack('>I4', payload, i)
        pi = pi + 1
        parts[pi] = spack('>I4', word ~ mk)
        i = i + 4
    end
    if i <= n then
        local k1, k2, k3, k4 = sbyte(key, 1, 4)
        local kb = { k1, k2, k3, k4 }
        local tail = {}
        local ti = 0
        local j = 0
        while i <= n do
            ti = ti + 1
            tail[ti] = schar(sbyte(payload, i) ~ kb[(j % 4) + 1])
            i = i + 1; j = j + 1
        end
        pi = pi + 1
        parts[pi] = table.concat(tail)
    end
    return table.concat(parts)
end

local function random_mask_key()
    if type(xnet) == 'table' and type(xnet.random_bytes) == 'function' then
        local b = xnet.random_bytes(4)
        if type(b) == 'string' and #b == 4 then return b end
    end
    return schar(math.random(0, 255), math.random(0, 255),
                 math.random(0, 255), math.random(0, 255))
end

-- ===========================================================================
-- Frame encode / decode
-- ===========================================================================

-- Encode one frame. Server frames are unmasked by default; pass opts.mask=true
-- (client side) to mask with a random key, or opts.mask_key for a fixed key.
--   opts.fin -- default true (set false to send a fragment)
function M.encode(opcode, payload, opts)
    payload = payload or ''
    opts = opts or {}
    local fin = opts.fin ~= false
    local b1 = (fin and 0x80 or 0x00) | (opcode & 0x0f)
    local n = #payload
    local mask_bit = opts.mask and 0x80 or 0x00

    local header
    if n < 126 then
        header = spack('>BB', b1, mask_bit | n)
    elseif n < 65536 then
        header = spack('>BBI2', b1, mask_bit | 126, n)
    else
        header = spack('>BBI8', b1, mask_bit | 127, n)
    end

    if opts.mask then
        local key = opts.mask_key or random_mask_key()
        return header .. key .. M.mask(payload, key)
    end
    return header .. payload
end

-- Decode one frame from buf starting at pos (default 1). Returns:
--   frame, next_pos                      -- frame = { fin, opcode, payload,
--                                            masked, rsv }
--   nil, pos, 'incomplete'               -- need more bytes
--   nil, nil, err                        -- protocol/size error (fatal)
-- opts.max_frame_size caps the declared payload length before buffering it.
function M.decode(buf, pos, opts)
    pos = pos or 1
    opts = opts or {}
    local n = #buf
    if pos + 1 > n then return nil, pos, 'incomplete' end

    local b1 = sbyte(buf, pos)
    local b2 = sbyte(buf, pos + 1)
    local fin    = (b1 & 0x80) ~= 0
    local rsv    = b1 & 0x70
    local opcode = b1 & 0x0f
    local masked = (b2 & 0x80) ~= 0
    local len    = b2 & 0x7f
    local hdr    = pos + 2

    if len == 126 then
        if hdr + 1 > n then return nil, pos, 'incomplete' end
        len = sunpack('>I2', buf, hdr); hdr = hdr + 2
    elseif len == 127 then
        if hdr + 7 > n then return nil, pos, 'incomplete' end
        len = sunpack('>I8', buf, hdr); hdr = hdr + 8
    end

    local maxlen = opts.max_frame_size
    if maxlen and len > maxlen then return nil, nil, 'frame too large' end

    local key
    if masked then
        if hdr + 3 > n then return nil, pos, 'incomplete' end
        key = buf:sub(hdr, hdr + 3); hdr = hdr + 4
    end

    if hdr + len - 1 > n then return nil, pos, 'incomplete' end
    local payload = (len > 0) and buf:sub(hdr, hdr + len - 1) or ''
    if masked and len > 0 then payload = M.mask(payload, key) end

    return {
        fin = fin, opcode = opcode, payload = payload,
        masked = masked, rsv = rsv,
    }, hdr + len
end

-- Convenience frame builders (server side, unmasked).
function M.text_frame(s)        return M.encode(M.OP_TEXT, tostring(s or '')) end
function M.binary_frame(s)      return M.encode(M.OP_BIN,  tostring(s or '')) end
function M.ping_frame(payload)  return M.encode(M.OP_PING, payload or '') end
function M.pong_frame(payload)  return M.encode(M.OP_PONG, payload or '') end

-- A close frame carries an optional 2-byte big-endian status code + UTF-8
-- reason. With no code it is an empty close (valid per RFC).
function M.close_frame(code, reason)
    local payload = ''
    if code then
        payload = spack('>I2', code & 0xffff) .. tostring(reason or '')
    end
    return M.encode(M.OP_CLOSE, payload)
end

-- Parse a close frame payload -> code, reason (code nil if empty/short).
function M.parse_close(payload)
    payload = payload or ''
    if #payload >= 2 then
        return sunpack('>I2', payload), payload:sub(3)
    end
    return nil, ''
end

-- ===========================================================================
-- Server-side upgrade: hand a live xnet HTTP connection over to WebSocket.
-- ===========================================================================
--
-- handlers (all optional):
--   on_open(ws)
--   on_message(ws, message, opcode)   -- opcode is OP_TEXT or OP_BIN
--   on_ping(ws, payload)              -- auto-pong is sent before this
--   on_pong(ws, payload)
--   on_close(ws, reason)              -- socket-level close (fires once)
--
-- opts:
--   protocol            -- subprotocol to echo in the handshake
--   protocols           -- offered set/list to select from (if protocol unset)
--   server_name         -- Server header in the handshake
--   max_message_size    -- assembled-message cap (default 4 MiB)
--   handshake_headers   -- extra headers for the 101 response
--   on_detach(conn,reason) -- internal hook the worker uses to forget the conn
--
-- Returns the ws object, or nil + error (after sending the handshake fails or
-- the request is not a valid upgrade).
function M.upgrade(conn, req, handlers, opts)
    handlers = handlers or {}
    opts = opts or {}

    if not M.is_upgrade(req) then
        return nil, 'not a websocket upgrade request'
    end

    local protocol = opts.protocol
    if not protocol and opts.protocols then
        protocol = M.select_protocol(req, opts.protocols)
    end

    local hs, herr = M.handshake(req, {
        protocol    = protocol,
        server_name = opts.server_name,
        headers     = opts.handshake_headers,
    })
    if not hs then return nil, herr end

    local max_msg = tonumber(opts.max_message_size) or DEFAULT_MAX_MESSAGE

    local ws = { conn = conn, protocol = protocol, closing = false, closed = false }

    function ws:fd()
        local ok, fd = pcall(function() return conn:fd() end)
        if ok then return fd end
        return nil
    end

    function ws:is_open()
        if self.closed or self.closing then return false end
        local ok, closed = pcall(function() return conn:is_closed() end)
        if ok then return not closed end
        return false
    end

    function ws:send_frame(opcode, payload, frame_opts)
        if self.closed then return false end
        local okk, rc = pcall(function()
            return conn:send_raw(M.encode(opcode, payload, frame_opts))
        end)
        return okk and rc and true or false
    end

    function ws:send_text(s)   return self:send_frame(M.OP_TEXT, tostring(s or '')) end
    function ws:send_binary(s) return self:send_frame(M.OP_BIN,  tostring(s or '')) end
    ws.send = ws.send_text
    function ws:send_ping(p)   return self:send_frame(M.OP_PING, p or '') end
    function ws:send_pong(p)   return self:send_frame(M.OP_PONG, p or '') end

    -- Send a close frame (once) and close the socket.
    function ws:close(code, reason)
        if self.closing or self.closed then return end
        self.closing = true
        pcall(function() conn:send_raw(M.close_frame(code or M.CLOSE_NORMAL, reason)) end)
        pcall(function() conn:close(reason or 'ws_close') end)
    end

    -- Per-connection parse state for message reassembly across fragments.
    local frag_op, frag_parts, frag_len = nil, nil, 0

    local function fail(code, why)
        ws:close(code, why)
    end

    local function on_data_frame(op, frame)
        if op == M.OP_CONT then
            if not frag_op then return fail(M.CLOSE_PROTOCOL_ERROR, 'unexpected continuation') end
            frag_len = frag_len + #frame.payload
            if frag_len > max_msg then return fail(M.CLOSE_TOO_LARGE, 'message too large') end
            frag_parts[#frag_parts + 1] = frame.payload
            if frame.fin then
                local msg, mop = table.concat(frag_parts), frag_op
                frag_op, frag_parts, frag_len = nil, nil, 0
                if handlers.on_message then pcall(handlers.on_message, ws, msg, mop) end
            end
        else -- OP_TEXT / OP_BIN: start of a message
            if frag_op then return fail(M.CLOSE_PROTOCOL_ERROR, 'fragmented message interrupted') end
            if frame.fin then
                if #frame.payload > max_msg then return fail(M.CLOSE_TOO_LARGE, 'message too large') end
                if handlers.on_message then pcall(handlers.on_message, ws, frame.payload, op) end
            else
                frag_op, frag_parts, frag_len = op, { frame.payload }, #frame.payload
            end
        end
    end

    local handler = {}

    function handler.on_packet(c, data)
        local pos, n = 1, #data
        while pos <= n do
            local frame, next_pos, derr = M.decode(data, pos, { max_frame_size = max_msg })
            if not frame then
                if derr == 'incomplete' then break end
                fail(M.CLOSE_PROTOCOL_ERROR, 'protocol error')
                return n
            end
            pos = next_pos

            local op = frame.opcode
            if op == M.OP_PING then
                pcall(function() ws:send_pong(frame.payload) end)
                if handlers.on_ping then pcall(handlers.on_ping, ws, frame.payload) end
            elseif op == M.OP_PONG then
                if handlers.on_pong then pcall(handlers.on_pong, ws, frame.payload) end
            elseif op == M.OP_CLOSE then
                local code, reason = M.parse_close(frame.payload)
                if not ws.closing and not ws.closed then
                    ws.closing = true
                    pcall(function() conn:send_raw(M.encode(M.OP_CLOSE, frame.payload)) end)
                    pcall(function() conn:close('ws_peer_close') end)
                end
                if handlers.on_close_frame then
                    pcall(handlers.on_close_frame, ws, code, reason)
                end
                return n
            elseif op == M.OP_CONT or op == M.OP_TEXT or op == M.OP_BIN then
                on_data_frame(op, frame)
            else
                fail(M.CLOSE_PROTOCOL_ERROR, 'bad opcode')
                return n
            end

            local okc, closed = pcall(function() return c:is_closed() end)
            if okc and closed then return n end
        end
        return pos - 1
    end

    function handler.on_close(c, reason)
        ws.closed = true
        if opts.on_detach then pcall(opts.on_detach, c, reason) end
        if handlers.on_close then pcall(handlers.on_close, ws, reason) end
    end

    -- Send the handshake, then hand the fd over to the frame dispatcher.
    local okk, rc = pcall(function() return conn:send_raw(hs) end)
    if not okk or not rc then
        return nil, 'handshake send failed'
    end
    conn:set_handler(handler)

    if handlers.on_open then pcall(handlers.on_open, ws) end
    return ws
end

return M
