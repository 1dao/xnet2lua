-- Spec for the gate's weak-auth admission DECISION (scripts/gate/admit.lua): turning
-- a client's first login frame into the shard the connection belongs on, before any
-- AEAD state exists (design §4 / §19.0 身份 ≠ 位置).
--
-- The decision is the pure brain of auth_worker.lua. The two properties that matter:
--   * a login resolves to a STABLE account_id (so a reconnect reshards identically),
--   * the shard lane is exactly zone_def's home lane (one hash site -> the gate
--     places a session on the SAME lane its battle home / persistent state use,
--     closing the residency gap home_residency_spec pins).
--
-- The socket glue in auth_worker.lua (attach/detach/handoff) is not unit-tested here;
-- it mirrors gate/main.lua's proven admission handoff and is verified by compile +
-- review until the live gate cutover slice.
--
-- Run via: bin/xnet tests/lua/admit_spec.lua

local spec = dofile('tests/lua/spec_helper.lua')
local admit = dofile('scripts/gate/admit.lua')
local auth = dofile('scripts/gate/auth.lua')
local zone_def = dofile('scripts/game/zone_def.lua')

local function u16(n) return string.char(math.floor(n / 256) % 256, n % 256) end
local function u32(n)
    return string.char(
        math.floor(n / 16777216) % 256, math.floor(n / 65536) % 256,
        math.floor(n / 256) % 256, n % 256)
end
-- build a frame matching admit.parse_login's layout.
local function frame(token, claimed)
    token = token or ''
    local flags = (claimed ~= nil) and 1 or 0
    local out = string.char(flags) .. u16(#token) .. token
    if claimed ~= nil then out = out .. u32(claimed) end
    return out
end

-- deterministic stand-in for the mock verifier's RNG, so minted ids are assertable.
local function seq_rand(start)
    local n = (start or 1) - 1
    return function() n = n + 1; return n end
end

local T = 6
local function lane_mod(id) return (id % T) + 1 end   -- predictable lane for decisions

spec.describe('gate weak-auth admission decision (§4/§19.0)', function()
    spec.it('parse_login round-trips token + claimed id', function()
        local ok, token, claimed = admit.parse_login(frame('ticket-abc', 4242))
        spec.truthy(ok, 'frame parses')
        spec.equal(token, 'ticket-abc')
        spec.equal(claimed, 4242)
    end)

    spec.it('parse_login: token only, no claimed id', function()
        local ok, token, claimed = admit.parse_login(frame('tok', nil))
        spec.truthy(ok)
        spec.equal(token, 'tok')
        spec.nil_value(claimed, 'no claimed id present')
    end)

    spec.it('parse_login rejects a short / truncated frame', function()
        spec.equal(admit.parse_login('\0\0'), false, 'fewer than 3 bytes')
        spec.equal(admit.parse_login('\0' .. u16(10) .. 'ab'), false,
            'claims a 10-byte token but supplies 2')
    end)

    spec.it('a claimed account_id is trusted and sharded (src=claimed)', function()
        local r = auth.new({ rand = seq_rand(1) })
        local d = admit.decide(frame('ignored', 100), { resolver = r, lane_for = lane_mod })
        spec.truthy(d.ok)
        spec.equal(d.account_id, 100, 'declared id used as-is')
        spec.equal(d.src, 'claimed')
        spec.equal(d.lane, lane_mod(100), 'sharded by the declared id')
    end)

    spec.it('a token resolves to a stable account_id and lane (src=verified)', function()
        local r = auth.new({ rand = seq_rand(5000) })
        local d1 = admit.decide(frame('player-token'), { resolver = r, lane_for = lane_mod })
        spec.truthy(d1.ok)
        spec.equal(d1.src, 'verified')
        spec.equal(d1.account_id, 5000, 'minted from the injected generator')
        spec.equal(d1.lane, lane_mod(5000))
        local d2 = admit.decide(frame('player-token'), { resolver = r, lane_for = lane_mod })
        spec.equal(d2.account_id, d1.account_id, 'same token -> same account_id')
        spec.equal(d2.lane, d1.lane, '-> same shard lane (reconnect lands identically)')
    end)

    spec.it('the shard lane IS zone_def home lane -- one hash site, gate == battle', function()
        zone_def.GAME_COUNT = 2
        zone_def.LANE_COUNT = T
        local r = auth.new({ rand = seq_rand(777) })
        local real_lane = function(id) return (select(2, zone_def.resolve_player_home(id))) end
        local d = admit.decide(frame('tok-z'), { resolver = r, lane_for = real_lane })
        spec.truthy(d.ok)
        local _, home_lane = zone_def.resolve_player_home(d.account_id)
        spec.equal(d.lane, home_lane, 'gate shard lane == battle home lane')
        spec.truthy(d.lane >= 1 and d.lane <= T, 'lane within [1,T]')
    end)

    spec.it('rejects a malformed frame (bad_login_frame)', function()
        local d = admit.decide('\0\0', { resolver = auth.new({}), lane_for = lane_mod })
        spec.equal(d.ok, false)
        spec.equal(d.reason, 'bad_login_frame')
    end)

    spec.it('rejects an empty login: no token, no claimed id (no_token)', function()
        local d = admit.decide(frame('', nil), { resolver = auth.new({}), lane_for = lane_mod })
        spec.equal(d.ok, false)
        spec.equal(d.reason, 'no_token')
    end)

    spec.it('rejects a claimed account_id of 0 (bad_account_id)', function()
        local d = admit.decide(frame('tok', 0), { resolver = auth.new({}), lane_for = lane_mod })
        spec.equal(d.ok, false)
        spec.equal(d.reason, 'bad_account_id')
    end)

    spec.it('surfaces a verifier rejection (verify_failed)', function()
        local r = auth.new({ verifier = { verify = function() return nil end } })
        local d = admit.decide(frame('any'), { resolver = r, lane_for = lane_mod })
        spec.equal(d.ok, false)
        spec.equal(d.reason, 'verify_failed')
    end)
end)

local failures = spec.finish()

return {
    __init = function()
        if failures > 0 then
            os.exit(1)
        end
        xthread.stop(0)
    end,
}
