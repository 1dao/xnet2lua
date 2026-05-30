-- scripts/game/chat.lua -- a gate lane's chat fanout registry (design §11).
--
-- Pure logic, no transport. One instance per gate worker (one lane). It answers
-- two questions for the lane's chat paths:
--
--   1. Broadcast fanout. World chat and system announce go to EVERY session the
--      lane holds (deliver_all). Guild and area chat are filtered: the lane keeps
--      guild_sids_by_lane[guildId] / zone_sids[zoneId] so a NATS broadcast only
--      touches the sessions that actually belong to that channel -- a lane with
--      no members of a guild skips the broadcast entirely ("不是所有 lane 都遍历",
--      design §11).
--   2. Private-chat routing. A target's home (home_game, home_lane) is fixed for
--      the character's lifetime, so resolve it once -- here via the affinity hash;
--      a real deployment hits DB/Redis -- and cache it (design §11). Private chat
--      then rides the TCP mesh straight to that home, never NATS.

local zone_def = dofile('scripts/game/zone_def.lua')

local M = {}
M.__index = M

function M.new()
    local self = setmetatable({}, M)
    self.sessions = {}      -- [sid] = true            (sessions this lane holds)
    self.channels = {}      -- [channel] = { [sid] = true }   (guild/area members)
    self.sub_of = {}        -- [sid] = { [channel] = true }   (reverse, for cleanup)
    self.home_cache = {}    -- [pid] = { home_game, home_lane }
    return self
end

-- Channel-id helpers so every caller formats the same key/topic consistently.
function M.guild_channel(guild_id) return 'guild:' .. tostring(guild_id) end
function M.area_channel(zone_id)   return 'area:' .. tostring(zone_id) end

function M:add_session(sid)
    self.sessions[sid] = true
end

-- On disconnect: drop the session and all its channel memberships.
function M:remove_session(sid)
    self.sessions[sid] = nil
    self:leave_all(sid)
end

function M:join(channel, sid)
    local c = self.channels[channel]
    if not c then c = {}; self.channels[channel] = c end
    c[sid] = true
    local s = self.sub_of[sid]
    if not s then s = {}; self.sub_of[sid] = s end
    s[channel] = true
end

function M:leave(channel, sid)
    local c = self.channels[channel]
    if c then
        c[sid] = nil
        if next(c) == nil then self.channels[channel] = nil end
    end
    local s = self.sub_of[sid]
    if s then
        s[channel] = nil
        if next(s) == nil then self.sub_of[sid] = nil end
    end
end

function M:leave_all(sid)
    local s = self.sub_of[sid]
    if not s then return end
    for channel in pairs(s) do
        local c = self.channels[channel]
        if c then
            c[sid] = nil
            if next(c) == nil then self.channels[channel] = nil end
        end
    end
    self.sub_of[sid] = nil
end

-- Filtered fanout (§11 guild/area): the sids on THIS lane in `channel`. An empty
-- list means the lane has no members and skips the broadcast.
function M:deliver(channel)
    local out = {}
    local c = self.channels[channel]
    if c then
        for sid in pairs(c) do out[#out + 1] = sid end
    end
    return out
end

function M:member_count(channel)
    local c = self.channels[channel]
    if not c then return 0 end
    local n = 0
    for _ in pairs(c) do n = n + 1 end
    return n
end

-- World chat / system announce (§11): every session this lane holds.
function M:deliver_all()
    local out = {}
    for sid in pairs(self.sessions) do out[#out + 1] = sid end
    return out
end

-- Private-chat target routing (§11). Resolve the target's lifetime home once and
-- cache it. `resolver` is an optional function(pid) -> game, lane (defaults to the
-- affinity hash); a deployment passes one backed by DB/Redis. Returns home_game,
-- home_lane.
function M:resolve_home(pid, resolver)
    local h = self.home_cache[pid]
    if h then return h[1], h[2] end
    local g, l = (resolver or zone_def.resolve_player_home)(pid)
    self.home_cache[pid] = { g, l }
    return g, l
end

return M
