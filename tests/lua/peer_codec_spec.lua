-- Unit specs for scripts/game/peer_codec.lua: the Game<->Game peer wire format
-- (design §14.3 / §14.4 / §6.1). Pure byte-layout + cmsgpack round-trips, no
-- sockets. Run via: bin/xnet tests/lua/peer_codec_spec.lua

local spec = dofile('tests/lua/spec_helper.lua')
local pc = dofile('scripts/game/peer_codec.lua')

-- LuaJIT here exposes table.unpack, not the bare 5.1 global.
local unpack_args = table.unpack or unpack

spec.describe('peer_codec HELLO (§6.1)', function()
    spec.it('round-trips game_id and lane', function()
        local hello = pc.encode_hello(7, 3)
        spec.equal(#hello, pc.HELLO_LEN)
        local g, l = pc.decode_hello(hello)
        spec.equal(g, 7)
        spec.equal(l, 3)
    end)

    spec.it('rejects a bad magic', function()
        local bad = 'XXXX' .. string.sub(pc.encode_hello(1, 1), 5)
        local g, l, err = pc.decode_hello(bad)
        spec.nil_value(g)
        spec.nil_value(l)
        spec.contains(err, 'magic')
    end)

    spec.it('rejects a wrong length', function()
        local g, _, err = pc.decode_hello('PEER')
        spec.nil_value(g)
        spec.contains(err, 'length')
    end)
end)

spec.describe('peer_codec frame header (§14.3)', function()
    spec.it('round-trips every header field', function()
        local frame = pc.encode({
            msg_type = pc.AOI, src_lane = 5, dst_lane = 9,
            dst_player_id = 16777216 * 4 + 123,   -- lane-4 sid, > 2^24
            opcode = 0xBEEF,
        }, 'hello-body')
        local h, body = pc.decode_header(frame)
        spec.truthy(h, 'header decoded')
        spec.equal(h.msg_type, pc.AOI)
        spec.equal(h.src_lane, 5)
        spec.equal(h.dst_lane, 9)
        spec.equal(h.dst_player_id, 16777216 * 4 + 123)
        spec.equal(h.opcode, 0xBEEF)
        spec.equal(body, 'hello-body')
    end)

    spec.it('round-trips a large 64-bit id exactly', function()
        local big = 2 ^ 40 + 987654       -- needs the high word
        local frame = pc.encode({ msg_type = pc.ZONE_CTRL, dst_player_id = big })
        local h = pc.decode_header(frame)
        spec.equal(h.dst_player_id, big)
    end)

    spec.it('rejects a frame shorter than the header', function()
        local h, err = pc.decode_header('short')
        spec.nil_value(h)
        spec.contains(err, 'short')
    end)
end)

spec.describe('peer_codec host message round-trip', function()
    local cases = {
        {
            name = 'enter_zone carries route + pos tables',
            args = { 'enter_zone', 3, 101,
                { home_game = 1, home_lane = 2, sid = 101 }, { x = 2058, y = 10 } },
            mt = pc.ZONE_CTRL, dst_id = 101,
        },
        {
            name = 'leave_zone',
            args = { 'leave_zone', 3, 101 },
            mt = pc.ZONE_CTRL, dst_id = 101,
        },
        {
            name = 'player_move',
            args = { 'player_move', 3, 101, { x = 2078, y = 20 } },
            mt = pc.ZONE_CTRL, dst_id = 101,
        },
        {
            name = 'aoi_in carries an event list',
            args = { 'aoi_in', 5050, 'delta', 4, 17,
                { { t = 3, id = 102, x = 1, y = 2 }, { t = 1, id = 103 } } },
            mt = pc.AOI, dst_id = 5050,
        },
        {
            name = 'border_ghost rides the BORDER_SUB type',
            args = { 'border_ghost', 2, 1, 'enter', 777, 1030, 100 },
            mt = pc.BORDER_SUB, dst_id = 777,
        },
    }

    for _, c in ipairs(cases) do
        spec.it(c.name, function()
            local frame = pc.encode_host_msg(2, 6, unpack_args(c.args, 1, #c.args))
            spec.truthy(frame, 'frame encoded')
            local h, body = pc.decode_header(frame)
            spec.equal(h.msg_type, c.mt, 'msg_type from name')
            spec.equal(h.src_lane, 2)
            spec.equal(h.dst_lane, 6)
            spec.equal(h.dst_player_id, c.dst_id, 'dst id pulled from args')
            local vals = pc.unpack_body(body)
            spec.equal(vals.n, #c.args, 'arg count preserved')
            spec.equal(vals[1], c.args[1], 'msg name preserved')
        end)
    end

    spec.it('aoi_in event list survives byte-for-byte', function()
        local events = { { t = 3, id = 102, x = 11, y = 22 }, { t = 2, id = 103 } }
        local frame = pc.encode_host_msg(4, 4, 'aoi_in', 9, 'delta', 4, 17, events)
        local _, body = pc.decode_header(frame)
        local vals = pc.unpack_body(body)
        -- vals = { 'aoi_in', sid, kind, zone_id, seq, events }
        local got = vals[6]
        spec.truthy(got, 'events table present')
        spec.equal(#got, 2)
        spec.equal(got[1].t, 3); spec.equal(got[1].id, 102); spec.equal(got[1].x, 11)
        spec.equal(got[2].t, 2); spec.equal(got[2].id, 103)
    end)

    spec.it('border_ghost preserves its ev tag and world pos', function()
        local frame = pc.encode_host_msg(2, 2, 'border_ghost', 2, 1, 'enter', 777, 1030, 100)
        local _, body = pc.decode_header(frame)
        local vals = pc.unpack_body(body)
        -- vals = { 'border_ghost', zone_id, src_zone, ev, id, x, y }
        spec.equal(vals[1], 'border_ghost')
        spec.equal(vals[4], 'enter')
        spec.equal(vals[5], 777)
        spec.equal(vals[6], 1030)
        spec.equal(vals[7], 100)
    end)

    spec.it('rejects an unknown host message', function()
        local frame, err = pc.encode_host_msg(1, 1, 'not_a_real_msg', 1)
        spec.nil_value(frame)
        spec.contains(err, 'unknown')
    end)
end)

spec.describe('peer_codec migration reserve (§19.1 hook 6)', function()
    spec.it('a MIGRATE frame decodes its type so v1 can drop it', function()
        local frame = pc.encode({ msg_type = pc.MIGRATE, src_lane = 1, dst_lane = 1 },
            'opaque-v2-body')
        local h = pc.decode_header(frame)
        spec.equal(h.msg_type, pc.MIGRATE)   -- caller logs + drops, never asserts
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
