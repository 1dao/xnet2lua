-- scripts/game/combat.lua -- pure combat rules (design doc §7.4, §9.1).
--
-- No state, no transport: skill lookup, range test, damage roll. The AUTHORITY
-- placement -- zone owner settles player-vs-NPC (the NPC lives in its lane),
-- target home_lane settles player-vs-player (only that lane may touch the
-- target's hp) -- lives in zone_host. This module only answers the local
-- question "given a skill and two stat blocks, what number comes out", so it is
-- unit-testable in isolation (tests/lua/combat_spec.lua).

local M = {}

-- v1 skill table. `range` is in world units (compared against the same world
-- coords the AOI grid is built from); `damage` is the base before defense.
M.SKILLS = {
    [1] = { id = 1, name = 'melee',    range = 48,  damage = 12, cooldown_ms = 400 },
    [2] = { id = 2, name = 'bow',      range = 220, damage = 8,  cooldown_ms = 700 },
    [3] = { id = 3, name = 'fireball', range = 160, damage = 24, cooldown_ms = 1500 },
}

-- Look up a skill definition by id, or nil for an unknown skill (callers must
-- reject the attack rather than crash -- a forged/odd opcode must never settle).
function M.skill(id)
    return M.SKILLS[id]
end

-- Squared distance, so callers never need a sqrt for a range comparison.
function M.dist2(ax, ay, bx, by)
    local dx, dy = ax - bx, ay - by
    return dx * dx + dy * dy
end

-- Is the target within the skill's reach? Boundary is inclusive (dist == range
-- still hits). A nil skill is out of range by definition.
function M.in_range(skill, ax, ay, bx, by)
    if not skill then return false end
    return M.dist2(ax, ay, bx, by) <= skill.range * skill.range
end

-- Damage = skill base + attacker.atk - target.def, floored at 1 so every landed
-- hit chips at least one point. Both stat blocks are optional (NPCs and v1
-- players carry no atk/def yet, so this degenerates to the flat skill base).
function M.roll_damage(skill, attacker, target)
    if not skill then return 0 end
    local raw = skill.damage + ((attacker and attacker.atk) or 0)
    local def = (target and target.def) or 0
    local d = raw - def
    if d < 1 then d = 1 end
    return d
end

return M
