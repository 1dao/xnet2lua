-- xagent/session/session.lua — a multi-turn conversation with persistence.
--
-- Holds the message history across user turns so the agent remembers earlier
-- exchanges (the headless `main.lua` is one-shot; this is what an interactive
-- driver — and later the GUI — sits on top of). Persists to JSON under
-- ~/.xagent/sessions/<id>.json and reloads for resume.

local loop = require('xagent.core.loop')
local fs = dofile('scripts/core/share/xfs.lua')
local xutils = require('xutils')

-- Compaction replaces the head of the history with a continuation-summary user
-- message; it must never become the session title.
local CONTINUE_PREFIX = 'This session is being continued'

local function first_user_text(messages)
    local saw_continuation = false
    for _, m in ipairs(messages or {}) do
        if m.role == 'user' then
            if type(m.content) == 'string' and m.content ~= '' then
                if m.content:sub(1, #CONTINUE_PREFIX) ~= CONTINUE_PREFIX then
                    return m.content
                end
                saw_continuation = true
            elseif type(m.content) == 'table' then
                -- image+text block message: title from the real text part (skip
                -- the resume hint that replaces stripped images on re-save)
                for _, b in ipairs(m.content) do
                    if b.type == 'text' and (b.text or '') ~= ''
                       and b.text:sub(1, #'[图片') ~= '[图片' then
                        return b.text
                    end
                end
                for _, b in ipairs(m.content) do
                    if b.type == 'image' or (b.type == 'text' and b.text:sub(1, #'[图片') == '[图片') then
                        return '[图片]'
                    end
                end
            end
        end
    end
    return saw_continuation and '（已压缩的会话）' or '(no prompt)'
end

math.randomseed(os.time())

local M = {}
local Session = {}
Session.__index = Session
M.Session = Session

local function gen_id()
    return string.format('%x%04x', os.time(), math.random(0, 0xffff))
end

function M.dir()
    return (fs.home():gsub('[/\\]+$', '')) .. '/.xagent/sessions'
end

-- opts: { cfg, cwd, tools, system, max_tokens, id? }
function M.new(opts)
    opts = opts or {}
    return setmetatable({
        id = opts.id or gen_id(),
        cfg = opts.cfg,
        cwd = opts.cwd or '.',
        tools = opts.tools,
        system = opts.system,
        max_tokens = opts.max_tokens,
        title = opts.title,        -- custom display name (nil → derived from 1st msg)
        messages = {},
        usage = { input_tokens = 0, output_tokens = 0 },
        created_at = os.time(),
    }, Session)
end

-- content: a plain string, or an array of content blocks (e.g. image + text).
function Session:add_user(content)
    self.messages[#self.messages + 1] = { role = 'user', content = content }
    return self
end

-- Capture a durable title from the first real user message BEFORE the history
-- can be reshaped: compaction replaces the head with a summary, after which a
-- display-time derivation has nothing real left to show.
function Session:ensure_title()
    if self.title and self.title ~= '' then return end
    local t = first_user_text(self.messages)
    if t and t ~= '(no prompt)' and t ~= '（已压缩的会话）' then self.title = t end
end

-- Run one assistant turn over the accumulated history. loop.run appends the
-- assistant message (and any tool_result turns) to self.messages in place, and
-- may compact the history when it nears the context window. The usage anchor is
-- threaded across turns so the token estimate stays cheap and accurate.
function Session:run(on_event)
    self:ensure_title()
    -- The skills listing is appended fresh each turn so conditional skills
    -- activated by the previous turn's file touches become visible.
    local system = self.system
    local rem = require('xagent.skills').reminder()
    if rem ~= '' then system = system .. '\n\n' .. rem end

    local res = loop.run({
        cfg = self.cfg,
        messages = self.messages,
        system = system,
        tools = self.tools,
        ctx = { cwd = self.cwd, session_id = self.id, confirm = self.confirm },
        max_tokens = self.max_tokens,
        on_event = on_event,
        last_usage = self.last_usage,
        usage_anchor_index = self.usage_anchor_index,
        should_stop = function() return self.cancelled end,
    })
    self.usage.input_tokens = self.usage.input_tokens + (res.usage.input_tokens or 0)
    self.usage.output_tokens = self.usage.output_tokens + (res.usage.output_tokens or 0)
    self.last_usage = res.last_usage
    self.usage_anchor_index = res.usage_anchor_index
    return res
end

-- Force a full context compaction now (the /compact command). Runs inside a
-- coroutine (it calls the model). Returns the compaction result table.
function Session:compact(focus, on_event)
    self:ensure_title()
    local compaction = require('xagent.context.compaction')
    local res = compaction.auto_compact_if_needed({
        messages = self.messages, cfg = self.cfg, system = self.system,
        usage = self.last_usage, usage_anchor_index = self.usage_anchor_index,
        focus = focus, force = true,
    })
    if res.did_compact or res.did_micro then
        compaction.replace_in_place(self.messages, res.messages)
        self.last_usage, self.usage_anchor_index = nil, nil   -- history reshaped
    end
    if on_event then
        on_event({ type = 'compact', did_compact = res.did_compact, did_micro = res.did_micro,
                   summary = res.summary, kept_tail = res.kept_tail, error = res.error })
    end
    return res
end

function Session:to_table()
    return {
        version = 1,
        id = self.id,
        cwd = self.cwd,
        model = self.cfg and self.cfg.model,
        created_at = self.created_at,
        title = self.title,
        usage = self.usage,
        messages = self.messages,
    }
end

-- Persist to <dir>/<id>.json (dir defaults to ~/.xagent/sessions). Returns path.
function Session:save(dir)
    dir = dir or M.dir()
    fs.mkdirp(dir)
    local path = dir .. '/' .. self.id .. '.json'
    local ok, err = fs.write_file(path, xutils.json_pack(self:to_table()))
    if not ok then return nil, err end
    return path
end

-- Resumed sessions don't re-send historical images (heavy base64 on every
-- request, for pictures the model already saw). Each image block is replaced
-- by this text hint so the conversation stays coherent for the model.
M.IMAGE_RESUME_HINT = '[图片已省略：原会话中用户在此粘贴过一张图片，恢复会话后不再随请求发送]'

local function strip_image_blocks(messages)
    for _, m in ipairs(messages or {}) do
        if type(m.content) == 'table' then
            for i, b in ipairs(m.content) do
                if b.type == 'image' then
                    m.content[i] = { type = 'text', text = M.IMAGE_RESUME_HINT }
                end
            end
        end
    end
end

-- Rehydrate a session from a saved file. cfg/tools/system are runtime-only and
-- must be supplied again (they're not persisted by reference).
function M.load(path, opts)
    opts = opts or {}
    local data = fs.read_file(path)
    if not data then return nil, 'cannot read ' .. tostring(path) end
    local t = xutils.json_unpack(data)
    if type(t) ~= 'table' then return nil, 'bad session file' end
    strip_image_blocks(t.messages)
    local s = M.new({
        cfg = opts.cfg, cwd = t.cwd, tools = opts.tools,
        system = opts.system, max_tokens = opts.max_tokens, id = t.id,
    })
    s.messages = t.messages or {}
    s.usage = t.usage or s.usage
    s.created_at = t.created_at or s.created_at
    s.title = t.title
    return s
end

-- List ALL saved sessions, most-recent first. Returns { {id, path, created_at,
-- title, n}, ... }. Ids start with a hex timestamp, so a descending id sort is
-- recency order. (Reads every file once — callers should list on open, not per
-- frame.) `title` prefers a stored custom name, else the first user message.
function M.list(dir)
    dir = dir or M.dir()
    local entries = xutils.scan_dir(dir)
    if not entries then return {} end

    local files = {}
    for _, e in ipairs(entries) do
        local id = (e.rel or ''):match('([^/\\]+)%.json$')
        if id then files[#files + 1] = { id = id, path = e.path } end
    end
    table.sort(files, function(a, b) return a.id > b.id end)

    local items = {}
    for _, f in ipairs(files) do
        local data = fs.read_file(f.path)
        local t = data and xutils.json_unpack(data)
        if type(t) == 'table' then
            local title = (type(t.title) == 'string' and t.title ~= '') and t.title
                or first_user_text(t.messages)
            items[#items + 1] = {
                id = t.id or f.id,
                path = f.path,
                created_at = t.created_at or 0,
                title = title,
                cwd = t.cwd,
                n = #(t.messages or {}),
            }
        end
    end
    return items
end

-- Rename a saved session (writes a custom `title` into its file).
function M.rename(path, new_title)
    local data = fs.read_file(path)
    local t = data and xutils.json_unpack(data)
    if type(t) ~= 'table' then return nil, 'bad session file' end
    t.title = tostring(new_title or '')
    return fs.write_file(path, xutils.json_pack(t))
end

-- Delete a saved session file.
function M.delete(path)
    return os.remove(path)
end

return M
