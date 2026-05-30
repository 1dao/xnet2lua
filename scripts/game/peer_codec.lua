-- scripts/game/peer_codec.lua -- Game <-> Game peer wire format (design §14.3,
-- §14.4, §6.1). Pure byte layout + cmsgpack body; no sockets, no xthread, so it
-- is unit-testable in isolation (tests/lua/peer_codec_spec.lua).
--
-- Two wire shapes ride the same len16-framed peer channel:
--
--   HELLO (handshake, §6.1):
--     [ magic:4B "PEER" | peer_game_id:4B | lane_idx:1B ]            (9 bytes)
--   ACK: single byte 0x01
--
--   business frame (§14.3):
--     [ msg_type:1B | src_lane:1B | dst_lane:1B | dst_player_id:8B
--       | opcode:2B | body ]                                  (13B header)
--
-- The body carries the zone_host message tuple (msg_name, ...) cmsgpack-packed,
-- so the same (msg, ...) that rides xthread.post in-process rides TCP cross-
-- process unchanged. msg_type/dst_lane/dst_player_id are a routing fast-path
-- (and a v2 hook); v1 dispatch unpacks the body for the authoritative args.

local M = {}

-- ----- msg_type enum (§14.4) -----
M.UPSTREAM   = 0x01   -- player upstream (gate -> game)
M.DOWNSTREAM = 0x02   -- server downstream (game -> gate -> client)
M.ZONE_CTRL  = 0x10   -- zone enter/leave/move notification (no commit/ack)
M.COMBAT     = 0x11   -- cross-process combat (ATTACK / DAMAGE / HIT_BROADCAST)
M.AOI        = 0x12   -- cross-process AOI (ZONE_SNAPSHOT / AOI_DELTA)
M.BORDER_SUB = 0x20   -- zone border subscription (startup)
M.WHISPER    = 0x21   -- direct message delivery (home_game known)
M.MIGRATE    = 0x30   -- RESERVED for v2 migration; v1 must log+drop, never crash
M.CONTROL    = 0xF0   -- control plane (heartbeat / topology)

-- §14.4 reserves the 0x30 band for migration-class messages that only v2 emits.
-- A rolling upgrade runs v1 and v2 side by side (§19.1 hook 6), so a v1 peer WILL
-- receive these -- and must drop them, never assert.
M.MIGRATE_MIN = 0x30
M.MIGRATE_MAX = 0x3F

-- classify() dispositions: hand the frame to the v1 handler, or drop it safely.
M.DISPATCH      = 'dispatch'      -- a known v1 type -> unpack the body and handle
M.DROP_MIGRATE  = 'drop_migrate'  -- reserved 0x30 band -> log+drop (v2 implements)
M.DROP_UNKNOWN  = 'drop_unknown'  -- unrecognised / malformed -> log+drop

M.MAGIC = 'PEER'
M.ACK = string.char(0x01)
M.HEADER_LEN = 13
M.HELLO_LEN = 9

-- which zone_host message goes in which category, and which positional arg
-- holds the target entity/sid (so the header's dst_player_id is meaningful).
local MSG_TYPE_OF = {
    enter_zone    = M.ZONE_CTRL,
    leave_zone    = M.ZONE_CTRL,
    player_move   = M.ZONE_CTRL,
    aoi_in        = M.AOI,
    border_ghost  = M.BORDER_SUB,
    -- cross-process combat (design §7.4 / §9): all five ride the COMBAT type so
    -- a peer can fast-path/meter the flow on msg_type alone (§14.4).
    attack_npc    = M.COMBAT,
    attack_player = M.COMBAT,
    damage_dealt  = M.COMBAT,
    hit_broadcast = M.COMBAT,
    combat_fx     = M.COMBAT,
}
local DST_ID_ARG = {
    enter_zone    = 2,   -- (zone_id, pid, route, pos)
    leave_zone    = 2,   -- (zone_id, pid)
    player_move   = 2,   -- (zone_id, pid, pos)
    aoi_in        = 1,   -- (sid, kind, zone_id, seq, payload)
    border_ghost  = 4,   -- (zone_id, src_zone, ev, id, x, y)
    attack_npc    = 2,   -- (zone_id, npc_id, attacker_pid, skill_id)
    attack_player = 1,   -- (target_pid, attacker_pid, skill_id)
    damage_dealt  = 1,   -- (pid, target_id, damage, target_hp, dead)
    hit_broadcast = 3,   -- (zone_id, attacker_pid, target_pid, skill_id)
    combat_fx     = 1,   -- (sid, zone_id, attacker_id, target_id, skill_id, damage)
}

-- cmsgpack is a C module present in worker threads; require lazily so the pure
-- header/HELLO codecs (used by the main thread's peer admission) never depend
-- on it.
local _cmsgpack
local function cmsgpack()
    if not _cmsgpack then _cmsgpack = require('cmsgpack') end
    return _cmsgpack
end

local floor = math.floor

local function u16be(n)
    return string.char(floor(n / 256) % 256, n % 256)
end

local function r16be(s, i)
    local b1, b2 = string.byte(s, i, i + 1)
    return b1 * 256 + b2
end

local function u32be(n)
    return string.char(
        floor(n / 16777216) % 256,
        floor(n / 65536) % 256,
        floor(n / 256) % 256,
        n % 256)
end

local function r32be(s, i)
    local b1, b2, b3, b4 = string.byte(s, i, i + 3)
    return b1 * 16777216 + b2 * 65536 + b3 * 256 + b4
end

-- 64-bit big-endian split into two u32. Player/sid ids fit in a Lua double
-- (< 2^53), so the high word is exact.
local function u64be(n)
    n = n or 0
    local hi = floor(n / 4294967296)
    local lo = n - hi * 4294967296
    return u32be(hi) .. u32be(lo)
end

local function r64be(s, i)
    return r32be(s, i) * 4294967296 + r32be(s, i + 4)
end

local function pack_values(...)
    return { n = select('#', ...), ... }
end

-- ----- HELLO / ACK (§6.1) -----

function M.encode_hello(game_id, lane)
    return M.MAGIC .. u32be(game_id or 0) .. string.char((lane or 0) % 256)
end

-- returns (game_id, lane) or (nil, nil, err)
function M.decode_hello(s)
    if type(s) ~= 'string' or #s ~= M.HELLO_LEN then
        return nil, nil, 'bad hello length'
    end
    if string.sub(s, 1, 4) ~= M.MAGIC then
        return nil, nil, 'bad hello magic'
    end
    return r32be(s, 5), string.byte(s, 9)
end

-- ----- business frame header (§14.3) -----

-- f = { msg_type, src_lane, dst_lane, dst_player_id, opcode }
function M.encode(f, body)
    body = body or ''
    return string.char((f.msg_type or 0) % 256)
        .. string.char((f.src_lane or 0) % 256)
        .. string.char((f.dst_lane or 0) % 256)
        .. u64be(f.dst_player_id or 0)
        .. u16be(f.opcode or 0)
        .. body
end

-- returns (header_table, body_string) or (nil, err)
function M.decode_header(frame)
    if type(frame) ~= 'string' or #frame < M.HEADER_LEN then
        return nil, 'short peer frame'
    end
    local body = #frame > M.HEADER_LEN and string.sub(frame, M.HEADER_LEN + 1) or ''
    return {
        msg_type      = string.byte(frame, 1),
        src_lane      = string.byte(frame, 2),
        dst_lane      = string.byte(frame, 3),
        dst_player_id = r64be(frame, 4),
        opcode        = r16be(frame, 12),
    }, body
end

-- ----- zone_host message <-> frame -----

-- Pack a zone_host (msg, ...) tuple into a complete peer frame.
function M.encode_host_msg(src_lane, dst_lane, msg, ...)
    local mt = MSG_TYPE_OF[msg]
    if not mt then return nil, 'unknown host msg: ' .. tostring(msg) end
    local dst_id = select(DST_ID_ARG[msg], ...) or 0
    if type(dst_id) ~= 'number' then dst_id = 0 end
    local body = cmsgpack().pack(msg, ...)
    return M.encode({
        msg_type = mt, src_lane = src_lane, dst_lane = dst_lane,
        dst_player_id = dst_id, opcode = 0,
    }, body)
end

-- Unpack a body back into a value list { n = N, [1]=msg, [2..]=args }.
function M.unpack_body(body)
    if type(body) ~= 'string' or #body == 0 then return { n = 0 } end
    return pack_values(cmsgpack().unpack(body))
end

-- ----- dispatch guard (§19.1 hook 6 / §19.3 item 7) -----
--
-- The msg_types this v1 build actually handles. Everything else is dropped, not
-- asserted: a v1 peer must survive both a v2 MIGRATE and outright garbage during
-- a rolling upgrade. The 0x30 band is split out so the caller can log it as a
-- known-future message ("migrate not supported in v1") rather than as corruption.
local KNOWN = {
    [M.UPSTREAM] = true, [M.DOWNSTREAM] = true,
    [M.ZONE_CTRL] = true, [M.COMBAT] = true, [M.AOI] = true,
    [M.BORDER_SUB] = true, [M.WHISPER] = true, [M.CONTROL] = true,
}

function M.is_known(msg_type)
    return KNOWN[msg_type] == true
end

function M.is_migrate(msg_type)
    return type(msg_type) == 'number'
        and msg_type >= M.MIGRATE_MIN and msg_type <= M.MIGRATE_MAX
end

-- msg_type -> disposition (DISPATCH / DROP_MIGRATE / DROP_UNKNOWN). Pure lookup.
function M.classify(msg_type)
    if KNOWN[msg_type] then return M.DISPATCH end
    if M.is_migrate(msg_type) then return M.DROP_MIGRATE end
    return M.DROP_UNKNOWN
end

-- Decode a peer frame far enough to decide its disposition, WITHOUT trusting the
-- body. Returns disposition, header, body. A frame too short to hold a header is
-- itself a safe DROP_UNKNOWN (header nil), never an error -- the peer read loop
-- can route every inbound frame through this without a pcall and never crash.
function M.classify_frame(frame)
    local header, body = M.decode_header(frame)
    if not header then return M.DROP_UNKNOWN, nil, nil end
    return M.classify(header.msg_type), header, body
end

return M
