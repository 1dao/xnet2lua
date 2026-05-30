-- §19.1 spec: the single "where is player P?" resolution site.
--
-- player_route.lua is the one function every "which Game/lane is this player on?"
-- caller goes through (§19.1 hook 2). A DB-sourced route wins; with no record it
-- falls back to the structural hash (§2). It carries the v2 seams -- home_game
-- update and cache invalidate -- that v1 never exercises but must expose.
--
-- Run via: bin/xnet tests/lua/player_route_spec.lua

local spec = dofile('tests/lua/spec_helper.lua')
local player_route = dofile('scripts/game/player_route.lua')
local zone_def = dofile('scripts/game/zone_def.lua')

-- A deterministic stub fallback for the override/seam drills, so assertions do
-- not depend on the hash internals.
local function fixed(g, l)
    return function(_pid) return g, l end
end

spec.describe('fallback to the structural hash (§2)', function()
    spec.it('an unknown player resolves via the hash, tagged src=hash', function()
        local pr = player_route.new()
        local g, l, hint, src = pr:resolve(424242)
        local hg, hl = zone_def.resolve_player_home(424242)
        spec.equal(g, hg, 'home_game matches the structural hash')
        spec.equal(l, hl, 'home_lane matches the structural hash')
        spec.nil_value(hint, 'no sid_hint without a record')
        spec.equal(src, 'hash')
        spec.truthy(not pr:known(424242), 'a fallback resolve does not cache')
    end)

    spec.it('honours an injected fallback', function()
        local pr = player_route.new({ fallback = fixed(4, 2) })
        local g, l, _, src = pr:resolve(7)
        spec.equal(g, 4)
        spec.equal(l, 2)
        spec.equal(src, 'hash')
    end)
end)

spec.describe('a known DB route wins (§2 "DB 字段为主")', function()
    spec.it('returns the learned route with its sid_hint, tagged src=db', function()
        local pr = player_route.new({ fallback = fixed(9, 9) })
        pr:learn(7, 2, 5, 0x05000001)
        local g, l, hint, src = pr:resolve(7)
        spec.equal(g, 2, 'DB home_game beats the hash')
        spec.equal(l, 5)
        spec.equal(hint, 0x05000001, 'sid_hint carried through')
        spec.equal(src, 'db')
        spec.truthy(pr:known(7))
    end)
end)

spec.describe('v2 seam: home_game update (§19.2 HOME_UPDATE)', function()
    spec.it('flips home_game on a known player but keeps home_lane', function()
        local pr = player_route.new()
        pr:learn(7, 2, 5)
        pr:update_home(7, 8)
        local g, l, _, src = pr:resolve(7)
        spec.equal(g, 8, 'home_game moved')
        spec.equal(l, 5, 'home_lane is lifetime-fixed, unchanged')
        spec.equal(src, 'update')
    end)

    spec.it('materialises an unknown player against its structural lane', function()
        local pr = player_route.new({ fallback = fixed(9, 4) })
        pr:update_home(7, 3)
        local g, l, _, src = pr:resolve(7)
        spec.equal(g, 3, 'new home_game taken')
        spec.equal(l, 4, 'home_lane filled from the structural fallback')
        spec.equal(src, 'update')
        spec.truthy(pr:known(7), 'now a real record')
    end)
end)

spec.describe('v2 seam: invalidate (§19.3 item 8)', function()
    spec.it('drops a cached route so the next resolve re-reads the fallback', function()
        local pr = player_route.new({ fallback = fixed(9, 9) })
        pr:learn(7, 2, 5)
        spec.truthy(pr:invalidate(7), 'a record was dropped')
        spec.truthy(not pr:known(7))
        local g, l, _, src = pr:resolve(7)
        spec.equal(g, 9, 'back to the fallback')
        spec.equal(l, 9)
        spec.equal(src, 'hash')
    end)

    spec.it('is a no-op (false) on an unknown player', function()
        local pr = player_route.new()
        spec.truthy(not pr:invalidate(999), 'nothing to drop')
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
