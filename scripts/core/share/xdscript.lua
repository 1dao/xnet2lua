-- xdscript.lua - lazy-loading, caching, error-isolating caller for 策划
-- (designer) callback scripts.
--
-- This is NOT a registry and NOT a pub/sub event bus (that name -- "xevent"
-- -- is reserved for a separate future module where one event fans out to
-- many already-registered in-memory listeners, e.g. an NPC kill notifying
-- every interested system). xdscript owns no trigger table at all: the
-- caller passes the module path + function name + args directly at the call
-- site, straight out of whatever config it already has (an activity table,
-- an npc alert config, a region table -- each subsystem keeps its own
-- key -> {module, func} mapping; xdscript never sees the key).
--
-- xdscript's only job: dofile the file once, cache the returned module table
-- by path, look up func_name on it, and call it safely.
--
--     xdscript.call(module_path, func_name, ...)
--
-- returns:
--   true, ...   -- func_name existed and ran without error; extra returns forwarded
--   false       -- func_name existed but raised an error while running (logged)
--   nil         -- module failed to load, or func_name is not a function on it (logged)
--
-- Loading model: `dofile` (not `require`), matching this repo's reload
-- convention -- dofile does not populate package.loaded, so re-running a
-- worker script re-reads every dofile'd file from disk. The table RETURNED
-- by that dofile is cached by module_path so repeated calls don't re-parse
-- the file from disk each time.
--
-- Reload model: per-Lua-state singleton (same pattern as xrouter/
-- xhttp_router -- stored under a _G key so every
-- dofile('scripts/core/share/xdscript.lua') in the same thread returns the
-- SAME table). The cache is cleared automatically whenever this file itself
-- gets re-dofile'd as part of a worker reload, so edited designer scripts
-- are re-read from disk instead of continuing to run stale cached code.
--
-- Usage:
--     local xdscript = dofile('scripts/core/share/xdscript.lua')
--     local ok = xdscript.call('scripts/design/region/poison_swamp.lua', 'on_enter', player, region_id)

local XDSCRIPT_KEY = '__xnet_xdscript'
local M = rawget(_G, XDSCRIPT_KEY)

local unpack_args = table.unpack or unpack

local function pack_values(...)
    return { n = select('#', ...), ... }
end

-- Drop every cached designer script, forcing ALL of them to be re-read from
-- disk on their next call. Defined up front (rather than further down) so
-- the reload branch below and the public M.reset() API share this one
-- implementation instead of duplicating `loaded = {}` in two places.
local function clear_cache(m)
    m.loaded = {}
end

if type(M) ~= 'table' then
    M = {}
    clear_cache(M)   -- module_path -> dofile'd module table
    rawset(_G, XDSCRIPT_KEY, M)
else
    -- Re-dofile'd as part of a worker reload: force every designer script to
    -- be re-read from disk on its next call.
    clear_cache(M)
end

local function log_err(fmt, ...)
    io.stderr:write(string.format('[XDSCRIPT] ' .. fmt, ...) .. '\n')
end

-- Lazily dofile + cache a designer script module by path.
local function load_module(module_path)
    local mod = M.loaded[module_path]
    if mod ~= nil then return mod end
    local ok, result = pcall(dofile, module_path)
    if not ok then
        log_err('load failed module=%s err=%s', module_path, tostring(result))
        return nil
    end
    if type(result) ~= 'table' then
        log_err('module did not return a table: %s', module_path)
        return nil
    end
    M.loaded[module_path] = result
    return result
end

-- Force a designer script to be re-read from disk on its next call, without
-- requiring a full worker reload (e.g. a debug/admin "reload one script"
-- command).
function M.invalidate(module_path)
    M.loaded[module_path] = nil
end

-- Drop every cached designer script, forcing ALL of them to be re-read from
-- disk on their next call. Same effect as invalidate() applied to the whole
-- cache, and the same thing that happens implicitly on a worker reload --
-- e.g. for a debug/admin "reload all scripts" command, without waiting for
-- a full worker reload.
function M.reset()
    clear_cache(M)
end

-- Call module_path.func_name(...) with lazy-load + cache + error isolation.
-- Never raises -- a broken designer script must not crash the caller (core
-- scene/AOI/game tick). Return value is one of:
--   true, ...  -- ran fine; extra values are func_name's own return values
--   false      -- func_name raised while running (error is logged)
--   nil        -- module failed to load, or func_name isn't a function on it
--                 (error is logged)
function M.call(module_path, func_name, ...)
    local mod = load_module(module_path)
    if not mod then return nil end

    local fn = mod[func_name]
    if type(fn) ~= 'function' then
        log_err('func missing: %s.%s', module_path, tostring(func_name))
        return nil
    end

    local rets = pack_values(pcall(fn, ...))
    if not rets[1] then
        log_err('callback error module=%s func=%s err=%s',
            module_path, func_name, tostring(rets[2]))
        return false
    end
    return true, unpack_args(rets, 2, rets.n)
end

return M
