-- Spec for the gate's IDENTITY authority over the client's in-band OP_LOGIN
-- (scripts/gate/relay.lua): for an admitted session the gate substitutes the
-- admission-resolved account_id for whatever player_id the client declares, so
-- battle binds the session under hash(account_id)%T -- the lane the fd was placed on
-- (design §4/§19.0 身份 ≠ 位置). This is the pure brain of the rewrite the gate worker
-- (scripts/gate/worker.lua) applies in its client->battle forward path; the one-line
-- socket wiring there (state.account_id is set only for admitted sessions) is review
-- + compile, since reaching it needs a post-AEAD forward (a WITH_HTTPS build).
--
-- Run via: bin/xnet tests/lua/gate_relay_spec.lua

local spec  = dofile('tests/lua/spec_helper.lua')
local relay = dofile('scripts/gate/relay.lua')

local function u16(n) return string.char(math.floor(n / 256) % 256, n % 256) end
local function u32(n)
    return string.char(
        math.floor(n / 16777216) % 256, math.floor(n / 65536) % 256,
        math.floor(n / 256) % 256, n % 256)
end
local function r32(s, i)
    local b1, b2, b3, b4 = string.byte(s, i, i + 3)
    return b1 * 16777216 + b2 * 65536 + b3 * 256 + b4
end
local function r16(s, i)
    local b1, b2 = string.byte(s, i, i + 1)
    return b1 * 256 + b2
end

-- a client business body: [opcode:2BE][payload]
local function body(opcode, payload) return u16(opcode) .. (payload or '') end
local function login_body(pid, extra) return body(relay.OP_LOGIN, u32(pid) .. (extra or '')) end

local OP_ECHO = 0x0001

spec.describe('gate identity authority over OP_LOGIN (§4/§19.0)', function()
    spec.it('OP_LOGIN is the protocol owner opcode (mirrors battle_worker)', function()
        spec.equal(relay.OP_LOGIN, 0x0009)
    end)

    spec.it('admitted session: declared player_id is overwritten with account_id', function()
        local out = relay.authoritative_login(login_body(9999), 4242)
        spec.equal(r16(out, 1), relay.OP_LOGIN, 'opcode preserved')
        spec.equal(r32(out, 3), 4242, 'bound id is the gate account_id, not the client-declared 9999')
        spec.equal(#out, 6, 'exactly opcode(2)+id(4)')
    end)

    spec.it('the substitution wins even when the client declares the SAME id', function()
        -- harmless idempotence: an honest client declaring its real id still gets the
        -- gate-authored id, byte-for-byte.
        local out = relay.authoritative_login(login_body(4242), 4242)
        spec.equal(r32(out, 3), 4242)
    end)

    spec.it('trailing payload after the id is preserved', function()
        local out = relay.authoritative_login(login_body(1, 'XY'), 7000)
        spec.equal(r32(out, 3), 7000, 'id rewritten')
        spec.equal(string.sub(out, 7), 'XY', 'bytes past the id are untouched')
    end)

    spec.it('non-admitted session (account_id nil): body passes through untouched', function()
        local b = login_body(9999)
        local out = relay.authoritative_login(b, nil)
        spec.equal(out, b, 'no admission id -> no rewrite, client id left as declared')
    end)

    spec.it('non-LOGIN opcode passes through even for an admitted session', function()
        local b = body(OP_ECHO, 'hello')
        local out = relay.authoritative_login(b, 4242)
        spec.equal(out, b, 'only OP_LOGIN carries identity; ECHO is opaque')
    end)

    spec.it('a frame too short to hold opcode+id passes through', function()
        local b = u16(relay.OP_LOGIN) .. 'ab'   -- 4 bytes: opcode + 2 stray bytes
        local out = relay.authoritative_login(b, 4242)
        spec.equal(out, b, 'no 4-byte id present -> nothing to rewrite')
    end)

    spec.it('an empty body passes through', function()
        spec.equal(relay.authoritative_login('', 4242), '')
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
