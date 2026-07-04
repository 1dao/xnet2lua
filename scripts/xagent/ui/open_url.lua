-- xagent/ui/open_url.lua — open a URL in the user's browser.
--
-- Generic UI helper (used by clickable transcript links and by the viz
-- pipeline). Desktop: shell out to the platform opener. Mobile/embedded hosts
-- override by setting the global function `xagent_open_url` (e.g. an Android
-- Intent or iOS openURL bridge); when present it wins, so the same Lua runs on
-- every host.

local IS_WIN = package.config:sub(1, 1) == '\\'

local M = {}

function M.open(url)
    url = tostring(url or '')
    if url == '' then return false, 'empty url' end

    local hook = rawget(_G, 'xagent_open_url')
    if type(hook) == 'function' then
        local ok, err = pcall(hook, url)
        return ok, err
    end

    local cmd
    if IS_WIN then
        -- `start` consumes the first quoted token as a window title, so pass an
        -- empty "" title before the quoted URL. `cmd /c` finds the builtin;
        -- the call detaches immediately.
        cmd = string.format('cmd /c start "" "%s"', url)
    elseif (os.getenv('OSTYPE') or ''):find('darwin') then
        cmd = string.format('open "%s" >/dev/null 2>&1 &', url)
    else
        -- Linux/BSD: prefer xdg-open, fall back to `open` if it exists.
        cmd = string.format(
            '{ command -v xdg-open >/dev/null 2>&1 && xdg-open "%s" || open "%s"; } >/dev/null 2>&1 &',
            url, url)
    end
    local ok = os.execute(cmd)
    return ok and true or false
end

return M
