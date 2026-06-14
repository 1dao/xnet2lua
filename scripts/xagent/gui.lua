-- xagent/gui.lua — desktop chat GUI (raygui). The interaction layer.
--
-- A tick-driven immediate-mode window: the runner calls __update each tick to
-- draw one frame, and the same tick pumps xpoll/xtimer so the LLM stream and
-- the subprocess worker keep progressing between frames. The agent runs as a
-- coroutine started on Send; its on_event updates the transcript, which renders
-- live. UTF-8 input/output is native (no console code-page issues).
--
-- Run: bin/xnet scripts/xagent/gui.lua

package.path = 'scripts/?.lua;tools/?.lua;' .. package.path
package.cpath = 'tools/?.dll;tools/?.so;' .. package.cpath

local router        = dofile('scripts/core/share/xrouter.lua')
local raygui        = require('raygui')
local xutils        = require('xutils')
local config        = require('xagent.config')
local registry      = require('xagent.tools.registry')
local system_prompt = require('xagent.context.system_prompt')
local project_md    = require('xagent.context.project_md')
local subprocess    = require('xagent.proc.subprocess')
local session       = require('xagent.session.session')
local transcript    = require('xagent.ui.transcript')
local markdown      = require('xagent.ui.markdown')
local text          = dofile('scripts/core/share/xtext.lua')
local fs            = dofile('scripts/core/share/xfs.lua')

registry.register(require('xagent.tools.read'))
registry.register(require('xagent.tools.write'))
registry.register(require('xagent.tools.edit'))
registry.register(require('xagent.tools.ls'))
registry.register(require('xagent.tools.glob'))
registry.register(require('xagent.tools.grep'))
registry.register(require('xagent.tools.bash'))
registry.register(require('xagent.tools.multi_edit'))
registry.register(require('xagent.tools.web_fetch'))
registry.register(require('xagent.tools.memory_write'))
registry.register(require('xagent.tools.todo_write').tool)
registry.register(require('xagent.tools.skill'))

local skills = require('xagent.skills')

local IS_WIN = (package.config:sub(1, 1) == '\\')
local FONT_SIZE = 22

-- Pre-seed common glyphs so streaming text doesn't keep rebuilding the font
-- atlas (every rebuild re-rasterizes the whole texture and makes ALL text —
-- header included — flicker). Covers CJK ideographs + CJK/fullwidth punctuation
-- + a few common symbols. ASCII is seeded by load_font itself.
local function preseed_charset()
    local t = {}
    local function range(a, b) for cp = a, b do t[#t + 1] = utf8.char(cp) end end
    range(0x4E00, 0x9FFF)   -- CJK Unified Ideographs (common Chinese)
    range(0x3000, 0x303F)   -- CJK symbols & punctuation
    range(0xFF00, 0xFFEF)   -- fullwidth forms
    range(0x2018, 0x2026)   -- quotes / dashes / bullet / ellipsis
    range(0x2190, 0x21B5)   -- arrows
    range(0x2200, 0x22FF)   -- mathematical operators (≈ ≠ ≤ ≥ ∞ ∑ √ ∈ …)
    range(0x25A0, 0x25FF)   -- geometric shapes (○ ● ◦ ■ □ ▲ ▶ …)
    range(0x2600, 0x26FF)   -- misc symbols (★ ☆ ☰ ☐ ☑ …; only those in the font load)
    -- specific common symbols outside the ranges above
    for _, cp in ipairs({ 0x00A0, 0x00B0, 0x00B1, 0x00B7, 0x00D7, 0x00F7,
                          0x00A2, 0x00A3, 0x00A5, 0x00A9, 0x00AE, 0x20AC, 0x2122,
                          0xFE19,            -- ︙ vertical kebab (the font lacks ⋮ U+22EE)
                          0x2713, 0x2714, 0x2705, 0x274C, 0x2714 }) do
        t[#t + 1] = utf8.char(cp)
    end
    return table.concat(t)
end

local S = {
    entries = {},        -- { role, text }
    cur = nil,           -- current streaming assistant entry
    text_tail = '',      -- buffered incomplete trailing UTF-8 bytes
    input = '',
    input_edit = true,
    busy = false,
    status = 'ready',
    sess = nil,
    view = nil,
    emoji_tex = nil,
    cfg = nil,
    started = false,
    -- left sidebar: nil | 'history' | 'settings'
    sidebar = nil,
    history_items = {},
    history_scroll = 0,        -- pixel scroll offset of the history list
    renaming = nil,            -- id of the session being renamed inline
    rename_text = '',
    rename_edit = false,
    confirm_delete = nil,      -- id of the session awaiting delete confirmation
    menu_item = nil,           -- history item whose ⋮ menu is open
    menu_y = 0,                -- screen y of that menu
    -- theme
    theme = 'nord',
    header_bg = { 30, 30, 38, 255 },
    sidebar_bg = { 26, 26, 32, 255 },
    -- pending image attachments (pasted via Ctrl+V): { png, w, h, tex }
    attachments = {},
    -- working directory for NEW sessions (history groups by it; click the ◇
    -- row to pick a new one via the native folder dialog)
    cwd = '.',
    picking_dir = false,       -- a folder dialog is currently open
    frame = 0,                 -- frame counter (drives the thinking-dots animation)
}

local SIDEBAR_W = 290
local THEMES = { 'nord', 'soft', 'candy', 'cyber', 'dark' }
local THEME_FILE = (fs.home():gsub('[/\\]+$', '')) .. '/.xagent/theme'

-- ── color helpers ──────────────────────────────────────────────────────────
local function unpack_color(v)
    return { (v >> 24) & 0xFF, (v >> 16) & 0xFF, (v >> 8) & 0xFF, v & 0xFF }
end
local function clamp8(x) return math.max(0, math.min(255, math.floor(x + 0.5))) end
local function shift(c, d) return { clamp8(c[1] + d), clamp8(c[2] + d), clamp8(c[3] + d), c[4] or 255 } end
local function mix(a, b, t)
    return { clamp8(a[1] + (b[1] - a[1]) * t), clamp8(a[2] + (b[2] - a[2]) * t),
             clamp8(a[3] + (b[3] - a[3]) * t), 255 }
end
local function luma(c) return 0.299 * c[1] + 0.587 * c[2] + 0.114 * c[3] end

-- Vertical "⋮" (kebab) button. NotoSansSC has NO vertical-three-dots glyph
-- (lacks ⋮ U+22EE; its ︙ U+FE19 renders horizontally), so we draw the three
-- dots ourselves over an empty button (which keeps the hover bg + click).
local function kebab_button(x, y, w, h, col)
    local clicked = raygui.button(x, y, w, h, '')
    local d, sp = 3, 5
    local cx = x + math.floor(w / 2) - math.floor(d / 2)
    local cy = y + math.floor(h / 2) - sp - 1
    for k = 0, 2 do
        raygui.draw_rectangle(cx, cy + k * sp, d, d, col[1], col[2], col[3], col[4] or 255)
    end
    return clicked
end

-- Filled-square "stop" button (shown in the input box while a turn is running;
-- click requests cancellation at the next turn boundary). Hand-drawn like the
-- kebab — the font has no reliable ■ glyph at this size.
local function stop_button(x, y, w, h, col)
    local clicked = raygui.button(x, y, w, h, '')
    local d = 10
    raygui.draw_rectangle(x + math.floor((w - d) / 2), y + math.floor((h - d) / 2), d, d,
        col[1], col[2], col[3], col[4] or 255)
    return clicked
end

-- ── working-directory helpers (history grouping + the editable current dir) ──
-- Normalized key so "C:\a\b", "c:/a/b/" group together on Windows.
local function dir_key(d)
    d = tostring(d or ''):gsub('\\', '/'):gsub('/+$', '')
    if IS_WIN then d = d:lower() end
    return d
end

-- Short display form: the last two path components.
local function dir_tail(d)
    d = tostring(d or ''):gsub('[\\/]+$', '')
    return d:match('([^\\/]+[\\/][^\\/]+)$') or d:match('([^\\/]+)$') or d
end

-- True if `dir` exists. Validated via cmd's EXIT CODE only: with the UTF-8
-- activeCodePage manifest on xnet.exe, the UTF-8 path converts correctly INTO
-- the child process, but cmd's piped OUTPUT is still in the console code page
-- (GBK) — echoing a non-ASCII path back through it would re-mangle the bytes,
-- so the caller keeps its own UTF-8 string.
local function dir_exists(dir)
    local f = io.popen(IS_WIN and ('cd /d "' .. dir .. '" 2>nul')
                              or ('cd "' .. dir .. '" 2>/dev/null'))
    if not f then return false end
    f:read('*a')
    local ok, _how, code = f:close()   -- (true|nil, 'exit', code)
    return ok == true or tonumber(code) == 0
end

-- UTF-8 → UTF-16LE (for PowerShell -EncodedCommand: no shell-quoting pitfalls,
-- and non-ASCII paths in the embedded script survive intact).
local function utf8_to_utf16le(s)
    local out = {}
    for _, cp in utf8.codes(s) do
        if cp < 0x10000 then
            out[#out + 1] = string.char(cp % 256, cp // 256)
        else
            local v = cp - 0x10000
            local hi = 0xD800 + v // 0x400
            local lo = 0xDC00 + v % 0x400
            out[#out + 1] = string.char(hi % 256, hi // 256, lo % 256, lo // 256)
        end
    end
    return table.concat(out)
end

local function add(role, text)
    local e = { role = role, text = text or '' }
    S.entries[#S.entries + 1] = e
    return e
end

local new_session   -- forward declaration (referenced by /new before its definition)

local function compact(v)
    local ok, s = pcall(xutils.json_pack, v)
    if not ok then return tostring(v) end
    if #s > 160 then s = s:sub(1, 160) .. '...' end
    return s
end

-- Split off any trailing incomplete UTF-8 sequence so the displayed text is
-- always valid (a multibyte char may straddle two stream deltas; feeding a half
-- char to utf8.codes during emoji tokenization would error and crash the frame).
local function utf8_split_complete(s)
    local n = #s
    if n == 0 then return '', '' end
    for i = n, math.max(1, n - 3), -1 do
        local b = s:byte(i)
        if b < 0x80 then
            return s, ''
        elseif b >= 0xC0 then
            local len = (b < 0xE0 and 2) or (b < 0xF0 and 3) or 4
            if i + len - 1 <= n then return s, '' else return s:sub(1, i - 1), s:sub(i) end
        end
    end
    return s, ''
end

local function flush_tail()
    if S.cur and S.text_tail ~= '' then S.cur.text = S.cur.text .. S.text_tail end
    S.text_tail = ''
    S.cur = nil
end

local function on_event(ev)
    if ev.type == 'text' then
        if not S.cur then S.cur = add('assistant', '') end
        local complete, tail = utf8_split_complete(S.text_tail .. ev.text)
        S.text_tail = tail
        S.cur.text = S.cur.text .. complete
    elseif ev.type == 'tool_use' then
        flush_tail()
        add('tool', '> ' .. ev.name .. '  ' .. compact(ev.input))
    elseif ev.type == 'tool_result' then
        flush_tail()
        local c = (ev.result and ev.result.content) or ''
        if type(c) ~= 'string' then c = '[non-text result]' end
        if #c > 600 then c = c:sub(1, 600) .. '\n  ...' end
        add('tool_result', c)
    elseif ev.type == 'budget' then
        S.budget = ev.budget
    elseif ev.type == 'compact_start' then
        flush_tail()
        S.status = '压缩上下文'        -- distinct status (busy dots animate); not frozen
    elseif ev.type == 'compact' then
        flush_tail()
        -- A concise notice ONLY — the summary text belongs in the message
        -- history (for the model), not dumped into the user's transcript.
        if ev.did_compact then
            add('system', '📚 上下文已压缩' ..
                (ev.kept_tail and ('，保留最近 ' .. ev.kept_tail .. ' 条消息') or ''))
            S.status = '思考中'         -- back to the answer that follows compaction
        elseif ev.error then
            add('error', '压缩失败: ' .. tostring(ev.error))
        end
        -- did_micro alone is silent — it's background housekeeping near the
        -- context limit, not something to announce in the transcript.
    elseif ev.type == 'done' then
        flush_tail(); S.busy = false; S.status = 'ready'
    elseif ev.type == 'error' then
        flush_tail(); add('error', 'ERROR: ' .. tostring(ev.error)); S.busy = false; S.status = 'error'
    end
end

-- Bind on_event to the session that STARTED the run. A turn/compaction keeps
-- running after the user switches sessions (the coroutine is parked in awaits);
-- without this guard its late events (text, the compaction summary, done) would
-- be pushed into the NEW session's transcript.
local function make_on_event(sess)
    return function(ev)
        if S.sess ~= sess then return end
        on_event(ev)
    end
end

-- Slash commands handled locally (not sent to the model). Returns true if the
-- input was a command (and was consumed).
local function handle_slash(text)
    local orig_cmd, rest = text:match('^/(%S+)%s*(.*)$')
    if not orig_cmd then return false end
    local cmd = orig_cmd:lower()
    if cmd == 'compact' then
        S.input = ''; S.busy = true; S.status = '压缩中…'; S.cur = nil
        local sess = S.sess
        local handler = make_on_event(sess)
        local co = coroutine.create(function()
            sess:compact(rest ~= '' and rest or nil, handler)
            pcall(function() sess:save() end)
            if S.sess == sess then S.busy = false; S.status = 'ready' end
        end)
        local ok, err = coroutine.resume(co)
        if not ok then handler({ type = 'error', error = err }) end
        return true
    elseif cmd == 'context' then
        S.input = ''
        local b = S.budget
        if b then
            add('system', string.format('📊 上下文 ~%d / %d tokens (%.0f%%)  ·  状态 %s  ·  自动压缩阈值 %d',
                b.estimated, b.context_window, b.percent * 100, b.state, b.auto_compact_threshold))
        else
            add('system', '📊 暂无上下文用量数据（发送一条消息后可见）')
        end
        return true
    elseif cmd == 'clear' or cmd == 'new' then
        S.input = ''
        new_session()
        return true
    elseif cmd == 'help' then
        S.input = ''
        local lines = { '可用命令:', '/compact [重点]  压缩上下文', '/context  查看上下文用量',
                        '/new  新会话', '/help  帮助' }
        local sk = require('xagent.skills').all_user_invocable()
        if #sk > 0 then
            lines[#lines + 1] = ''
            lines[#lines + 1] = '技能(/<名称> [参数]):'
            for _, s in ipairs(sk) do lines[#lines + 1] = '/' .. s.name .. '  ' .. (s.description or '') end
        end
        add('system', table.concat(lines, '\n'))
        return true
    end

    -- Not a built-in: maybe a user-invoked skill (/<skill-name> [args]).
    local skill = require('xagent.skills').find_invocable(orig_cmd)
    if skill then
        S.input = ''
        local prompt = require('xagent.skills').render_body(skill, rest, S.sess and S.sess.id or 'unknown-session')
        add('user', text)                     -- echo what the user typed
        S.busy = true; S.status = '思考中'; S.cur = nil
        local sess = S.sess
        local handler = make_on_event(sess)
        sess.cancelled = nil
        sess:add_user(prompt)
        local co = coroutine.create(function()
            sess:run(handler); pcall(function() sess:save() end)
        end)
        local ok, err = coroutine.resume(co)
        if not ok then handler({ type = 'error', error = err }) end
        return true
    end
    return false
end

local function clear_attachments()
    for _, a in ipairs(S.attachments) do
        if a.tex then pcall(raygui.unload_texture, a.tex) end
    end
    S.attachments = {}
end

local function submit()
    if S.busy or not S.sess then return end
    local text = (S.input or ''):gsub('^%s+', ''):gsub('%s+$', '')
    if text == '' and #S.attachments == 0 then return end
    if text:sub(1, 1) == '/' and handle_slash(text) then return end

    -- With attachments the user turn becomes content BLOCKS: image blocks
    -- (base64 PNG, the Anthropic image source format) + an optional text block.
    local content, shown = text, text
    if #S.attachments > 0 then
        content = {}
        local marks = {}
        for _, a in ipairs(S.attachments) do
            content[#content + 1] = { type = 'image', source = {
                type = 'base64', media_type = 'image/png',
                data = xutils.base64_encode(a.png),
            } }
            marks[#marks + 1] = string.format('[图片 %d×%d]', a.w, a.h)
        end
        if text ~= '' then content[#content + 1] = { type = 'text', text = text } end
        shown = table.concat(marks, ' ') .. (text ~= '' and ('\n' .. text) or '')
    end

    add('user', shown)
    clear_attachments()
    S.input = ''
    S.busy = true
    S.status = '思考中'
    S.cur = nil
    local sess = S.sess
    local handler = make_on_event(sess)
    sess.cancelled = nil    -- a previous stop-click must not kill this new turn
    sess:add_user(content)

    local co = coroutine.create(function()
        sess:run(handler)
        pcall(function() sess:save() end)   -- save the session that RAN (S.sess may have changed)
    end)
    local ok, err = coroutine.resume(co)
    if not ok then handler({ type = 'error', error = err }) end
end

-- Rebuild transcript entries from a loaded session's message history.
local function rebuild_entries(messages)
    local entries = {}
    local function push(role, text) entries[#entries + 1] = { role = role, text = text or '' } end
    for _, m in ipairs(messages or {}) do
        if m.role == 'user' then
            if type(m.content) == 'string' then
                push('user', m.content)
            elseif type(m.content) == 'table' then
                -- Either tool_results (the agent loop's synthetic turns) or a
                -- real user message of image + text blocks — render both.
                local parts = {}
                for _, b in ipairs(m.content) do
                    if b.type == 'tool_result' then
                        local c = b.content
                        if type(c) ~= 'string' then c = '[result]' end
                        push('tool_result', c)
                    elseif b.type == 'image' then
                        parts[#parts + 1] = '[图片]'
                    elseif b.type == 'text' then
                        parts[#parts + 1] = b.text or ''
                    end
                end
                if #parts > 0 then push('user', table.concat(parts, '\n')) end
            end
        elseif m.role == 'assistant' then
            if type(m.content) == 'string' then
                push('assistant', m.content)
            elseif type(m.content) == 'table' then
                for _, b in ipairs(m.content) do
                    if b.type == 'text' then push('assistant', b.text)
                    elseif b.type == 'tool_use' then push('tool', '> ' .. tostring(b.name) .. '  ' .. compact(b.input)) end
                end
            end
        end
    end
    return entries
end

local function sanitize_label(s)
    s = tostring(s or ''):gsub('[\r\n;]', ' ')
    if #s > 56 then s = text.valid_utf8(s:sub(1, 56)) .. '…' end   -- byte cut → fix UTF-8
    return s
end

local function refresh_history()   -- reload items; keeps scroll, clears inline modes
    S.history_items = session.list()
    S.renaming = nil
    S.confirm_delete = nil
    S.menu_item = nil
end

-- Switch the working directory for NEW sessions. Keeps the caller's UTF-8
-- string as-is (picker/dialog paths are already canonical; see dir_exists for
-- why we never round-trip the path through cmd's output).
local function apply_cwd(dir)
    dir = tostring(dir or ''):gsub('^%s+', ''):gsub('%s+$', '')
    if #dir > 3 then dir = dir:gsub('[\\/]+$', '') end   -- keep "C:\" intact
    if dir ~= '' and dir_exists(dir) then
        S.cwd = dir
        skills.bootstrap(dir)   -- reload project skills for the new working dir
        S.status = '目录已切换（新会话生效）'
    else
        print('[xagent] apply_cwd failed for: ' .. dir)   -- diagnosis via xlog
        S.status = '目录不存在: ' .. dir
    end
end

-- Open the directory picker. Primary: the EMBEDDED raygui file dialog
-- (gui_window_file_dialog compiled into raygui.dll) — in-process, theme-
-- consistent, no encoding pitfalls. The PowerShell fallback below is kept only
-- until the embedded one is confirmed good, then deleted.
local function pick_directory()
    if raygui.file_dialog_open then
        if S.dir_dialog then return end
        -- Open at the drive ROOT, not the cwd: picking a project dir usually
        -- means navigating somewhere else entirely.
        local root = IS_WIN and (((S.cwd or ''):match('^%a:') or 'C:') .. '\\') or '/'
        raygui.file_dialog_open(root, 600, 440, true)    -- dirs only
        S.dir_dialog = true
        S.status = '选择目录…（进入目标目录后点 Select）'
        return
    end
    return pick_directory_ps()
end

-- DEPRECATED fallback: native FolderBrowserDialog via PowerShell on the
-- subprocess worker. Remove once the embedded dialog is confirmed.
function pick_directory_ps()
    if S.picking_dir then return end
    if not IS_WIN then S.status = 'folder picker: Windows only'; return end
    S.picking_dir = true
    S.status = '选择目录中…'

    local preset = (S.cwd or ''):gsub("'", "''")   -- PS single-quote escaping
    -- The picked path is wrapped in sentinels: powershell.exe serializes its
    -- progress/error streams as CLIXML (`<Objs Version=...`) onto stderr when
    -- redirected, and the worker merges stderr into stdout — so the raw output
    -- can contain arbitrary XML noise around the path. Parse ONLY the
    -- sentinel-delimited span. ProgressPreference cuts the noise at the source.
    local ps = "$ProgressPreference='SilentlyContinue'\n" ..
        "[Console]::OutputEncoding=[Text.Encoding]::UTF8\n" ..
        "Add-Type -AssemblyName System.Windows.Forms | Out-Null\n" ..
        "$f = New-Object System.Windows.Forms.FolderBrowserDialog\n" ..
        "$f.ShowNewFolderButton = $true\n" ..
        "$f.SelectedPath = '" .. preset .. "'\n" ..
        "if ($f.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) " ..
        "{ [Console]::Out.Write('<<PICK>>' + $f.SelectedPath + '<<END>>') }\n"
    local cmd = 'powershell -NoProfile -STA -EncodedCommand ' ..
        xutils.base64_encode(utf8_to_utf16le(ps))

    local co = coroutine.create(function()
        local r = subprocess.run({ cmd = cmd, timeout_ms = 300000 })  -- 5 min to pick
        S.picking_dir = false
        local raw = tostring(r and r.stdout or '')
        local out = raw:match('<<PICK>>(.-)<<END>>')
        out = out and out:gsub('^%s+', ''):gsub('%s+$', '') or ''
        if out == '' then S.status = 'ready'; return end   -- dialog cancelled
        apply_cwd(out)
    end)
    local ok, err = coroutine.resume(co)
    if not ok then
        S.picking_dir = false
        S.status = '选择目录失败: ' .. tostring(err)
    end
end

-- Toggle a sidebar mode on/off (clicking the active one closes it).
local function toggle_sidebar(mode)
    if S.sidebar == mode then S.sidebar = nil; return end
    if mode == 'history' then refresh_history(); S.history_scroll = 0 end
    S.sidebar = mode
end

local function load_history_item(it)
    if not it then return end
    local s2 = session.load(it.path, { cfg = S.cfg })
    if not s2 then S.status = 'load failed'; return end
    if S.sess then S.sess.cancelled = true end   -- stop a still-running turn at its next boundary
    s2.tools = registry.to_api_params()
    s2.system = system_prompt.build({ cwd = s2.cwd, project_md = project_md.load(s2.cwd) })
    s2.max_tokens = 4096
    S.sess = s2
    S.cwd = s2.cwd or S.cwd                      -- follow the resumed session's dir
    S.entries = rebuild_entries(s2.messages)
    S.cur, S.text_tail, S.busy = nil, '', false
    S.budget = nil                               -- meter restarts on the next turn
    clear_attachments()
    S.sidebar = nil
    S.status = 'resumed (' .. #s2.messages .. ' msgs)'
end

local function start_rename(it)
    S.renaming = it.id
    S.rename_text = it.title or ''
    S.rename_edit = true
    S.confirm_delete = nil
    S.menu_item = nil
end

local function do_rename(it)
    local name = (S.rename_text or ''):gsub('^%s+', ''):gsub('%s+$', '')
    if name ~= '' then
        session.rename(it.path, name)
        if S.sess and S.sess.id == it.id then S.sess.title = name end
    end
    S.renaming = nil
    refresh_history()
end

local function do_delete(it)
    session.delete(it.path)
    S.confirm_delete = nil
    refresh_history()
end

function new_session()
    if not S.cfg or not S.cfg.api_key then return end
    if S.sess then S.sess.cancelled = true end   -- stop a still-running turn at its next boundary
    local cwd = S.cwd or (S.sess and S.sess.cwd) or '.'
    S.sess = session.new({
        cfg = S.cfg, cwd = cwd, tools = registry.to_api_params(),
        system = system_prompt.build({ cwd = cwd, project_md = project_md.load(cwd) }),
        max_tokens = 4096,
    })
    S.entries = {}
    S.cur, S.text_tail, S.busy = nil, '', false
    S.budget = nil                               -- meter restarts on the next turn
    clear_attachments()
    add('system', 'new session · ' .. S.cfg.model .. '\nEnter 发送 · Ctrl+Enter 换行')
    S.sidebar = nil
    S.status = 'new session'
end

-- Apply a raygui style and derive matching colors for the custom-drawn areas
-- (transcript bg/text, markdown palette, role colors) by reading the style's
-- BACKGROUND/TEXT/accent via get_style. One click re-themes the whole window.
local function apply_theme(name)
    pcall(function() require('styles.' .. name).apply(raygui) end)
    raygui.set_style(raygui.DEFAULT, raygui.TEXT_SIZE, FONT_SIZE)
    raygui.set_style(raygui.DEFAULT, raygui.TEXT_ALIGNMENT, raygui.TEXT_ALIGN_LEFT)
    S.theme = name

    local bg     = unpack_color(raygui.get_style(raygui.DEFAULT, raygui.BACKGROUND_COLOR))
    local txt    = unpack_color(raygui.get_style(raygui.DEFAULT, raygui.TEXT_COLOR_NORMAL))
    local accent = unpack_color(raygui.get_style(raygui.DEFAULT, raygui.BORDER_COLOR_FOCUSED))
    local base   = unpack_color(raygui.get_style(raygui.DEFAULT, raygui.BASE_COLOR_NORMAL))
    local dark   = luma(bg) < 128
    local muted  = mix(txt, bg, 0.42)

    markdown.palette = {
        text    = txt,
        heading = accent,
        code    = dark and { 130, 205, 150, 255 } or { 22, 120, 66, 255 },
        bullet  = mix(accent, txt, 0.35),
        quote   = muted,
        hr      = mix(txt, bg, 0.62),
        table   = mix(txt, bg, 0.18),
    }
    markdown.code_bg = dark and shift(bg, 16) or shift(bg, -14)

    transcript.role_colors.user        = accent
    transcript.role_colors.assistant   = txt
    transcript.role_colors.tool        = dark and { 120, 205, 205, 255 } or { 22, 130, 130, 255 }
    transcript.role_colors.tool_result = muted
    transcript.role_colors.system      = muted
    transcript.role_colors.error       = { 220, 90, 90, 255 }

    S.view.bg = bg
    S.header_bg = base
    S.sidebar_bg = shift(bg, dark and 8 or -8)
    S.view:invalidate()

    pcall(function()
        fs.mkdirp((fs.home():gsub('[/\\]+$', '')) .. '/.xagent')
        fs.write_file(THEME_FILE, name)
    end)
end

local function get_cwd()
    local f = io.popen(IS_WIN and 'cd' or 'pwd')
    if not f then return '.' end
    local s = (f:read('*a') or '.'):gsub('%s+$', '')
    f:close()
    return s
end

local function __init()
    S.cfg = config.load()
    assert(xnet.init())
    assert(subprocess.setup())

    raygui.init(960, 700, 'xagent')
    -- Pre-seed glyphs (eliminates streaming flicker); fall back to ASCII-only.
    if not raygui.load_font('tools/fonts/NotoSansSC-Regular.otf', FONT_SIZE, preseed_charset()) then
        raygui.load_font('tools/fonts/NotoSansSC-Regular.otf', FONT_SIZE)
    end

    -- Color emoji come from the atlas (the font has no emoji glyphs).
    S.emoji_tex = raygui.load_texture('tools/emoji_atlas.png')
    S.view = transcript.new_view({ font_size = FONT_SIZE, raygui = raygui, emoji_tex = S.emoji_tex })
    -- Copy a message's raw Markdown to the clipboard (the "复制" button per answer).
    S.view.on_copy = function(entry)
        raygui.set_clipboard(entry.text or '')
        S.status = 'copied ✓'
    end

    -- Apply the saved (or default) color theme.
    local saved = fs.read_file(THEME_FILE)
    saved = saved and saved:gsub('%s+', '')
    apply_theme((saved and saved ~= '') and saved or 'nord')

    if not S.cfg.api_key or S.cfg.api_key == '' then
        add('error', 'No token. Set XAGENT_AUTH_TOKEN in xagent.local.cfg, then restart.')
        return
    end

    local cwd = get_cwd()
    S.cwd = cwd
    skills.bootstrap(cwd)   -- discover ~/.xagent/skills + <cwd>/.xagent/skills
    local pmd = project_md.load(cwd)
    local sys = system_prompt.build({ cwd = cwd, project_md = pmd })
    S.sess = session.new({
        cfg = S.cfg, cwd = cwd, tools = registry.to_api_params(),
        system = sys, max_tokens = 4096,
    })
    add('system', 'xagent ready · ' .. S.cfg.model .. ' · ' .. cwd ..
        (pmd and '  (project memory loaded)' or '') ..
        '\nEnter 发送 · Ctrl+Enter 换行')
    S.started = true
end

local function __update()
    if not S.view then return end
    if raygui.should_close() then xthread.stop(0); return end

    local W, H = raygui.screen_size()
    raygui.begin()

    -- directory dialog open: freeze the UI underneath (raygui controls via
    -- lock; custom-drawn transcript/list wheel via flags). Unlocked again just
    -- before the dialog itself is drawn at the end of the frame.
    if S.dir_dialog then raygui.lock() end
    S.view.lock_input = S.dir_dialog or nil

    -- top bar: title/status + context meter + settings + history toggles
    S.frame = S.frame + 1
    local hb = S.header_bg
    raygui.draw_rectangle(0, 0, W, 38, hb[1], hb[2], hb[3], hb[4])
    local status_text = S.status
    if S.busy then   -- thinking dots: . .. ... cycling (~3 steps/second)
        status_text = status_text .. ' ' .. ('.'):rep(1 + math.floor(S.frame / 20) % 3)
    end
    raygui.label(12, 8, W - 260, 24, 'xagent  ·  ' ..
        (S.cfg and S.cfg.model or '?') .. '  ·  ' .. status_text)

    -- context-usage meter: token count + a thin bar filling toward the window.
    -- Green normally, amber on 'warning', red on 'error'/'blocking' (compaction
    -- imminent / just happened).
    local b = S.budget
    if b then
        local mw, mx, my, mh = 96, W - 196, 15, 8
        local kt = b.estimated >= 1000 and string.format('%.1fk', b.estimated / 1000)
            or tostring(b.estimated)
        raygui.label(mx - 70, 8, 66, 24, kt .. ' tok')
        local pct = math.min(1, b.percent or 0)
        local fill = { 110, 170, 120, 255 }
        if b.state == 'warning' then fill = { 210, 175, 70, 255 }
        elseif b.state ~= 'normal' then fill = { 215, 95, 85, 255 } end
        local trk = mix(S.view.bg or { 40, 40, 40, 255 },
            transcript.role_colors.system or { 120, 120, 120, 255 }, 0.5)
        raygui.draw_rectangle(mx, my, mw, mh, trk[1], trk[2], trk[3], 255)
        raygui.draw_rectangle(mx, my, math.floor(mw * pct), mh, fill[1], fill[2], fill[3], 255)
    end

    if raygui.button(W - 88, 6, 38, 28, '#141#') then toggle_sidebar('settings') end   -- gear
    if raygui.button(W - 46, 6, 38, 28, '#139#') then toggle_sidebar('history') end    -- clock

    -- left sidebar (inline, default hidden); shifts the main area right
    local lx = 0
    if S.sidebar then
        lx = SIDEBAR_W
        local sb = S.sidebar_bg
        raygui.draw_rectangle(0, 40, SIDEBAR_W, H - 40, sb[1], sb[2], sb[3], sb[4])
        if S.sidebar == 'history' then
            raygui.label(10, 46, SIDEBAR_W - 90, 22, '历史会话')
            if raygui.button(SIDEBAR_W - 78, 44, 70, 26, '新会话') then new_session() end

            -- current working directory (new sessions start here); clicking it
            -- opens the NATIVE folder picker (async — the GUI keeps rendering)
            if raygui.button(8, 74, SIDEBAR_W - 16, 26,
                '◇ ' .. sanitize_label(dir_tail(S.cwd)) ..
                (S.picking_dir and '  ·  选择中…' or '  ·  点击切换目录')) then
                pick_directory()
            end

            -- group sessions by working directory (first appearance ≈ recency)
            local items = S.history_items
            local rows, groups = {}, {}
            for _, it in ipairs(items) do
                local key = dir_key(it.cwd or '?')
                local g = groups[key]
                if not g then
                    g = { dir = it.cwd or '?', items = {} }
                    groups[key] = g
                    rows[#rows + 1] = { header = g }
                end
                g.items[#g.items + 1] = it
            end
            do  -- flatten: header rows interleaved with their item rows
                local flat = {}
                for _, r in ipairs(rows) do
                    flat[#flat + 1] = r
                    for _, it in ipairs(r.header.items) do flat[#flat + 1] = { item = it } end
                end
                rows = flat
            end

            local list_top = 108
            local view_h = H - list_top - 8
            local row_h = FONT_SIZE + 16
            local max_scroll = math.max(0, #rows * row_h - view_h)

            -- natural pixel scroll (only when the pointer is over the list;
            -- suppressed while the directory dialog overlays the UI)
            local mx, my = raygui.get_mouse()
            local over_list = not S.dir_dialog and mx >= 0 and mx <= SIDEBAR_W
                and my >= list_top and my <= list_top + view_h
            if over_list then
                local d = raygui.get_wheel()
                if d ~= 0 then S.history_scroll = S.history_scroll - d * row_h * 1.5; S.menu_item = nil end
            end
            if S.history_scroll > max_scroll then S.history_scroll = max_scroll end
            if S.history_scroll < 0 then S.history_scroll = 0 end

            if #items == 0 then
                raygui.label(10, list_top + 6, SIDEBAR_W - 20, 22, '（暂无会话）')
            else
                local kw = 26                              -- ⋮ / icon button width
                local title_w = SIDEBAR_W - 16             -- FULL width; ⋮ overlays on hover
                local kx = SIDEBAR_W - 8 - kw              -- right-edge button
                local kx2 = SIDEBAR_W - 8 - 2 * kw - 4     -- second-from-right button
                -- virtualize: only rows near the viewport; the scissor clips the edges.
                local first = math.max(1, math.floor(S.history_scroll / row_h) - 2)
                local last  = math.min(#rows, math.floor((S.history_scroll + view_h) / row_h) + 3)

                raygui.begin_scissor(0, list_top, SIDEBAR_W, view_h)
                for i = first, last do
                    local row = rows[i]
                    local ry = list_top + (i - 1) * row_h - S.history_scroll
                    if ry + row_h > list_top and ry < list_top + view_h then   -- skip fully off-screen
                        local rh = row_h - 5
                        if row.header then
                            -- directory group header; click switches the working dir
                            local cur = dir_key(row.header.dir) == dir_key(S.cwd)
                            if raygui.button(8, ry, title_w, rh,
                                -- ◆ not ▸: NotoSansSC lacks U+25B8 (renders '?');
                                -- GB2312 geometric shapes (●◆◇○) are always present
                                (cur and '● ' or '◆ ') .. sanitize_label(dir_tail(row.header.dir))) then
                                apply_cwd(row.header.dir)
                            end
                        else
                            local it = row.item
                            if it.id == S.renaming then
                                S.rename_text, S.rename_edit = raygui.textbox(8, ry, title_w - 2 * kw - 8, rh, S.rename_text, S.rename_edit)
                                if raygui.button(kx2, ry, kw, rh, '#112#') then do_rename(it) end        -- ✓ 保存
                                if raygui.button(kx, ry, kw, rh, '#113#') then S.renaming = nil end       -- ✗ 取消
                            elseif it.id == S.confirm_delete then
                                raygui.label(12, ry + 4, title_w - 2 * kw - 30, rh, '删除？')
                                if raygui.button(kx2, ry, kw, rh, '#112#') then do_delete(it) end         -- ✓ 确认删除
                                if raygui.button(kx, ry, kw, rh, '#113#') then S.confirm_delete = nil end  -- ✗ 取消
                            elseif S.menu_item == it then
                                -- ⋮ clicked: reveal 修改 / 删除 on this row
                                local bw = (title_w - kw - 8) / 2
                                if raygui.button(8, ry, bw, rh, '修改') then start_rename(it) end
                                if raygui.button(8 + bw + 4, ry, bw, rh, '删除') then
                                    S.confirm_delete = it.id; S.renaming = nil; S.menu_item = nil
                                end
                                if kebab_button(kx, ry, kw, rh, markdown.palette.text) then S.menu_item = nil end   -- 再点收起
                            else
                                -- full-width title; the ⋮ OVERLAYS its right edge on hover,
                                -- so a click there must not also load the session.
                                local over_row = over_list and my >= ry and my < ry + rh
                                local over_kebab = over_row and mx >= kx and mx < kx + kw
                                local clicked = raygui.button(8, ry, title_w, rh, '   ○  ' .. sanitize_label(it.title))
                                if over_row then
                                    if kebab_button(kx, ry, kw, rh, markdown.palette.text) then S.menu_item = it end
                                end
                                if clicked and not over_kebab then load_history_item(it) end
                            end
                        end
                    end
                end
                raygui.end_scissor()
            end
        else -- settings
            raygui.label(10, 46, SIDEBAR_W - 20, 22, '配色方案')
            local by = 78
            for _, t in ipairs(THEMES) do
                local lbl = (t == S.theme) and ('●  ' .. t) or ('    ' .. t)
                if raygui.button(10, by, SIDEBAR_W - 20, 32, lbl) then apply_theme(t) end
                by = by + 38
            end
            raygui.label(12, by + 12, SIDEBAR_W - 24, 22, '模型: ' .. (S.cfg and S.cfg.model or '?'))
        end
    end

    -- transcript (right of the sidebar); attachments shrink it a bit more
    local input_h = 96
    local att_h = (#S.attachments > 0) and 58 or 0
    local tx, ty = lx + 8, 44
    local tw, th = W - lx - 16, H - ty - input_h - att_h - 12
    S.view:draw(S.entries, tx, ty, tw, th)

    -- attachment strip: pasted images as thumbnails, each with a ✗ to remove
    if att_h > 0 then
        local ax, ay, thumb = lx + 8, H - input_h - att_h - 2, 48
        local remove_i
        for i, a in ipairs(S.attachments) do
            local tw2 = math.max(24, math.min(96, math.floor(thumb * a.w / a.h + 0.5)))
            if a.tex then raygui.draw_texture(a.tex, ax, ay + 4, tw2, thumb) end
            if raygui.button(ax + tw2 - 16, ay + 4, 16, 16, '#113#') then remove_i = i end
            ax = ax + tw2 + 10
        end
        raygui.label(ax + 4, ay + 16, 220, 22, #S.attachments .. ' 张图片将随消息发送')
        if remove_i then
            local a = table.remove(S.attachments, remove_i)
            if a and a.tex then pcall(raygui.unload_texture, a.tex) end
        end
    end

    -- input: Enter sends, Ctrl+Enter inserts a newline (no Send button).
    -- textbox_multi reads raw keys (not raygui-locked), so its edit mode is
    -- forced off while the directory dialog is open.
    local iy = H - input_h - 4
    local submitted, new_edit
    S.input, new_edit, submitted = raygui.textbox_multi(
        lx + 8, iy, W - lx - 16, input_h, S.input,
        (not S.dir_dialog) and S.input_edit or false, true)
    if not S.dir_dialog then
        S.input_edit = new_edit
        if submitted then submit() end
    end

    -- while running: a stop square overlays the input's top-right corner
    -- (clicking requests cancellation at the next turn boundary)
    if S.busy then
        local sb = 26
        if stop_button(W - 14 - sb, iy + 6, sb, sb, { 215, 95, 85, 255 }) then
            if S.sess then S.sess.cancelled = true end
            S.status = '停止中'
        end
    end

    -- Ctrl+V with an image on the clipboard (flag set inside textbox_multi):
    -- grab it as PNG, make a thumbnail texture, queue as an attachment.
    local png, pw, ph = raygui.take_pasted_image()
    if png then
        local tex = raygui.load_texture_mem(png)
        S.attachments[#S.attachments + 1] = { png = png, w = pw, h = ph, tex = tex }
        S.status = '已附加图片 ' .. pw .. '×' .. ph
    end

    -- directory dialog: drawn LAST (on top of everything), after unlocking —
    -- the lock above only freezes the UI underneath it.
    if S.dir_dialog then
        raygui.unlock()
        local status, dir = raygui.file_dialog()
        if status == 'select' then
            S.dir_dialog = false
            if dir == '::' then          -- Select pressed on the drive-list view
                S.status = 'ready'
            else
                apply_cwd(dir)           -- dir pick: current dialog directory; file ignored
            end
        elseif status ~= 'active' then
            S.dir_dialog = false
            S.status = 'ready'
        end
    end

    raygui.finish()
end

local function __uninit()
    if S.view then raygui.close() end
    if xnet and xnet.uninit then xnet.uninit() end
end

return {
    __tick_ms = 16,
    __thread_handle = router.handle,
    __init = __init,
    __update = __update,
    __uninit = __uninit,
}
