-- scripts/game/gameload.lua -- the character-creation load registry (design
-- §17.8 / §13.2 / §4.0).
--
-- Pure logic, no transport. A Game work worker publishes `game.load` over NATS
-- once a minute; whichever process mints new characters (account service / a work
-- worker / the controller) subscribes and feeds each report into report(). At
-- creation time pick_least_loaded() answers "which Game should this new
-- character's home_game be?" entirely in-memory -- no RPC on the hot creation
-- path (design §17.8).
--
-- Staleness matters: a Game that stopped reporting (crashed, partitioned) must
-- NOT keep attracting new characters, so every read honours a TTL and an entry
-- older than the TTL is treated as gone.

local M = {}
M.__index = M

-- Three reporting periods of slack (work worker reports ~every minute, §17.8):
-- one missed beat is normal jitter, three means the Game is really gone.
local DEFAULT_TTL_MS = 180000

function M.new(opts)
    opts = opts or {}
    local self = setmetatable({}, M)
    self.ttl_ms = opts.ttl_ms or DEFAULT_TTL_MS
    self.games = {}   -- [game_id] = { load=, updated=, ...extra }
    return self
end

local function live(self, g, now_ms)
    return g ~= nil and (now_ms or 0) - g.updated <= self.ttl_ms
end

-- Fold one `game.load` report in. `load` is a single comparable scalar where
-- lower means freer (e.g. active player count, or a weighted score); any `extra`
-- fields (players, cpu_ms, frame_p95...) ride along for monitoring/visibility.
function M:report(game_id, load, now_ms, extra)
    local g = self.games[game_id]
    if not g then
        g = {}
        self.games[game_id] = g
    end
    g.load = load
    g.updated = now_ms or 0
    if extra then
        for k, v in pairs(extra) do
            if k ~= 'load' and k ~= 'updated' then g[k] = v end
        end
    end
    return g
end

function M:is_live(game_id, now_ms)
    return live(self, self.games[game_id], now_ms)
end

-- Drop entries that have aged past the TTL. Optional housekeeping -- reads are
-- already TTL-aware, but reaping keeps the table from growing after a Game is
-- permanently retired.
function M:reap(now_ms)
    local removed = 0
    for id, g in pairs(self.games) do
        if not live(self, g, now_ms) then
            self.games[id] = nil
            removed = removed + 1
        end
    end
    return removed
end

-- §17.8 / §13.2: the least-loaded LIVE Game, for a new character's home_game.
-- Ties break on the lowest game_id so independent creators agree deterministically
-- and don't all stampede onto the same Game. Returns game_id, load -- or nil when
-- no Game is currently reporting (caller falls back to the hash, §4.0).
function M:pick_least_loaded(now_ms)
    local best_id, best_load
    for id, g in pairs(self.games) do
        if live(self, g, now_ms) then
            if best_load == nil
                or g.load < best_load
                or (g.load == best_load and id < best_id) then
                best_id, best_load = id, g.load
            end
        end
    end
    return best_id, best_load
end

-- A picker callback bound to `now_ms`, suitable to hand straight to
-- zone_def.assign_home(pid, picker) at character creation.
function M:picker(now_ms)
    local self_ref = self
    return function()
        return self_ref:pick_least_loaded(now_ms)
    end
end

-- Read-only view for monitoring (design §16): { [game_id] = {load, live} }.
function M:snapshot(now_ms)
    local out = {}
    for id, g in pairs(self.games) do
        out[id] = { load = g.load, live = live(self, g, now_ms) }
    end
    return out
end

return M
