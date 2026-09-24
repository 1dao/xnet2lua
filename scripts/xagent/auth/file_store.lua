-- Desktop credentials live outside workspaces in an owner-only directory.
-- Android replaces this adapter with its Keystore-backed host bridge.
local json = require('xutils')
local fs = dofile('scripts/core/share/xfs.lua')
local M = {}
local directory = fs.home():gsub('[/\\]+$', '') .. '/.xagent/auth'
local path = directory .. '/chatgpt.json'
local function shell_quote(s) return "'" .. s:gsub("'", "'\\''") .. "'" end
local function protect()
    if fs.is_windows then
        -- icacls is present on supported Windows editions and avoids loading
        -- PowerShell security modules in restricted installations.
        local p = directory:gsub('"', '')
        local user = (os.getenv('USERDOMAIN') or '') .. '\\' .. (os.getenv('USERNAME') or '')
        assert(os.execute('if not exist "' .. p .. '" mkdir "' .. p .. '" >nul 2>nul')
            and os.execute('icacls "' .. p .. '" /inheritance:r /grant:r "' .. user:gsub('"', '') .. '":F >nul 2>nul'),
            'Cannot protect ChatGPT credential directory')
    else
        assert(os.execute('mkdir -p ' .. shell_quote(directory) .. ' && chmod 700 ' .. shell_quote(directory)),
            'Cannot protect ChatGPT credential directory')
    end
end
function M.load()
    local value = fs.read_file(path) or fs.read_file(path .. '.previous')
    if not value then return nil end
    local parsed = json.json_unpack(value)
    assert(type(parsed) == 'table', 'Invalid ChatGPT credential file')
    return parsed
end
function M.save(value)
    protect()
    if not value then
        for _, name in ipairs({path, path .. '.previous', path .. '.tmp'}) do
            if fs.read_file(name) then local ok, err = os.remove(name); if not ok then return nil, err end end
        end
        return true
    end
    local tmp = path .. '.tmp'
    local f, err = io.open(tmp, 'wb'); if not f then return nil, err end
    local ok, write_err = f:write(assert(json.json_pack(value)))
    local closed, close_err = f:close()
    if not ok or not closed then os.remove(tmp); return nil, write_err or close_err end
    if not fs.is_windows then
        if not os.execute('chmod 600 ' .. shell_quote(tmp)) then os.remove(tmp); return nil, 'Cannot protect credentials' end
    end
    -- Windows rename cannot replace an existing target. Keep a recovery copy.
    local backup = path .. '.previous'
    os.remove(backup)
    local existed = fs.read_file(path) ~= nil
    if existed then
        local moved, move_err = os.rename(path, backup)
        if not moved then os.remove(tmp); return nil, move_err end
    end
    local moved, move_err = os.rename(tmp, path)
    if not moved then if existed then os.rename(backup, path) end; return nil, move_err end
    os.remove(backup)
    return true
end
return M
