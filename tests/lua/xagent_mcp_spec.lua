-- Unit specs for the offline-testable MCP plumbing: tool-name mapping, JSON-RPC
-- framing, config validation/loading, Streamable-HTTP body parsing, the tool
-- adapter, and the in-memory registry. The network paths (handshake, tools/call
-- over sockets) are exercised end-to-end by scripts/xagent/test_mcp_loopback.lua.
-- Run via: bin/xnet tests/lua/xagent_mcp_spec.lua

package.path = 'scripts/?.lua;' .. package.path

local spec        = dofile('tests/lua/spec_helper.lua')
local names       = require('xagent.mcp.names')
local jsonrpc     = require('xagent.mcp.jsonrpc')
local config      = require('xagent.mcp.config')
local http        = require('xagent.mcp.transport_http')
local fetch_tools = require('xagent.mcp.fetch_tools')
local mcp_reg     = require('xagent.mcp.registry')
local xutils      = require('xutils')
local fs          = dofile('scripts/core/share/xfs.lua')

spec.describe('mcp.names', function()
    spec.it('builds mcp__server__tool', function()
        spec.equal(names.build('github', 'create_issue'), 'mcp__github__create_issue')
    end)

    spec.it('normalizes illegal chars to underscore', function()
        spec.equal(names.build('my.server', 'do/it now'), 'mcp__my_server__do_it_now')
    end)

    spec.it('is_mcp recognizes the prefix', function()
        spec.truthy(names.is_mcp('mcp__a__b'))
        spec.equal(names.is_mcp('Read'), false)
        spec.equal(names.is_mcp(nil), false)
    end)

    spec.it('parses back to (server, tool), rejoining __ in the tool half', function()
        local s, t = names.parse('mcp__srv__do__thing')
        spec.equal(s, 'srv')
        spec.equal(t, 'do__thing')
    end)

    spec.it('parse returns nil for non-mcp names', function()
        spec.nil_value(names.parse('Read'))
        spec.nil_value(names.parse('mcp__onlyserver'))
    end)
end)

spec.describe('mcp.jsonrpc', function()
    spec.it('next_id is monotonic', function()
        local a, b = jsonrpc.next_id(), jsonrpc.next_id()
        spec.truthy(b > a)
    end)

    spec.it('builds a request envelope', function()
        local m = jsonrpc.request(5, 'tools/list', { x = 1 })
        spec.equal(m.jsonrpc, '2.0')
        spec.equal(m.id, 5)
        spec.equal(m.method, 'tools/list')
        spec.equal(m.params.x, 1)
    end)

    spec.it('a notification carries no id', function()
        local m = jsonrpc.notification('notifications/initialized')
        spec.nil_value(m.id)
        spec.equal(m.method, 'notifications/initialized')
    end)

    spec.it('encode round-trips through json', function()
        local s = assert(jsonrpc.encode(jsonrpc.request(1, 'ping')))
        local d = xutils.json_unpack(s)
        spec.equal(d.method, 'ping')
    end)

    spec.it('parse_response returns result on success', function()
        local r, err = jsonrpc.parse_response({ jsonrpc = '2.0', id = 1, result = { ok = true } })
        spec.nil_value(err)
        spec.equal(r.ok, true)
    end)

    spec.it('parse_response surfaces a JSON-RPC error', function()
        local r, err = jsonrpc.parse_response({ jsonrpc = '2.0', id = 1,
            error = { code = -32601, message = 'method not found' } })
        spec.nil_value(r)
        spec.contains(err, 'method not found')
        spec.contains(err, '32601')
    end)
end)

spec.describe('mcp.config.validate', function()
    spec.it('infers stdio when only a command is present', function()
        local c = assert(config.validate('x', { command = 'npx', args = { '-y', 'srv' } }))
        spec.equal(c.type, 'stdio')
        spec.equal(c.command, 'npx')
        spec.equal(c.args[2], 'srv')
    end)

    spec.it('infers http when a url is present', function()
        local c = assert(config.validate('x', { url = 'https://h/mcp' }))
        spec.equal(c.type, 'http')
        spec.equal(c.url, 'https://h/mcp')
    end)

    spec.it('accepts explicit sse with headers', function()
        local c = assert(config.validate('x', { type = 'sse', url = 'https://h/sse',
            headers = { Authorization = 'Bearer t' } }))
        spec.equal(c.type, 'sse')
        spec.equal(c.headers.Authorization, 'Bearer t')
    end)

    spec.it('rejects stdio without a command', function()
        local c, err = config.validate('x', { type = 'stdio' })
        spec.nil_value(c)
        spec.contains(err, 'command')
    end)

    spec.it('rejects http without a url', function()
        local c, err = config.validate('x', { type = 'http' })
        spec.nil_value(c)
        spec.contains(err, 'url')
    end)

    spec.it('rejects an unknown transport', function()
        local c, err = config.validate('x', { type = 'carrier-pigeon', url = 'x' })
        spec.nil_value(c)
        spec.contains(err, 'unsupported transport')
    end)

    spec.it('rejects non-string header values', function()
        local c, err = config.validate('x', { url = 'https://h', headers = { A = 1 } })
        spec.nil_value(c)
        spec.contains(err, 'headers')
    end)
end)

spec.describe('mcp.config.extract', function()
    spec.it('collects valid servers and records errors for bad ones', function()
        local errors = {}
        local out = config.extract({ mcpServers = {
            good = { url = 'https://h/mcp' },
            bad = { type = 'stdio' },          -- missing command
        } }, 'project', errors)
        spec.truthy(out.good)
        spec.equal(out.good.scope, 'project')
        spec.nil_value(out.bad)
        spec.equal(#errors, 1)
    end)

    spec.it('returns empty when mcpServers is absent', function()
        local errors = {}
        local out = config.extract({}, 'user', errors)
        spec.equal(next(out), nil)
    end)
end)

spec.describe('mcp.config.load (project .mcp.json)', function()
    spec.it('reads <cwd>/.mcp.json with project scope', function()
        local dir = (fs.home():gsub('[/\\]+$', '')) .. '/.xagent/_mcp_spec_tmp'
        fs.mkdirp(dir)
        assert(fs.write_file(dir .. '/.mcp.json',
            '{"mcpServers":{"demo":{"url":"https://example/mcp"}}}'))
        local servers, errors = config.load(dir)
        spec.truthy(servers.demo, 'demo server loaded')
        spec.equal(servers.demo.type, 'http')
        spec.equal(servers.demo.scope, 'project')
        os.remove(dir .. '/.mcp.json')
        os.remove(dir)
    end)
end)

spec.describe('mcp.transport_http.parse_body', function()
    spec.it('parses a single application/json response', function()
        local objs = assert(http.parse_body('application/json',
            '{"jsonrpc":"2.0","id":1,"result":{"ok":true}}'))
        spec.equal(#objs, 1)
        spec.equal(objs[1].id, 1)
    end)

    spec.it('parses a JSON-RPC batch array', function()
        local objs = assert(http.parse_body('application/json',
            '[{"jsonrpc":"2.0","id":1,"result":1},{"jsonrpc":"2.0","id":2,"result":2}]'))
        spec.equal(#objs, 2)
        spec.equal(objs[2].id, 2)
    end)

    spec.it('extracts JSON-RPC messages from an SSE stream', function()
        local body = 'event: message\ndata: {"jsonrpc":"2.0","id":7,"result":{"v":1}}\n\n'
        local objs = assert(http.parse_body('text/event-stream', body))
        spec.equal(#objs, 1)
        spec.equal(objs[1].id, 7)
    end)

    spec.it('returns an empty list for an empty body', function()
        local objs = assert(http.parse_body('application/json', ''))
        spec.equal(#objs, 0)
    end)

    spec.it('errors on a non-JSON body', function()
        local objs, err = http.parse_body('application/json', 'not json')
        spec.nil_value(objs)
        spec.contains(err, 'invalid JSON')
    end)
end)

spec.describe('mcp.fetch_tools.stringify_content', function()
    spec.it('joins text blocks', function()
        spec.equal(fetch_tools.stringify_content({ { type = 'text', text = 'a' }, { type = 'text', text = 'b' } }), 'a\nb')
    end)

    spec.it('summarizes image blocks', function()
        local s = fetch_tools.stringify_content({ { type = 'image', mimeType = 'image/png', data = 'AAAA' } })
        spec.contains(s, 'image: image/png')
    end)

    spec.it('uses resource text or a uri placeholder', function()
        spec.equal(fetch_tools.stringify_content({ { type = 'resource', resource = { text = 'hi' } } }), 'hi')
        spec.contains(fetch_tools.stringify_content({ { type = 'resource', resource = { uri = 'mem://x' } } }), 'mem://x')
    end)
end)

spec.describe('mcp.fetch_tools.build_adapter', function()
    local function fake_client()
        local c = { name = 'srv', calls = {} }
        function c:call_tool(tool, args)
            self.calls[#self.calls + 1] = { tool = tool, args = args }
            return { content = { { type = 'text', text = 'ok:' .. tostring(args.x) } }, isError = false }
        end
        return c
    end

    spec.it('names the tool and forwards to the server tool name', function()
        local c = fake_client()
        local t = fetch_tools.build_adapter(c, { name = 'do_thing', description = 'd', inputSchema = { type = 'object' } })
        spec.equal(t.name, 'mcp__srv__do_thing')
        spec.equal(t.is_read_only(), false)
        local r = t.call({ x = '1' })
        spec.equal(r.content, 'ok:1')
        spec.equal(c.calls[1].tool, 'do_thing')   -- server gets its OWN name
    end)

    spec.it('honors the readOnlyHint annotation', function()
        local t = fetch_tools.build_adapter(fake_client(),
            { name = 'peek', annotations = { readOnlyHint = true } })
        spec.equal(t.is_read_only(), true)
    end)

    spec.it('maps a server failure to an is_error result', function()
        local c = { name = 'srv' }
        function c:call_tool() return nil, 'boom' end
        local t = fetch_tools.build_adapter(c, { name = 'x' })
        local r = t.call({})
        spec.equal(r.is_error, true)
        spec.contains(r.content, 'boom')
    end)

    spec.it('falls back to an object schema when none is given', function()
        local t = fetch_tools.build_adapter(fake_client(), { name = 'x' })
        spec.equal(t.input_schema.type, 'object')
    end)
end)

spec.describe('mcp.registry', function()
    spec.it('stores and filters by status', function()
        mcp_reg.clear()
        mcp_reg.set('a', { name = 'a', status = 'connected' }, { {}, {} })
        mcp_reg.set('b', { name = 'b', status = 'failed' }, {})
        spec.equal(#mcp_reg.connections(), 2)
        spec.equal(#mcp_reg.connected(), 1)
        spec.equal(#mcp_reg.get('a').tools, 2)
        mcp_reg.clear()
        spec.equal(#mcp_reg.connections(), 0)
    end)
end)

return {
    __tick_ms = 1000,
    __thread_handle = function() end,
    __init = function()
        local failed = spec.finish()
        if failed > 0 then os.exit(1) end
        xthread.stop(0)
    end,
}
