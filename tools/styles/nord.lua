-- raygui Nord 风格（北极蓝灰 — 冷静、高级、护眼）
-- 灵感来自 Arctic Nord 色彩体系
-- 用法: require("styles.nord").apply(raygui)

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
    -- 极夜背景色
    raygui.set_style(D, raygui.BORDER_COLOR_NORMAL,   0x4c566aff)  -- 深灰蓝边框
    raygui.set_style(D, raygui.BASE_COLOR_NORMAL,     0x3b4252ff)  -- 控件底色
    raygui.set_style(D, raygui.TEXT_COLOR_NORMAL,     0xd8dee9ff)  -- 雪花白文字
    -- 聚焦状态（Frost 霜蓝）
    raygui.set_style(D, raygui.BORDER_COLOR_FOCUSED,  0x81a1c1ff)  -- 高亮蓝边框
    raygui.set_style(D, raygui.BASE_COLOR_FOCUSED,    0x434c5eff)  -- 略亮的底色
    raygui.set_style(D, raygui.TEXT_COLOR_FOCUSED,    0xeceff4ff)  -- 更亮的文字
    -- 按下状态（极光蓝绿）
    raygui.set_style(D, raygui.BORDER_COLOR_PRESSED,  0x88c0d0ff)  -- 霜青边框
    raygui.set_style(D, raygui.BASE_COLOR_PRESSED,    0x88c0d0ff)  -- 霜青底色
    raygui.set_style(D, raygui.TEXT_COLOR_PRESSED,    0x2e3440ff)  -- 深色文字
    -- 禁用状态
    raygui.set_style(D, raygui.BORDER_COLOR_DISABLED, 0x3b4252ff)
    raygui.set_style(D, raygui.BASE_COLOR_DISABLED,   0x2e3440ff)
    raygui.set_style(D, raygui.TEXT_COLOR_DISABLED,   0x616e88ff)

    raygui.set_style(D, raygui.BORDER_WIDTH,          0x00000001)  -- 1px 细边框
    raygui.set_style(D, raygui.TEXT_SIZE,             0x00000010)  -- 16px
    raygui.set_style(D, raygui.TEXT_SPACING,          0x00000001)  -- 1px 字间距
    raygui.set_style(D, raygui.TEXT_PADDING,          0x00000008)  -- 8px 内边距
    raygui.set_style(D, raygui.TEXT_LINE_SPACING,     0x0000000a)  -- 10px 行间距
    raygui.set_style(D, raygui.LINE_COLOR,            0x6d7a96ff)  -- Group title/separator color
    raygui.set_style(D, raygui.BACKGROUND_COLOR,      0x2e3440ff)  -- 画布背景（极夜）

    -- ========== BUTTON 按钮微调 ==========
    raygui.set_style(B, raygui.BASE_COLOR_NORMAL,     0x434c5eff)  -- 按钮底色略亮
    raygui.set_style(B, raygui.BORDER_COLOR_FOCUSED,  0x8fbcbbff)  -- 悬停边框（浅霜青）
    raygui.set_style(B, raygui.BASE_COLOR_FOCUSED,    0x4c566aff)  -- 悬停底色
    raygui.set_style(B, raygui.BASE_COLOR_PRESSED,    0x81a1c1ff)  -- 按下变蓝

    -- ========== SLIDER 滑动条 ==========
    raygui.set_style(S, raygui.BASE_COLOR_NORMAL,     0x434c5eff)
    raygui.set_style(S, raygui.BASE_COLOR_FOCUSED,    0x4c566aff)
    raygui.set_style(S, raygui.BASE_COLOR_PRESSED,    0x88c0d0ff)
    raygui.set_style(S, raygui.TEXT_COLOR_FOCUSED,    0x88c0d0ff)

    -- ========== PROGRESSBAR 进度条 ==========
    raygui.set_style(P, raygui.BASE_COLOR_NORMAL,     0x434c5eff)
    raygui.set_style(P, raygui.BASE_COLOR_FOCUSED,    0x4c566aff)
    raygui.set_style(P, raygui.TEXT_COLOR_FOCUSED,    0x81a1c1ff)

    -- ========== CHECKBOX ==========
    raygui.set_style(C, raygui.BASE_COLOR_PRESSED,    0x88c0d0ff)
    raygui.set_style(C, raygui.TEXT_COLOR_PRESSED,    0x2e3440ff)

    -- ========== TEXTBOX / VALUEBOX ==========
    raygui.set_style(T, raygui.TEXT_COLOR_FOCUSED,    0xeceff4ff)
    raygui.set_style(T, raygui.BASE_COLOR_FOCUSED,    0x3b4252ff)
    raygui.set_style(V, raygui.TEXT_COLOR_FOCUSED,    0xeceff4ff)
    raygui.set_style(V, raygui.BASE_COLOR_FOCUSED,    0x3b4252ff)
end

return M
