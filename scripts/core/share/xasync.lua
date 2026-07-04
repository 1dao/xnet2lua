-- xasync.lua — coroutine "await" for callback-based async ops.
--
-- This is what lets a coroutine (e.g. an agentic loop) wait on a callback-based
-- async op — the streaming HTTP client, a subprocess RPC, a timer — as if it
-- were blocking, without stalling the event loop. `start(resolve)` kicks off the
-- async op; when its callback fires (later, from the event loop) it calls
-- `resolve(...)`, which resumes us. The values passed to resolve become await's
-- return values. Dependency-free; any thread can `dofile` it.

---@class xasync
local M = {}

local pack = table.pack
local unpack = table.unpack

function M.await(start)
    local co, is_main = coroutine.running()
    assert(co and not is_main, 'xasync.await must run inside a coroutine')

    local done = false
    local vals = nil

    local function resolve(...)
        if done then return end
        done = true
        vals = pack(...)
        -- Only resume if we actually yielded (async path). If `start` resolved
        -- synchronously, we never yield and just fall through to the return.
        if coroutine.status(co) == 'suspended' then
            local ok, err = coroutine.resume(co)
            if not ok then
                io.stderr:write('[xasync] resume error: ' .. tostring(err) .. '\n')
            end
        end
    end

    start(resolve)

    if not done then
        coroutine.yield()
    end
    return unpack(vals, 1, vals.n)
end

return M
