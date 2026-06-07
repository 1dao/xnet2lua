-- xhttp.lua - HTTP server manager.
-- Main thread owns listen_fd and passes accepted sockets to worker threads.
-- HTTP parsing/response serialization live in scripts/core/share/xhttp_codec.lua.

local M = rawget(_G, 'xhttp')
if type(M) ~= 'table' then M = {} end

local to_bool = dofile('scripts/core/share/xmisc.lua').to_bool

local DEFAULT_WORKER_SCRIPT = 'scripts/core/server/xhttp_worker.lua'

local STATE_KEY = '__xnet_xhttp_state'
local state = rawget(_G, STATE_KEY)
if type(state) ~= 'table' then
    state = {}
    rawset(_G, STATE_KEY, state)
end
if state.running == nil then state.running = false end
if type(state.workers) ~= 'table' then state.workers = {} end
if state.rr_index == nil then state.rr_index = 0 end

local function build_workers(cfg)
    if type(cfg.workers) == 'table' and #cfg.workers > 0 then
        local out = {}
        for i, id in ipairs(cfg.workers) do
            out[i] = tonumber(id)
        end
        return out
    end

    local base = tonumber(cfg.worker_base) or xthread.WORKER_GRP3
    local count = tonumber(cfg.worker_count or cfg.workers or 2) or 2
    if count < 1 then count = 1 end

    local out = {}
    for i = 1, count do
        out[i] = base + i - 1
    end
    return out
end

local function normalize_config(cfg)
    cfg = cfg or {}
    local compr = cfg.compression or {}
    local max_decompressed_size = tonumber(cfg.max_decompressed_size)
    if max_decompressed_size and max_decompressed_size <= 0 then
        max_decompressed_size = nil
    end
    return {
        host = cfg.host or '127.0.0.1',
        port = tonumber(cfg.port) or 18080,
        https = to_bool(cfg.https, false),
        server_name = cfg.server_name or cfg.name or 'xnet-http',
        worker_name = cfg.worker_name,
        worker_script = cfg.worker_script or DEFAULT_WORKER_SCRIPT,
        app_script = cfg.app_script,
        cert_file = cfg.cert_file or cfg.cert or '',
        key_file = cfg.key_file or cfg.key or '',
        key_password = cfg.key_password or cfg.password or '',
        ca_file = cfg.ca_file or '',
        max_request_size = tonumber(cfg.max_request_size) or 16 * 1024 * 1024,
        compress_enabled  = to_bool(compr.enabled, true),
        compress_min_size = tonumber(compr.min_size) or 256,
        compress_level    = tonumber(compr.level) or 6,
        decompress_requests = to_bool(cfg.decompress_requests, true),
        max_decompressed_size = max_decompressed_size,
        -- HTTP -> HTTPS upgrade: when force_https is set on a plaintext server,
        -- every request is answered with a redirect to redirect_port over https.
        -- hsts (Strict-Transport-Security) is emitted on HTTPS responses and on
        -- the redirect; accepts bool / number / string / table (see
        -- xhttp_codec.hsts_value).
        force_https     = to_bool(cfg.force_https, false),
        redirect_port   = tonumber(cfg.redirect_port or cfg.https_port) or 443,
        redirect_status = tonumber(cfg.redirect_status) or 301,
        hsts            = cfg.hsts,
        workers = build_workers(cfg),
    }
end

local function pick_worker()
    local workers = state.workers
    if #workers == 0 then return nil end
    state.rr_index = (state.rr_index % #workers) + 1
    return workers[state.rr_index]
end

local function shutdown_workers()
    local workers = state.workers
    for i = #workers, 1, -1 do
        local id = workers[i]
        local ok, err = xthread.shutdown_thread(id)
        if not ok then
            io.stderr:write('[XHTTP] shutdown worker failed: ' .. tostring(id) .. ' ' .. tostring(err) .. '\n')
        end
        workers[i] = nil
    end
end

function M.start(cfg)
    if state.running then
        return true
    end
    if XNET_WITH_HTTP == false then
        return false, 'xnet was built without HTTP support'
    end

    local conf = normalize_config(cfg)
    if type(conf.app_script) ~= 'string' or conf.app_script:match('^%s*$') then
        return false, 'xhttp.start requires non-empty app_script'
    end
    if type(conf.worker_name) ~= 'string' or conf.worker_name:match('^%s*$') then
        return false, 'xhttp.start requires non-empty worker_name'
    end
    if conf.https and XNET_WITH_HTTPS == false then
        return false, 'HTTPS support is not compiled in; rebuild with WITH_HTTPS=1'
    end
    if conf.https then
        if conf.cert_file == '' or conf.key_file == '' then
            return false, 'HTTPS requires cert_file and key_file'
        end
    end

    state.workers = {}
    state.rr_index = 0

    for i, id in ipairs(conf.workers) do
        local worker_name = string.format('%s-%02d', conf.worker_name, i)
        local ok, err = xthread.create_thread(id, worker_name, conf.worker_script)
        if not ok then
            shutdown_workers()
            return false, err
        end
        state.workers[#state.workers + 1] = id

        ok, err = xthread.post(id, 'xhttp_worker_start',
            conf.app_script, conf.max_request_size, conf.server_name,
            conf.https, conf.cert_file, conf.key_file, conf.key_password,
            conf.compress_enabled, conf.compress_min_size, conf.compress_level,
            conf.decompress_requests, conf.max_decompressed_size,
            conf.ca_file,
            {
                force_https     = conf.force_https,
                redirect_port   = conf.redirect_port,
                redirect_status = conf.redirect_status,
                hsts            = conf.hsts,
            })
        if not ok then
            shutdown_workers()
            return false, err
        end
    end

    local l, err = xnet.listen_fd(conf.host, conf.port, {
        on_accept = function(_, fd, ip, port)
            local id = pick_worker()
            if not id then
                io.stderr:write('[XHTTP] no worker for accepted fd\n')
                return false
            end

            local ok, post_err = xthread.post(id, 'xhttp_accept', fd, ip, port)
            if not ok then
                io.stderr:write('[XHTTP] post accepted fd failed: ' .. tostring(post_err) .. '\n')
                return false
            end
            return true
        end,
        on_close = function(_, reason)
            print('[XHTTP] listener closed:', reason)
        end,
    })
    if not l then
        shutdown_workers()
        return false, err
    end

    state.listener = l
    state.running = true
    print(string.format('[XHTTP] listening on %s://%s:%d workers=%d',
        conf.https and 'https' or 'http', conf.host, conf.port, #state.workers))
    return true
end

function M.stop()
    if state.listener then
        state.listener:close('xhttp_stop')
        state.listener = nil
    end
    shutdown_workers()
    state.running = false
    return true
end

function M.running()
    return state.running
end

function M.worker_ids()
    local out = {}
    for i, id in ipairs(state.workers) do out[i] = id end
    return out
end

_G.xhttp = M
return M
