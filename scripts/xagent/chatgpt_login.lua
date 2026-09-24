-- Desktop CLI login: bin/xnet[.exe] scripts/xagent/chatgpt_login.lua
-- Optional PROXY=socks5h://host:port or ACTION=logout. Never prints credentials.
package.path = 'scripts/?.lua;' .. package.path
local login = require('xagent.auth.login')
local auth = require('xagent.auth.chatgpt')
local json = require('xutils')
return {
    __tick_ms = 20,
    __init = function()
        assert(xnet.init())
        if json.get_config('ACTION') == 'logout' then
            auth.logout(); print('ChatGPT logged out'); xthread.stop(0); return
        end
        local ok, url = pcall(login.start, { proxy = json.get_config('PROXY'),
            on_done = function(success, err)
                print(success and 'ChatGPT login saved' or tostring(err))
                xthread.stop(success and 0 or 1)
            end })
        if not ok then print(tostring(url)); xthread.stop(1); return end
        print('Complete login in your browser. If it did not open, visit:\n' .. url)
        require('xagent.ui.open_url').open(url)
    end,
    __update = login.tick,
    __uninit = function() login.cancel(); xnet.uninit() end,
}
