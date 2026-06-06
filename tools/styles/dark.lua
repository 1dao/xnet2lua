-- raygui Dark 风格（Graphite — 现代石墨深色，冷静蓝色点缀）
-- 中性深灰底 + 克制的蓝色强调，干净、护眼、专业
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
    raygui.set_style(D, raygui.BORDER_COLOR_NORMAL,   0x2e333dff)  -- 低对比边框
    raygui.set_style(D, raygui.BASE_COLOR_NORMAL,     0x21252dff)  -- 控件底色
    raygui.set_style(D, raygui.TEXT_COLOR_NORMAL,     0xb9c0ccff)  -- 柔和灰白文字

    raygui.set_style(D, raygui.BORDER_COLOR_FOCUSED,  0x5b8defff)  -- 蓝色高亮边框
    raygui.set_style(D, raygui.BASE_COLOR_FOCUSED,    0x2b313bff)  -- 悬停略亮
    raygui.set_style(D, raygui.TEXT_COLOR_FOCUSED,    0xeaf0f7ff)  -- 高亮文字

    raygui.set_style(D, raygui.BORDER_COLOR_PRESSED,  0x5b8defff)  -- 按下蓝边
    raygui.set_style(D, raygui.BASE_COLOR_PRESSED,    0x5b8defff)  -- 按下蓝色实心
    raygui.set_style(D, raygui.TEXT_COLOR_PRESSED,    0x0e1116ff)  -- 深色文字

    raygui.set_style(D, raygui.BORDER_COLOR_DISABLED, 0x262b33ff)
    raygui.set_style(D, raygui.BASE_COLOR_DISABLED,   0x1c2026ff)
    raygui.set_style(D, raygui.TEXT_COLOR_DISABLED,   0x4d5662ff)

    raygui.set_style(D, raygui.BORDER_WIDTH,          1)
    raygui.set_style(D, raygui.TEXT_SIZE,             16)
    raygui.set_style(D, raygui.TEXT_SPACING,          1)
    raygui.set_style(D, raygui.TEXT_PADDING,          8)
    raygui.set_style(D, raygui.TEXT_LINE_SPACING,     10)
    raygui.set_style(D, raygui.LINE_COLOR,            0x2e333dff)  -- 分割线/边
    raygui.set_style(D, raygui.BACKGROUND_COLOR,      0x16191fff)  -- 面板背景（近黑）

    -- ========== BUTTON ==========
    raygui.set_style(B, raygui.BASE_COLOR_NORMAL,     0x272c35ff)
    raygui.set_style(B, raygui.BORDER_COLOR_FOCUSED,  0x5b8defff)
    raygui.set_style(B, raygui.BASE_COLOR_FOCUSED,    0x2f3742ff)
    raygui.set_style(B, raygui.BASE_COLOR_PRESSED,    0x5b8defff)

    -- ========== SLIDER ==========
    raygui.set_style(S, raygui.BASE_COLOR_NORMAL,     0x2b313bff)
    raygui.set_style(S, raygui.BASE_COLOR_FOCUSED,    0x343b46ff)
    raygui.set_style(S, raygui.BASE_COLOR_PRESSED,    0x5b8defff)
    raygui.set_style(S, raygui.TEXT_COLOR_FOCUSED,    0x5b8defff)

    -- ========== PROGRESSBAR ==========
    raygui.set_style(P, raygui.BASE_COLOR_NORMAL,     0x2b313bff)
    raygui.set_style(P, raygui.BASE_COLOR_FOCUSED,    0x5b8defff)
    raygui.set_style(P, raygui.TEXT_COLOR_FOCUSED,    0x5b8defff)

    -- ========== CHECKBOX ==========
    raygui.set_style(C, raygui.BASE_COLOR_PRESSED,    0x5b8defff)
    raygui.set_style(C, raygui.TEXT_COLOR_PRESSED,    0x0e1116ff)

    -- ========== TEXTBOX / VALUEBOX ==========
    raygui.set_style(T, raygui.TEXT_COLOR_FOCUSED,    0xeaf0f7ff)
    raygui.set_style(T, raygui.BASE_COLOR_FOCUSED,    0x21252dff)
    raygui.set_style(V, raygui.TEXT_COLOR_FOCUSED,    0xeaf0f7ff)
    raygui.set_style(V, raygui.BASE_COLOR_FOCUSED,    0x21252dff)
end

return M
