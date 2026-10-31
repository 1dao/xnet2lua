-- raygui Dark — 中性石墨与淡蓝紫，保持正文清晰、强调克制。
-- 用法: require("styles.dark").apply(raygui)

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
    raygui.set_style(D, raygui.BORDER_COLOR_NORMAL,   0x3b3d46ff)
    raygui.set_style(D, raygui.BASE_COLOR_NORMAL,     0x26272dff)
    raygui.set_style(D, raygui.TEXT_COLOR_NORMAL,     0xe7e5e4ff)

    raygui.set_style(D, raygui.BORDER_COLOR_FOCUSED,  0xa7b4ffff)
    raygui.set_style(D, raygui.BASE_COLOR_FOCUSED,    0x32343eff)
    raygui.set_style(D, raygui.TEXT_COLOR_FOCUSED,    0xfaf9f7ff)

    raygui.set_style(D, raygui.BORDER_COLOR_PRESSED,  0xa7b4ffff)
    raygui.set_style(D, raygui.BASE_COLOR_PRESSED,    0xa7b4ffff)
    raygui.set_style(D, raygui.TEXT_COLOR_PRESSED,    0x181b27ff)

    raygui.set_style(D, raygui.BORDER_COLOR_DISABLED, 0x303139ff)
    raygui.set_style(D, raygui.BASE_COLOR_DISABLED,   0x202126ff)
    raygui.set_style(D, raygui.TEXT_COLOR_DISABLED,   0x777984ff)

    raygui.set_style(D, raygui.BORDER_WIDTH,          1)
    raygui.set_style(D, raygui.TEXT_SIZE,             16)
    raygui.set_style(D, raygui.TEXT_SPACING,          1)
    raygui.set_style(D, raygui.TEXT_PADDING,          8)
    raygui.set_style(D, raygui.TEXT_LINE_SPACING,     10)
    raygui.set_style(D, raygui.LINE_COLOR,            0x464852ff)
    raygui.set_style(D, raygui.BACKGROUND_COLOR,      0x1b1c20ff)

    -- ========== BUTTON ==========
    raygui.set_style(B, raygui.BASE_COLOR_NORMAL,     0x2c2d35ff)
    raygui.set_style(B, raygui.BORDER_COLOR_FOCUSED,  0xa7b4ffff)
    raygui.set_style(B, raygui.BASE_COLOR_FOCUSED,    0x363945ff)
    raygui.set_style(B, raygui.BASE_COLOR_PRESSED,    0xa7b4ffff)
    raygui.set_style(S, raygui.BASE_COLOR_NORMAL,     0x32343eff)
    raygui.set_style(S, raygui.BASE_COLOR_FOCUSED,    0x3d404dff)
    raygui.set_style(S, raygui.BASE_COLOR_PRESSED,    0xa7b4ffff)
    raygui.set_style(S, raygui.TEXT_COLOR_FOCUSED,    0xa7b4ffff)
    raygui.set_style(P, raygui.BASE_COLOR_NORMAL,     0x32343eff)
    raygui.set_style(P, raygui.BASE_COLOR_FOCUSED,    0xa7b4ffff)
    raygui.set_style(P, raygui.TEXT_COLOR_FOCUSED,    0xa7b4ffff)
    raygui.set_style(C, raygui.BASE_COLOR_PRESSED,    0xa7b4ffff)
    raygui.set_style(C, raygui.TEXT_COLOR_PRESSED,    0x181b27ff)
    raygui.set_style(T, raygui.TEXT_COLOR_FOCUSED,    0xfaf9f7ff)
    raygui.set_style(T, raygui.BASE_COLOR_FOCUSED,    0x26272dff)
    raygui.set_style(V, raygui.TEXT_COLOR_FOCUSED,    0xfaf9f7ff)
    raygui.set_style(V, raygui.BASE_COLOR_FOCUSED,    0x26272dff)
end

return M
