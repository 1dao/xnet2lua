-- xagent/test_tls_probe.lua — keyless TLS reachability probe.
--
-- Opens a real HTTPS connection to the configured endpoint and POSTs a tiny
-- request with a bogus key. We don't care about the body: getting ANY HTTP
-- status back proves DNS + TCP + TLS handshake + CA verification + the network
-- path all work, and that only auth remains. A 401/403 is the expected, SUCCESS
-- outcome here. Times out after ~8s so it never hangs.
--
-- Run: bin/xnet scripts/xagent/test_tls_probe.lua
--   override URL with URL=https://host/path on argv or ANTHROPIC_BASE_URL env.

package.path = 'scripts/?.lua;' .. package.path
local stream = dofile('scripts/core/share/xhttp_stream.lua')
local xutils = require('xutils')

local argv = {}
if type(arg) == 'table' then
    for _, it in ipairs(arg) do
        local k, v = tostring(it):match('^([%w_]+)=(.*)$'); if k then argv[k] = v end
    end
end
local base = argv.URL or os.getenv('ANTHROPIC_BASE_URL') or 'https://api.anthropic.com'
base = base:gsub('/+$', '')
local url = base .. '/v1/messages'

local function out(s) io.write(s); io.flush() end

local done = false
local ticks = 0
local TIMEOUT_TICKS = 800   -- ~8s at __tick_ms=10

local function stop(code, msg)
    if done then return end
    done = true
    out('[tls-probe] ' .. msg .. '\n')
    xthread.stop(code)
end

local function __init()
    assert(xnet.init())
    out('[tls-probe] connecting ' .. url .. ' ...\n')
    stream.request({
        url = url,
        method = 'POST',
        headers = {
            ['x-api-key'] = 'sk-probe-invalid',
            ['anthropic-version'] = '2023-06-01',
            ['content-type'] = 'application/json',
        },
        body = xutils.json_pack({ model = 'probe', max_tokens = 1,
            messages = { { role = 'user', content = 'x' } } }),
        verify = true,
    }, {
        on_headers = function(status, headers)
            stop(0, string.format(
                'OK — TLS+CA+network reachable; HTTP %d from server (auth is the only thing left)',
                status))
        end,
        on_error = function(e) stop(1, 'FAIL — ' .. tostring(e)) end,
        on_done = function() if not done then stop(1, 'FAIL — closed with no HTTP response') end end,
    })
end

local function __update()
    if done then return end
    ticks = ticks + 1
    if ticks >= TIMEOUT_TICKS then stop(1, 'FAIL — timeout (no response in ~8s; network blocked?)') end
end

return { __tick_ms = 10, __thread_handle = function() end, __init = __init, __update = __update,
         __uninit = function() xnet.uninit() end }
