-- Spec for gate login admission: turning what a client presents at login (a token,
-- maybe a claimed account_id) into the STABLE account_id the gate shards on
-- (scripts/gate/auth.lua; design §4 / §19.0 身份 ≠ 位置).
--
-- The contract that matters for sharding: the SAME token must always resolve to the
-- SAME account_id, or a reconnecting player would reshard to a different lane every
-- login and the residency the shard exists to provide would break. The "random"
-- account_id the mock mints is therefore stable-per-token, not per-call. A
-- deterministic generator is injected so the mock's choices are assertable (the test
-- pins the contract, not math.random's sequence).
--
-- Run via: bin/xnet tests/lua/auth_spec.lua

local spec = dofile('tests/lua/spec_helper.lua')
local auth = dofile('scripts/gate/auth.lua')

-- a deterministic stand-in for the mock's RNG: hands out start, start+1, ... so each
-- new token gets a distinct, predictable account_id.
local function seq_rand(start)
    local n = (start or 1000) - 1
    return function() n = n + 1; return n end
end

spec.describe('gate login resolves a stable account_id (the shard key) (§4/§19.0)', function()
    spec.it('a client-declared account_id is trusted as-is (v1, src=claimed)', function()
        local r = auth.new({ rand = seq_rand(1) })
        local id, src = r:resolve('tok-ignored', 42)
        spec.equal(id, 42, 'the declared account_id wins')
        spec.equal(src, 'claimed', 'and is reported as claimed (trusted, not verified)')
    end)

    spec.it('a token with no declared id is verified to an account_id (src=verified)', function()
        local r = auth.new({ rand = seq_rand(7000) })
        local id, src = r:resolve('token-A', nil)
        spec.equal(src, 'verified', 'the token went through the verifier')
        spec.equal(id, 7000, 'minting the first id from the injected generator')
    end)

    spec.it('the same token always resolves to the same account_id (reconnect reshards same)', function()
        local r = auth.new({ rand = seq_rand(500) })
        local id1 = r:resolve('returning-token')
        local id2 = r:resolve('returning-token')
        local id3 = r:resolve('returning-token')
        spec.equal(id1, 500, 'first login mints 500')
        spec.equal(id2, id1, 'second login of the same token -> same account_id')
        spec.equal(id3, id1, 'and stays stable across further logins')
    end)

    spec.it('distinct tokens get distinct account_ids', function()
        local r = auth.new({ rand = seq_rand(1) })
        local a = r:resolve('tok-a')
        local b = r:resolve('tok-b')
        local c = r:resolve('tok-c')
        spec.truthy(a ~= b and b ~= c and a ~= c, 'three tokens -> three distinct ids')
    end)

    spec.it('a declared id wins over the token, and does NOT consume the token', function()
        local r = auth.new({ rand = seq_rand(1) })
        local id, src = r:resolve('tok-x', 9001)
        spec.equal(id, 9001, 'declared id used')
        spec.equal(src, 'claimed')
        -- the verifier only mints when a token is actually resolved, so 'tok-x' is
        -- still fresh: resolving it alone now draws the FIRST generator value.
        local tid = r:resolve('tok-x')
        spec.equal(tid, 1, 'the token was untouched until resolved on its own')
    end)

    spec.it('no token and no declared id -> no account_id (src=no_token)', function()
        local r = auth.new({ rand = seq_rand(1) })
        local id, src = r:resolve(nil, nil)
        spec.nil_value(id, 'nothing to resolve from')
        spec.equal(src, 'no_token')
        local id2, src2 = r:resolve('', nil)
        spec.nil_value(id2, 'an empty token is no token')
        spec.equal(src2, 'no_token')
    end)

    spec.it('an injected verifier that rejects yields (nil, verify_failed)', function()
        local r = auth.new({ verifier = { verify = function() return nil end } })
        local id, src = r:resolve('any-token')
        spec.nil_value(id, 'the verifier rejected the token')
        spec.equal(src, 'verify_failed')
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
