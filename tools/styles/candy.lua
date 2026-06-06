-- raygui Candy 风格（Macaron — 清新马卡龙浅色，糖果粉点缀）
-- 纯白控件 + 柔和粉色强调，干净、甜而不腻
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
    raygui.set_style(D, raygui.BORDER_COLOR_NORMAL,   0xf3d9dfff)  -- 淡粉边框
    raygui.set_style(D, raygui.BASE_COLOR_NORMAL,     0xffffffff)  -- 纯白填充
    raygui.set_style(D, raygui.TEXT_COLOR_NORMAL,     0x7a5a62ff)  -- 暖灰褐文字（不刺眼）

    raygui.set_style(D, raygui.BORDER_COLOR_FOCUSED,  0xff7eb6ff)  -- 糖果粉边框
    raygui.set_style(D, raygui.BASE_COLOR_FOCUSED,    0xfff0f5ff)  -- 极淡粉底
    raygui.set_style(D, raygui.TEXT_COLOR_FOCUSED,    0xe85d97ff)  -- 玫红文字

    raygui.set_style(D, raygui.BORDER_COLOR_PRESSED,  0xff5ba3ff)  -- 按下深粉边
    raygui.set_style(D, raygui.BASE_COLOR_PRESSED,    0xff7eb6ff)  -- 按下粉色实心
    raygui.set_style(D, raygui.TEXT_COLOR_PRESSED,    0xffffffff)  -- 白字

    raygui.set_style(D, raygui.BORDER_COLOR_DISABLED, 0xf3e7eaff)
    raygui.set_style(D, raygui.BASE_COLOR_DISABLED,   0xfbf3f5ff)
    raygui.set_style(D, raygui.TEXT_COLOR_DISABLED,   0xd9c2c8ff)

    raygui.set_style(D, raygui.BORDER_WIDTH,          1)
    raygui.set_style(D, raygui.TEXT_SIZE,             16)
    raygui.set_style(D, raygui.TEXT_SPACING,          1)
    raygui.set_style(D, raygui.TEXT_PADDING,          8)
    raygui.set_style(D, raygui.TEXT_LINE_SPACING,     10)
    raygui.set_style(D, raygui.LINE_COLOR,            0xf3d9dfff)
    raygui.set_style(D, raygui.BACKGROUND_COLOR,      0xfff7f9ff)  -- 面板背景（奶粉白）

    -- ========== BUTTON ==========
    raygui.set_style(B, raygui.BASE_COLOR_NORMAL,     0xfff4f7ff)
    raygui.set_style(B, raygui.BORDER_COLOR_FOCUSED,  0xff7eb6ff)
    raygui.set_style(B, raygui.BASE_COLOR_FOCUSED,    0xfff0f5ff)
    raygui.set_style(B, raygui.BASE_COLOR_PRESSED,    0xff7eb6ff)

    -- ========== SLIDER ==========
    raygui.set_style(S, raygui.BASE_COLOR_NORMAL,     0xfbe6ecff)
    raygui.set_style(S, raygui.BASE_COLOR_FOCUSED,    0xf6dbe3ff)
    raygui.set_style(S, raygui.BASE_COLOR_PRESSED,    0xff7eb6ff)
    raygui.set_style(S, raygui.TEXT_COLOR_FOCUSED,    0xe85d97ff)

    -- ========== PROGRESSBAR ==========
    raygui.set_style(P, raygui.BASE_COLOR_NORMAL,     0xfbe6ecff)
    raygui.set_style(P, raygui.BASE_COLOR_FOCUSED,    0xff7eb6ff)
    raygui.set_style(P, raygui.TEXT_COLOR_FOCUSED,    0xe85d97ff)

    -- ========== CHECKBOX ==========
    raygui.set_style(C, raygui.BASE_COLOR_PRESSED,    0xff7eb6ff)
    raygui.set_style(C, raygui.TEXT_COLOR_PRESSED,    0xffffffff)

    -- ========== TEXTBOX / VALUEBOX ==========
    raygui.set_style(T, raygui.TEXT_COLOR_FOCUSED,    0x7a5a62ff)
    raygui.set_style(T, raygui.BASE_COLOR_FOCUSED,    0xffffffff)
    raygui.set_style(V, raygui.TEXT_COLOR_FOCUSED,    0x7a5a62ff)
    raygui.set_style(V, raygui.BASE_COLOR_FOCUSED,    0xffffffff)
end

return M
