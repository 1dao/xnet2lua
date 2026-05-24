-- Busted-style unit specs for scripts/core/share/xhttp_codec.lua.
-- Run via: make -C tests unit-lua ROOT=.. or make unit-lua

local spec = dofile('tests/lua/spec_helper.lua')
local codec = dofile('scripts/core/share/xhttp_codec.lua')

spec.describe('xhttp_codec helpers', function()
    spec.it('decodes query strings and absolute targets', function()
        local path, query_string, query =
            codec.parse_target('http://example.test/hello?name=alice+cat&flag')

        spec.equal(path, '/hello')
        spec.equal(query_string, 'name=alice+cat&flag')
        spec.equal(query.name, 'alice cat')
        spec.equal(query.flag, true)
    end)

    spec.it('parses content-type parameters', function()
        local mime, params = codec.parse_content_type(
            'Multipart/Form-Data; boundary="abc123"; charset=utf-8')

        spec.equal(mime, 'multipart/form-data')
        spec.equal(params.boundary, 'abc123')
        spec.equal(params.charset, 'utf-8')
    end)
end)

spec.describe('xhttp_codec request parsing', function()
    spec.it('parses a content-length request', function()
        local raw = table.concat({
            'POST /echo?x=1 HTTP/1.1',
            'Host: localhost',
            'Content-Length: 5',
            '',
            'hello',
        }, '\r\n')

        local req, next_pos, err = codec.parse_request(raw)
        spec.nil_value(err)
        spec.truthy(req)
        spec.equal(req.method, 'POST')
        spec.equal(req.path, '/echo')
        spec.equal(req.query.x, '1')
        spec.equal(req.body, 'hello')
        spec.equal(next_pos, #raw + 1)
    end)

    spec.it('parses a chunked request body', function()
        local raw = table.concat({
            'POST /chunk HTTP/1.1',
            'Host: localhost',
            'Transfer-Encoding: chunked',
            '',
            '5',
            'hello',
            '1',
            '!',
            '0',
            '',
            '',
        }, '\r\n')

        local req, _, err = codec.parse_request(raw)
        spec.nil_value(err)
        spec.equal(req.body, 'hello!')
    end)

    spec.it('reports incomplete headers without consuming input', function()
        local req, next_pos, err = codec.parse_request('GET / HTTP/1.1\r\nHost: local')
        spec.nil_value(req)
        spec.nil_value(next_pos)
        spec.equal(err, 'incomplete')
    end)

    spec.it('rejects malformed request lines', function()
        local req, next_pos, err = codec.parse_request('NOT-HTTP\r\nHost: local\r\n\r\n')
        spec.nil_value(req)
        spec.nil_value(next_pos)
        spec.equal(err, 'bad request line')
    end)

    spec.it('rejects bodies above the configured limit', function()
        local raw = table.concat({
            'POST /big HTTP/1.1',
            'Host: localhost',
            'Content-Length: 12',
            '',
            'hello world!',
        }, '\r\n')

        local req, next_pos, err = codec.parse_request(raw, 1, { max_request_size = 8 })
        spec.nil_value(req)
        spec.nil_value(next_pos)
        spec.equal(err, 'request body too large')
    end)

    spec.it('reports bad chunk sizes', function()
        local raw = table.concat({
            'POST /chunk HTTP/1.1',
            'Host: localhost',
            'Transfer-Encoding: chunked',
            '',
            'zz',
            'bad',
            '0',
            '',
            '',
        }, '\r\n')

        local req, next_pos, err = codec.parse_request(raw)
        spec.nil_value(req)
        spec.nil_value(next_pos)
        spec.equal(err, 'bad chunk size')
    end)
end)

spec.describe('xhttp_codec body decoders', function()
    spec.it('parses urlencoded forms', function()
        local form = codec.form('name=alice+cat&kind=urlencoded')
        spec.equal(form.name, 'alice cat')
        spec.equal(form.kind, 'urlencoded')
    end)

    spec.it('parses multipart fields and files', function()
        local boundary = '----xnet-spec'
        local body = table.concat({
            '--' .. boundary,
            'Content-Disposition: form-data; name="name"',
            '',
            'alice',
            '--' .. boundary,
            'Content-Disposition: form-data; name="upload"; filename="hello.txt"',
            'Content-Type: text/plain',
            '',
            'file-body',
            '--' .. boundary .. '--',
            '',
        }, '\r\n')

        local parts, err = codec.multipart({
            headers = { ['content-type'] = 'multipart/form-data; boundary=' .. boundary },
            body = body,
        })

        spec.nil_value(err)
        spec.equal(parts.fields.name, 'alice')
        spec.equal(parts.files.upload.filename, 'hello.txt')
        spec.equal(parts.files.upload.data, 'file-body')
    end)

    spec.it('rejects multipart bodies without a boundary', function()
        local parts, err = codec.multipart({
            headers = { ['content-type'] = 'multipart/form-data' },
            body = 'anything',
        })

        spec.nil_value(parts)
        spec.equal(err, 'missing multipart boundary')
    end)
end)

spec.describe('xhttp_codec response parsing', function()
    spec.it('parses a response and honors content-length', function()
        local raw = 'HTTP/1.1 200 OK\r\nContent-Length: 5\r\n\r\nhello'
        local resp, next_pos, err = codec.parse_response(raw)

        spec.nil_value(err)
        spec.equal(resp.status, 200)
        spec.equal(resp.body, 'hello')
        spec.equal(next_pos, #raw + 1)
    end)

    spec.it('normalizes scalar responses', function()
        local status, body, headers = codec.normalize_response({
            method = 'GET',
            keep_alive = true,
        }, 'hello')

        spec.equal(status, 200)
        spec.equal(body, 'hello')
        spec.equal(headers['Content-Length'], '5')
        spec.equal(headers.Connection, 'keep-alive')
    end)

    spec.it('parses HEAD responses without consuming a body', function()
        local raw = 'HTTP/1.1 204 No Content\r\nContent-Length: 99\r\n\r\nignored'
        local resp, next_pos, err = codec.parse_response(raw, 1, { method = 'HEAD' })

        spec.nil_value(err)
        spec.equal(resp.status, 204)
        spec.equal(resp.body, '')
        spec.equal(next_pos, raw:find('\r\n\r\n', 1, true) + 4)
    end)

    spec.it('normalizes missing file responses to 404', function()
        local status, body, headers = codec.normalize_response({
            method = 'GET',
            keep_alive = false,
        }, {
            file = 'tests/lua/this-file-does-not-exist.txt',
        })

        spec.equal(status, 404)
        spec.equal(body, 'file not found\n')
        spec.equal(headers['Content-Length'], tostring(#body))
        spec.equal(headers.Connection, 'close')
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
