local async = dofile('scripts/core/share/xasync.lua')
local question_tool = require('xagent.tools.ask_user_question')
local transcript = require('xagent.ui.transcript')
local M = {}

function M.bind(tab, sess)
    return function(request)
        if tab.sess ~= sess or sess.cancelled then return { cancelled = true } end
        return async.await(function(resolve)
            local p = { request = request, resolve = resolve, index = 1, answers = {}, scroll = 0, edit = true }
            for _, q in ipairs(request.questions) do p.answers[q.id] = { selected = {}, text = '' } end
            tab.pending_input = p
            tab.status = '等待你的回答'
        end)
    end
end

function M.resolve(tab, reply)
    local p = tab.pending_input
    if not p then return end
    -- Resuming can immediately open another question on the same tab.
    tab.pending_input = nil
    tab.status = '思考中'
    p.resolve(reply)
end

function M.cancel(tab) M.resolve(tab, { cancelled = true }) end

local function mix(a, b, amount)
    local c = {}
    for i = 1, 3 do c[i] = math.floor(a[i] + (b[i] - a[i]) * amount) end
    return c
end

-- The bundled renderer exposes rectangles only. Strips provide rounded corners
-- without textures, font icons, or a native runtime rebuild.
local function rounded(rg, x, y, w, h, radius, color)
    x, y, w, h = math.floor(x), math.floor(y), math.floor(w), math.floor(h)
    local r = math.max(0, math.min(radius, math.floor(w / 2), math.floor(h / 2)))
    rg.draw_rectangle(x, y + r, w, h - 2 * r, color[1], color[2], color[3], 255)
    for row = 0, r - 1 do
        local inset = math.ceil(r - math.sqrt(r * r - (r - row - 0.5) ^ 2))
        rg.draw_rectangle(x + inset, y + row, w - 2 * inset, 1, color[1], color[2], color[3], 255)
        rg.draw_rectangle(x + inset, y + h - row - 1, w - 2 * inset, 1, color[1], color[2], color[3], 255)
    end
end

local function move(p, index)
    p.index, p.scroll, p.error, p.edit = index, 0, nil, true
end

local function advance(tab, p, q)
    local valid, err = question_tool.validate_answers({ questions = { q } }, p.answers)
    if not valid then p.error = err; return end
    if p.index < #p.request.questions then move(p, p.index + 1); return end
    local answers = question_tool.validate_answers(p.request, p.answers)
    if answers then M.resolve(tab, { answers = answers }); return end
    -- Header navigation may have left earlier questions unanswered.
    for i, question in ipairs(p.request.questions) do
        if not question_tool.validate_answers({ questions = { question } }, p.answers) then
            move(p, i); p.error = '请回答或跳过这一题'; return
        end
    end
end

function M.height(tab, width, measure)
    local q = tab.pending_input.request.questions[tab.pending_input.index]
    local function count(s) return #transcript.wrap(s, math.max(40, width - 84), measure) end
    local height = 148 + count('第 1 题（单选）：' .. q.question) * 24
    for _, option in ipairs(q.options) do
        local rows = count(option.label) + (option.description ~= '' and count(option.description) or 0)
        height = height + math.max(40, rows * 22 + 12) + 4
    end
    return math.max(220, math.min(360, height))
end

function M.draw(tab, rg, x, y, w, h, colors, locked, stop)
    local p = tab.pending_input
    if not p then return end
    local q = p.request.questions[p.index]
    local a = p.answers[q.id]
    local bg, fg = colors.bg, colors.text
    local border, muted = mix(bg, fg, 0.12), mix(bg, fg, 0.58)
    local blue = { 65, 128, 255 }
    local mx, my = rg.get_mouse()
    local down = rg.mouse_down()
    local pressed, released = down and not p.prev_down, p.prev_down and not down
    p.prev_down = down
    if locked then p.pointer = nil end
    local function hit(id, bx, by, bw, bh, enabled)
        local over = mx >= bx and mx < bx + bw and my >= by and my < by + bh
        if pressed and over and not locked and enabled ~= false then p.pointer = id end
        return released and over and p.pointer == id and not locked and enabled ~= false, over and not locked
    end
    local function text(s, tx, ty, color, size)
        color = color or fg
        rg.draw_text(s, math.floor(tx), math.floor(ty), size or 16, color[1], color[2], color[3], 255)
    end
    local function capsule(label, bx, by, bw, bh, enabled, filled)
        local clicked, over = hit(label, bx, by, bw, bh, enabled)
        local fill = filled and (enabled and fg or mix(bg, fg, 0.36)) or (over and mix(bg, fg, 0.06) or bg)
        rounded(rg, bx, by, bw, bh, 16, filled and fill or border)
        if not filled then rounded(rg, bx + 1, by + 1, bw - 2, bh - 2, 15, fill) end
        text(label, bx + (bw - rg.measure_text(label, 16)) / 2, by + (bh - 16) / 2,
            filled and bg or (enabled and fg or border))
        return clicked
    end

    rounded(rg, x, y, w, h, 22, border)
    rounded(rg, x + 1, y + 1, w - 2, h - 2, 21, bg)
    rounded(rg, x + 21, y + 21, 16, 16, 8, muted)
    rounded(rg, x + 22, y + 22, 14, 14, 7, bg)
    text('?', x + 26, y + 23, muted, 12)
    text('问题', x + 48, y + 22, muted)
    local previous = hit('previous', x + w - 162, y + 14, 28, 30, p.index > 1)
    local following = hit('following', x + w - 80, y + 14, 28, 30, p.index < #p.request.questions)
    local close = hit('close', x + w - 44, y + 14, 28, 30)
    text('‹', x + w - 154, y + 20, p.index > 1 and muted or border, 20)
    text(string.format('%d of %d', p.index, #p.request.questions), x + w - 126, y + 23, muted, 14)
    text('›', x + w - 72, y + 20, p.index < #p.request.questions and muted or border, 20)
    text('×', x + w - 36, y + 20, muted, 20)

    local body_y, body_h = y + 62, math.max(20, h - 140)
    local function wrap(s) return transcript.wrap(s, math.max(40, w - 84), function(t) return rg.measure_text(t, 16) end) end
    local title = string.format('第 %d 题（%s）：%s', p.index,
        #q.options == 0 and '输入' or (q.multi_select and '多选' or '单选'), q.question)
    local lines, options = wrap(title), {}
    local content_h = #lines * 24 + 14
    for i, o in ipairs(q.options) do
        local rows = wrap(o.label)
        local description = o.description ~= '' and wrap(o.description) or {}
        local height = math.max(40, (#rows + #description) * 22 + 12)
        options[#options + 1] = { index = i, label = o.label, rows = rows, description = description, top = content_h, height = height }
        content_h = content_h + height + 4
    end
    if not locked and mx >= x and mx < x + w and my >= body_y and my < body_y + body_h then
        p.scroll = p.scroll - rg.get_wheel() * 36
    end
    local max_scroll = math.max(0, content_h - body_h)
    p.scroll = math.max(0, math.min(p.scroll, max_scroll))
    rg.begin_scissor(x + 10, body_y, w - 20, body_h)
    local top = body_y - p.scroll
    for i, line in ipairs(lines) do
        text(line, x + 20, top + (i - 1) * 24)
        text(line, x + 21, top + (i - 1) * 24)
    end
    local chosen
    for _, option in ipairs(options) do
        local oy = top + option.top
        if oy + option.height > body_y and oy < body_y + body_h then
            local hy, hb = math.max(oy, body_y), math.min(oy + option.height, body_y + body_h)
            -- Native buttons can consume Enter before the textbox. Keep all
            -- card controls on mouse press/release; Enter belongs to the editor.
            local clicked, over = hit('option' .. option.index, x + 14, hy, w - 28, hb - hy)
            if clicked then
                a.skipped = nil
                if q.multi_select then
                    local found
                    for i, label in ipairs(a.selected) do
                        if label == option.label then table.remove(a.selected, i); found = true; break end
                    end
                    if not found then a.selected[#a.selected + 1] = option.label end
                else a.selected = { option.label }; a.text = ''; chosen = true end
            end
            local selected = false
            for _, label in ipairs(a.selected) do if label == option.label then selected = true end end
            if over or selected then
                local shade = mix(bg, fg, selected and 0.08 or 0.04)
                rg.draw_rectangle(x + 14, math.floor(hy), w - 28, math.floor(hb - hy), shade[1], shade[2], shade[3], 255)
            end
            rounded(rg, x + 21, oy + 8, 24, 24, 6, border)
            rounded(rg, x + 22, oy + 9, 22, 22, 5, selected and blue or mix(bg, fg, 0.04))
            text(selected and '✓' or tostring(option.index), x + 28, oy + 12, selected and bg or muted, 14)
            for i, row in ipairs(option.rows) do text(row, x + 57, oy + 11 + (i - 1) * 22) end
            for i, row in ipairs(option.description) do text(row, x + 57, oy + 11 + (#option.rows + i - 1) * 22, muted) end
        end
    end
    rg.end_scissor()
    if max_scroll > 0 then
        local thumb = math.max(12, body_h * body_h / content_h)
        rg.draw_rectangle(x + w - 9, math.floor(body_y + (body_h - thumb) * p.scroll / max_scroll), 2, math.floor(thumb), muted[1], muted[2], muted[3], 255)
    end

    local fy = y + h - 62
    rounded(rg, x + 10, fy, w - 20, 50, 18, p.edit and blue or border)
    rounded(rg, x + 11, fy + 1, w - 22, 48, 17, bg)
    -- Pencil drawn with pixels so it does not depend on optional font glyphs.
    for i = 0, 9 do rg.draw_rectangle(x + 25 + i, fy + 30 - i, 2, 2, muted[1], muted[2], muted[3], 255) end
    local submitted, saved = nil, {}
    if rg.get_style then
        for _, prop in ipairs({ rg.BORDER_WIDTH, rg.BASE_COLOR_NORMAL, rg.BASE_COLOR_FOCUSED, rg.BASE_COLOR_PRESSED,
            rg.BORDER_COLOR_NORMAL, rg.BORDER_COLOR_FOCUSED, rg.BORDER_COLOR_PRESSED }) do
            saved[prop] = rg.get_style(rg.TEXTBOX, prop)
            rg.set_style(rg.TEXTBOX, prop, prop == rg.BORDER_WIDTH and 0 or ((bg[1] << 24) | (bg[2] << 16) | (bg[3] << 8) | 255))
        end
    end
    a.text, p.edit, submitted = rg.textbox_multi(x + 40, fy + 8, w - 224, 34, a.text, not locked and p.edit or false, true)
    for prop, value in pairs(saved) do rg.set_style(rg.TEXTBOX, prop, value) end
    if a.text == '' then text('或自行撰写回复', x + 46, fy + 17, mix(bg, fg, 0.30)) end
    local valid = question_tool.validate_answers({ questions = { q } }, p.answers) ~= nil
    local skip = capsule('跳过', x + w - 164, fy + 9, 54, 32, true)
    local next_clicked = capsule('下一步', x + w - 100, fy + 9, 78, 32, valid, true)
    if p.error then text(p.error, x + 20, fy - 20, muted, 14) end
    if released then p.pointer = nil end
    if locked then return end
    if close then stop(tab); return end
    if previous then move(p, p.index - 1); return end
    if following then move(p, p.index + 1); return end
    if skip then p.answers[q.id] = { selected = {}, text = '', skipped = true }; advance(tab, p, q); return end
    if chosen or submitted or next_clicked then
        if submitted or a.text:find('%S') then a.skipped = nil end
        if (submitted or (next_clicked and a.text:find('%S'))) and not q.multi_select and not chosen then a.selected = {} end
        advance(tab, p, q)
    end
end

return M
