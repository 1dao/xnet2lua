-- raygui Soft 风格（清新柔光 — 现代、干净、呼吸感）
-- 灵感来自 Material Design / 毛玻璃质感
-- 用法: require("styles.soft").apply(raygui)

local M = {}

function M.apply(raygui)
    local D = raygui.DEFAULT
    local B = raygui.BUTTON
    local S = raygui.SLIDER
    local P = raygui.PROGRESSBAR
    local C = raygui.CHECKBOX
    local T = raygui.TEXTBOX
    local V = raygui.VALUEBOX

    -- ========== DEFAULT 全局属性 ==========
    -- 亮色清爽基底
    raygui.set_style(D, raygui.BORDER_COLOR_NORMAL,   0xe2e5f0ff)  -- 浅灰框线
    raygui.set_style(D, raygui.BASE_COLOR_NORMAL,     0xffffffff)  -- 纯白填充
    raygui.set_style(D, raygui.TEXT_COLOR_NORMAL,     0x2d3436ff)  -- 深灰文字（非纯黑，更柔和）

    -- 聚焦状态（靛蓝主色）
    raygui.set_style(D, raygui.BORDER_COLOR_FOCUSED,  0x4a6cf7ff)  -- 亮蓝高亮边框
    raygui.set_style(D, raygui.BASE_COLOR_FOCUSED,    0xeef1ffff)  -- 淡蓝底色
    raygui.set_style(D, raygui.TEXT_COLOR_FOCUSED,    0x4a6cf7ff)  -- 靛蓝文字

    -- 按下状态
    raygui.set_style(D, raygui.BORDER_COLOR_PRESSED,  0x3b5de7ff)  -- 深蓝边框
    raygui.set_style(D, raygui.BASE_COLOR_PRESSED,    0x4a6cf7ff)  -- 靛蓝实色填充
    raygui.set_style(D, raygui.TEXT_COLOR_PRESSED,    0xffffffff)  -- 白字

    -- 禁用状态
    raygui.set_style(D, raygui.BORDER_COLOR_DISABLED, 0xeef0f4ff)
    raygui.set_style(D, raygui.BASE_COLOR_DISABLED,   0xf5f6faff)
    raygui.set_style(D, raygui.TEXT_COLOR_DISABLED,   0xb0b8c8ff)

    raygui.set_style(D, raygui.BORDER_WIDTH,          0x00000001)  -- 1px 细边框
    raygui.set_style(D, raygui.TEXT_SIZE,             0x00000010)  -- 16px
    raygui.set_style(D, raygui.TEXT_SPACING,          0x00000001)  -- 1px 字间距
    raygui.set_style(D, raygui.TEXT_PADDING,          0x00000008)  -- 8px 内边距
    raygui.set_style(D, raygui.TEXT_LINE_SPACING,     0x0000000a)  -- 10px 行间距
    raygui.set_style(D, raygui.LINE_COLOR,            0x9aa6bdff)  -- Group title/separator color
    raygui.set_style(D, raygui.BACKGROUND_COLOR,      0xf5f6faff)  -- 画布背景（极浅灰蓝）

    -- ========== BUTTON 按钮微调 ==========
    raygui.set_style(B, raygui.BASE_COLOR_NORMAL,     0xf5f6faff)  -- 按钮底色略深于纯白
    raygui.set_style(B, raygui.BORDER_COLOR_FOCUSED,  0x4a6cf7ff)  -- 悬停蓝色边框
    raygui.set_style(B, raygui.BASE_COLOR_FOCUSED,    0xeef1ffff)  -- 悬停淡蓝底色
    raygui.set_style(B, raygui.BASE_COLOR_PRESSED,    0x4a6cf7ff)  -- 按下蓝色实心

    -- ========== SLIDER 滑动条 ==========
    raygui.set_style(S, raygui.BASE_COLOR_NORMAL,     0xeef0f4ff)
    raygui.set_style(S, raygui.BASE_COLOR_FOCUSED,    0xe2e5f0ff)
    raygui.set_style(S, raygui.BASE_COLOR_PRESSED,    0x4a6cf7ff)
    raygui.set_style(S, raygui.TEXT_COLOR_FOCUSED,    0x4a6cf7ff)

    -- ========== PROGRESSBAR 进度条 ==========
    raygui.set_style(P, raygui.BASE_COLOR_NORMAL,     0xeef0f4ff)
    raygui.set_style(P, raygui.BASE_COLOR_FOCUSED,    0x4a6cf7ff)
    raygui.set_style(P, raygui.TEXT_COLOR_FOCUSED,    0x4a6cf7ff)

    -- ========== CHECKBOX ==========
    raygui.set_style(C, raygui.BASE_COLOR_PRESSED,    0x4a6cf7ff)
    raygui.set_style(C, raygui.TEXT_COLOR_PRESSED,    0xffffffff)

    -- ========== TEXTBOX / VALUEBOX ==========
    raygui.set_style(T, raygui.TEXT_COLOR_FOCUSED,    0x2d3436ff)
    raygui.set_style(T, raygui.BASE_COLOR_FOCUSED,    0xffffffff)
    raygui.set_style(V, raygui.TEXT_COLOR_FOCUSED,    0x2d3436ff)
    raygui.set_style(V, raygui.BASE_COLOR_FOCUSED,    0xffffffff)
end

return M
