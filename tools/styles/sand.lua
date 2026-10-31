-- raygui Sand — 暖沙土底、陶褐色强调与深暖灰正文。
-- 用法: require("styles.sand").apply(raygui)

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
    -- 沙土色背景与暖白控件
    raygui.set_style(D, raygui.BORDER_COLOR_NORMAL,   0xd7c7acff)
    raygui.set_style(D, raygui.BASE_COLOR_NORMAL,     0xfaf3e7ff)
    raygui.set_style(D, raygui.TEXT_COLOR_NORMAL,     0x4f4438ff)
    -- 聚焦状态（陶褐色）
    raygui.set_style(D, raygui.BORDER_COLOR_FOCUSED,  0x8a633dff)
    raygui.set_style(D, raygui.BASE_COLOR_FOCUSED,    0xe9d8bbff)
    raygui.set_style(D, raygui.TEXT_COLOR_FOCUSED,    0x5a412cff)
    -- 按下状态
    raygui.set_style(D, raygui.BORDER_COLOR_PRESSED,  0x8a633dff)
    raygui.set_style(D, raygui.BASE_COLOR_PRESSED,    0x8a633dff)
    raygui.set_style(D, raygui.TEXT_COLOR_PRESSED,    0xfff9f0ff)
    -- 禁用状态
    raygui.set_style(D, raygui.BORDER_COLOR_DISABLED, 0xfaf3e7ff)
    raygui.set_style(D, raygui.BASE_COLOR_DISABLED,   0xf2e8d5ff)
    raygui.set_style(D, raygui.TEXT_COLOR_DISABLED,   0xa89880ff)

    raygui.set_style(D, raygui.BORDER_WIDTH,          0x00000001)
    raygui.set_style(D, raygui.TEXT_SIZE,             0x00000010)
    raygui.set_style(D, raygui.TEXT_SPACING,          0x00000001)
    raygui.set_style(D, raygui.TEXT_PADDING,          0x00000008)
    raygui.set_style(D, raygui.TEXT_LINE_SPACING,     0x0000000a)
    raygui.set_style(D, raygui.LINE_COLOR,            0xd1bc9aff)
    raygui.set_style(D, raygui.BACKGROUND_COLOR,      0xf2e8d5ff)

    -- ========== BUTTON 按钮微调 ==========
    raygui.set_style(B, raygui.BASE_COLOR_NORMAL,     0xe9d8bbff)
    raygui.set_style(B, raygui.BORDER_COLOR_FOCUSED,  0x795332ff)
    raygui.set_style(B, raygui.BASE_COLOR_FOCUSED,    0xd7c7acff)
    raygui.set_style(B, raygui.BASE_COLOR_PRESSED,    0x8a633dff)

    -- ========== SLIDER 滑动条 ==========
    raygui.set_style(S, raygui.BASE_COLOR_NORMAL,     0xe9d8bbff)
    raygui.set_style(S, raygui.BASE_COLOR_FOCUSED,    0xd7c7acff)
    raygui.set_style(S, raygui.BASE_COLOR_PRESSED,    0x8a633dff)
    raygui.set_style(S, raygui.TEXT_COLOR_FOCUSED,    0x8a633dff)
    raygui.set_style(P, raygui.BASE_COLOR_NORMAL,     0xe9d8bbff)
    raygui.set_style(P, raygui.BASE_COLOR_FOCUSED,    0xd7c7acff)
    raygui.set_style(P, raygui.TEXT_COLOR_FOCUSED,    0x8a633dff)
    raygui.set_style(C, raygui.BASE_COLOR_PRESSED,    0x8a633dff)
    raygui.set_style(C, raygui.TEXT_COLOR_PRESSED,    0xfff9f0ff)
    raygui.set_style(T, raygui.TEXT_COLOR_FOCUSED,    0x5a412cff)
    raygui.set_style(T, raygui.BASE_COLOR_FOCUSED,    0xfaf3e7ff)
    raygui.set_style(V, raygui.TEXT_COLOR_FOCUSED,    0x5a412cff)
    raygui.set_style(V, raygui.BASE_COLOR_FOCUSED,    0xfaf3e7ff)
end

return M
