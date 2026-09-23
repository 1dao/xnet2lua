-- Unit specs for the OpenAI Chat Completions codec: history → request
-- translation, and chunk stream → Anthropic-shaped result. Offline and
-- deterministic; the live round-trip is scripts/xagent/test_stream.lua
-- API_FORMAT=openai (needs a key).
-- Run via: bin/xnet tests/lua/xagent_openai_spec.lua

package.path = 'scripts/?.lua;' .. package.path

local spec = dofile('tests/lua/spec_helper.lua')
local xutils = require('xutils')
local openai = require('xagent.llm.openai')
local provider = require('xagent.llm.provider')
local config = require('xagent.config')

local function pack(t) return xutils.json_pack(t) end

local function chunk(delta, finish_reason, extra)
    local ev = { id = 'chatcmpl_1', object = 'chat.completion.chunk',
                 choices = { { index = 0, delta = delta, finish_reason = finish_reason } } }
    for k, v in pairs(extra or {}) do ev[k] = v end
    return pack(ev)
end

-- Drive a decoder with a list of SSE data payloads; return (result, err, seen).
local function decode(payloads)
    local result, err
    local seen = { text = {}, tools = {}, input = {} }
    local dec = openai.new_decoder({
        on_text = function(t) seen.text[#seen.text + 1] = t end,
        on_tool_use_start = function(id, name) seen.tools[#seen.tools + 1] = name .. ':' .. id end,
        on_tool_input = function(id, frag) seen.input[#seen.input + 1] = id .. '=' .. frag end,
        on_done = function(r) result = r end,
        on_error = function(m) err = m end,
    })
    for _, d in ipairs(payloads) do dec:on_sse(nil, d) end
    dec:finish()
    return result, err, seen
end

spec.describe('openai.endpoint', function()
    spec.it('accepts every common base-url shape', function()
        spec.equal(openai.endpoint(nil), 'https://api.openai.com/v1/chat/completions')
        spec.equal(openai.endpoint('https://api.openai.com/v1/'), 'https://api.openai.com/v1/chat/completions')
        spec.equal(openai.endpoint('https://api.deepseek.com'), 'https://api.deepseek.com/v1/chat/completions')
        spec.equal(openai.endpoint('https://open.bigmodel.cn/api/paas/v4'),
            'https://open.bigmodel.cn/api/paas/v4/chat/completions')
        spec.equal(openai.endpoint('https://x.test/v1/chat/completions'), 'https://x.test/v1/chat/completions')
        -- a query string stays at the end instead of swallowing the path
        spec.equal(openai.endpoint('https://r.openai.azure.com/openai/deployments/d/chat/completions?api-version=2024-10-21'),
            'https://r.openai.azure.com/openai/deployments/d/chat/completions?api-version=2024-10-21')
        spec.equal(openai.endpoint('https://x.test/v1/?api-version=1'), 'https://x.test/v1/chat/completions?api-version=1')
        spec.equal(openai.endpoint('https://x.test?k=1'), 'https://x.test/v1/chat/completions?k=1')
    end)
end)

spec.describe('openai.build_request', function()
    spec.it('uses bearer auth, streams with usage, and maps tools', function()
        local req = openai.build_request(
            { api_key = 'sk-test', base_url = 'https://api.example.com/v1', model = 'gpt-4.1' },
            { messages = { { role = 'user', content = 'hi' } }, system = 'be brief', max_tokens = 100,
              tools = { { name = 'Read', description = 'read a file',
                          input_schema = { type = 'object', properties = { file_path = { type = 'string' } } } } } })
        spec.equal(req.url, 'https://api.example.com/v1/chat/completions')
        spec.equal(req.headers['authorization'], 'Bearer sk-test')
        spec.nil_value(req.headers['x-api-key'])
        local body = xutils.json_unpack(req.body)
        spec.equal(body.stream, true)
        spec.equal(body.stream_options.include_usage, true)
        spec.equal(body.max_tokens, 100)
        spec.equal(body.messages[1].role, 'system')
        spec.equal(body.messages[1].content, 'be brief')
        spec.equal(body.messages[2].content, 'hi')
        spec.equal(body.tools[1].type, 'function')
        spec.equal(body.tools[1]['function'].name, 'Read')
        spec.equal(body.tools[1]['function'].parameters.properties.file_path.type, 'string')
    end)

    spec.it('uses max_completion_tokens for reasoning models', function()
        local req = openai.build_request({ api_key = 'k', model = 'o3-mini' },
            { messages = { { role = 'user', content = 'hi' } }, max_tokens = 50 })
        local body = xutils.json_unpack(req.body)
        spec.equal(body.max_completion_tokens, 50)
        spec.nil_value(body.max_tokens)
    end)

    spec.it('omits tools when there are none', function()
        local req = openai.build_request({ api_key = 'k', model = 'm' },
            { messages = { { role = 'user', content = 'hi' } }, tools = {} })
        spec.nil_value(xutils.json_unpack(req.body).tools)
    end)
end)

spec.describe('openai.convert_messages', function()
    spec.it('maps a tool round-trip onto tool_calls + role=tool', function()
        local msgs = openai.convert_messages({
            { role = 'user', content = 'read x' },
            { role = 'assistant', content = {
                { type = 'thinking', thinking = 'need the file' },
                { type = 'tool_use', id = 'c1', name = 'Read', input = { file_path = 'x' } },
                { type = 'tool_use', id = 'c2', name = 'Read', input = {} },
            } },
            { role = 'user', content = {
                { type = 'tool_result', tool_use_id = 'c1', content = 'data' },
                { type = 'tool_result', tool_use_id = 'c2', content = 'nope', is_error = true },
                { type = 'text', text = 'also this' },
            } },
        }, nil)
        spec.equal(#msgs, 5)
        local a = msgs[2]
        spec.equal(a.role, 'assistant')
        spec.equal(a.content, xutils.json_null)
        spec.equal(a.reasoning_content, 'need the file')
        spec.equal(#a.tool_calls, 2)
        spec.equal(a.tool_calls[1].id, 'c1')
        spec.equal(xutils.json_unpack(a.tool_calls[1]['function'].arguments).file_path, 'x')
        spec.equal(a.tool_calls[2]['function'].arguments, '{}')
        spec.equal(msgs[3].role, 'tool')
        spec.equal(msgs[3].tool_call_id, 'c1')
        spec.equal(msgs[3].content, 'data')
        spec.equal(msgs[4].content, 'Error: nope')
        spec.equal(msgs[5].role, 'user')
        spec.equal(msgs[5].content, 'also this')
        -- the whole thing must still encode (content = json null)
        spec.contains(pack({ messages = msgs }), '"content":null')
    end)

    spec.it('turns base64 images into data-url image parts', function()
        local msgs = openai.convert_messages({
            { role = 'user', content = {
                { type = 'image', source = { type = 'base64', media_type = 'image/png', data = 'QUJD' } },
                { type = 'text', text = 'what is this' },
            } },
        })
        local parts = msgs[1].content
        spec.equal(parts[1].type, 'image_url')
        spec.equal(parts[1].image_url.url, 'data:image/png;base64,QUJD')
        spec.equal(parts[2].text, 'what is this')
    end)

    spec.it('drops signed (Anthropic) thinking and honours echo_reasoning=false', function()
        local hist = { { role = 'assistant', content = {
            { type = 'thinking', thinking = 'x', signature = 'sig' },
            { type = 'text', text = 'ok' } } } }
        spec.nil_value(openai.convert_messages(hist)[1].reasoning_content)
        hist[1].content[1].signature = nil
        spec.equal(openai.convert_messages(hist)[1].reasoning_content, 'x')
        spec.nil_value(openai.convert_messages(hist, nil, { echo_reasoning = false })[1].reasoning_content)
    end)
end)

spec.describe('openai decoder', function()
    spec.it('reassembles text, reasoning, parallel tool calls and usage', function()
        local r, err, seen = decode({
            chunk({ role = 'assistant', reasoning_content = 'let me ' }),
            chunk({ reasoning_content = 'look' }),
            chunk({ content = 'Sure' }),
            chunk({ tool_calls = {
                { index = 0, id = 'c1', type = 'function', ['function'] = { name = 'Read', arguments = '' } },
            } }),
            chunk({ tool_calls = { { index = 0, ['function'] = { arguments = '{"file_path":' } } } }),
            chunk({ tool_calls = {
                { index = 1, id = 'c2', type = 'function', ['function'] = { name = 'Glob', arguments = '{"pattern":"*"}' } },
            } }),
            chunk({ tool_calls = { { index = 0, ['function'] = { arguments = '"a.lua"}' } } } }),
            chunk({}, 'tool_calls'),
            pack({ id = 'chatcmpl_1', choices = {}, usage = {
                prompt_tokens = 100, completion_tokens = 20,
                prompt_tokens_details = { cached_tokens = 60 } } }),
            '[DONE]',
        })
        spec.nil_value(err)
        spec.equal(table.concat(seen.text), 'Sure')
        spec.equal(seen.tools[1], 'Read:c1')
        spec.equal(seen.tools[2], 'Glob:c2')
        spec.equal(r.stop_reason, 'tool_use')
        spec.equal(r.id, 'chatcmpl_1')
        local c = r.message.content
        spec.equal(#c, 4)
        spec.equal(c[1].type, 'thinking')
        spec.equal(c[1].thinking, 'let me look')
        spec.equal(c[2].text, 'Sure')
        spec.equal(c[3].name, 'Read')
        spec.equal(c[3].input.file_path, 'a.lua')
        spec.equal(c[4].input.pattern, '*')
        spec.equal(r.usage.input_tokens, 40)
        spec.equal(r.usage.cache_read_input_tokens, 60)
        spec.equal(r.usage.output_tokens, 20)
    end)

    spec.it('maps finish reasons and ignores null content', function()
        local r = decode({ pack({ id = 'x', choices = { { index = 0,
            delta = { content = xutils.json_null } } } }),
            chunk({ content = 'cut' }), chunk({}, 'length'), '[DONE]' })
        spec.equal(r.stop_reason, 'max_tokens')
        spec.equal(#r.message.content, 1)
        r = decode({ chunk({ content = 'done' }), chunk({}, 'stop') })
        spec.equal(r.stop_reason, 'end_turn')
    end)

    spec.it('trusts emitted tool calls over finish_reason=stop', function()
        local r = decode({
            chunk({ tool_calls = { { index = 0, id = 't', ['function'] = { name = 'Ls', arguments = '{}' } } } }),
            chunk({}, 'stop'), '[DONE]' })
        spec.equal(r.stop_reason, 'tool_use')
    end)

    spec.it('keeps unparsable arguments as _raw/_error', function()
        local r = decode({
            chunk({ tool_calls = { { index = 0, id = 't', ['function'] = { name = 'Ls', arguments = '{"a":' } } } }),
            chunk({}, 'tool_calls'), '[DONE]' })
        spec.equal(r.message.content[1].input._raw, '{"a":')
        spec.truthy(r.message.content[1].input._error)
    end)

    spec.it('fails a stream cut off before finish_reason instead of running its tools', function()
        local r, err = decode({
            chunk({ tool_calls = { { index = 0, id = 't', ['function'] = { name = 'Bash', arguments = '{"command":"rm' } } } }),
        })
        spec.nil_value(r)
        spec.contains(err, 'before the response completed')
        r, err = decode({ chunk({ content = 'half an ans' }) })
        spec.nil_value(r)
        spec.contains(err, 'before the response completed')
        -- [DONE] alone is a server-declared end, and counts as complete
        r, err = decode({ chunk({ content = 'ok' }), '[DONE]' })
        spec.nil_value(err)
        spec.equal(r.stop_reason, 'end_turn')
    end)

    spec.it('flags missing usage instead of reporting zeros', function()
        local r = decode({ chunk({ content = 'hi' }), chunk({}, 'stop'), '[DONE]' })
        spec.truthy(r.usage_missing)
        r = decode({ chunk({ content = 'hi' }), chunk({}, 'stop'),
            pack({ choices = {}, usage = { prompt_tokens = 0, completion_tokens = 0 } }), '[DONE]' })
        spec.nil_value(r.usage_missing)
    end)

    spec.it('keeps refusal text as visible content', function()
        local r, err, seen = decode({ chunk({ refusal = "I can't " }), chunk({ refusal = 'help with that.' }),
            chunk({}, 'stop'), '[DONE]' })
        spec.nil_value(err)
        spec.equal(table.concat(seen.text), "I can't help with that.")
        spec.equal(r.message.content[1].text, "I can't help with that.")
        spec.equal(r.stop_reason, 'refusal')
    end)

    spec.it('surfaces in-stream errors and empty streams', function()
        local _, err = decode({ pack({ error = { message = 'rate limited' } }) })
        spec.equal(err, 'rate limited')
        _, err = decode({})
        spec.contains(err, 'no response from model')
    end)
end)

spec.describe('gemini thought signatures', function()
    local GEMINI = { base_url = 'https://generativelanguage.googleapis.com/v1beta/openai/',
                     model = 'gemini-3.5-flash-lite' }
    local SIG = { google = { thought_signature = 'sig-abc' } }

    -- The shape Gemini actually streams: no `index`, one whole call per delta,
    -- the signature only on the first call of the step.
    local function gemini_stream()
        return decode({
            chunk({ role = 'assistant', tool_calls = { { id = 'call_1', type = 'function',
                extra_content = SIG,
                ['function'] = { name = 'get_weather', arguments = '{"city":"Paris"}' } } } }),
            chunk({ role = 'assistant', tool_calls = { { id = 'call_2', type = 'function',
                ['function'] = { name = 'get_weather', arguments = '{"city":"Tokyo"}' } } } }),
            chunk({ role = 'assistant' }, 'stop'),
            '[DONE]',
        })
    end

    spec.it('keeps index-less parallel calls apart and captures the signature', function()
        local r, err = gemini_stream()
        spec.nil_value(err)
        local c = r.message.content
        spec.equal(#c, 2)
        spec.equal(c[1].id, 'call_1')
        spec.equal(c[1].input.city, 'Paris')
        spec.equal(c[2].id, 'call_2')
        spec.equal(c[2].input.city, 'Tokyo')
        spec.equal(c[1].extra_content.google.thought_signature, 'sig-abc')
        spec.nil_value(c[2].extra_content)
        spec.equal(r.stop_reason, 'tool_use')
    end)

    spec.it('continues an index-less call from id-less fragments', function()
        local r = decode({
            chunk({ tool_calls = { { id = 'c1', ['function'] = { name = 'Read', arguments = '{"file_path":' } } } }),
            chunk({ tool_calls = { { ['function'] = { arguments = '"a.lua"}' } } } }),
            chunk({}, 'tool_calls'), '[DONE]',
        })
        spec.equal(#r.message.content, 1)
        spec.equal(r.message.content[1].input.file_path, 'a.lua')
    end)

    spec.it('echoes the signature back to Gemini on the call that carried it', function()
        local r = gemini_stream()
        local msgs = openai.convert_messages({ r.message }, nil, GEMINI)
        local calls = msgs[1].tool_calls
        spec.equal(calls[1].extra_content.google.thought_signature, 'sig-abc')
        spec.nil_value(calls[2].extra_content)
    end)

    spec.it('uses the placeholder when a Gemini step has no signature', function()
        local msgs = openai.convert_messages({ { role = 'assistant', content = {
            { type = 'tool_use', id = 'a', name = 'x', input = {} },
            { type = 'tool_use', id = 'b', name = 'x', input = {} } } } }, nil, GEMINI)
        local calls = msgs[1].tool_calls
        spec.equal(calls[1].extra_content.google.thought_signature, 'skip_thought_signature_validator')
        spec.nil_value(calls[2].extra_content)
    end)

    spec.it('never sends the field to other endpoints', function()
        local r = gemini_stream()
        local msgs = openai.convert_messages({ r.message }, nil,
            { base_url = 'https://api.openai.com/v1', model = 'gpt-4.1' })
        spec.nil_value(msgs[1].tool_calls[1].extra_content)
        -- nor to Anthropic, which rejects unknown block fields
        local anthropic = require('xagent.llm.anthropic')
        local req = anthropic.build_request({ api_key = 'k' }, { messages = { r.message } })
        spec.nil_value(req.body:find('extra_content', 1, true))
        spec.equal(r.message.content[1].extra_content.google.thought_signature, 'sig-abc')  -- history untouched
    end)

    spec.it("reads Gemini's array-wrapped HTTP error", function()
        local common = require('xagent.llm.common')
        local msg = common.format_http_error(400,
            '[{"error":{"code":400,"message":"Function call is missing a thought_signature","status":"INVALID_ARGUMENT"}}]')
        spec.equal(msg, 'HTTP 400: Function call is missing a thought_signature')
    end)
end)

spec.describe('provider + config', function()
    spec.it('dispatches on api_format', function()
        spec.equal(provider.codec({ api_format = 'openai' }), openai)
        spec.equal(provider.codec({}), require('xagent.llm.anthropic'))
        local got
        provider.stream_message({ api_format = 'bogus' }, {}, { on_error = function(m) got = m end })
        spec.contains(got, 'unknown api_format')
    end)

    spec.it('infers format and auth style from the url', function()
        spec.equal(config.infer_api_format('https://api.openai.com/v1'), 'openai')
        spec.equal(config.infer_api_format('https://api.deepseek.com/anthropic'), 'anthropic')
        spec.equal(config.infer_api_format('https://x.test/v1/chat/completions'), 'openai')
        spec.equal(config.infer_api_format('https://api.anthropic.com'), 'anthropic')
        spec.equal(config.infer_auth_style('https://api.openai.com/v1'), 'bearer')
        spec.equal(config.infer_auth_style('https://r.openai.azure.com/openai', 'openai'), 'api-key')
        spec.equal(config.infer_auth_style('https://api.deepseek.com', 'anthropic'), 'x-api-key')
    end)
end)

return {
    __init = function()
        local failed = spec.finish()
        if failed > 0 then os.exit(1) end
        xthread.stop(0)
    end,
}
