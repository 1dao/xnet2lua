-- Stage 7 spec: a gate lane's chat fanout registry (design §11).
--
-- chat.lua keeps a lane's guild/area channel membership so a NATS broadcast only
-- touches the sessions that belong to the channel (world chat and system announce
-- hit every session), and caches a private-chat target's lifetime home so private
-- messages ride the mesh straight there.
--
-- Run via: bin/xnet tests/lua/chat_spec.lua

local spec = dofile('tests/lua/spec_helper.lua')
local chat = dofile('scripts/game/chat.lua')

-- pairs() order is unspecified; compare channel fanout as a set.
local function as_set(list)
    local set = {}
    for i = 1, #list do set[list[i]] = true end
    return set
end

spec.describe('filtered guild/area fanout touches only members (§11)', function()
    spec.it('delivers a guild broadcast to just that guild on this lane', function()
        local c = chat.new()
        local g42 = chat.guild_channel(42)
        c:join(g42, 1001)
        c:join(g42, 1002)
        c:join(chat.guild_channel(99), 1003)
        local fan = as_set(c:deliver(g42))
        spec.truthy(fan[1001] and fan[1002], 'both guild-42 members reached')
        spec.truthy(not fan[1003], 'a guild-99 member is not in the guild-42 fanout')
        spec.equal(c:member_count(g42), 2)
    end)

    spec.it('a channel with no members on this lane yields an empty fanout', function()
        local c = chat.new()
        spec.equal(#c:deliver(chat.area_channel(7)), 0, 'lane skips the broadcast')
    end)

    spec.it('formats stable channel ids', function()
        spec.equal(chat.guild_channel(42), 'guild:42')
        spec.equal(chat.area_channel(7), 'area:7')
    end)

    spec.it('tracks one sid across several channels', function()
        local c = chat.new()
        c:join(chat.guild_channel(1), 5001)
        c:join(chat.area_channel(3), 5001)
        spec.equal(c:member_count(chat.guild_channel(1)), 1)
        spec.equal(c:member_count(chat.area_channel(3)), 1)
    end)
end)

spec.describe('membership cleanup (§11)', function()
    spec.it('leave removes a member and prunes the empty channel', function()
        local c = chat.new()
        local area = chat.area_channel(5)
        c:join(area, 2001)
        c:leave(area, 2001)
        spec.equal(c:member_count(area), 0)
        spec.equal(#c:deliver(area), 0)
    end)

    spec.it('remove_session drops the sid from every channel it was in', function()
        local c = chat.new()
        c:add_session(3001)
        c:join(chat.guild_channel(1), 3001)
        c:join(chat.area_channel(2), 3001)
        c:join(chat.guild_channel(1), 3002)      -- a bystander stays
        c:remove_session(3001)
        spec.truthy(not as_set(c:deliver(chat.guild_channel(1)))[3001],
            'disconnected sid gone from guild')
        spec.equal(#c:deliver(chat.area_channel(2)), 0, 'and from area')
        spec.equal(c:member_count(chat.guild_channel(1)), 1, 'bystander untouched')
    end)
end)

spec.describe('world chat / system announce hit every session (§11)', function()
    spec.it('delivers to all sessions the lane holds', function()
        local c = chat.new()
        c:add_session(4001)
        c:add_session(4002)
        c:add_session(4003)
        spec.equal(#c:deliver_all(), 3)
        c:remove_session(4002)
        local fan = as_set(c:deliver_all())
        spec.truthy(fan[4001] and fan[4003])
        spec.truthy(not fan[4002], 'a removed session no longer receives world chat')
    end)
end)

spec.describe('private-chat home is resolved once and cached (§11)', function()
    spec.it('caches the lifetime home, calling the resolver only once', function()
        local c = chat.new()
        local calls = 0
        local function resolver(_pid) calls = calls + 1; return 7, 3 end
        local g1, l1 = c:resolve_home(8001, resolver)
        local g2, l2 = c:resolve_home(8001, resolver)
        spec.equal(g1, 7); spec.equal(l1, 3)
        spec.equal(g2, 7); spec.equal(l2, 3)
        spec.equal(calls, 1, 'second private message reuses the cached home')
    end)

    spec.it('default resolver matches the affinity hash', function()
        local c = chat.new()
        local zone_def = dofile('scripts/game/zone_def.lua')
        local rg, rl = zone_def.resolve_player_home(8002)
        local g, l = c:resolve_home(8002)
        spec.equal(g, rg, 'home_game from resolve_player_home')
        spec.equal(l, rl, 'home_lane from resolve_player_home')
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
