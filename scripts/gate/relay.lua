-- scripts/gate/relay.lua -- gate-worker client<->battle relay transforms.
--
-- The gate worker is a near-opaque pipe between a client session and its lane's
-- battle connection, with ONE exception: IDENTITY. After weak-auth admission
-- (design §4/§19.0 身份 ≠ 位置) the gate has already RESOLVED the session to a
-- permanent account_id and placed the fd on lane = hash(account_id)%T. So when the
-- client later declares a player_id in its in-band OP_LOGIN, the GATE -- not the
-- client -- is the authority on that id: it substitutes the admitted account_id, so
-- battle binds the session under the SAME id the lane was chosen from. That closes
-- the residency gap home_residency_spec pins (gate placement == battle home), and
-- retires battle_worker.lua's "v1 TRUSTS the declared id" caveat for admitted
-- sessions. The client-declared id is NOT trusted; battle's OP_LOGIN ack echoes the
-- bound (gate-authored) id back, so the client still learns its real player_id.
--
-- This is the gate-side half of the binding battle_worker.lua's OP_LOGIN handler
-- performs. Kept pure (no xnet/xthread) so it is unit-tested by gate_relay_spec.

local M = {}

-- The single client business opcode the gate must understand to be identity-
-- authoritative. Mirrors battle_worker.lua's OP_LOGIN (the protocol owner); kept in
-- sync by gate_relay_spec, which asserts the two agree is a review concern.
M.OP_LOGIN = 0x0009

local function r16be(s, i)
    local b1, b2 = string.byte(s, i, i + 1)
    return (b1 or 0) * 256 + (b2 or 0)
end

local function u16be(n)
    return string.char(math.floor(n / 256) % 256, n % 256)
end

local function u32be(n)
    return string.char(
        math.floor(n / 16777216) % 256, math.floor(n / 65536) % 256,
        math.floor(n / 256) % 256, n % 256)
end

-- A client business body is [opcode:2BE][payload]. For an admitted session
-- (account_id ~= nil) carrying OP_LOGIN [player_id:4BE][rest...], replace the
-- client-declared player_id with the gate-resolved account_id and preserve any
-- trailing payload. Every other body -- a non-admitted session (account_id nil), a
-- non-LOGIN opcode, or a frame too short to hold opcode+id -- passes through
-- byte-for-byte. Pure: returns the (possibly rewritten) body, never mutates.
function M.authoritative_login(body, account_id)
    if account_id == nil then return body end
    if type(body) ~= 'string' or #body < 6 then return body end
    if r16be(body, 1) ~= M.OP_LOGIN then return body end
    return u16be(M.OP_LOGIN) .. u32be(account_id) .. string.sub(body, 7)
end

return M
