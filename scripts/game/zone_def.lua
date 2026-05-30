-- scripts/game/zone_def.lua -- pure grid/zone geometry + static topology.
--
-- No xnet APIs are touched here, so this module loads under a plain Lua VM and
-- is unit-testable in isolation. It is the SINGLE place where world->zone and
-- zone->owner hashing lives (design doc §19.1 hook 2): every caller asks these
-- functions instead of inlining `hash % T`, so v2 migration only edits here.

local M = {}

local floor = math.floor

-- Deployment constants (design §0). v1 keeps a single game process.
M.GAME_COUNT = 1       -- M: number of game processes
M.LANE_COUNT = 6       -- T: lanes per game (matches GAME_BATTLE_WORKERS default)

-- World is a fixed lattice of square zones; each zone is an independent actor
-- (design §3). Inside a zone sits the AOI grid lattice (design §8.1).
M.GRID_SIZE = 32       -- AOI grid edge, world units. R = G/2 (design §8.1)
M.ZONE_SIZE = 1024     -- zone edge, world units => 32x32 grids per zone
M.WORLD_COLS = 16      -- zones per row; world is WORLD_COLS*ZONE_SIZE wide
M.WORLD_ROWS = 16      -- zones per column; bounds the zone lattice vertically

-- AOI grids per zone edge. A zone's local grid coords run 0 .. GRIDS_PER_ZONE-1;
-- the edge cells (0 and GRIDS_PER_ZONE-1) are the ones whose 3x3 view spills into
-- the neighbouring zone and so drive border subscription (design §8.4).
M.GRIDS_PER_ZONE = floor(M.ZONE_SIZE / M.GRID_SIZE)

-- World coord -> AOI grid coord (gx, gy), local to whatever zone the point is
-- in. Grid coords are zone-relative; full positioning still needs the zone_id.
function M.pos_to_grid(x, y)
    local zs = M.ZONE_SIZE
    local lx = x - floor(x / zs) * zs    -- offset within the zone
    local ly = y - floor(y / zs) * zs
    return floor(lx / M.GRID_SIZE), floor(ly / M.GRID_SIZE)
end

-- World coord -> zone_id (1-based, row-major over the zone lattice).
function M.world_to_zone(x, y)
    local zx = floor(x / M.ZONE_SIZE)
    local zy = floor(y / M.ZONE_SIZE)
    return zy * M.WORLD_COLS + zx + 1
end

-- 3x3 grid block around (gx, gy), inclusive. Flat list of {gx, gy} pairs.
-- With R = G/2 a player's view is bounded by its own cell plus neighbours.
function M.neighbors9(gx, gy)
    local out = {}
    for dx = -1, 1 do
        for dy = -1, 1 do
            out[#out + 1] = { gx + dx, gy + dy }
        end
    end
    return out
end

-- ----- zone lattice topology (design §8.4 border subscription) -----

-- zone_id (1-based) -> lattice coords (zx, zy), row-major. Inverse of
-- world_to_zone's zone numbering.
function M.zone_coord(zone_id)
    local idx = zone_id - 1
    return idx % M.WORLD_COLS, floor(idx / M.WORLD_COLS)
end

-- lattice coords (zx, zy) -> zone_id, or nil when outside the world rectangle.
function M.zone_at(zx, zy)
    if zx < 0 or zx >= M.WORLD_COLS or zy < 0 or zy >= M.WORLD_ROWS then
        return nil
    end
    return zy * M.WORLD_COLS + zx + 1
end

-- The zone's (0,0) corner expressed in GLOBAL grid units. Adding a zone-local
-- grid coord to this yields a world-unique grid coord; subtracting it back out
-- is how a neighbour translates a foreign entity into its own (possibly
-- out-of-[0,GRIDS_PER_ZONE) ) local grid for ghost placement.
function M.zone_origin_grid(zone_id)
    local zx, zy = M.zone_coord(zone_id)
    return zx * M.GRIDS_PER_ZONE, zy * M.GRIDS_PER_ZONE
end

-- World coord -> GLOBAL grid coord (NOT wrapped per zone, unlike pos_to_grid).
function M.world_to_global_grid(x, y)
    return floor(x / M.GRID_SIZE), floor(y / M.GRID_SIZE)
end

-- The neighbour zone one lattice step in direction (dzx, dzy) from zone_id, or
-- nil at a world edge. Used to resolve a border egress direction to a zone_id.
function M.neighbor_zone(zone_id, dzx, dzy)
    local zx, zy = M.zone_coord(zone_id)
    return M.zone_at(zx + dzx, zy + dzy)
end

-- zone_id -> owning (game_idx, lane_idx). v1: pure hash; static overrides win
-- for hot zones (design §7.7). This is the only hashing site for zone owners.
--
-- Failover (design §3 / §17.3): a zone may carry a standby (game, lane). When the
-- controller declares the zone's primary game down (M.mark_game_down), the owner
-- resolves to that standby until the game is restored. Because this stays the one
-- ownership site, every caller -- combat settlement, AOI broadcast, border
-- subscription -- follows the flip without a change of its own.
M.zone_owner_override = {}        -- [zone_id] = { game_idx, lane_idx } (primary)
M.zone_standby = {}               -- [zone_id] = { game_idx, lane_idx } (failover)
M.game_down = {}                  -- [game_idx] = true while controller-declared down

local function primary_zone_owner(zone_id)
    local o = M.zone_owner_override[zone_id]
    if o then return o[1], o[2] end
    local lane = (zone_id - 1) % M.LANE_COUNT + 1
    local game = (zone_id - 1) % M.GAME_COUNT + 1
    return game, lane
end

function M.resolve_zone_owner(zone_id)
    local game, lane = primary_zone_owner(zone_id)
    if M.game_down[game] then
        local sb = M.zone_standby[zone_id]
        if sb then return sb[1], sb[2] end
    end
    return game, lane
end

-- Controller hooks (design §17.3). Idempotent: flip every zone whose primary
-- lives on `game` to its standby owner, or restore the primary once healthy.
function M.mark_game_down(game)
    M.game_down[game] = true
end

function M.mark_game_up(game)
    M.game_down[game] = nil
end

-- player_id -> owning (home_game, home_lane). Affinity is LIFETIME-FIXED (design
-- §0 item 5): a player's hp/buff/cooldown live forever on this lane, and combat
-- routes ATTACK_PLAYER to it by re-deriving it from the target id alone -- the
-- attacker never carries the target's route, only its id (design §9.1). This is
-- the single hashing site for player affinity, mirroring resolve_zone_owner.
--
-- A multiplicative hash (NOT raw `pid % T`) so contiguous id ranges spread
-- across lanes instead of skewing onto a few (design §0 item 3). HASH_MUL is
-- kept < 2^22 so `pid * HASH_MUL` stays exact in a Lua double for pid < 2^31.
M.player_home_override = {}        -- [pid] = { game_idx, lane_idx }
local HASH_MUL = 2654435           -- Knuth-ish constant, trimmed to stay exact
local function pid_hash(pid)
    local n = pid % 2147483648
    return (n * HASH_MUL + 1013904223) % 4294967296
end

function M.resolve_player_home(pid)
    local o = M.player_home_override[pid]
    if o then return o[1], o[2] end
    local h = pid_hash(pid)
    local game = h % M.GAME_COUNT + 1
    local lane = floor(h / M.GAME_COUNT) % M.LANE_COUNT + 1
    return game, lane
end

-- Mint a NEW character's permanent home at creation (design §4.0). Returns
-- (home_game, home_lane); the caller persists them (DB / player_home_override)
-- and they never change for that character's lifetime.
--
--   * home_lane is ALWAYS the structural hash: T is a lifetime-fixed deployment
--     constant (design §0 / §19), so the lane is not a choice.
--   * home_game PREFERS the load picker (design §17.8: pick_least_loaded steers
--     new characters onto the freest Game) and only falls back to the hash when
--     no load intel is available (design §2: "DB 字段为主,缺字段时退化到 hash").
--
-- `pick_game` is an optional `function() -> game_id|nil` (e.g.
-- gameload:picker(now)); with no picker, or when it returns nil, this is exactly
-- resolve_player_home(pid) -- the pure-hash deployment.
function M.assign_home(pid, pick_game)
    local h = pid_hash(pid)
    local home_lane = floor(h / M.GAME_COUNT) % M.LANE_COUNT + 1
    local home_game = pick_game and pick_game() or nil
    if not home_game then home_game = h % M.GAME_COUNT + 1 end
    return home_game, home_lane
end

return M
