-- xagent/viz/paths.lua — resolve the viz output root + host/port, and build
-- safe page filenames.
--
-- Portability seam. This module depends ONLY on config/env + the process cwd,
-- never on per-thread state, so the main thread (the viz_publish tool) and the
-- xhttp static-server worker thread (a separate Lua state) independently resolve
-- the SAME absolute directory. It is also the single knob a future Android/iOS
-- host flips to redirect everything into its app sandbox.
--
-- Resolution (highest precedence first):
--   1. XAGENT_VIZ_DIR        explicit output dir
--   2. XAGENT_DATA_DIR/viz   app data root (mobile host points DATA_DIR at its sandbox)
--   3. <cwd>/.xagent/viz     desktop default (relative to the launch cwd)

local xutils = require('xutils')

local M = {}

-- cfg key from xnet.cfg first, then the process environment (so a host shell can
-- inject XAGENT_DATA_DIR without writing a cfg file).
local function cfg(key)
    local v = xutils.get_config and xutils.get_config(key) or nil
    if v ~= nil and v ~= '' then return v end
    v = os.getenv(key)
    if v ~= nil and v ~= '' then return v end
    return nil
end

local function strip_slash(p) return (tostring(p):gsub('[/\\]+$', '')) end

function M.root()
    local explicit = cfg('XAGENT_VIZ_DIR')
    if explicit then return strip_slash(explicit) end
    local data = cfg('XAGENT_DATA_DIR')
    if data then return strip_slash(data) .. '/viz' end
    return '.xagent/viz'   -- relative to the process cwd (same for every thread)
end

function M.host() return cfg('XAGENT_VIZ_HOST') or '127.0.0.1' end
function M.port() return tonumber(cfg('XAGENT_VIZ_PORT')) or 7900 end

-- slugify to [a-z0-9-]; non-ascii (e.g. CJK) bytes are dropped so filenames and
-- URLs stay ascii-safe (valid in any browser/WebView). Falls back to 'viz'.
function M.slugify(s)
    s = tostring(s or ''):lower():gsub('[^%w]+', '-'):gsub('^-+', ''):gsub('-+$', '')
    if s == '' then s = 'viz' end
    if #s > 48 then s = (s:sub(1, 48):gsub('-+$', '')) end
    return s
end

-- A unique page filename. A monotonic counter + HHMMSS keeps regenerations
-- distinct, so each publish gets a fresh URL (no stale browser cache).
local seq = 0
function M.filename(title, slug)
    local base = (slug and slug ~= '') and M.slugify(slug) or M.slugify(title)
    seq = seq + 1
    return string.format('%s-%s-%d.html', base, os.date('%H%M%S'), seq)
end

return M
