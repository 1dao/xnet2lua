-- scripts/gate/sid.lua -- the ONE place the SID bit layout is defined (design
-- §19.1 hook 7 / §19.3 偷懒 #2). The gate worker mints SIDs; nothing else may
-- reinvent the formula, so the magic constant lives here and only here.
--
-- v1 layout (unchanged from the original inline gate formula):
--
--     sid = (lane - 1) * 2^24 + local_seq        -- lane in the high 8 bits
--
-- INVARIANT (the whole point of hook 7): a SID encodes ONLY lifetime-permanent
-- facts. `lane` is safe because home_lane is fixed at 建号 and 永不变 (design §2).
-- It is DELIBERATELY impossible to put home_game (or any field that v2 migration
-- could change) into a SID through this module: there is no such parameter and no
-- decode that returns one. The instant a SID's meaning depended on "current Game",
-- migrating a player would make every previously-issued SID self-contradictory.
-- If a future build must pack more into a SID, it may pack ONLY permanent fields
-- (e.g. low bits of player_id, which is also 永久不变).

local M = {}

local floor = math.floor

M.LANE_STRIDE = 16777216           -- 2^24: size of each lane's local-seq space
M.SEQ_MIN = 1
M.SEQ_MAX = M.LANE_STRIDE - 1      -- 16777215 distinct ids per lane

-- Encode a permanent (lane, local_seq) into a SID. Returns nil when lane < 1 or the
-- per-lane sequence is out of [SEQ_MIN, SEQ_MAX]; the caller reads nil as "id space
-- exhausted on this lane" and refuses the session (matching the old gate behaviour).
function M.encode(lane, seq)
    if type(lane) ~= 'number' or type(seq) ~= 'number' then return nil end
    if lane < 1 then return nil end
    if seq < M.SEQ_MIN or seq > M.SEQ_MAX then return nil end
    return (lane - 1) * M.LANE_STRIDE + seq
end

-- Recover the (permanent) lane a SID was minted on. lane is the only routing fact a
-- SID carries, and it is valid for the player's whole life precisely because it is
-- permanent -- there is no home_game to recover, by design.
function M.lane_of(sid)
    if type(sid) ~= 'number' then return nil end
    return floor(sid / M.LANE_STRIDE) + 1
end

-- Recover the per-lane local sequence.
function M.seq_of(sid)
    if type(sid) ~= 'number' then return nil end
    return sid % M.LANE_STRIDE
end

return M
