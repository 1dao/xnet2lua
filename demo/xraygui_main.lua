-- RayGUI usage demo.
-- Preferred in this repo:
--   bin/xnet demo/raygui_main.lua
-- Auto-exit after N frames, useful for smoke checks:
--   bin/xnet demo/raygui_main.lua frames=120
-- It can also run with a standalone Lua runtime that matches raygui.dll:
--   lua demo/raygui_main.lua

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

local function draw_demo_frame()
    frame = frame + 1
    progress_value = (progress_value + 0.5) % 100

    raygui.begin()

    raygui.panel(10, 10, 780, 580, "RayGUI Lua demo")
    raygui.label(24, 42, 300, 28, "Run: bin/xnet demo/raygui_main.lua")

    if frame_limit then
        raygui.label(520, 42, 220, 28, ("Frame %d / %d"):format(frame, frame_limit))
    else
        raygui.label(520, 42, 220, 28, ("Frame %d"):format(frame))
    end

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

    raygui.group(408, 86, 348, 220, "Text controls")

    raygui.label(428, 124, 84, 28, "Textbox")
    text_input, text_input_edit = raygui.textbox(520, 120, 210, 36, text_input, text_input_edit)

    raygui.label(428, 176, 84, 28, "Multi")
    text_multi, text_multi_edit = raygui.textbox_multi(520, 172, 210, 86, text_multi, text_multi_edit)

    raygui.group(24, 330, 360, 220, "Selection controls")

    raygui.label(44, 370, 86, 28, "List")
    list_selected, list_scroll = raygui.listview(
        44, 400, 150, 126,
        "alpha;bravo;charlie;delta;echo;foxtrot;golf",
        list_selected,
        list_scroll
    )
    raygui.label(44, 528, 150, 20, "List index: " .. tostring(list_selected))
    raygui.label(214, 448, 140, 28, "Dropdown: " .. tostring(dropdown_selected))

    -- Draw dropdown last so its expanded popup stays above nearby controls.
    raygui.label(214, 370, 120, 28, "Dropdown")
    dropdown_selected, dropdown_open = raygui.dropdown(
        214, 400, 140, 36,
        "Option 1;Option 2;Option 3;Option 4",
        dropdown_selected,
        dropdown_open
    )

    raygui.group(408, 330, 348, 220, "Status")
    raygui.label(428, 370, 260, 28, "Mouse over UI: " .. tostring(raygui.is_mouse_over_ui()))
    raygui.label(428, 410, 260, 28, "Font loaded: " .. tostring(font_loaded))
    raygui.label(428, 450, 280, 28, "Close the window to exit.")
    raygui.label(428, 490, 280, 28, "Use frames=N for auto-exit.")

    raygui.finish()
end

local function __init()
    raygui.init(800, 600, "RayGUI Lua demo")
    window_initialized = true

    local font_path = tool_dir .. "/fonts/NotoSansSC-Regular.otf"
    font_loaded = raygui.load_font(font_path, 20)

    raygui.set_style(raygui.DEFAULT, raygui.TEXT_SIZE, 20)
    raygui.set_style(raygui.DEFAULT, raygui.TEXT_PADDING, 4)
    raygui.set_style(raygui.DEFAULT, raygui.TEXT_ALIGNMENT, raygui.TEXT_ALIGN_LEFT)
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
