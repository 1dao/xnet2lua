-- scripts/game/mailbox.lua -- work-worker offline message store (design §10).
--
-- Pure logic, no transport. §10 puts "离线消息处理" on the work worker: mail,
-- private chat, and reward grants aimed at a player who is *offline* can't be
-- delivered in real time, so they are parked here and handed over the moment
-- the recipient comes back. The online/offline decision lives in the session
-- layer; this module is just the store:
--
--   * deliver()  -- park a message for an offline recipient. Boxes are capped
--     (a full box rejects new mail) and entries optionally expire after a TTL.
--   * drain()    -- the login hand-off: take a recipient's whole backlog in
--     FIFO order and clear the box.
--   * peek()/pending() -- inspect without consuming ("you have N unread").
--   * ack()      -- claim/remove a single message (mail UI collects one at a
--     time), idempotent on unknown ids.
--   * reap()     -- periodic sweep that drops expired mail across every box.

local M = {}
M.__index = M

local DEFAULT_CAP = 200          -- max parked messages per recipient

function M.new(opts)
    opts = opts or {}
    local self = setmetatable({}, M)
    self.cap = opts.cap or DEFAULT_CAP
    self.ttl_ms = opts.ttl_ms        -- nil = messages never expire
    self.boxes = {}                  -- [to] = { msgs = { <stored>, ... } }
    self.seq = 0                     -- monotonic id source
    return self
end

local function shallow_copy(t)
    local c = {}
    if t then for k, v in pairs(t) do c[k] = v end end
    return c
end

local function box_of(self, to)
    local b = self.boxes[to]
    if not b then
        b = { msgs = {} }
        self.boxes[to] = b
    end
    return b
end

-- Drop TTL-expired messages from one box in place; returns how many went.
-- A message expires once `now_ms - ts >= ttl_ms` (no TTL => never).
function M:_sweep_box(b, now_ms)
    if self.ttl_ms == nil then return 0 end
    now_ms = now_ms or 0
    local kept, dropped = {}, 0
    for _, m in ipairs(b.msgs) do
        if (now_ms - m.ts) >= self.ttl_ms then
            dropped = dropped + 1
        else
            kept[#kept + 1] = m
        end
    end
    if dropped > 0 then b.msgs = kept end
    return dropped
end

-- Park a message for offline recipient `to`. The stored copy is stamped with a
-- monotonic `id` and arrival `ts`; a missing `kind` defaults to 'mail'.
-- Returns the stored message, or nil + 'mailbox_full' when the box is at cap.
function M:deliver(to, msg, now_ms)
    now_ms = now_ms or 0
    local b = box_of(self, to)
    self:_sweep_box(b, now_ms)       -- make room before the capacity check
    if #b.msgs >= self.cap then
        return nil, 'mailbox_full'
    end
    self.seq = self.seq + 1
    local stored = shallow_copy(msg)
    stored.id = self.seq
    stored.ts = now_ms
    if stored.kind == nil then stored.kind = 'mail' end
    b.msgs[#b.msgs + 1] = stored
    return stored
end

-- How many messages are waiting for `to` (drops expired first if now_ms given).
function M:pending(to, now_ms)
    local b = self.boxes[to]
    if not b then return 0 end
    if now_ms ~= nil then self:_sweep_box(b, now_ms) end
    return #b.msgs
end

-- Waiting messages for `to` in FIFO order, WITHOUT clearing the box.
function M:peek(to, now_ms)
    local b = self.boxes[to]
    if not b then return {} end
    if now_ms ~= nil then self:_sweep_box(b, now_ms) end
    local out = {}
    for i, m in ipairs(b.msgs) do out[i] = m end
    return out
end

-- The login hand-off: return `to`'s whole backlog (FIFO, expired dropped) and
-- clear the box. Always returns a list (empty when there is nothing waiting).
function M:drain(to, now_ms)
    local b = self.boxes[to]
    if not b then return {} end
    if now_ms ~= nil then self:_sweep_box(b, now_ms) end
    local out = b.msgs
    self.boxes[to] = nil
    return out
end

-- Remove a single message by id (the player claimed/read it). Returns the
-- removed message, or nil if `to`/`id` is not present.
function M:ack(to, id)
    local b = self.boxes[to]
    if not b then return nil end
    for i, m in ipairs(b.msgs) do
        if m.id == id then
            table.remove(b.msgs, i)
            if #b.msgs == 0 then self.boxes[to] = nil end
            return m
        end
    end
    return nil
end

-- Periodic sweep: drop expired mail across every box and prune empty boxes.
-- Returns the total number of messages dropped.
function M:reap(now_ms)
    if self.ttl_ms == nil then return 0 end
    local total = 0
    for to, b in pairs(self.boxes) do
        total = total + self:_sweep_box(b, now_ms)
        if #b.msgs == 0 then self.boxes[to] = nil end
    end
    return total
end

return M
