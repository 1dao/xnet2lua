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
local combat = dofile('scripts/game/combat.lua')

local DEFAULT_HP = 100

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

-- Deliver a message to an explicit home route (self when local). Used by the
-- combat settler, which already holds the recipient's cached route (the zone
-- owner has the attacker's subscription route; §7.4).
function M:_to_route(route, msg, ...)
    if route.home_game == self.game and route.home_lane == self.lane then
        self:recv(msg, ...)
    else
        self.post(route.home_game, route.home_lane, msg, ...)
    end
end

-- Deliver a message to a player's home lane, resolved from the id ALONE via the
-- lifetime-fixed affinity hash (design §9.1): an attacker routes ATTACK_PLAYER
-- to its target without ever holding the target's route.
function M:_to_player_home(pid, msg, ...)
    local g, l = zone_def.resolve_player_home(pid)
    if g == self.game and l == self.lane then
        self:recv(msg, ...)
    else
        self.post(g, l, msg, ...)
    end
end

-- ----- home role: lifecycle (design §19.1 hook 3) -----

-- Bring a player online on this (its home) lane. runtime_hint is nil in v1 (cold
-- load from Redis); v2 migration passes the live runtime state through here.
function M:spawn_player(pid, sid, pos, runtime_hint)
    local route = { home_game = self.game, home_lane = self.lane, sid = sid }
    self.players[pid] = {
        sid = sid, pos = pos, current_zone = nil, last_seq = {}, route = route,
        -- combat state lives ONLY here, on the home lane (design §9.1): hp is
        -- authoritative, `known` caches other entities' last-seen world pos from
        -- AOI so this lane can range-check an inbound ATTACK_PLAYER locally.
        hp = (runtime_hint and runtime_hint.hp) or DEFAULT_HP,
        max_hp = (runtime_hint and runtime_hint.max_hp) or DEFAULT_HP,
        known = {},
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

-- home role: this player's client fired a skill at an NPC. The NPC is owned by
-- the zone owner (design §7.4.A), so forward the intent there to be settled.
function M:client_attack_npc(pid, npc_id, skill_id)
    local p = self.players[pid]
    if not p or not p.current_zone then return end
    self:_to_owner(p.current_zone, 'attack_npc', p.current_zone, npc_id, pid, skill_id)
end

-- home role: this player's client fired a skill at another player. The TARGET's
-- home lane is authoritative for its hp (design §9.1), so route the intent there
-- by the target id alone -- we never need to know where the target physically is.
function M:client_attack_player(pid, target_pid, skill_id)
    if not self.players[pid] then return end
    self:_to_player_home(target_pid, 'attack_player', target_pid, pid, skill_id)
end

-- owner role: place an NPC into a zone this lane owns (design §7.5). NPC AI/spawn
-- all live here; v1 exposes just the placement so combat has a target.
function M:spawn_npc(zone_id, npc_id, x, y, hp)
    local z = owned_zone(self, zone_id)
    if not z then return nil end
    return z:spawn_npc(npc_id, x, y, hp)
end

-- owner role: a subscriber's home flipped on migration (design §19.1 hook 5). The
-- zone caches only the route, so swapping that record is the ENTIRE change -- the
-- next flush / fx fan-out routes to the new home untouched. v1 never migrates a
-- player, so this is never called; the seam exists so v2's SUBSCRIBER_HOME_UPDATE
-- handler is a one-liner. Returns the new route, or nil if we don't own the zone /
-- pid isn't subscribed.
function M:update_subscriber_home(zone_id, pid, new_route)
    local z = owned_zone(self, zone_id)
    if not z then return nil end
    return z:update_route(pid, new_route)
end

-- home role: AOI/snapshot landed for one of our players. Applies the staleness
-- guard (design §7.3) then forwards to the client.
function M:_home_deliver(sid, kind, zone_id, seq, payload)
    local pid = self.sid_to_pid[sid]
    local p = pid and self.players[pid]
    if not p then return end
    if kind == 'snapshot' then
        p.last_seq[zone_id] = seq                       -- snapshot resets baseline
        for _, e in ipairs(payload) do                  -- seed last-known positions
            p.known[e.id] = { x = e.x, y = e.y }
        end
        self.to_client(sid, 'snapshot', zone_id, seq, payload)
        return
    end
    if zone_id ~= p.current_zone then return end         -- tail from an old zone
    if seq <= (p.last_seq[zone_id] or 0) then return end -- out-of-order / stale
    p.last_seq[zone_id] = seq
    -- maintain the last-known-pos cache the combat range check reads (§9.1):
    -- ENTER/MOVE refresh the foreign entity's pos, LEAVE forgets it.
    for _, e in ipairs(payload) do
        if e.t == Zone.EV_LEAVE then
            p.known[e.id] = nil
        elseif e.x then
            p.known[e.id] = { x = e.x, y = e.y }
        end
    end
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
    elseif msg == 'border_ghost' then
        -- owner role: a neighbour zone announced one of its edge entities. Inject
        -- (or retract) it as a ghost in the target zone we own (design §8.4).
        local zone_id, _src_zone, ev, id, x, y = ...
        local z = owned_zone(self, zone_id)
        if not z then return end
        if ev == 'leave' then z:ghost_remove(id) else z:ghost_set(id, x, y) end
    elseif msg == 'attack_npc' then
        self:_settle_attack_npc(...)
    elseif msg == 'attack_player' then
        self:_settle_attack_player(...)
    elseif msg == 'damage_dealt' then
        -- home role: the settler reported a hit our player landed -> floating number.
        local pid, target_id, dmg, target_hp, dead = ...
        local p = self.players[pid]
        if not p then return end
        self.to_client(p.sid, 'combat', p.current_zone or 0, 0,
            { kind = 'damage', target = target_id, damage = dmg,
              target_hp = target_hp, dead = dead })
    elseif msg == 'hit_broadcast' then
        self:_broadcast_hit(...)
    elseif msg == 'combat_fx' then
        -- home role: zone owner asked us to show a hit to one of our subscribers.
        local sid, zone_id, attacker_id, target_id, skill_id, dmg = ...
        local pid = self.sid_to_pid[sid]
        local p = pid and self.players[pid]
        if not p then return end
        self.to_client(p.sid, 'combat', zone_id, 0,
            { kind = 'fx', attacker = attacker_id, target = target_id,
              skill = skill_id, damage = dmg })
    end
end

-- owner role: settle a player->NPC hit (design §7.4.A). The zone is authoritative
-- for the NPC; on success we send DAMAGE_DEALT back to the attacker's home (for
-- the damage number / exp) and fan COMBAT_FX out to every same-grid subscriber.
function M:_settle_attack_npc(zone_id, npc_id, attacker_pid, skill_id)
    local z = self.zones[zone_id]
    if not z then return end
    local skill = combat.skill(skill_id)
    if not skill then return end
    local result, fx = z:attack_npc(attacker_pid, npc_id, skill)
    if not result.ok then return end
    self:_to_route(result.attacker_route, 'damage_dealt',
        attacker_pid, npc_id, result.damage, result.npc_hp, result.dead)
    for i = 1, #fx do
        local w = fx[i]
        self:_to_route(w.route, 'combat_fx',
            w.route.sid, zone_id, attacker_pid, npc_id, skill_id, result.damage)
    end
end

-- home role (target side): settle an inbound player->player hit (design §9.1).
-- This lane owns the target's hp, so it validates locally (target online, the
-- attacker was actually seen, in range) then applies damage. Results fan out to
-- the target's own client (authoritative hp), the attacker's home (the number),
-- and the zone owner (so it can broadcast the fx to nearby players).
function M:_settle_attack_player(target_pid, attacker_pid, skill_id)
    local tp = self.players[target_pid]
    if not tp then return end                       -- target not home here / offline
    local skill = combat.skill(skill_id)
    if not skill then return end
    local apos = tp.known[attacker_pid]
    if not apos then return end                     -- never saw the attacker -> reject
    if not combat.in_range(skill, tp.pos.x, tp.pos.y, apos.x, apos.y) then return end

    local dmg = combat.roll_damage(skill, nil, tp)
    tp.hp = (tp.hp or DEFAULT_HP) - dmg
    local dead = tp.hp <= 0
    if dead then tp.hp = 0 end

    -- authoritative hp update to the target's own client.
    self.to_client(tp.sid, 'combat', tp.current_zone or 0, 0,
        { kind = 'hp', target = target_pid, hp = tp.hp, damage = dmg, dead = dead })
    -- the damage number back to the attacker (resolve its home by id).
    self:_to_player_home(attacker_pid, 'damage_dealt',
        attacker_pid, target_pid, dmg, tp.hp, dead)
    -- let the zone owner paint the hit for everyone watching the target's cell.
    if tp.current_zone then
        self:_to_owner(tp.current_zone, 'hit_broadcast',
            tp.current_zone, attacker_pid, target_pid, skill_id)
    end
end

-- owner role: a target's home asked us to show a player-vs-player hit to nearby
-- subscribers (design §7.4.B). Fan COMBAT_FX to every watcher of the target cell.
function M:_broadcast_hit(zone_id, attacker_pid, target_pid, skill_id)
    local z = self.zones[zone_id]
    if not z then return end
    local fx = z:fx_watchers(target_pid)
    for i = 1, #fx do
        local w = fx[i]
        self:_to_route(w.route, 'combat_fx',
            w.route.sid, zone_id, attacker_pid, target_pid, skill_id, 0)
    end
end

-- owner role: route one border egress event to the neighbour zone that lies in
-- its lattice direction. The neighbour's owner injects the ghost (§8.4).
function M:_route_border(src_zone, e)
    local nz = zone_def.neighbor_zone(src_zone, e.dgx, e.dgy)
    if not nz then return end           -- world edge: no zone in that direction
    self:_to_owner(nz, 'border_ghost', nz, src_zone, e.ev, e.id, e.x, e.y)
end

-- owner role: end-of-frame flush of every owned zone (design §9.3). After
-- draining subscriber deltas, forward this frame's border egress so neighbour
-- zones can refresh their ghost view of our edge entities.
function M:tick()
    for zone_id, z in pairs(self.zones) do
        z:flush(function(route, zid, seq, events)
            self:_to_home(route, 'delta', zid, seq, events)
        end)
        local egress = z:drain_border()
        for i = 1, #egress do
            self:_route_border(zone_id, egress[i])
        end
    end
end

return M
