-- scripts/game/zone.lua -- pure per-zone AOI actor (design doc §7, §8).
--
-- A zone owns its AOI grid, its subscriber set, and the enter/leave/move delta
-- algorithm. It does NOT own player entities (those live on each player's
-- home lane, design §7.1). The logic is transport-agnostic: deltas are buffered
-- per subscriber and drained through an `emit` callback at frame end, so the
-- identical code path serves an in-process subscriber (xthread.post to its home
-- lane) and a cross-process one (peer_conns to its home game). The subscriber's
-- full route {home_game, home_lane, sid} is what makes this possible without a
-- rewrite when migration lands (design §8.3, §19.1 hook 5).
--
-- AOI visibility rule: a player at grid h sees grid g iff g is in the 3x3 block
-- around h. This is symmetric, so the set of players occupying the 3x3 block
-- around g IS the set of watchers of g -- no separate watcher index needed.

local zone_def = dofile('scripts/game/zone_def.lua')

local M = {}
M.__index = M

-- Per-subscriber delta event kinds.
M.EV_ENTER = 1    -- entity became visible: { id, x, y } full snapshot
M.EV_LEAVE = 2    -- entity left view:      { id }
M.EV_MOVE  = 3    -- visible entity moved:  { id, x, y }

function M.new(zone_id)
    return setmetatable({
        zone_id     = zone_id,
        seq         = 0,        -- monotonic; stamps every delta (design §7.3)
        grid        = {},       -- grid[gx][gy] = { players = { [pid]=true } }
        subscribers = {},       -- pid -> { route, pos = {x,y}, gx, gy }
        pending     = {},       -- pid -> { event, ... }, cleared each flush
    }, M)
end

-- ----- grid occupancy helpers (all O(1) or O(9)) -----

local function cell(zone, gx, gy)
    local col = zone.grid[gx]
    if not col then col = {}; zone.grid[gx] = col end
    local c = col[gy]
    if not c then c = { players = {} }; col[gy] = c end
    return c
end

local function grid_add(zone, gx, gy, pid)
    cell(zone, gx, gy).players[pid] = true
end

local function grid_del(zone, gx, gy, pid)
    local col = zone.grid[gx]
    local c = col and col[gy]
    if c then c.players[pid] = nil end
end

-- Players occupying the 3x3 block around (gx, gy): everyone who can see that
-- cell. Returned as a set { [pid]=true }.
local function watchers(zone, gx, gy)
    local out = {}
    for dx = -1, 1 do
        local col = zone.grid[gx + dx]
        if col then
            for dy = -1, 1 do
                local c = col[gy + dy]
                if c then
                    for pid in pairs(c.players) do out[pid] = true end
                end
            end
        end
    end
    return out
end

local function push(zone, pid, ev)
    local q = zone.pending[pid]
    if not q then q = {}; zone.pending[pid] = q end
    q[#q + 1] = ev
end

-- ----- subscription lifecycle (design §7.2) -----

-- ENTER_ZONE: subscribe `pid` (with routing info `route`) at world `pos`.
-- Returns (snapshot, seq): the list of entities currently visible to pid, for a
-- ZONE_SNAPSHOT downstream. Existing watchers get an EV_ENTER for pid.
function M:enter(pid, route, pos)
    if self.subscribers[pid] then self:leave(pid) end   -- idempotent re-enter
    local gx, gy = zone_def.pos_to_grid(pos.x, pos.y)
    self.subscribers[pid] = { route = route, pos = pos, gx = gx, gy = gy }
    self.seq = self.seq + 1

    local snapshot = {}
    for wpid in pairs(watchers(self, gx, gy)) do
        if wpid ~= pid then
            push(self, wpid, { t = M.EV_ENTER, id = pid, x = pos.x, y = pos.y })
            local s = self.subscribers[wpid]
            snapshot[#snapshot + 1] = { id = wpid, x = s.pos.x, y = s.pos.y }
        end
    end
    grid_add(self, gx, gy, pid)
    return snapshot, self.seq
end

-- LEAVE_ZONE: unsubscribe `pid`. Watchers get an EV_LEAVE.
function M:leave(pid)
    local sub = self.subscribers[pid]
    if not sub then return end
    grid_del(self, sub.gx, sub.gy, pid)
    self.subscribers[pid] = nil
    self.pending[pid] = nil             -- nothing to deliver to a leaver
    self.seq = self.seq + 1
    for wpid in pairs(watchers(self, sub.gx, sub.gy)) do
        push(self, wpid, { t = M.EV_LEAVE, id = pid })
    end
end

-- ----- movement (design §8.3) -----

-- A subscribed player moved to world `pos`. Emits MOVE/ENTER/LEAVE for affected
-- watchers and, on a grid change, for the mover's own changing view.
function M:move(pid, pos)
    local sub = self.subscribers[pid]
    if not sub then return end
    local gx0, gy0 = sub.gx, sub.gy
    local gx1, gy1 = zone_def.pos_to_grid(pos.x, pos.y)
    sub.pos = pos
    self.seq = self.seq + 1

    if gx0 == gx1 and gy0 == gy1 then
        -- same cell: a plain position update to everyone watching it.
        for wpid in pairs(watchers(self, gx1, gy1)) do
            if wpid ~= pid then
                push(self, wpid, { t = M.EV_MOVE, id = pid, x = pos.x, y = pos.y })
            end
        end
        return
    end

    -- cross-cell: capture the old watcher set, relocate, capture the new set,
    -- then diff. Visibility is mutual, so each transition is symmetric.
    local old_w = watchers(self, gx0, gy0)
    grid_del(self, gx0, gy0, pid)
    grid_add(self, gx1, gy1, pid)
    sub.gx, sub.gy = gx1, gy1
    local new_w = watchers(self, gx1, gy1)

    for wpid in pairs(new_w) do
        if wpid ~= pid then
            if old_w[wpid] then
                -- still mutually visible: watcher just sees the mover move.
                push(self, wpid, { t = M.EV_MOVE, id = pid, x = pos.x, y = pos.y })
            else
                -- newly mutually visible: both sides gain each other.
                push(self, wpid, { t = M.EV_ENTER, id = pid, x = pos.x, y = pos.y })
                local s = self.subscribers[wpid]
                push(self, pid, { t = M.EV_ENTER, id = wpid, x = s.pos.x, y = s.pos.y })
            end
        end
    end
    for wpid in pairs(old_w) do
        if wpid ~= pid and not new_w[wpid] then
            -- no longer mutually visible: both sides lose each other.
            push(self, wpid, { t = M.EV_LEAVE, id = pid })
            push(self, pid,  { t = M.EV_LEAVE, id = wpid })
        end
    end
end

-- ----- frame flush (design §9.3) -----

-- Drain buffered deltas. `emit(route, zone_id, seq, events)` is invoked once per
-- subscriber that has events this frame; the caller routes by route fields.
function M:flush(emit)
    local seq = self.seq
    local pending = self.pending
    self.pending = {}
    for pid, q in pairs(pending) do
        if #q > 0 then
            local sub = self.subscribers[pid]
            if sub then emit(sub.route, self.zone_id, seq, q) end
        end
    end
end

-- Introspection helper for tests / monitoring.
function M:subscriber_count()
    local n = 0
    for _ in pairs(self.subscribers) do n = n + 1 end
    return n
end

return M
