-- test_viz.lua — end-to-end test for the viz pipeline:
--   paths/slug resolution + builtin-skill discovery (offline)  then
--   ensure_server -> viz_publish -> HTTP GET the served page (online).
--
-- Run: .\bin\xnet.exe scripts\xagent\test_viz.lua
-- Exit code 0 = all passed, 1 = failure. Output via io.write (clean stdout).

package.path = 'scripts/?.lua;' .. package.path

local router = dofile('scripts/core/share/xrouter.lua')
local httpc  = dofile('scripts/core/share/xhttp_client.lua')
local xutils = require('xutils')
local paths      = require('xagent.viz.paths')
local viz        = require('xagent.viz')
local tool       = require('xagent.tools.viz_publish')
local loader     = require('xagent.skills.loader')
local skills     = require('xagent.skills')
local transcript = require('xagent.ui.transcript')

local function w(s) io.write(s); io.flush() end
local failed = 0
local function check(name, cond)
    w((cond and '  PASS ' or '  FAIL ') .. name .. '\n')
    if not cond then failed = failed + 1 end
end

local MARKER = 'AETHERVIZ_TEST_MARKER_42'

-- ---- offline checks ----
local function offline_checks()
    w('[offline]\n')
    check('root default = .xagent/viz', paths.root() == '.xagent/viz')
    check("slug 'Newton's 2nd Law!' -> newton-s-2nd-law",
        paths.slugify("Newton's 2nd Law!") == 'newton-s-2nd-law')
    check('slug CJK falls back to viz', paths.slugify('牛顿第二定律') == 'viz')
    check('filename uses slug + .html',
        paths.filename('牛顿第二定律', 'newtons-second-law')
            :match('^newtons%-second%-law%-%d+%-%d+%.html$') ~= nil)
    check('tool name = viz_publish', tool.name == 'viz_publish')
    check('tool rejects missing html', tool.call({}, { cwd = '.' }).is_error == true)

    local res = loader.load_all('.')
    local src
    for _, s in ipairs(res.skills) do if s.name == 'aetherviz' then src = s.source end end
    check('aetherviz skill discovered', src ~= nil)
    check('aetherviz from builtin scope', src == 'builtin')

    -- The skill body MUST inject the user's topic via $ARGUMENTS, else the model
    -- gets generic instructions with no subject and visualizes the wrong thing.
    skills.bootstrap('.')   -- populate the registry for find_invocable + reminder
    local sk = skills.find_invocable('aetherviz')
    local rendered = sk and skills.render_body(sk, '牛顿第二定律', 'sess') or ''
    check('skill body injects the topic', rendered:find('牛顿第二定律', 1, true) ~= nil)
    check('skill body consumes $ARGUMENTS', rendered:find('$ARGUMENTS', 1, true) == nil)

    -- skills reminder must stay valid UTF-8 even with long CJK descriptions
    -- (budget.truncate cut on a byte boundary → split multibyte char → empty
    -- JSON body → "json_pack produced an empty body"). Regression guard.
    local budget = require('xagent.skills.budget')
    local long_cjk = string.rep('力学模块物理演示互动可视化', 40)   -- >>250 bytes, ~520 chars
    local listing = budget.format({ { name = 'x', description = long_cjk } })
    check('budget listing is valid UTF-8', xutils.json_pack({ s = listing }) ~= nil)
    check('budget truncated (… appended)', listing:find('…', 1, true) ~= nil)
    local rem_ok = xutils.json_pack({ s = skills.reminder() }) ~= nil
    check('skills.reminder() json-packs (no bad UTF-8)', rem_ok)

    -- clickable-link URL detection (transcript)
    local L1 = transcript.find_links('已生成页面：http://127.0.0.1:7900/a-b-1.html')
    check('find_links finds one url', #L1 == 1)
    check('find_links captures url', L1[1] and L1[1].url == 'http://127.0.0.1:7900/a-b-1.html')
    local L2 = transcript.find_links('见 http://x/y.html。')   -- trailing CJK period trimmed
    check('find_links trims trailing punctuation', L2[1] and L2[1].url == 'http://x/y.html')
    check('find_links ignores plain text', #transcript.find_links('no links here at all') == 0)
end

-- ---- online: publish + fetch back ----
local function online_check()
    w('[online]\n')
    local port, err = viz.ensure_server()
    check('viz server started', port ~= nil)
    if not port then
        w('  (server error: ' .. tostring(err) .. ')\n')
        xthread.stop(1); return
    end

    local html = '<!DOCTYPE html><html><body>' .. MARKER .. '</body></html>'
    local res = tool.call({ html = html, slug = 'test-page', open = false }, { cwd = '.' })
    check('publish ok (no error)', not res.is_error)
    local url = tostring(res.content):match('(http://%S+%.html)')
    check('publish returned http url', url ~= nil)
    if not url then xthread.stop(1); return end
    w('  url = ' .. url .. '\n')

    httpc.request({ url = url, method = 'GET' }, function(herr, resp)
        check('GET no transport error', herr == nil)
        check('GET status 200', resp and resp.status == 200)
        check('GET body has marker',
            resp and type(resp.body) == 'string' and resp.body:find(MARKER, 1, true) ~= nil)

        -- also hit the index route
        local base = url:match('^(http://[^/]+/)')
        httpc.request({ url = base, method = 'GET' }, function(ierr, iresp)
            check('index status 200', not ierr and iresp and iresp.status == 200)
            w(failed == 0 and ('Lua unit tests: ALL passed\n')
                or ('Lua unit tests: ' .. failed .. ' FAILED\n'))
            xthread.stop(failed == 0 and 0 or 1)
        end)
    end)
end

local function __init()
    assert(xnet.init())
    offline_checks()
    online_check()
end

return {
    __tick_ms = 10,
    __thread_handle = router.handle,
    __init = __init,
    __uninit = function()
        viz.server.stop()
        if xnet and xnet.uninit then xnet.uninit() end
    end,
}
