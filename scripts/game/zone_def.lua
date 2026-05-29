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

-- zone_id -> owning (game_idx, lane_idx). v1: pure hash; static overrides win
-- for hot zones (design §7.7). This is the only hashing site for zone owners.
M.zone_owner_override = {}        -- [zone_id] = { game_idx, lane_idx }

function M.resolve_zone_owner(zone_id)
    local o = M.zone_owner_override[zone_id]
    if o then return o[1], o[2] end
    local lane = (zone_id - 1) % M.LANE_COUNT + 1
    local game = (zone_id - 1) % M.GAME_COUNT + 1
    return game, lane
end

return M
