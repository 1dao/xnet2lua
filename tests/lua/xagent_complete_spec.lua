-- Unit specs for the input autocomplete logic (ui/complete.lua): token
-- detection for / and @, live filtering, ranking, and applying a choice back
-- into the input text + caret offset. All offline, no raygui.
-- Run via: bin/xnet tests/lua/xagent_complete_spec.lua

package.path = 'scripts/?.lua;' .. package.path

local spec     = dofile('tests/lua/spec_helper.lua')
local complete = require('xagent.ui.complete')

-- fakes: a fixed command catalog and a tiny in-memory directory tree
local SLASH = {
    { name = 'compact', desc = '压缩上下文' },
    { name = 'context', desc = '上下文用量' },
    { name = 'mcp',     desc = 'MCP' },
    { name = 'new',     desc = '新会话' },
    { name = 'help',    desc = '帮助' },
    { name = 'code-review', desc = 'review' },
}
local TREE = {
    [''] = { 'core/', 'ui/', 'config.lua', 'main.lua', '.hidden' },
    ['core/'] = { 'loop.lua', 'session/', 'async.lua' },
}
local deps = {
    slash_items = function() return SLASH end,
    list_dir = function(rel) return TREE[rel or ''] or {} end,
}

local function names(items)
    local t = {}
    for i, it in ipairs(items) do t[i] = it.name end
    return t
end
local function has(items, name)
    for _, it in ipairs(items) do if it.name == name then return true end end
    return false
end

spec.describe('detect / slash', function()
    spec.it('bare slash → empty query', function()
        local d = complete.detect('/')
        spec.equal(d.kind, 'slash'); spec.equal(d.query, '')
    end)
    spec.it('partial command', function()
        spec.equal(complete.detect('/comp').query, 'comp')
    end)
    spec.it('hyphenated command name', function()
        spec.equal(complete.detect('/code-review').query, 'code-review')
    end)
    spec.it('a space ends slash mode', function()
        spec.nil_value(complete.detect('/comp x'))
    end)
    spec.it('slash must start the input', function()
        spec.nil_value(complete.detect('hi /comp'))
        spec.nil_value(complete.detect('a/b'))
    end)
end)

spec.describe('detect @ path', function()
    spec.it('bare @ at start', function()
        local d = complete.detect('@')
        spec.equal(d.kind, 'at'); spec.equal(d.dir_part, ''); spec.equal(d.leaf, '')
        spec.equal(d.prefix, '@')
    end)
    spec.it('@ after whitespace, with a subdir path', function()
        local d = complete.detect('see @core/se')
        spec.equal(d.kind, 'at')
        spec.equal(d.dir_part, 'core/')
        spec.equal(d.leaf, 'se')
        spec.equal(d.prefix, 'see @core/')
    end)
    spec.it('email-like a@b does not trigger', function()
        spec.nil_value(complete.detect('user@host'))
    end)
    spec.it('@ not at the end does not trigger', function()
        spec.nil_value(complete.detect('@core hello'))
    end)
end)

spec.describe('filter_slash', function()
    spec.it('empty query lists all', function()
        spec.equal(#complete.filter_slash(SLASH, ''), #SLASH)
    end)
    spec.it('prefix matches rank before substring matches', function()
        -- 'co' is a prefix of compact/context/code-review, a substring of none else
        local out = complete.filter_slash(SLASH, 'co')
        spec.truthy(has(out, 'compact'))
        spec.truthy(has(out, 'context'))
        spec.truthy(has(out, 'code-review'))
        spec.truthy(not has(out, 'mcp'))
    end)
    spec.it('substring match (mc inside mcp)', function()
        local out = complete.filter_slash(SLASH, 'mc')
        spec.truthy(has(out, 'mcp'))
    end)
    spec.it('insert carries a trailing space', function()
        local out = complete.filter_slash(SLASH, 'compact')
        spec.equal(out[1].insert, '/compact ')
    end)
end)

spec.describe('compute @ listing', function()
    spec.it('lists root, dirs first, hides dotfiles', function()
        local m = complete.compute('@', deps)
        spec.equal(m.kind, 'at')
        -- core/ and ui/ (dirs) precede the files
        spec.equal(m.items[1].is_dir, true)
        spec.equal(m.items[2].is_dir, true)
        spec.truthy(not has(m.items, '.hidden'))   -- dotfile hidden without a dot leaf
        spec.truthy(has(m.items, 'config.lua'))
    end)
    spec.it('a leading dot reveals dotfiles', function()
        local m = complete.compute('@.h', deps)
        spec.truthy(has(m.items, '.hidden'))
    end)
    spec.it('filters by leaf inside a subdirectory', function()
        local m = complete.compute('@core/lo', deps)
        spec.truthy(has(m.items, 'loop.lua'))
        spec.truthy(not has(m.items, 'async.lua'))
    end)
    spec.it('no match → nil menu', function()
        spec.nil_value(complete.compute('@zzz', deps))
    end)
end)

spec.describe('apply', function()
    spec.it('slash replaces the whole input', function()
        local m = complete.compute('/comp', deps)
        local new, caret = complete.apply(m, m.items[1])
        spec.equal(new, '/compact ')
        spec.equal(caret, #new)
    end)
    spec.it('@ file keeps the prefix and adds a trailing space', function()
        local m = complete.compute('see @config', deps)
        local item
        for _, it in ipairs(m.items) do if it.name == 'config.lua' then item = it end end
        local new = complete.apply(m, item)
        spec.equal(new, 'see @config.lua ')
    end)
    spec.it('@ directory keeps drilling (no trailing space)', function()
        local m = complete.compute('@cor', deps)
        local item
        for _, it in ipairs(m.items) do if it.name == 'core/' then item = it end end
        local new, caret = complete.apply(m, item)
        spec.equal(new, '@core/')
        spec.equal(caret, #new)
    end)
end)

return {
    __init = function()
        local failed = spec.finish()
        if failed > 0 then os.exit(1) end
        xthread.stop(0)
    end,
}
