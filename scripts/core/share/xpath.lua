-- xpath.lua — minimal cross-platform path helpers (Lua has none).
-- Pure string ops, dependency-free; any thread can `dofile` it.

local M = {}

local SEP = package.config:sub(1, 1)   -- '\' on Windows, '/' on POSIX
M.sep = SEP
M.is_windows = (SEP == '\\')

function M.is_absolute(p)
    if type(p) ~= 'string' or p == '' then return false end
    if p:sub(1, 1) == '/' then return true end                 -- POSIX
    if p:match('^%a:[/\\]') then return true end                -- C:\ or C:/
    if p:sub(1, 2) == '\\\\' then return true end               -- UNC \\server
    return false
end

-- Join + normalize against cwd. Forward slashes are fine for io.open / cmd on
-- Windows (the CRT accepts both), so we keep '/' as the internal separator.
function M.resolve(p, cwd)
    p = tostring(p or '')
    if M.is_absolute(p) then return p end
    cwd = tostring(cwd or '.'):gsub('[/\\]+$', '')
    if p == '' then return cwd end
    return cwd .. '/' .. p
end

function M.basename(p)
    return (tostring(p or ''):gsub('[/\\]+$', ''):match('[^/\\]+$')) or p
end

function M.dirname(p)
    local d = tostring(p or ''):gsub('[/\\]+$', ''):match('^(.*)[/\\][^/\\]+$')
    return d or '.'
end

return M
