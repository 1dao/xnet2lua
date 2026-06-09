-- MySQL worker thread.
-- Uses xnet/xchannel raw mode and implements the MySQL protocol in Lua.

local unpack_args = table.unpack or unpack
local router = dofile('scripts/core/share/xrouter.lua')
local xutils = require('xutils')   -- C-backed sha1/sha256 (always linked)
router.set_log_prefix('XMYSQL-WORKER')

local config = {
    host = '127.0.0.1',
    port = 3306,
    user = 'root',
    password = '',
    database = '',
    pool_size = 4,
    reconnect_ms = 1000,
    max_packet = 64 * 1024 * 1024,
    charset = 45,
}

local conns = {}
local waitq = {}
local rr = 1
local stopping = false
-- Set when a connection fails for a reason that retrying cannot fix (bad
-- credentials, an unsupported auth plugin, or caching_sha2_password full
-- authentication which this client can't perform). We then fail queued/new
-- requests immediately with this reason instead of letting them hang until the
-- caller's RPC timeout fires and reports a misleading "rpc timeout". Cleared on
-- every (re)start of the pool so corrected credentials get a fresh attempt.
local fatal_auth_error = nil
function xthread.register(pt, h) return router.register(pt, h) end

local function resume_request(req, ...)
    return router.resume_request(req, ...)
end

local function fail_request(req, err)
    if req then
        resume_request(req, false, err)
    end
end

local MASK32 = 0xffffffff
local TWO32 = 0x100000000

local function to_u32(v)
    v = v % TWO32
    if v < 0 then v = v + TWO32 end
    return v
end

local bit_band
local bit_bor
local bit_bxor
local bit_bnot
local bit_lshift
local bit_rshift

do
    local bitlib = rawget(_G, 'bit')
    if not bitlib then pcall(function() bitlib = require('bit') end) end
    if not bitlib then bitlib = rawget(_G, 'bit32') end
    if not bitlib then pcall(function() bitlib = require('bit32') end) end

    if bitlib and bitlib.band and bitlib.bor and bitlib.bxor and bitlib.bnot and bitlib.lshift and bitlib.rshift then
        bit_band = function(a, ...)
            if a == nil then return MASK32 end
            local r = to_u32(a)
            for i = 1, select('#', ...) do
                r = to_u32(bitlib.band(r, select(i, ...)))
            end
            return r
        end
        bit_bor = function(a, ...)
            if a == nil then return 0 end
            local r = to_u32(a)
            for i = 1, select('#', ...) do
                r = to_u32(bitlib.bor(r, select(i, ...)))
            end
            return r
        end
        bit_bxor = function(a, ...)
            if a == nil then return 0 end
            local r = to_u32(a)
            for i = 1, select('#', ...) do
                r = to_u32(bitlib.bxor(r, select(i, ...)))
            end
            return r
        end
        bit_bnot = function(a)
            return to_u32(bitlib.bnot(a))
        end
        bit_lshift = function(a, n)
            return to_u32(bitlib.lshift(a, n))
        end
        bit_rshift = function(a, n)
            return to_u32(bitlib.rshift(a, n))
        end
    else
        local function bit2(a, b, mode)
            a = to_u32(a)
            b = to_u32(b)
            local r = 0
            local place = 1
            for _ = 1, 32 do
                local abit = a % 2
                local bbit = b % 2
                if mode == 'and' then
                    if abit == 1 and bbit == 1 then r = r + place end
                elseif mode == 'or' then
                    if abit == 1 or bbit == 1 then r = r + place end
                else
                    if abit ~= bbit then r = r + place end
                end
                a = (a - abit) / 2
                b = (b - bbit) / 2
                place = place * 2
            end
            return r
        end

        bit_band = function(a, ...)
            if a == nil then return MASK32 end
            local r = to_u32(a)
            for i = 1, select('#', ...) do
                r = bit2(r, select(i, ...), 'and')
            end
            return to_u32(r)
        end
        bit_bor = function(a, ...)
            if a == nil then return 0 end
            local r = to_u32(a)
            for i = 1, select('#', ...) do
                r = bit2(r, select(i, ...), 'or')
            end
            return to_u32(r)
        end
        bit_bxor = function(a, ...)
            if a == nil then return 0 end
            local r = to_u32(a)
            for i = 1, select('#', ...) do
                r = bit2(r, select(i, ...), 'xor')
            end
            return to_u32(r)
        end
        bit_bnot = function(a)
            return to_u32(MASK32 - to_u32(a))
        end
        bit_lshift = function(a, n)
            n = math.floor(n or 0)
            if n <= 0 then return to_u32(a) end
            if n >= 32 then return 0 end
            return to_u32(to_u32(a) * (2 ^ n))
        end
        bit_rshift = function(a, n)
            n = math.floor(n or 0)
            if n <= 0 then return to_u32(a) end
            if n >= 32 then return 0 end
            return math.floor(to_u32(a) / (2 ^ n))
        end
    end
end

local function bchr(...)
    return string.char(...)
end

local function byte_at(s, pos)
    return string.byte(s, pos) or 0
end

local function le_int(data, pos, n)
    local out = 0
    local mul = 1
    for i = 0, n - 1 do
        out = out + byte_at(data, pos + i) * mul
        mul = mul * 256
    end
    return out
end

local function int1(n)
    return bchr(bit_band(n, 0xff))
end

local function int2(n)
    return bchr(bit_band(n, 0xff), bit_band(bit_rshift(n, 8), 0xff))
end

local function int3(n)
    return bchr(bit_band(n, 0xff), bit_band(bit_rshift(n, 8), 0xff), bit_band(bit_rshift(n, 16), 0xff))
end

local function int4(n)
    return bchr(bit_band(n, 0xff), bit_band(bit_rshift(n, 8), 0xff), bit_band(bit_rshift(n, 16), 0xff), bit_band(bit_rshift(n, 24), 0xff))
end


local function read_null(data, pos)
    local p = string.find(data, '\0', pos, true)
    if not p then
        return string.sub(data, pos), #data + 1
    end
    return string.sub(data, pos, p - 1), p + 1
end

local function read_lenenc(data, pos)
    local b = byte_at(data, pos)
    if b < 0xfb then
        return b, pos + 1, false
    end
    if b == 0xfb then
        return nil, pos + 1, true
    end
    if b == 0xfc then
        return le_int(data, pos + 1, 2), pos + 3, false
    end
    if b == 0xfd then
        return le_int(data, pos + 1, 3), pos + 4, false
    end
    if b == 0xfe then
        return le_int(data, pos + 1, 8), pos + 9, false
    end
    return nil, pos + 1, false
end

local function read_lenenc_string(data, pos)
    local len, next_pos, is_null = read_lenenc(data, pos)
    if is_null then
        return nil, next_pos, true
    end
    if not len then
        return nil, next_pos, false
    end
    return string.sub(data, next_pos, next_pos + len - 1), next_pos + len, false
end

local function write_lenenc(n)
    if n < 0xfb then
        return int1(n)
    end
    if n <= 0xffff then
        return int1(0xfc) .. int2(n)
    end
    if n <= 0xffffff then
        return int1(0xfd) .. int3(n)
    end
    return int1(0xfe) .. int4(bit_band(n, MASK32)) .. int4(bit_band(bit_rshift(n, 32), MASK32))
end

local function xor_string(a, b)
    local out = {}
    for i = 1, math.min(#a, #b) do
        out[i] = bchr(bit_band(bit_bxor(byte_at(a, i), byte_at(b, i)), 0xff))
    end
    return table.concat(out)
end

-- SHA-1 / SHA-256 are provided by the C xutils module (mbedTLS-backed, linked
-- on every build). These thin wrappers keep the rest of the worker unchanged.
-- The bit-op shim above is still used by the little-endian MySQL packet codecs
-- (int1/int3/int4), so it stays.
local function sha1(msg)
    return xutils.sha1(tostring(msg or ''))
end

local function sha256(msg)
    return xutils.sha256(tostring(msg or ''))
end

local function auth_token(plugin, password, seed)
    password = password or ''
    if password == '' then
        return ''
    end

    if plugin == 'mysql_native_password' then
        local s1 = sha1(password)
        local s2 = sha1(s1)
        return xor_string(s1, sha1(seed .. s2))
    end

    if plugin == 'caching_sha2_password' then
        local s1 = sha256(password)
        local s2 = sha256(s1)
        return xor_string(s1, sha256(s2 .. seed))
    end

    return nil, 'unsupported auth plugin: ' .. tostring(plugin)
end

local function hex_string(s)
    local out = {}
    for i = 1, #s do
        out[i] = string.format('%02x', byte_at(s, i))
    end
    return table.concat(out)
end

local function check_hash_impl()
    local sha1_abc = 'a9993e364706816aba3e25717850c26c9cd0d89d'
    local sha256_abc = 'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad'
    local sha256_bin_abc = '4f8b42c22dd3729b519ba6f68d2da7cc5b2d606d05daed5ad5128cc03e6c6358'
    if hex_string(sha1('abc')) ~= sha1_abc then
        io.stderr:write('[XMYSQL-WORKER] sha1 self-check failed\n')
    end
    if hex_string(sha256('abc')) ~= sha256_abc then
        io.stderr:write('[XMYSQL-WORKER] sha256 self-check failed\n')
    end
    if hex_string(sha256(sha256('abc'))) ~= sha256_bin_abc then
        io.stderr:write('[XMYSQL-WORKER] sha256 binary self-check failed\n')
    end
end

local function parse_packet(data, pos)
    if pos + 4 > #data + 1 then
        return nil, pos, true
    end
    local len = byte_at(data, pos) + byte_at(data, pos + 1) * 256 + byte_at(data, pos + 2) * 65536
    local seq = byte_at(data, pos + 3)
    local start = pos + 4
    local stop = start + len - 1
    if stop > #data then
        return nil, pos, true
    end
    return {
        seq = seq,
        payload = string.sub(data, start, stop),
    }, stop + 1, false
end

local function pack_packet(payload, seq)
    return int3(#payload) .. int1(seq or 0) .. payload
end

local function parse_handshake(payload)
    local pos = 1
    local protocol = byte_at(payload, pos)
    pos = pos + 1
    local server_version
    server_version, pos = read_null(payload, pos)
    local connection_id = le_int(payload, pos, 4)
    pos = pos + 4
    local salt1 = string.sub(payload, pos, pos + 7)
    pos = pos + 8
    pos = pos + 1
    local caps_low = le_int(payload, pos, 2)
    pos = pos + 2
    local charset = byte_at(payload, pos)
    pos = pos + 1
    local status = le_int(payload, pos, 2)
    pos = pos + 2
    local caps_high = le_int(payload, pos, 2)
    pos = pos + 2
    local caps = bit_bor(bit_lshift(caps_high, 16), caps_low)
    local auth_len = byte_at(payload, pos)
    pos = pos + 1
    pos = pos + 10
    local salt2 = ''
    if pos <= #payload then
        salt2, pos = read_null(payload, pos)
    end
    local plugin = 'mysql_native_password'
    if pos <= #payload then
        plugin = read_null(payload, pos)
        if plugin == '' then
            plugin = 'mysql_native_password'
        end
    end
    if auth_len > 0 then
        local salt2_len = math.max(12, auth_len - 9)
        if #salt2 > salt2_len then
            salt2 = string.sub(salt2, 1, salt2_len)
        end
    end

    return {
        protocol = protocol,
        server_version = server_version,
        connection_id = connection_id,
        charset = charset,
        status = status,
        capabilities = caps,
        seed = salt1 .. salt2,
        plugin = plugin,
    }
end

local function make_handshake_response(hs)
    local CLIENT_LONG_PASSWORD = 0x00000001
    local CLIENT_LONG_FLAG = 0x00000004
    local CLIENT_CONNECT_WITH_DB = 0x00000008
    local CLIENT_PROTOCOL_41 = 0x00000200
    local CLIENT_TRANSACTIONS = 0x00002000
    local CLIENT_SECURE_CONNECTION = 0x00008000
    local CLIENT_MULTI_RESULTS = 0x00020000
    local CLIENT_PLUGIN_AUTH = 0x00080000
    local CLIENT_CONNECT_ATTRS = 0x00100000
    local CLIENT_PLUGIN_AUTH_LENENC_CLIENT_DATA = 0x00200000

    local db = config.database or ''
    local flags = bit_bor(
        CLIENT_LONG_PASSWORD, CLIENT_LONG_FLAG, CLIENT_PROTOCOL_41,
        CLIENT_TRANSACTIONS, CLIENT_SECURE_CONNECTION, CLIENT_MULTI_RESULTS,
        CLIENT_PLUGIN_AUTH, CLIENT_CONNECT_ATTRS, CLIENT_PLUGIN_AUTH_LENENC_CLIENT_DATA
    )
    if db ~= '' then
        flags = bit_bor(flags, CLIENT_CONNECT_WITH_DB)
    end

    if hs.capabilities then
        flags = bit_band(flags, hs.capabilities)
    end

    local token, err = auth_token(hs.plugin, config.password, hs.seed)
    if not token then
        return nil, err
    end

    local parts = {
        int4(flags),
        int4(config.max_packet),
        int1(config.charset),
        string.rep('\0', 23),
        config.user,
        '\0',
    }
    if bit_band(flags, CLIENT_PLUGIN_AUTH_LENENC_CLIENT_DATA) ~= 0 then
        parts[#parts + 1] = write_lenenc(#token)
        parts[#parts + 1] = token
    elseif bit_band(flags, CLIENT_SECURE_CONNECTION) ~= 0 then
        parts[#parts + 1] = int1(#token)
        parts[#parts + 1] = token
    else
        parts[#parts + 1] = token
        parts[#parts + 1] = '\0'
    end
    if db ~= '' then
        parts[#parts + 1] = db
        parts[#parts + 1] = '\0'
    end
    if bit_band(flags, CLIENT_PLUGIN_AUTH) ~= 0 then
        parts[#parts + 1] = hs.plugin
        parts[#parts + 1] = '\0'
    end
    if bit_band(flags, CLIENT_CONNECT_ATTRS) ~= 0 then
        parts[#parts + 1] = write_lenenc(0)
    end
    return table.concat(parts)
end

local function parse_err(payload)
    local code = le_int(payload, 2, 2)
    local pos = 4
    local state = ''
    if string.sub(payload, pos, pos) == '#' then
        state = string.sub(payload, pos + 1, pos + 5)
        pos = pos + 6
    end
    local msg = string.sub(payload, pos)
    return string.format('mysql error %d %s %s', code, state, msg)
end

local function parse_ok(payload)
    local pos = 2
    local affected_rows
    affected_rows, pos = read_lenenc(payload, pos)
    local last_insert_id
    last_insert_id, pos = read_lenenc(payload, pos)
    return {
        ok = true,
        affected_rows = affected_rows or 0,
        last_insert_id = last_insert_id or 0,
    }
end

local function is_eof(payload)
    return #payload < 9 and byte_at(payload, 1) == 0xfe
end

local function parse_column(payload)
    local pos = 1
    local catalog; catalog, pos = read_lenenc_string(payload, pos)
    local schema; schema, pos = read_lenenc_string(payload, pos)
    local table_name; table_name, pos = read_lenenc_string(payload, pos)
    local org_table; org_table, pos = read_lenenc_string(payload, pos)
    local name; name, pos = read_lenenc_string(payload, pos)
    local org_name; org_name, pos = read_lenenc_string(payload, pos)
    return {
        catalog = catalog,
        schema = schema,
        table = table_name,
        org_table = org_table,
        name = name or org_name or '',
        org_name = org_name,
    }
end

local function parse_row(payload, columns)
    local pos = 1
    local row = {}
    local values = {}
    for i, col in ipairs(columns) do
        local value, next_pos, is_null = read_lenenc_string(payload, pos)
        pos = next_pos
        if not is_null then
            values[i] = value
            row[col.name] = value
        end
    end
    return row, values
end

local function build_result(rs)
    local fields = {}
    for i, col in ipairs(rs.columns) do
        fields[i] = col.name
    end
    return {
        ok = true,
        fields = fields,
        rows = rs.rows,
        values = rs.values,
    }
end

local function choose_conn()
    if #conns == 0 then return nil end
    for i = 1, #conns do
        local idx = ((rr + i - 2) % #conns) + 1
        local c = conns[idx]
        if c.connected and c.ready and c.conn and not c.closed and #c.pending == 0 then
            rr = (idx % #conns) + 1
            return c
        end
    end
    return nil
end

local function send_on_conn(c, req)
    c.pending[#c.pending + 1] = req
    local ok = c.conn and c.conn:send_raw(pack_packet(req.payload, 0))
    if not ok then
        table.remove(c.pending)
        fail_request(req, 'mysql send failed')
        return false
    end
    return true
end

local flush_waiting

local function enqueue(req)
    local c = choose_conn()
    if not c then
        waitq[#waitq + 1] = req
        return true
    end
    return send_on_conn(c, req)
end

flush_waiting = function()
    while #waitq > 0 do
        local c = choose_conn()
        if not c then return end
        local req = table.remove(waitq, 1)
        send_on_conn(c, req)
    end
end

local function complete_request(c, ok, result)
    local req = table.remove(c.pending, 1)
    c.result = nil
    if not req then
        return
    end
    resume_request(req, ok, result)
    flush_waiting()
end

local function fail_conn_pending(c, err)
    local pending = c.pending
    c.pending = {}
    c.result = nil
    for _, req in ipairs(pending) do
        fail_request(req, err)
    end
end

local function close_conn(c, reason)
    if c.conn and not c.conn:is_closed() then
        c.conn:close(reason or 'close')
    end
end

local function mark_ready(c)
    c.phase = 'ready'
    c.ready = true
    print(string.format('[XMYSQL-WORKER] ready[%d] %s@%s:%s db=%s',
        c.index, config.user, config.host, tostring(config.port),
        config.database ~= '' and config.database or '(none)'))
    flush_waiting()
end

local function fail_auth(c, reason)
    -- Non-retryable auth failure: remember it so queued/new requests fail fast
    -- with this reason rather than hanging until the caller's RPC timeout.
    fatal_auth_error = reason
    close_conn(c, reason)
end

local function handle_auth_packet(c, pkt)
    local payload = pkt.payload
    local tag = byte_at(payload, 1)
    if tag == 0x00 then
        mark_ready(c)
        return
    end
    if tag == 0xff then
        fail_auth(c, parse_err(payload))
        return
    end
    if tag == 0xfe then
        local plugin, pos = read_null(payload, 2)
        local seed = string.sub(payload, pos)
        if #seed > 0 and byte_at(seed, #seed) == 0 then
            seed = string.sub(seed, 1, #seed - 1)
        end
        local token, err = auth_token(plugin, config.password, seed)
        if not token then
            fail_auth(c, err)
            return
        end
        c.auth_plugin = plugin
        print(string.format('[XMYSQL-WORKER] auth switch[%d] plugin=%s seed_len=%d',
            c.index, tostring(plugin), #seed))
        c.conn:send_raw(pack_packet(token, pkt.seq + 1))
        return
    end
    if tag == 0x01 then
        local status = byte_at(payload, 2)
        if status == 3 then
            return
        end
        if status == 4 then
            if config.password == '' then
                c.conn:send_raw(pack_packet('', pkt.seq + 1))
                return
            end
            fail_auth(c, "MySQL account uses caching_sha2_password and requires "
                .. "first-time full authentication, which this client does not "
                .. "support. Use an account with mysql_native_password "
                .. "(ALTER USER ... IDENTIFIED WITH mysql_native_password BY '...'), "
                .. "or pre-authenticate once with the mysql CLI to warm the cache.")
            return
        end
    end
    fail_auth(c, 'unexpected auth packet')
end

local function handle_query_packet(c, pkt)
    local payload = pkt.payload
    local tag = byte_at(payload, 1)

    if not c.result then
        if tag == 0x00 then
            complete_request(c, true, parse_ok(payload))
            return
        end
        if tag == 0xff then
            complete_request(c, false, parse_err(payload))
            return
        end

        local col_count = read_lenenc(payload, 1)
        c.result = {
            col_count = col_count,
            columns = {},
            rows = {},
            values = {},
            stage = 'columns',
        }
        return
    end

    local rs = c.result
    if rs.stage == 'columns' then
        if is_eof(payload) then
            rs.stage = 'rows'
            return
        end
        rs.columns[#rs.columns + 1] = parse_column(payload)
        if #rs.columns >= rs.col_count then
            rs.stage = 'fields_eof'
        end
        return
    end

    if rs.stage == 'fields_eof' then
        if is_eof(payload) then
            rs.stage = 'rows'
            return
        end
        rs.stage = 'rows'
    end

    if rs.stage == 'rows' then
        if is_eof(payload) then
            complete_request(c, true, build_result(rs))
            return
        end
        if tag == 0xff then
            complete_request(c, false, parse_err(payload))
            return
        end
        local row, values = parse_row(payload, rs.columns)
        rs.rows[#rs.rows + 1] = row
        rs.values[#rs.values + 1] = values
    end
end

local function connect_one(c)
    if stopping or c.connecting or c.connected then return end
    c.connecting = true
    c.closed = false

    local handler = {}

    function handler.on_connect(conn, ip, port)
        c.conn = conn
        c.connected = true
        c.ready = false
        c.connecting = false
        c.closed = false
        c.phase = 'handshake'
        conn:set_framing({ type = 'raw', max_packet = config.max_packet })
        print(string.format('[XMYSQL-WORKER] connected[%d] %s:%s raw',
            c.index, tostring(ip), tostring(port)))
    end

    function handler.on_packet(_, data)
        local pos = 1
        while pos <= #data do
            local pkt, next_pos, incomplete = parse_packet(data, pos)
            if incomplete then
                break
            end

            if c.phase == 'handshake' then
                c.handshake = parse_handshake(pkt.payload)
                c.auth_plugin = c.handshake.plugin
                print(string.format('[XMYSQL-WORKER] handshake[%d] server=%s plugin=%s seed_len=%d caps=0x%x',
                    c.index, tostring(c.handshake.server_version),
                    tostring(c.handshake.plugin), #c.handshake.seed,
                    c.handshake.capabilities or 0))
                local response, err = make_handshake_response(c.handshake)
                if not response then
                    close_conn(c, err)
                    return next_pos - 1
                end
                c.phase = 'auth'
                c.conn:send_raw(pack_packet(response, 1))
            elseif c.phase == 'auth' then
                handle_auth_packet(c, pkt)
            else
                handle_query_packet(c, pkt)
            end

            pos = next_pos
        end
        return pos - 1
    end

    function handler.on_close(_, reason)
        c.connected = false
        c.ready = false
        c.connecting = false
        c.closed = true
        c.conn = nil
        c.phase = 'closed'
        fail_conn_pending(c, reason or 'mysql connection closed')
        if fatal_auth_error then
            -- Don't leave queued requests hanging until the caller times out;
            -- surface the real reason now. Also stop retrying -- reconnecting
            -- would just hit the same auth failure in a 1s loop.
            local q = waitq
            waitq = {}
            for _, req in ipairs(q) do
                fail_request(req, fatal_auth_error)
            end
        elseif not stopping then
            c.retry_at = os.time() + math.max(1, math.floor(config.reconnect_ms / 1000))
        end
        print(string.format('[XMYSQL-WORKER] close[%d]: %s', c.index, tostring(reason)))
    end

    local conn, err = xnet.connect(config.host, config.port, handler)
    if not conn then
        c.connecting = false
        c.retry_at = os.time() + math.max(1, math.floor(config.reconnect_ms / 1000))
        print(string.format('[XMYSQL-WORKER] connect[%d] failed: %s', c.index, tostring(err)))
        return
    end
    c.conn = conn
end

local function start_pool(host, port, user, password, database, pool_size, reconnect_ms, max_packet, charset)
    config.host = host or config.host
    config.port = tonumber(port) or config.port
    config.user = user or config.user
    config.password = password or ''
    config.database = database or ''
    config.pool_size = math.max(1, tonumber(pool_size) or config.pool_size)
    config.reconnect_ms = tonumber(reconnect_ms) or config.reconnect_ms
    config.max_packet = tonumber(max_packet) or config.max_packet
    config.charset = tonumber(charset) or config.charset
    stopping = false
    fatal_auth_error = nil   -- fresh credentials get a fresh attempt

    for i = 1, config.pool_size do
        local c = {
            index = i,
            conn = nil,
            connected = false,
            ready = false,
            connecting = false,
            closed = false,
            retry_at = 0,
            pending = {},
            result = nil,
            phase = 'init',
        }
        conns[i] = c
        connect_one(c)
    end
end

local function stop_pool(silent)
    stopping = true
    local q = waitq
    waitq = {}
    if not silent then
        for _, req in ipairs(q) do
            fail_request(req, 'xmysql stopped')
        end
    end
    for _, c in ipairs(conns) do
        if silent then
            c.pending = {}
            c.result = nil
        else
            fail_conn_pending(c, 'xmysql stopped')
        end
        close_conn(c, 'xmysql stopped')
    end
    conns = {}
end

xthread.register('xmysql_start', function(host, port, user, password, database, pool_size, reconnect_ms, max_packet, charset)
    print(string.format('[XMYSQL-WORKER] start %s:%s user=%s db=%s pool=%s',
        tostring(host), tostring(port), tostring(user),
        database ~= '' and tostring(database) or '(none)', tostring(pool_size)))
    start_pool(host, port, user, password, database, pool_size, reconnect_ms, max_packet, charset)
end)

xthread.register('xmysql_stop', function(silent)
    stop_pool(silent)
end)

-- In-place pool reconfigure: close the current connections and reconnect with
-- new credentials WITHOUT destroying this thread (see xmysql.reconfigure). Used
-- by the xadmin setup flow so changing DB settings at runtime doesn't require a
-- thread shutdown (which corrupts other threads' poll state).
xthread.register('xmysql_restart', function(host, port, user, password, database, pool_size, reconnect_ms, max_packet, charset)
    print(string.format('[XMYSQL-WORKER] restart (in-place) %s:%s user=%s db=%s',
        tostring(host), tostring(port), tostring(user),
        database ~= '' and tostring(database) or '(none)'))
    stop_pool(true)
    start_pool(host, port, user, password, database, pool_size, reconnect_ms, max_packet, charset)
end)

xthread.register('xmysql_query', function(sql)
    local req = router.current_request()
    if not req then
        return false, 'xmysql rpc context missing'
    end
    if fatal_auth_error then
        -- Pool can't authenticate; fail fast with the real reason instead of
        -- queueing forever (and reporting a misleading rpc timeout).
        return false, fatal_auth_error
    end
    req.sql = tostring(sql)
    req.payload = int1(0x03) .. req.sql
    enqueue(req)
    return coroutine.yield()
end)

local function __init()
    print('[XMYSQL-WORKER] init')
    check_hash_impl()
    assert(xnet.init())
end

local function __update()
    -- Network polling is driven by the C layer after xnet.init(); this
    -- callback only handles Lua-side reconnect timers.
    local now = os.time()
    for _, c in ipairs(conns) do
        if not stopping and not fatal_auth_error and not c.connected and not c.connecting and c.retry_at > 0 and now >= c.retry_at then
            c.retry_at = 0
            connect_one(c)
        end
    end
end

local function __uninit()
    stop_pool(true)
    xnet.uninit()
    print('[XMYSQL-WORKER] uninit')
end

return {
    __init = __init,
    __update = __update,
    __uninit = __uninit,
    __thread_handle = router.handle,
}
