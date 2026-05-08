-- xadmin_main.lua - admin web console main thread.
-- Owns: xnet listener, NATS client, HTTP server, peer discovery table,
-- and the single-coroutine script-execution dispatcher.
--
-- Launch with a unique SERVER_NAME, e.g.:
--   bin/xnet scripts/xadmin/xadmin_main.lua SERVER_NAME=xadmin1
--   bin/xnet scripts/xadmin/xadmin_main.lua SERVER_NAME=xadmin2 XADMIN_PORT=18081
--
-- Cross-thread protocol (see xlua/lua_xthread.c top-of-file comment):
--   * incoming NATS RPCs arrive as RPC messages and are dispatched through the
--     coroutine wrapper below (xnats_business.lua pattern).
--   * incoming POSTs from xadmin HTTP workers are plain fire-and-forget posts
--     carrying the worker thread id and a request id; replies go back via
--     xthread.post.

local xnats = dofile('scripts/core/server/xnats.lua')
local xhttp = dofile('scripts/core/server/xhttp.lua')
local xutils = require('xutils')
local router = dofile('scripts/core/share/xrouter.lua')
router.set_log_prefix('XADMIN-MAIN')

local CONFIG_FILE = 'xnet.cfg'
local ok_cfg, cfg_err = xutils.load_config(CONFIG_FILE)
if not ok_cfg then
    io.stderr:write('[XADMIN-MAIN] config not loaded: ' .. tostring(cfg_err) .. '\n')
end

local SERVER_NAME = XNET_PROCESS_NAME or xutils.get_config('SERVER_NAME', 'xadmin1')
local HTTP_HOST = xutils.get_config('XADMIN_HOST', '127.0.0.1')
local HTTP_PORT = tonumber(xutils.get_config('XADMIN_PORT', '18090')) or 18090
local NATS_HOST = xutils.get_config('NATS_HOST', '127.0.0.1')
local NATS_PORT = tonumber(xutils.get_config('NATS_PORT', '4222')) or 4222
local NATS_PREFIX = xutils.get_config('NATS_PREFIX', 'xnet.test')
local TOKEN = xutils.get_config('XADMIN_TOKEN', '')
local HEARTBEAT_MS = tonumber(xutils.get_config('XADMIN_HEARTBEAT_MS', '5000')) or 5000
local PEER_TTL_MS = tonumber(xutils.get_config('XADMIN_PEER_TTL_MS', '15000')) or 15000

local function to_bool(v, default)
    if v == nil then return default end
    if v == true or v == 1 or v == '1' or v == 'true' or v == 'yes' or v == 'on' then return true end
    if v == false or v == 0 or v == '0' or v == 'false' or v == 'no' or v == 'off' then return false end
    return default
end

local HTTPS = to_bool(xutils.get_config('XADMIN_HTTPS', '0'), false)
local CERT = xutils.get_config('HTTPS_CERT', 'demo/certs/server.crt')
local KEY  = xutils.get_config('HTTPS_KEY',  'demo/certs/server.key')
local KEY_PASSWORD = xutils.get_config('HTTPS_KEY_PASSWORD', '')

local NATS_ID = xthread.NATS
local MAIN_ID = xthread.MAIN

function xthread.register(pt, h) return router.register(pt, h) end

local function pack_values(...)
    return { n = select('#', ...), ... }
end

-- ---------------------------------------------------------------------------
-- Peer discovery -- each xadmin instance heartbeats on NATS and tracks who
-- it has heard from. peers[name] = last_seen_ms.
-- ---------------------------------------------------------------------------

local peers = {}

local function now_ms()
    return xtimer.now_ms()
end

local function note_peer(name)
    name = tostring(name or '')
    if name == '' then return end
    peers[name] = now_ms()
end

local function alive_peers()
    local cutoff = now_ms() - PEER_TTL_MS
    local out = {}
    for name, last in pairs(peers) do
        if last >= cutoff then
            out[#out + 1] = { name = name, last_seen_ms = last }
        end
    end
    table.sort(out, function(a, b) return a.name < b.name end)
    return out
end

xthread.register('xadmin_announce', function(name)
    if name and name ~= SERVER_NAME then
        note_peer(name)
    end
end)

-- ---------------------------------------------------------------------------
-- Sandbox script execution (used by both local exec and remote NATS exec).
-- ---------------------------------------------------------------------------

local _IS_LUA51 = (_VERSION == 'Lua 5.1')

local function compile(src, env)
    if _IS_LUA51 then
        local fn, err = loadstring(src, '=admin')
        if fn then setfenv(fn, env) end
        return fn, err
    end
    return load(src, '=admin', 't', env)
end

local function tostring_safe(v)
    local ok, s = pcall(tostring, v)
    if ok then return s end
    return '<tostring error>'
end

local function exec_script(src)
    local out = {}
    local env = setmetatable({
        print = function(...)
            local n = select('#', ...)
            local parts = {}
            for i = 1, n do parts[i] = tostring_safe(select(i, ...)) end
            out[#out + 1] = table.concat(parts, '\t')
        end,
    }, { __index = _G })

    local fn, perr = compile(src, env)
    if not fn then
        return false, '', 'compile error: ' .. tostring(perr)
    end

    local results = pack_values(pcall(fn))
    local ok = results[1]
    if not ok then
        return false, table.concat(out, '\n'), 'runtime error: ' .. tostring_safe(results[2])
    end

    local rets = {}
    for i = 2, results.n do rets[#rets + 1] = tostring_safe(results[i]) end
    return true, table.concat(out, '\n'), table.concat(rets, '\t')
end

-- ---------------------------------------------------------------------------
-- NATS RPC handler: another xadmin asks us to run a script locally.
-- Returns ok, stdout, result_or_err.
-- ---------------------------------------------------------------------------

xthread.register('xadmin_remote_exec', function(src)
    return exec_script(tostring(src or ''))
end)

-- ---------------------------------------------------------------------------
-- Worker -> main: peer query and exec dispatch.
-- ---------------------------------------------------------------------------

xthread.register('xadmin_query_peers', function(reply_to, request_id)
    local body, err = xutils.json_pack({
        self = SERVER_NAME,
        peers = alive_peers(),
        token_required = TOKEN ~= '',
    })
    if not body then body = '{"self":"' .. SERVER_NAME .. '","peers":[]}' end
    xthread.post(reply_to, 'xadmin_peers_reply', request_id, body)
end)

xthread.register('xadmin_run_script', function(reply_to, request_id, target, script)
    target = tostring(target or '')
    script = tostring(script or '')
    if target == '' or target == 'self' or target == SERVER_NAME then
        local ok, stdout, result = exec_script(script)
        xthread.post(reply_to, 'xadmin_exec_reply', request_id, ok, SERVER_NAME, stdout or '', result or '')
        return
    end

    -- Remote: NATS RPC into the target's xadmin_remote_exec.
    -- We are inside a coroutine (see __thread_handle), so xnats.rpc may yield.
    local ok, value, stdout, result = xnats.rpc(target, 'xadmin_remote_exec', script)
    if not ok then
        -- ok==false means RPC layer error; value carries the message.
        xthread.post(reply_to, 'xadmin_exec_reply', request_id, false, target,
            '', 'rpc failed: ' .. tostring(value))
        return
    end
    -- Remote's exec_script returns (ok, stdout, result).
    -- xnats.rpc returns (true, ok, stdout, result) where the leading true is
    -- the RPC success flag. Re-pack to match the worker's expected schema.
    xthread.post(reply_to, 'xadmin_exec_reply', request_id,
        value and true or false, target, stdout or '', result or '')
end)

-- ---------------------------------------------------------------------------
-- Lifecycle
-- ---------------------------------------------------------------------------

local function __init()
    print(string.format('[XADMIN-MAIN] init server=%s http=%s://%s:%d nats=%s:%d prefix=%s',
        SERVER_NAME, HTTPS and 'https' or 'http', HTTP_HOST, HTTP_PORT,
        NATS_HOST, NATS_PORT, NATS_PREFIX))
    if TOKEN ~= '' then
        print('[XADMIN-MAIN] auth: X-Xadmin-Token required')
    else
        print('[XADMIN-MAIN] auth: open (set XADMIN_TOKEN to require a token)')
    end

    assert(xnet.init())
    xtimer.init(32)

    -- NATS first (main thread is the NATS worker so we receive xadmin_remote_exec).
    local ok, err = xnats.start({
        host = NATS_HOST,
        port = NATS_PORT,
        name = SERVER_NAME,
        prefix = NATS_PREFIX,
        workers = { MAIN_ID },
        reconnect_ms = 1000,
        rpc_timeout_ms = 10000,
    })
    if not ok then error(err) end

    -- HTTP server with our custom worker that supports async responses.
    ok, err = xhttp.start({
        host = HTTP_HOST,
        port = HTTP_PORT,
        https = HTTPS,
        cert_file = CERT,
        key_file = KEY,
        key_password = KEY_PASSWORD,
        worker_count = 1,
        worker_base = xthread.WORKER_GRP3,
        worker_script = 'scripts/xadmin/xadmin_worker.lua',
        app_script = 'scripts/xadmin/xadmin_app.lua',
        max_request_size = 4 * 1024 * 1024,
        server_name = 'xnet-xadmin',
    })
    if not ok then error(err) end

    -- Heartbeat: announce ourselves on NATS so other xadmin peers find us.
    -- Fire one immediately, then every HEARTBEAT_MS.
    local function heartbeat()
        xnats.publish('xadmin_announce', SERVER_NAME)
    end
    heartbeat()
    xtimer.add(HEARTBEAT_MS, heartbeat, -1)

    print(string.format('[XADMIN-MAIN] open %s://%s:%d/', HTTPS and 'https' or 'http', HTTP_HOST, HTTP_PORT))
end

local function __uninit()
    xhttp.stop()
    xnats.stop(true)
    xnet.uninit()
    print('[XADMIN-MAIN] uninit')
end

return {
    __init = __init,
    __thread_handle = router.handle,
    __uninit = __uninit,
    __tick_ms = 10,
}
