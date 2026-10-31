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
    raygui.set_style(D, raygui.BORDER_COLOR_NORMAL,   0xe8e6e6ff)  -- 浅灰框线
    raygui.set_style(D, raygui.BASE_COLOR_NORMAL,     0xffffffff)  -- 纯白填充
    raygui.set_style(D, raygui.TEXT_COLOR_NORMAL,     0x28282bff)  -- 深灰文字（非纯黑，更柔和）

    -- 聚焦状态（蓝色主色）
    raygui.set_style(D, raygui.BORDER_COLOR_FOCUSED,  0x3b82f6ff)  -- 亮蓝高亮边框
    raygui.set_style(D, raygui.BASE_COLOR_FOCUSED,    0xf2f4f7ff)  -- 浅灰底色
    raygui.set_style(D, raygui.TEXT_COLOR_FOCUSED,    0x3b82f6ff)  -- 蓝色文字

    -- 按下状态
    raygui.set_style(D, raygui.BORDER_COLOR_PRESSED,  0x2563ebff)  -- 深蓝边框
    raygui.set_style(D, raygui.BASE_COLOR_PRESSED,    0x3b82f6ff)  -- 蓝色实色填充
    raygui.set_style(D, raygui.TEXT_COLOR_PRESSED,    0xffffffff)  -- 白字

    -- 禁用状态
    raygui.set_style(D, raygui.BORDER_COLOR_DISABLED, 0xf1efefff)
    raygui.set_style(D, raygui.BASE_COLOR_DISABLED,   0xffffffff)
    raygui.set_style(D, raygui.TEXT_COLOR_DISABLED,   0xaaa7a7ff)

    raygui.set_style(D, raygui.BORDER_WIDTH,          0x00000001)  -- 1px 细边框
    raygui.set_style(D, raygui.TEXT_SIZE,             0x00000010)  -- 16px
    raygui.set_style(D, raygui.TEXT_SPACING,          0x00000001)  -- 1px 字间距
    raygui.set_style(D, raygui.TEXT_PADDING,          0x00000008)  -- 8px 内边距
    raygui.set_style(D, raygui.TEXT_LINE_SPACING,     0x0000000a)  -- 10px 行间距
    raygui.set_style(D, raygui.LINE_COLOR,            0xd5d1d1ff)  -- Group title/separator color
    raygui.set_style(D, raygui.BACKGROUND_COLOR,      0xffffffff)  -- 画布背景（白色）

    -- ========== BUTTON 按钮微调 ==========
    raygui.set_style(B, raygui.BASE_COLOR_NORMAL,     0xffffffff)  -- 按钮使用白色底
    raygui.set_style(B, raygui.BORDER_COLOR_FOCUSED,  0x3b82f6ff)  -- 悬停蓝色边框
    raygui.set_style(B, raygui.BASE_COLOR_FOCUSED,    0xf2f4f7ff)  -- 悬停浅灰底色
    raygui.set_style(B, raygui.BASE_COLOR_PRESSED,    0x3b82f6ff)  -- 按下蓝色实心

    -- ========== SLIDER 滑动条 ==========
    raygui.set_style(S, raygui.BASE_COLOR_NORMAL,     0xf1efefff)
    raygui.set_style(S, raygui.BASE_COLOR_FOCUSED,    0xe8e6e6ff)
    raygui.set_style(S, raygui.BASE_COLOR_PRESSED,    0x3b82f6ff)
    raygui.set_style(S, raygui.TEXT_COLOR_FOCUSED,    0x3b82f6ff)

    -- ========== PROGRESSBAR 进度条 ==========
    raygui.set_style(P, raygui.BASE_COLOR_NORMAL,     0xf1efefff)
    raygui.set_style(P, raygui.BASE_COLOR_FOCUSED,    0x3b82f6ff)
    raygui.set_style(P, raygui.TEXT_COLOR_FOCUSED,    0x3b82f6ff)

    -- ========== CHECKBOX ==========
    raygui.set_style(C, raygui.BASE_COLOR_PRESSED,    0x3b82f6ff)
    raygui.set_style(C, raygui.TEXT_COLOR_PRESSED,    0xffffffff)

    -- ========== TEXTBOX / VALUEBOX ==========
    raygui.set_style(T, raygui.TEXT_COLOR_FOCUSED,    0x28282bff)
    raygui.set_style(T, raygui.BASE_COLOR_FOCUSED,    0xffffffff)
    raygui.set_style(V, raygui.TEXT_COLOR_FOCUSED,    0x28282bff)
    raygui.set_style(V, raygui.BASE_COLOR_FOCUSED,    0xffffffff)
end

return M
