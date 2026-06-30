-- xagent/viz/server.lua — bring up the local static server that serves the viz
-- output dir.
--
-- Reuses the xhttp worker-thread server, so serving runs OFF the agent thread
-- and never blocks chat/streaming. Idempotent: safe to call at boot (honours the
-- "server starts with xagent" choice) and again from the publish tool.

local xhttp = dofile('scripts/core/server/xhttp.lua')
local paths = require('xagent.viz.paths')

local M = {}
local state = { started = false, port = nil, err = nil }

-- Returns the bound port on success, or (nil, err) if the server can't start
-- (e.g. xnet built without HTTP, or the port is already taken). Never throws.
function M.ensure()
    if state.started then return state.port end
    local port = paths.port()

    -- xhttp.start returns (false, msg) on failure; pcall also guards a throw
    -- from create_thread / listen_fd (e.g. port conflict).
    local pcall_ok, started, serr = pcall(xhttp.start, {
        host          = paths.host(),
        port          = port,
        worker_count  = 1,
        worker_name   = 'xagent-viz',
        worker_script = 'scripts/core/server/xhttp_worker.lua',
        app_script    = 'scripts/xagent/viz/static_app.lua',
        server_name   = 'xagent-viz',
        max_request_size = 256 * 1024,
    })
    if not pcall_ok then
        state.err = tostring(started)
        return nil, state.err
    end
    if not started then
        state.err = tostring(serr or 'xhttp.start failed')
        return nil, state.err
    end

    state.started, state.port, state.err = true, port, nil
    return port
end

-- Stop the server + its worker. Call at process __uninit (before xnet.uninit),
-- mirroring xadmin's lifecycle, so worker sockets close cleanly instead of
-- erroring out during runtime teardown.
function M.stop()
    if not state.started then return end
    pcall(function() xhttp.stop() end)
    state.started, state.port = false, nil
end

function M.running() return state.started end
function M.port() return state.port end
function M.last_error() return state.err end

-- http URL for a published filename (must call ensure() first).
function M.url(filename)
    return string.format('http://%s:%d/%s', paths.host(), state.port or paths.port(), filename)
end

return M
