-- Unit specs for the HTTP client building blocks: xhttp_codec.parse_url and the
-- response-parsing extensions (chunked / decompress / eof) that the client
-- relies on. The end-to-end async round-trip lives in demo/xhttp_client_main.lua.
-- Run via: make unit-lua

local spec = dofile('tests/lua/spec_helper.lua')
local codec = dofile('scripts/core/share/xhttp_codec.lua')
local xcompress = require('xcompress')

spec.describe('xhttp_codec.parse_url', function()
    spec.it('parses scheme, host, default port and path', function()
        local scheme, host, port, path = codec.parse_url('http://example.test/a/b?x=1')
        spec.equal(scheme, 'http')
        spec.equal(host, 'example.test')
        spec.equal(port, 80)
        spec.equal(path, '/a/b?x=1')
    end)

    spec.it('defaults https to port 443 and "/"', function()
        local scheme, host, port, path = codec.parse_url('https://example.test')
        spec.equal(scheme, 'https')
        spec.equal(host, 'example.test')
        spec.equal(port, 443)
        spec.equal(path, '/')
    end)

    spec.it('honours an explicit port and strips userinfo', function()
        local scheme, host, port, path = codec.parse_url('http://user:pw@host.test:8080/p')
        spec.equal(scheme, 'http')
        spec.equal(host, 'host.test')
        spec.equal(port, 8080)
        spec.equal(path, '/p')
    end)

    spec.it('parses a bracketed IPv6 literal with port', function()
        local scheme, host, port = codec.parse_url('https://[::1]:9443/')
        spec.equal(scheme, 'https')
        spec.equal(host, '::1')
        spec.equal(port, 9443)
    end)

    spec.it('rejects a URL without a scheme', function()
        local scheme, err = codec.parse_url('example.test/x')
        spec.nil_value(scheme)
        spec.truthy(err)
    end)
end)

spec.describe('xhttp_codec.parse_response', function()
    spec.it('parses a content-length body', function()
        local raw = table.concat({
            'HTTP/1.1 200 OK',
            'Content-Length: 5',
            '',
            'hello',
        }, '\r\n')
        local resp, next_pos, err = codec.parse_response(raw)
        spec.nil_value(err)
        spec.equal(resp.status, 200)
        spec.equal(resp.body, 'hello')
        spec.equal(next_pos, #raw + 1)
    end)

    spec.it('reports incomplete when the body has not all arrived', function()
        local raw = 'HTTP/1.1 200 OK\r\nContent-Length: 5\r\n\r\nhel'
        local resp, _, err = codec.parse_response(raw)
        spec.nil_value(resp)
        spec.equal(err, 'incomplete')
    end)

    spec.it('decodes a chunked body', function()
        local raw = table.concat({
            'HTTP/1.1 200 OK',
            'Transfer-Encoding: chunked',
            '',
            '5', 'hello',
            '6', ' world',
            '0', '', '',
        }, '\r\n')
        local resp, _, err = codec.parse_response(raw)
        spec.nil_value(err)
        spec.equal(resp.status, 200)
        spec.equal(resp.body, 'hello world')
    end)

    spec.it('treats 204/304 and HEAD as bodyless', function()
        local raw = 'HTTP/1.1 204 No Content\r\n\r\n'
        local resp = codec.parse_response(raw)
        spec.truthy(resp)
        spec.equal(resp.status, 204)
        spec.equal(resp.body, '')

        local head_raw = 'HTTP/1.1 200 OK\r\nContent-Length: 10\r\n\r\n'
        local hresp = codec.parse_response(head_raw, 1, { method = 'HEAD' })
        spec.truthy(hresp)
        spec.equal(hresp.body, '')
    end)

    spec.it('reads an eof-framed body when told the peer closed', function()
        local raw = 'HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\n\r\nstreamed-body'
        local resp, _, err = codec.parse_response(raw)
        spec.equal(err, 'incomplete')      -- no length, no chunking -> wait

        local resp2 = codec.parse_response(raw, 1, { eof = true })
        spec.truthy(resp2)
        spec.equal(resp2.body, 'streamed-body')
    end)

    spec.it('transparently gunzips when decompress is set', function()
        local plain = string.rep('the quick brown fox; ', 64)
        local gz = assert(xcompress.gzip(plain))
        local raw = 'HTTP/1.1 200 OK\r\nContent-Encoding: gzip\r\nContent-Length: '
            .. tostring(#gz) .. '\r\n\r\n' .. gz
        local resp, _, err = codec.parse_response(raw, 1, { decompress = true })
        spec.nil_value(err)
        spec.equal(resp.body, plain)
        spec.equal(resp.content_encoding, 'gzip')
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
