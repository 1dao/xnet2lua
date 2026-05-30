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
--
-- Cross-zone borders (design §8.4): an entity sitting on a zone edge cell has a
-- view block that spills one cell into the neighbouring zone. Two mechanisms
-- bridge that gap, both reusing the same 3x3 machinery:
--   * EGRESS  -- a local subscriber on an edge cell is announced to the neighbour
--               owner via `border_out`; zone_host routes it by lattice direction.
--   * GHOST   -- a foreign entity the neighbour announced is injected here at its
--               translated (possibly out-of-[0,N)) grid coord. Ghosts are visible
--               to local subscribers but never receive deltas (they "see" from
--               their own home zone). Symmetry therefore does NOT apply to ghosts,
--               so they live in a separate layer rather than in `grid`.

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
        subscribers = {},       -- pid -> { route, pos, gx, gy, border = {dirkey=dir} }
        pending     = {},       -- pid -> { event, ... }, cleared each flush
        ghosts      = {},       -- gid -> { gx, gy, x, y }  foreign entities (§8.4)
        border_out  = {},       -- egress events for neighbours, drained each frame
        npcs        = {},        -- npc_id -> { x, y, gx, gy, hp, max_hp } (§7.5)
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

-- The subscriber routes watching cell (gx, gy): the AOI audience a combat fx
-- must reach (design §7.4 "广播表现给同 grid 订阅者"). Each entry pairs the
-- pid with the cached home route so zone_host can deliver without a lookup.
local function watcher_routes(zone, gx, gy)
    local out = {}
    for pid in pairs(watchers(zone, gx, gy)) do
        local s = zone.subscribers[pid]
        if s then out[#out + 1] = { pid = pid, route = s.route } end
    end
    return out
end

local function push(zone, pid, ev)
    local q = zone.pending[pid]
    if not q then q = {}; zone.pending[pid] = q end
    q[#q + 1] = ev
end

-- ----- cross-zone border helpers (design §8.4) -----

-- A direction is one of the 8 lattice steps; key it 0..8 (4 = self, unused).
local function dirkey(dgx, dgy) return (dgx + 1) * 3 + (dgy + 1) end

-- Recompute which neighbour zones a subscriber on cell (sub.gx, sub.gy) is
-- visible into, and diff against its previous set to emit enter/move/leave
-- egress. `removed` forces the empty set (subscriber is leaving). Egress events
-- carry the entity's world pos; zone_host translates direction -> neighbour zone.
local function update_border(zone, pid, sub, removed)
    local maxg = zone_def.GRIDS_PER_ZONE - 1
    local newdirs = {}
    if not removed then
        local gx, gy = sub.gx, sub.gy
        local atL, atR = (gx <= 0), (gx >= maxg)
        local atD, atU = (gy <= 0), (gy >= maxg)
        for dgx = -1, 1 do
            for dgy = -1, 1 do
                if dgx ~= 0 or dgy ~= 0 then
                    local okx = (dgx == 0) or (dgx == -1 and atL) or (dgx == 1 and atR)
                    local oky = (dgy == 0) or (dgy == -1 and atD) or (dgy == 1 and atU)
                    if okx and oky then newdirs[dirkey(dgx, dgy)] = { dgx, dgy } end
                end
            end
        end
    end
    local old = sub.border
    for k, d in pairs(old) do
        if not newdirs[k] then
            zone.border_out[#zone.border_out + 1] =
                { ev = 'leave', dgx = d[1], dgy = d[2], id = pid }
        end
    end
    for k, d in pairs(newdirs) do
        zone.border_out[#zone.border_out + 1] = {
            ev = old[k] and 'move' or 'enter',
            dgx = d[1], dgy = d[2], id = pid, x = sub.pos.x, y = sub.pos.y,
        }
    end
    sub.border = newdirs
end

-- Ghosts (foreign entities) within the 3x3 block around (gx, gy). Returned as a
-- map gid -> ghost. Ghosts live outside `grid`, so the normal watchers() never
-- returns them; a moving local subscriber consults this to gain/lose ghosts.
local function ghosts_in_block(zone, gx, gy)
    local out = {}
    for gid, g in pairs(zone.ghosts) do
        if g.gx >= gx - 1 and g.gx <= gx + 1
        and g.gy >= gy - 1 and g.gy <= gy + 1 then
            out[gid] = g
        end
    end
    return out
end

-- ----- subscription lifecycle (design §7.2) -----

-- ENTER_ZONE: subscribe `pid` (with routing info `route`) at world `pos`.
-- Returns (snapshot, seq): the list of entities currently visible to pid, for a
-- ZONE_SNAPSHOT downstream. Existing watchers get an EV_ENTER for pid.
function M:enter(pid, route, pos)
    if self.subscribers[pid] then self:leave(pid) end   -- idempotent re-enter
    local gx, gy = zone_def.pos_to_grid(pos.x, pos.y)
    local sub = { route = route, pos = pos, gx = gx, gy = gy, border = {} }
    self.subscribers[pid] = sub
    self.seq = self.seq + 1

    local snapshot = {}
    for wpid in pairs(watchers(self, gx, gy)) do
        if wpid ~= pid then
            push(self, wpid, { t = M.EV_ENTER, id = pid, x = pos.x, y = pos.y })
            local s = self.subscribers[wpid]
            snapshot[#snapshot + 1] = { id = wpid, x = s.pos.x, y = s.pos.y }
        end
    end
    -- include any cross-border ghosts already visible from this cell.
    for gid, g in pairs(ghosts_in_block(self, gx, gy)) do
        snapshot[#snapshot + 1] = { id = gid, x = g.x, y = g.y }
    end
    grid_add(self, gx, gy, pid)
    update_border(self, pid, sub)               -- announce us to neighbours
    return snapshot, self.seq
end

-- LEAVE_ZONE: unsubscribe `pid`. Watchers get an EV_LEAVE.
function M:leave(pid)
    local sub = self.subscribers[pid]
    if not sub then return end
    update_border(self, pid, sub, true)         -- retract us from neighbours
    grid_del(self, sub.gx, sub.gy, pid)
    self.subscribers[pid] = nil
    self.pending[pid] = nil             -- nothing to deliver to a leaver
    self.seq = self.seq + 1
    for wpid in pairs(watchers(self, sub.gx, sub.gy)) do
        push(self, wpid, { t = M.EV_LEAVE, id = pid })
    end
end

-- v2 seam (design §19.1 hook 5): a subscriber's home flips on migration. The zone
-- only caches the route, so swapping that record in place is the ENTIRE change --
-- the next flush / fx fan-out routes to the new home with no other code touched.
-- That is precisely why a subscriber stores the full {home_game, home_lane, sid}
-- rather than a bare `true` (the §19.1 反例). v1 never migrates a player, so it
-- never calls this; the interface exists so v2's SUBSCRIBER_HOME_UPDATE handler is
-- a one-liner. Returns the new route, or nil if `pid` is not subscribed here.
function M:update_route(pid, new_route)
    local sub = self.subscribers[pid]
    if not sub then return nil end
    sub.route = new_route
    return sub.route
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
        update_border(self, pid, sub)           -- refresh our pos at neighbours
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

    -- the mover's own changing view of cross-border ghosts (one-directional:
    -- ghosts don't gain/lose us here -- their home zone handles their side).
    local old_g = ghosts_in_block(self, gx0, gy0)
    local new_g = ghosts_in_block(self, gx1, gy1)
    for gid, g in pairs(new_g) do
        if not old_g[gid] then
            push(self, pid, { t = M.EV_ENTER, id = gid, x = g.x, y = g.y })
        end
    end
    for gid in pairs(old_g) do
        if not new_g[gid] then push(self, pid, { t = M.EV_LEAVE, id = gid }) end
    end

    update_border(self, pid, sub)               -- our edge exposure may have changed
end

-- ----- ghost injection: the receiving side of a border subscription (§8.4) -----

-- A foreign entity `gid` from a neighbour zone is at world (x, y). Translate to
-- this zone's (out-of-range) local grid and push ENTER/MOVE/LEAVE to the local
-- subscribers who can see that cell. The ghost itself is never a subscriber, so
-- it receives nothing; its own visibility is maintained by its home zone.
function M:ghost_set(gid, x, y)
    local ogx, ogy = zone_def.zone_origin_grid(self.zone_id)
    local ggx, ggy = zone_def.world_to_global_grid(x, y)
    local gx, gy = ggx - ogx, ggy - ogy
    local g = self.ghosts[gid]
    self.seq = self.seq + 1
    if not g then
        self.ghosts[gid] = { gx = gx, gy = gy, x = x, y = y }
        for wpid in pairs(watchers(self, gx, gy)) do
            push(self, wpid, { t = M.EV_ENTER, id = gid, x = x, y = y })
        end
        return
    end
    if g.gx == gx and g.gy == gy then
        g.x, g.y = x, y
        for wpid in pairs(watchers(self, gx, gy)) do
            push(self, wpid, { t = M.EV_MOVE, id = gid, x = x, y = y })
        end
        return
    end
    local old_w = watchers(self, g.gx, g.gy)
    g.gx, g.gy, g.x, g.y = gx, gy, x, y
    local new_w = watchers(self, gx, gy)
    for wpid in pairs(new_w) do
        push(self, wpid, old_w[wpid]
            and { t = M.EV_MOVE,  id = gid, x = x, y = y }
            or  { t = M.EV_ENTER, id = gid, x = x, y = y })
    end
    for wpid in pairs(old_w) do
        if not new_w[wpid] then push(self, wpid, { t = M.EV_LEAVE, id = gid }) end
    end
end

-- A foreign entity left this zone's border view (neighbour retracted it).
function M:ghost_remove(gid)
    local g = self.ghosts[gid]
    if not g then return end
    self.ghosts[gid] = nil
    self.seq = self.seq + 1
    for wpid in pairs(watchers(self, g.gx, g.gy)) do
        push(self, wpid, { t = M.EV_LEAVE, id = gid })
    end
end

-- Hand the frame's buffered border egress to the caller (zone_host), which maps
-- each event's (dgx, dgy) to a neighbour zone and forwards it. Clears the buffer.
function M:drain_border()
    local out = self.border_out
    self.border_out = {}
    return out
end

-- ----- NPC combat: zone owner is authoritative (design §7.4.A, §7.5) -----
--
-- NPCs live on the zone owner lane (the opposite of players, who live on their
-- home lane), so the zone owner settles every player->NPC hit with no lock and
-- no cross-lane read: the attacker's position is already cached as a subscriber.

-- Place an NPC at world (x, y) with `hp` (default 100). Returns the entity.
function M:spawn_npc(npc_id, x, y, hp)
    local gx, gy = zone_def.pos_to_grid(x, y)
    local n = { x = x, y = y, gx = gx, gy = gy, hp = hp or 100, max_hp = hp or 100 }
    self.npcs[npc_id] = n
    return n
end

function M:npc(npc_id) return self.npcs[npc_id] end

-- Settle one attacker_pid -> npc_id hit with the (already looked-up) skill_def
-- { range, damage }. Validates the attacker is a local subscriber and within
-- range of the NPC, then applies damage. Returns:
--   result = { ok = true, npc_id, damage, npc_hp, dead, attacker_route }
--          | { ok = false, reason = 'no_attacker'|'no_npc'|'out_of_range' }
--   fx     = watcher_routes around the NPC (only when ok) -- the fx audience.
-- Authority note: only this lane ever writes npc.hp, so the read-modify-write is
-- race-free (design §9.2 "谁被改谁就是权威").
function M:attack_npc(attacker_pid, npc_id, skill_def)
    local atk = self.subscribers[attacker_pid]
    if not atk then return { ok = false, reason = 'no_attacker' } end
    local n = self.npcs[npc_id]
    if not n or n.hp <= 0 then return { ok = false, reason = 'no_npc' } end
    local dx, dy = atk.pos.x - n.x, atk.pos.y - n.y
    if dx * dx + dy * dy > skill_def.range * skill_def.range then
        return { ok = false, reason = 'out_of_range' }
    end
    local dmg = skill_def.damage
    n.hp = n.hp - dmg
    local dead = n.hp <= 0
    if dead then n.hp = 0 end
    local result = {
        ok = true, npc_id = npc_id, damage = dmg, npc_hp = n.hp, dead = dead,
        attacker_route = atk.route,
    }
    return result, watcher_routes(self, n.gx, n.gy)
end

-- The subscriber routes that should see a hit centred on `pid`'s cell -- used to
-- fan a player-vs-player HIT_BROADCAST out as fx (design §7.4.B). Empty if pid
-- is not (or no longer) a local subscriber.
function M:fx_watchers(pid)
    local s = self.subscribers[pid]
    if not s then return {} end
    return watcher_routes(self, s.gx, s.gy)
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
