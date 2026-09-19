-- Busted-style unit specs for the xutils crypto/encoding exports
-- (mbedTLS-backed hashes/HMAC/AES + base64/hex). Run via: make -C tests unit-lua
--
-- These are available on EVERY build (HTTPS or not): the mbedTLS hash and AES
-- files are self-contained and linked unconditionally. See xlua/lua_xutils.c.

local spec = dofile('tests/lua/spec_helper.lua')
local u    = require('xutils')

spec.describe('xutils hashes', function()
    spec.it('sha1 matches the known vector', function()
        spec.equal(u.sha1_hex('abc'), 'a9993e364706816aba3e25717850c26c9cd0d89d')
        spec.equal(#u.sha1('abc'), 20)
    end)

    spec.it('sha256 matches the known vector', function()
        spec.equal(u.sha256_hex('abc'),
            'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad')
        spec.equal(u.sha256_hex(''),
            'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855')
        spec.equal(#u.sha256('abc'), 32)
    end)

    spec.it('sha512 and md5 match known vectors', function()
        spec.equal(u.sha512_hex('abc'),
            'ddaf35a193617abacc417349ae20413112e6fa4e89a97ea20a9eeee64b55d39a' ..
            '2192992a274fc1a836ba3c23a3feebbd454d4423643ce80e2a9ac94fa54ca49f')
        spec.equal(u.md5_hex('abc'), '900150983cd24fb0d6963f7d28e17f72')
    end)
end)

spec.describe('xutils HMAC', function()
    spec.it('hmac_sha256 matches RFC vector', function()
        spec.equal(
            u.hmac_sha256_hex('key', 'The quick brown fox jumps over the lazy dog'),
            'f7bc83f430538424b13298e6aa6fb143ef4d59a14946175997479dbc2d1a3cd8')
    end)

    spec.it('hmac_sha1 with a long key (> block size) hashes the key first', function()
        -- Just exercise the long-key branch + length; value not pinned here.
        local out = u.hmac_sha1(string.rep('K', 100), 'data')
        spec.equal(#out, 20)
    end)
end)

spec.describe('xutils base64 / hex', function()
    spec.it('base64 encodes with padding (RFC 4648 test vectors)', function()
        spec.equal(u.base64_encode(''), '')
        spec.equal(u.base64_encode('f'), 'Zg==')
        spec.equal(u.base64_encode('fo'), 'Zm8=')
        spec.equal(u.base64_encode('foo'), 'Zm9v')
        spec.equal(u.base64_encode('foobar'), 'Zm9vYmFy')
    end)

    spec.it('base64url uses -_ and drops padding', function()
        -- 0xfb 0xff 0xbf -> standard "+/+/"-ish bytes; url-safe avoids + and /.
        local enc = u.base64url_encode('\251\255\191')
        spec.truthy(not enc:find('[+/=]'))
        spec.equal(u.base64url_decode(enc), '\251\255\191')
    end)

    spec.it('base64 decode round-trips arbitrary bytes', function()
        local raw = 'any\0binary\255\254data'
        spec.equal(u.base64_decode(u.base64_encode(raw)), raw)
    end)

    spec.it('base64 decode rejects invalid input', function()
        local out, err = u.base64_decode('!!!!')
        spec.nil_value(out)
        spec.truthy(err)
    end)

    spec.it('hex encode/decode round-trips', function()
        spec.equal(u.hex_encode('\0\1\2\255'), '000102ff')
        spec.equal(u.hex_decode('000102ff'), '\0\1\2\255')
        local out, err = u.hex_decode('abc')   -- odd length
        spec.nil_value(out)
        spec.truthy(err)
    end)
end)

spec.describe('xutils AES-CBC', function()
    local function bin(h) return (h:gsub('%x%x', function(b) return string.char(tonumber(b, 16)) end)) end

    -- NIST SP 800-38A F.2.1 / F.2.5, first block. Worth pinning to a published
    -- vector rather than to a round-trip: a round-trip passes just as happily
    -- with the blocks chained the wrong way round.
    local IV = bin('000102030405060708090a0b0c0d0e0f')
    local PT = bin('6bc1bee22e409f96e93d7e117393172a')
    local K128 = bin('2b7e151628aed2a6abf7158809cf4f3c')

    spec.it('matches the NIST CBC-AES128 vector', function()
        spec.equal(u.hex_encode(u.aes_cbc_encrypt(K128, IV, PT)), '7649abac8119b246cee98e9b12e9197d')
        spec.equal(u.aes_cbc_decrypt(K128, IV, bin('7649abac8119b246cee98e9b12e9197d')), PT)
    end)

    spec.it('matches the NIST CBC-AES256 vector', function()
        local k = bin('603deb1015ca71be2b73aef0857d77811f352c073b6108d72d9810a30914dff4')
        spec.equal(u.hex_encode(u.aes_cbc_encrypt(k, IV, PT)), 'f58c4c04d6e5f1ba779eabfb5f7bfbd6')
        spec.equal(u.aes_cbc_decrypt(k, IV, bin('f58c4c04d6e5f1ba779eabfb5f7bfbd6')), PT)
    end)

    spec.it('chains blocks instead of encrypting each on its own', function()
        -- Two identical plaintext blocks must not come out identical; that is
        -- the whole of the difference from ECB, and an IV copied by value.
        local ct = u.aes_cbc_encrypt(K128, IV, PT .. PT)
        spec.equal(#ct, 32)
        spec.truthy(ct:sub(1, 16) ~= ct:sub(17, 32))
        spec.equal(u.aes_cbc_decrypt(K128, IV, ct), PT .. PT)
    end)

    spec.it('refuses a bad key, iv or length', function()
        local out, err = u.aes_cbc_encrypt('short', IV, PT)
        spec.nil_value(out)
        spec.truthy(err)
        out, err = u.aes_cbc_encrypt(K128, 'short', PT)
        spec.nil_value(out)
        spec.truthy(err)
        out, err = u.aes_cbc_decrypt(K128, IV, 'not a whole block')
        spec.nil_value(out)
        spec.truthy(err)
    end)
end)

spec.describe('xutils crypto in higher-level use', function()
    spec.it('reproduces the RFC 6455 WebSocket accept key', function()
        local GUID = '258EAFA5-E914-47DA-95CA-C5AB0DC85B11'
        spec.equal(u.base64_encode(u.sha1('dGhlIHNhbXBsZSBub25jZQ==' .. GUID)),
            's3pPLMBiTxaQ9kYGzzhZRbK+xOo=')
    end)
end)

local failures = spec.finish()

return {
    __init = function()
        if failures > 0 then os.exit(1) end
        xthread.stop(0)
    end,
}
