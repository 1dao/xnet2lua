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
function raygui.init(width, height, title) end

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

return raygui
