-- scripts/game/player_route.lua -- the single "where is player P?" site (§19.1).
--
-- Pure logic, no transport. Design §19.1 hook (2): every "which Game/lane is this
-- player on?" question goes through resolve() -- nobody inlines `hash % M` (the
-- §19.1 反例 / §19.3 items 2-4 "挖坑"). Keeping it one function is what makes the
-- v2 migration mechanical: the body changes from "DB/Redis lookup" to "directory
-- service" and not one caller moves.
--
--   * §2 "DB 字段为主,缺字段时退化到 hash": a known route -- written at character
--     creation / login admission from DB/Redis -- wins; with no record we fall
--     back to the structural hash (zone_def.resolve_player_home), so a brand-new
--     or cold-cache player still routes correctly.
--   * The v2 seam (§19.2 / §19.3 item 8): home_game can be UPDATED (the HOME_UPDATE
--     a migration sends) and a cached route INVALIDATED. v1 never migrates a
--     player, so it never calls these in anger -- but the interface has to exist,
--     so v2's handler is a one-liner against this same record. home_lane never
--     moves: T is a lifetime-fixed deployment constant (§0 / §19).

local zone_def = dofile('scripts/game/zone_def.lua')

local M = {}
M.__index = M

function M.new(opts)
    opts = opts or {}
    local self = setmetatable({}, M)
    self.routes = {}     -- [pid] = { home_game, home_lane, sid_hint, src }
    -- fallback(pid) -> home_game, home_lane. Defaults to the structural hash.
    self.fallback = opts.fallback or zone_def.resolve_player_home
    return self
end

-- Record a player's DB-sourced route (character creation / login admission).
-- home_lane is structural and lifetime-fixed; home_game may later be updated.
function M:learn(pid, home_game, home_lane, sid_hint)
    local r = {
        home_game = home_game,
        home_lane = home_lane,
        sid_hint = sid_hint,
        src = 'db',
    }
    self.routes[pid] = r
    return r
end

-- "Where is player P?" -> home_game, home_lane, sid_hint, src.
-- A known route wins (src='db'/'update'); otherwise the structural hash
-- (src='hash', sid_hint nil).
function M:resolve(pid)
    local r = self.routes[pid]
    if r then return r.home_game, r.home_lane, r.sid_hint, r.src end
    local g, l = self.fallback(pid)
    return g, l, nil, 'hash'
end

-- v2 seam (§19.2 HOME_UPDATE): a player's home_game flips on migration; home_lane
-- stays put. For an unknown pid we materialise the record against the structural
-- lane, so the route is self-consistent afterwards. Returns the updated record.
function M:update_home(pid, new_home_game)
    local r = self.routes[pid]
    if r then
        r.home_game = new_home_game
        r.src = 'update'
    else
        local _, l = self.fallback(pid)
        r = { home_game = new_home_game, home_lane = l, src = 'update' }
        self.routes[pid] = r
    end
    return r
end

-- v2 seam (§19.3 item 8): drop a cached route so the next resolve re-reads it
-- (from the directory service, in v2). v1 caches forever and never calls this,
-- but the interface must exist. Returns true if a record was actually dropped.
function M:invalidate(pid)
    if self.routes[pid] == nil then return false end
    self.routes[pid] = nil
    return true
end

function M:known(pid)
    return self.routes[pid] ~= nil
end

return M
