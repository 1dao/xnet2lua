-- xtimerx.lua
--
-- Reload-safe timer wrapper for lua_xtimer.c
--
-- Usage in a Lua module:
--
--   local M = require("xtimerx")(...)
--
--   function M:on_tick(t)
--       print("tick")
--   end
--
--   M.timer_every("tick", 1000, "on_tick")
--
--   return M
--
-- Reload:
--
--   local xtimerx = require("xtimerx")
--   xtimerx.__reload()
--
--   package.loaded["game.player_timer"] = nil
--   require("game.player_timer")
--
-- Important:
--
--   If a module has ever declared timers through xtimerx, later versions of
--   that module must still keep this line:
--
--       local M = require("xtimerx")(...)
--
--   even if all timer declarations are removed.
--
--   Reason:
--     xtimerx uses module generation to detect stale timers lazily.
--     The module generation is advanced only when require("xtimerx")(...) is
--     executed by that module.
--
--   Therefore, if a new version removes require("xtimerx") entirely, xtimerx
--   cannot know that the module has been reloaded, and old timers from that
--   module may continue to run.
--
--   Correct way to remove all timers from a module:
--
--       local M = require("xtimerx")(...)
--       return M
--
--   Or explicitly cancel them:
--
--       local M = require("xtimerx")(...)
--       M.timer_cancel("tick")
--       M.timer_cancel("save")
--       return M
--
-- C-side requirement:
--
--   This version deletes timers immediately by calling timer:del().
--   The C timer core must support deleting the current firing timer safely:
--
--     * expired timer is extracted from heap before callback;
--     * xtimer_del() on firing timer only marks cancelled;
--     * actual node release/reuse is done after callback returns;
--     * released nodes may go to freelist.

local xtimer = require("xtimer")

local XT = rawget(_G, "__XTIMERX")
if type(XT) ~= "table" then
    XT = {
        timers = {},              -- key -> rec
        fn_cache = {},            -- module::func -> { fn = fn, self = owner }
        module_generation = {},   -- module -> generation
        next_token = 0,
        reload_count = 0,
    }
    rawset(_G, "__XTIMERX", XT)
else
    XT.timers = XT.timers or {}
    XT.fn_cache = XT.fn_cache or {}
    XT.module_generation = XT.module_generation or {}
    XT.next_token = XT.next_token or 0
    XT.reload_count = XT.reload_count or 0
end

local xtimerx = {}

local function log(msg)
    print("[xtimerx] " .. tostring(msg))
end

local function traceback(err)
    if debug and debug.traceback then
        return debug.traceback(tostring(err), 2)
    end
    return tostring(err)
end

local function next_token()
    XT.next_token = (XT.next_token or 0) + 1
    return XT.next_token
end

local function timer_key(module_name, timer_name)
    return module_name .. "::" .. timer_name
end

local function fn_key(module_name, func_name)
    return module_name .. "::" .. func_name
end

local function check_timer_args(timer_name, interval_ms, func_name, repeat_num)
    assert(type(timer_name) == "string", "timer_name must be string")
    assert(type(interval_ms) == "number", "interval_ms must be number")
    assert(interval_ms >= 0, "interval_ms must be >= 0")
    assert(type(func_name) == "string", "func_name must be string")

    if repeat_num == nil then
        repeat_num = -1
    end

    assert(type(repeat_num) == "number", "repeat_num must be number")
    assert(repeat_num == -1 or repeat_num >= 1, "repeat_num must be -1 or >= 1")

    return repeat_num
end

-- Supports:
--
--   "on_tick"
--   "timer.on_tick"
--   "sub.timer.on_tick"
--
-- For "on_tick":
--   owner = module table
--   fn    = module.on_tick
--
-- For "sub.timer.on_tick":
--   owner = module.sub.timer
--   fn    = module.sub.timer.on_tick
--
local function get_field_with_owner(root, path)
    local cur = root
    local owner = root

    for name in string.gmatch(path, "[^%.]+") do
        if type(cur) ~= "table" then
            return nil, nil
        end

        owner = cur
        cur = cur[name]

        if cur == nil then
            return nil, nil
        end
    end

    return owner, cur
end

local function resolve_fn(module_name, func_name)
    local key = fn_key(module_name, func_name)

    local cached = XT.fn_cache[key]
    if cached ~= nil then
        return cached.fn, cached.self
    end

    local mod = package.loaded[module_name]
    if type(mod) ~= "table" then
        return nil, nil, "module not loaded: " .. tostring(module_name)
    end

    local owner, fn = get_field_with_owner(mod, func_name)
    if type(fn) ~= "function" then
        return nil, nil, "function not found: " .. tostring(module_name) .. "." .. tostring(func_name)
    end

    local entry = {
        fn = fn,
        self = owner,
    }

    XT.fn_cache[key] = entry
    return fn, owner
end

-- Delete a timer record now.
--
-- This relies on the C timer core supporting safe deletion during callback.
-- If the timer is currently firing, C should only mark it cancelled and release
-- or recycle the node after callback returns.
local function delete_rec(key, rec, remove_from_current)
    if not rec or rec.deleted then
        return false
    end

    rec.deleted = true

    if remove_from_current and key and XT.timers[key] == rec then
        XT.timers[key] = nil
    end

    local t = rec.timer
    rec.timer = nil

    if t then
        local ok, err = pcall(function()
            if t:active() then
                t:del()
            end
        end)

        if not ok then
            log("timer:del failed: " .. tostring(err))
            return false
        end
    end

    return true
end

-- One-shot / finite-repeat timer has naturally finished.
-- Do not call timer:del() here. C side is already finishing this timer.
local function finish_rec(key, rec)
    if not rec or rec.deleted then
        return
    end

    rec.deleted = true

    if XT.timers[key] == rec then
        XT.timers[key] = nil
    end

    rec.timer = nil
end

local function make_trampoline(key, token)
    return function(timer_self)
        local rec = XT.timers[key]

        -- This can happen when:
        -- 1. timer was cancelled
        -- 2. timer was replaced because interval/repeat changed
        -- 3. old C timer callback entered after Lua record was removed
        if not rec or rec.deleted then
            return
        end

        -- Old trampoline from replaced timer.
        -- New timer uses same key but different token.
        if rec.token ~= token then
            return
        end

        local current_gen = XT.module_generation[rec.module_name] or 0

        -- Lazy cleanup:
        -- This timer belongs to an old module generation.
        -- New module version did not redeclare this timer.
        if rec.generation ~= current_gen then
            delete_rec(key, rec, true)
            return
        end

        local final_call = false

        if rec.repeat_num > 0 then
            rec.remaining = (rec.remaining or rec.repeat_num) - 1
            if rec.remaining <= 0 then
                final_call = true
            end
        end

        local fn, self_obj, err = resolve_fn(rec.module_name, rec.func_name)
        if not fn then
            log(err)

            if final_call then
                finish_rec(key, rec)
            end

            return
        end

        -- Business callback convention:
        --
        --   function M:on_tick(timer_self)
        --   end
        --
        -- Therefore call:
        --
        --   fn(M, timer_self)
        --
        local ok, call_err = xpcall(function()
            return fn(self_obj, timer_self)
        end, traceback)

        if not ok then
            log("callback error: " .. tostring(call_err))
        end

        if final_call then
            finish_rec(key, rec)
        end
    end
end

local function declare_timer(module_name, generation, timer_name, interval_ms, func_name, repeat_num)
    repeat_num = check_timer_args(timer_name, interval_ms, func_name, repeat_num)

    local key = timer_key(module_name, timer_name)
    local rec = XT.timers[key]

    if rec and not rec.deleted then
        local changed =
            rec.interval_ms ~= interval_ms or
            rec.repeat_num ~= repeat_num

        -- Interval or repeat changed:
        -- delete old timer immediately. C timer core is responsible for safe
        -- cancellation if the old timer is currently firing.
        if changed then
            delete_rec(key, rec, true)
            rec = nil
        else
            -- Same timer, just update callback target and module generation.
            -- Do not reset remaining for finite-repeat timer, because C side
            -- still owns its own repeat_remaining.
            rec.func_name = func_name
            rec.generation = generation
            return rec.timer
        end
    end

    local token = next_token()

    rec = {
        module_name = module_name,
        timer_name = timer_name,
        func_name = func_name,

        interval_ms = interval_ms,
        repeat_num = repeat_num,
        remaining = repeat_num > 0 and repeat_num or nil,

        generation = generation,
        token = token,

        timer = nil,
        deleted = false,
    }

    -- Important:
    -- The function passed to C is trampoline, not business callback.
    local t = xtimer.add(interval_ms, make_trampoline(key, token), repeat_num)

    rec.timer = t
    XT.timers[key] = rec

    return t
end

local function cancel_timer(module_name, timer_name)
    assert(type(module_name) == "string", "module_name must be string")
    assert(type(timer_name) == "string", "timer_name must be string")

    local key = timer_key(module_name, timer_name)
    local rec = XT.timers[key]

    if not rec then
        return false
    end

    return delete_rec(key, rec, true)
end

local function new_module(module_name)
    assert(type(module_name) == "string", "xtimerx: module name required")

    local gen = (XT.module_generation[module_name] or 0) + 1
    XT.module_generation[module_name] = gen

    local M = {}

    M.__MODULE = module_name
    M.__GENERATION = gen

    function M.timer_every(timer_name, interval_ms, func_name, repeat_num)
        return declare_timer(module_name, gen, timer_name, interval_ms, func_name, repeat_num or -1)
    end

    function M.timer_once(timer_name, interval_ms, func_name)
        return declare_timer(module_name, gen, timer_name, interval_ms, func_name, 1)
    end

    function M.timer_delay(timer_name, interval_ms, func_name)
        return declare_timer(module_name, gen, timer_name, interval_ms, func_name, 1)
    end

    function M.timer_cancel(timer_name)
        return cancel_timer(module_name, timer_name)
    end

    return M
end

function xtimerx.__reload()
    -- No arguments.
    -- Only clear callback cache.
    -- Do not delete timers here.
    --
    -- Deleted timer declarations will be detected lazily when old timers fire.
    XT.fn_cache = {}
    XT.reload_count = (XT.reload_count or 0) + 1
    return XT.reload_count
end

function xtimerx.cancel(module_name, timer_name)
    return cancel_timer(module_name, timer_name)
end

function xtimerx.cancel_module(module_name)
    assert(type(module_name) == "string", "module_name must be string")

    local count = 0

    -- Do not mutate XT.timers while iterating it directly.
    local keys = {}
    for key, rec in pairs(XT.timers) do
        if rec.module_name == module_name then
            keys[#keys + 1] = key
        end
    end

    for i = 1, #keys do
        local key = keys[i]
        local rec = XT.timers[key]
        if rec and delete_rec(key, rec, true) then
            count = count + 1
        end
    end

    return count
end

function xtimerx.__uninit()
    local keys = {}
    for key in pairs(XT.timers) do
        keys[#keys + 1] = key
    end

    for i = 1, #keys do
        local key = keys[i]
        local rec = XT.timers[key]
        if rec then
            delete_rec(key, rec, true)
        end
    end

    XT.fn_cache = {}
    XT.module_generation = {}
    XT.reload_count = 0
end

function xtimerx.dump()
    local count = 0

    for key, rec in pairs(XT.timers) do
        count = count + 1
        print(string.format(
            "[xtimerx] key=%s module=%s timer=%s func=%s interval=%s repeat=%s gen=%s token=%s deleted=%s",
            tostring(key),
            tostring(rec.module_name),
            tostring(rec.timer_name),
            tostring(rec.func_name),
            tostring(rec.interval_ms),
            tostring(rec.repeat_num),
            tostring(rec.generation),
            tostring(rec.token),
            tostring(rec.deleted)
        ))
    end

    print("[xtimerx] timers=" .. tostring(count))
    return count
end

setmetatable(xtimerx, {
    __call = function(_, module_name)
        return new_module(module_name)
    end
})

return xtimerx
