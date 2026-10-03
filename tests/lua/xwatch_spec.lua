-- Unit specs for recursive change notification (xlua/lua_xwatch.c).
-- Run via: make -C tests unit-lua ROOT=.. or bin/xnet tests/lua/xwatch_spec.lua

local spec = dofile('tests/lua/spec_helper.lua')
local u = require('xutils')
local w_mod = require('xwatch')

local function write(path, text)
    local f = assert(io.open(path, 'wb')); assert(f:write(text)); assert(f:close())
end

-- Read until want(paths seen so far, structural) holds or about two seconds
-- pass: FSEvents delivers after its latency, the others almost at once.
local function collect(w, want)
    local seen, structural = {}, false
    for _ = 1, 40 do
        local paths, s, overflow = assert(w:read(50))
        for _, p in ipairs(paths) do seen[p] = true end
        structural = structural or s or overflow
        if want(seen, structural) then break end
    end
    return seen, structural
end

if not w_mod.open then
    print('xwatch: no backend on this platform; skipped')
    local failures = spec.finish()
    return { __init = function() xthread.stop(failures > 0 and 1 or 0) end }
end

local root = 'tests/.xwatch-' .. os.time() .. '-' .. math.random(1000000)
assert(u.mkdir_p(root .. '/sub'))
assert(u.mkdir_p(root .. '/.hidden'))
write(root .. '/sub/a.txt', 'one')

spec.describe('xwatch ' .. tostring(w_mod.backend), function()
    local w = assert(w_mod.open(root, { skip_hidden = true }))

    spec.it('returns nothing when nothing changed', function()
        local paths, structural, overflow = assert(w:read())
        spec.equal(#paths, 0); spec.equal(structural, false); spec.equal(overflow, false)
    end)

    spec.it('reports a modified file by its relative path', function()
        write(root .. '/sub/a.txt', 'two')
        local seen = collect(w, function(seen) return seen['sub/a.txt'] end)
        spec.truthy(seen['sub/a.txt'], 'sub/a.txt reported')
    end)

    spec.it('includes a change completed before read without waiting', function()
        for i = 1, 20 do
            write(root .. '/sub/a.txt', 'quick ' .. i)
            local paths = assert(w:read())
            local hit = false
            for _, p in ipairs(paths) do hit = hit or p == 'sub/a.txt' end
            spec.truthy(hit, 'write ' .. i .. ' visible to an immediate read')
        end
    end)

    spec.it('reports files created in a new directory as structural', function()
        assert(u.mkdir_p(root .. '/new'))
        write(root .. '/new/b.lua', 'x')
        local seen, structural = collect(w, function(seen, s) return s and (seen['new'] or seen['new/b.lua']) end)
        spec.truthy(seen['new'] or seen['new/b.lua'], 'new directory reported')
        spec.equal(structural, true)
        -- the new directory is watched too
        write(root .. '/new/b.lua', 'y')
        seen = collect(w, function(seen) return seen['new/b.lua'] end)
        spec.truthy(seen['new/b.lua'], 'change inside the new directory reported')
    end)

    spec.it('follows a directory renamed within the tree', function()
        assert(os.rename(root .. '/new', root .. '/moved'))
        local seen, structural = collect(w, function(seen, s) return s and seen['moved'] end)
        spec.truthy(seen['moved'], 'rename target reported')
        spec.equal(structural, true)
        write(root .. '/moved/b.lua', 'z')
        seen = collect(w, function(seen) return seen['moved/b.lua'] end)
        spec.truthy(seen['moved/b.lua'], 'change reported under the new name')
        spec.equal(seen['new/b.lua'], nil)
    end)

    spec.it('reports removal as structural', function()
        os.remove(root .. '/sub/a.txt')
        local seen, structural = collect(w, function(seen, s) return s and seen['sub/a.txt'] end)
        spec.truthy(seen['sub/a.txt'], 'removed file reported')
        spec.equal(structural, true)
    end)

    if w_mod.backend == 'inotify' then
        spec.it('leaves hidden directories unwatched with skip_hidden', function()
            write(root .. '/.hidden/c.txt', 'x')
            write(root .. '/sub/d.txt', 'x')
            local seen = collect(w, function(seen) return seen['sub/d.txt'] end)
            spec.equal(seen['.hidden/c.txt'], nil)
        end)
    end

    spec.it('stops reading once closed', function()
        w:close()
        w:close()
        local paths, err = w:read()
        spec.equal(paths, nil); spec.contains(err, 'closed')
    end)

    spec.it('fails to open a missing directory', function()
        local none, err = w_mod.open(root .. '/absent')
        spec.equal(none, nil); spec.truthy(err)
    end)
end)

assert(u.rmtree(root))
local failures = spec.finish()
return { __init = function() xthread.stop(failures > 0 and 1 or 0) end }
