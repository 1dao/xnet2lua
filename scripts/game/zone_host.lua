-- scripts/game/zone_host.lua -- per-lane AOI coordinator (design doc §7, §8).
--
-- One battle lane plays two roles simultaneously (design §7.1):
--   * home role:  owns the player entities whose home_lane == this lane.
--   * owner role: owns the zones whose (game, lane) == this lane.
-- Both live in the same Lua state, dispatched by message, so there are no locks.
--
-- This module is transport-agnostic. It never opens a socket and never calls
-- xthread directly; instead it is handed two callbacks:
--   post(game, lane, msg, ...)            -- deliver a message to host (game,lane)
--   to_client(sid, kind, zone_id, seq, p) -- final delivery to a home client
-- battle_worker.lua wires these to xthread.post / peer_conns / send_to_client;
-- the unit test wires them to an in-memory bus. (design §8.3, §19.1 hook 5)
--
-- Cross-lane / cross-game arguments ride xthread.post, which MessagePack-encodes
-- nested tables, so the event list passes through `post` as-is; only the
-- cross-game TCP edge in battle_worker adds an explicit frame.

local zone_def = dofile('scripts/game/zone_def.lua')
local Zone = dofile('scripts/game/zone.lua')

local M = {}
M.__index = M

-- Set the deployment topology (T lanes, M games) that drives zone->owner
-- hashing. Each thread dofile's its own module copy, so battle_worker must call
-- this once at startup rather than relying on the file defaults.
function M.configure(opts)
    if opts.lane_count then zone_def.LANE_COUNT = opts.lane_count end
    if opts.game_count then zone_def.GAME_COUNT = opts.game_count end
end

-- deps = { game, lane, post, to_client }
function M.new(deps)
    return setmetatable({
        game       = deps.game,
        lane       = deps.lane,
        post       = deps.post,
        to_client  = deps.to_client,
        zones      = {},     -- owner role: zone_id -> Zone (only zones we own)
        players    = {},     -- home role: pid -> { sid, pos, current_zone,
                             --                      last_seq = {[zone]=n}, route }
        sid_to_pid = {},     -- home role: sid -> pid
    }, M)
end

-- ----- owner role: lazily materialise a zone this lane owns -----

local function owned_zone(self, zone_id)
    local g, l = zone_def.resolve_zone_owner(zone_id)
    if g ~= self.game or l ~= self.lane then return nil end
    local z = self.zones[zone_id]
    if not z then z = Zone.new(zone_id); self.zones[zone_id] = z end
    return z
end

-- Route a message to whichever host owns `zone_id` (self when local).
function M:_to_owner(zone_id, msg, ...)
    local g, l = zone_def.resolve_zone_owner(zone_id)
    if g == self.game and l == self.lane then
        self:recv(msg, ...)
    else
        self.post(g, l, msg, ...)
    end
end

-- Deliver an AOI payload to a subscriber's home host (self when local).
-- kind is 'snapshot' (full visible set) or 'delta' (event list).
function M:_to_home(route, kind, zone_id, seq, payload)
    if route.home_game == self.game and route.home_lane == self.lane then
        self:_home_deliver(route.sid, kind, zone_id, seq, payload)
    else
        self.post(route.home_game, route.home_lane, 'aoi_in',
            route.sid, kind, zone_id, seq, payload)
    end
end

-- ----- home role: lifecycle (design §19.1 hook 3) -----

-- Bring a player online on this (its home) lane. runtime_hint is nil in v1 (cold
-- load from Redis); v2 migration passes the live runtime state through here.
function M:spawn_player(pid, sid, pos, _runtime_hint)
    local route = { home_game = self.game, home_lane = self.lane, sid = sid }
    self.players[pid] = {
        sid = sid, pos = pos, current_zone = nil, last_seq = {}, route = route,
    }
    self.sid_to_pid[sid] = pid
    self:_enter_zone(pid, zone_def.world_to_zone(pos.x, pos.y))
    return self.players[pid]
end

function M:despawn_player(pid, _reason)
    local p = self.players[pid]
    if not p then return end
    if p.current_zone then self:_to_owner(p.current_zone, 'leave_zone', p.current_zone, pid) end
    self.sid_to_pid[p.sid] = nil
    self.players[pid] = nil
end

function M:_enter_zone(pid, zone_id)
    local p = self.players[pid]
    p.current_zone = zone_id
    p.last_seq[zone_id] = 0
    self:_to_owner(zone_id, 'enter_zone', zone_id, pid, p.route, p.pos)
end

-- home role: a movement packet arrived from this player's client.
function M:client_move(pid, new_pos)
    local p = self.players[pid]
    if not p then return end
    p.pos = new_pos
    local nz = zone_def.world_to_zone(new_pos.x, new_pos.y)
    if nz ~= p.current_zone then
        local old = p.current_zone
        if old then self:_to_owner(old, 'leave_zone', old, pid) end
        self:_enter_zone(pid, nz)
    else
        self:_to_owner(nz, 'player_move', nz, pid, new_pos)
    end
end

-- home role: AOI/snapshot landed for one of our players. Applies the staleness
-- guard (design §7.3) then forwards to the client.
function M:_home_deliver(sid, kind, zone_id, seq, payload)
    local pid = self.sid_to_pid[sid]
    local p = pid and self.players[pid]
    if not p then return end
    if kind == 'snapshot' then
        p.last_seq[zone_id] = seq                       -- snapshot resets baseline
        self.to_client(sid, 'snapshot', zone_id, seq, payload)
        return
    end
    if zone_id ~= p.current_zone then return end         -- tail from an old zone
    if seq <= (p.last_seq[zone_id] or 0) then return end -- out-of-order / stale
    p.last_seq[zone_id] = seq
    self.to_client(sid, 'delta', zone_id, seq, payload)
end

-- ----- message dispatch (both roles) -----

function M:recv(msg, ...)
    if msg == 'enter_zone' then
        local zone_id, pid, route, pos = ...
        local z = owned_zone(self, zone_id)
        if not z then return end
        local snapshot, seq = z:enter(pid, route, pos)
        self:_to_home(route, 'snapshot', zone_id, seq, snapshot)
    elseif msg == 'leave_zone' then
        local zone_id, pid = ...
        local z = self.zones[zone_id]
        if z then z:leave(pid) end
    elseif msg == 'player_move' then
        local zone_id, pid, pos = ...
        local z = self.zones[zone_id]
        if z then z:move(pid, pos) end
    elseif msg == 'aoi_in' then
        self:_home_deliver(...)
    end
end

-- owner role: end-of-frame flush of every owned zone (design §9.3).
function M:tick()
    for _, z in pairs(self.zones) do
        z:flush(function(route, zone_id, seq, events)
            self:_to_home(route, 'delta', zone_id, seq, events)
        end)
    end
end

return M
