-- Busted-style unit specs for scripts/core/share/xwebsocket.lua and the
-- HTTP->HTTPS upgrade helpers in scripts/core/share/xhttp_codec.lua.
-- Run via: make -C tests unit-lua ROOT=.. or make unit-lua

local spec  = dofile('tests/lua/spec_helper.lua')
local ws    = dofile('scripts/core/share/xwebsocket.lua')
local codec = dofile('scripts/core/share/xhttp_codec.lua')

spec.describe('xwebsocket handshake', function()
    spec.it('computes the RFC 6455 accept key', function()
        -- The canonical example from RFC 6455 §1.3.
        spec.equal(ws.accept_key('dGhlIHNhbXBsZSBub25jZQ=='),
            's3pPLMBiTxaQ9kYGzzhZRbK+xOo=')
    end)

    spec.it('base64-encodes with padding', function()
        spec.equal(ws.base64(''), '')
        spec.equal(ws.base64('f'), 'Zg==')
        spec.equal(ws.base64('fo'), 'Zm8=')
        spec.equal(ws.base64('foo'), 'Zm9v')
        spec.equal(ws.base64('foobar'), 'Zm9vYmFy')
    end)

    spec.it('detects a websocket upgrade request', function()
        local req = {
            headers = {
                ['upgrade'] = 'websocket',
                ['connection'] = 'keep-alive, Upgrade',
                ['sec-websocket-key'] = 'dGhlIHNhbXBsZSBub25jZQ==',
            },
        }
        spec.truthy(ws.is_upgrade(req))
    end)

    spec.it('rejects non-upgrade requests', function()
        spec.equal(ws.is_upgrade({ headers = { ['upgrade'] = 'h2c' } }), false)
        spec.equal(ws.is_upgrade({ headers = {} }), false)
    end)

    spec.it('builds a 101 handshake with the accept key', function()
        local req = { headers = { ['sec-websocket-key'] = 'dGhlIHNhbXBsZSBub25jZQ==' } }
        local hs = ws.handshake(req, { protocol = 'chat', server_name = 'x' })
        spec.contains(hs, 'HTTP/1.1 101 Switching Protocols')
        spec.contains(hs, 'Upgrade: websocket')
        spec.contains(hs, 'Sec-WebSocket-Accept: s3pPLMBiTxaQ9kYGzzhZRbK+xOo=')
        spec.contains(hs, 'Sec-WebSocket-Protocol: chat')
        spec.truthy(hs:sub(-4) == '\r\n\r\n')
    end)

    spec.it('selects an offered subprotocol', function()
        local req = { headers = { ['sec-websocket-protocol'] = 'foo, chat ,bar' } }
        spec.equal(ws.select_protocol(req, { 'chat', 'echo' }), 'chat')
        spec.nil_value(ws.select_protocol(req, { 'echo' }))
    end)
end)

spec.describe('xwebsocket frame codec', function()
    spec.it('round-trips a short text frame (server, unmasked)', function()
        local f = ws.encode(ws.OP_TEXT, 'hello')
        -- byte1 = 0x81 (FIN+text), byte2 = 0x05 (unmasked len 5)
        spec.equal(f:byte(1), 0x81)
        spec.equal(f:byte(2), 0x05)
        local frame, next_pos = ws.decode(f, 1)
        spec.truthy(frame)
        spec.equal(frame.opcode, ws.OP_TEXT)
        spec.equal(frame.fin, true)
        spec.equal(frame.masked, false)
        spec.equal(frame.payload, 'hello')
        spec.equal(next_pos, #f + 1)
    end)

    spec.it('round-trips a masked client frame', function()
        local f = ws.encode(ws.OP_BIN, 'binary-data', { mask = true, mask_key = 'ABCD' })
        spec.equal(f:byte(1), 0x82)              -- FIN + binary
        spec.equal(f:byte(2), 0x80 | 11)         -- mask bit + len 11
        local frame, next_pos = ws.decode(f, 1)
        spec.equal(frame.masked, true)
        spec.equal(frame.opcode, ws.OP_BIN)
        spec.equal(frame.payload, 'binary-data')  -- decoded back to plaintext
        spec.equal(next_pos, #f + 1)
    end)

    spec.it('masking is symmetric across word + tail boundaries', function()
        local payload = string.rep('A', 10)      -- 2 full words + 2 tail bytes
        local masked = ws.mask(payload, 'wxyz')
        spec.truthy(masked ~= payload)
        spec.equal(ws.mask(masked, 'wxyz'), payload)
    end)

    spec.it('uses the 16-bit extended length for medium frames', function()
        local payload = string.rep('z', 200)
        local f = ws.encode(ws.OP_TEXT, payload)
        spec.equal(f:byte(2), 126)               -- 126 => 2-byte length follows
        local frame, next_pos = ws.decode(f, 1)
        spec.equal(#frame.payload, 200)
        spec.equal(next_pos, #f + 1)
    end)

    spec.it('reports incomplete frames without consuming input', function()
        local f = ws.encode(ws.OP_TEXT, 'hello')
        local frame, pos, err = ws.decode(f:sub(1, 4), 1)
        spec.nil_value(frame)
        spec.equal(pos, 1)
        spec.equal(err, 'incomplete')
    end)

    spec.it('rejects frames over max_frame_size', function()
        local f = ws.encode(ws.OP_TEXT, string.rep('z', 200))
        local frame, _, err = ws.decode(f, 1, { max_frame_size = 100 })
        spec.nil_value(frame)
        spec.equal(err, 'frame too large')
    end)

    spec.it('decodes two pipelined frames in order', function()
        local buf = ws.encode(ws.OP_TEXT, 'one') .. ws.encode(ws.OP_TEXT, 'two')
        local f1, p1 = ws.decode(buf, 1)
        spec.equal(f1.payload, 'one')
        local f2, p2 = ws.decode(buf, p1)
        spec.equal(f2.payload, 'two')
        spec.equal(p2, #buf + 1)
    end)

    spec.it('builds and parses close frames', function()
        local cf = ws.close_frame(ws.CLOSE_NORMAL, 'bye')
        local frame = ws.decode(cf, 1)
        spec.equal(frame.opcode, ws.OP_CLOSE)
        local code, reason = ws.parse_close(frame.payload)
        spec.equal(code, 1000)
        spec.equal(reason, 'bye')
    end)
end)

spec.describe('xhttp_codec HTTP->HTTPS upgrade helpers', function()
    spec.it('formats HSTS values from flexible specs', function()
        spec.equal(codec.hsts_value(true), 'max-age=31536000')
        spec.equal(codec.hsts_value(60), 'max-age=60')
        spec.equal(codec.hsts_value('max-age=1; preload'), 'max-age=1; preload')
        spec.equal(codec.hsts_value({ max_age = 100, include_subdomains = true }),
            'max-age=100; includeSubDomains')
        spec.nil_value(codec.hsts_value(nil))
        spec.nil_value(codec.hsts_value(false))
    end)

    spec.it('computes https URLs, swapping the port', function()
        local req = { headers = { host = 'example.com:8080' }, target = '/a?b=1' }
        spec.equal(codec.https_url(req, { https_port = 443 }), 'https://example.com/a?b=1')
        spec.equal(codec.https_url(req, { https_port = 8443 }), 'https://example.com:8443/a?b=1')
    end)

    spec.it('builds a redirect response with Location + HSTS', function()
        local req = { headers = { host = 'h.test' }, target = '/x' }
        local resp = codec.https_redirect(req, { https_port = 443, status = 308, hsts = true })
        spec.equal(resp.status, 308)
        spec.equal(resp.headers['Location'], 'https://h.test/x')
        spec.equal(resp.headers['Strict-Transport-Security'], 'max-age=31536000')
    end)

    spec.it('injects HSTS into normalized responses when opts.hsts is set', function()
        local _, _, headers = codec.normalize_response(
            { method = 'GET', keep_alive = true },
            { status = 200, body = 'ok' },
            { hsts = 31536000 })
        spec.equal(headers['Strict-Transport-Security'], 'max-age=31536000')
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
