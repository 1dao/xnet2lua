-- Unit specs for scripts/gate/sid.lua: the canonical SID bit-layout codec
-- (design §19.1 hook 7 / §19.3 偷懒 #2). Pure arithmetic, no sockets. Proves the
-- layout round-trips, matches the legacy inline gate formula byte-for-byte (so the
-- gate refactor is behaviour-preserving), and pins the hook-7 invariant: a SID
-- encodes ONLY permanent facts -- never home_game. Run via:
--   bin/xnet tests/lua/sid_spec.lua
--   make -C tests unit-lua

local spec = dofile('tests/lua/spec_helper.lua')
local sid = dofile('scripts/gate/sid.lua')

-- the exact formula the gate worker used inline before extraction.
local function legacy(lane, seq) return (lane - 1) * 16777216 + seq end

spec.describe('sid encode/decode round-trip', function()
    spec.it('recovers lane and seq for assorted values', function()
        local cases = {
            { 1, 1 }, { 1, 7 }, { 2, 1 }, { 3, 42 }, { 16, 12345 },
            { 32, sid.SEQ_MAX }, { 8, 16777215 },
        }
        for _, c in ipairs(cases) do
            local lane, seq = c[1], c[2]
            local s = sid.encode(lane, seq)
            spec.truthy(s, 'encodes lane=' .. lane .. ' seq=' .. seq)
            spec.equal(sid.lane_of(s), lane, 'lane round-trips')
            spec.equal(sid.seq_of(s), seq, 'seq round-trips')
        end
    end)
end)

spec.describe('sid matches the legacy inline gate formula', function()
    spec.it('is byte-for-byte identical to (lane-1)*2^24 + seq', function()
        for lane = 1, 32 do
            for _, seq in ipairs({ 1, 2, 255, 256, 65535, 16777215 }) do
                spec.equal(sid.encode(lane, seq), legacy(lane, seq),
                    'lane=' .. lane .. ' seq=' .. seq)
            end
        end
    end)
end)

spec.describe('sid carries lane in the high bits', function()
    spec.it('same seq on different lanes yields distinct, distinguishable sids', function()
        local a = sid.encode(3, 100)
        local b = sid.encode(9, 100)
        spec.truthy(a ~= b, 'different lanes -> different sid')
        spec.equal(sid.lane_of(a), 3)
        spec.equal(sid.lane_of(b), 9)
        spec.equal(sid.seq_of(a), 100)
        spec.equal(sid.seq_of(b), 100, 'lane does not bleed into the seq field')
    end)
end)

spec.describe('sid boundary + range guards', function()
    spec.it('accepts the seq endpoints and rejects out-of-range seq', function()
        spec.truthy(sid.encode(1, sid.SEQ_MIN), 'SEQ_MIN ok')
        spec.truthy(sid.encode(1, sid.SEQ_MAX), 'SEQ_MAX ok')
        spec.nil_value(sid.encode(1, 0), 'seq 0 rejected')
        spec.nil_value(sid.encode(1, sid.SEQ_MAX + 1), 'seq past the lane stride rejected')
    end)

    spec.it('rejects a bad lane or non-number input', function()
        spec.nil_value(sid.encode(0, 1), 'lane 0 rejected')
        spec.nil_value(sid.encode(-1, 1), 'negative lane rejected')
        spec.nil_value(sid.encode(nil, 1), 'nil lane rejected')
        spec.nil_value(sid.encode(1, nil), 'nil seq rejected')
        spec.nil_value(sid.lane_of('xx'), 'lane_of on non-number is nil')
        spec.nil_value(sid.seq_of(nil), 'seq_of on nil is nil')
    end)

    spec.it('the seq endpoint stays inside its own lane (no carry into the next)', function()
        local top = sid.encode(5, sid.SEQ_MAX)
        spec.equal(sid.lane_of(top), 5, 'max seq does not spill into lane 6')
    end)
end)

-- ----- hook-7 invariant: a SID never encodes home_game (design §19.1 hook 7) -----

spec.describe('sid is migration-invariant (encodes no home_game)', function()
    spec.it('has no game term: the formula depends only on (lane, seq)', function()
        -- Two players the design would put on the SAME lane but (hypothetically)
        -- different home_game must get SIDs that differ ONLY by seq -- because the
        -- codec has no home_game parameter at all. If game ever leaked into a SID,
        -- this is the test that would catch it.
        local p_game1 = sid.encode(4, 11)
        local p_game7 = sid.encode(4, 12)            -- same lane, no game involved
        spec.equal(sid.lane_of(p_game1), 4)
        spec.equal(sid.lane_of(p_game7), 4, 'lane is independent of any game notion')
        spec.equal(p_game7 - p_game1, 1, 'sids differ purely by the seq increment')
    end)

    spec.it('a minted SID decodes to the same lane for the player\'s whole life', function()
        -- v1 player home_game == hash; v2 migration would change "current game".
        -- A SID must survive that unchanged -- decoding can only ever return the
        -- permanent lane, never a stale game. There is deliberately no lane->game
        -- coupling here to go stale.
        local s = sid.encode(3, 7)
        spec.equal(sid.lane_of(s), 3, 'before any (hypothetical) migration')
        -- nothing about the SID changes when the player moves Games: re-decoding
        -- the SAME bytes yields the SAME lane, by construction.
        spec.equal(sid.lane_of(s), 3, 'after a (hypothetical) migration -- unchanged')
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
