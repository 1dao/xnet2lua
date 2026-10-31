-- raygui Candy — 奶白与低饱和玫瑰色，正文使用深暖灰。
-- 用法: require("styles.candy").apply(raygui)

local M = {}

function M.apply(raygui)
    local D = raygui.DEFAULT
    local B = raygui.BUTTON
    local S = raygui.SLIDER
    local P = raygui.PROGRESSBAR
    local C = raygui.CHECKBOX
    local T = raygui.TEXTBOX
    local V = raygui.VALUEBOX

    -- ========== DEFAULT 全局 ==========
    raygui.set_style(D, raygui.BORDER_COLOR_NORMAL,   0xe9dce0ff)
    raygui.set_style(D, raygui.BASE_COLOR_NORMAL,     0xfffefdff)
    raygui.set_style(D, raygui.TEXT_COLOR_NORMAL,     0x473e45ff)

    raygui.set_style(D, raygui.BORDER_COLOR_FOCUSED,  0xae587dff)
    raygui.set_style(D, raygui.BASE_COLOR_FOCUSED,    0xfaedf2ff)
    raygui.set_style(D, raygui.TEXT_COLOR_FOCUSED,    0xa94d73ff)

    raygui.set_style(D, raygui.BORDER_COLOR_PRESSED,  0xae5078ff)
    raygui.set_style(D, raygui.BASE_COLOR_PRESSED,    0xae587dff)
    raygui.set_style(D, raygui.TEXT_COLOR_PRESSED,    0xffffffff)

    raygui.set_style(D, raygui.BORDER_COLOR_DISABLED, 0xece3e5ff)
    raygui.set_style(D, raygui.BASE_COLOR_DISABLED,   0xfaf4f3ff)
    raygui.set_style(D, raygui.TEXT_COLOR_DISABLED,   0xa8979eff)

    raygui.set_style(D, raygui.BORDER_WIDTH,          1)
    raygui.set_style(D, raygui.TEXT_SIZE,             16)
    raygui.set_style(D, raygui.TEXT_SPACING,          1)
    raygui.set_style(D, raygui.TEXT_PADDING,          8)
    raygui.set_style(D, raygui.TEXT_LINE_SPACING,     10)
    raygui.set_style(D, raygui.LINE_COLOR,            0xddc9d0ff)
    raygui.set_style(D, raygui.BACKGROUND_COLOR,      0xfff9f7ff)

    -- ========== BUTTON ==========
    raygui.set_style(B, raygui.BASE_COLOR_NORMAL,     0xfcf2f4ff)
    raygui.set_style(B, raygui.BORDER_COLOR_FOCUSED,  0xae587dff)
    raygui.set_style(B, raygui.BASE_COLOR_FOCUSED,    0xfaedf2ff)
    raygui.set_style(B, raygui.BASE_COLOR_PRESSED,    0xae587dff)
    raygui.set_style(S, raygui.BASE_COLOR_NORMAL,     0xf5e6ebff)
    raygui.set_style(S, raygui.BASE_COLOR_FOCUSED,    0xefd8e1ff)
    raygui.set_style(S, raygui.BASE_COLOR_PRESSED,    0xae587dff)
    raygui.set_style(S, raygui.TEXT_COLOR_FOCUSED,    0xa94d73ff)
    raygui.set_style(P, raygui.BASE_COLOR_NORMAL,     0xf5e6ebff)
    raygui.set_style(P, raygui.BASE_COLOR_FOCUSED,    0xae587dff)
    raygui.set_style(P, raygui.TEXT_COLOR_FOCUSED,    0xa94d73ff)
    raygui.set_style(C, raygui.BASE_COLOR_PRESSED,    0xae587dff)
    raygui.set_style(C, raygui.TEXT_COLOR_PRESSED,    0xffffffff)
    raygui.set_style(T, raygui.TEXT_COLOR_FOCUSED,    0x473e45ff)
    raygui.set_style(T, raygui.BASE_COLOR_FOCUSED,    0xfffefdff)
    raygui.set_style(V, raygui.TEXT_COLOR_FOCUSED,    0x473e45ff)
    raygui.set_style(V, raygui.BASE_COLOR_FOCUSED,    0xfffefdff)
end

return M
