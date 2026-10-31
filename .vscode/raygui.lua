---@meta raygui
---@diagnostic disable: missing-return, unused-local

-- Editor-only LuaLS annotations for tools/raygui.dll.
-- Runtime code should keep using: local raygui = require("raygui")

---@class raygui
local raygui = {}

---@type integer
raygui.DEFAULT = 0

---@type integer
raygui.TEXT_ALIGNMENT = 14

---@type integer
raygui.TEXT_SIZE = 16

---@type integer
raygui.TEXT_PADDING = 13

---@type integer
raygui.TEXT_ALIGN_LEFT = 0

---@type integer
raygui.TEXT_ALIGN_CENTER = 1

---@type integer
raygui.TEXT_ALIGN_RIGHT = 2

---Initializes a raylib window for raygui drawing.
---@param width integer
---@param height integer
---@param title string
---@param options? {undecorated?: boolean, desktop_maximize?: boolean} desktop_maximize avoids exclusive-fullscreen detection for borderless maximized windows on Windows.
function raygui.init(width, height, title, options) end

---Closes the raylib window created by raygui.init().
function raygui.close() end

---Returns whether the window should close.
---@return boolean shouldClose
function raygui.should_close() end

---Begins one drawing frame.
function raygui.begin() end

---Finishes one drawing frame.
function raygui.finish() end

---Returns true when the mouse is currently over a raygui control.
---@return boolean overUI
function raygui.is_mouse_over_ui() end

---Draws a clickable button.
---@param x number
---@param y number
---@param width number
---@param height number
---@param text string
---@return boolean clicked
function raygui.button(x, y, width, height, text) end

---Draws a text label.
---@param x number
---@param y number
---@param width number
---@param height number
---@param text string
function raygui.label(x, y, width, height, text) end

---Draws a checkbox.
---@param x number
---@param y number
---@param width number
---@param height number
---@param text string
---@param checked boolean
---@return boolean checked
function raygui.checkbox(x, y, width, height, text, checked) end

---Draws a value slider.
---@param x number
---@param y number
---@param width number
---@param height number
---@param minValue number
---@param maxValue number
---@param value number
---@return number value
function raygui.slider(x, y, width, height, minValue, maxValue, value) end

---Draws a progress bar.
---@param x number
---@param y number
---@param width number
---@param height number
---@param value number
---@param minValue number
---@param maxValue number
function raygui.progressbar(x, y, width, height, value, minValue, maxValue) end

---Draws a single-line text box.
---@param x number
---@param y number
---@param width number
---@param height number
---@param text string
---@param editMode boolean
---@return string text
---@return boolean editMode
function raygui.textbox(x, y, width, height, text, editMode) end

---Draws a multi-line text box.
---@param x number
---@param y number
---@param width number
---@param height number
---@param text string
---@param editMode boolean
---@return string text
---@return boolean editMode
function raygui.textbox_multi(x, y, width, height, text, editMode) end

---Draws a panel.
---@param x number
---@param y number
---@param width number
---@param height number
---@param text string
function raygui.panel(x, y, width, height, text) end

---Draws a grouped box.
---@param x number
---@param y number
---@param width number
---@param height number
---@param text string
function raygui.group(x, y, width, height, text) end

---Draws a window box.
---@param x number
---@param y number
---@param width number
---@param height number
---@param text string
---@return boolean closed
function raygui.window(x, y, width, height, text) end

---Draws a dropdown box.
---@param x number
---@param y number
---@param width number
---@param height number
---@param text string
---@param selected integer
---@param open boolean
---@return integer selected
---@return boolean open
function raygui.dropdown(x, y, width, height, text, selected, open) end

---Draws a list view.
---@param x number
---@param y number
---@param width number
---@param height number
---@param text string
---@param selected integer
---@param scroll integer
---@return integer selected
---@return integer scroll
function raygui.listview(x, y, width, height, text, selected, scroll) end

---Sets a raygui style value.
---@param control integer
---@param property integer
---@param value integer
function raygui.set_style(control, property, value) end

---Loads a font from disk. The optional charset is passed to the native module.
---@param path string
---@param fontSize integer
---@param charset? string
---@return boolean ok
function raygui.load_font(path, fontSize, charset) end

---Loads the platform's UI font; returns false when no suitable font is found.
---@param font_size integer
---@param charset? string
---@return boolean
function raygui.load_system_font(font_size, charset) end

---@param text string
---@param font_size? integer
---@return number width
---@return number height
function raygui.measure_text(text, font_size) end

---@param text string
---@param x number
---@param y number
---@param font_size? number
---@param red? integer
---@param green? integer
---@param blue? integer
---@param alpha? integer
function raygui.draw_text(text, x, y, font_size, red, green, blue, alpha) end

---@return number x
---@return number y
function raygui.window_pos() end

---@param x integer
---@param y integer
function raygui.set_window_pos(x, y) end

---@param width integer
---@param height integer
function raygui.set_window_size(width, height) end

---@return number x
---@return number y
function raygui.mouse_screen() end

function raygui.minimize_window() end
function raygui.maximize_window() end
function raygui.restore_window() end

---@return boolean
function raygui.is_window_maximized() end

---@param cursor integer raylib MouseCursor value
function raygui.set_mouse_cursor(cursor) end

return raygui
