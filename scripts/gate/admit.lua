-- scripts/gate/admit.lua -- the gate's weak-auth admission DECISION (pure).
--
-- The brain of the auth lane (auth_worker.lua) in the "weak-auth first, strong-AEAD
-- after migration" placement scheme (design §4 / §19.0 身份 ≠ 位置). A client's first
-- frame is a login ticket (optionally a claimed account_id); this turns it into the
-- shard the connection belongs on -- hash(account_id)%T -- while NO AEAD state exists
-- yet, so the fd handoff to the owning worker carries nothing but the fd + account_id
-- and stays cheap. The heavy AEAD handshake then runs once, after the fd lands.
--
-- Deliberately free of xnet/xthread so the decision unit-tests in isolation;
-- auth_worker.lua is the thin socket glue that feeds frames in and acts on the result.

local M = {}

local function u16be(s, i)
    local a, b = s:byte(i, i + 1)
    return a * 256 + b
end

local function u32be(s, i)
    local a, b, c, d = s:byte(i, i + 3)
    return ((a * 256 + b) * 256 + c) * 256 + d
end

-- Login frame -- a v1 SEAM (it becomes the real signed/short-lived ticket later):
--   [1]              flags       bit0 = a claimed account_id trails the token
--   [2..3]           token_len   u16be
--   [4 .. 3+len]     token       token_len bytes (the auth credential)
--   [4+len .. +4]    account_id  u32be, present iff flags bit0
-- Returns (true, token, claimed_id|nil) or false on a malformed / truncated frame.
function M.parse_login(body)
    if type(body) ~= 'string' or #body < 3 then return false end
    local flags = body:byte(1)
    local has_claimed = (flags % 2) == 1
    local token_len = u16be(body, 2)
    local need = 3 + token_len + (has_claimed and 4 or 0)
    if #body < need then return false end
    local token = token_len > 0 and body:sub(4, 3 + token_len) or ''
    local claimed
    if has_claimed then claimed = u32be(body, 4 + token_len) end
    return true, token, claimed
end

-- decide(body, deps) -> result table.
--   deps.resolver : an auth.new(...) instance -- resolve(token, claimed) -> id, src
--   deps.lane_for : function(account_id) -> lane in [1, T]  (zone_def hash site)
-- result:
--   { ok = true,  account_id = n, lane = n, src = 'claimed'|'verified' }
--   { ok = false, reason = 'bad_login_frame'|'no_token'|'verify_failed'
--                          |'bad_account_id'|'no_lane' }
function M.decide(body, deps)
    local ok, token, claimed = M.parse_login(body)
    if not ok then return { ok = false, reason = 'bad_login_frame' } end
    local account_id, src = deps.resolver:resolve(token, claimed)
    if not account_id then return { ok = false, reason = src or 'no_token' } end
    if type(account_id) ~= 'number' or account_id <= 0 then
        return { ok = false, reason = 'bad_account_id' }
    end
    local lane = deps.lane_for(account_id)
    if not lane then return { ok = false, reason = 'no_lane' } end
    return { ok = true, account_id = account_id, lane = lane, src = src }
end

return M
