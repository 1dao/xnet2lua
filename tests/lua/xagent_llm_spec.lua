-- Unit specs for the xagent LLM building blocks: the SSE parser, the
-- incremental HTTP chunked decoder, the head parser, and the Anthropic
-- SSE -> assistant-message reassembler. All offline / deterministic; the live
-- streaming round-trip lives in scripts/xagent/test_stream.lua (needs an API key).
-- Run via: bin/xnet tests/lua/xagent_llm_spec.lua

package.path = 'scripts/?.lua;' .. package.path

local spec = dofile('tests/lua/spec_helper.lua')
local xutils = require('xutils')
local sse = dofile('scripts/core/share/xsse.lua')
local stream = dofile('scripts/core/share/xhttp_stream.lua')
local anthropic = require('xagent.llm.anthropic')

-- Feed `text` to a parser in arbitrary byte-sized splits and collect events.
local function feed_split(parser, text, step)
    local events = {}
    local i = 1
    while i <= #text do
        local piece = text:sub(i, i + step - 1)
        for _, ev in ipairs(parser:feed(piece)) do events[#events + 1] = ev end
        i = i + step
    end
    return events
end

spec.describe('sse parser', function()
    spec.it('parses multiple events across awkward splits', function()
        local text =
            'event: message_start\ndata: {"a":1}\n\n' ..
            'event: ping\ndata: hello\n\n'
        for _, step in ipairs({ 1, 3, 7, 1000 }) do
            local events = feed_split(sse.new(), text, step)
            spec.equal(#events, 2, 'event count @step ' .. step)
            spec.equal(events[1].event, 'message_start')
            spec.equal(events[1].data, '{"a":1}')
            spec.equal(events[2].event, 'ping')
            spec.equal(events[2].data, 'hello')
        end
    end)

    spec.it('handles CRLF line endings and data-only events', function()
        local events = sse.new():feed('data: line1\r\ndata: line2\r\n\r\n')
        spec.equal(#events, 1)
        spec.nil_value(events[1].event)
        spec.equal(events[1].data, 'line1\nline2')   -- multi data joined with \n
    end)

    spec.it('ignores comment lines', function()
        local events = sse.new():feed(': this is a comment\ndata: x\n\n')
        spec.equal(#events, 1)
        spec.equal(events[1].data, 'x')
    end)

    spec.it('buffers a partial event until its blank line arrives', function()
        local p = sse.new()
        spec.equal(#p:feed('data: partial'), 0)
        spec.equal(#p:feed(' more'), 0)
        local events = p:feed('\n\n')
        spec.equal(#events, 1)
        spec.equal(events[1].data, 'partial more')
    end)
end)

-- Manually chunk-encode a payload into HTTP Transfer-Encoding: chunked form.
local function chunk_encode(payload, chunk_size)
    local out = {}
    local i = 1
    while i <= #payload do
        local part = payload:sub(i, i + chunk_size - 1)
        out[#out + 1] = string.format('%x\r\n%s\r\n', #part, part)
        i = i + chunk_size
    end
    out[#out + 1] = '0\r\n\r\n'
    return table.concat(out)
end

spec.describe('chunked decoder', function()
    spec.it('reassembles a payload regardless of feed boundaries', function()
        local payload = string.rep('abcdefghij', 25)   -- 250 bytes
        local encoded = chunk_encode(payload, 17)
        for _, step in ipairs({ 1, 2, 5, 23, 4096 }) do
            local dec = stream._new_chunked()
            local got = {}
            local i = 1
            while i <= #encoded do
                got[#got + 1] = dec:feed(encoded:sub(i, i + step - 1))
                i = i + step
            end
            spec.equal(table.concat(got), payload, 'decoded @step ' .. step)
            spec.truthy(dec.done, 'decoder reached terminator @step ' .. step)
        end
    end)
end)

spec.describe('head parser', function()
    spec.it('extracts status and lowercased headers', function()
        local head = 'HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\n' ..
                     'Transfer-Encoding: chunked'
        local status, headers = stream._parse_head(head)
        spec.equal(status, 200)
        spec.equal(headers['content-type'], 'text/event-stream')
        spec.equal(headers['transfer-encoding'], 'chunked')
    end)
end)

-- Build a canned Anthropic SSE sequence and drive the reassembler with it.
local function pack(ev) return xutils.json_pack(ev) end

spec.describe('anthropic reassembler', function()
    spec.it('assembles text + tool_use blocks from an SSE sequence', function()
        local streamed_text = {}
        local tool_starts = {}
        local result

        local dec = anthropic.new_decoder({
            on_text = function(t) streamed_text[#streamed_text + 1] = t end,
            on_tool_use_start = function(id, name) tool_starts[#tool_starts + 1] = id .. ':' .. name end,
            on_done = function(r) result = r end,
            on_error = function(m) error('unexpected on_error: ' .. m) end,
        })

        local seq = {
            { 'message_start', pack({ type = 'message_start',
                message = { id = 'msg_1', usage = { input_tokens = 10, output_tokens = 0 } } }) },
            { 'content_block_start', pack({ type = 'content_block_start', index = 0,
                content_block = { type = 'text', text = '' } }) },
            { 'content_block_delta', pack({ type = 'content_block_delta', index = 0,
                delta = { type = 'text_delta', text = 'Hello' } }) },
            { 'content_block_delta', pack({ type = 'content_block_delta', index = 0,
                delta = { type = 'text_delta', text = ' world' } }) },
            { 'content_block_stop', pack({ type = 'content_block_stop', index = 0 }) },
            { 'content_block_start', pack({ type = 'content_block_start', index = 1,
                content_block = { type = 'tool_use', id = 'tu_1', name = 'Read' } }) },
            { 'content_block_delta', pack({ type = 'content_block_delta', index = 1,
                delta = { type = 'input_json_delta', partial_json = '{"file' } }) },
            { 'content_block_delta', pack({ type = 'content_block_delta', index = 1,
                delta = { type = 'input_json_delta', partial_json = '_path":"a.txt"}' } }) },
            { 'content_block_stop', pack({ type = 'content_block_stop', index = 1 }) },
            { 'message_delta', pack({ type = 'message_delta',
                delta = { stop_reason = 'tool_use' }, usage = { output_tokens = 5 } }) },
            { 'message_stop', pack({ type = 'message_stop' }) },
        }
        for _, e in ipairs(seq) do dec:on_sse(e[1], e[2]) end

        spec.equal(table.concat(streamed_text), 'Hello world')
        spec.equal(#tool_starts, 1)
        spec.equal(tool_starts[1], 'tu_1:Read')

        spec.truthy(result, 'on_done fired')
        spec.equal(result.stop_reason, 'tool_use')
        spec.equal(result.usage.input_tokens, 10)
        spec.equal(result.usage.output_tokens, 5)

        local content = result.message.content
        spec.equal(#content, 2, 'two content blocks')
        spec.equal(content[1].type, 'text')
        spec.equal(content[1].text, 'Hello world')
        spec.equal(content[2].type, 'tool_use')
        spec.equal(content[2].name, 'Read')
        spec.equal(content[2].input.file_path, 'a.txt')
    end)

    spec.it('surfaces an SSE error event', function()
        local got
        local dec = anthropic.new_decoder({ on_error = function(m) got = m end })
        dec:on_sse('error', pack({ type = 'error', error = { message = 'overloaded' } }))
        spec.equal(got, 'overloaded')
    end)
end)

spec.describe('anthropic.build_request', function()
    spec.it('builds url, auth header and a streaming json body', function()
        local req = anthropic.build_request(
            { api_key = 'sk-test', base_url = 'https://api.example.com/', model = 'claude-x' },
            { messages = { { role = 'user', content = 'hi' } }, system = 'be brief' })
        spec.equal(req.url, 'https://api.example.com/v1/messages')
        spec.equal(req.headers['x-api-key'], 'sk-test')
        spec.equal(req.headers['anthropic-version'], '2023-06-01')
        spec.contains(req.body, '"model"')
        spec.contains(req.body, '"stream"')
        spec.contains(req.body, '"system"')
    end)

    spec.it('supports bearer auth style', function()
        local req = anthropic.build_request(
            { api_key = 'tok', auth_style = 'bearer' },
            { messages = { { role = 'user', content = 'hi' } } })
        spec.equal(req.headers['authorization'], 'Bearer tok')
        spec.nil_value(req.headers['x-api-key'])
    end)
end)

return {
    __init = function()
        local failed = spec.finish()
        if failed > 0 then os.exit(1) end
        xthread.stop(0)
    end,
}
