-- scripts/game/playerstore.lua -- one home lane's resident player store (§19.1).
--
-- Pure logic, no transport. This is the v1 spine for design §19.1 hooks (3)+(4)
-- and the §19.3 anti-patterns 5/6/8. It exists because v1 must NOT grow the
-- "everything lives in lane memory, flush only on logout" habit (§19.3 #5), which
-- the design calls 锁死设计 -- it makes the v2 migration a data-flow reversal
-- instead of a mechanical extension. So from day one we split a player into:
--
--   * persistent state -- Redis-backed, WRITE-THROUGH. Lane memory is only a
--     droppable cache (§19.1.4). Any field change is marked dirty and flushed out
--     within a time bound; the memory copy can be dropped at any time and reloaded.
--   * runtime state    -- transient (buff timers, cooldowns, AI). This is exactly
--     the payload a v2 MIGRATE packet carries (§19.1.4 "MIGRATE 包只带运行时态");
--     persistent state the destination Game re-pulls from Redis, so the packet
--     stays ~1KB instead of tens of KB.
--
-- Lifecycle is standalone functions, NOT inlined into a login/logout handler
-- (§19.1.3 / §19.3 #6): spawn()/despawn() are the SAME two entry points v2 will
-- call on the MIGRATE send/recv ends. In v1 `runtime_hint` is nil (cold start
-- from Redis); in v2 it is the runtime態 the MIGRATE packet brought over.
--
--   * spawn(pid, runtime_hint) -- cold-load persistent via opts.load, build the
--     resident entry. Idempotent. Decoupled from "login".
--   * get/set                  -- persistent reads / write-through writes.
--   * get_runtime/set_runtime  -- the transient, migration-carried fields.
--   * flush(now, force)        -- push dirty persistent fields to opts.write,
--     batched but time-bounded (§19.1.4 "可批量,但有时间上限").
--   * disconnect/reconnect     -- mark offline but KEEP memory for a grace window.
--   * reap(now)                -- §19.1.4 "断线 30s 没回来 → 清内存,不丢数据":
--     force-flush then drop entries past the grace window. No data loss.
--   * despawn(pid)             -- force-flush then drop (the logout / MIGRATE-send).
--   * invalidate(pid)          -- §19.3 #8: drop the cache WITHOUT flushing. v1
--     never calls it, but the interface must exist so v2 can forget a player that
--     migrated away. This is the one drop path that does NOT write.
--
-- DEFERRED LIVE EDGE: opts.load/opts.write are where this meets the work worker
-- and xredis. v1 wires them to async Redis read/write; until that lands they
-- default to an in-memory no-op so the logic is unit-testable in isolation.

local M = {}
M.__index = M

local DEFAULT_FLUSH_MAX_MS = 1000    -- upper bound on how long a dirty field waits
local DEFAULT_DROP_AFTER_MS = 30000  -- §19.1.4 disconnect grace before memory drop

function M.new(opts)
    opts = opts or {}
    local self = setmetatable({}, M)
    self.players = {}                         -- [pid] = entry
    -- load(pid) -> persistent table (cold start from Redis). Default: empty.
    self.load = opts.load or function() return {} end
    -- write(pid, fields) -> persist the dirty subset (the write-through sink).
    self.write = opts.write or function() return true end
    self.flush_max_ms = opts.flush_max_ms or DEFAULT_FLUSH_MAX_MS
    self.drop_after_ms = opts.drop_after_ms or DEFAULT_DROP_AFTER_MS
    return self
end

-- Flush one entry's pending persistent writes, if any. With force=true the time
-- bound is ignored (logout / migrate-send / reap must leave nothing behind);
-- otherwise we only write once the oldest pending change has aged past
-- flush_max_ms, so several set()s coalesce into a single batched write.
-- Returns true iff a write actually happened.
local function flush_entry(self, pid, e, now_ms, force)
    if next(e.dirty) == nil then return false end
    if not force and e.dirty_since ~= nil
        and (now_ms - e.dirty_since) < self.flush_max_ms then
        return false
    end
    local fields = {}
    for k in pairs(e.dirty) do fields[k] = e.persistent[k] end
    self.write(pid, fields)
    e.dirty = {}
    e.dirty_since = nil
    return true
end

-- Lifecycle (§19.1.3): bring a player resident in this lane. v1 calls it from
-- login admission with runtime_hint=nil (cold load); v2 calls the SAME function
-- on the MIGRATE recv end with the runtime態 the packet carried. Idempotent: a
-- second spawn of a resident player just re-marks them online (it does NOT reload
-- and clobber unflushed memory). Returns the entry.
function M:spawn(pid, runtime_hint, now_ms)
    local e = self.players[pid]
    if e then
        e.online = true
        e.disconnected_at = nil
        return e
    end
    e = {
        persistent = self.load(pid) or {},
        runtime = runtime_hint or {},
        dirty = {},
        dirty_since = nil,
        online = true,
        disconnected_at = nil,
    }
    self.players[pid] = e
    return e
end

-- Read a persistent (Redis-backed) field. nil if the player is not resident.
function M:get(pid, field)
    local e = self.players[pid]
    if not e then return nil end
    return e.persistent[field]
end

-- Write-through a persistent field (§19.1.4 / §19.3 #5): update the memory cache,
-- mark the field dirty, and stamp the oldest-pending time so flush() can honour
-- the time bound. The actual Redis write happens in flush(); this never blocks the
-- battle frame. Returns true, or nil if the player is not resident.
function M:set(pid, field, value, now_ms)
    local e = self.players[pid]
    if not e then return nil end
    e.persistent[field] = value
    e.dirty[field] = true
    if e.dirty_since == nil then e.dirty_since = now_ms or 0 end
    return true
end

-- Read a transient runtime field (the migration-carried state). nil if not resident.
function M:get_runtime(pid, field)
    local e = self.players[pid]
    if not e then return nil end
    return e.runtime[field]
end

-- Write a transient runtime field. NOT persisted and NOT dirty: this is the state
-- a v2 MIGRATE packet packs and ships, never the Redis write-through path.
function M:set_runtime(pid, field, value)
    local e = self.players[pid]
    if not e then return nil end
    e.runtime[field] = value
    return true
end

-- Periodic write-through drain. Flushes every resident entry whose dirty fields
-- have aged past flush_max_ms (or all of them when force=true). Returns the number
-- of players actually written. The work worker calls this on a tick.
function M:flush(now_ms, force)
    now_ms = now_ms or 0
    local n = 0
    for pid, e in pairs(self.players) do
        if flush_entry(self, pid, e, now_ms, force) then n = n + 1 end
    end
    return n
end

-- Lifecycle (§19.1.3): take a player out of this lane (logout / MIGRATE-send).
-- Force-flush first so nothing is lost, then drop the memory. Returns true, or
-- false if the player was not resident.
function M:despawn(pid, now_ms)
    local e = self.players[pid]
    if not e then return false end
    flush_entry(self, pid, e, now_ms or 0, true)
    self.players[pid] = nil
    return true
end

-- Mark a player offline but KEEP their memory for the grace window (§19.1.4):
-- a quick reconnect must not re-pay the cold load. Returns true if resident.
function M:disconnect(pid, now_ms)
    local e = self.players[pid]
    if not e then return false end
    e.online = false
    e.disconnected_at = now_ms or 0
    return true
end

-- The player came back inside the grace window: cancel the pending drop. Returns
-- true if resident.
function M:reconnect(pid, now_ms)
    local e = self.players[pid]
    if not e then return false end
    e.online = true
    e.disconnected_at = nil
    return true
end

-- §19.1.4 "断线 30s 没回来 → 直接清内存,不丢数据": sweep every disconnected entry
-- past drop_after_ms, force-flush it, then drop the memory. Returns how many were
-- dropped. Write-through means the persistent state is already safe; the force
-- flush just covers any field changed in the last sub-second before disconnect.
function M:reap(now_ms)
    now_ms = now_ms or 0
    local dropped = 0
    for pid, e in pairs(self.players) do
        if not e.online and e.disconnected_at ~= nil
            and (now_ms - e.disconnected_at) >= self.drop_after_ms then
            flush_entry(self, pid, e, now_ms, true)
            self.players[pid] = nil
            dropped = dropped + 1
        end
    end
    return dropped
end

-- §19.3 #8: drop the cached copy WITHOUT flushing -- a pure cache invalidation.
-- v1 caches forever and never calls this; the interface exists so v2 can forget a
-- player the moment a MIGRATE hands them to another Game. Unlike despawn() this
-- deliberately does not write (the destination owns the data now). Returns true if
-- a record was dropped.
function M:invalidate(pid)
    if self.players[pid] == nil then return false end
    self.players[pid] = nil
    return true
end

function M:known(pid)
    return self.players[pid] ~= nil
end

function M:online(pid)
    local e = self.players[pid]
    return e ~= nil and e.online == true
end

function M:is_dirty(pid)
    local e = self.players[pid]
    return e ~= nil and next(e.dirty) ~= nil
end

function M:count()
    local n = 0
    for _ in pairs(self.players) do n = n + 1 end
    return n
end

return M
