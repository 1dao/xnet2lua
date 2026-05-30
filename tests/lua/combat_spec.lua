-- Unit specs for scripts/game/combat.lua: the pure combat-rules kernel
-- (design §7.4 / §9.1). Skill lookup, range test, damage roll -- no state, no
-- transport. Run via: bin/xnet tests/lua/combat_spec.lua

local spec = dofile('tests/lua/spec_helper.lua')
local combat = dofile('scripts/game/combat.lua')

spec.describe('combat skill table', function()
    spec.it('looks up the known v1 skills', function()
        local melee = combat.skill(1)
        spec.truthy(melee, 'melee exists')
        spec.equal(melee.name, 'melee')
        spec.truthy(combat.skill(2), 'bow exists')
        spec.truthy(combat.skill(3), 'fireball exists')
    end)

    spec.it('returns nil for an unknown skill id', function()
        spec.nil_value(combat.skill(999))
    end)
end)

spec.describe('combat range (squared, inclusive)', function()
    local melee = combat.skill(1)        -- range 48

    spec.it('computes squared distance without a sqrt', function()
        spec.equal(combat.dist2(0, 0, 3, 4), 25)
    end)

    spec.it('lands a hit comfortably inside the radius', function()
        spec.truthy(combat.in_range(melee, 0, 0, 30, 0))
    end)

    spec.it('treats the boundary as a hit (<=)', function()
        spec.truthy(combat.in_range(melee, 0, 0, 48, 0))
    end)

    spec.it('misses one unit past the radius', function()
        spec.truthy(not combat.in_range(melee, 0, 0, 49, 0))
    end)

    spec.it('a nil skill is never in range', function()
        spec.truthy(not combat.in_range(nil, 0, 0, 0, 0))
    end)
end)

spec.describe('combat damage roll', function()
    local melee = combat.skill(1)        -- base damage 12

    spec.it('is the flat skill base with no stat blocks', function()
        spec.equal(combat.roll_damage(melee), 12)
    end)

    spec.it('adds attacker atk and subtracts target def', function()
        spec.equal(combat.roll_damage(melee, { atk = 5 }, { def = 3 }), 14)
    end)

    spec.it('floors at 1 against overwhelming defense', function()
        spec.equal(combat.roll_damage(melee, nil, { def = 1000 }), 1)
    end)

    spec.it('a nil skill deals nothing', function()
        spec.equal(combat.roll_damage(nil), 0)
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
