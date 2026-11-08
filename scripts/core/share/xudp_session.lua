-- Lua-only, process-lifetime UDP sessions. The send callback owns socket/thread
-- routing. Binary codecs and security/compression are replaceable callbacks.
-- Plaintext requires explicit allow_insecure=true (used by the loopback demo).
local notify = dofile('scripts/core/share/xudp_notify.lua')
local rpc = dofile('scripts/core/share/xudp_rpc.lua')
local move = dofile('scripts/core/share/xudp_move.lua')
local json = require('xutils')
local M, Session = {}, {}
Session.__index = Session
local MAX = 2147483647
local function number(n, min)
    return type(n) == 'number' and n % 1 == 0 and n >= (min or 1) and n <= MAX
end
local function id(s) return type(s) == 'string' and #s <= 10 and number(tonumber(s)) and tostring(tonumber(s)) == s end
local function clock(self, now)
    assert(type(now) == 'number' and now >= self.now and now < math.huge, 'monotonic milliseconds required')
    self.now = now
end
local function encode(self, value)
    local ok, data = pcall(self.pack, value)
    if ok and type(data) == 'string' and #data <= self.max_plain then return data end
end
local function decode(self, data)
    if type(data) ~= 'string' or #data > self.max_plain then return nil end
    local ok, value = pcall(self.unpack, data)
    if ok and type(value) == 'table' then return value end
end
local function message_valid(self, m)
    if type(m) ~= 'table' then return false end
    if m.kind == 'NOTIFY' then
        return type(m.name) == 'string' and #m.name > 0 and #m.name <= 64 and
            type(m.payload) == 'string' and #m.payload <= self.max_payload
    elseif m.kind == 'PAUSE' then
        return move.valid(m.state) and #m.state.payload <= self.max_payload
    elseif m.kind == 'RPC_ACCEPTED' then return id(m.id)
    elseif m.kind == 'RPC_RESULT' then
        return id(m.id) and type(m.success) == 'boolean' and type(m.payload) == 'string'
            and #m.payload <= self.max_payload
    elseif m.kind == 'RPC_STATUS' then
        return id(m.id) and (m.payload == 'processing' or m.payload == 'unknown')
    end
    return false
end

function Session:_decode_batch(ping_id, body)
    local messages = decode(self,body)
    if not messages then return nil end
    local count,bytes,events,total_bytes = 0,0,0,0
    for index,data in pairs(messages) do
        if not number(index) or type(data)~='string' then return nil end
        count,total_bytes = count+1,total_bytes+#data
        local m = decode(self,data)
        if not message_valid(self,m) then return nil end
        if m.kind=='NOTIFY' or m.kind=='PAUSE' then events,bytes = events+1,bytes+#data end
    end
    for i=1,count do if messages[i]==nil then return nil end end
    if count>self.notifications.max_messages or total_bytes>self.notifications.max_bytes then return nil end
    local last = self.notifications.last_id
    if last==ping_id and body~=self.notifications.last_body then return nil end
    if not last or tonumber(ping_id)>tonumber(last) then
        if #self.events+events>self.max_events or self.event_bytes+bytes>self.max_event_bytes then return nil end
    end
    return messages
end

function Session:_send(kind, fields, context)
    if not self.peer_ip then return false, 'no_peer' end
    if self.tx >= MAX then return false, 'sequence_exhausted' end
    self.tx = self.tx + 1 -- failed sends never reuse a security sequence
    local p = {version = 1, session = self.session_id, sequence = self.tx, kind = kind}
    for k, v in pairs(fields or {}) do p[k] = v end
    local body = encode(self, p)
    if not body then return false, 'encode_failed' end
    local flag = 'R'
    if self.compress and #body >= self.compress_threshold then
        local ok, compressed = pcall(self.compress, body)
        if not ok or type(compressed) ~= 'string' then return false, 'compress_failed' end
        if #compressed < #body then flag, body = 'C', compressed end
    end
    body = flag .. body
    if self.seal then
        local ok, sealed = pcall(self.seal, body, self.tx, self.server and 's2c' or 'c2s')
        if not ok or type(sealed) ~= 'string' then return false, 'seal_failed' end
        body = sealed
    end
    if #body > self.max_packet then return false, 'too_large' end
    return self.send(body, self.peer_ip, self.peer_port, kind, context)
end

function Session:_fits(kind, fields)
    local p = {version = 1, session = self.session_id, sequence = MAX, kind = kind}
    for k,v in pairs(fields) do p[k] = v end
    local bytes = encode(self,p)
    return bytes and #bytes + 1 + self.security_overhead <= self.max_packet
end
function Session:_queue(data, key)
    if not data then return false, 'encode_failed' end
    local batch = encode(self,{data})
    if not batch or #batch > self.notifications.cfg.max_batch_bytes or
        not self:_fits('PING',{id = tostring(MAX),body = batch}) then return false, 'too_large' end
    return self.notifications:enqueue(data,key)
end
function Session:_publish(kind, rpc_id, success, payload, key)
    local data = encode(self, {kind = kind, id = rpc_id, success = success, payload = payload})
    if not data then return false, 'encode_failed' end
    return self:_queue(data, key)
end

local function new(o, server)
    assert(type(o.send) == 'function')
    assert(type(o.session_id) == 'string' and #o.session_id > 0 and #o.session_id <= 128)
    assert((type(o.seal) == 'function' and type(o.open) == 'function') or
        (not o.seal and not o.open and o.allow_insecure == true), 'security callbacks or explicit simulation mode required')
    assert((not o.compress and not o.decompress) or
        (type(o.compress) == 'function' and type(o.decompress) == 'function'))
    local self = setmetatable({server = server, send = o.send, session_id = o.session_id,
        pack = o.pack or json.json_pack, unpack = o.unpack or json.json_unpack,
        seal = o.seal, open = o.open, compress = o.compress, decompress = o.decompress,
        compress_threshold = o.compress_threshold or 256, max_packet = o.max_packet or 1200,
        max_plain = o.max_plain or 4096, max_payload = o.max_payload or 512,
        security_overhead = o.security_overhead or (o.seal and 64 or 0),
        max_events = o.max_events or 64, max_event_bytes = o.max_event_bytes or 32768,
        peer_ip = o.peer_ip, peer_port = o.peer_port, now = o.now or 0, tx = 0, rx_max = 0,
        replay = {}, events = {}, event_bytes = 0, latest = {}, next_hello = o.now or 0,
        hello_retry_ms = o.hello_retry_ms or 100, skipped_pauses = 0}, Session)
    self.replay_window = o.replay_window or 64
    for _, key in ipairs({'max_packet','max_plain','max_payload','max_events','max_event_bytes','hello_retry_ms','compress_threshold'}) do
        assert(number(self[key]), 'invalid ' .. key)
    end
    assert(self.max_packet <= 65507 and self.max_plain <= 1048576)
    assert(type(self.now)=='number' and self.now>=0 and self.now<math.huge)
    assert(type(self.pack)=='function' and type(self.unpack)=='function')
    assert(number(self.security_overhead,0))
    assert(number(self.replay_window) and self.replay_window <= 4096)
    assert(not self.peer_ip or (type(self.peer_ip) == 'string' and number(self.peer_port) and self.peer_port <= 65535))
    local cfg = o.notify or {}
    local r = {}; for k,v in pairs(o.rpc or {}) do r[k] = v end
    r.max_request_bytes = r.max_request_bytes or self.max_payload
    r.max_result_bytes = r.max_result_bytes or self.max_payload
    assert(number(r.max_request_bytes) and r.max_request_bytes <= self.max_payload)
    assert(number(r.max_result_bytes) and r.max_result_bytes <= self.max_payload)
    if server then
        self.notifications = notify.new_sender({now = self.now, max_messages = cfg.max_messages or 64,
            max_bytes = cfg.max_bytes or 32768, max_message_bytes = cfg.max_message_bytes or 800,
            max_batch_bytes = cfg.max_batch_bytes or 800, heartbeat_ms = cfg.heartbeat_ms or 1000,
            retry_ms = cfg.retry_ms or 100, retry_max_ms = cfg.retry_max_ms or 1000,
            send_retry_ms = cfg.send_retry_ms or 10, round_timeout_ms = cfg.round_timeout_ms or 10000,
            session_timeout_ms = cfg.session_timeout_ms or 30000, max_attempts = cfg.max_attempts or 32,
            compare_ids = function(a,b) return tonumber(a) > tonumber(b) and 1 or (a == b and 0 or -1) end,
            next_id = function()
                self.ping_sequence = (self.ping_sequence or 0) + 1
                assert(self.ping_sequence <= MAX, 'ping IDs exhausted')
                return tostring(self.ping_sequence)
            end,
            pack = function(_, messages, budget)
                local selected, body = {}, encode(self, {})
                for i, data in ipairs(messages) do
                    selected[i] = data
                    local candidate = encode(self, selected)
                    if not candidate or #candidate > budget or
                        not self:_fits('PING',{id = tostring(MAX),body = candidate}) then selected[i] = nil; break end
                    body = candidate
                end
                return body, #selected
            end,
            send_ping = function(ping_id, body, attempt)
                return self:_send('PING', {id = ping_id, body = body}, {session = self.session_id, id = ping_id, attempt = attempt})
            end})
        r.dispatch = assert(o.dispatch, 'dispatch callback required')
        r.publish = function(...) return self:_publish(...) end
        self.rpc = rpc.new_server(r)
        local m = {}; for k,v in pairs(o.move or {}) do m[k] = v end
        m.max_payload_bytes = m.max_payload_bytes or self.max_payload
        assert(number(m.max_payload_bytes) and m.max_payload_bytes <= self.max_payload)
        m.send = function(state) return self:_send('MOVE', {state = state}) end
        self.moves = move.new_sender(m)
    else
        assert(self.peer_ip, 'server address required')
        assert(self.max_events >= (cfg.max_messages or 64), 'event queue must fit a whole batch')
        assert(self.max_event_bytes >= (cfg.max_batch_bytes or 800), 'event byte limit must fit a whole batch')
        r.send = function(kind, rpc_id, request)
            if not self.ready then return false, 'not_ready' end
            return self:_send(kind, {id = rpc_id, request = kind == 'RPC_REQUEST' and request or nil})
        end
        self.rpc = rpc.new_client(r)
        self.moves = move.new_receiver(o.move)
        self.notifications = notify.new_receiver({max_batches = 4, max_messages = cfg.max_messages or 64,
            max_bytes = cfg.max_bytes or 32768, max_batch_bytes = cfg.max_batch_bytes or 800,
            compare_ids = function(a,b) return tonumber(a) > tonumber(b) and 1 or (a == b and 0 or -1) end,
            decode = function(ping_id, body)
                return self:_decode_batch(ping_id,body)
            end,
            send_pong = function(ping_id) return self:_send('PONG', {id = ping_id}) end})
    end
    return self
end

function M.new_server(o) return new(o, true) end
function M.new_client(o) return new(o, false) end

function Session:_packet(data)
    if type(data) ~= 'string' or #data > self.max_packet then return nil, 'too_large' end
    if self.open then
        local ok, plain = pcall(self.open, data, self.server and 'c2s' or 's2c')
        if not ok or type(plain) ~= 'string' then return nil, 'authentication_failed' end
        data = plain
    end
    if #data>self.max_plain+1 then return nil,'too_large' end
    local flag = data:sub(1,1)
    data = data:sub(2)
    if flag == 'C' then
        if not self.decompress then return nil, 'compression_unsupported' end
        local ok, plain = pcall(self.decompress, data, self.max_plain)
        if not ok or type(plain) ~= 'string' or #plain > self.max_plain then return nil, 'decompress_failed' end
        data = plain
    elseif flag ~= 'R' then return nil, 'invalid_envelope' end
    local p = decode(self, data)
    if not p or p.version ~= 1 or p.session ~= self.session_id or not number(p.sequence) then return nil, 'invalid_packet' end
    if self.replay[p.sequence] or p.sequence <= self.rx_max - self.replay_window then return nil, 'replay' end
    return p
end

function Session:receive(data, ip, port, now)
    clock(self, now)
    if self.closed then return false,'closed' end
    local p, error = self:_packet(data)
    if not p then return false, error end
    if type(ip) ~= 'string' or not number(port) or port > 65535 then return false, 'invalid_peer' end
    if self.peer_ip and (ip ~= self.peer_ip or port ~= self.peer_port) then return false, 'path_change_unsupported' end
    local valid = (p.kind == 'HELLO' and self.server) or (p.kind == 'HELLO_OK' and not self.server)
    if p.kind == 'PONG' and self.server then valid = id(p.id)
    elseif p.kind == 'PING' and not self.server then valid = id(p.id) and type(p.body) == 'string'
    elseif p.kind == 'MOVE' and not self.server then valid = move.valid(p.state) and #p.state.payload <= self.max_payload
    elseif p.kind == 'RPC_REQUEST' and self.server then valid = id(p.id) and type(p.request) == 'string' and #p.request <= self.max_payload
    elseif p.kind == 'RPC_QUERY' and self.server then valid = id(p.id) end
    if not valid then return false, 'invalid_message' end
    if self.server and not self.peer_ip and p.kind~='HELLO' and p.kind~='RPC_REQUEST' then return false,'no_peer' end
    if p.kind=='PING' and not self:_decode_batch(p.id,p.body) then return false,'invalid_batch' end
    -- Peer changes, unauthenticated packets and malformed messages never update
    -- routing/liveness. Security replay and logical Ping dedup are separate.
    self.peer_ip, self.peer_port = ip, port
    self.rx_max = math.max(self.rx_max, p.sequence)
    self.replay[p.sequence] = true
    for sequence in pairs(self.replay) do if sequence <= self.rx_max - self.replay_window then self.replay[sequence] = nil end end
    if p.kind == 'HELLO' then
        if not self.ready then self.ready = true; self.notifications:valid_receive(now) end
        return self:_send('HELLO_OK')
    elseif p.kind == 'HELLO_OK' then
        if not self.ready then
            self.ready = true
            if self.rpc.active then self.rpc.active.next_send = now end
            return self.rpc:step(now)
        end
        return true
    elseif p.kind == 'PONG' then return self.notifications:ack(p.id, now)
    elseif p.kind == 'RPC_REQUEST' then
        local ok, reason = self.rpc:request(p.id, p.request, now)
        if ok and reason ~= 'duplicate' then self.notifications:valid_receive(now)
        elseif ok then return true,reason
        elseif reason == 'capacity' or reason == 'invalid_request' then
            self:_publish('RPC_RESULT', p.id, false, reason, 'rpc-rejected:' .. p.id)
        else self:_publish('RPC_STATUS', p.id, false, 'unknown', 'rpc-expired:' .. p.id) end
        return ok, reason
    elseif p.kind == 'RPC_QUERY' then
        return self.rpc:query(p.id, now)
    elseif p.kind == 'MOVE' then
        local ok, state = self.moves:accept(p.state)
        if ok then self.latest[state.entity] = state end
        return ok, state
    elseif p.kind == 'PING' then
        local accepted, reason = self.notifications:receive(p.id, p.body)
        if not accepted then return false, reason end
        while true do
            local messages = self.notifications:take()
            if not messages then break end
            for _, bytes in ipairs(messages) do
                local m = assert(decode(self, bytes))
                if m.kind == 'NOTIFY' or m.kind == 'PAUSE' then
                    local keep = true
                    if m.kind == 'PAUSE' then
                        keep = self.moves:accept(m.state)
                        if keep then self.latest[m.state.entity] = m.state
                        else self.skipped_pauses = self.skipped_pauses + 1 end
                    end
                    if keep then
                        self.events[#self.events + 1] = {message = m, bytes = #bytes}
                        self.event_bytes = self.event_bytes + #bytes
                    end
                else self.rpc:receive(m.kind, m.id, m.success, m.payload, now) end
            end
        end
        return true, reason
    end
end

function Session:step(now)
    clock(self, now)
    if self.closed then return false,'closed' end
    local rpc_ok,rpc_reason = self.rpc:step(now)
    if self.server then
        if not self.peer_ip then return true, 'no_peer' end
        local ok, reason = self.notifications:step(now)
        self.moves:flush()
        return ok, reason
    elseif not self.ready and now >= self.next_hello then
        self.next_hello = now + self.hello_retry_ms
        return self:_send('HELLO')
    end
    if not self.server and rpc_ok == false then return false,rpc_reason end
    return true
end
function Session:notify(name, payload)
    assert(self.server)
    if self.closed then return false,'closed' end
    local m = {kind = 'NOTIFY', name = name, payload = payload}
    if not message_valid(self,m) then return false, 'invalid_notify' end
    local data = encode(self,m)
    if not data then return false, 'encode_failed' end
    return self:_queue(data)
end
function Session:pause(state)
    assert(self.server)
    if self.closed then return false,'closed' end
    if not move.valid(state) or #state.payload > self.max_payload then return false, 'invalid_pause' end
    local data = encode(self, {kind = 'PAUSE', state = state})
    if not data then return false, 'encode_failed' end
    return self:_queue(data, 'pause:' .. state.entity)
end
function Session:move(state)
    assert(self.server)
    if self.closed then return false,'closed' end
    if not move.valid(state) or #state.payload>self.max_payload then return false,'invalid_move' end
    if not self:_fits('MOVE',{state=state}) then return false,'too_large' end
    return self.moves:put(state)
end
function Session:rpc_call(request, now)
    assert(not self.server); clock(self,now)
    if self.closed then return nil,'closed' end
    if type(request) ~= 'string' or #request>self.rpc.cfg.max_request_bytes or
        not self:_fits('RPC_REQUEST',{id = tostring(MAX),request = request}) then return nil,'too_large' end
    return self.rpc:request(request,now)
end
function Session:complete(rpc_id, success, result, now)
    assert(self.server); clock(self,now)
    if self.closed then return false,'closed' end
    if not id(rpc_id) or type(success)~='boolean' or type(result)~='string' or
        #result>self.rpc.cfg.max_result_bytes then return false,'invalid_result' end
    local data = encode(self,{kind = 'RPC_RESULT',id = rpc_id,success = success,payload = result})
    local batch = data and encode(self,{data})
    if not batch or #data > self.notifications.cfg.max_message_bytes or
        #batch > self.notifications.cfg.max_batch_bytes or not self:_fits('PING',{id = tostring(MAX),body = batch}) then
        return false,'too_large'
    end
    return self.rpc:complete(rpc_id,success,result,now)
end
function Session:send_result(context, success, now)
    assert(self.server); clock(self,now)
    if self.closed then return false,'closed' end
    if type(context)~='table' or context.session~=self.session_id then return false,'stale_session' end
    return self.notifications:send_result(context.id, context.attempt, success, now)
end
function Session:baseline(entity, generation)
    assert(not self.server)
    local ok,reason = self.moves:baseline(entity,generation)
    if ok then self.latest[entity] = nil end
    return ok,reason
end
function Session:take_move(entity) local state = self.latest[entity]; self.latest[entity] = nil; return state end
function Session:forget_entity(entity)
    self.latest[entity] = nil
    return self.moves:forget(entity)
end
function Session:take_result() assert(not self.server); return self.rpc:take_result() end
function Session:take_notification()
    while #self.events > 0 do
        local entry = table.remove(self.events, 1)
        self.event_bytes = self.event_bytes - entry.bytes
        local m = entry.message
        local v = m.kind == 'PAUSE' and self.moves.versions[m.state.entity]
        if m.kind~='PAUSE' or (v and v.generation == m.state.generation and v.motion == m.state.motion and v.sequence == m.state.sequence) then
            return m
        end
        self.skipped_pauses = self.skipped_pauses + 1
    end
end
function Session:close()
    self.closed = true
    if not self.server then self.rpc:close() end
end
function Session:status()
    local out = {ready = self.ready == true, closed = self.closed == true, sequence = self.tx,
        receive_sequence = self.rx_max, peer_ip = self.peer_ip, peer_port = self.peer_port,
        skipped_pauses = self.skipped_pauses, rpc_records = self.rpc.count, rpc_bytes = self.rpc.bytes}
    if self.server then
        out.notifications = self.notifications:status()
        out.move_pending = #self.moves.order
    else
        local a = self.rpc.active
        out.rpc_active = a and a.id
        out.rpc_timed_out = a and a.timed_out or false
        out.rpc_pending = #self.rpc.pending
        out.notification_pending = #self.events
    end
    return out
end
return M
