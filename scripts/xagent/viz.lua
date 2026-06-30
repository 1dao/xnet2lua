-- xagent/viz.lua — facade for the interactive-visualization output pipeline:
-- resolve where pages live (paths), run the local static server (server), and
-- open URLs in the browser (open_url). Used by tools/viz_publish.lua and by the
-- main/gui boot to start the server with the app.

local M = {
    paths    = require('xagent.viz.paths'),
    server   = require('xagent.viz.server'),
    open_url = require('xagent.ui.open_url'),
}

-- Start (idempotently) the local static server. Returns port or (nil, err).
function M.ensure_server() return M.server.ensure() end

return M
