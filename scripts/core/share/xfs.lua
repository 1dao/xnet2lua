-- xfs.lua — small filesystem helpers (Lua io can't mkdir / find home).
-- Dependency-free; any thread can `dofile` it.

---@class xfs
local M = {}

local SEP = package.config:sub(1, 1)
M.is_windows = (SEP == '\\')

function M.home()
    return os.getenv('USERPROFILE') or os.getenv('HOME') or '.'
end

-- Create a directory and any missing parents. Uses a brief os.execute (the only
-- portable mkdir we have without a C binding); output is suppressed.
function M.mkdirp(path)
    if M.is_windows then
        local p = path:gsub('/', '\\')
        os.execute('if not exist "' .. p .. '" mkdir "' .. p .. '" >nul 2>nul')
    else
        os.execute('mkdir -p "' .. path .. '" >/dev/null 2>&1')
    end
end

function M.read_file(path)
    local f = io.open(path, 'rb')
    if not f then return nil end
    local data = f:read('*a')
    f:close()
    return data
end

function M.write_file(path, data)
    local f, err = io.open(path, 'wb')
    if not f then return nil, err end
    f:write(data)
    f:close()
    return true
end

return M
