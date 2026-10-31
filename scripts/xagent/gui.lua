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
local mcp           = require('xagent.mcp.bootstrap')
local mcp_registry  = require('xagent.mcp.registry')
local session       = require('xagent.session.session')
local transcript    = require('xagent.ui.transcript')
local markdown      = require('xagent.ui.markdown')
local complete      = require('xagent.ui.complete')
local text          = dofile('scripts/core/share/xtext.lua') ---@type xtext
local fs            = dofile('scripts/core/share/xfs.lua') ---@type xfs
local async         = dofile('scripts/core/share/xasync.lua') ---@type xasync
local xproxy        = dofile('scripts/core/share/xproxy.lua')
local api_log       = require('xagent.llm.api_log')
local user_input    = require('xagent.ui.user_input')
local surface       = require('xagent.ui.surface')

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
registry.register(require('xagent.tools.ask_user_question'))


local skills    = require('xagent.skills')
local open_url  = require('xagent.ui.open_url')
local tokens    = require('xagent.context.tokens')

local function ktok(v)
    v = tonumber(v) or 0
    if v >= 1000 then return string.format('%.1fk', v / 1000) end
    return tostring(v)
end

-- "输入 120.3k（缓存 92%） · 输出 3.1k". Input counts cache hits and writes too
-- (the codecs report input_tokens without them), so the percentage says how
-- much of what the request read was billed at cache price.
local function usage_label(u)
    if not u then return '' end
    local s = '输入 ' .. ktok(tokens.total_input_tokens(u))
    local r = tokens.cache_hit_ratio(u)
    if r then s = s .. string.format('（缓存 %d%%）', math.floor(r * 100 + 0.5)) end
    return s .. ' · 输出 ' .. ktok(u.output_tokens)
end

local IS_WIN = (package.config:sub(1, 1) == '\\')
local FONT_SIZE = 16
-- Rasterize above the largest UI heading (26px), then draw at logical sizes.
local FONT_ATLAS_SIZE = 32

-- Starting per-turn output cap. A bigger cap is free — you only pay for tokens
-- actually produced — but a TOO-SMALL cap silently breaks big outputs: an
-- AetherViz single-file page (Three.js + KaTeX + heavy CSS) can run ~10k+ tokens
-- and at 8192 the tool_use JSON gets truncated mid-stream (→ unparseable args).
-- 16384 fits those pages; if the model is STILL cut off the loop auto-escalates
-- max_tokens up to the model's output ceiling (see loop.MAX_TOKENS_CEILING).
-- Override the start value with XAGENT_MAX_TOKENS (NOTE: must stay ≤ the model's
-- hard output limit, or every request fails).
local MAX_TOKENS = tonumber(xutils.get_config('XAGENT_MAX_TOKENS'))
    or tonumber(os.getenv('XAGENT_MAX_TOKENS')) or 16384

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
    range(0x2010, 0x2027)   -- hyphens / en+em dashes (—, U+2014) / quotes / bullet / ellipsis
    range(0x2190, 0x21B5)   -- arrows
    range(0x2200, 0x22FF)   -- mathematical operators (≈ ≠ ≤ ≥ ∞ ∑ √ ∈ …)
    range(0x25A0, 0x25FF)   -- geometric shapes (○ ● ◦ ■ □ ▲ ▶ …)
    range(0x2600, 0x26FF)   -- misc symbols (★ ☆ ☰ ☐ ☑ …; only those in the font load)
    -- specific common symbols outside the ranges above
    for _, cp in ipairs({ 0x00A0, 0x00B0, 0x00B1, 0x00B7, 0x00D7, 0x00F7, 0x2039, 0x203A,
                          0x00A2, 0x00A3, 0x00A5, 0x00A9, 0x00AE, 0x20AC, 0x2122,
                          0xFE19,            -- ︙ vertical kebab (the font lacks ⋮ U+22EE)
                          0x2713, 0x2714, 0x2705, 0x274C, 0x2714 }) do
        t[#t + 1] = utf8.char(cp)
    end
    return table.concat(t)
end

-- Per-conversation state lives on a TAB (S.tabs[i]); S holds the tab list plus
-- the active index and all app-level (cross-tab) state. Each tab carries its own
-- model profile, session, transcript view, input, busy/status, budget, pending
-- confirm, attachments and working directory — so several models can run at once
-- and a background tab keeps streaming while another is shown. A tab looks like:
--   { id, cfg, sess, view, entries={}, cur, text_tail='',
--     input='', input_edit=true, busy=false, status='ready', budget,
--     pending_confirm, attachments={}, cwd='.' }
local S = {
    tabs = {},                 -- list of tabs (one per conversation)
    active = 1,                -- index of the active tab
    profiles = nil,            -- configured LLM profiles (config.load_profiles())
    tab_picker = false,        -- the "+" new-tab model-picker popup is open
    plus_x = 0,                -- screen x of the "+" button (picker anchor)
    next_tab_id = 1,
    -- settings page: theme/model dropdowns + the add-model form
    dd_open = nil,             -- which dropdown is open: nil | 'theme' | 'model'
    dd_anchor = nil,           -- { x, y, w } of the open dropdown button
    model_sel = 1,             -- selected profile index in the model dropdown
    add_model = nil,           -- the add-model form state while it's open
    -- tool permission mode: 'write' = auto-run (default), 'ask' = confirm each
    -- state-changing tool before it runs. The parked await lives per-tab.
    mode = 'write',
    emoji_tex = nil,
    on_copy = nil,             -- copy handler shared by every tab's view
    view_bg = nil,             -- transcript bg from the active theme (new views use it)
    started = false,
    -- left sidebar (the ≡ button): nil | 'history' — projects and their sessions
    sidebar = nil,
    -- right panel (from the ⋮ menu): nil | 'files' | 'model' | 'mcp' | 'apilog' | 'appearance'
    panel = nil,
    history_items = {},
    history_scroll = 0,        -- pixel scroll offset of the history list
    history_query = '',        -- history search text (title substring)
    history_query_edit = false,
    history_collapsed = false,
    history_group_open = {},  -- directory key -> explicit expanded/collapsed override
    files_open = {},           -- dir_key(cwd) -> { [rel_dir] = true } expanded tree nodes
    files_scroll = 0,          -- pixel scroll of the file tree
    -- API request/response log panel (in-memory, this run only)
    apilog_scroll = 0,         -- pixel scroll of the API-log list
    apilog_selected = nil,     -- the log record whose detail is shown in the main area
    log_view = nil,            -- transcript view used to render the selected record
    renaming = nil,            -- id of the session being renamed inline
    rename_text = '',
    rename_edit = false,
    confirm_delete = nil,      -- id of the session awaiting delete confirmation
    menu_item = nil,           -- history item whose ⋮ menu is open
    menu_y = 0,                -- screen y of that menu
    -- theme
    theme = 'soft',
    header_bg = { 30, 30, 38, 255 },
    sidebar_bg = { 26, 26, 32, 255 },
    picking_dir = false,       -- a folder dialog is currently open
    frame = 0,                 -- frame counter (drives the thinking-dots animation)
    -- input autocomplete (/ commands, @ file refs): computed from the ACTIVE tab
    menu = nil,                -- { kind, items, prefix } computed each frame, or nil
    menu_sel = 1,              -- highlighted item (1-based)
    menu_off = 0,              -- first visible row when the list scrolls
    menu_dismissed_for = nil,  -- input text the user pressed Esc on (re-show on edit)
    dir_cache = {},            -- abspath -> immediate children, for the @ picker
}

local SIDEBAR_W = 300
local HEADER_H  = 38               -- top bar (title/status/meter/toggles)
local TABBAR_H  = 40               -- tab strip below the top bar
local TOP       = HEADER_H + TABBAR_H   -- top y of the sidebar / main content
local THEMES = { 'sand', 'soft', 'candy', 'cyber', 'dark' }
local THEME_FILE = (fs.home():gsub('[/\\]+$', '')) .. '/.xagent/theme'
-- Last picked working directory, persisted so the NEXT app launch defaults its
-- initial session to it (mirrors how THEME_FILE persists the color theme).
local CWD_FILE   = (fs.home():gsub('[/\\]+$', '')) .. '/.xagent/cwd'

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

-- Small hand-drawn "×" centered in (x,y,w,h). Used for the tab close affordance:
-- drawn directly (NO button frame) so it doesn't render a second border inside
-- the tab. Same rationale as kebab/stop — a label '#113#' icon code isn't
-- reliable in this wrapper, and a nested button looks misaligned.
local function draw_x(x, y, w, h, col, r)
    r = r or 4
    local cx, cy = x + w / 2, y + h / 2
    for d = -r, r do
        raygui.draw_rectangle(math.floor(cx + d - 1), math.floor(cy + d - 1), 2, 2,
            col[1], col[2], col[3], col[4] or 255)
        raygui.draw_rectangle(math.floor(cx + d - 1), math.floor(cy - d - 1), 2, 2,
            col[1], col[2], col[3], col[4] or 255)
    end
end

-- Small hand-drawn caret (▼ / ▲) centered at (cx, cy) — the dropdown indicator.
-- Hand-drawn for the same reason as draw_x: triangle glyphs aren't reliable here.
local function draw_caret(cx, cy, col, up)
    for k = 0, 3 do
        local w = 7 - 2 * k
        local row = up and (3 - k) or k
        raygui.draw_rectangle(math.floor(cx - w / 2), math.floor(cy - 2 + row),
            math.max(1, w), 1, col[1], col[2], col[3], col[4] or 255)
    end
end

-- Borderless button: its background matches `bg` until hovered / pressed,
-- when it takes a slightly shifted tint — the toolbar look of the header and
-- the composer row. raygui has no such style, so the BUTTON colors are swapped
-- in for this one call and restored after; raygui still owns click and lock
-- handling (modals freeze it like any other control).
local FLAT_PROPS
local function pack_color(c)
    return (c[1] << 24) | (c[2] << 16) | (c[3] << 8) | (c[4] or 255)
end
local function flat_button(x, y, w, h, label, bg, hover_bg)
    bg = bg or S.view_bg or { 240, 240, 240, 255 }
    local B = raygui.BUTTON
    FLAT_PROPS = FLAT_PROPS or {
        raygui.BORDER_WIDTH,
        raygui.BASE_COLOR_NORMAL, raygui.BORDER_COLOR_NORMAL,
        raygui.BASE_COLOR_FOCUSED, raygui.BORDER_COLOR_FOCUSED,
        raygui.BASE_COLOR_PRESSED, raygui.BORDER_COLOR_PRESSED,
    }
    local saved = {}
    for i, prop in ipairs(FLAT_PROPS) do saved[i] = raygui.get_style(B, prop) end
    local d = (luma(bg) < 128) and 1 or -1        -- lighten on dark themes, darken on light
    local base = pack_color(bg)
    local hover, press = pack_color(shift(bg, 14 * d)), pack_color(shift(bg, 26 * d))
    if hover_bg then hover, press = pack_color(hover_bg), pack_color(shift(hover_bg, -20)) end
    local vals = { 0, base, base, hover, hover, press, press }
    for i, prop in ipairs(FLAT_PROPS) do raygui.set_style(B, prop, vals[i]) end
    local clicked = raygui.button(x, y, w, h, label)
    for i, prop in ipairs(FLAT_PROPS) do raygui.set_style(B, prop, saved[i]) end
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

-- Active tab accessor — per-conversation state lives on the tab, not S.
local function T() return S.tabs[S.active] end

local function add(tab, role, text)
    local e = { role = role, text = text or '' }
    tab.entries[#tab.entries + 1] = e
    return e
end

-- Transient "thinking…" line shown in the transcript while a turn is busy but
-- nothing has appeared yet — including the long, INVISIBLE stretch where a big
-- tool argument (e.g. a whole HTML document) streams into the tool call. It's
-- a normal entry kept as the LAST item, with dots animating off S.frame; removed
-- the instant real content (text or a tool card) shows up, or the turn ends.
local function clear_thinking(tab)
    local th = tab.thinking
    if not th then return end
    for i = #tab.entries, 1, -1 do
        if tab.entries[i] == th then table.remove(tab.entries, i); break end
    end
    tab.thinking = nil
end

local function update_thinking(tab)
    -- Waiting for output: busy, nothing streaming yet, not parked on a
    -- permission prompt (that has its own UI).
    if not (tab.busy and not tab.cur and not tab.pending_confirm and not tab.pending_input) then
        clear_thinking(tab); return
    end
    local text = 'thinking' .. ('.'):rep(1 + math.floor(S.frame / 20) % 3)
    if tab.thinking and tab.entries[#tab.entries] == tab.thinking then
        tab.thinking.text = text                 -- already last: just refresh dots
    else
        clear_thinking(tab)                      -- a new entry got appended after it
        tab.thinking = add(tab, 'thinking', text)
    end
end

-- forward declarations (referenced before their definitions below)
local new_session, new_tab, close_tab, select_tab

local function compact(v)
    local ok, s = pcall(xutils.json_pack, v)
    if not ok then return tostring(v) end
    if #s > 160 then s = s:sub(1, 160) .. '...' end
    return s
end

-- Per-session permission gate handed to the agent (ctx.confirm). In 'write' mode
-- it auto-allows; in
-- 'ask' mode it parks the agent coroutine on an await until the user clicks
-- 允许/拒绝. The await lives on the OWNING tab, so a background tab can park its
-- own confirm (surfaced via a '!' on its tab button) without blocking others.
-- Runs inside the agent coroutine, so async.await is safe here.
local function make_confirm(tab, sess)
    return function(req)
        if sess.cancelled or tab.sess ~= sess then return false end
        if S.mode ~= 'ask' then return true end
        return async.await(function(resolve)
            tab.pending_confirm = { req = req, resolve = resolve }
        end)
    end
end

local function cancel_session(tab)
    if tab.sess then tab.sess.cancelled = true end
    user_input.cancel(tab)
    if tab.pending_confirm then
        local pc = tab.pending_confirm; tab.pending_confirm = nil; pc.resolve(false)
    end
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

local function flush_tail(tab)
    if tab.cur and tab.text_tail ~= '' then tab.cur.text = tab.cur.text .. tab.text_tail end
    tab.text_tail = ''
    tab.cur = nil
end

local function on_event(tab, ev)
    if ev.type == 'text' then
        if not tab.cur then tab.cur = add(tab, 'assistant', '') end
        local complete, tail = utf8_split_complete(tab.text_tail .. ev.text)
        tab.text_tail = tail
        tab.cur.text = tab.cur.text .. complete
    elseif ev.type == 'tool_use' then
        flush_tail(tab)
        add(tab, 'tool', '> ' .. ev.name .. '  ' .. compact(ev.input))
    elseif ev.type == 'tool_result' then
        flush_tail(tab)
        local c = (ev.result and ev.result.content) or ''
        if type(c) ~= 'string' then c = '[non-text result]' end
        if #c > 600 then c = c:sub(1, 600) .. '\n  ...' end
        add(tab, 'tool_result', c)
    elseif ev.type == 'budget' then
        tab.budget = ev.budget
    elseif ev.type == 'compact_start' then
        flush_tail(tab)
        tab.status = '压缩上下文'        -- distinct status (busy dots animate); not frozen
    elseif ev.type == 'compact' then
        flush_tail(tab)
        -- A concise notice ONLY — the summary text belongs in the message
        -- history (for the model), not dumped into the user's transcript.
        if ev.did_compact then
            add(tab, 'system', '📚 上下文已压缩' ..
                (ev.kept_tail and ('，保留最近 ' .. ev.kept_tail .. ' 条消息') or ''))
            tab.status = '思考中'         -- back to the answer that follows compaction
        elseif ev.error then
            add(tab, 'error', '压缩失败: ' .. tostring(ev.error))
        end
        -- did_micro alone is silent — it's background housekeeping near the
        -- context limit, not something to announce in the transcript.
    elseif ev.type == 'truncated_retry' then
        -- The turn was cut off at max_tokens mid-output; the loop is re-running it
        -- with a larger cap. Drop the partial assistant text so the re-stream
        -- doesn't duplicate it; keep the turn busy (thinking dots continue).
        if tab.cur then
            for i = #tab.entries, 1, -1 do
                if tab.entries[i] == tab.cur then table.remove(tab.entries, i); break end
            end
        end
        tab.text_tail = ''; tab.cur = nil
        tab.status = string.format('输出较大，提升上限重试 (%s→%s)',
            tostring(ev.from or '?'), tostring(ev.to or '?'))
    elseif ev.type == 'done' then
        flush_tail(tab); clear_thinking(tab); tab.busy = false
        tab.status = ev.stop_reason == 'cancelled' and '已停止' or '完成'
        -- This turn's totals over every request it made (tool round-trips too);
        -- the header shows them next to the status until the next turn ends.
        if ev.usage and tokens.total_input_tokens(ev.usage) > 0 then
            tab.last_usage = ev.usage
        end
    elseif ev.type == 'error' then
        flush_tail(tab); clear_thinking(tab); add(tab, 'error', 'ERROR: ' .. tostring(ev.error)); tab.busy = false; tab.status = 'error'
    end
end

-- Bind on_event to the TAB and the session that STARTED the run. Events always
-- route to their owning tab (so a background tab keeps streaming while another
-- is shown); the guard drops late events (text, compaction summary, done) once
-- the tab has replaced that session via /new or a history load.
local function make_on_event(tab, sess)
    return function(ev)
        if tab.sess ~= sess then return end
        on_event(tab, ev)
    end
end

-- The desktop UI uses the existing agent prompt without extra MCP instructions.
local function build_system(cwd)
    return system_prompt.build({ cwd = cwd, project_md = project_md.load(cwd) })
end

local function handle_slash(text)
    local orig_cmd, rest = text:match('^/(%S+)%s*(.*)$')
    if not orig_cmd then return false end
    local cmd = orig_cmd:lower()
    local tab = T()
    if cmd == 'compact' then
        tab.input = ''; tab.busy = true; tab.status = '压缩中…'; tab.cur = nil
        local sess = tab.sess
        local handler = make_on_event(tab, sess)
        local co = coroutine.create(function()
            sess:compact(rest ~= '' and rest or nil, handler)
            pcall(function() sess:save() end)
            if tab.sess == sess then tab.busy = false; tab.status = 'ready' end
        end)
        local ok, err = coroutine.resume(co)
        if not ok then handler({ type = 'error', error = err }) end
        return true
    elseif cmd == 'context' then
        tab.input = ''
        local b = tab.budget
        if b then
            add(tab, 'system', string.format('📊 上下文 ~%d / %d tokens (%.0f%%)  ·  状态 %s  ·  自动压缩阈值 %d',
                b.estimated, b.context_window, b.percent * 100, b.state, b.auto_compact_threshold))
        else
            add(tab, 'system', '📊 暂无上下文用量数据（发送一条消息后可见）')
        end
        return true
    elseif cmd == 'clear' or cmd == 'new' then
        tab.input = ''
        new_session()
        return true
    elseif cmd == 'mcp' then
        tab.input = ''
        local lines = { 'MCP 服务器:' }
        local conns = mcp_registry.connections()
        if S.mcp_status == 'connecting' then
            lines[#lines + 1] = '（连接中…）'
        end
        if #conns == 0 then
            lines[#lines + 1] = '（未配置；在 ~/.xagent/mcp.json 或 <当前目录>/.mcp.json ' ..
                '中添加 mcpServers，重启后生效）'
        else
            for _, c in ipairs(conns) do
                local entry = mcp_registry.get(c.name)
                local n = entry and #entry.tools or 0
                local icon = (c.status == 'connected' and '●')
                    or (c.status == 'pending' and '◐') or '○'
                local line = string.format('%s %s  [%s]  %d 工具', icon, c.name, c.status, n)
                if c.error then line = line .. '  — ' .. tostring(c.error) end
                lines[#lines + 1] = line
            end
        end
        add(tab, 'system', table.concat(lines, '\n'))
        return true
    elseif cmd == 'help' then
        tab.input = ''
        local lines = { '可用命令:', '/compact [重点]  压缩上下文', '/context  查看上下文用量',
                        '/mcp  查看 MCP 服务器', '/new  新会话（当前标签）', '/help  帮助',
                        '（顶部 + 新建标签可同时跑多个模型）' }
        local sk = require('xagent.skills').all_user_invocable()
        if #sk > 0 then
            lines[#lines + 1] = ''
            lines[#lines + 1] = '技能(/<名称> [参数]):'
            for _, s in ipairs(sk) do lines[#lines + 1] = '/' .. s.name .. '  ' .. (s.description or '') end
        end
        add(tab, 'system', table.concat(lines, '\n'))
        return true
    end

    -- Not a built-in: maybe a user-invoked skill (/<skill-name> [args]).
    local skill = require('xagent.skills').find_invocable(orig_cmd)
    if skill then
        tab.input = ''
        local prompt = require('xagent.skills').render_body(skill, rest, tab.sess and tab.sess.id or 'unknown-session')
        add(tab, 'user', text)                -- echo what the user typed
        tab.busy = true; tab.status = '思考中'; tab.cur = nil
        local sess = tab.sess
        local handler = make_on_event(tab, sess)
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

local function clear_attachments(tab)
    for _, a in ipairs(tab.attachments) do
        if a.tex then pcall(raygui.unload_texture, a.tex) end
    end
    tab.attachments = {}
end

local function submit()
    local tab = T()
    if tab.busy or not tab.sess then return end
    if not tab.cfg or (not tab.cfg.auth_type and (not tab.cfg.api_key or tab.cfg.api_key == '')) then
        tab.status = '该模型未配置 token'; return
    end
    local text = (tab.input or ''):gsub('^%s+', ''):gsub('%s+$', '')
    if text == '' and #tab.attachments == 0 then return end
    tab.welcome = false
    if text:sub(1, 1) == '/' and handle_slash(text) then return end

    -- With attachments the user turn becomes content BLOCKS: image blocks
    -- (base64 PNG, the Anthropic image source format) + an optional text block.
    local content, shown = text, text
    if #tab.attachments > 0 then
        content = {}
        local marks = {}
        for _, a in ipairs(tab.attachments) do
            content[#content + 1] = { type = 'image', source = {
                type = 'base64', media_type = 'image/png',
                data = xutils.base64_encode(a.png),
            } }
            marks[#marks + 1] = string.format('[图片 %d×%d]', a.w, a.h)
        end
        if text ~= '' then content[#content + 1] = { type = 'text', text = text } end
        shown = table.concat(marks, ' ') .. (text ~= '' and ('\n' .. text) or '')
    end

    add(tab, 'user', shown)
    clear_attachments(tab)
    tab.input = ''
    tab.busy = true
    tab.status = '思考中'
    tab.cur = nil
    local sess = tab.sess
    local handler = make_on_event(tab, sess)
    sess.cancelled = nil    -- a previous stop-click must not kill this new turn
    sess:add_user(content)

    local co = coroutine.create(function()
        sess:run(handler)
        pcall(function() sess:save() end)   -- save the session that RAN (the active tab may have changed)
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
                        -- The skills listing the session injects is for the
                        -- model, not something the user typed.
                        if (b.text or ''):sub(1, 17) ~= '<system-reminder>' then
                            parts[#parts + 1] = b.text or ''
                        end
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

-- Like sanitize_label, but cut by WIDTH (characters dropped, '…' appended)
-- until it fits `maxw` pixels in the UI font at `size`, instead of at a fixed
-- byte count — for text sharing its row with other controls.
local FIT_MAX_CHARS = 160   -- more than any row can show at the smallest glyph width

local function fit_label(s, maxw, size)
    s = tostring(s or ''):gsub('[\r\n;]', ' ')
    local n = utf8.len(s)
    if not n then s = text.valid_utf8(s); n = utf8.len(s) or #s end
    -- A session title can be a whole pasted prompt. Measuring it in full —
    -- once per dropped character, for every row, every frame — froze the
    -- history list, so long text is pre-cut and the fit is a binary search.
    local cut = n > FIT_MAX_CHARS
    if cut then s = s:sub(1, utf8.offset(s, FIT_MAX_CHARS + 1) - 1); n = FIT_MAX_CHARS end
    if not cut and raygui.measure_text(s, size) <= maxw then return s end
    local function prefix(k) return s:sub(1, (utf8.offset(s, k + 1) or (#s + 1)) - 1) .. '…' end
    local lo, hi = 0, n            -- longest prefix whose "prefix…" fits
    while lo < hi do
        local mid = math.floor((lo + hi + 1) / 2)
        if raygui.measure_text(prefix(mid), size) <= maxw then lo = mid else hi = mid - 1 end
    end
    return prefix(lo)
end

local function refresh_history()   -- reload items; keeps scroll, clears inline modes
    S.history_items = session.list()
    S.renaming = nil
    S.confirm_delete = nil
    S.menu_item = nil
end

-- Persist the chosen working dir so the next app launch defaults to it.
-- Best-effort (same pattern as the theme file); failure is silent.
local function save_cwd(dir)
    pcall(function()
        fs.mkdirp((fs.home():gsub('[/\\]+$', '')) .. '/.xagent')
        fs.write_file(CWD_FILE, dir)
    end)
end

-- Switch the working directory and START A NEW SESSION rooted in it. Keeps the
-- caller's UTF-8 string as-is (picker/dialog paths are already canonical; see
-- dir_exists for why we never round-trip the path through cmd's output). The
-- choice is persisted so the next launch opens its first session here too.
-- Operates on the ACTIVE tab: each tab has its own working directory.
local function apply_cwd(dir)
    dir = tostring(dir or ''):gsub('^%s+', ''):gsub('%s+$', '')
    if #dir > 3 then dir = dir:gsub('[\\/]+$', '') end   -- keep "C:\" intact
    if dir ~= '' and dir_exists(dir) then
        T().cwd = dir
        skills.bootstrap(dir)   -- reload project skills for the new working dir
        save_cwd(dir)
        new_session()           -- immediately switch to a fresh session here (this tab)
    else
        print('[xagent] apply_cwd failed for: ' .. dir)   -- diagnosis via xlog
        T().status = '目录不存在: ' .. dir
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
        local root = IS_WIN and (((T().cwd or ''):match('^%a:') or 'C:') .. '\\') or '/'
        raygui.file_dialog_open(root, 600, 440, true)    -- dirs only
        S.dir_dialog = true
        T().status = '选择目录…（进入目标目录后点击文件夹确认图标）'
        return
    end
    return pick_directory_ps()
end

-- DEPRECATED fallback: native FolderBrowserDialog via PowerShell on the
-- subprocess worker. Remove once the embedded dialog is confirmed.
function pick_directory_ps()
    if S.picking_dir then return end
    if not IS_WIN then T().status = 'folder picker: Windows only'; return end
    S.picking_dir = true
    T().status = '选择目录中…'

    local preset = (T().cwd or ''):gsub("'", "''")   -- PS single-quote escaping
    -- The picked path stays wrapped in sentinels. The worker now stages stdout
    -- through a file rather than relaying it down a pipe, so powershell.exe's
    -- CLIXML progress/error chatter no longer lands in the captured output — but
    -- parsing only the sentinel-delimited span costs nothing and keeps this
    -- robust against whatever else a PS host decides to print.
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
        -- run_ui, not run: this RPC is held open for as long as the human leaves
        -- the dialog up (5 min cap). On the shared pool that would occupy a
        -- worker every agent tab needs; the UI lane is reserved for exactly this.
        local r = subprocess.run_ui({ cmd = cmd, timeout_ms = 300000 })
        S.picking_dir = false
        local raw = tostring(r and r.stdout or '')
        local out = raw:match('<<PICK>>(.-)<<END>>')
        out = out and out:gsub('^%s+', ''):gsub('%s+$', '') or ''
        if out == '' then T().status = 'ready'; return end   -- dialog cancelled
        apply_cwd(out)
    end)
    local ok, err = coroutine.resume(co)
    if not ok then
        S.picking_dir = false
        T().status = '选择目录失败: ' .. tostring(err)
    end
end

-- Toggle the left sidebar (projects + sessions) open/closed.
local function toggle_sidebar()
    if S.sidebar then S.sidebar = nil; return end
    refresh_history(); S.history_scroll = 0
    S.sidebar = 'history'
end

-- Open a right-panel page from the ⋮ menu (picking the open one closes it).
local function toggle_panel(mode)
    if S.panel == mode then S.panel = nil; return end
    if mode == 'apilog' then S.apilog_scroll = 0; S.apilog_selected = nil end
    if mode == 'files' then S.files_scroll = 0 end
    S.panel = mode
end

-- ── API request/response log panel ─────────────────────────────────────────
-- Insert newlines at structural points of a compact JSON body so it wraps and
-- reads reasonably. String-aware: breaks are added ONLY outside quoted strings,
-- so the result is still valid JSON (copyable + parseable), never split mid-value.
local function reflow_json(s)
    s = tostring(s or '')
    local out, oi = {}, 0
    local instr, esc = false, false
    for i = 1, #s do
        local c = s:sub(i, i)
        oi = oi + 1; out[oi] = c
        if instr then
            if esc then esc = false
            elseif c == '\\' then esc = true
            elseif c == '"' then instr = false end
        elseif c == '"' then instr = true
        elseif c == ',' or c == '{' or c == '[' then
            oi = oi + 1; out[oi] = '\n'
        end
    end
    return table.concat(out)
end

local function shorttok(v)
    if not v then return '?' end
    if v >= 1000 then return string.format('%.1fk', v / 1000) end
    return tostring(v)
end

-- COMPLETE HTTP request as raw text (request line + headers + full body); this is
-- what the 请求 copy button puts on the clipboard. Auth header is already redacted
-- in api_log. NOT reflowed — the body is the exact bytes we sent.
local function http_request_text(rec)
    local lines = { (rec.method or 'POST') .. ' ' .. tostring(rec.url or '') }
    if type(rec.headers) == 'table' then
        local keys = {}
        for k in pairs(rec.headers) do keys[#keys + 1] = k end
        table.sort(keys)
        for _, k in ipairs(keys) do lines[#lines + 1] = k .. ': ' .. tostring(rec.headers[k]) end
    end
    lines[#lines + 1] = ''
    lines[#lines + 1] = rec.request or ''
    if rec.req_truncated then
        lines[#lines + 1] = string.format('\n…[请求体过大，已截断；原始 %d 字节]', rec.request_bytes or 0)
    end
    return table.concat(lines, '\n')
end

-- Build the read-only detail "transcript" for one API-log record. The two body
-- rows carry an explicit copy_text = the COMPLETE raw request / response, so the
-- 复制 button copies the full original (not the reflowed preview). Other rows opt
-- out of copy via no_copy.
local function build_log_detail(rec)
    local rows = {}
    local function L(role, t, extra)
        local row = { role = role, text = t or '' }
        if extra then for k, v in pairs(extra) do row[k] = v end end
        rows[#rows + 1] = row
    end
    if not rec then return rows end

    L('user', string.format('请求 #%d  ·  %s', rec.seq, os.date('%Y-%m-%d %H:%M:%S', rec.ts)), { no_copy = true })
    L('system', '')

    -- ── 请求 ── (body row copies the COMPLETE raw HTTP request)
    L('tool', '请求方法：' .. (rec.method or 'POST'), { no_copy = true })
    L('tool', '请求地址：' .. tostring(rec.url or ''), { no_copy = true })
    L('system', '模型：' .. tostring(rec.model or '?'))
    L('user', '【请求参数】（点“复制”得到完整 HTTP 请求）', { no_copy = true })
    L('tool_result', (rec.request ~= '' and reflow_json(rec.request)) or '（空）',
        { copy_text = http_request_text(rec) })
    if rec.req_truncated then
        L('system', string.format('… 请求体过大仅截断“显示”，复制仍为完整（原始 %d 字节）', rec.request_bytes or 0))
    end

    L('system', '')
    -- ── 返回 ── (body row copies the COMPLETE response incl. full content)
    if not rec.done then
        L('tool', '返回状态：进行中…', { no_copy = true })
    elseif rec.error then
        L('tool', '返回状态：HTTP ' .. tostring(rec.status or '-') .. '  失败', { no_copy = true })
        L('error', '错误：' .. tostring(rec.error))
    else
        L('tool', string.format('返回状态：HTTP %s  ·  stop=%s  ·  %dms',
            tostring(rec.status or '-'), tostring(rec.stop_reason or '?'),
            rec.elapsed_ms or 0), { no_copy = true })
        if rec.usage then
            local u = rec.usage
            L('tool', string.format('用量：%s  （未缓存 %d · 缓存命中 %d · 写入缓存 %d）',
                usage_label(u), u.input_tokens or 0, u.cache_read_input_tokens or 0,
                u.cache_creation_input_tokens or 0), { no_copy = true })
        end
    end
    -- The RAW response body, shown UNPARSED — the exact SSE stream the server
    -- sent. It already carries every block (text deltas AND tool_use blocks with
    -- their streamed input), so this single view IS "the complete return". Display
    -- == copy == the protocol bytes; no extraction, no preview.
    L('user', '【HTTP 返回 · 原始 SSE】（含 text 与 tool_use；显示=复制=原文）', { no_copy = true })
    local raw = rec.raw_response
    L('tool_result',
        (raw and raw ~= '' and raw)
        or (not rec.done and '（进行中…）')
        or '（无原始返回内容；旧记录或重启前发起的请求没有此字段）',
        { copy_text = (raw and raw ~= '' and raw) or '' })
    if rec.raw_truncated then L('system', '… 原始返回超过 4MB，显示与复制均已截断') end
    return rows
end

-- Select a log record to show in the main area; clicking the active one closes it.
local function select_log(rec)
    if S.apilog_selected == rec then rec = nil end
    S.apilog_selected = rec
    S.log_detail = build_log_detail(rec)
    S.log_detail_for = rec
    S.log_detail_done = rec and rec.done or nil
    if S.log_view then S.log_view.scroll = 0; S.log_view.follow = false end
end

-- Load a saved session into the ACTIVE tab (runs under that tab's model).
local function load_history_item(it)
    if not it then return end
    local tab = T()
    local s2 = session.load(it.path, { cfg = tab.cfg })
    if not s2 then tab.status = 'load failed'; return end
    cancel_session(tab)
    s2.tools = registry.to_api_params()
    s2.system = build_system(s2.cwd)
    s2.max_tokens = MAX_TOKENS
    s2.confirm = make_confirm(tab, s2)
    s2.request_user_input = user_input.bind(tab, s2)
    tab.sess = s2
    tab.cwd = s2.cwd or tab.cwd                   -- this tab follows the resumed session's dir
    tab.entries = rebuild_entries(s2.messages)
    tab.welcome = false
    tab.cur, tab.text_tail, tab.busy = nil, '', false
    tab.budget = nil                              -- meter restarts on the next turn
    tab.pending_confirm = nil
    S.dir_cache, S.menu, S.menu_dismissed_for = {}, nil, nil   -- @ picker follows the new cwd
    clear_attachments(tab)
    tab.status = 'resumed (' .. #s2.messages .. ' msgs)'
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
        for _, tab in ipairs(S.tabs) do
            if tab.sess and tab.sess.id == it.id then tab.sess.title = name end
        end
    end
    S.renaming = nil
    refresh_history()
end

local function do_delete(it)
    session.delete(it.path)
    S.confirm_delete = nil
    refresh_history()
end

-- Reset the ACTIVE tab to a fresh session (same model + cwd).
function new_session()
    local tab = T()
    if not tab.cfg then return end
    cancel_session(tab)
    local cwd = tab.cwd or (tab.sess and tab.sess.cwd) or '.'
    tab.sess = session.new({
        cfg = tab.cfg, cwd = cwd, tools = registry.to_api_params(),
        system = build_system(cwd),
        max_tokens = MAX_TOKENS,
    })
    tab.sess.confirm = make_confirm(tab, tab.sess)
    tab.sess.request_user_input = user_input.bind(tab, tab.sess)
    tab.entries = {}
    tab.welcome = true
    tab.cur, tab.text_tail, tab.busy = nil, '', false
    tab.budget = nil                             -- meter restarts on the next turn
    tab.pending_confirm = nil
    S.dir_cache, S.menu, S.menu_dismissed_for = {}, nil, nil   -- @ picker follows the new cwd
    clear_attachments(tab)
    add(tab, 'system', 'new session · ' .. tab.cfg.model .. ' · ' .. cwd .. '\nEnter 发送 · Ctrl+Enter 换行')
    tab.status = 'new session'
end

-- Create a new tab bound to `cfg` (a profile) and make it active. `cwd` defaults
-- to the current tab's working dir (so a new tab opens where you are). Each tab
-- gets its own session + transcript view; several can run concurrently.
function new_tab(cfg, cwd)
    cfg = cfg or (S.profiles and S.profiles[1])
    if not cfg then return end
    cwd = cwd or (T() and T().cwd) or '.'
    local tab = {
        id = S.next_tab_id,
        cfg = cfg,
        entries = {}, cur = nil, text_tail = '',
        input = '', input_edit = true, welcome = true,
        busy = false, status = 'ready', budget = nil,
        pending_confirm = nil, attachments = {},
        cwd = cwd,
        view = transcript.new_view({ font_size = FONT_SIZE, raygui = raygui, emoji_tex = S.emoji_tex }),
    }
    S.next_tab_id = S.next_tab_id + 1
    tab.view.bg = S.view_bg
    tab.view.on_copy = S.on_copy
    tab.view.on_link = S.on_link
    skills.bootstrap(cwd)   -- align the (global) project skills with this tab's dir
    tab.sess = session.new({
        cfg = cfg, cwd = cwd, tools = registry.to_api_params(),
        system = build_system(cwd),
        max_tokens = MAX_TOKENS,
    })
    tab.sess.confirm = make_confirm(tab, tab.sess)
    tab.sess.request_user_input = user_input.bind(tab, tab.sess)
    S.tabs[#S.tabs + 1] = tab
    S.active = #S.tabs
    S.menu, S.menu_sel, S.menu_off, S.menu_dismissed_for = nil, 1, 0, nil
    if not cfg.auth_type and (not cfg.api_key or cfg.api_key == '') then
        add(tab, 'error', '该模型（' .. (cfg.name or cfg.model or '?') ..
            '）未配置 token：在 xagent.local.cfg 设置 XAGENT_AUTH_TOKEN。')
    else
        add(tab, 'system', 'new tab · ' .. (cfg.name or cfg.model) .. ' · ' .. cfg.model ..
            ' · ' .. cwd .. '\nEnter 发送 · Ctrl+Enter 换行')
    end
    return tab
end

-- Close tab i (cancels its running turn). The last tab can't be closed.
function close_tab(i)
    if #S.tabs <= 1 then return end
    local tab = S.tabs[i]
    if not tab then return end
    cancel_session(tab)
    clear_attachments(tab)
    local was_active = S.active
    table.remove(S.tabs, i)                      -- the view is plain Lua; GC reclaims it
    if was_active > i then S.active = was_active - 1
    elseif was_active == i then S.active = math.min(i, #S.tabs) end
    if S.active < 1 then S.active = 1 end
    select_tab(S.active)
end

-- Switch the active tab; refresh per-tab context (autocomplete + project skills).
function select_tab(i)
    if i < 1 or i > #S.tabs then return end
    S.active = i
    S.menu, S.menu_sel, S.menu_off, S.menu_dismissed_for = nil, 1, 0, nil
    local tab = S.tabs[i]
    if tab and tab.cwd then skills.bootstrap(tab.cwd) end
end

-- Apply a raygui style and derive matching colors for the custom-drawn areas
-- (transcript bg/text, markdown palette, role colors) by reading the style's
-- BACKGROUND/TEXT/accent via get_style. One click re-themes the whole window.
local function apply_theme(name)
    if name == 'nord' then name = 'sand' end -- migrate the saved theme name
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

    S.view_bg = bg
    S.header_bg = base
    S.sidebar_bg = name == 'soft' and { 250, 248, 248, 255 } or shift(bg, dark and 8 or -8)
    for _, tab in ipairs(S.tabs) do
        if tab.view then tab.view.bg = bg; tab.view:invalidate() end
    end
    if S.log_view then S.log_view.bg = bg; S.log_view:invalidate() end

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

-- ── input autocomplete (/ commands · @ file refs) ───────────────────────────
-- Immediate children of <cwd>/<rel> (dirs marked with a trailing '/'), reduced
-- from xutils.scan_dir like the LS tool and cached per resolved directory: the
-- recursive walk runs once per directory the user drills into, not per keystroke
-- (files created mid-session won't show until the working dir changes).
local function list_dir_cached(rel)
    rel = tostring(rel or '')
    local base = (T() and T().cwd) or '.'
    local sub = rel:gsub('[/\\]+$', '')
    local abs = (sub == '') and base or (base:gsub('[/\\]+$', '') .. '/' .. sub)
    local hit = S.dir_cache[abs]
    if hit then return hit end
    local entries = xutils.scan_dir(abs)
    local seen, children = {}, {}
    if entries then
        for _, e in ipairs(entries) do
            local r = (e.rel or ''):gsub('\\', '/')
            local first = r:match('^([^/]+)')
            if first and first ~= '' then
                local label = r:find('/') and (first .. '/') or first
                if not seen[label] then seen[label] = true; children[#children + 1] = label end
            end
        end
    end
    table.sort(children)
    S.dir_cache[abs] = children
    return children
end

-- The slash-command catalog (built-ins handled by handle_slash + user skills).
local function slash_items()
    local items = {
        { name = 'compact', desc = '压缩上下文' },
        { name = 'context', desc = '查看上下文用量' },
        { name = 'mcp',     desc = '查看/管理 MCP 服务器（add/remove/reload）' },
        { name = 'new',     desc = '新会话' },
        { name = 'help',    desc = '帮助' },
    }
    for _, s in ipairs(skills.all_user_invocable()) do
        items[#items + 1] = { name = s.name, desc = s.description or '' }
    end
    return items
end

local completion_deps = { slash_items = slash_items, list_dir = list_dir_cached }

-- Recompute S.menu from the current input each frame. NOT gated on input focus:
-- clicking a popup row defocuses the textbox, and GuiButton fires on mouse
-- RELEASE, so the menu must survive the press→release of its own click. Token
-- presence is the gate instead (input is cleared on every session switch, so a
-- token only ever appears after the user has focused and typed).
local function update_completion_menu()
    S.menu = nil
    local tab = T()
    if tab.busy or S.dir_dialog or tab.pending_confirm or tab.pending_input or S.tab_picker or S.add_model then return end
    local menu = complete.compute(tab.input, completion_deps)
    if not menu then S.menu_dismissed_for = nil; return end
    if raygui.is_key_pressed and raygui.is_key_pressed(raygui.KEY_ESCAPE) then
        S.menu_dismissed_for = tab.input; return     -- Esc hides it until the text changes
    end
    if S.menu_dismissed_for == tab.input then return end
    local n = #menu.items
    if S.menu_sel < 1 or S.menu_sel > n then S.menu_sel = 1 end
    if raygui.is_key_pressed then
        if raygui.is_key_pressed(raygui.KEY_DOWN) then S.menu_sel = S.menu_sel % n + 1 end
        if raygui.is_key_pressed(raygui.KEY_UP)   then S.menu_sel = (S.menu_sel - 2) % n + 1 end
    end
    S.menu = menu
end

-- Insert the chosen candidate into the input and drop the caret after it.
local function accept_completion(item)
    if not S.menu or not item then return end
    local new_input, caret = complete.apply(S.menu, item)
    if not new_input then return end
    T().input = new_input
    if raygui.set_textbox_cursor then raygui.set_textbox_cursor(caret) end
    T().input_edit = true                          -- the popup click defocused the box
    S.menu, S.menu_sel, S.menu_off, S.menu_dismissed_for = nil, 1, 0, nil
end

-- Render the popup above the input box; handles hover (selects) and click (inserts).
local function draw_completion_menu(lx, iy, W)
    local menu = S.menu
    if not menu then return end
    local items = menu.items
    local n = #items
    local MAXVIS, row_h, head_h = 8, FONT_SIZE + 12, 24
    local vis = math.min(MAXVIS, n)

    local off = S.menu_off or 0                     -- keep the highlight on-screen
    if S.menu_sel <= off then off = S.menu_sel - 1 end
    if S.menu_sel > off + MAXVIS then off = S.menu_sel - MAXVIS end
    off = math.max(0, math.min(off, math.max(0, n - MAXVIS)))
    S.menu_off = off

    local px, pw = lx + 8, W - lx - 16
    local ph = head_h + vis * row_h + 6
    local py = iy - ph - 6

    local pb = S.sidebar_bg
    raygui.draw_rectangle(px, py, pw, ph, pb[1], pb[2], pb[3], 250)
    local ac = (markdown.palette and markdown.palette.heading) or { 110, 170, 120, 255 }
    raygui.draw_rectangle(px, py, 4, ph, ac[1], ac[2], ac[3], 255)

    local more = (n > vis or items.truncated)
        and ('   (' .. n .. (items.truncated and '+' or '') .. ')') or ''
    raygui.label(px + 12, py + 3, pw - 24, 20,
        ((menu.kind == 'slash') and '命令' or '文件/目录') ..
        '   ↑↓ 选择 · Enter 插入 · Esc 关闭' .. more)

    local mx, my = raygui.get_mouse()
    for i = 1, vis do
        local idx = off + i
        local it = items[idx]
        if it then
            local ry = py + head_h + (i - 1) * row_h
            if mx >= px and mx <= px + pw and my >= ry and my < ry + row_h then
                S.menu_sel = idx                    -- hover highlights (Enter takes it)
            end
            local label = ((idx == S.menu_sel) and '● ' or '   ') .. sanitize_label(it.label)
            if menu.kind == 'slash' and it.desc and it.desc ~= '' then
                label = label .. '    ' .. it.desc
            end
            if raygui.button(px + 6, ry, pw - 12, row_h - 4, label) then
                accept_completion(it)
            end
        end
    end
end

-- ── tab bar (one tab per conversation; each shows its model) ────────────────
-- A strip below the top bar: a button per tab (model name + busy dots / '!' when
-- a confirm is pending), a hover-close '×' (except on the last tab), and a '+'
-- to open a new tab. Returns having possibly switched/created/closed the active
-- tab, so the caller re-reads T() afterwards.
local function draw_tabbar(W)
    local y = HEADER_H
    local bg = S.view_bg or { 240, 240, 240, 255 }
    raygui.draw_rectangle(0, y, W, TABBAR_H, bg[1], bg[2], bg[3], 255)
    local tc = (markdown.palette and markdown.palette.text) or { 60, 60, 60, 255 }
    local line = mix(bg, tc, 0.12)                    -- hairline under the strip
    raygui.draw_rectangle(0, y + TABBAR_H - 1, W, 1, line[1], line[2], line[3], 255)

    local n = #S.tabs
    local plus_w = 30
    local avail = W - 6 - plus_w - 8 - (S.panel and 40 or 0)   -- room for the panel close icon
    local tw = math.max(70, math.min(180, math.floor(avail / math.max(1, n)) - 2))
    local ry, rh = y + 3, TABBAR_H - 5
    local x = 6
    local mx, my = raygui.get_mouse()
    local ac = (markdown.palette and markdown.palette.heading) or { 110, 170, 120, 255 }

    for i, tab in ipairs(S.tabs) do
        local active = (i == S.active)
        local label = (tab.cfg and tab.cfg.name) or '?'
        if tab.pending_confirm or tab.pending_input then
            label = label .. '  !'
        elseif tab.busy then
            label = label .. ' ' .. ('.'):rep(1 + math.floor(S.frame / 20) % 3)
        end
        local over = my >= ry and my < ry + rh and mx >= x and mx < x + tw
        local closable = (n > 1 and over)            -- show the close affordance on hover
        local tab_bg = active and mix(bg, ac, 0.10) or bg
        local clicked = surface.button(raygui, x, ry, tw, rh, '  ' .. fit_label(sanitize_label(label), tw - 38), tab_bg, tc, 8)
        if active then raygui.draw_rectangle(x + 6, ry + rh - 1, tw - 12, 2, ac[1], ac[2], ac[3], 255) end
        -- The close 'x' is a FRAMELESS icon drawn over the tab's right edge (a
        -- nested button would draw a second border inside the tab and look
        -- misaligned). The single tab button handles the click: over the icon →
        -- close, anywhere else → select.
        local over_close = false
        if closable then
            over_close = mx >= x + tw - 22 and mx < x + tw - 4
            -- brighten the × when the pointer is right over it
            local xcol = over_close and { 235, 120, 110, 255 }
                or (markdown.palette and markdown.palette.text) or { 200, 200, 200, 255 }
            draw_x(x + tw - 20, ry, 16, rh, xcol)
        end
        if clicked then
            if over_close then close_tab(i); return   -- S.tabs mutated; stop iterating this frame
            else select_tab(i) end
        end
        x = x + tw + 2
    end

    -- the right panel's close button sits in this row, above the panel itself
    -- (inside the panel it would collide with each page's own header buttons)
    if S.panel and flat_button(W - 38, ry, 32, rh, '#113#') then S.panel = nil end

    S.plus_x = x
    if flat_button(x, ry, plus_w, rh, '+') then
        if S.profiles and #S.profiles > 1 then
            S.tab_picker = not S.tab_picker
        else
            new_tab(S.profiles and S.profiles[1]); S.tab_picker = false
        end
    end
end

-- The "+" model-picker popup: one row per configured profile; pick → new tab.
-- Esc closes it; clicking "+" again toggles it.
local function draw_tab_picker(W, H)
    if not S.tab_picker or S.dir_dialog then return end
    if raygui.is_key_pressed and raygui.is_key_pressed(raygui.KEY_ESCAPE) then
        S.tab_picker = false; return
    end
    local profs = S.profiles or {}
    local row_h = FONT_SIZE + 14
    local pw = 340
    local px = math.max(6, math.min(S.plus_x or 6, W - pw - 8))
    local py = TOP + 2
    local ph = 26 + #profs * row_h
    local pb = S.sidebar_bg
    raygui.draw_rectangle(px, py, pw, ph, pb[1], pb[2], pb[3], 252)
    local ac = (markdown.palette and markdown.palette.heading) or { 110, 170, 120, 255 }
    raygui.draw_rectangle(px, py, 4, ph, ac[1], ac[2], ac[3], 255)
    raygui.label(px + 12, py + 3, pw - 24, 20, '新建标签 · 选择模型 · Esc 关闭')
    for i, p in ipairs(profs) do
        local ry = py + 24 + (i - 1) * row_h
        local host = ((p.base_url or ''):gsub('^https?://', '')):match('^([^/]+)') or ''
        local lbl = '  ' .. sanitize_label(p.name or p.model or '?')
        if host ~= '' then lbl = lbl .. '    · ' .. host end
        if raygui.button(px + 6, ry, pw - 12, row_h - 4, lbl) then
            new_tab(p); S.tab_picker = false
        end
    end
end

-- ── settings page: dropdowns + add-model form ──────────────────────────────
-- Open tabs follow edits: each tab is rebound (by the profile's stable key) to
-- the reloaded profile, so a changed model / proxy / token applies from its
-- next turn (a turn already running keeps the cfg it started with). A tab whose
-- profile was deleted keeps its old settings.
local function reload_profiles()
    S.profiles = config.load_profiles()
    if S.model_sel < 1 then S.model_sel = 1 end
    if S.model_sel > #S.profiles then S.model_sel = #S.profiles end
    local by_key = {}
    for _, p in ipairs(S.profiles) do if p.key then by_key[p.key] = p end end
    for _, tab in ipairs(S.tabs) do
        local p = tab.cfg and tab.cfg.key and by_key[tab.cfg.key]
        if p then
            tab.cfg = p
            if tab.sess then tab.sess.cfg = p end
        end
    end
end

-- Rebind the ACTIVE tab to another profile (the header's model switcher). The
-- conversation carries over — only the session's cfg changes, so the next turn
-- goes to the new model, the same way reload_profiles rebinds an edited profile.
-- Refused mid-turn: the running request was built for the old model.
local function switch_tab_model(p)
    local tab = T()
    if not p or not tab or tab.cfg == p then return end
    if tab.busy then tab.status = '运行中，停止后再切换模型'; return end
    tab.cfg = p
    if tab.sess then tab.sess.cfg = p end
    tab.budget = nil            -- the meter's window belongs to the old model; refills next turn
    if not p.auth_type and (not p.api_key or p.api_key == '') then
        tab.status = '该模型未配置 token'
    else
        tab.status = '已切换到 ' .. (p.name or p.model or '?')
    end
end

-- The ⋮ menu: right-panel pages, in the order they are listed.
local PANEL_MENU = {
    { mode = 'files',      label = '工作区文件' },
    { mode = 'model',      label = '模型设置' },
    { mode = 'mcp',        label = '工具与 MCP' },
    { mode = 'apilog',     label = 'API 请求记录' },
    { mode = 'appearance', label = '外观配色' },
}

-- A dropdown trigger: a button + a caret. Records its anchor while open so the
-- popup list (drawn on top of everything at frame end) knows where to appear.
local function dropdown_button(id, x, y, w, h, current)
    local open = (S.dd_open == id)
    local clicked = raygui.button(x, y, w, h, '  ' .. sanitize_label(current or '（无）'))
    local col = (markdown.palette and markdown.palette.text) or { 200, 200, 200, 255 }
    draw_caret(x + w - 14, y + h / 2, col, open)
    if clicked then S.dd_open = open and nil or id end
    if S.dd_open == id then S.dd_anchor = { x = x, y = y, w = w, h = h } end
end

-- Flat variant of dropdown_button (no frame until hovered), for toolbars.
local function flat_dropdown(id, x, y, w, h, current, bg)
    local open = (S.dd_open == id)
    local label = '  ' .. sanitize_label(current or '（无）')
    local clicked
    if bg then clicked = surface.button(raygui, x, y, w, h, label, bg, markdown.palette.text, 7)
    else clicked = flat_button(x, y, w, h, label) end
    local col = (markdown.palette and markdown.palette.text) or { 200, 200, 200, 255 }
    draw_caret(x + w - 12, y + h / 2, col, open)
    if clicked then S.dd_open = open and nil or id end
    if S.dd_open == id then S.dd_anchor = { x = x, y = y, w = w, h = h } end
end

-- Draw the open dropdown's list (theme or model) over the rest of the UI.
-- `was_open` is S.dd_open as of frame start (before any control could toggle it),
-- so the click that OPENS the dropdown this frame isn't read as an outside-click.
local function draw_dropdown_overlays(was_open)
    if not S.dd_open or not S.dd_anchor then S.dd_prev_down = false; return end
    raygui.unlock()                       -- background was locked while a dropdown is open
    -- the theme/model pickers live on their sidebar pages; the header's
    -- per-tab model switcher ('tabmodel') is always on screen
    if (S.dd_open == 'theme' and S.panel ~= 'appearance')
        or (S.dd_open == 'model' and S.panel ~= 'model') then
        S.dd_open = nil; return
    end
    if raygui.is_key_pressed and raygui.is_key_pressed(raygui.KEY_ESCAPE) then
        S.dd_open = nil; return
    end
    local items = {}
    if S.dd_open == 'theme' then
        for _, t in ipairs(THEMES) do items[#items + 1] = { label = t, cur = (t == S.theme) } end
    elseif S.dd_open == 'model' then
        for i, p in ipairs(S.profiles or {}) do
            items[#items + 1] = { label = p.name or p.model or '?', cur = (i == S.model_sel) }
        end
    elseif S.dd_open == 'menu' then
        for _, m in ipairs(PANEL_MENU) do
            items[#items + 1] = { label = m.label, mode = m.mode, cur = (S.panel == m.mode) }
        end
    elseif S.dd_open == 'tabmodel' then
        local cur = T().cfg
        for _, p in ipairs(S.profiles or {}) do
            items[#items + 1] = { label = p.name or p.model or '?', prof = p,
                cur = (p == cur) or (cur ~= nil and p.key ~= nil and p.key == cur.key) }
        end
    end
    if #items == 0 then S.dd_open = nil; return end
    local a = S.dd_anchor
    local row_h = FONT_SIZE + 10
    local px, pw, py = a.x, math.max(a.w, 240), a.y + a.h + 2
    local ph = 6 + #items * row_h
    local sw, sh = raygui.screen_size()
    if px + pw > sw - 4 then px = math.max(4, sw - 4 - pw) end   -- the ⋮ menu sits at the right edge
    if py + ph > sh - 4 then py = math.max(4, a.y - ph - 2) end  -- the composer's picker: open upward
    local pb = S.sidebar_bg
    raygui.draw_rectangle(px, py, pw, ph, pb[1], pb[2], pb[3], 252)
    local ac = (markdown.palette and markdown.palette.heading) or { 110, 170, 120, 255 }
    raygui.draw_rectangle(px, py, 3, ph, ac[1], ac[2], ac[3], 255)
    for i, it in ipairs(items) do
        local ry = py + 3 + (i - 1) * row_h
        if flat_button(px + 4, ry, pw - 8, row_h - 3,
                (it.cur and '● ' or '   ') .. sanitize_label(it.label), pb) then
            if S.dd_open == 'theme' then apply_theme(it.label)
            elseif S.dd_open == 'model' then S.model_sel = i
            elseif S.dd_open == 'menu' then toggle_panel(it.mode)
            elseif S.dd_open == 'tabmodel' then switch_tab_model(it.prof) end
            S.dd_open = nil
        end
    end

    -- Dismiss on a press that lands outside both the list and its trigger button.
    -- The background is locked, so this click is consumed purely to close (it does
    -- not also activate whatever sits underneath). Press-EDGE only (down this
    -- frame, up last), and gated on `was_open` so the opening click — which is a
    -- press over the trigger that this same frame set S.dd_open — never self-closes.
    local down = (raygui.mouse_down and raygui.mouse_down()) or false
    local press = down and not S.dd_prev_down
    S.dd_prev_down = down
    if was_open and press and S.dd_open then
        local mx, my = raygui.get_mouse()
        local in_list = mx >= px and mx <= px + pw and my >= py and my <= py + ph
        local in_trig = mx >= a.x and mx <= a.x + a.w and my >= a.y and my <= a.y + a.h
        if not in_list and not in_trig then S.dd_open = nil end
    end
end

local function open_add_model()
    S.dd_open = nil
    S.add_model = { name = '', url = 'https://', model = '', token = '', proxy = '', api_format = nil,
                    name_e = false, url_e = false, model_e = false, token_e = false, proxy_e = false,
                    err = nil }
end

-- Open the same form prefilled with profile `p`. Fields hold the profile's OWN
-- values (explicit name, own proxy — not the inherited default) so saving only
-- records what the user actually changed; Token starts empty (= keep).
local function open_edit_model(p)
    S.dd_open = nil
    local inferred = config.infer_api_format(p.base_url)
    local pinned = (p.api_format ~= inferred) and p.api_format or nil
    S.add_model = { edit = p, name = p.name_own or '', url = p.base_url or '', model = p.model or '',
                    token = '', proxy = p.proxy_own or '', api_format = pinned,
                    name_e = false, url_e = false, model_e = false, token_e = false, proxy_e = false,
                    err = nil }
    S.add_model.orig = { name = S.add_model.name, url = S.add_model.url, model = S.add_model.model,
                         proxy = S.add_model.proxy, api_format = pinned }
end

-- Persist the edit form: a user model is updated in place; a cfg-file profile
-- gets an override. Only fields that differ from what the form opened with are
-- written, so untouched cfg values keep following the cfg file.
local function save_edit_model(f, url, model, proxy, token)
    local o, p = f.orig, f.edit
    local name = (f.name or ''):gsub('^%s+', ''):gsub('%s+$', '')
    local e = {}
    if name ~= o.name then e.name = name end
    -- A name that was just the model id follows a model change.
    if model ~= o.model and name == o.model then e.name = model end
    if url ~= o.url then e.base_url = url end
    if model ~= o.model then e.model = model end
    if proxy ~= o.proxy then e.proxy = proxy end
    if token ~= '' then e.api_key = token end
    if f.api_format ~= o.api_format then e.api_format = f.api_format end
    if next(e) == nil then return end
    if p.source == 'json' then
        config.update_user_model(p.json_index, e)
    else
        config.set_cfg_override(p.key, e)
    end
end

-- A centered modal to add a model (persisted to ~/.xagent/models.json), or to
-- edit one when S.add_model.edit is set (see open_edit_model). Only
-- URL + 模型ID are required. The protocol follows the URL until the user picks
-- one; auth_style is derived from the protocol (x-api-key / Bearer). 代理 is
-- optional: empty inherits the shared XAGENT_PROXY, 'direct' opts out. Esc /
-- 取消 closes.
local chatgpt_login = require('xagent.auth.login')
local chatgpt_auth = require('xagent.auth.chatgpt')

local function draw_add_model_modal(W, H)
    local f = S.add_model
    if not f then return end
    if raygui.is_key_pressed and raygui.is_key_pressed(raygui.KEY_ESCAPE) then
        chatgpt_login.cancel(); S.add_model = nil; return
    end
    local mw, mh = 520, 480
    local mx, my = math.floor((W - mw) / 2), math.floor((H - mh) / 2)
    raygui.draw_rectangle(mx - 2, my - 2, mw + 4, mh + 4, 0, 0, 0, 170)   -- shadow/border
    local pb = S.sidebar_bg
    raygui.draw_rectangle(mx, my, mw, mh, pb[1], pb[2], pb[3], 255)
    local ac = (markdown.palette and markdown.palette.heading) or { 110, 170, 120, 255 }
    raygui.draw_rectangle(mx, my, mw, 3, ac[1], ac[2], ac[3], 255)
    raygui.label(mx + 16, my + 12, mw - 80, 24, f.edit
        and ('编辑模型 · ' .. sanitize_label(f.edit.name or f.edit.model or '?') .. '（Token 留空=不变）')
        or '新增模型（鉴权方式按协议自动选择）')

    if raygui.button(mx + mw - 48, my + 8, 32, 30, '#113#') then chatgpt_login.cancel(); S.add_model = nil; return end

    local pad, lblw = 16, 84
    local fx = mx + pad + lblw + 8
    local fw = mw - (pad + lblw + 8) - pad
    local rh, row = 30, my + 48
    local function fld(label, id)
        raygui.label(mx + pad, row + 4, lblw, 22, label)
        f[id], f[id .. '_e'] = raygui.textbox(fx, row, fw, rh - 4, f[id], f[id .. '_e'])
        row = row + rh + 6
    end
    fld('名称', 'name')
    fld('API地址', 'url')
    fld('模型ID', 'model')
    fld('Token', 'token')
    fld('代理', 'proxy')
    raygui.label(fx, row - 8, fw, 20, '空=默认  socks5://h:1080  http://u:p@h:8080')
    row = row + 16

    -- Protocol toggle. Until clicked it tracks the URL (…/chat/completions,
    -- api.openai.com → OpenAI); a click pins the choice.
    local fmt = f.api_format or config.infer_api_format(f.url)
    raygui.label(mx + pad, row + 4, lblw, 22, '协议')
    local fmt_label = ({openai='OpenAI (Chat Completions)', responses='OpenAI (Responses)', anthropic='Anthropic (Messages)'})[fmt] or fmt
    if raygui.button(fx, row, fw, rh - 4, fmt_label) then
        f.api_format = ({anthropic='openai', openai='responses', responses='anthropic'})[fmt] or 'anthropic'
    end
    row = row + rh + 6

    if raygui.button(fx, row, fw / 2 - 4, rh - 4, chatgpt_login.running() and '取消 ChatGPT 登录' or '登录 ChatGPT') then
        if chatgpt_login.running() then chatgpt_login.cancel(); f.err = nil
        else
            local ok, url = pcall(chatgpt_login.start, {
                proxy = config.resolve_proxy(f.proxy, xutils.get_config('XAGENT_PROXY')),
                on_done = function(success, err)
                    if success then
                        f.url = chatgpt_auth.endpoint; f.api_format = 'responses'; f.token = ''
                        f.err = 'ChatGPT 已登录，请填写模型 ID 并保存'
                    else f.err = err end
                end,
            })
            if ok then
                local opened = open_url.open(url)
                if not opened then chatgpt_login.cancel(); f.err = '无法打开浏览器' else f.err = '请在浏览器完成登录' end
            else f.err = tostring(url) end
        end
    end
    if raygui.button(fx + fw / 2 + 4, row, fw / 2 - 4, rh - 4, '退出 ChatGPT') then
        chatgpt_login.cancel()
        local ok, err = pcall(chatgpt_auth.logout)
        f.err = ok and 'ChatGPT 已退出' or tostring(err)
    end
    row = row + rh + 6

    if f.err then
        local ec = { 220, 90, 90, 255 }
        raygui.draw_rectangle(mx + pad, row, 6, 6, ec[1], ec[2], ec[3], 255)
        raygui.label(mx + pad + 12, row - 4, mw - 2 * pad - 12, 22, f.err)
    end

    if surface.icon_button(raygui, mx + mw - 48, row + 24, 32, 30, 'save', pb,
        (markdown.palette and markdown.palette.text) or {40,40,40,255}) then
        local url = (f.url or ''):gsub('^%s+', ''):gsub('%s+$', '')
        local model = (f.model or ''):gsub('^%s+', ''):gsub('%s+$', '')
        local proxy = (f.proxy or ''):gsub('^%s+', ''):gsub('%s+$', '')
        local _, perr = xproxy.parse(proxy)
        if url == '' or url == 'https://' or model == '' then
            f.err = '请至少填写 API地址 和 模型ID'
        elseif perr and proxy:lower() ~= 'direct' and proxy:lower() ~= 'none' then
            f.err = '代理格式错误: ' .. perr
        elseif f.edit then
            save_edit_model(f, url, model, proxy, (f.token or ''):gsub('^%s+', ''):gsub('%s+$', ''))
            local key = f.edit.key
            reload_profiles()
            for i, p in ipairs(S.profiles) do if p.key == key then S.model_sel = i end end
            S.add_model = nil
            if T() then T().status = '已更新模型（下一轮对话生效）' end
        else
            config.add_user_model({ name = (f.name or ''):gsub('^%s+', ''):gsub('%s+$', ''),
                base_url = url, model = model, api_format = f.api_format,
                api_key = (f.token or ''):gsub('^%s+', ''):gsub('%s+$', ''),
                proxy = proxy })
            reload_profiles()
            S.model_sel = #S.profiles      -- select the model just added
            S.add_model = nil
            if T() then T().status = '已添加模型' end
        end
    end
    if S.add_model then
        surface.tooltip(raygui, mx + mw - 48, row + 24, 32, 30, '保存', pb,
            (markdown.palette and markdown.palette.text) or {40,40,40,255})
    end
end

-- The bundled agent exposes MCP status; configuration still uses its JSON files.
local function draw_mcp_section(x0, pad, y, H)
    raygui.label(x0 + pad, y, SIDEBAR_W - 2 * pad, 22, 'MCP 服务器')
    y = y + 30
    local conns = mcp_registry.connections()
    if #conns == 0 then
        raygui.label(x0 + pad, y, SIDEBAR_W - 2 * pad, 22,
            S.mcp_status == 'connecting' and '（连接中…）' or '（未配置）')
    end
    for _, c in ipairs(conns) do
        if y + 26 > H - 70 then break end
        local entry = mcp_registry.get(c.name)
        raygui.label(x0 + pad, y, SIDEBAR_W - 2 * pad, 22,
            string.format('%s  [%s]  %d 工具', sanitize_label(c.name), c.status, entry and #entry.tools or 0))
        y = y + 26
        if c.error then
            raygui.label(x0 + pad, y, SIDEBAR_W - 2 * pad, 22, fit_label(sanitize_label(c.error), SIDEBAR_W - 2 * pad))
            y = y + 26
        end
    end
    raygui.label(x0 + pad, H - 62, SIDEBAR_W - 2 * pad, 22, '~/.xagent/mcp.json 或 .mcp.json')
    raygui.label(x0 + pad, H - 36, SIDEBAR_W - 2 * pad, 22, '修改配置后重启生效')
end

-- ── shared drawing bits for the rail / sidebars / composer ──────────────────
local function accent_col() return (markdown.palette and markdown.palette.heading) or { 110, 170, 120, 255 } end
local function text_col() return (markdown.palette and markdown.palette.text) or { 200, 200, 200, 255 } end
local function muted_col() return transcript.role_colors.system or { 140, 140, 140, 255 } end

local function draw_text_col(s, x, y, size, col)
    raygui.draw_text(s, x, y, size, col[1], col[2], col[3], col[4] or 255)
end

-- Wheel-scroll a sidebar list: adjusts S[key] when the pointer is over the
-- list (not while the folder dialog covers it) and clamps it to the content.
-- Returns whether the pointer is over the list, the wheel delta, and the mouse.
local function scroll_list(key, x0, top, view_h, content_h, step)
    local mx, my = raygui.get_mouse()
    local over = not S.dir_dialog and mx >= x0 and mx <= x0 + SIDEBAR_W
        and my >= top and my <= top + view_h
    local d = 0
    if over then
        d = raygui.get_wheel()
        if d ~= 0 then S[key] = S[key] - d * step end
    end
    local max_scroll = math.max(0, content_h - view_h)
    if S[key] > max_scroll then S[key] = max_scroll end
    if S[key] < 0 then S[key] = 0 end
    return over, d, mx, my
end

-- Append an @reference to the active tab's input and focus it. With rel == ''
-- this leaves a bare '@', which opens the file picker (complete.lua's trigger).
local function insert_file_ref(rel)
    local tab = T()
    local s = tab.input or ''
    if s ~= '' and not s:match('%s$') then s = s .. ' ' end
    tab.input = s .. '@' .. rel .. (rel ~= '' and ' ' or '')
    if raygui.set_textbox_cursor then raygui.set_textbox_cursor(#tab.input) end
    -- the click that got here may have defocused the box this frame; the
    -- forced flag re-focuses it after textbox_multi reports its edit state
    tab.input_edit, tab.input_edit_forced = true, true
end

-- Request cancellation of the active tab's turn (takes effect at the next turn
-- boundary). A parked ask-mode confirm is released as a deny so the loop can
-- reach that boundary instead of hanging on the prompt.
local function stop_turn(tab)
    tab.status = '停止中'
    cancel_session(tab)
end

-- ── frameless window chrome ─────────────────────────────────────────────────
-- The window has no OS title bar (init { undecorated = true }), like Claude's
-- desktop app: the header carries minimize / maximize / close right of ⋮, a
-- press on empty header space moves the window (double-click maximizes), and
-- a thin band along the border resizes it. With a raygui build that lacks the
-- window functions, S.frameless stays false and the OS frame is kept.
local WINBTN_W = 46                 -- width of each of the three window buttons
local EDGE = 5                      -- resize band along the window border
local MIN_W, MIN_H = 480, 360
local EDGE_CURSOR = { n = 6, s = 6, e = 5, w = 5, nw = 7, se = 7, ne = 8, sw = 8 }

local function toggle_maximize()
    if raygui.is_window_maximized() then raygui.restore_window() else raygui.maximize_window() end
end

local function set_cursor(n)
    if S.win_cursor ~= n then S.win_cursor = n; raygui.set_mouse_cursor(n) end
end

-- Which border band the pointer is on: '', or a combination of n/s + e/w.
local function edge_at(mx, my, W, H)
    local e = ''
    if my < EDGE then e = 'n' elseif my >= H - EDGE then e = 's' end
    if mx < EDGE then e = e .. 'w' elseif mx >= W - EDGE then e = e .. 'e' end
    return e
end

-- True if (mx, my) is on a header control (recorded by draw_header last frame);
-- everything else in the header is a drag handle.
local function over_header_control(mx, my)
    for _, r in ipairs(S.hdr_hits or {}) do
        if mx >= r[1] and mx < r[1] + r[3] and my >= r[2] and my < r[2] + r[4] then return true end
    end
    return false
end

-- Runs at the start of each frame, from the raw mouse state. Returns true while
-- a move/resize is in progress (the caller freezes the rest of the UI). Moves
-- follow the pointer in SCREEN coordinates (mouse_screen), not window-relative
-- ones, which lag a frame behind each move and make the window jitter.
local function window_chrome(W, H)
    local down = raygui.mouse_down()
    local maximized = raygui.is_window_maximized()
    if maximized then S.win_grab = nil end
    local press = down and not S.win_prev_down
    S.win_prev_down = down
    local g = S.win_grab
    if g then
        if not down then S.win_grab = nil; return false end
        local sx, sy = raygui.mouse_screen()
        local dx, dy = sx - g.sx, sy - g.sy
        if g.mode == 'move' then
            raygui.set_window_pos(g.wx + dx, g.wy + dy)
        else
            local x, y, w, h = g.wx, g.wy, g.ww, g.wh
            if g.mode:find('e') then w = math.max(MIN_W, g.ww + dx) end
            if g.mode:find('s') then h = math.max(MIN_H, g.wh + dy) end
            if g.mode:find('w') then w = math.max(MIN_W, g.ww - dx); x = g.wx + g.ww - w end
            if g.mode:find('n') then h = math.max(MIN_H, g.wh - dy); y = g.wy + g.wh - h end
            raygui.set_window_size(w, h)
            if x ~= g.wx or y ~= g.wy then raygui.set_window_pos(x, y) end
        end
        return true
    end

    local mx, my = raygui.get_mouse()
    local edge = maximized and '' or edge_at(mx, my, W, H)
    set_cursor(EDGE_CURSOR[edge] or 0)
    if not press then return false end

    local function grab(mode)
        local sx, sy = raygui.mouse_screen()
        local wx, wy = raygui.window_pos()
        S.win_grab = { mode = mode, sx = sx, sy = sy, wx = wx, wy = wy, ww = W, wh = H }
    end
    if edge ~= '' then
        grab(edge); return true
    end
    if my < HEADER_H and not over_header_control(mx, my) then
        if S.win_last_press and S.frame - S.win_last_press < 25 then   -- ~0.4 s at 60 fps
            S.win_last_press = nil
            toggle_maximize()
            return true
        end
        S.win_last_press = S.frame
        if not maximized then grab('move'); return true end   -- a maximized window stays put
    end
    return false
end

-- minimize / maximize-restore / close, hand-drawn icons over flat buttons
local function draw_window_controls(W)
    local txt = text_col()
    local x = W - 3 * WINBTN_W
    local cy = math.floor(HEADER_H / 2)
    if flat_button(x, 0, WINBTN_W, HEADER_H, '') then raygui.minimize_window() end
    raygui.draw_rectangle(x + 18, cy, 10, 1, txt[1], txt[2], txt[3], 255)

    x = x + WINBTN_W
    if flat_button(x, 0, WINBTN_W, HEADER_H, '') then toggle_maximize() end
    local function box(bx, by, n)
        raygui.draw_rectangle(bx, by, n, 1, txt[1], txt[2], txt[3], 255)
        raygui.draw_rectangle(bx, by + n - 1, n, 1, txt[1], txt[2], txt[3], 255)
        raygui.draw_rectangle(bx, by, 1, n, txt[1], txt[2], txt[3], 255)
        raygui.draw_rectangle(bx + n - 1, by, 1, n, txt[1], txt[2], txt[3], 255)
    end
    if raygui.is_window_maximized() then        -- restore: two overlapping squares
        box(x + 20, cy - 6, 8)
        local bg = S.view_bg or { 240, 240, 240, 255 }
        raygui.draw_rectangle(x + 18, cy - 4, 8, 8, bg[1], bg[2], bg[3], 255)
        box(x + 18, cy - 4, 8)
    else
        box(x + 18, cy - 5, 10)
    end

    x = x + WINBTN_W
    local mx, my = raygui.get_mouse()
    local over = mx >= x and my >= 0 and my < HEADER_H
    if flat_button(x, 0, WINBTN_W, HEADER_H, '', nil, { 196, 43, 28, 255 }) then S.quit = true end
    draw_x(x + 15, 0, 16, HEADER_H, over and { 255, 255, 255, 255 } or txt, 5)
end

-- ── top bar ─────────────────────────────────────────────────────────────────
-- [≡]  session title  (workspace)   status · usage ........ 12.3k tok ▬▬▬  [⋮]
-- Flat, on the content background like the conversation below it: ≡ toggles
-- the projects/sessions sidebar, the workspace chip picks another directory,
-- ⋮ lists the right-panel pages. (The model picker lives in the composer.)

-- What the header calls the active tab's conversation: its saved/renamed
-- title, else its first user message, else nil (a fresh session shows no
-- title — a "new session" placeholder said nothing the empty transcript doesn't).
local function tab_title(tab)
    local t = tab.sess and tab.sess.title
    if not t or t == '' then
        for _, e in ipairs(tab.entries) do
            if e.role == 'user' then t = e.text; break end
        end
    end
    return (t and t ~= '') and t or nil
end

local function dir_name(d)
    d = tostring(d or ''):gsub('[\\/]+$', '')
    return d:match('([^\\/]+)$') or d
end

local function draw_header(W, tab)
    local bg = S.view_bg or { 240, 240, 240, 255 }
    raygui.draw_rectangle(0, 0, W, HEADER_H, bg[1], bg[2], bg[3], 255)
    local txt, muted = text_col(), muted_col()

    -- header controls; the rest of the bar is the window's drag handle
    local hits = { { 6, 5, 34, 28 } }
    S.hdr_hits = hits

    -- ≡: three bars over a flat button (the font's ☰ isn't reliable at this size)
    if flat_button(6, 5, 34, 28, '') then toggle_sidebar() end
    local lc = S.sidebar and accent_col() or txt
    for k = 0, 2 do raygui.draw_rectangle(15, 12 + k * 6, 16, 2, lc[1], lc[2], lc[3], 255) end

    -- session title (none yet for a fresh session)
    local x = 50
    local t = tab_title(tab)
    if t then
        local title = fit_label(t, math.max(80, math.floor(W * 0.32)))
        draw_text_col(title, 52, 11, FONT_SIZE, txt)
        x = 52 + raygui.measure_text(title) + 12
    end

    -- workspace chip: a tinted pill that darkens on hover; click = pick a directory
    local chip_bg = shift(bg, (luma(bg) < 128) and 16 or -12)
    local chip = S.picking_dir and '选择中…' or fit_label(dir_name(tab.cwd), 160)
    local cw = raygui.measure_text(chip) + 22
    if surface.button(raygui, x, 8, cw, 22, chip, chip_bg, txt, 7) then pick_directory() end
    hits[#hits + 1] = { x, 8, cw, 22 }
    x = x + cw + 14

    -- right side: [meter] [⋮] [– □ ×]
    local wbw = S.frameless and (3 * WINBTN_W + 6) or 0
    local kx = W - 40 - wbw
    local right = kx - 8
    local b = tab.budget
    if b then
        -- token count + a thin bar filling toward the window. Green normally,
        -- amber on 'warning', red on 'error'/'blocking' (compaction imminent /
        -- just happened).
        local bw, bh = 72, 6
        local bx, by = right - bw, 16
        local kt = ktok(b.estimated) .. ' tok'
        local ktw = raygui.measure_text(kt, 13)
        draw_text_col(kt, bx - ktw - 8, 12, 13, muted)
        local pct = math.min(1, b.percent or 0)
        local fill = { 110, 170, 120, 255 }
        if b.state == 'warning' then fill = { 210, 175, 70, 255 }
        elseif b.state ~= 'normal' then fill = { 215, 95, 85, 255 } end
        local trk = mix(bg, muted, 0.35)
        raygui.draw_rectangle(bx, by, bw, bh, trk[1], trk[2], trk[3], 255)
        raygui.draw_rectangle(bx, by, math.floor(bw * pct), bh, fill[1], fill[2], fill[3], 255)
        right = bx - ktw - 20
    end

    -- status (+ this turn's usage once it finished), muted, between the two
    local status_text = tab.status
    if tab.busy then   -- thinking dots: . .. ... cycling (~3 steps/second)
        status_text = status_text .. ' ' .. ('.'):rep(1 + math.floor(S.frame / 20) % 3)
    elseif tab.last_usage then
        status_text = status_text .. '  ·  本轮 ' .. usage_label(tab.last_usage)
    end
    if right - x > 40 then
        draw_text_col(fit_label(status_text, right - x, 13), x, 12, 13, muted)
    end

    -- ⋮: the page menu (drawn by draw_dropdown_overlays like the other lists)
    local on = S.panel or S.dd_open == 'menu'
    if flat_button(kx, 5, 34, 28, '') then
        S.dd_open = (S.dd_open ~= 'menu') and 'menu' or nil
    end
    local dc = on and accent_col() or txt
    for k = 0, 2 do raygui.draw_rectangle(kx + 16, 12 + k * 6, 3, 3, dc[1], dc[2], dc[3], 255) end
    if S.dd_open == 'menu' then S.dd_anchor = { x = kx, y = 5, w = 34, h = 28 } end
    hits[#hits + 1] = { kx, 5, 34, 28 }

    if S.frameless then
        draw_window_controls(W)
        hits[#hits + 1] = { W - 3 * WINBTN_W, 0, 3 * WINBTN_W, HEADER_H }
    end
end

-- ── sidebar pages ───────────────────────────────────────────────────────────
-- Left sidebar — history: search + group folding, sessions grouped by working
-- directory, each row showing its title over a muted "time · message count"
-- line (near-identical titles are otherwise impossible to tell apart).
-- Preserve the session list's recency order. Folding changes visibility of
-- sessions, never which projects are present in the history overview.
local function build_history_groups(items, query, collapsed, open_by_key, key_for_dir)
    local groups, by_key, shown = {}, {}, 0
    local q = (query or ''):lower():gsub('^%s+', ''):gsub('%s+$', '')
    for _, item in ipairs(items) do
        local dir = item.cwd or '?'
        local key = key_for_dir(dir)
        local matches = q == '' or dir:lower():find(q, 1, true)
            or tostring(item.title or ''):lower():find(q, 1, true)
        if matches then
            local group = by_key[key]
            if not group then
                local expanded = open_by_key[key]
                if expanded == nil then expanded = not collapsed or q ~= '' end
                group = { key = key, dir = dir, items = {}, expanded = expanded }
                groups[#groups + 1], by_key[key] = group, group
            end
            group.items[#group.items + 1] = item
            shown = shown + 1
        end
    end
    return groups, shown
end


local function draw_history_sidebar(x0, H, tab)
    -- one header row: 历史会话 · [search…] · fold icon
    local lw = raygui.measure_text('历史会话') + 12
    draw_text_col('历史会话', x0 + 10, TOP + 9, FONT_SIZE, text_col())
    local fold_w = 28
    local fx = x0 + 10 + lw
    local fw = SIDEBAR_W - (fx - x0) - fold_w - 14
    S.history_query, S.history_query_edit = raygui.textbox(fx, TOP + 4, fw, 26,
        S.history_query, S.history_query_edit)
    if S.history_query == '' and not S.history_query_edit then
        draw_text_col('搜索…', fx + 8, TOP + 9, FONT_SIZE, muted_col())
    end

    -- Folding hides session rows while retaining every project header.
    local bx = x0 + SIDEBAR_W - 8 - fold_w
    if flat_button(bx, TOP + 4, fold_w, 26, '', S.sidebar_bg) then
        S.history_collapsed = not S.history_collapsed
        S.history_group_open = {}
        S.history_scroll = 0
        S.menu_item = nil
    end
    do
        local c = S.history_collapsed and accent_col() or text_col()
        local n, ix, iy = 11, bx + math.floor((fold_w - 11) / 2), TOP + 4 + math.floor((26 - 11) / 2)
        raygui.draw_rectangle(ix, iy, n, 1, c[1], c[2], c[3], 255)
        raygui.draw_rectangle(ix, iy + n - 1, n, 1, c[1], c[2], c[3], 255)
        raygui.draw_rectangle(ix, iy, 1, n, c[1], c[2], c[3], 255)
        raygui.draw_rectangle(ix + n - 1, iy, 1, n, c[1], c[2], c[3], 255)
        raygui.draw_rectangle(ix + 3, iy + 5, 5, 1, c[1], c[2], c[3], 255)             -- minus
        if S.history_collapsed then
            raygui.draw_rectangle(ix + 5, iy + 3, 1, 5, c[1], c[2], c[3], 255)         -- plus
        end
    end

    -- Search both project paths and conversation titles.
    local cur_key = dir_key(tab.cwd)
    local groups, shown = build_history_groups(S.history_items, S.history_query,
        S.history_collapsed, S.history_group_open, dir_key)
    -- flatten into rows with their y offsets (headers are shorter than items)
    local HEAD_H, ITEM_H = 30, FONT_SIZE + 32
    local rows, y = {}, 0
    for _, g in ipairs(groups) do
        rows[#rows + 1] = { header = g, y = y, h = HEAD_H }; y = y + HEAD_H
        if g.expanded then
            for _, it in ipairs(g.items) do rows[#rows + 1] = { item = it, y = y, h = ITEM_H }; y = y + ITEM_H end
        end
    end

    local list_top = TOP + 38
    local view_h = H - list_top - 8
    local over_list, wheel, mx, my = scroll_list('history_scroll', x0, list_top, view_h, y, ITEM_H)
    if wheel ~= 0 then S.menu_item = nil end

    if shown == 0 then
        raygui.label(x0 + 10, list_top + 6, SIDEBAR_W - 20, 22,
            (#S.history_items == 0) and '（暂无会话）' or '（没有匹配的会话）')
        return
    end

    local kw = 26                                  -- ⋮ / icon button width
    local rx, title_w = x0 + 8, SIDEBAR_W - 16     -- FULL width; ⋮ overlays on hover
    local kx = x0 + SIDEBAR_W - 8 - kw             -- right-edge button
    local kx2 = kx - kw - 4                        -- second-from-right button
    local txt, muted = text_col(), muted_col()

    raygui.begin_scissor(x0, list_top, SIDEBAR_W, view_h)
    for _, row in ipairs(rows) do
        local ry = list_top + row.y - S.history_scroll
        if ry + row.h > list_top and ry < list_top + view_h then   -- skip off-screen rows
            local rh = row.h - 5
            if row.header then
                local g = row.header
                local col = g.key == cur_key and accent_col() or txt
                local count = tostring(#g.items)
                local count_w = raygui.measure_text(count, 13)
                if flat_button(rx, ry, title_w, rh, '', S.sidebar_bg) then
                    S.history_group_open[g.key] = not g.expanded
                    S.menu_item = nil
                end
                if g.expanded then
                    draw_caret(rx + 10, ry + rh / 2, col, false)
                else
                    for k = 0, 3 do
                        raygui.draw_rectangle(rx + 8 + k, math.floor(ry + rh / 2) - 3 + k,
                            1, 7 - 2 * k, col[1], col[2], col[3], 255)
                    end
                end
                draw_text_col(fit_label(dir_tail(g.dir), title_w - count_w - 44), rx + 24, ry + 5, FONT_SIZE, col)
                draw_text_col(count, rx + title_w - count_w - 10, ry + 6, 13, muted)
            else
                local it = row.item
                if it.id == S.renaming then
                    S.rename_text, S.rename_edit = raygui.textbox(rx, ry, title_w - 2 * kw - 8, rh, S.rename_text, S.rename_edit)
                    if surface.icon_button(raygui, kx2, ry, kw, rh, 'confirm', S.sidebar_bg, txt) then do_rename(it) end
                    if surface.icon_button(raygui, kx, ry, kw, rh, 'cancel', S.sidebar_bg, txt) then S.renaming = nil end
                elseif it.id == S.confirm_delete then
                    raygui.label(rx + 4, ry + 4, title_w - 2 * kw - 30, rh - 8, '删除？')
                    if surface.icon_button(raygui, kx2, ry, kw, rh, 'confirm', S.sidebar_bg, txt) then do_delete(it) end
                    if surface.icon_button(raygui, kx, ry, kw, rh, 'cancel', S.sidebar_bg, txt) then S.confirm_delete = nil end
                elseif S.menu_item == it then
                    -- ⋮ clicked: reveal 修改 / 删除 on this row
                    local bw = (title_w - kw - 8) / 2
                    if surface.icon_button(raygui, rx, ry, bw, rh, 'edit', S.sidebar_bg, txt) then start_rename(it) end
                    if surface.icon_button(raygui, rx + bw + 4, ry, bw, rh, 'delete', S.sidebar_bg, txt) then
                        S.confirm_delete = it.id; S.renaming = nil; S.menu_item = nil
                    end
                    if kebab_button(kx, ry, kw, rh, txt) then S.menu_item = nil end   -- 再点收起
                else
                    -- empty button (hover bg + click) with the two text lines drawn
                    -- over it; the ⋮ OVERLAYS the right edge on hover, so a click
                    -- there must not also load the session.
                    local over_row = over_list and my >= ry and my < ry + rh
                    local over_kebab = over_row and mx >= kx and mx < kx + kw
                    local clicked = raygui.button(rx, ry, title_w, rh, '')
                    local tcol = (tab.sess and tab.sess.id == it.id) and accent_col() or txt
                    draw_text_col(fit_label(it.title, title_w - 24 - (over_row and kw or 0)),
                        rx + 10, ry + 5, FONT_SIZE, tcol)
                    local when = (tonumber(it.created_at) or 0) > 0
                        and os.date('%m-%d %H:%M', it.created_at) or '—'
                    draw_text_col(when .. '  ·  ' .. tostring(it.n or 0) .. ' 条',
                        rx + 10, ry + 9 + FONT_SIZE, 13, muted)
                    if over_row then
                        if kebab_button(kx, ry, kw, rh, txt) then S.menu_item = it end
                    end
                    if clicked and not over_kebab then load_history_item(it) end
                end
            end
        end
    end
    raygui.end_scissor()
end

-- Files: the active tab's working directory as an expandable tree. Children come
-- from list_dir_cached — the same per-directory cache the @ picker uses — and a
-- click on a file drops an @reference into the input (how the model is told to
-- read it). Expanded nodes are remembered per directory.
local function draw_files_sidebar(x0, H, tab)
    raygui.label(x0 + 10, TOP + 6, SIDEBAR_W - 90, 22, '工作区文件')
    if raygui.button(x0 + SIDEBAR_W - 40, TOP + 4, 32, 26, '#211#') then S.dir_cache = {} end
    draw_text_col(fit_label(tab.cwd or '.', SIDEBAR_W - 20, 13), x0 + 10, TOP + 36, 13, muted_col())
    draw_text_col('点击文件插入 @引用 · 点击目录展开', x0 + 10, TOP + 54, 13, muted_col())

    local key = dir_key(tab.cwd)
    local open = S.files_open[key]
    if not open then open = {}; S.files_open[key] = open end
    local rows = {}
    local function walk(rel, depth)
        -- directories first (the cached list is plain alphabetical, which is
        -- what the @ picker wants), each group keeping its alphabetical order
        local kids = {}
        for i, name in ipairs(list_dir_cached(rel)) do kids[i] = name end
        table.sort(kids, function(a, b)
            local da, db = a:sub(-1) == '/', b:sub(-1) == '/'
            if da ~= db then return da end
            return a:lower() < b:lower()
        end)
        for _, name in ipairs(kids) do
            local is_dir = name:sub(-1) == '/'
            local path = rel .. name
            rows[#rows + 1] = { path = path, name = is_dir and name:sub(1, -2) or name, dir = is_dir, depth = depth }
            if is_dir and open[path] and depth < 16 then walk(path, depth + 1) end
        end
    end
    walk('', 0)

    local list_top = TOP + 76
    local view_h = H - list_top - 8
    local row_h = FONT_SIZE + 10
    scroll_list('files_scroll', x0, list_top, view_h, #rows * row_h, row_h * 1.5)
    if #rows == 0 then
        raygui.label(x0 + 10, list_top + 6, SIDEBAR_W - 20, 22, '（空目录）')
        return
    end
    -- virtualize: only rows near the viewport; the scissor clips the edges
    local first = math.max(1, math.floor(S.files_scroll / row_h))
    local last = math.min(#rows, math.floor((S.files_scroll + view_h) / row_h) + 2)
    raygui.begin_scissor(x0, list_top, SIDEBAR_W, view_h)
    for i = first, last do
        local r = rows[i]
        local ry = list_top + (i - 1) * row_h - S.files_scroll
        local ind = math.min(r.depth * 14, SIDEBAR_W - 80)
        local w = SIDEBAR_W - 16 - ind
        local row_x, rh = x0 + 8 + ind, row_h - 3
        if raygui.button(row_x, ry, w, rh, '') then
            if r.dir then
                open[r.path] = (not open[r.path]) or nil
            else
                insert_file_ref(r.path)
                tab.status = '已引用 @' .. r.path
            end
        end
        if r.dir then
            local col = muted_col()
            if open[r.path] then
                draw_caret(row_x + 8, ry + rh / 2, col, false)
            else
                for k = 0, 3 do
                    raygui.draw_rectangle(row_x + 6 + k, math.floor(ry + rh / 2) - 3 + k,
                        1, 7 - 2 * k, col[1], col[2], col[3], 255)
                end
            end
            surface.icon(raygui, row_x + 18, ry + (rh - 20) / 2, 'folder')
        end
        draw_text_col(fit_label(r.name, w - 52), row_x + 44, ry + 4, FONT_SIZE, text_col())
    end
    raygui.end_scissor()
end

local function draw_apilog_sidebar(x0, H)
    raygui.label(x0 + 10, TOP + 6, SIDEBAR_W - 90, 22, 'API 请求记录')
    if surface.icon_button(raygui, x0 + SIDEBAR_W - 40, TOP + 4, 32, 26, 'delete', S.sidebar_bg, text_col()) then
        api_log.clear(); S.apilog_selected = nil
        S.log_detail = nil; S.log_detail_for = nil
    end
    raygui.label(x0 + 10, TOP + 34, SIDEBAR_W - 20, 20, '点击条目查看 请求/返回 详情（重启清空）')

    local recs = api_log.list()
    local n = #recs
    local list_top = TOP + 60
    local view_h = H - list_top - 8
    local row_h = FONT_SIZE + 18
    scroll_list('apilog_scroll', x0, list_top, view_h, n * row_h, row_h * 1.5)

    if n == 0 then
        raygui.label(x0 + 10, list_top + 6, SIDEBAR_W - 20, 22, '（暂无请求记录）')
        return
    end
    raygui.begin_scissor(x0, list_top, SIDEBAR_W, view_h)
    for i = 1, n do
        local rec = recs[n - i + 1]          -- newest first
        local ry = list_top + (i - 1) * row_h - S.apilog_scroll
        if ry + row_h > list_top and ry < list_top + view_h then
            local icon = (not rec.done) and '○' or (rec.error and '×' or '✓')
            local lbl
            if rec.done and not rec.error then
                local r = tokens.cache_hit_ratio(rec.usage)
                lbl = string.format('%s #%d %s  %s→%s%s', icon, rec.seq, os.date('%H:%M:%S', rec.ts),
                    rec.usage and shorttok(tokens.total_input_tokens(rec.usage)) or '?',
                    shorttok(rec.usage and rec.usage.output_tokens),
                    r and string.format('  缓存%d%%', math.floor(r * 100 + 0.5)) or '')
            elseif rec.error then
                lbl = string.format('%s #%d %s  失败', icon, rec.seq, os.date('%H:%M:%S', rec.ts))
            else
                lbl = string.format('%s #%d %s  …', icon, rec.seq, os.date('%H:%M:%S', rec.ts))
            end
            lbl = (rec == S.apilog_selected and '● ' or '   ') .. lbl
            if raygui.button(x0 + 8, ry, SIDEBAR_W - 16, row_h - 5, lbl) then select_log(rec) end
        end
    end
    raygui.end_scissor()
end

-- Model page: pick a profile to inspect / edit / delete, or add one. Which model
-- a TAB talks to is chosen from the header switcher (or the button at the end).
local function draw_model_sidebar(x0, H, tab)
    local pad = 12
    local my0 = TOP + 6
    raygui.label(x0 + pad, my0, SIDEBAR_W - 2 * pad, 22, '模型配置')
    local nprof = #(S.profiles or {})
    if S.model_sel < 1 then S.model_sel = 1 end
    if S.model_sel > nprof then S.model_sel = math.max(1, nprof) end
    local selp = (S.profiles or {})[S.model_sel]
    local addw = 56
    local ddw = SIDEBAR_W - 2 * pad - addw - 6
    dropdown_button('model', x0 + pad, my0 + 24, ddw, 30, selp and (selp.name or selp.model) or '（无）')
    if raygui.button(x0 + pad + ddw + 6, my0 + 24, addw, 30, '+') then open_add_model() end

    local dy = my0 + 64
    if selp then
        local function det(s) raygui.label(x0 + pad, dy, SIDEBAR_W - 2 * pad, 20, s); dy = dy + 22 end
        det('地址: ' .. sanitize_label(selp.base_url or '?'))
        det('模型: ' .. sanitize_label(selp.model or '?'))
        det('协议: ' .. tostring(selp.api_format or 'anthropic'))
        det('鉴权: ' .. tostring(selp.auth_style or 'x-api-key'))
        det('来源: ' .. (selp.source == 'json' and '自定义（可删除）' or '配置文件'))
        det('Token: ' .. ((selp.api_key and selp.api_key ~= '') and '已设置' or '未设置'))
        det('代理: ' .. (selp.proxy and sanitize_label(xproxy.redact(selp.proxy)) or '直连'))
        if selp.overridden then det('（已在界面修改，覆盖配置文件）') end
        dy = dy + 4
        if surface.icon_button(raygui, x0 + pad, dy, 32, 28, 'edit', S.sidebar_bg, text_col()) then open_edit_model(selp) end
        if selp.source == 'json' and selp.json_index then
            if surface.icon_button(raygui, x0 + pad + 40, dy, 32, 28, 'delete', S.sidebar_bg, text_col()) then
                config.delete_user_model(selp.json_index)
                reload_profiles()
            end
        elseif selp.overridden then
            if raygui.button(x0 + pad + 96, dy, 120, 28, '恢复配置文件') then
                config.clear_cfg_override(selp.key)
                reload_profiles()
            end
        end
        dy = dy + 40
        if tab.cfg ~= selp and raygui.button(x0 + pad, dy, SIDEBAR_W - 2 * pad, 28, '当前标签改用此模型') then
            switch_tab_model(selp)
        end
    end
end

local function draw_appearance_sidebar(x0)
    local pad = 12
    raygui.label(x0 + pad, TOP + 6, SIDEBAR_W - 2 * pad, 22, '配色方案')
    dropdown_button('theme', x0 + pad, TOP + 30, SIDEBAR_W - 2 * pad, 30, S.theme)
end

-- ── composer ────────────────────────────────────────────────────────────────
-- The input box plus a toolbar row under it, so everything that shapes the next
-- message sits next to it: [+ 引用文件] [permission mode] hints … [发送 / 停止].
local INPUT_H, TOOLBAR_H = 78, 40

local function composer_color()
    if S.theme == 'soft' then return { 255, 255, 255, 255 } end
    local bg = S.view_bg
    return mix(bg, text_col(), luma(bg) < 128 and 0.045 or 0.018)
end

local function draw_welcome(tab, x, y, w, h)
    local center = x + w / 2
    local top = y + math.max(12, math.floor(h * 0.32) - 32)
    local function centered(label, yy, size, col)
        draw_text_col(label, math.floor(center - raygui.measure_text(label, size) / 2), yy, size, col)
    end
    centered('从一个想法开始', top, 26, text_col())
    centered('读懂项目、修改代码，或一起解决一个问题。', top + 44, 16, muted_col())
    local choices = {
        { '理解项目', '请介绍当前项目的结构、主要模块和运行方式。' },
        { '实现功能', '我想在当前项目中实现一个功能：' },
        { '排查问题', '帮我排查当前项目中的问题：' },
    }
    local gap = 10
    local bw = math.min(144, math.floor((w - 2 * gap) / 3))
    local left = math.floor(center - (3 * bw + 2 * gap) / 2)
    if h > 190 and bw >= 80 then
        for i, item in ipairs(choices) do
            if surface.button(raygui, left + (i - 1) * (bw + gap), top + 92, bw, 38,
                item[1], mix(S.view_bg, accent_col(), 0.065), text_col(), 10) then
                tab.input, tab.input_edit, tab.input_edit_forced = item[2], true, true
            end
        end
    end
end

local function draw_composer_toolbar(tab, x, iy, w)
    local ty, bh = iy + INPUT_H + 4, 30
    local bg, txt, ac = composer_color(), text_col(), accent_col()
    if surface.button(raygui, x, ty, 30, bh, '+', bg, txt, 8) then insert_file_ref('') end

    local compact = w < 620
    local mode_w = compact and 62 or 132
    local mode_lbl = (S.mode == 'ask') and (compact and '询问' or '询问 · 写前确认')
        or (compact and '写入' or '写入 · 自动执行')
    if surface.button(raygui, x + 36, ty, mode_w, bh, mode_lbl, bg, txt, 7) then
        S.mode = (S.mode == 'ask') and 'write' or 'ask'
        tab.status = (S.mode == 'ask') and '询问模式：写操作前确认' or '写入模式：自动执行'
    end

    local send_w = 32
    local sx = x + w - send_w
    local mname = sanitize_label(tab.cfg and (tab.cfg.name or tab.cfg.model) or '?')
    local mw = math.min(200, math.max(60, w - mode_w - send_w - 60), raygui.measure_text(mname) + 40)
    local mx = sx - 10 - mw
    flat_dropdown('tabmodel', mx, ty, mw, bh, fit_label(mname, mw - 38), bg)

    local hx = x + 36 + mode_w + 12
    local room = mx - 12 - hx
    if room > 100 then
        draw_text_col(fit_label('Enter 发送 · Ctrl+Enter 换行 · Ctrl+V 贴图', room, 13),
            hx, ty + 8, 13, muted_col())
    end
    if tab.busy then
        if surface.button(raygui, sx, ty, send_w, bh, '', mix(bg, ac, 0.15), txt, 9) then stop_turn(tab) end
        raygui.draw_rectangle(sx + 11, ty + 10, 10, 10, txt[1], txt[2], txt[3], 255)
        return false
    end
    local ink = luma(ac) > 155 and { 30, 36, 48, 255 } or { 255, 255, 255, 255 }
    return surface.button(raygui, sx, ty, send_w, bh, '#121#', ac, ink, 9)
end

local function __init()
    S.profiles = config.load_profiles()
    assert(xnet.init())
    -- ui_lane reserves one worker outside the shared pool for the folder dialog,
    -- which holds its RPC open for as long as the human takes to answer.
    assert(subprocess.setup({ ui_lane = true }))

    -- Borderless (custom title bar in the header) when this raygui build can
    -- move/resize/minimize the window; otherwise keep the OS frame.
    S.frameless = (raygui.mouse_screen and raygui.set_window_pos and raygui.minimize_window) and true or false
    raygui.init(960, 700, 'xagent', {
        undecorated = S.frameless,
        desktop_maximize = IS_WIN and S.frameless,
    })
    -- A larger atlas avoids enlarging 16px bitmaps for headings while keeping
    -- the existing font metrics and all UI geometry in logical pixels.
    local charset = preseed_charset()
    local font_loaded = raygui.load_system_font(FONT_ATLAS_SIZE, charset)
    if not font_loaded then raygui.load_font('tools/fonts/NotoSansSC-Regular.otf', FONT_ATLAS_SIZE, charset) end

    -- Color emoji come from the atlas (the font has no emoji glyphs).
    S.emoji_tex = raygui.load_texture('tools/emoji_atlas.png')
    -- Copy puts the RAW source on the clipboard, never the rendered/reflowed text:
    -- entry.copy_text (explicit raw payload) wins, else entry.text (raw Markdown).
    -- Shared by every tab's view (set via S.on_copy in new_tab).
    local function copy_entry(entry)
        raygui.set_clipboard(entry.copy_text or entry.text or '')
        if T() then T().status = 'copied ✓' end
    end
    S.on_copy = copy_entry

    -- Click a URL in the transcript to open it in the default browser.
    -- Restrict to web/file schemes for safety.
    local function open_link(url)
        local scheme = tostring(url or ''):match('^(%a[%w%+%.%-]*)://')
        if scheme == 'http' or scheme == 'https' or scheme == 'file' then
            open_url.open(url)
            if T() then T().status = '已打开链接 ↗' end
        end
    end
    S.on_link = open_link

    -- A second view renders the selected API-log record's request/response detail.
    S.log_view = transcript.new_view({ font_size = FONT_SIZE, raygui = raygui,
        emoji_tex = S.emoji_tex, anchor_top = true })
    S.log_view.on_copy = copy_entry
    S.log_view.on_link = open_link

    -- Apply the saved (or default) color theme (sets S.view_bg for new tabs).
    local saved = fs.read_file(THEME_FILE)
    saved = saved and saved:gsub('%s+', '')
    apply_theme((saved and saved ~= '') and saved or 'soft')

    -- Default the first tab's dir to the last picked one (persisted across
    -- launches); fall back to the process cwd if none saved or it's gone.
    local cwd = get_cwd()
    local savedcwd = fs.read_file(CWD_FILE)
    savedcwd = savedcwd and savedcwd:gsub('^%s+', ''):gsub('%s+$', '')
    if savedcwd and savedcwd ~= '' and dir_exists(savedcwd) then cwd = savedcwd end

    -- First tab (base profile). new_tab handles skills.bootstrap + the no-token
    -- case (it adds an error entry but keeps the UI alive instead of returning).
    new_tab(S.profiles[1], cwd)
    local pmd = project_md.load(cwd)
    if pmd and T().cfg.api_key and T().cfg.api_key ~= '' then
        add(T(), 'system', '（已加载 project memory）')
    end
    S.started = true

    -- Bring up MCP servers in the background. The handshake awaits the network,
    -- so it runs as a coroutine that the event loop resumes between frames; tools
    -- register globally, so we refresh every live tab's tools param when done
    -- (new/resumed sessions pick them up automatically at creation).
    S.mcp_status = 'connecting'
    local boot_co = coroutine.create(function()
        -- Prove the process workers answer before any tool call rides on one.
        -- A dead worker would otherwise show up as the first Bash mysteriously
        -- timing out, minutes later. Coroutine-only, hence in here.
        local sok, serr = subprocess.selftest()
        if not sok then add(T(), 'error', '进程池自检失败: ' .. tostring(serr)) end

        -- bootstrap is best-effort (no throws): bad config / failed servers are
        -- collected into summary.errors, never raised. It awaits the network, so
        -- it isn't wrapped in pcall (yielding across pcall isn't safe on every
        -- Lua backend); a stray error surfaces via the resume check below or, on
        -- a later resume, xasync's resume-error log.
        local summary = mcp.bootstrap(cwd, { verify = S.profiles[1] and S.profiles[1].verify })
        S.mcp_status = 'ready'
        local params = registry.to_api_params()
        for _, tab in ipairs(S.tabs) do if tab.sess then tab.sess.tools = params end end
        for _, err in ipairs(summary.errors or {}) do add(T(), 'error', 'MCP: ' .. tostring(err)) end
    end)
    local ok, err = coroutine.resume(boot_co)
    if not ok then S.mcp_status = 'error'; add(T(), 'error', 'MCP 启动失败: ' .. tostring(err)) end
end

local function __update()
    chatgpt_login.tick()
    if raygui.should_close() or S.quit then xthread.stop(0); return end
    local tab = T()
    if not tab then return end

    local W, H = raygui.screen_size()
    raygui.begin()

    -- frameless window: move/resize from the raw mouse before anything draws;
    -- while it runs the UI is locked so the drag doesn't also press controls
    local grabbing = S.frameless and window_chrome(W, H)
    if grabbing then raygui.lock() end

    -- Capture the dropdown's open-state BEFORE any control this frame can toggle
    -- it: the click that OPENS a dropdown must not also be read as the outside-
    -- click that closes it (see draw_dropdown_overlays).
    local dd_open_at_start = S.dd_open

    -- directory dialog open: freeze the UI underneath (raygui controls via
    -- lock; custom-drawn transcript/list wheel via flags). Unlocked again just
    -- before the dialog itself is drawn at the end of the frame.
    local modal = S.dir_dialog or S.add_model or S.dd_open
    if modal then raygui.lock() end
    tab.view.lock_input = modal or nil

    -- top bar: model switcher · workspace · status/usage · context meter
    S.frame = S.frame + 1
    update_thinking(tab)   -- maintain the transient "thinking…" transcript line
    draw_header(W, tab)

    -- tab strip (below the top bar); may switch/create/close the active tab
    draw_tabbar(W)
    tab = T()

    -- left sidebar (≡: projects + sessions) and right panel (⋮ pages); the
    -- conversation takes the space between them: lx .. rx
    local lx, rx = 0, W
    local sb = S.sidebar_bg
    -- Keep the composer usable when panels would leave less than 360px.
    -- Retain the selected pages so resizing wider brings them back.
    local show_sidebar = S.sidebar and W >= SIDEBAR_W + 360
    local show_panel = S.panel and W >= (show_sidebar and 2 or 1) * SIDEBAR_W + 360
    if show_sidebar then
        lx = SIDEBAR_W
        raygui.draw_rectangle(0, TOP, SIDEBAR_W, H - TOP, sb[1], sb[2], sb[3], sb[4])
        draw_history_sidebar(0, H, tab)
    end
    if show_panel then
        local x0 = W - SIDEBAR_W
        rx = x0
        raygui.draw_rectangle(x0, TOP, SIDEBAR_W, H - TOP, sb[1], sb[2], sb[3], sb[4])
        if S.panel == 'files' then draw_files_sidebar(x0, H, tab)
        elseif S.panel == 'model' then draw_model_sidebar(x0, H, tab)
        elseif S.panel == 'mcp' then draw_mcp_section(x0, 12, TOP + 6, H)
        elseif S.panel == 'apilog' then draw_apilog_sidebar(x0, H)
        elseif S.panel == 'appearance' then draw_appearance_sidebar(x0) end
    end

    -- transcript (right of the sidebar); attachments shrink it a bit more
    local answering = tab.pending_input ~= nil
    local comp_h = INPUT_H + TOOLBAR_H + 36
    local att_h = (#tab.attachments > 0) and 58 or 0
    local question_h = answering and math.min(user_input.height(tab, rx - lx - 16,
        function(s) return raygui.measure_text(s, 16) end), H - TOP - comp_h - att_h - 24) or 0
    local content_pad = math.min(48, math.max(20, math.floor((rx - lx) * 0.04)))
    local tx, ty = lx + content_pad, TOP + 16
    local tw, th = rx - lx - 2 * content_pad, math.max(0, H - ty - comp_h - question_h - att_h - 12 - (answering and 10 or 0))
    if th > 24 and S.panel == 'apilog' and S.apilog_selected then
        local rec = S.apilog_selected
        -- rebuild the detail if the record finished since it was first shown
        if S.log_detail_for ~= rec or S.log_detail_done ~= rec.done then
            S.log_detail = build_log_detail(rec)
            S.log_detail_for = rec
            S.log_detail_done = rec.done
        end
        S.log_view:draw(S.log_detail, tx, ty, tw, th)
    elseif th > 24 then
        local fresh = tab.welcome and not tab.busy
        for _, entry in ipairs(tab.entries) do
            if entry.role ~= 'system' then fresh = false; break end
        end
        if fresh and th > 150 then draw_welcome(tab, tx, ty, tw, th)
        else tab.view:draw(tab.entries, tx, ty, tw, th) end
    end

    -- attachment strip: pasted images as thumbnails, each with a ✗ to remove
    if att_h > 0 then
        local ax, ay, thumb = lx + 32, H - comp_h - att_h - 2, 48
        local remove_i
        for i, a in ipairs(tab.attachments) do
            local tw2 = math.max(24, math.min(96, math.floor(thumb * a.w / a.h + 0.5)))
            if a.tex then raygui.draw_texture(a.tex, ax, ay + 4, tw2, thumb) end
            if raygui.button(ax + tw2 - 16, ay + 4, 16, 16, '#113#') then remove_i = i end
            ax = ax + tw2 + 10
        end
        raygui.label(ax + 4, ay + 16, 220, 22, #tab.attachments .. ' 张图片将随消息发送')
        if remove_i then
            local a = table.remove(tab.attachments, remove_i)
            if a and a.tex then pcall(raygui.unload_texture, a.tex) end
        end
    end

    -- input: Enter sends, Ctrl+Enter inserts a newline; the toolbar under it
    -- has the send/stop button. textbox_multi reads raw keys (not raygui-
    -- locked), so its edit mode is forced off while the directory dialog is open.
    local iy = H - comp_h + 12
    local composer_x, composer_w = lx + 32, rx - lx - 64
    local card_bg = composer_color()
    local edge = mix(S.view_bg, tab.input_edit and accent_col() or text_col(), tab.input_edit and 0.48 or 0.16)
    surface.rounded(raygui, composer_x - 12, iy - 12, composer_w + 24, INPUT_H + TOOLBAR_H + 24, 16, edge)
    surface.rounded(raygui, composer_x - 11, iy - 11, composer_w + 22, INPUT_H + TOOLBAR_H + 22, 15, card_bg)
    if answering then
        local colors = {
            bg = S.sidebar_bg, text = text_col(),
            accent = (markdown.palette and markdown.palette.heading) or { 110, 170, 120, 255 },
        }
        user_input.draw(tab, raygui, lx + 8, iy - question_h - att_h - 10, rx - lx - 16, question_h,
            colors, modal or grabbing, stop_turn)
    end
    local new_input, submitted, new_edit
    new_input, new_edit, submitted = surface.editor(raygui, card_bg,
        composer_x, iy, composer_w, INPUT_H, tab.input,
        (not modal and not answering) and tab.input_edit or false, true)
    -- The card owns keyboard input while waiting. Keep the original
    -- composer and its draft visible without letting a second editor consume keys.
    if not answering then tab.input = new_input end
    if tab.input == '' then   -- placeholder (the caret sits just left of it)
        draw_text_col(fit_label('问点什么，或描述一个任务…   / 命令 · @ 引用文件', composer_w - 20),
            composer_x + 8, iy + 10, FONT_SIZE, muted_col())
    end
    local send_clicked = draw_composer_toolbar(tab, composer_x, iy, composer_w)

    -- live / @ autocomplete menu, recomputed from the (possibly edited) input
    update_completion_menu()

    if not S.dir_dialog and not answering then
        -- the toolbar's '+' / a file-tree click may have just focused the box
        tab.input_edit = new_edit or tab.input_edit_forced
        tab.input_edit_forced = nil
        if send_clicked then
            submit()
        elseif submitted then
            if S.menu then
                -- Enter inserts the highlighted candidate — except when the user
                -- already typed a full slash command verbatim, then just run it.
                local it = S.menu.items[S.menu_sel]
                if S.menu.kind == 'slash' and it and ('/' .. it.name) == tab.input then
                    submit()
                else
                    accept_completion(it)
                end
            else
                submit()
            end
        end
    end

    -- popup is drawn above the input box (after focus handling, so a row click
    -- can re-focus the box); only shows while a / or @ token is present
    draw_completion_menu(lx + 12, iy - 12, rx - 12)
    -- the "+" new-tab model picker (anchored under the tab bar)
    draw_tab_picker(W, H)

    -- "ask" mode: a state-changing tool is parked awaiting the user's decision
    -- (for the ACTIVE tab; a background tab shows '!' on its tab button instead).
    -- A strip above the input shows the tool + args with 允许 / 拒绝.
    if tab.pending_confirm then
        local pc = tab.pending_confirm
        local bx, bw, bh = lx + 8, rx - lx - 16, 86
        local by = iy - bh - 6
        local pb = S.sidebar_bg
        raygui.draw_rectangle(bx, by, bw, bh, pb[1], pb[2], pb[3], 255)
        local ac = (markdown.palette and markdown.palette.heading) or { 210, 175, 70, 255 }
        raygui.draw_rectangle(bx, by, 4, bh, ac[1], ac[2], ac[3], 255)
        raygui.label(bx + 14, by + 8, bw - 28, 22, '询问模式 · 是否执行此工具调用？')
        raygui.label(bx + 14, by + 32, bw - 28, 22,
            (pc.req and pc.req.name or '?') .. '   ' .. compact(pc.req and pc.req.input or {}))
        -- clear BEFORE resolve: resolve resumes the agent, which may immediately
        -- park the NEXT tool's confirm into tab.pending_confirm.
        if raygui.button(bx + bw - 188, by + bh - 34, 86, 28, '允许') then
            tab.pending_confirm = nil; pc.resolve(true)
        end
        if raygui.button(bx + bw - 96, by + bh - 34, 86, 28, '拒绝') then
            tab.pending_confirm = nil; pc.resolve(false)
        end
    end

    -- Ctrl+V with an image on the clipboard (flag set inside textbox_multi):
    -- grab it as PNG, make a thumbnail texture, queue as an attachment.
    local png, pw, ph = raygui.take_pasted_image()
    if png and not answering then
        local tex = raygui.load_texture_mem(png)
        tab.attachments[#tab.attachments + 1] = { png = png, w = pw, h = ph, tex = tex }
        tab.status = '已附加图片 ' .. pw .. '×' .. ph
    end

    -- directory dialog: drawn LAST (on top of everything), after unlocking —
    -- the lock above only freezes the UI underneath it.
    if S.dir_dialog then
        raygui.unlock()
        local status, dir = raygui.file_dialog()
        if status == 'select' then
            S.dir_dialog = false
            if dir == '::' then          -- Select pressed on the drive-list view
                tab.status = 'ready'
            else
                apply_cwd(dir)           -- dir pick: current dialog directory; file ignored
            end
        elseif status ~= 'active' then
            S.dir_dialog = false
            tab.status = 'ready'
        end
    end

    -- add-model modal: drawn LAST, after unlocking (same pattern as the dialog).
    if S.add_model then
        raygui.unlock()
        draw_add_model_modal(W, H)
    end

    -- open dropdown list: topmost overlay; unlocks the background it was drawn over.
    draw_dropdown_overlays(dd_open_at_start)

    if grabbing then raygui.unlock() end
    raygui.finish()
end

local function __uninit()
    for _, tab in ipairs(S.tabs) do cancel_session(tab) end
    chatgpt_login.cancel()
    -- Join the process workers while this state is still alive (see xproc.shutdown).
    subprocess.shutdown()
    if S.started then raygui.close() end
    if xnet and xnet.uninit then xnet.uninit() end
end

return {
    __tick_ms = 16,
    __thread_handle = router.handle,
    __init = __init,
    __update = __update,
    __uninit = __uninit,
}
