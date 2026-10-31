-- raygui Cyber — 深海蓝底、青色强调，淡紫仅用于按下状态。
-- 用法: require("styles.cyber").apply(raygui)

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
    raygui.set_style(D, raygui.BORDER_COLOR_NORMAL,   0x30465cff)
    raygui.set_style(D, raygui.BASE_COLOR_NORMAL,     0x172338ff)
    raygui.set_style(D, raygui.TEXT_COLOR_NORMAL,     0xdce6f4ff)

    raygui.set_style(D, raygui.BORDER_COLOR_FOCUSED,  0x59d8ceff)
    raygui.set_style(D, raygui.BASE_COLOR_FOCUSED,    0x203249ff)
    raygui.set_style(D, raygui.TEXT_COLOR_FOCUSED,    0xedf7ffff)

    raygui.set_style(D, raygui.BORDER_COLOR_PRESSED,  0xb7a7eeff)
    raygui.set_style(D, raygui.BASE_COLOR_PRESSED,    0xb7a7eeff)
    raygui.set_style(D, raygui.TEXT_COLOR_PRESSED,    0x101827ff)

    raygui.set_style(D, raygui.BORDER_COLOR_DISABLED, 0x223146ff)
    raygui.set_style(D, raygui.BASE_COLOR_DISABLED,   0x141e2dff)
    raygui.set_style(D, raygui.TEXT_COLOR_DISABLED,   0x71879cff)

    raygui.set_style(D, raygui.BORDER_WIDTH,          1)
    raygui.set_style(D, raygui.TEXT_SIZE,             16)
    raygui.set_style(D, raygui.TEXT_SPACING,          1)
    raygui.set_style(D, raygui.TEXT_PADDING,          8)
    raygui.set_style(D, raygui.TEXT_LINE_SPACING,     10)
    raygui.set_style(D, raygui.LINE_COLOR,            0x37556cff)
    raygui.set_style(D, raygui.BACKGROUND_COLOR,      0x101827ff)

    -- ========== BUTTON ==========
    raygui.set_style(B, raygui.BASE_COLOR_NORMAL,     0x1b2a40ff)
    raygui.set_style(B, raygui.BORDER_COLOR_FOCUSED,  0x59d8ceff)
    raygui.set_style(B, raygui.BASE_COLOR_FOCUSED,    0x29435aff)
    raygui.set_style(B, raygui.BASE_COLOR_PRESSED,    0xb7a7eeff)
    raygui.set_style(S, raygui.BASE_COLOR_NORMAL,     0x203249ff)
    raygui.set_style(S, raygui.BASE_COLOR_FOCUSED,    0x29435aff)
    raygui.set_style(S, raygui.BASE_COLOR_PRESSED,    0x59d8ceff)
    raygui.set_style(S, raygui.TEXT_COLOR_FOCUSED,    0x59d8ceff)
    raygui.set_style(P, raygui.BASE_COLOR_NORMAL,     0x203249ff)
    raygui.set_style(P, raygui.BASE_COLOR_FOCUSED,    0x59d8ceff)
    raygui.set_style(P, raygui.TEXT_COLOR_FOCUSED,    0x59d8ceff)
    raygui.set_style(C, raygui.BASE_COLOR_PRESSED,    0x59d8ceff)
    raygui.set_style(C, raygui.TEXT_COLOR_PRESSED,    0x101827ff)
    raygui.set_style(T, raygui.TEXT_COLOR_FOCUSED,    0xedf7ffff)
    raygui.set_style(T, raygui.BASE_COLOR_FOCUSED,    0x172338ff)
    raygui.set_style(V, raygui.TEXT_COLOR_FOCUSED,    0xedf7ffff)
    raygui.set_style(V, raygui.BASE_COLOR_FOCUSED,    0x172338ff)
end

return M
