-- xagent/ui/emoji.lua — map Unicode emoji codepoints to tools/emoji_atlas.png
-- cells so the transcript can draw color emoji from the atlas (the NotoSansSC
-- font has no color-emoji glyphs). The atlas is a 12-col grid of 72px cells,
-- indexed by the names from demo/xraygui_main.lua's EMOJI table.

local M = {}

M.CELL = 72
M.COLS = 12

-- Codepoints to skip entirely (variation selectors, ZWJ, skin tones).
local function skip(cp)
    return cp == 0xFE0F or cp == 0xFE0E or cp == 0x200D
        or (cp >= 0x1F3FB and cp <= 0x1F3FF)
end

-- Unicode emoji codepoint -> atlas index (a curated common subset).
M.MAP = {
    [0x1F4BE]=0,  [0x1F4BD]=0,                          -- 💾 save
    [0x1F4C2]=2,  [0x1F4C1]=2,  [0x1F5C2]=2,            -- 📁 folder
    [0x1F4C4]=3,  [0x1F4C3]=3,                          -- 📄 file
    [0x270F]=5,   [0x1F4DD]=97,                         -- ✏ edit / 📝 memo
    [0x1F50D]=11, [0x1F50E]=11,                         -- 🔍 search
    [0x2699]=12,  [0x1F527]=13,                         -- ⚙ settings / 🔧 tools
    [0x1F504]=14, [0x1F501]=14,                         -- 🔄 refresh
    [0x2705]=18,  [0x2714]=18,                          -- ✅✔ check
    [0x274C]=19,  [0x2716]=19,  [0x2718]=19,            -- ❌✖ close
    [0x2611]=20,                                        -- ☑ ok
    [0x26A0]=22,                                        -- ⚠ warning
    [0x2139]=23,                                        -- ℹ info
    [0x2753]=24,  [0x2754]=24,                          -- ❓❔ question
    [0x2757]=25,  [0x2755]=25,                          -- ❗❕ exclamation
    [0x1F3E0]=26,                                       -- 🏠 home
    [0x2B50]=27,  [0x1F31F]=27,                         -- ⭐🌟 star
    [0x2764]=28,  [0x1F495]=28, [0x1F496]=28, [0x1F497]=28,
    [0x1F499]=28, [0x1F49A]=28, [0x1F49B]=28, [0x1F49C]=28, [0x1F9E1]=28,  -- ❤ hearts
    [0x1F516]=29,                                       -- 🔖 bookmark
    [0x1F4CC]=30,                                       -- 📌 pin
    [0x1F3F7]=31,                                       -- 🏷 tag
    [0x1F6A9]=32, [0x1F3C1]=32,                         -- 🚩🏁 flag
    [0x1F514]=33, [0x1F515]=34,                         -- 🔔🔕 bell
    [0x1F512]=35, [0x1F510]=35,                         -- 🔒🔐 lock
    [0x1F513]=36,                                       -- 🔓 unlock
    [0x1F511]=37, [0x1F5DD]=37,                         -- 🔑🗝 key
    [0x1F441]=38, [0x1F440]=38,                         -- 👁👀 eye
    [0x25B6]=45,                                        -- ▶ play
    [0x23F8]=46,  [0x23F9]=47,                          -- ⏸⏹ pause/stop
    [0x1F3B5]=56, [0x1F3B6]=56,                         -- 🎵🎶 music
    [0x1F4E7]=57, [0x2709]=57,  [0x1F4E9]=57,           -- 📧✉ mail
    [0x1F4AC]=58,                                       -- 💬 chat
    [0x1F4DE]=59, [0x260E]=59,                          -- 📞☎ phone
    [0x1F4C5]=67, [0x1F4C6]=67,                         -- 📅 calendar
    [0x1F550]=68, [0x23F0]=68,                          -- 🕐⏰ clock
    [0x1F4BB]=71, [0x1F5A5]=71,                         -- 💻🖥 computer
    [0x1F4F7]=74, [0x1F4F8]=74,                         -- 📷 camera
    [0x1F3A5]=75, [0x1F4F9]=75,                         -- 🎥📹 video
    [0x1F5BC]=76, [0x1F304]=76,                         -- 🖼 image
    [0x1F4B0]=77, [0x1F4B5]=77,                         -- 💰💵 money
    [0x1F4B3]=78, [0x1F6D2]=79,                         -- 💳 card / 🛒 cart
    [0x1F381]=80,                                       -- 🎁 gift
    [0x1F3C6]=81,                                       -- 🏆 trophy
    [0x1F451]=82,                                       -- 👑 crown
    [0x1F48E]=83,                                       -- 💎 gem
    [0x1F525]=84,                                       -- 🔥 fire
    [0x2728]=85,                                        -- ✨ sparkles
    [0x2600]=86,  [0x1F31E]=86,                         -- ☀🌞 sun
    [0x1F319]=87,                                       -- 🌙 moon
    [0x2601]=88,                                        -- ☁ cloud
    [0x1F327]=89, [0x2614]=89,                          -- 🌧☔ rain
    [0x2744]=90,                                        -- ❄ snow
    [0x1F308]=91,                                       -- 🌈 rainbow
    [0x26A1]=92,                                        -- ⚡ zap
    [0x1F4A7]=93,                                       -- 💧 droplet
    [0x1F680]=94,                                       -- 🚀 rocket
    [0x1F4A1]=95,                                       -- 💡 bulb
    [0x1F4D6]=96, [0x1F4DA]=96, [0x1F4D5]=96, [0x1F4D8]=96,  -- 📖📚 book
    [0x1F310]=98, [0x1F30D]=98, [0x1F30E]=98, [0x1F30F]=98,  -- 🌐🌍 globe
    [0x1F4E6]=99,                                       -- 📦 package
    [0x1F389]=100,[0x1F38A]=100,                        -- 🎉🎊 party
    [0x1F388]=101,                                      -- 🎈 balloon
    [0x1F382]=102,[0x1F370]=102,                        -- 🎂🍰 cake
    [0x2615]=103,                                       -- ☕ coffee
    [0x1F44D]=104,[0x1F44E]=105,[0x1F44C]=106,          -- 👍👎👌
    [0x1F44F]=107,[0x1F44B]=108,                        -- 👏👋
    [0x1F449]=109,[0x1F446]=109,[0x1F448]=109,[0x1F447]=109,  -- 👉 point
    [0x1F64F]=110,[0x1F4AA]=111,                        -- 🙏💪
    [0x1F60A]=112,[0x1F642]=112,[0x1F603]=112,          -- 😊🙂😃
    [0x1F601]=113,[0x1F600]=113,                        -- 😁😀
    [0x1F602]=114,[0x1F923]=114,                        -- 😂🤣
    [0x1F609]=115,[0x1F60E]=116,[0x1F914]=117,          -- 😉😎🤔
    [0x1F622]=118,[0x1F62D]=118,                        -- 😢😭
    [0x1F620]=119,[0x1F621]=119,                        -- 😠😡
    [0x1F60D]=120,[0x1F970]=120,                        -- 😍🥰
    [0x1F916]=121,                                      -- 🤖 robot
    [0x1F464]=122,[0x1F9D1]=122,[0x1F465]=123,          -- 👤🧑👥
    [0x1F6E1]=124,[0x1F3AF]=125,                        -- 🛡🎯
    [0x1F4CD]=126,[0x1F5FA]=127,                        -- 📍🗺
    [0x1F3AE]=128,[0x1F4AF]=129,                        -- 🎮💯
    [0x1F528]=130,[0x1F6E0]=130,[0x1F9E9]=131,          -- 🔨🛠🧩
}

-- src(idx) -> sx, sy, sw, sh  (cell rect in the atlas)
function M.src(idx)
    return (idx % M.COLS) * M.CELL, (idx // M.COLS) * M.CELL, M.CELL, M.CELL
end

-- tokenize(s) -> { {text=...} | {emoji=idx}, ... }   (pcall-safe vs bad UTF-8)
local function tokenize_unsafe(s)
    local out, buf = {}, {}
    for _, cp in utf8.codes(s) do
        if skip(cp) then            -- drop selectors/joiners/skin tones
        else
            local idx = M.MAP[cp]
            if idx then
                if #buf > 0 then out[#out + 1] = { text = table.concat(buf) }; buf = {} end
                out[#out + 1] = { emoji = idx }
            else
                buf[#buf + 1] = utf8.char(cp)
            end
        end
    end
    if #buf > 0 then out[#out + 1] = { text = table.concat(buf) } end
    return out
end

function M.tokenize(s)
    if s == '' then return {} end
    local ok, res = pcall(tokenize_unsafe, s)
    if ok then return res end
    return { { text = s } }     -- malformed UTF-8 → draw as plain text
end

-- measure_width(s, font_size, measure_text) — text runs measured by the font,
-- each emoji counted as a square of side font_size. Keeps wrap + draw aligned.
function M.measure_width(s, font_size, measure_text)
    local w = 0
    for _, tok in ipairs(M.tokenize(s)) do
        if tok.text then w = w + measure_text(tok.text) else w = w + font_size end
    end
    return w
end

return M
