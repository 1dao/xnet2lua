-- Failure-path spec for the home-lane RESIDENCY INVARIANT that cross-player combat
-- silently depends on (design §9.1 / §19.0, and the §19.3 #7 discipline: "v1 玩家
-- 状态不变,所以 找不到玩家/路由失效 类异常路径可能从来没测过 —— v2 上线这些
-- 路径都要用,挖一堆坑"). This spec digs that hole out in the open.
--
-- The invariant: ATTACK_PLAYER is routed to the TARGET by id alone --
-- zone_host:_to_player_home(target) re-derives the home from zone_def.resolve_player_home
-- (hash(target)%T) and posts there, because only the target's home lane owns its hp
-- (§9.1). For the hit to land, the target's LIVE session must actually be resident on
-- hash(target)%T. If it is not, the routed message reaches an empty host and
-- _settle_attack_player returns at `if not tp then` -- a graceful no-op, but the hit
-- is LOST. The same holds for the attacker end: the DAMAGE_DEALT number is routed back
-- to hash(attacker)%T, so an attacker resident elsewhere never sees its own number.
--
-- Why this is a real v1 gap, not a hypothetical: combat_flow_spec only passes because
-- its spawn_at_home helper deliberately places each player on its hashed home lane.
-- The live login path does NOT yet do that -- the gate assigns a connection's lane by
-- round-robin at accept (gate/main.lua pick_client_worker), before player_id is even
-- known, and battle 'spawn_at' builds the entity on THAT lane. So a session can sit on
-- a lane other than hash(player_id)%T, and cross-lane PvP against it silently no-ops.
-- The design's fix is to place the session on hash(player_id)%T after login (§19.1 /
-- the fixed Gate-Game doc §137 "握手后按 player_id 哈希取模分配 worker"); that is a
-- connection-model change. This spec does NOT implement it -- it PINS the contract the
-- placement must satisfy and the graceful-degradation behaviour until it does, so the
-- obligation is visible and regression-guarded rather than implicit.
--
-- Each gap assertion is paired with a CONTROL that is identical except for residency,
-- so the failure is provably caused by residency alone and the test is not vacuous.
--
-- Run via: bin/xnet tests/lua/home_residency_spec.lua

local spec = dofile('tests/lua/spec_helper.lua')
local zone_def = dofile('scripts/game/zone_def.lua')
local Host = dofile('scripts/game/zone_host.lua')

local GAMES, LANES = 2, 6
Host.configure({ game_count = GAMES, lane_count = LANES })
zone_def.GAME_COUNT = GAMES
zone_def.LANE_COUNT = LANES

-- A synchronous in-memory game cluster: post(game, lane, msg, ...) delivers straight
-- into the destination host (same bus shape as combat_flow_spec, minus the peer wire
-- -- residency is a routing-target question, independent of the game-boundary codec).
local function build_world()
    local hosts = {}
    local client_log = {}

    local function to_client(sid, kind, zone_id, seq, payload)
        local q = client_log[sid]
        if not q then q = {}; client_log[sid] = q end
        q[#q + 1] = { kind = kind, zone_id = zone_id, seq = seq, payload = payload }
    end

    local function post(game, lane, msg, ...)
        local target = hosts[game] and hosts[game][lane]
        if target then target:recv(msg, ...) end
    end

    for g = 1, GAMES do
        hosts[g] = {}
        for l = 1, LANES do
            hosts[g][l] = Host.new({
                game = g, lane = l, post = post, to_client = to_client,
            })
        end
    end
    return hosts, client_log
end

local function home_of(pid)
    return zone_def.resolve_player_home(pid)
end

-- A lane in the SAME home game but guaranteed NOT equal to the hash home lane --
-- this is the "wrong" placement a round-robin gate can hand a session.
local function off_home_lane(pid)
    local _, hl = home_of(pid)
    return (hl % LANES) + 1
end

local function combat_events(log, sid, inner_kind)
    local q = log[sid]
    if not q then return {} end
    local out = {}
    for i = 1, #q do
        local e = q[i]
        if e.kind == 'combat' and type(e.payload) == 'table'
        and e.payload.kind == inner_kind then
            out[#out + 1] = e.payload
        end
    end
    return out
end

-- attacker A and target T share one world cell so the AOI makes them mutually
-- visible (the target's home seeds tp.known[A], so the range check can pass). Where
-- each LIVE session sits is the caller's choice -- that is the variable under test.
local POS = { x = 28, y = 20 }                  -- zone 1, grid (0,0)
local MELEE = 1                                 -- dmg 12, same as combat_flow_spec
local A, T = 4001, 4002                         -- attacker / target player_ids

spec.describe('cross-player combat needs the TARGET session on hash(target)%T (§9.1/§19.3#7)', function()
    spec.it('CONTROL: target resident on its hash home lane -> the hit lands', function()
        local hosts, log = build_world()
        local ag, al = home_of(A)
        local tg, tl = home_of(T)
        hosts[ag][al]:spawn_player(A, A, { x = POS.x, y = POS.y })
        hosts[tg][tl]:spawn_player(T, T, { x = POS.x, y = POS.y })   -- ON hash home

        hosts[ag][al]:client_attack_player(A, T, MELEE)

        local hp = combat_events(log, T, 'hp')
        spec.equal(#hp, 1, 'target home wrote one authoritative hp update')
        spec.equal(hp[1].hp, 88, 'target hp 100 -> 88 (settled on its home lane)')
        spec.equal(#combat_events(log, A, 'damage'), 1, 'attacker got its damage number')
    end)

    spec.it('GAP: same target one lane off its hash home -> the hit is silently lost', function()
        local hosts, log = build_world()
        local ag, al = home_of(A)
        local tg = (select(1, home_of(T)))
        local wrong_lane = off_home_lane(T)        -- a round-robin placement, not hash(T)%T
        spec.truthy(wrong_lane ~= (select(2, home_of(T))), 'control: the lane really differs')
        hosts[ag][al]:spawn_player(A, A, { x = POS.x, y = POS.y })
        hosts[tg][wrong_lane]:spawn_player(T, T, { x = POS.x, y = POS.y })   -- OFF hash home

        hosts[ag][al]:client_attack_player(A, T, MELEE)

        -- routed to the (empty) hash home lane -> _settle_attack_player's `if not tp`
        -- guard fires: no crash, but no hp write and no damage number reach anyone.
        spec.equal(#combat_events(log, T, 'hp'), 0, 'no hp write: target not resident on its home lane')
        spec.equal(#combat_events(log, A, 'damage'), 0, 'and the attacker gets no number')
        -- the live entity DID spawn -- it is just on the lane combat does not route to.
        spec.truthy(hosts[tg][wrong_lane].players[T], 'the session is alive, just mis-placed')
        spec.nil_value(hosts[tg][(select(2, home_of(T)))].players[T],
            'and absent from the lane the attack was routed to')
    end)
end)

spec.describe('the ATTACKER end needs the same residency for its own number (§9.1)', function()
    spec.it('CONTROL: attacker resident on hash(attacker)%T -> it sees its number', function()
        local hosts, log = build_world()
        local ag, al = home_of(A)
        local tg, tl = home_of(T)
        hosts[ag][al]:spawn_player(A, A, { x = POS.x, y = POS.y })   -- ON hash home
        hosts[tg][tl]:spawn_player(T, T, { x = POS.x, y = POS.y })

        hosts[ag][al]:client_attack_player(A, T, MELEE)

        spec.equal(#combat_events(log, T, 'hp'), 1, 'the hit still lands on the target')
        spec.equal(#combat_events(log, A, 'damage'), 1, 'and the number routes back to the resident attacker')
    end)

    spec.it('GAP: attacker one lane off its hash home -> hit lands but its number is lost', function()
        local hosts, log = build_world()
        local ag = (select(1, home_of(A)))
        local a_wrong = off_home_lane(A)
        local tg, tl = home_of(T)
        hosts[ag][a_wrong]:spawn_player(A, A, { x = POS.x, y = POS.y })  -- OFF hash home
        hosts[tg][tl]:spawn_player(T, T, { x = POS.x, y = POS.y })

        hosts[ag][a_wrong]:client_attack_player(A, T, MELEE)

        -- the TARGET is correctly resident, so the hit lands and its hp drops...
        spec.equal(#combat_events(log, T, 'hp'), 1, 'target hp still settled on its home lane')
        -- ...but DAMAGE_DEALT routes to hash(attacker)%T, where this attacker is NOT,
        -- so the attacker never sees its own floating number.
        spec.equal(#combat_events(log, A, 'damage'), 0, 'attacker off its home lane never gets the number')
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
