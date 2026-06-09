-- raygui Cyber 风格（Neon — 赛博霓虹，近黑底 + 青色强调 + 洋红按压）
-- 克制版赛博朋克：暗场里只点两种霓虹，干净不脏
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
    raygui.set_style(D, raygui.BORDER_COLOR_NORMAL,   0x1f3a4dff)  -- 暗青边框
    raygui.set_style(D, raygui.BASE_COLOR_NORMAL,     0x0f1922ff)  -- 深海底色
    raygui.set_style(D, raygui.TEXT_COLOR_NORMAL,     0x6fd3e8ff)  -- 青色文字

    raygui.set_style(D, raygui.BORDER_COLOR_FOCUSED,  0x22d3eeff)  -- 霓虹青边框
    raygui.set_style(D, raygui.BASE_COLOR_FOCUSED,    0x12262fff)  -- 悬停略亮
    raygui.set_style(D, raygui.TEXT_COLOR_FOCUSED,    0xb6f3ffff)  -- 亮青文字

    raygui.set_style(D, raygui.BORDER_COLOR_PRESSED,  0xff3df0ff)  -- 洋红按压（点睛）
    raygui.set_style(D, raygui.BASE_COLOR_PRESSED,    0xff3df0ff)  -- 洋红实心
    raygui.set_style(D, raygui.TEXT_COLOR_PRESSED,    0x06080dff)  -- 近黑文字

    raygui.set_style(D, raygui.BORDER_COLOR_DISABLED, 0x16242dff)
    raygui.set_style(D, raygui.BASE_COLOR_DISABLED,   0x0b141aff)
    raygui.set_style(D, raygui.TEXT_COLOR_DISABLED,   0x335462ff)

    raygui.set_style(D, raygui.BORDER_WIDTH,          1)
    raygui.set_style(D, raygui.TEXT_SIZE,             16)
    raygui.set_style(D, raygui.TEXT_SPACING,          1)
    raygui.set_style(D, raygui.TEXT_PADDING,          8)
    raygui.set_style(D, raygui.TEXT_LINE_SPACING,     10)
    raygui.set_style(D, raygui.LINE_COLOR,            0x1f3a4dff)
    raygui.set_style(D, raygui.BACKGROUND_COLOR,      0x080d14ff)  -- 面板背景（近黑蓝）

    -- ========== BUTTON ==========
    raygui.set_style(B, raygui.BASE_COLOR_NORMAL,     0x10202bff)
    raygui.set_style(B, raygui.BORDER_COLOR_FOCUSED,  0x22d3eeff)
    raygui.set_style(B, raygui.BASE_COLOR_FOCUSED,    0x143540ff)
    raygui.set_style(B, raygui.BASE_COLOR_PRESSED,    0xff3df0ff)

    -- ========== SLIDER ==========
    raygui.set_style(S, raygui.BASE_COLOR_NORMAL,     0x12262fff)
    raygui.set_style(S, raygui.BASE_COLOR_FOCUSED,    0x163742ff)
    raygui.set_style(S, raygui.BASE_COLOR_PRESSED,    0x22d3eeff)
    raygui.set_style(S, raygui.TEXT_COLOR_FOCUSED,    0x22d3eeff)

    -- ========== PROGRESSBAR ==========
    raygui.set_style(P, raygui.BASE_COLOR_NORMAL,     0x12262fff)
    raygui.set_style(P, raygui.BASE_COLOR_FOCUSED,    0x22d3eeff)
    raygui.set_style(P, raygui.TEXT_COLOR_FOCUSED,    0x22d3eeff)

    -- ========== CHECKBOX ==========
    raygui.set_style(C, raygui.BASE_COLOR_PRESSED,    0x22d3eeff)
    raygui.set_style(C, raygui.TEXT_COLOR_PRESSED,    0x06080dff)

    -- ========== TEXTBOX / VALUEBOX ==========
    raygui.set_style(T, raygui.TEXT_COLOR_FOCUSED,    0xb6f3ffff)
    raygui.set_style(T, raygui.BASE_COLOR_FOCUSED,    0x0f1922ff)
    raygui.set_style(V, raygui.TEXT_COLOR_FOCUSED,    0xb6f3ffff)
    raygui.set_style(V, raygui.BASE_COLOR_FOCUSED,    0x0f1922ff)
end

return M
