-- Busted-style unit specs for the xutils crypto/encoding exports
-- (mbedTLS-backed hashes/HMAC + base64/hex). Run via: make -C tests unit-lua
--
-- These are available on EVERY build (HTTPS or not): the mbedTLS hash files are
-- self-contained and linked unconditionally. See xlua/lua_xutils.c.

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
