local xthread = ...

local c_log_init = xthread._log_init
local c_log_enabled = xthread._log_enabled
local c_log_verbose = xthread._log_verbose
local c_log_debug = xthread._log_debug
local c_log_info = xthread._log_info
local c_log_system = xthread._log_system
local c_log_warn = xthread._log_warn
local c_log_error = xthread._log_error
local c_log_fatal = xthread._log_fatal
local c_set_log_level = xthread._set_log_level
local c_get_log_level = xthread._get_log_level

local LOG_VERBOSE = 2
local LOG_DEBUG   = 3
local LOG_INFO    = 4
local LOG_SYSTEM  = 5
local LOG_WARN    = 6
local LOG_ERROR   = 7
local LOG_FATAL   = 8

local _unpack = table.unpack or unpack
local _pack = table.pack or function(...)
    return { n = select('#', ...), ... }
end

local function _str(v)
    local ok, s = pcall(tostring, v)
    if ok then return s end
    return '<tostring error>'
end

local function _concat(sep, ...)
    local args = _pack(...)
    local parts = {}
    for i = 1, args.n do parts[i] = _str(args[i]) end
    return table.concat(parts, sep or '')
end

local function _concat_head(sep, head, args)
    if not args then return _str(head) end
    local parts = { _str(head) }
    for i = 1, args.n do parts[#parts + 1] = _str(args[i]) end
    return table.concat(parts, sep or '')
end

local function _append_from(head, args, start)
    if start > args.n then return head end
    local parts = { head }
    for i = start, args.n do parts[#parts + 1] = _str(args[i]) end
    return table.concat(parts, '\t')
end

local function _format_arg_count(fmt)
    local i = 1
    local count = 0
    local has_percent = false
    while true do
        local p = string.find(fmt, '%', i, true)
        if not p then return count, has_percent end
        has_percent = true
        if string.sub(fmt, p + 1, p + 1) == '%' then
            i = p + 2
        else
            count = count + 1
            i = p + 1
        end
    end
end

local function _message(fmt, ...)
    local n = select('#', ...)
    local args = nil
    if n > 0 then args = _pack(...) end
    if type(fmt) ~= 'string' then
        return _concat_head('\t', fmt, args)
    end
    local fmt_n, has_percent = _format_arg_count(fmt)
    if n == 0 then
        if has_percent then
            local ok, s = pcall(string.format, fmt)
            if ok then return s end
        end
        return _str(fmt)
    end
    if fmt_n > 0 and n >= fmt_n then
        local ok, s = pcall(string.format, fmt, _unpack(args, 1, fmt_n))
        if ok then
            return _append_from(s, args, fmt_n + 1)
        end
    elseif fmt_n == 0 and has_percent then
        local ok, s = pcall(string.format, fmt)
        if ok then return _append_from(s, args, 1) end
    end
    return _concat_head('\t', fmt, args)
end

function xthread.log_init()
    return c_log_init()
end

function xthread.log_verbose(...)
    if not c_log_enabled(LOG_VERBOSE) then return true end
    return c_log_verbose(_message(...))
end

function xthread.log_debug(...)
    if not c_log_enabled(LOG_DEBUG) then return true end
    return c_log_debug(_message(...))
end

function xthread.log_info(...)
    if not c_log_enabled(LOG_INFO) then return true end
    return c_log_info(_message(...))
end

function xthread.log_system(...)
    if not c_log_enabled(LOG_SYSTEM) then return true end
    return c_log_system(_message(...))
end

function xthread.log_warn(...)
    if not c_log_enabled(LOG_WARN) then return true end
    return c_log_warn(_message(...))
end

function xthread.log_error(...)
    if not c_log_enabled(LOG_ERROR) then return true end
    return c_log_error(_message(...))
end

function xthread.log_fatal(...)
    if not c_log_enabled(LOG_FATAL) then return true end
    return c_log_fatal(_message(...))
end

function xthread.set_level(level)
    return c_set_log_level(level)
end

xthread.set_log_level = xthread.set_level

function xthread.get_level()
    return c_get_log_level()
end

xthread.get_log_level = xthread.get_level

if not rawget(_G, '__xthread_log_print_installed') then
    rawset(_G, '__xthread_log_print_installed', true)
    _G.print = function(...)
        return xthread.log_info(...)
    end
    if type(io) == 'table' then
        local stderr_proxy
        stderr_proxy = {
            write = function(_, ...)
                if c_log_enabled(LOG_ERROR) then
                    c_log_error(_concat('', ...))
                end
                return stderr_proxy
            end,
            flush = function() return true end,
        }
        io.stderr = stderr_proxy
    end
end

return xthread
