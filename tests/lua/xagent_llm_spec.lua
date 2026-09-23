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

    spec.it('fails a stream that closes before any stop_reason', function()
        local got, done
        local dec = anthropic.new_decoder({
            on_error = function(m) got = m end, on_done = function() done = true end })
        dec:on_sse('message_start', pack({ type = 'message_start', message = { id = 'm' } }))
        dec:on_sse('content_block_start', pack({ type = 'content_block_start', index = 0,
            content_block = { type = 'tool_use', id = 't', name = 'Bash' } }))
        dec:on_sse('content_block_delta', pack({ type = 'content_block_delta', index = 0,
            delta = { type = 'input_json_delta', partial_json = '{"command":"rm' } }))
        dec:finish()   -- transport closed: no message_delta / message_stop
        spec.nil_value(done)
        spec.contains(got, 'before the response completed')
    end)
end)

spec.describe('api_log redaction', function()
    spec.it('masks every provider auth header', function()
        local api_log = require('xagent.llm.api_log')
        for _, h in ipairs({ 'Authorization', 'x-api-key', 'api-key', 'X-Goog-Api-Key', 'X-Auth-Token' }) do
            spec.truthy(api_log._is_secret_header(h), h)
        end
        spec.truthy(not api_log._is_secret_header('content-type'))
        local rec = api_log.begin({ url = 'u', method = 'POST', body = '{}',
            headers = { ['api-key'] = 'sk-secret', ['content-type'] = 'application/json' } })
        spec.equal(rec.headers['api-key'], '***redacted***')
        spec.equal(rec.headers['content-type'], 'application/json')
    end)
end)

spec.describe('common.json_encode', function()
    local common = require('xagent.llm.common')

    spec.it('sorts object keys whatever the insertion order', function()
        local a, b = {}, {}
        for _, k in ipairs({ 'type', 'input', 'id', 'name' }) do a[k] = k end
        for _, k in ipairs({ 'name', 'id', 'input', 'type' }) do b[k] = k end
        spec.equal(common.json_encode(a), '{"id":"id","input":"input","name":"name","type":"type"}')
        spec.equal(common.json_encode(b), common.json_encode(a))
    end)

    spec.it('follows json_pack for shapes and leaves', function()
        spec.equal(common.json_encode({ 1, 'x', true, 1.5 }), '[1,"x",true,1.5]')
        spec.equal(common.json_encode({}), '{}')
        spec.equal(common.json_encode(xutils.json_null), 'null')
        spec.equal(common.json_encode({ [1] = 'a', [3] = 'c' }), '{"1":"a","3":"c"}')
        spec.equal(common.json_encode({ s = 'a"b\n中' }), '{"s":' .. xutils.json_pack('a"b\n中') .. '}')
        local nested = { tools = { { name = 'Read', input_schema = { type = 'object', required = { 'p' } } } } }
        spec.equal(common.json_encode(nested),
            '{"tools":[{"input_schema":{"required":["p"],"type":"object"},"name":"Read"}]}')
    end)

    spec.it('fails like json_pack on invalid UTF-8 and non-encodable values', function()
        spec.nil_value(common.json_encode({ text = '\255' }))
        spec.nil_value(common.json_encode({ f = function() end }))
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

    spec.it('marks the system prompt and the newest message as cache breakpoints', function()
        local history = {
            { role = 'user', content = 'first' },
            { role = 'assistant', content = { { type = 'tool_use', id = 't1', name = 'Read', input = {} } } },
            { role = 'user', content = { { type = 'tool_result', tool_use_id = 't1', content = 'x' } } },
        }
        local req = anthropic.build_request({ api_key = 'k' }, { messages = history, system = 'SYS' })
        local body = xutils.json_unpack(req.body)
        spec.equal(body.system[1].text, 'SYS')
        spec.equal(body.system[1].cache_control.type, 'ephemeral')
        spec.equal(body.messages[3].content[1].cache_control.type, 'ephemeral')
        spec.nil_value(body.messages[1].cache_control)
        spec.nil_value(history[3].content[1].cache_control, 'the history must not be mutated')
    end)

    spec.it('skips thinking blocks and wraps string content for the breakpoint', function()
        local out = anthropic._cache_last_message({
            { role = 'assistant', content = { { type = 'text', text = 'a' }, { type = 'thinking', thinking = 't' } } },
        })
        spec.equal(out[1].content[1].cache_control.type, 'ephemeral')
        spec.nil_value(out[1].content[2].cache_control)
        out = anthropic._cache_last_message({ { role = 'user', content = 'hi' } })
        spec.equal(out[1].content[1].text, 'hi')
        spec.equal(out[1].content[1].cache_control.type, 'ephemeral')
    end)

    spec.it('sends no cache_control when prompt_cache is off', function()
        local req = anthropic.build_request({ api_key = 'k', prompt_cache = false },
            { messages = { { role = 'user', content = 'hi' } }, system = 'SYS' })
        spec.truthy(not req.body:find('cache_control', 1, true))
        spec.equal(xutils.json_unpack(req.body).system, 'SYS')
    end)

    spec.it('supports bearer auth style', function()
        local req = anthropic.build_request(
            { api_key = 'tok', auth_style = 'bearer' },
            { messages = { { role = 'user', content = 'hi' } } })
        spec.equal(req.headers['authorization'], 'Bearer tok')
        spec.nil_value(req.headers['x-api-key'])
    end)
end)

spec.describe('prompt_cache config', function()
    local config = require('xagent.config')
    spec.it('only an explicit off value disables caching', function()
        spec.equal(config.parse_prompt_cache('off'), false)
        spec.equal(config.parse_prompt_cache(' FALSE '), false)
        spec.equal(config.parse_prompt_cache(false), false)
        spec.nil_value(config.parse_prompt_cache(nil))
        spec.nil_value(config.parse_prompt_cache('on'))
    end)
end)

spec.describe('proxy config', function()
    local config = require('xagent.config')

    spec.it('prefers the profile proxy over the shared default', function()
        spec.equal(config.resolve_proxy('socks5://a:1', 'http://b:2'), 'socks5://a:1')
        spec.equal(config.resolve_proxy(nil, 'http://b:2'), 'http://b:2')
        spec.equal(config.resolve_proxy('  ', ' http://b:2 '), 'http://b:2')
    end)

    spec.it('lets a profile opt out of the shared default', function()
        spec.nil_value(config.resolve_proxy('direct', 'http://b:2'))
        spec.nil_value(config.resolve_proxy('NONE', 'http://b:2'))
        spec.nil_value(config.resolve_proxy(nil, nil))
    end)

    -- models.json edits, against a throwaway file (never the user's real one).
    local real_models_file = config.models_file
    local tmp_models = (os.getenv('TEMP') or os.getenv('TMPDIR') or '.') .. '/xagent_models_spec.json'
    local function with_tmp_models(fn)
        os.remove(tmp_models)
        config.models_file = function() return tmp_models end
        local ok, err = pcall(fn)
        config.models_file = real_models_file
        os.remove(tmp_models)
        if not ok then error(err, 0) end
    end
    local function find(key)
        for _, p in ipairs(config.load_profiles()) do if p.key == key then return p end end
    end

    spec.it('edits a user model in place and keeps its key', function()
        with_tmp_models(function()
            config.add_user_model({ base_url = 'https://api.openai.com/v1', model = 'm1', api_key = 'k1' })
            config.add_user_model({ base_url = 'https://x.test/anthropic', model = 'other' })
            local p = config.load_profiles()
            local key
            for _, q in ipairs(p) do if q.model == 'm1' then key = q.key end end
            spec.truthy(key)
            config.update_user_model(find(key).json_index,
                { model = 'm2', name = 'm2', proxy = 'socks5://127.0.0.1:1080', api_key = '' })
            local e = find(key)
            spec.equal(e.model, 'm2')
            spec.equal(e.name, 'm2')
            spec.equal(e.proxy, 'socks5://127.0.0.1:1080')
            spec.equal(e.api_key, 'k1')                 -- blank token = unchanged
            spec.equal(e.api_format, 'openai')          -- protocol kept
            spec.equal(e.auth_style, 'bearer')
            -- deleting an earlier model must not re-key this one
            for _, q in ipairs(config.load_profiles()) do
                if q.model == 'other' then config.delete_user_model(q.json_index) end
            end
            spec.equal(find(key).model, 'm2')
            config.update_user_model(find(key).json_index, { proxy = '' })
            spec.equal(find(key).proxy_own, nil)
        end)
    end)

    spec.it('keeps keys stable for models saved before ids existed', function()
        with_tmp_models(function()
            local f = assert(io.open(tmp_models, 'wb'))
            f:write(xutils.json_pack({ models = {
                { base_url = 'https://a.test/anthropic', model = 'a' },
                { base_url = 'https://b.test/anthropic', model = 'b' },
            } }))
            f:close()
            local key_b
            for _, q in ipairs(config.load_profiles()) do if q.model == 'b' then key_b = q.key end end
            for _, q in ipairs(config.load_profiles()) do
                if q.model == 'a' then config.delete_user_model(q.json_index) end
            end
            spec.equal(find(key_b).model, 'b')
        end)
    end)

    spec.it('overrides a cfg profile without touching the cfg, and resets', function()
        with_tmp_models(function()
            local base = config.load_profiles()[1]
            spec.equal(base.source, 'cfg')
            config.set_cfg_override(base.key, { model = 'edited-model', proxy = 'http://u:p@h:8080' })
            local e = find(base.key)
            spec.equal(e.model, 'edited-model')
            spec.equal(e.proxy, 'http://u:p@h:8080')
            spec.equal(e.base_url, base.base_url)
            spec.truthy(e.overridden)
            config.set_cfg_override(base.key, { proxy = 'direct' })   -- merges
            e = find(base.key)
            spec.equal(e.model, 'edited-model')
            spec.nil_value(e.proxy)
            config.clear_cfg_override(base.key)
            e = find(base.key)
            spec.equal(e.model, base.model)
            spec.nil_value(e.overridden)
        end)
    end)

    spec.it('reports a malformed proxy through on_error, not a raise', function()
        local got
        stream.request({ url = 'http://127.0.0.1:1/', proxy = 'localhost:1080' },
            { on_error = function(e) got = e end })
        spec.truthy(got and got:find('proxy config', 1, true))
    end)
end)

return {
    __init = function()
        local failed = spec.finish()
        if failed > 0 then os.exit(1) end
        xthread.stop(0)
    end,
}
