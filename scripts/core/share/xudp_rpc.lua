-- One instance per authenticated logical session/namespace. Opaque request and
-- result strings are immutable. No sockets, timers, persistence or wire codec.
assert(type(require('xnet').udp_bind) == 'function', 'UDP support is not enabled')
local M, Server, Client = {}, {}, {}
Server.__index, Client.__index = Server, Client
local MAX_ID = 2147483647

local function integer(n, minimum)
    return type(n) == 'number' and n % 1 == 0 and n >= minimum and n <= MAX_ID
end
local function id_number(id)
    if type(id) ~= 'string' or #id > 10 then return nil end
    local n = tonumber(id)
    if integer(n, 1) and tostring(n) == id then return n end
end
local function clock(self, now)
    assert(type(now) == 'number' and now >= self.now and now < math.huge, 'monotonic milliseconds required')
    self.now = now
end
local function config(o, defaults)
    local c = {}
    for key, value in pairs(defaults) do
        c[key] = o[key] == nil and value or o[key]
        assert(integer(c[key], key == 'ack_delay_ms' and 0 or 1), 'invalid ' .. key)
    end
    return c
end

function M.new_server(o)
    assert(type(o.dispatch) == 'function' and type(o.publish) == 'function')
    local c = config(o, {max_records = 128, max_bytes = 131072, max_request_bytes = 512,
        max_result_bytes = 512, result_ttl_ms = 60000, ack_delay_ms = 10, publish_retry_ms = 10})
    assert(c.max_result_bytes >= 32, 'result limit must fit framework errors')
    return setmetatable({cfg = c, dispatch = o.dispatch, publish = o.publish,
        records = {}, count = 0, bytes = 0, highwater = 0, now = 0, dispatches = 0}, Server)
end

function Server:_expire()
    for id, r in pairs(self.records) do
        if r.expires and self.now >= r.expires then
            self.bytes, self.count = self.bytes - r.bytes, self.count - 1
            self.records[id] = nil
        end
    end
end

function Server:_publish(r)
    if not r.dirty or self.now < r.next_publish then return end
    local ok, accepted = pcall(self.publish, r.kind, r.id, r.success, r.payload,
        'rpc:' .. r.id)
    if ok and accepted == true then r.dirty = false
    else r.next_publish = self.now + self.cfg.publish_retry_ms end
end

function Server:request(id, request, now)
    clock(self, now)
    self:_expire()
    local n = id_number(id)
    if not n or type(request) ~= 'string' or #request > self.cfg.max_request_bytes then
        if n then self.highwater = math.max(self.highwater,n) end
        return false, 'invalid_request'
    end
    local r = self.records[id]
    if r then
        if r.request ~= request then return false, 'conflicting_request' end
        if r.state ~= 'processing' then r.dirty = true
        elseif self.now >= r.ack_due then r.dirty, r.kind = true, 'RPC_ACCEPTED' end
        self:_publish(r)
        return true, 'duplicate'
    end
    -- Client calls are serialized. A retired/lower ID must never execute again,
    -- even after the bounded result cache has expired. Keep this watermark for
    -- the lifetime of this session; a new session must have a new identity.
    if n <= self.highwater then return false, 'expired' end
    local reserved = #id + #request + self.cfg.max_result_bytes
    if self.count >= self.cfg.max_records or self.bytes + reserved > self.cfg.max_bytes then
        self.highwater = n -- rejection is final for this ID, even after capacity recovers
        return false, 'capacity'
    end
    r = {id = id, request = request, state = 'processing', bytes = reserved,
        ack_due = now + self.cfg.ack_delay_ms, next_publish = now}
    self.records[id], self.highwater = r, n
    self.count, self.bytes = self.count + 1, self.bytes + reserved
    self.dispatches = self.dispatches + 1
    -- Register before dispatch: synchronous completion and reentrant duplicate
    -- requests see the same record. False means business delivery was rejected.
    local called, accepted = pcall(self.dispatch, id, request)
    if r.state == 'processing' and (not called or accepted ~= true) then
        self:complete(id, false, called and 'dispatch_rejected' or 'dispatch_error', self.now)
    end
    return true
end

function Server:complete(id, success, result, now)
    clock(self, now)
    local r = self.records[id]
    if not r or r.state ~= 'processing' then return false, 'not_processing' end
    if type(success) ~= 'boolean' or type(result) ~= 'string' or #result > self.cfg.max_result_bytes then
        return false, 'invalid_result'
    end
    self.bytes = self.bytes - r.bytes
    r.bytes = #id + #r.request + #result
    self.bytes = self.bytes + r.bytes
    r.state, r.kind, r.success, r.payload = 'done', 'RPC_RESULT', success, result
    r.expires, r.dirty, r.next_publish = now + self.cfg.result_ttl_ms, true, now
    self:_publish(r)
    return true
end

function Server:query(id, now)
    clock(self, now)
    self:_expire()
    if not id_number(id) then return false, 'invalid_id' end
    local r = self.records[id]
    if not r then
        -- Distinct key preserves any already-queued result copy after expiry.
        return self.publish('RPC_STATUS', id, false, 'unknown', 'rpc-expired:' .. id)
    end
    if r.state == 'processing' then
        -- Queries during the short acceptance delay do not defeat coalescing.
        if now < r.ack_due then return true, 'processing' end
        r.kind, r.payload, r.success = 'RPC_STATUS', 'processing', false
    end
    r.dirty = true
    self:_publish(r)
    return true
end

function Server:step(now)
    clock(self, now)
    self:_expire()
    for _, r in pairs(self.records) do
        if r.state == 'processing' and not r.kind and now >= r.ack_due then
            r.kind, r.dirty = 'RPC_ACCEPTED', true
        end
        self:_publish(r)
    end
end

function M.new_client(o)
    assert(type(o.send) == 'function')
    local c = config(o, {max_calls = 32, max_bytes = 32768, max_request_bytes = 512,
        max_result_bytes = 512, request_retry_ms = 100, query_retry_ms = 1000,
        retry_max_ms = 2000, timeout_ms = 10000})
    assert(c.retry_max_ms >= c.request_retry_ms and c.retry_max_ms >= c.query_retry_ms)
    return setmetatable({cfg = c, send = o.send, pending = {}, results = {},
        count = 0, bytes = 0, sequence = 0, now = 0}, Client)
end

function Client:request(request, now)
    clock(self, now)
    if self.closed then return nil, 'closed' end
    if type(request) ~= 'string' or #request > self.cfg.max_request_bytes then return nil, 'too_large' end
    local reserved = #request + self.cfg.max_result_bytes
    if self.count >= self.cfg.max_calls or self.bytes + reserved > self.cfg.max_bytes then return nil, 'capacity' end
    if self.sequence >= MAX_ID then return nil, 'id_exhausted' end
    self.sequence = self.sequence + 1
    local id = tostring(self.sequence)
    self.pending[#self.pending + 1] = {id = id, request = request, bytes = reserved}
    self.count, self.bytes = self.count + 1, self.bytes + reserved
    self:step(now)
    return id
end

function Client:step(now)
    clock(self, now)
    if self.closed then return false, 'closed' end
    if not self.active then
        self.active = table.remove(self.pending, 1)
        if self.active then
            self.active.deadline, self.active.next_send = now + self.cfg.timeout_ms, now
            self.active.delay = self.cfg.request_retry_ms
        end
    end
    local a = self.active
    if not a then return true end
    if now >= a.deadline then
        -- An unknown outcome does NOT release the next cached call. A late
        -- actual result may still resolve this call; close() abandons the queue.
        a.timed_out = true
        return false, 'timeout'
    end
    if now < a.next_send then return true end
    local kind = a.accepted and 'RPC_QUERY' or 'RPC_REQUEST'
    local ok, sent = pcall(self.send, kind, a.id, a.request)
    a.next_send = now + a.delay
    a.delay = math.min(self.cfg.retry_max_ms, a.delay * 2)
    return ok and sent == true
end

function Client:receive(kind, id, success, result, now)
    clock(self, now)
    local a = self.active
    if self.closed or not a or a.id ~= id then return false, 'stale_reply' end
    if kind == 'RPC_RESULT' then
        if type(success) ~= 'boolean' or type(result) ~= 'string' or #result > self.cfg.max_result_bytes then
            return false, 'invalid_result'
        end
        a.success, a.result, a.request = success, result, nil
        self.results[#self.results + 1], self.active = a, nil
        self:step(now) -- ONLY the terminal server result releases the next call
        return true
    elseif kind == 'RPC_ACCEPTED' or (kind == 'RPC_STATUS' and result == 'processing') then
        if not a.accepted then
            a.accepted, a.delay = true, self.cfg.query_retry_ms
            a.next_send = now + a.delay
        end
        return true
    elseif kind == 'RPC_STATUS' and result == 'unknown' then
        a.unknown = true
        return true, 'unknown'
    end
    return false, 'invalid_reply'
end

function Client:take_result()
    local r = table.remove(self.results, 1)
    if not r then return nil end
    self.count, self.bytes = self.count - 1, self.bytes - r.bytes
    return r.id, r.success, r.result
end
function Client:close() self.closed = true end

return M
