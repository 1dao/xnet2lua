---@meta
---@diagnostic disable: unreachable-code, unused-local
do return end

-- LuaLS metadata for the native raygui module.
-- LuaLS 使用的 raygui 原生模块元数据。
-- This file is metadata-only and does not execute at runtime.
-- 本文件仅用于元数据，不会在运行时执行。

---@class raygui
local raygui = {}

---@alias raygui.fileDialogStatus "active"|"select"|"cancel"

-- Public API / 公共 API

-- Window / 窗口

---Initialize the raylib window and reset raygui defaults.
---初始化 raylib 窗口，并重置 raygui 默认状态。
---@param width integer Window width in pixels. / 窗口宽度（像素）。
---@param height integer Window height in pixels. / 窗口高度（像素）。
---@param title string Title shown in the window frame. / 窗口标题栏显示的标题。
function raygui.init(width, height, title) end

---Close the window and release cached font, texture, and model resources.
---关闭窗口并释放缓存的字体、纹理和模型资源。
function raygui.close() end

---@return boolean shouldClose Whether the window has requested to close. / 窗口是否请求关闭。
function raygui.should_close() end

---Begin a drawing frame and clear the back buffer with DEFAULT.BACKGROUND_COLOR.
---开始绘制一帧，并使用 DEFAULT.BACKGROUND_COLOR 清空背景缓冲区。
function raygui.begin() end

---End the current drawing frame and present it to the screen.
---结束当前绘制帧并提交到屏幕。
function raygui.finish() end

-- Controls / 控件

---Draw a standard push button.
---绘制标准按钮。
---@param x number Left position in pixels. / 左侧位置（像素）。
---@param y number Top position in pixels. / 顶部位置（像素）。
---@param width number Button width. / 按钮宽度。
---@param height number Button height. / 按钮高度。
---@param text string Button label text. / 按钮显示文字。
---@return boolean pressed True when the button is clicked on this frame. / 本帧被点击时返回 true。
function raygui.button(x, y, width, height, text) end

---Draw a static text label.
---绘制静态文本标签。
---@param x number Left position in pixels. / 左侧位置（像素）。
---@param y number Top position in pixels. / 顶部位置（像素）。
---@param width number Label width. / 标签宽度。
---@param height number Label height. / 标签高度。
---@param text string Label text to display. / 要显示的标签文字。
function raygui.label(x, y, width, height, text) end

---Draw a checkbox and toggle its state when clicked.
---绘制复选框，并在点击时切换其状态。
---@param x number Left position in pixels. / 左侧位置（像素）。
---@param y number Top position in pixels. / 顶部位置（像素）。
---@param width number Checkbox width. / 复选框宽度。
---@param height number Checkbox height. / 复选框高度。
---@param text string Label text shown beside the box. / 复选框旁显示的文字。
---@param checked boolean Current checked state. / 当前是否勾选。
---@return boolean checked Updated checked state. / 更新后的勾选状态。
function raygui.checkbox(x, y, width, height, text, checked) end

---Draw a slider and return the mapped numeric value.
---绘制滑动条，并返回映射后的数值。
---@param x number Left position in pixels. / 左侧位置（像素）。
---@param y number Top position in pixels. / 顶部位置（像素）。
---@param width number Slider track width. / 滑条轨道宽度。
---@param height number Slider track height. / 滑条轨道高度。
---@param min number Minimum value of the range. / 范围最小值。
---@param max number Maximum value of the range. / 范围最大值。
---@param value number Current value to display and edit. / 当前显示并可编辑的值。
---@param _unused1? any Compatibility placeholder kept for the native binding. / 为兼容原生绑定保留的占位参数。
---@param _unused2? any Compatibility placeholder kept for the native binding. / 为兼容原生绑定保留的占位参数。
---@return number value Updated value within [min, max]. / 更新后的数值，位于 [min, max] 范围内。
function raygui.slider(x, y, width, height, min, max, value, _unused1, _unused2) end

---Draw a progress bar for a numeric value.
---绘制进度条，显示一个数值所处的进度。
---@param x number Left position in pixels. / 左侧位置（像素）。
---@param y number Top position in pixels. / 顶部位置（像素）。
---@param width number Progress bar width. / 进度条宽度。
---@param height number Progress bar height. / 进度条高度。
---@param value number Current progress value. / 当前进度值。
---@param min number Minimum value of the range. / 范围最小值。
---@param max number Maximum value of the range. / 范围最大值。
function raygui.progressbar(x, y, width, height, value, min, max) end

---Draw a single-line text box.
---绘制单行文本输入框。
---@param x number Left position in pixels. / 左侧位置（像素）。
---@param y number Top position in pixels. / 顶部位置（像素）。
---@param width number Text box width. / 输入框宽度。
---@param height number Text box height. / 输入框高度。
---@param text string Current text content. / 当前文本内容。
---@param editMode boolean Whether the box is in edit mode. / 是否处于编辑状态。
---@return string text Updated text content. / 更新后的文本内容。
---@return boolean editMode Updated edit mode flag. / 更新后的编辑状态。
function raygui.textbox(x, y, width, height, text, editMode) end

---Draw a multi-line text box with word wrapping and submission support.
---绘制多行文本输入框，支持自动换行和提交。
---@param x number Left position in pixels. / 左侧位置（像素）。
---@param y number Top position in pixels. / 顶部位置（像素）。
---@param width number Text box width. / 输入框宽度。
---@param height number Text box height. / 输入框高度。
---@param text string Current text content. / 当前文本内容。
---@param editMode boolean Whether the box is in edit mode. / 是否处于编辑状态。
---@param enterSubmits? boolean When true, Enter submits and Ctrl+Enter inserts a newline. / 为 true 时，Enter 提交，Ctrl+Enter 插入换行。
---@return string text Updated text content. / 更新后的文本内容。
---@return boolean editMode Updated edit mode flag. / 更新后的编辑状态。
---@return boolean submitted True when the content was submitted on this frame. / 本帧触发提交时返回 true。
function raygui.textbox_multi(x, y, width, height, text, editMode, enterSubmits) end

---Draw a plain panel container.
---绘制普通面板容器。
---@param x number Left position in pixels. / 左侧位置（像素）。
---@param y number Top position in pixels. / 顶部位置（像素）。
---@param width number Panel width. / 面板宽度。
---@param height number Panel height. / 面板高度。
---@param text string Optional caption text. / 可选标题文字。
function raygui.panel(x, y, width, height, text) end

---Draw a group box with a caption line.
---绘制带标题线的分组框。
---@param x number Left position in pixels. / 左侧位置（像素）。
---@param y number Top position in pixels. / 顶部位置（像素）。
---@param width number Group box width. / 分组框宽度。
---@param height number Group box height. / 分组框高度。
---@param text string Group title text. / 分组标题文字。
function raygui.group(x, y, width, height, text) end

-- Window dialogs / 窗口对话框

---Draw a window box with a title bar and close button.
---绘制带标题栏和关闭按钮的窗口框。
---@param x number Left position in pixels. / 左侧位置（像素）。
---@param y number Top position in pixels. / 顶部位置（像素）。
---@param width number Window width. / 窗口宽度。
---@param height number Window height. / 窗口高度。
---@param title string Window title text. / 窗口标题文字。
---@return boolean closed True when the close button is clicked. / 点击关闭按钮时返回 true。
function raygui.window(x, y, width, height, title) end

---Draw a modal message box and return the selected result.
---绘制模态消息框，并返回用户选择的结果。
---@param x number Left position in pixels. / 左侧位置（像素）。
---@param y number Top position in pixels. / 顶部位置（像素）。
---@param width number Dialog width. / 对话框宽度。
---@param height number Dialog height. / 对话框高度。
---@param title string Dialog title. / 对话框标题。
---@param message string Message text shown in the body. / 消息正文文本。
---@param buttons string Semicolon-separated button labels, such as "Cancel;OK". / 用分号分隔的按钮标签，例如 "Cancel;OK"。
---@return integer result Returns -1 while open, 0 when the close button is clicked, or a 1-based button index. / 打开时返回 -1，点击关闭按钮返回 0，否则返回从 1 开始的按钮索引。
function raygui.messagebox(x, y, width, height, title, message, buttons) end

---Draw a dropdown selector.
---绘制下拉选择框。
---@param x number Left position in pixels. / 左侧位置（像素）。
---@param y number Top position in pixels. / 顶部位置（像素）。
---@param width number Dropdown width. / 下拉框宽度。
---@param height number Dropdown height. / 下拉框高度。
---@param text string Semicolon-separated item labels. / 用分号分隔的选项文本。
---@param selected integer 1-based selected index. / 当前选中的索引，从 1 开始。
---@param open boolean Whether the dropdown is expanded. / 下拉框是否展开。
---@return integer selected Updated 1-based selected index. / 更新后的选中索引，从 1 开始。
---@return boolean open Updated expanded state. / 更新后的展开状态。
function raygui.dropdown(x, y, width, height, text, selected, open) end

---Draw a scrollable list view.
---绘制可滚动的列表视图。
---@param x number Left position in pixels. / 左侧位置（像素）。
---@param y number Top position in pixels. / 顶部位置（像素）。
---@param width number List view width. / 列表视图宽度。
---@param height number List view height. / 列表视图高度。
---@param text string Semicolon-separated item labels. / 用分号分隔的项目文本。
---@param selected integer 1-based selected index. / 当前选中的索引，从 1 开始。
---@param scroll integer Current scroll offset. / 当前滚动偏移。
---@return integer selected Updated 1-based selected index. / 更新后的选中索引，从 1 开始。
---@return integer scroll Updated scroll offset. / 更新后的滚动偏移。
function raygui.listview(x, y, width, height, text, selected, scroll) end

---Check whether the mouse is currently over an interactive UI element.
---检查鼠标当前是否悬停在可交互 UI 元素上。
---@return boolean overUi True when the pointer is over UI. / 指针悬停在 UI 上时返回 true。
function raygui.is_mouse_over_ui() end

-- Control style / 控件样式

---Set a style property for a control class.
---为某个控件类设置样式属性。
---@param control integer Control ID such as DEFAULT or BUTTON. / 控件 ID，例如 DEFAULT 或 BUTTON。
---@param property integer Style property constant. / 样式属性常量。
---@param value integer Integer value to store in the style table. / 要写入样式表的整数值。
function raygui.set_style(control, property, value) end

---Get a style property for a control class.
---读取某个控件类的样式属性。
---@param control integer Control ID such as DEFAULT or BUTTON. / 控件 ID，例如 DEFAULT 或 BUTTON。
---@param property integer Style property constant. / 样式属性常量。
---@return integer value Stored integer style value. / 已保存的整数样式值。
function raygui.get_style(control, property) end

-- Resources / 资源

---Load a font file and optionally preload extra glyphs.
---加载字体文件，并可选预载额外字形。
---@param path string Font file path. / 字体文件路径。
---@param fontSize integer Font size in pixels. / 字体大小（像素）。
---@param charset? string Seed text used to preload glyphs that may be needed later. / 用于预载后续可能用到字形的种子文本。
---@return boolean ok True when the font loads successfully. / 字体加载成功时返回 true。
function raygui.load_font(path, fontSize, charset) end

---Load an image file into a GPU texture.
---将图片文件加载为 GPU 纹理。
---@param path string Image file path. / 图片文件路径。
---@return integer|nil textureId Texture id on success, or nil on failure. / 成功时返回纹理 ID，失败时返回 nil。
---@return string|nil err Error message when loading fails. / 加载失败时返回错误信息。
function raygui.load_texture(path) end

---Decode in-memory PNG bytes into a texture.
---把内存中的 PNG 数据解码为纹理。
---@param pngBytes string PNG byte string. / PNG 二进制数据。
---@return integer|nil textureId Texture id on success, or nil on failure. / 成功时返回纹理 ID，失败时返回 nil。
---@return integer|string|nil widthOrError Texture width on success, or an error string on failure. / 成功时返回纹理宽度，失败时返回错误字符串。
---@return integer|nil height Texture height on success. / 成功时返回纹理高度。
function raygui.load_texture_mem(pngBytes) end

---Release a texture previously created by raygui.load_texture or raygui.load_texture_mem.
---释放由 raygui.load_texture 或 raygui.load_texture_mem 创建的纹理。
---@param textureId integer Texture id to unload. / 要释放的纹理 ID。
function raygui.unload_texture(textureId) end

---Read the current clipboard image and encode it as PNG bytes.
---读取当前剪贴板中的图片，并编码为 PNG 字节串。
---@return string|nil pngBytes PNG bytes when an image is available. / 剪贴板有图片时返回 PNG 字节串。
---@return integer|nil width Image width in pixels. / 图片宽度（像素）。
---@return integer|nil height Image height in pixels. / 图片高度（像素）。
function raygui.get_clipboard_image() end

---Take the last pasted image captured from Ctrl+V in textbox_multi.
---取走最近一次在 textbox_multi 中通过 Ctrl+V 捕获到的图片。
---@return string|nil pngBytes PNG bytes when a pasted image is pending. / 有待处理的粘贴图片时返回 PNG 字节串。
---@return integer|nil width Image width in pixels. / 图片宽度（像素）。
---@return integer|nil height Image height in pixels. / 图片高度（像素）。
function raygui.take_pasted_image() end

---Open the in-app file or directory picker.
---打开内置的文件或目录选择对话框。
---@param initPath? string Optional initial path. / 可选的初始路径。
---@param width? integer Optional dialog width. / 可选的对话框宽度。
---@param height? integer Optional dialog height. / 可选的对话框高度。
---@param dirsOnly? boolean When true, force directory-only selection. / 为 true 时仅选择目录。
function raygui.file_dialog_open(initPath, width, height, dirsOnly) end

---Poll the file dialog once per frame.
---每帧轮询一次文件对话框。
---@return raygui.fileDialogStatus|nil status Active while open, select on success, cancel on close, or nil when not opened. / 打开时返回 active，选择成功返回 select，关闭返回 cancel，未打开时返回 nil。
---@return string|nil dir Current directory path. / 当前目录路径。
---@return string|nil file Selected file name. / 选中的文件名。
function raygui.file_dialog() end

---Draw a full texture at the destination rectangle.
---在目标矩形位置绘制整张纹理。
---@param textureId integer Texture id returned by load_texture. / load_texture 返回的纹理 ID。
---@param x number Destination x position. / 目标 X 坐标。
---@param y number Destination y position. / 目标 Y 坐标。
---@param width? number Optional destination width, defaults to the texture width. / 可选目标宽度，默认使用纹理宽度。
---@param height? number Optional destination height, defaults to the texture height. / 可选目标高度，默认使用纹理高度。
---@param r? integer Tint red channel, 0..255. / 调色红色通道，范围 0..255。
---@param g? integer Tint green channel, 0..255. / 调色绿色通道，范围 0..255。
---@param b? integer Tint blue channel, 0..255. / 调色蓝色通道，范围 0..255。
---@param a? integer Tint alpha channel, 0..255. / 调色透明度通道，范围 0..255。
function raygui.draw_texture(textureId, x, y, width, height, r, g, b, a) end

-- Drawing / 绘制

---Draw a source sub-rectangle of a texture to a destination rectangle.
---将纹理的源子矩形绘制到目标矩形。
---@param textureId integer Texture id returned by load_texture. / load_texture 返回的纹理 ID。
---@param srcX number Source rectangle x position. / 源矩形的 X 坐标。
---@param srcY number Source rectangle y position. / 源矩形的 Y 坐标。
---@param srcW number Source rectangle width. / 源矩形宽度。
---@param srcH number Source rectangle height. / 源矩形高度。
---@param dstX number Destination x position. / 目标 X 坐标。
---@param dstY number Destination y position. / 目标 Y 坐标。
---@param dstW? number Optional destination width, defaults to srcW. / 可选目标宽度，默认使用 srcW。
---@param dstH? number Optional destination height, defaults to srcH. / 可选目标高度，默认使用 srcH。
---@param r? integer Tint red channel, 0..255. / 调色红色通道，范围 0..255。
---@param g? integer Tint green channel, 0..255. / 调色绿色通道，范围 0..255。
---@param b? integer Tint blue channel, 0..255. / 调色蓝色通道，范围 0..255。
---@param a? integer Tint alpha channel, 0..255. / 调色透明度通道，范围 0..255。
function raygui.draw_texture_ex(textureId, srcX, srcY, srcW, srcH, dstX, dstY, dstW, dstH, r, g, b, a) end

---Draw one built-in raygui icon.
---绘制一个 raygui 内置图标。
---@param iconId integer Icon constant such as ICON_SAVE or ICON_CUBE. / 图标常量，例如 ICON_SAVE 或 ICON_CUBE。
---@param x integer Destination x position. / 目标 X 坐标。
---@param y integer Destination y position. / 目标 Y 坐标。
---@param pixelSize integer Icon size in pixels. / 图标尺寸（像素）。
---@param r? integer Icon red channel, 0..255. / 图标红色通道，范围 0..255。
---@param g? integer Icon green channel, 0..255. / 图标绿色通道，范围 0..255。
---@param b? integer Icon blue channel, 0..255. / 图标蓝色通道，范围 0..255。
---@param a? integer Icon alpha channel, 0..255. / 图标透明度通道，范围 0..255。
function raygui.draw_icon(iconId, x, y, pixelSize, r, g, b, a) end

---Set the icon scale used by the current UI context.
---设置当前 UI 上下文使用的图标缩放倍数。
---@param scale integer Icon scale factor. / 图标缩放倍数。
function raygui.set_icon_scale(scale) end

-- Resource helper / 资源辅助

---Load a style file and apply its settings.
---加载样式文件并应用其中的设置。
---@param path string Style file path. / 样式文件路径。
---@return boolean ok True when the style loads successfully. / 样式加载成功时返回 true。
---@return string|nil err Error message when loading fails. / 加载失败时返回错误信息。
function raygui.load_style(path) end

-- Window state / 窗口状态

---Lock UI interaction so controls do not respond to input.
---锁定 UI 交互，使控件暂时不响应输入。
function raygui.lock() end

---Unlock UI interaction again.
---解除 UI 交互锁定。
function raygui.unlock() end

---Check whether the UI is currently locked.
---检查 UI 是否处于锁定状态。
---@return boolean locked True when UI input is locked. / UI 输入被锁定时返回 true。
function raygui.is_locked() end

---Draw a rotating 3D model preview viewport.
---绘制一个会旋转的 3D 模型预览窗口。
---@param x number Left position in pixels. / 左侧位置（像素）。
---@param y number Top position in pixels. / 顶部位置（像素）。
---@param width number Viewport width. / 视口宽度。
---@param height number Viewport height. / 视口高度。
---@param angle? number Optional angle in degrees, defaults to time-based rotation. / 可选角度（度），默认按时间自动旋转。
function raygui.model_view(x, y, width, height, angle) end

---Measure text size using the current font.
---使用当前字体测量文本尺寸。
---@param text string Text to measure. / 要测量的文本。
---@param size? number Optional font size, defaults to DEFAULT.TEXT_SIZE. / 可选字体大小，默认使用 DEFAULT.TEXT_SIZE。
---@return number width Measured text width in pixels. / 测量得到的文本宽度（像素）。
---@return number height Measured text height in pixels. / 测量得到的文本高度（像素）。
function raygui.measure_text(text, size) end

---Draw text directly to the screen.
---直接在屏幕上绘制文本。
---@param text string Text to draw. / 要绘制的文本。
---@param x number Baseline x position. / 基线 X 坐标。
---@param y number Baseline y position. / 基线 Y 坐标。
---@param size? number Optional font size, defaults to DEFAULT.TEXT_SIZE. / 可选字体大小，默认使用 DEFAULT.TEXT_SIZE。
---@param r? integer Text red channel, 0..255. / 文本红色通道，范围 0..255。
---@param g? integer Text green channel, 0..255. / 文本绿色通道，范围 0..255。
---@param b? integer Text blue channel, 0..255. / 文本蓝色通道，范围 0..255。
---@param a? integer Text alpha channel, 0..255. / 文本透明度通道，范围 0..255。
function raygui.draw_text(text, x, y, size, r, g, b, a) end

---Draw a filled rectangle.
---绘制一个实心矩形。
---@param x number Left position. / 左侧位置。
---@param y number Top position. / 顶部位置。
---@param width number Rectangle width. / 矩形宽度。
---@param height number Rectangle height. / 矩形高度。
---@param r? integer Fill red channel, 0..255. / 填充红色通道，范围 0..255。
---@param g? integer Fill green channel, 0..255. / 填充绿色通道，范围 0..255。
---@param b? integer Fill blue channel, 0..255. / 填充蓝色通道，范围 0..255。
---@param a? integer Fill alpha channel, 0..255. / 填充透明度通道，范围 0..255。
function raygui.draw_rectangle(x, y, width, height, r, g, b, a) end

---Begin a scissor rectangle to clip subsequent drawing.
---开始一个剪裁矩形，对后续绘制进行裁剪。
---@param x number Left position of the clip rect. / 裁剪矩形左侧位置。
---@param y number Top position of the clip rect. / 裁剪矩形顶部位置。
---@param width number Clip rect width. / 裁剪矩形宽度。
---@param height number Clip rect height. / 裁剪矩形高度。
function raygui.begin_scissor(x, y, width, height) end

---End the active scissor rectangle.
---结束当前激活的剪裁矩形。
function raygui.end_scissor() end

-- Input / 输入

---Get the current vertical mouse wheel delta.
---获取当前鼠标滚轮的垂直增量。
---@return number dy Wheel delta for this frame. / 本帧滚轮的增量。
function raygui.get_wheel() end

---Get the current mouse position.
---获取当前鼠标坐标。
---@return number x Mouse x position in pixels. / 鼠标 X 坐标（像素）。
---@return number y Mouse y position in pixels. / 鼠标 Y 坐标（像素）。
function raygui.get_mouse() end

---Get the current window size.
---获取当前窗口尺寸。
---@return integer width Window width in pixels. / 窗口宽度（像素）。
---@return integer height Window height in pixels. / 窗口高度（像素）。
function raygui.screen_size() end

---Set the system clipboard text.
---设置系统剪贴板文本。
---@param text string Text to place on the clipboard. / 要写入剪贴板的文本。
function raygui.set_clipboard(text) end

---Get the current system clipboard text.
---读取当前系统剪贴板文本。
---@return string text Clipboard text contents. / 剪贴板中的文本内容。
function raygui.get_clipboard() end

-- Style constants / 样式常量

-- Default style slot / 默认样式槽位
raygui.DEFAULT = 0

-- Text layout / 文本布局
raygui.TEXT_ALIGNMENT = 14
raygui.TEXT_SIZE = 16
raygui.TEXT_PADDING = 13
raygui.TEXT_ALIGN_LEFT = 0
raygui.TEXT_ALIGN_CENTER = 1
raygui.TEXT_ALIGN_RIGHT = 2

-- Color slots / 颜色槽位
raygui.BORDER_COLOR_NORMAL = 0
raygui.BASE_COLOR_NORMAL = 1
raygui.TEXT_COLOR_NORMAL = 2
raygui.BORDER_COLOR_FOCUSED = 3
raygui.BASE_COLOR_FOCUSED = 4
raygui.TEXT_COLOR_FOCUSED = 5
raygui.BORDER_COLOR_PRESSED = 6
raygui.BASE_COLOR_PRESSED = 7
raygui.TEXT_COLOR_PRESSED = 8
raygui.BORDER_COLOR_DISABLED = 9
raygui.BASE_COLOR_DISABLED = 10
raygui.TEXT_COLOR_DISABLED = 11

-- Size and spacing / 尺寸与间距
raygui.BORDER_WIDTH = 12
raygui.TEXT_SPACING = 17
raygui.LINE_COLOR = 18
raygui.BACKGROUND_COLOR = 19
raygui.TEXT_LINE_SPACING = 20

-- Control IDs / 控件 ID
raygui.LABEL = 1
raygui.BUTTON = 2
raygui.TOGGLE = 3
raygui.SLIDER = 4
raygui.PROGRESSBAR = 5
raygui.CHECKBOX = 6
raygui.TEXTBOX = 9
raygui.VALUEBOX = 10

-- Icon constants / 图标常量 (raygui ricons 4.x)
raygui.ICON_NONE = 0
raygui.ICON_FOLDER_FILE_OPEN = 1
raygui.ICON_FILE_SAVE_CLASSIC = 2
raygui.ICON_FOLDER_OPEN = 3
raygui.ICON_FOLDER_SAVE = 4
raygui.ICON_FILE_OPEN = 5
raygui.ICON_FILE_SAVE = 6
raygui.ICON_FILE_EXPORT = 7
raygui.ICON_FILE_ADD = 8
raygui.ICON_FILE_DELETE = 9
raygui.ICON_FILETYPE_TEXT = 10
raygui.ICON_FILETYPE_AUDIO = 11
raygui.ICON_FILETYPE_IMAGE = 12
raygui.ICON_FILETYPE_PLAY = 13
raygui.ICON_FILETYPE_VIDEO = 14
raygui.ICON_FILETYPE_INFO = 15
raygui.ICON_FILE_COPY = 16
raygui.ICON_FILE_CUT = 17
raygui.ICON_FILE_PASTE = 18
raygui.ICON_CURSOR_HAND = 19
raygui.ICON_CURSOR_POINTER = 20
raygui.ICON_CURSOR_CLASSIC = 21
raygui.ICON_PENCIL = 22
raygui.ICON_PENCIL_BIG = 23
raygui.ICON_BRUSH_CLASSIC = 24
raygui.ICON_BRUSH_PAINTER = 25
raygui.ICON_WATER_DROP = 26
raygui.ICON_COLOR_PICKER = 27
raygui.ICON_RUBBER = 28
raygui.ICON_COLOR_BUCKET = 29
raygui.ICON_TEXT_T = 30
raygui.ICON_TEXT_A = 31
raygui.ICON_SCALE = 32
raygui.ICON_RESIZE = 33
raygui.ICON_FILTER_POINT = 34
raygui.ICON_FILTER_BILINEAR = 35
raygui.ICON_CROP = 36
raygui.ICON_CROP_ALPHA = 37
raygui.ICON_SQUARE_TOGGLE = 38
raygui.ICON_SYMMETRY = 39
raygui.ICON_SYMMETRY_HORIZONTAL = 40
raygui.ICON_SYMMETRY_VERTICAL = 41
raygui.ICON_LENS = 42
raygui.ICON_LENS_BIG = 43
raygui.ICON_EYE_ON = 44
raygui.ICON_EYE_OFF = 45
raygui.ICON_FILTER_TOP = 46
raygui.ICON_FILTER = 47
raygui.ICON_TARGET_POINT = 48
raygui.ICON_TARGET_SMALL = 49
raygui.ICON_TARGET_BIG = 50
raygui.ICON_TARGET_MOVE = 51
raygui.ICON_CURSOR_MOVE = 52
raygui.ICON_CURSOR_SCALE = 53
raygui.ICON_CURSOR_SCALE_RIGHT = 54
raygui.ICON_CURSOR_SCALE_LEFT = 55
raygui.ICON_UNDO = 56
raygui.ICON_REDO = 57
raygui.ICON_REREDO = 58
raygui.ICON_MUTATE = 59
raygui.ICON_ROTATE = 60
raygui.ICON_REPEAT = 61
raygui.ICON_SHUFFLE = 62
raygui.ICON_EMPTYBOX = 63
raygui.ICON_TARGET = 64
raygui.ICON_TARGET_SMALL_FILL = 65
raygui.ICON_TARGET_BIG_FILL = 66
raygui.ICON_TARGET_MOVE_FILL = 67
raygui.ICON_CURSOR_MOVE_FILL = 68
raygui.ICON_CURSOR_SCALE_FILL = 69
raygui.ICON_CURSOR_SCALE_RIGHT_FILL = 70
raygui.ICON_CURSOR_SCALE_LEFT_FILL = 71
raygui.ICON_UNDO_FILL = 72
raygui.ICON_REDO_FILL = 73
raygui.ICON_REREDO_FILL = 74
raygui.ICON_MUTATE_FILL = 75
raygui.ICON_ROTATE_FILL = 76
raygui.ICON_REPEAT_FILL = 77
raygui.ICON_SHUFFLE_FILL = 78
raygui.ICON_EMPTYBOX_SMALL = 79
raygui.ICON_BOX = 80
raygui.ICON_BOX_TOP = 81
raygui.ICON_BOX_TOP_RIGHT = 82
raygui.ICON_BOX_RIGHT = 83
raygui.ICON_BOX_BOTTOM_RIGHT = 84
raygui.ICON_BOX_BOTTOM = 85
raygui.ICON_BOX_BOTTOM_LEFT = 86
raygui.ICON_BOX_LEFT = 87
raygui.ICON_BOX_TOP_LEFT = 88
raygui.ICON_BOX_CENTER = 89
raygui.ICON_BOX_CIRCLE_MASK = 90
raygui.ICON_POT = 91
raygui.ICON_ALPHA_MULTIPLY = 92
raygui.ICON_ALPHA_CLEAR = 93
raygui.ICON_DITHERING = 94
raygui.ICON_MIPMAPS = 95
raygui.ICON_BOX_GRID = 96
raygui.ICON_GRID = 97
raygui.ICON_BOX_CORNERS_SMALL = 98
raygui.ICON_BOX_CORNERS_BIG = 99
raygui.ICON_FOUR_BOXES = 100
raygui.ICON_GRID_FILL = 101
raygui.ICON_BOX_MULTISIZE = 102
raygui.ICON_ZOOM_SMALL = 103
raygui.ICON_ZOOM_MEDIUM = 104
raygui.ICON_ZOOM_BIG = 105
raygui.ICON_ZOOM_ALL = 106
raygui.ICON_ZOOM_CENTER = 107
raygui.ICON_BOX_DOTS_SMALL = 108
raygui.ICON_BOX_DOTS_BIG = 109
raygui.ICON_BOX_CONCENTRIC = 110
raygui.ICON_BOX_GRID_BIG = 111
raygui.ICON_OK_TICK = 112
raygui.ICON_CROSS = 113
raygui.ICON_ARROW_LEFT = 114
raygui.ICON_ARROW_RIGHT = 115
raygui.ICON_ARROW_DOWN = 116
raygui.ICON_ARROW_UP = 117
raygui.ICON_ARROW_LEFT_FILL = 118
raygui.ICON_ARROW_RIGHT_FILL = 119
raygui.ICON_ARROW_DOWN_FILL = 120
raygui.ICON_ARROW_UP_FILL = 121
raygui.ICON_AUDIO = 122
raygui.ICON_FX = 123
raygui.ICON_WAVE = 124
raygui.ICON_WAVE_SINUS = 125
raygui.ICON_WAVE_SQUARE = 126
raygui.ICON_WAVE_TRIANGULAR = 127
raygui.ICON_CROSS_SMALL = 128
raygui.ICON_PLAYER_PREVIOUS = 129
raygui.ICON_PLAYER_PLAY_BACK = 130
raygui.ICON_PLAYER_PLAY = 131
raygui.ICON_PLAYER_PAUSE = 132
raygui.ICON_PLAYER_STOP = 133
raygui.ICON_PLAYER_NEXT = 134
raygui.ICON_PLAYER_RECORD = 135
raygui.ICON_MAGNET = 136
raygui.ICON_LOCK_CLOSE = 137
raygui.ICON_LOCK_OPEN = 138
raygui.ICON_CLOCK = 139
raygui.ICON_TOOLS = 140
raygui.ICON_GEAR = 141
raygui.ICON_GEAR_BIG = 142
raygui.ICON_BIN = 143
raygui.ICON_HAND_POINTER = 144
raygui.ICON_LASER = 145
raygui.ICON_COIN = 146
raygui.ICON_EXPLOSION = 147
raygui.ICON_1UP = 148
raygui.ICON_PLAYER = 149
raygui.ICON_PLAYER_JUMP = 150
raygui.ICON_KEY = 151
raygui.ICON_DEMON = 152
raygui.ICON_TEXT_POPUP = 153
raygui.ICON_GEAR_EX = 154
raygui.ICON_CRACK = 155
raygui.ICON_CRACK_POINTS = 156
raygui.ICON_STAR = 157
raygui.ICON_DOOR = 158
raygui.ICON_EXIT = 159
raygui.ICON_MODE_2D = 160
raygui.ICON_MODE_3D = 161
raygui.ICON_CUBE = 162
raygui.ICON_CUBE_FACE_TOP = 163
raygui.ICON_CUBE_FACE_LEFT = 164
raygui.ICON_CUBE_FACE_FRONT = 165
raygui.ICON_CUBE_FACE_BOTTOM = 166
raygui.ICON_CUBE_FACE_RIGHT = 167
raygui.ICON_CUBE_FACE_BACK = 168
raygui.ICON_CAMERA = 169
raygui.ICON_SPECIAL = 170
raygui.ICON_LINK_NET = 171
raygui.ICON_LINK_BOXES = 172
raygui.ICON_LINK_MULTI = 173
raygui.ICON_LINK = 174
raygui.ICON_LINK_BROKE = 175
raygui.ICON_TEXT_NOTES = 176
raygui.ICON_NOTEBOOK = 177
raygui.ICON_SUITCASE = 178
raygui.ICON_SUITCASE_ZIP = 179
raygui.ICON_MAILBOX = 180
raygui.ICON_MONITOR = 181
raygui.ICON_PRINTER = 182
raygui.ICON_PHOTO_CAMERA = 183
raygui.ICON_PHOTO_CAMERA_FLASH = 184
raygui.ICON_HOUSE = 185
raygui.ICON_HEART = 186
raygui.ICON_CORNER = 187
raygui.ICON_VERTICAL_BARS = 188
raygui.ICON_VERTICAL_BARS_FILL = 189
raygui.ICON_LIFE_BARS = 190
raygui.ICON_INFO = 191
raygui.ICON_CROSSLINE = 192
raygui.ICON_HELP = 193
raygui.ICON_FILETYPE_ALPHA = 194
raygui.ICON_FILETYPE_HOME = 195
raygui.ICON_LAYERS_VISIBLE = 196
raygui.ICON_LAYERS = 197
raygui.ICON_WINDOW = 198
raygui.ICON_HIDPI = 199
raygui.ICON_FILETYPE_BINARY = 200
raygui.ICON_HEX = 201
raygui.ICON_SHIELD = 202
raygui.ICON_FILE_NEW = 203
raygui.ICON_FOLDER_ADD = 204
raygui.ICON_ALARM = 205
raygui.ICON_CPU = 206
raygui.ICON_ROM = 207
raygui.ICON_STEP_OVER = 208
raygui.ICON_STEP_INTO = 209
raygui.ICON_STEP_OUT = 210
raygui.ICON_RESTART = 211
raygui.ICON_BREAKPOINT_ON = 212
raygui.ICON_BREAKPOINT_OFF = 213
raygui.ICON_BURGER_MENU = 214
raygui.ICON_CASE_SENSITIVE = 215
raygui.ICON_REG_EXP = 216
raygui.ICON_FOLDER = 217
raygui.ICON_FILE = 218
raygui.ICON_SAND_TIMER = 219
raygui.ICON_WARNING = 220
raygui.ICON_HELP_BOX = 221
raygui.ICON_INFO_BOX = 222
raygui.ICON_PRIORITY = 223
raygui.ICON_LAYERS_ISO = 224
raygui.ICON_LAYERS2 = 225
raygui.ICON_MLAYERS = 226
raygui.ICON_MAPS = 227
raygui.ICON_HOT = 228
raygui.ICON_LABEL = 229
raygui.ICON_NAME_ID = 230
raygui.ICON_SLICING = 231
raygui.ICON_MANUAL_CONTROL = 232
raygui.ICON_COLLISION = 233
raygui.ICON_CIRCLE_ADD = 234
raygui.ICON_CIRCLE_ADD_FILL = 235
raygui.ICON_CIRCLE_WARNING = 236
raygui.ICON_CIRCLE_WARNING_FILL = 237
raygui.ICON_BOX_MORE = 238
raygui.ICON_BOX_MORE_FILL = 239
raygui.ICON_BOX_MINUS = 240
raygui.ICON_BOX_MINUS_FILL = 241
raygui.ICON_UNION = 242
raygui.ICON_INTERSECTION = 243
raygui.ICON_DIFFERENCE = 244
raygui.ICON_SPHERE = 245
raygui.ICON_CYLINDER = 246
raygui.ICON_CONE = 247
raygui.ICON_ELLIPSOID = 248
raygui.ICON_CAPSULE = 249

return raygui
