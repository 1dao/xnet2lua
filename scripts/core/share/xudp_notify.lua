-- Optional UDP notification mechanism. No sockets, timers or wire format are
-- created here. Hooks must not reenter an instance. The eventual transport
-- must authenticate before receive/ack/valid_receive, bound decompression and
-- parsing, and allocate a NEW security sequence/nonce on EVERY send attempt.
-- The immutable body below is encoded/compressed logical content, not AEAD
-- ciphertext. None of these hooks supplies a default insecure transport.
assert(type(require('xnet').udp_bind) == 'function', 'UDP support is not enabled')

local M = {}
local Sender, Receiver = {}, {}
Sender.__index, Receiver.__index = Sender, Receiver

local function positive(o, key)
    local n = o[key]
    assert(type(n) == 'number' and n > 0 and n < math.huge and n % 1 == 0,
        key .. ' must be a positive integer')
    return n
end

local function hook(o, key)
    assert(type(o[key]) == 'function', key .. ' function required')
    return o[key]
end

local function id_valid(id) return type(id) == 'string' and #id > 0 end

local function clock(self, now)
    assert(not self.busy, 'UDP notification hook reentry')
    assert(type(now) == 'number' and now < math.huge and now >= self.now,
        'now must be finite monotonic milliseconds')
    self.now = now
end

local function call(self, fn, ...)
    self.busy = true
    local ok, a, b = pcall(fn, ...)
    self.busy = false
    return ok, a, b
end

function M.new_sender(o)
    assert(type(o) == 'table')
    local cfg = {}
    for _, key in ipairs({'max_messages', 'max_bytes', 'max_message_bytes',
        'max_batch_bytes', 'heartbeat_ms', 'retry_ms', 'retry_max_ms',
        'send_retry_ms', 'round_timeout_ms', 'session_timeout_ms', 'max_attempts'}) do
        cfg[key] = positive(o, key)
    end
    assert(cfg.retry_max_ms >= cfg.retry_ms, 'retry_max_ms < retry_ms')
    assert(cfg.max_message_bytes <= cfg.max_bytes, 'message limit exceeds capacity')
    local self = setmetatable({cfg = cfg, pending = {}, held_bytes = 0,
        held_messages = 0, now = 0, counters = {sent = 0, retries = 0,
            send_failures = 0, pack_failures = 0, stale_pongs = 0, queue_full = 0}}, Sender)
    self.pack = hook(o, 'pack')
    self.send_ping = hook(o, 'send_ping')
    self.next_id = hook(o, 'next_id')
    self.compare_ids = hook(o, 'compare_ids')
    clock(self, o.now)
    self.last_receive, self.next_heartbeat = self.now, self.now + cfg.heartbeat_ms
    return self
end

-- Message strings are immutable and owned by the queue after success. Capacity
-- includes queued AND in-flight messages until matching Pong releases them.
function Sender:enqueue(message, key)
    assert(not self.busy, 'UDP notification hook reentry')
    assert(type(message) == 'string', 'encoded message string required')
    if self.expired then return false, self.expired end
    if key ~= nil then assert(id_valid(key), 'nonempty queue key required') end
    if #message > self.cfg.max_message_bytes then return false, 'too_large' end
    if key then
        for _, entry in ipairs(self.pending) do
            if entry.key == key then
                local bytes = self.held_bytes - #entry.data + #message
                if bytes > self.cfg.max_bytes then return false, 'queue_full' end
                entry.data, self.held_bytes = message, bytes
                return true, 'replaced'
            end
        end
        if self.current and self.current.keys[key] == message then return true, 'in_flight' end
    end
    if self.held_messages >= self.cfg.max_messages or
        self.held_bytes + #message > self.cfg.max_bytes then
        self.counters.queue_full = self.counters.queue_full + 1
        return false, 'queue_full'
    end
    self.pending[#self.pending + 1] = {data = message, key = key}
    self.held_messages = self.held_messages + 1
    self.held_bytes = self.held_bytes + #message
    return true
end

-- Keyed replacement affects pending messages only; packed content is immutable.
function Sender:remove_pending(key)
    assert(not self.busy, 'UDP notification hook reentry')
    for i, entry in ipairs(self.pending) do
        if entry.key == key then
            table.remove(self.pending, i)
            self.held_messages = self.held_messages - 1
            self.held_bytes = self.held_bytes - #entry.data
            return true
        end
    end
    return false
end

function Sender:_alive()
    if not self.expired then
        if self.now - self.last_receive >= self.cfg.session_timeout_ms then
            self.expired = 'session_timeout'
        elseif self.current and self.now >= self.current.deadline then
            self.expired = 'round_timeout'
        end
    end
    return not self.expired, self.expired
end

function Sender:step(now)
    clock(self, now)
    if not self:_alive() then return false, self.expired end
    local current = self.current
    if not current then
        if #self.pending == 0 and now < self.next_heartbeat then return true, 'idle' end
        if self.next_pack and now < self.next_pack then return true, 'pack_wait' end
        local ok, id = call(self, self.next_id)
        if not ok or not id_valid(id) then return false, 'invalid_ping_id' end
        if self.last_id then
            local compared, order = call(self, self.compare_ids, id, self.last_id)
            if not compared or order ~= 1 then return false, 'non_increasing_ping_id' end
        end
        -- Reserve the ID even on pack failure; never reuse it for different data.
        self.last_id = id
        local candidate = {}
        for i, entry in ipairs(self.pending) do candidate[i] = entry.data end
        local packed, body, count = call(self, self.pack, id, candidate, self.cfg.max_batch_bytes)
        if not packed or type(body) ~= 'string' or #body > self.cfg.max_batch_bytes or
            type(count) ~= 'number' or count % 1 ~= 0 or count < 0 or
            count > #self.pending or (#self.pending > 0 and count == 0) then
            self.counters.pack_failures = self.counters.pack_failures + 1
            self.next_pack = now + self.cfg.send_retry_ms
            return false, 'pack_failed'
        end
        local bytes, keys = 0, {}
        for _ = 1, count do
            local entry = table.remove(self.pending, 1)
            bytes = bytes + #entry.data
            if entry.key then keys[entry.key] = entry.data end
        end
        current = {id = id, body = body, count = count, bytes = bytes,
            deadline = now + self.cfg.round_timeout_ms, attempts = 0,
            sent = 0, keys = keys, retry_delay = self.cfg.retry_ms, next_retry = now}
        self.current, self.next_pack = current, nil
    end
    if current.transmitting then return true, 'transmitting' end
    if now < current.next_retry then return true, 'waiting' end
    if current.attempts >= self.cfg.max_attempts then
        self.expired = 'attempt_limit'
        return false, self.expired
    end
    current.attempts = current.attempts + 1
    -- Re-encrypting the same logical body is the transport hook's job.
    current.transmitting = true
    local called, sent, reason = call(self, self.send_ping, current.id, current.body, current.attempts)
    if called and sent == nil and reason == 'pending' then return true, 'transmitting' end
    return self:_sent(current, called and sent == true, now,
        called and (reason or 'send_failed') or 'send_failed')
end

function Sender:_sent(current, sent, now, reason)
    current.transmitting = false
    if not sent then
        self.counters.send_failures = self.counters.send_failures + 1
        current.next_retry = now + self.cfg.send_retry_ms
        return false, reason or 'send_failed'
    end
    if current.sent > 0 then self.counters.retries = self.counters.retries + 1 end
    current.sent = current.sent + 1
    self.counters.sent = self.counters.sent + 1
    self.next_heartbeat = now + self.cfg.heartbeat_ms
    current.next_retry = now + current.retry_delay
    current.retry_delay = math.min(self.cfg.retry_max_ms, current.retry_delay * 2)
    return true, 'sent'
end

-- An owning I/O thread reports actual socket acceptance for an async send.
-- A stale receipt must not affect a newer attempt/round or heartbeat deadline.
function Sender:send_result(id, attempt, success, now)
    clock(self, now)
    if not self:_alive() then return false, self.expired end
    local c = self.current
    if not c or c.id ~= id or c.attempts ~= attempt or not c.transmitting then
        return false, 'stale_send_result'
    end
    return self:_sent(c, success == true, now)
end

function Sender:ack(id, now)
    clock(self, now)
    if not self:_alive() then return false, self.expired end
    local current = self.current
    if not current or id ~= current.id or current.sent == 0 then
        self.counters.stale_pongs = self.counters.stale_pongs + 1
        return false, 'stale_pong'
    end
    self.held_messages = self.held_messages - current.count
    self.held_bytes = self.held_bytes - current.bytes
    self.current, self.last_receive = nil, now
    -- Do not wait for the next idle heartbeat when queued data is available.
    self:step(now)
    return true
end

-- Caller may invoke only for an authenticated, fresh, replay-accepted client
-- message. Duplicate/stale control packets must not call this method.
function Sender:valid_receive(now)
    clock(self, now)
    if not self:_alive() then return false, self.expired end
    self.last_receive = now
    return true
end

function Sender:status()
    local out = {pending = #self.pending, held_bytes = self.held_bytes,
        held_messages = self.held_messages, next_heartbeat = self.next_heartbeat,
        last_receive = self.last_receive, expired = self.expired}
    if self.current then
        out.current_id, out.current_body = self.current.id, self.current.body
        out.next_retry, out.deadline = self.current.next_retry, self.current.deadline
    end
    for k, v in pairs(self.counters) do out[k] = v end
    return out
end

function M.new_receiver(o)
    return setmetatable({decode = hook(o, 'decode'), compare_ids = hook(o, 'compare_ids'),
        send_pong = hook(o, 'send_pong'), max_batches = positive(o, 'max_batches'),
        max_messages = positive(o, 'max_messages'), max_bytes = positive(o, 'max_bytes'),
        max_batch_bytes = positive(o, 'max_batch_bytes'), batches = {},
        bytes = 0, messages = 0, duplicates = 0}, Receiver)
end

-- Input has ALREADY passed authentication/replay and bounded decompression.
-- decode must parse the entire body or fail. Receiver queues owned messages
-- before Pong; application execution is explicitly separated via take().
function Receiver:receive(id, body)
    assert(not self.busy, 'UDP notification hook reentry')
    if not id_valid(id) or type(body) ~= 'string' or #body > self.max_batch_bytes then
        return false, 'invalid_ping'
    end
    local decoded, messages = call(self, self.decode, id, body)
    if not decoded or type(messages) ~= 'table' then return false, 'decode_failed' end
    local owned, bytes, count = {}, 0, 0
    for i, message in pairs(messages) do
        if type(i) ~= 'number' or i % 1 ~= 0 or i < 1 or type(message) ~= 'string' then
            return false, 'invalid_messages'
        end
        owned[i], bytes, count = message, bytes + #message, count + 1
        if count > self.max_messages or bytes > self.max_bytes then return false, 'too_large' end
    end
    for i = 1, count do if owned[i] == nil then return false, 'invalid_messages' end end
    local order = 1
    if self.last_id then
        local compared
        compared, order = call(self, self.compare_ids, id, self.last_id)
        if not compared or (order ~= -1 and order ~= 0 and order ~= 1) then
            return false, 'invalid_ping_id'
        end
        if order == 0 and body ~= self.last_body then return false, 'conflicting_ping' end
    end
    if order == 1 then
        if count > 0 and (#self.batches >= self.max_batches or
            self.messages + count > self.max_messages or self.bytes + bytes > self.max_bytes) then
            return false, 'queue_full'
        end
        -- Empty heartbeats carry no business work and need no queue slot.
        if count > 0 then
            self.batches[#self.batches + 1] = {id = id, messages = owned, bytes = bytes}
            self.messages, self.bytes = self.messages + count, self.bytes + bytes
        end
        self.last_id, self.last_body = id, body
    else
        self.duplicates = self.duplicates + 1
    end
    local called, sent = call(self, self.send_pong, id)
    return true, order == 1 and 'accepted' or 'duplicate', called and sent == true
end

function Receiver:take()
    assert(not self.busy, 'UDP notification hook reentry')
    local batch = table.remove(self.batches, 1)
    if not batch then return nil end
    self.messages, self.bytes = self.messages - #batch.messages, self.bytes - batch.bytes
    return batch.messages, batch.id
end

return M
