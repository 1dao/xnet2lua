-- scripts/game/playerstore_redis.lua -- the Redis write-through sink for playerstore.
--
-- Pure logic over an INJECTED redis client, so it unit-tests against a fake. This
-- is the load/write pair design §19.1.4 mandates for v1: "任何持久字段变更立即通过
-- work worker 写 Redis". make() returns { load, write } closures suitable to hand
-- straight to playerstore.new(...), replacing its no-op stubs.
--
-- A player's persistent fields map to a Redis HASH keyed `player:<pid>`:
--   * load(pid)         -> HGETALL player:<pid>, decoded to a { field = value } table
--     (the cold start; a missing key / connection error yields an empty table so the
--     player simply gets defaults).
--   * write(pid, fields) -> HSET player:<pid> f v ...  -- FIELD-LEVEL, only the dirty
--     subset playerstore hands us. This is the point of the hash mapping over a JSON
--     blob: §19.1.4 wants per-field write-through, not whole-record rewrites. Sent via
--     the fire-and-forget post() so it never blocks the work lane.
--
-- The injected `redis` must expose the scripts/core/server/xredis.lua API:
--   call(cmd, ...)  -> ok, reply   (synchronous; used for load)
--   post(cmd, ...)  -> ok          (fire-and-forget; used for write)
-- Note xredis.post(cb, cmd, ...) treats a non-function first arg as the command, so
-- post('HSET', key, ...) lands as cmd='HSET' -- which is exactly how we call it.
--
-- LIMITATION (honest): Redis hash values are bulk strings, so a value round-trips as
-- a string -- set('gold', 100) reloads as '100'. v1 has no numeric persistent stat
-- flowing yet; a typed caller converts with tonumber(). No type tagging is invented.

local M = {}

local unpack = table.unpack or unpack
local DEFAULT_PREFIX = 'player:'

-- Flat HGETALL reply { f1, v1, f2, v2, ... } -> { [f1] = v1, [f2] = v2, ... }.
local function decode_hash(reply)
    local t = {}
    if type(reply) ~= 'table' then return t end
    local i = 1
    while i + 1 <= #reply do
        t[reply[i]] = reply[i + 1]
        i = i + 2
    end
    return t
end

function M.make(redis, opts)
    opts = opts or {}
    local prefix = opts.prefix or DEFAULT_PREFIX
    local function key_of(pid) return prefix .. tostring(pid) end

    local function load(pid)
        local ok, reply = redis.call('HGETALL', key_of(pid))
        if not ok then return {} end
        return decode_hash(reply)
    end

    local function write(pid, fields)
        local args = { 'HSET', key_of(pid) }
        local n = 0
        for f, v in pairs(fields) do
            args[#args + 1] = tostring(f)
            args[#args + 1] = tostring(v)
            n = n + 1
        end
        if n == 0 then return true end           -- nothing dirty -> no command
        return redis.post(unpack(args))
    end

    return { load = load, write = write, key_of = key_of }
end

return M
