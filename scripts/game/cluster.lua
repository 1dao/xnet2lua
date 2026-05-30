-- scripts/game/cluster.lua -- the gate-side game_id -> endpoint routing table
-- with a primary/standby health state machine (design §17.3 / §12.1).
--
-- Pure logic, no sockets: a gate drives it with on_disconnect / on_reconnect as
-- the per-game battle link opens and closes, and ticks it on a timer. resolve()
-- answers "which host:port do I dial / forward to for this game_id, and is the
-- lane frozen right now?".
--
-- The whole point of the standby model (design §17.3): failover keeps the LOGICAL
-- game_id fixed, so every player's home_lane and sid are untouched -- only the
-- PHYSICAL endpoint flips. The client sees a few-second reconnect hiccup, nothing
-- more. This module is the one place that decides which physical endpoint a
-- logical game_id currently points at.

local M = {}
M.__index = M

-- Per-game health states:
--   'up'      primary reachable; route to primary.
--   'grace'   primary link just dropped; upstream is FROZEN (the gate returns
--             OP_SERVER_BUSY for sids homed here) while we wait out the grace
--             window for the primary to come back (design §12.1).
--   'standby' grace expired, or the controller forced failover, with a standby
--             configured; route to the standby endpoint. home_lane / sid keep.
--   'down'    grace expired with NO standby; the gate drops these clients so they
--             reconnect elsewhere and pull from Redis (design §12.1).
M.UP = 'up'
M.GRACE = 'grace'
M.STANDBY = 'standby'
M.DOWN = 'down'

local DEFAULT_GRACE_MS = 30000   -- §12.1: 30s before giving up on the primary

function M.new(opts)
    opts = opts or {}
    local self = setmetatable({}, M)
    self.grace_ms = opts.grace_ms or DEFAULT_GRACE_MS
    self.games = {}   -- [game_id] = { primary=, standby=, state=, grace_until= }
    return self
end

-- Static config load (design §3 endpoint table).
--   endpoints[game_id] = { primary = {host=,port=}, standby = {host=,port=}? }
function M:configure(endpoints)
    for game_id, ep in pairs(endpoints or {}) do
        self:set_game(game_id, ep.primary, ep.standby)
    end
    return self
end

function M:set_game(game_id, primary, standby)
    self.games[game_id] = {
        primary = primary,
        standby = standby,
        state = M.UP,
        grace_until = nil,
    }
    return self
end

-- battle link for game_id closed (design §12.1): open the grace window and freeze
-- upstream. now_ms is the caller's monotonic clock. A drop that lands while we are
-- already on the standby is ignored -- the standby is what's serving now.
function M:on_disconnect(game_id, now_ms)
    local g = self.games[game_id]
    if not g then return nil end
    if g.state == M.UP then
        g.state = M.GRACE
        g.grace_until = (now_ms or 0) + self.grace_ms
    end
    return g.state
end

-- Primary re-established admission inside the grace window: recover cleanly.
function M:on_reconnect(game_id)
    local g = self.games[game_id]
    if not g then return nil end
    if g.state == M.GRACE then
        g.state = M.UP
        g.grace_until = nil
    end
    return g.state
end

local function tick_one(self, game_id, now_ms)
    local g = self.games[game_id]
    if not g or g.state ~= M.GRACE then return nil end
    if (now_ms or 0) < (g.grace_until or 0) then return nil end
    g.state = g.standby and M.STANDBY or M.DOWN
    g.grace_until = nil
    return g.state
end

-- Timer tick. With a game_id, promotes just that game's expired grace; without
-- one, sweeps every game. Returns the new state (single) / a {game_id=state} map
-- of the games that changed (sweep), or nil when nothing changed.
function M:tick(now_ms, game_id)
    if game_id ~= nil then return tick_one(self, game_id, now_ms) end
    local changed
    for id in pairs(self.games) do
        local s = tick_one(self, id, now_ms)
        if s then
            changed = changed or {}
            changed[id] = s
        end
    end
    return changed
end

-- Controller-driven immediate failover (design §17.3), skipping the grace wait.
-- No-op (returns false) when no standby is configured.
function M:failover(game_id)
    local g = self.games[game_id]
    if not g or not g.standby then return false end
    g.state = M.STANDBY
    g.grace_until = nil
    return true
end

-- Controller restore once the primary is healthy again.
function M:restore(game_id)
    local g = self.games[game_id]
    if not g then return false end
    g.state = M.UP
    g.grace_until = nil
    return true
end

-- "Which endpoint, and is the lane frozen?" Returns endpoint, state, frozen.
-- endpoint is nil while frozen (grace) or down.
function M:resolve(game_id)
    local g = self.games[game_id]
    if not g then return nil, nil, false end
    if g.state == M.UP then return g.primary, M.UP, false end
    if g.state == M.STANDBY then return g.standby, M.STANDBY, false end
    if g.state == M.GRACE then return nil, M.GRACE, true end
    return nil, M.DOWN, false
end

function M:state(game_id)
    local g = self.games[game_id]
    return g and g.state or nil
end

-- §12.1 freeze flag: the gate returns OP_SERVER_BUSY for sids whose home game is
-- frozen (mid-grace), holding the client until the primary recovers or we flip.
function M:is_frozen(game_id)
    local g = self.games[game_id]
    return g ~= nil and g.state == M.GRACE
end

return M
