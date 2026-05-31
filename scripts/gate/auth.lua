-- scripts/gate/auth.lua -- gate login admission: resolve a connection's PERMANENT
-- account_id, the key the gate shards on (design §4 login / §19.0 身份 ≠ 位置).
--
-- WHY this exists. A connection must be placed on its shard -- the gate worker /
-- battle lane hash(account_id)%T -- so the live session lands on the SAME lane its
-- persistent state is keyed under and cross-player combat routes to (the residency
-- gap home_residency_spec pins). The shard key is the account_id, so the gate has to
-- be HOLDING a stable account_id before it commits the connection. This module turns
-- "what the client presented at login" into that account_id.
--
-- The login presents a TOKEN, and MAY also present a claimed account_id:
--   * client sent an account_id -> v1 TRUSTS it. Same trust level as today's
--     OP_LOGIN: the AEAD channel is authenticated, but there is no account DB yet,
--     so this is NOT a security boundary. A real deployment drops the claimed id and
--     always verifies the token.
--   * client sent only a token -> resolve it through a VERIFIER. In production the
--     verifier RPCs a real auth service that maps the token to the account it was
--     issued for. For the dev/test phase, mock_verifier() stands in (the "模拟 token
--     认证线程" behaviour, minus the thread): it mints an account_id the first time
--     it sees a token and CACHES token->account_id, so a reconnecting token reshards
--     to the SAME lane. A non-stable map would defeat the very sharding it feeds.
--
-- Deliberately a PURE module: no xnet/xthread/network deps, so it unit-tests in
-- isolation. Two things layer on top in later slices, kept out of here on purpose:
--   * the THREAD that hosts a verifier (mock now, real-auth RPC later) -- so a slow
--     verify never blocks the gate worker, the same pattern as the REDIS service.
--   * the gate WIRING that calls resolve() at login and then moves the connection to
--     hash(account_id)%T (the fd/AEAD handoff). That is the connection-model change;
--     this module is the part that needs no rework to build and test.

local M = {}

-- mock_verifier: the dev/test stand-in for a real token-auth service. Mints a random
-- account_id the FIRST time a token is seen, then caches token->account_id forever,
-- so the same token always resolves to the same account_id. No network, no account
-- DB. `opts.rand` lets a test inject a deterministic generator; the default draws
-- from math.random across the u32 id space (player_ids are u32 on the wire / in
-- zone_def's hash). `opts.id_space` caps the range for the default generator.
function M.mock_verifier(opts)
    opts = opts or {}
    local id_space = opts.id_space or 0x7FFFFFFF
    local rand = opts.rand or function() return math.random(1, id_space) end
    local by_token = {}            -- token -> account_id (stable for the token's life)
    local used = {}                -- account_id -> true (mint-collision guard)
    return {
        verify = function(token)
            if token == nil or token == '' then return nil end
            local id = by_token[token]
            if id then return id end       -- a returning token reshards identically
            repeat id = rand() until id and not used[id]
            by_token[token] = id
            used[id] = true
            return id
        end,
    }
end

local Resolver = {}
Resolver.__index = Resolver

-- new(opts): opts.verifier injects a verifier ({ verify = function(token)->id|nil });
-- with none, a mock_verifier(opts) is used (so opts.rand / opts.id_space pass through).
function M.new(opts)
    opts = opts or {}
    return setmetatable({
        verifier = opts.verifier or M.mock_verifier(opts),
    }, Resolver)
end

-- resolve(token, claimed_account_id) -> account_id, src
--   ('id',  'claimed')   client declared an id; v1 trusts it (token left untouched)
--   ('id',  'verified')  no declared id; the token resolved through the verifier
--   (nil,   'no_token')  nothing to resolve from
--   (nil,   'verify_failed') the verifier rejected the token
function Resolver:resolve(token, claimed_account_id)
    if claimed_account_id ~= nil then
        return claimed_account_id, 'claimed'
    end
    if token == nil or token == '' then
        return nil, 'no_token'
    end
    local id = self.verifier.verify(token)
    if not id then
        return nil, 'verify_failed'
    end
    return id, 'verified'
end

return M
