-- xagent/viz/static_app.lua — xhttp app_script that serves the viz output dir
-- as a read-only static site.
--
-- Runs inside an xhttp worker thread (its own Lua state), so it resolves the viz
-- root via xagent.viz.paths the same config-only way the publish tool does — the
-- two threads agree on the same absolute directory without sharing state.
--
-- Newly published files are served immediately: a wildcard route resolves the
-- request path against the root at request time (no per-file registration), so
-- pages written after the server started are picked up automatically.

package.path = 'scripts/?.lua;' .. package.path

local router = dofile('scripts/core/share/xhttp_router.lua')
local paths  = require('xagent.viz.paths')
local xutils = require('xutils')

local ROOT = paths.root()

-- Reject path traversal / NUL / absolute escapes; return a clean relative path.
local function safe_rel(rel)
    rel = tostring(rel or ''):gsub('\\', '/'):gsub('^/+', '')
    local parts = {}
    for part in rel:gmatch('[^/]+') do
        if part == '..' or part:find('%z') then return nil end
        if part ~= '' and part ~= '.' then parts[#parts + 1] = part end
    end
    if #parts == 0 then return nil end
    return table.concat(parts, '/')
end

local function read_bytes(path)
    local f = io.open(path, 'rb'); if not f then return nil end
    local data = f:read('*a'); f:close(); return data
end

router.reset({ log_prefix = 'XAGENT-VIZ' })

-- Index: list the generated pages in the root.
router.get('/', function()
    local entries = xutils.scan_dir(ROOT) or {}
    local names = {}
    for _, e in ipairs(entries) do
        local rel = (e.rel or ''):gsub('\\', '/')
        if rel:match('%.html$') and not rel:find('/') then names[#names + 1] = rel end
    end
    table.sort(names, function(a, b) return a > b end)   -- newest-ish first
    local rows = {}
    for _, name in ipairs(names) do
        rows[#rows + 1] = string.format('<li><a href="/%s">%s</a></li>', name, name)
    end
    if #rows == 0 then rows[1] = '<li class="empty">（还没有生成页面）</li>' end
    local body = [[<!DOCTYPE html><html lang="zh"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>AetherViz</title><style>
body{font-family:system-ui,-apple-system,"Segoe UI",sans-serif;margin:0;padding:48px;
 background:linear-gradient(180deg,#0f172a 0%,#164e63 100%);color:#e2e8f0;min-height:100vh;}
h1{color:#2dd4bf;font-weight:700;}a{color:#22d3ee;text-decoration:none;}
a:hover{text-decoration:underline;}ul{line-height:2;padding-left:20px;}
.empty{color:#94a3b8;list-style:none;}</style></head><body>
<h1>AetherViz · 已生成页面</h1><ul>]] .. table.concat(rows) .. [[</ul></body></html>]]
    return { status = 200, body = body, headers = { ['Content-Type'] = 'text/html; charset=utf-8' } }
end)

-- Serve any file under the root.
router.get('/*path', function(req)
    local rel = safe_rel(req.params and req.params.path)
    if not rel then return { status = 400, body = 'bad path\n' } end
    local data = read_bytes(ROOT .. '/' .. rel)
    if not data then return { status = 404, body = 'not found\n' } end
    return {
        status = 200,
        body = data,
        headers = { ['Content-Type'] = router.content_type_for(rel) },
    }
end)

return { router = router }
