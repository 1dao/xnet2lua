-- RayGUI usage demo.
-- Preferred in this repo:
--   bin/xnet demo/xraygui_main.lua
-- Auto-exit after N frames, useful for smoke checks:
--   bin/xnet demo/xraygui_main.lua frames=120
-- It can also run with a standalone Lua runtime that matches raygui.dll:
--   lua demo/xraygui_main.lua
--
-- 资源（dll / styles / fonts / emoji_atlas.png）均放在 ../tools 下。

local function script_dir()
    local source = debug.getinfo(1, "S").source
    if source:sub(1, 1) == "@" then
        source = source:sub(2)
    end
    source = source:gsub("\\", "/")
    return source:match("^(.*)/") or "."
end

local function parent_dir(path)
    return (path:gsub("/+$", ""):match("^(.*)/[^/]+$")) or "."
end

local function parse_frame_limit()
    if not arg then
        return nil
    end

    for _, item in ipairs(arg) do
        local value = item:match("^frames=(%d+)$") or item:match("^%-%-frames=(%d+)$")
        if value then
            return math.max(1, tonumber(value))
        end
    end

    return nil
end

local demo_dir = script_dir()
local root_dir = parent_dir(demo_dir)
local tool_dir = root_dir .. "/tools"

package.path = tool_dir .. "/?.lua;" .. package.path
package.cpath = tool_dir .. "/?.dll;" .. tool_dir .. "/?.so;" .. package.cpath

---@type raygui
local raygui = require("raygui")

local frame_limit = parse_frame_limit()
local frame = 0
local button_hits = 0
local checkbox_checked = false
local slider_value = 50.0
local progress_value = 0.0
local text_input = "Hello RayGUI"
local text_input_edit = false
local text_multi = "Line one\nLine two\nLine three"
local text_multi_edit = false
local dropdown_selected = 1
local dropdown_open = false
local list_selected = 1
local list_scroll = 0
local font_loaded = false
local window_initialized = false
local stop_requested = false

-- ===== 新特性所需的状态 / 资源（贴图在 __init 里加载，需 GL 上下文）=====
local emoji_tex = nil          -- 彩色 emoji 图集 emoji_atlas.png
local confirm_open   = false   -- 确认对话框是否弹出
local confirm_result = ""      -- 上次对话框的选择结果

-- emoji 图集元数据：cell/cols 为图集网格，index 是 名字->序号（与 emoji_atlas.png 对应）。
-- 改图集时用 gen_emoji_atlas.py 重新生成 PNG，脚本会把这张表打印出来，覆盖粘贴即可。
local EMOJI = { cell = 72, cols = 12, count = 132, index = {
    save=0, open=1, folder=2, file=3, new=4, edit=5, delete=6, add=7,
    remove=8, copy=9, cut=10, search=11, settings=12, tools=13, refresh=14, sync=15,
    undo=16, redo=17, check=18, close=19, ok=20, cancel=21, warning=22, info=23,
    question=24, exclamation=25, home=26, star=27, heart=28, bookmark=29, pin=30, tag=31,
    flag=32, bell=33, bell_off=34, lock=35, unlock=36, key=37, eye=38, up=39,
    down=40, left=41, right=42, back=43, toparr=44, play=45, pause=46, stop=47,
    record=48, next=49, prev=50, forward=51, rewind=52, sound=53, mute=54, mic=55,
    music=56, mail=57, chat=58, phone=59, mobile=60, upload=61, download=62, link=63,
    attach=64, chart=65, trending=66, calendar=67, clock=68, hourglass=69, print=70, computer=71,
    keyboard=72, battery=73, camera=74, video=75, image=76, money=77, card=78, cart=79,
    gift=80, trophy=81, crown=82, gem=83, fire=84, sparkles=85, sun=86, moon=87,
    cloud=88, rain=89, snow=90, rainbow=91, zap=92, droplet=93, rocket=94, bulb=95,
    book=96, memo=97, globe=98, package=99, party=100, balloon=101, cake=102, coffee=103,
    thumbs_up=104, thumbs_down=105, ok_hand=106, clap=107, wave=108, point_right=109, pray=110, muscle=111,
    smile=112, grin=113, joy=114, wink=115, cool=116, think=117, cry=118, angry=119,
    love=120, robot=121, user=122, users=123, shield=124, target=125, location=126, map=127,
    game=128, hundred=129, hammer=130, puzzle=131,
} }

-- 把 emoji（名字或数字序号）解析成图集源矩形 (sx, sy, sw, sh)
local function emoji_src(key)
    local idx = type(key) == "string" and EMOJI.index[key] or key
    local c, cell = EMOJI.cols, EMOJI.cell
    return (idx % c) * cell, (idx // c) * cell, cell, cell
end

-- 在 (x,y) 处画一个 size×size 的彩色 emoji（key 可用名字 "save" 或数字序号）
local function draw_emoji(key, x, y, size)
    if not emoji_tex or not EMOJI then return end
    local idx = type(key) == "string" and EMOJI.index[key] or key
    if not idx then return end
    local sx, sy, sw, sh = emoji_src(idx)
    raygui.draw_texture_ex(emoji_tex, sx, sy, sw, sh, x, y, size, size)
end

-- 组合按钮：彩色 emoji 贴图(左) + 文字(右)。
-- raygui 按钮只能画自己的文字，所以先画一个【文字左对齐、左内边距留空】的普通按钮，
-- 再把 emoji 贴图叠加在按钮左侧；点击逻辑仍用按钮自身返回值。
local function emoji_button(x, y, w, h, key, text)
    local esize = h - 12
    raygui.set_style(raygui.DEFAULT, raygui.TEXT_ALIGNMENT, raygui.TEXT_ALIGN_LEFT)
    raygui.set_style(raygui.DEFAULT, raygui.TEXT_PADDING, esize + 10)
    local clicked = raygui.button(x, y, w, h, text)
    -- 恢复本 demo 默认样式（左对齐、padding=4）
    raygui.set_style(raygui.DEFAULT, raygui.TEXT_PADDING, 4)
    raygui.set_style(raygui.DEFAULT, raygui.TEXT_ALIGNMENT, raygui.TEXT_ALIGN_LEFT)
    draw_emoji(key, x + 6, y + (h - esize) / 2, esize)
    return clicked
end

local function draw_demo_frame()
    frame = frame + 1
    progress_value = (progress_value + 0.5) % 100

    raygui.begin()

    -- 下拉框展开 / 对话框弹出时锁定其它控件：避免点击穿透到被覆盖的控件。
    -- 真正的"置顶"靠在帧末尾最后再画 dropdown / messagebox 实现。
    if dropdown_open or confirm_open then raygui.lock() end

    raygui.panel(0, 0, 800, 730, "RayGUI Lua demo")
    raygui.label(24, 42, 360, 28, "Run: bin/xnet demo/xraygui_main.lua")

    if frame_limit then
        raygui.label(680, 42, 200, 28, ("Frame %d / %d"):format(frame, frame_limit))
    else
        raygui.label(680, 42, 200, 28, ("Frame %d"):format(frame))
    end

    -- ===================== 第一行：基础控件 / 文本控件 =====================
    raygui.group(24, 86, 360, 220, "Basic controls")

    if raygui.button(44, 124, 120, 36, "Button") then
        button_hits = button_hits + 1
    end
    raygui.label(184, 128, 160, 28, "Clicks: " .. tostring(button_hits))

    checkbox_checked = raygui.checkbox(44, 179, 22, 22, "", checkbox_checked)
    raygui.label(78, 176, 120, 28, "Checkbox")
    raygui.label(224, 176, 120, 28, checkbox_checked and "ON" or "OFF")

    raygui.label(44, 226, 86, 28, "Slider")
    slider_value = raygui.slider(132, 226, 180, 28, 0, 100, slider_value)
    raygui.label(320, 226, 48, 28, string.format("%.0f", slider_value))

    raygui.label(44, 268, 86, 24, "Progress")
    raygui.progressbar(132, 270, 180, 20, progress_value, 0, 100)

    raygui.group(408, 86, 360, 220, "Text controls")

    raygui.label(428, 124, 84, 28, "Textbox")
    text_input, text_input_edit = raygui.textbox(520, 120, 222, 36, text_input, text_input_edit)

    -- 多行框：长按退格连删、内容多了不再溢出（已在 raygui.dll 内修复）
    raygui.label(428, 176, 84, 28, "Multi")
    text_multi, text_multi_edit = raygui.textbox_multi(520, 172, 222, 110, text_multi, text_multi_edit)

    -- ===================== 第二行：选择控件 / 状态 =====================
    raygui.group(24, 330, 360, 220, "Selection controls")

    raygui.label(44, 370, 86, 28, "List")
    list_selected, list_scroll = raygui.listview(
        44, 400, 150, 126,
        "alpha;bravo;charlie;delta;echo;foxtrot;golf",
        list_selected,
        list_scroll
    )
    raygui.label(44, 528, 150, 20, "List index: " .. tostring(list_selected))
    raygui.label(214, 370, 120, 28, "Dropdown")
    raygui.label(214, 448, 140, 28, "Selected: " .. tostring(dropdown_selected))

    raygui.group(408, 330, 360, 220, "Status")
    raygui.label(428, 370, 320, 28, "Mouse over UI: " .. tostring(raygui.is_mouse_over_ui()))
    raygui.label(428, 410, 320, 28, "Font loaded: " .. tostring(font_loaded))
    raygui.label(428, 450, 320, 28, "Emoji atlas: " .. tostring(emoji_tex ~= nil))
    raygui.label(428, 490, 320, 28, "Close window / use frames=N to exit.")

    -- ===================== 第三行：图标 / Emoji / 对话框 =====================
    -- 组框要包住自己的内容：顶 566（在第二行 550 之下、不重叠），底 ~724（盖住 Last 标签）
    raygui.group(24, 566, 744, 128, "Icons / Emoji / Dialog")

    -- 1) #iconID# 内置图标按钮（与字体无关，单色）；同一行右侧放 emoji+文字 组合按钮
    raygui.set_icon_scale(2)
    if raygui.button(44,  600, 96,  34, "#131# Play")   then end
    if raygui.button(146, 600, 96,  34, "#132# Pause")  then end
    if raygui.button(248, 600, 96,  34, "#133# Stop")   then end
    if raygui.button(350, 600, 104, 34, "#141# Config") then end
    raygui.set_icon_scale(1)

    -- emoji + 文字 组合按钮（与图标按钮同一行）；点"删除"弹确认对话框
    if emoji_button(466, 600, 120, 34, "save", "保存") then
        confirm_result = "saved"
    end
    if emoji_button(594, 600, 120, 34, "delete", "删除") then
        confirm_open = true
    end

    -- 2) 彩色 emoji（贴图，从 emoji_atlas.png 采样）
    raygui.label(44, 644, 200, 24, "Color emoji:")
    if emoji_tex then
        for i = 0, 23 do
            draw_emoji(i, 150 + i * 24, 646, 20)
        end
    end

    if confirm_result ~= "" then
        raygui.label(44, 690, 320, 24, "Last: " .. confirm_result)
    end

    -- ===================== 置顶层：dropdown 与 对话框 =====================
    raygui.unlock()

    -- dropdown 放最后画，展开列表盖在最上层（正确 z 序）
    dropdown_selected, dropdown_open = raygui.dropdown(
        214, 400, 140, 36,
        "Option 1;Option 2;Option 3;Option 4",
        dropdown_selected,
        dropdown_open
    )

    -- 模态确认对话框：返回 -1=未点 0=✖ 1=取消 2=确定
    if confirm_open then
        local res = raygui.messagebox(290, 330, 320, 156,
            "Confirm", "Delete this item?\nThis cannot be undone.", "Cancel;OK")
        if res >= 0 then
            confirm_open = false
            confirm_result = (res == 2) and "deleted" or "cancelled"
        end
    end

    raygui.finish()
end

local function __init()
    raygui.init(790, 730, "RayGUI Lua demo")
    window_initialized = true

    local font_path = tool_dir .. "/fonts/NotoSansSC-Regular.otf"
    font_loaded = raygui.load_font(font_path, 20)

    -- 应用一个现代 UI 风格（styles/ 在 tools 下，require 走 package.path）
    -- 可换 dark / soft / nord / candy / cyber
    pcall(function() require("styles.candy").apply(raygui) end)

    raygui.set_style(raygui.DEFAULT, raygui.TEXT_SIZE, 20)
    raygui.set_style(raygui.DEFAULT, raygui.TEXT_PADDING, 4)
    raygui.set_style(raygui.DEFAULT, raygui.TEXT_ALIGNMENT, raygui.TEXT_ALIGN_LEFT)

    -- 预加载彩色 emoji 贴图（此时窗口/GL 上下文已就绪）；元数据 dofile 读取
    emoji_tex = raygui.load_texture(tool_dir .. "/emoji_atlas.png")
end

local function request_stop(code)
    if stop_requested then
        return
    end
    stop_requested = true

    io.stdout:write(("RayGUI demo completed, frames=%d\n"):format(frame))
    io.stdout:flush()

    if rawget(_G, "XNET_MAIN_FILE") then
        xthread.stop(code or 0)
    end
end

local function __update()
    if not window_initialized then
        return
    end

    if raygui.should_close() then
        request_stop(0)
        return
    end

    draw_demo_frame()

    if frame_limit and frame >= frame_limit then
        request_stop(0)
    end
end

local function __uninit()
    if window_initialized then
        if emoji_tex then raygui.unload_texture(emoji_tex) end
        raygui.close()
        window_initialized = false
    end
end

local function run_standalone()
    local ok, err = xpcall(function()
        __init()
        while not stop_requested do
            __update()
        end
        __uninit()
    end, debug.traceback)

    if window_initialized then
        __uninit()
    end

    if not ok then
        io.stderr:write(tostring(err), "\n")
        io.stderr:flush()
        return false
    end

    return true
end

if rawget(_G, "XNET_MAIN_FILE") then
    return {
        __tick_ms = 16,
        __thread_handle = function() end,
        __init = __init,
        __update = __update,
        __uninit = __uninit,
    }
end

os.exit(run_standalone() and 0 or 1)
