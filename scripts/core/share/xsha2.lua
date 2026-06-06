-- xsha2.lua - SHA-256 and HMAC-SHA256 in pure Lua.
--
-- Requires Lua 5.3+ (native bitwise operators, 64-bit integers, string.pack).
-- This is the runtime backend xnet ships with (minilua = Lua 5.5). It is used
-- by xadmin for password hashing and signed session cookies; keep it
-- dependency-free so any thread can `dofile` it.

local M = {}

local sbyte = string.byte
local schar = string.char
local sformat = string.format
local spack = string.pack
local sunpack = string.unpack

local function rrot(x, n)
    return ((x >> n) | (x << (32 - n))) & 0xffffffff
end

local K = {
    0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
    0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
    0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
    0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
    0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
    0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
    0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
    0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
}

-- SHA-256 over a byte string, returns the 32-byte raw digest.
function M.sha256(msg)
    msg = tostring(msg or '')
    local h0, h1, h2, h3 = 0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a
    local h4, h5, h6, h7 = 0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19

    local bitlen = #msg * 8
    msg = msg .. '\128'
    while (#msg % 64) ~= 56 do msg = msg .. '\0' end
    msg = msg .. spack('>I8', bitlen)

    local w = {}
    for chunk = 1, #msg, 64 do
        for i = 1, 16 do
            w[i] = sunpack('>I4', msg, chunk + (i - 1) * 4)
        end
        for i = 17, 64 do
            local x15, x2 = w[i - 15], w[i - 2]
            local s0 = rrot(x15, 7) ~ rrot(x15, 18) ~ (x15 >> 3)
            local s1 = rrot(x2, 17) ~ rrot(x2, 19) ~ (x2 >> 10)
            w[i] = (w[i - 16] + s0 + w[i - 7] + s1) & 0xffffffff
        end

        local a, b, c, d = h0, h1, h2, h3
        local e, f, g, hh = h4, h5, h6, h7
        for i = 1, 64 do
            local S1 = rrot(e, 6) ~ rrot(e, 11) ~ rrot(e, 25)
            local ch = (e & f) ~ ((~e) & g)
            local t1 = (hh + S1 + ch + K[i] + w[i]) & 0xffffffff
            local S0 = rrot(a, 2) ~ rrot(a, 13) ~ rrot(a, 22)
            local maj = (a & b) ~ (a & c) ~ (b & c)
            local t2 = (S0 + maj) & 0xffffffff
            hh = g; g = f; f = e; e = (d + t1) & 0xffffffff
            d = c; c = b; b = a; a = (t1 + t2) & 0xffffffff
        end

        h0 = (h0 + a) & 0xffffffff; h1 = (h1 + b) & 0xffffffff
        h2 = (h2 + c) & 0xffffffff; h3 = (h3 + d) & 0xffffffff
        h4 = (h4 + e) & 0xffffffff; h5 = (h5 + f) & 0xffffffff
        h6 = (h6 + g) & 0xffffffff; h7 = (h7 + hh) & 0xffffffff
    end

    return spack('>I4I4I4I4I4I4I4I4', h0, h1, h2, h3, h4, h5, h6, h7)
end

function M.tohex(s)
    local out = {}
    for i = 1, #s do
        out[i] = sformat('%02x', sbyte(s, i))
    end
    return table.concat(out)
end

function M.sha256_hex(msg)
    return M.tohex(M.sha256(msg))
end

local BLOCK = 64

-- HMAC-SHA256(key, msg) -> 32-byte raw digest.
function M.hmac_sha256(key, msg)
    key = tostring(key or '')
    if #key > BLOCK then key = M.sha256(key) end
    local ikey, okey = {}, {}
    for i = 1, BLOCK do
        local b = (i <= #key) and sbyte(key, i) or 0
        ikey[i] = schar(b ~ 0x36)
        okey[i] = schar(b ~ 0x5c)
    end
    return M.sha256(table.concat(okey) .. M.sha256(table.concat(ikey) .. tostring(msg or '')))
end

function M.hmac_sha256_hex(key, msg)
    return M.tohex(M.hmac_sha256(key, msg))
end

-- Constant-time-ish comparison for equal-length hex digests.
function M.equal(a, b)
    a, b = tostring(a or ''), tostring(b or '')
    if #a ~= #b then return false end
    local diff = 0
    for i = 1, #a do
        diff = diff | (sbyte(a, i) ~ sbyte(b, i))
    end
    return diff == 0
end

return M
