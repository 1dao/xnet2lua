-- demo/xhttp_compress_main.lua -- smoke test for HTTP compression / decompression
-- integrated into xhttp_codec.lua via xcompress.
--
-- Calls the codec directly (no socket / no worker) so the integration paths
-- are exercised independently of xhttp.start.
--
-- Run with:  ./bin/xnet demo/xhttp_compress_main.lua

local codec     = dofile('scripts/core/share/xhttp_codec.lua')
local xcompress = require('xcompress')

local fails = 0
local function check(cond, msg)
    if cond then
        print('PASS: ' .. msg)
    else
        fails = fails + 1
        io.stderr:write('FAIL: ' .. msg .. '\n')
    end
end

local function __init()
    print('[xhttp-compress] init')

    -- ====================================================================
    -- 1. Accept-Encoding negotiation
    -- ====================================================================
    check(codec.select_encoding('gzip, deflate, br') == 'gzip',
        'select_encoding prefers gzip')
    check(codec.select_encoding('deflate') == 'deflate',
        'select_encoding falls back to deflate')
    check(codec.select_encoding('br') == nil,
        'select_encoding rejects unsupported brotli')
    check(codec.select_encoding(nil) == nil,
        'select_encoding handles nil')

    -- ====================================================================
    -- 2. Response compression via normalize_response
    -- ====================================================================
    local plain = string.rep('lorem ipsum dolor sit amet ', 64)  -- ~1.7 KB
    local req = {
        method = 'GET',
        keep_alive = true,
        headers = { ['accept-encoding'] = 'gzip, deflate' },
    }
    local status, body, headers = codec.normalize_response(req,
        { status = 200, body = plain, headers = { ['Content-Type'] = 'text/plain' } },
        { compression = { enabled = true, min_size = 256, level = 6 } })

    check(status == 200, 'response status preserved')
    check(headers['Content-Encoding'] == 'gzip', 'gzip selected and emitted')
    check(headers['Vary'] == 'Accept-Encoding', 'Vary header set')
    check(tonumber(headers['Content-Length']) == #body, 'Content-Length matches compressed body')
    check(#body < #plain, 'compressed body smaller than plain (' .. #plain .. ' -> ' .. #body .. ')')

    -- Decompresses back to original
    local round = xcompress.gunzip(body, #plain)
    check(round == plain, 'compressed body decompresses to original')

    -- ====================================================================
    -- 3. Skip compression when body too small
    -- ====================================================================
    local tiny = 'hi'
    local _, b2, h2 = codec.normalize_response(req,
        { status = 200, body = tiny },
        { compression = { enabled = true, min_size = 256 } })
    check(h2['Content-Encoding'] == nil, 'tiny body left uncompressed')
    check(b2 == tiny, 'tiny body unchanged')

    -- ====================================================================
    -- 4. Skip compression for blacklisted content types
    -- ====================================================================
    local fake_png = string.rep('\137PNG\r\n\26\n', 200)
    local _, b3, h3 = codec.normalize_response(req,
        { status = 200, body = fake_png,
          headers = { ['Content-Type'] = 'image/png' } },
        { compression = { enabled = true, min_size = 256 } })
    check(h3['Content-Encoding'] == nil, 'image/png skipped (CT blacklist)')
    check(b3 == fake_png, 'image body unchanged')

    -- ====================================================================
    -- 5. No Accept-Encoding -> no compression
    -- ====================================================================
    local req_no_ae = { method = 'GET', keep_alive = true, headers = {} }
    local _, b4, h4 = codec.normalize_response(req_no_ae,
        { status = 200, body = plain },
        { compression = { enabled = true, min_size = 256 } })
    check(h4['Content-Encoding'] == nil, 'no Accept-Encoding -> no compression')
    check(b4 == plain, 'body unchanged when client did not opt in')

    -- ====================================================================
    -- 6. Existing Content-Encoding from the app is respected
    -- ====================================================================
    local manual_gz = xcompress.gzip(plain)
    local _, b5, h5 = codec.normalize_response(req,
        { status = 200, body = manual_gz,
          headers = { ['Content-Encoding'] = 'gzip', ['Content-Type'] = 'text/plain' } },
        { compression = { enabled = true, min_size = 256 } })
    check(h5['Content-Encoding'] == 'gzip', 'pre-set Content-Encoding preserved')
    check(b5 == manual_gz, 'pre-compressed body untouched')

    -- ====================================================================
    -- 7. Request body decompression via parse_request
    -- ====================================================================
    local request_body = string.rep('client uploaded blob ', 200)
    local gzipped = xcompress.gzip(request_body)
    local raw =
        'POST /upload HTTP/1.1\r\n' ..
        'Host: example.com\r\n' ..
        'Content-Type: application/octet-stream\r\n' ..
        'Content-Encoding: gzip\r\n' ..
        'Content-Length: ' .. #gzipped .. '\r\n' ..
        '\r\n' ..
        gzipped

    local parsed, _, perr = codec.parse_request(raw, 1, { decompress = true })
    check(parsed ~= nil, 'parse_request with decompress: ' .. tostring(perr))
    if parsed then
        check(parsed.body == request_body, 'request body decompressed back to plain')
        check(parsed.content_encoding == 'gzip', 'req.content_encoding records the original encoding')
        check(parsed.headers['content-length'] == tostring(#request_body),
            'content-length rewritten to plain length')
    end

    -- 7b. Same payload, opts.decompress = false: handler sees the gzipped bytes
    local parsed_raw, _, _ = codec.parse_request(raw, 1, { decompress = false })
    check(parsed_raw and parsed_raw.body == gzipped,
        'decompress=false leaves body in compressed form')
    check(parsed_raw and parsed_raw.content_encoding == nil,
        'no content_encoding flag when decompress=false')

    -- 7c. Malformed gzip body should produce a clean parse error
    local bad_raw =
        'POST / HTTP/1.1\r\n' ..
        'Content-Encoding: gzip\r\n' ..
        'Content-Length: 4\r\n\r\nbad!'
    local _, _, err = codec.parse_request(bad_raw, 1, { decompress = true })
    check(err ~= nil and err:find('decompress', 1, true) ~= nil,
        'malformed gzip body surfaces a decompress error')

    print(string.format('\n--- xhttp-compress smoke: %d failures ---', fails))
    xthread.stop(fails > 0 and 1 or 0)
end

local function __uninit()
    print('[xhttp-compress] uninit')
end

return { __init = __init, __uninit = __uninit }
