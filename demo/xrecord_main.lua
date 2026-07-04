-- Regression example for xrecord: schema-defined compact record pools.
-- Run directly with: ./bin/xnet demo/xrecord_main.lua
-- Or through Makefile: make run-lua SCRIPT=demo/xrecord_main.lua
-- CI runs this via make test-lua-core.

local pass, fail = 0, 0
local failures = {}

local function ok(name, cond, detail)
    if cond then
        pass = pass + 1
        print(string.format('  PASS  %s', name))
    else
        fail = fail + 1
        local msg = string.format('  FAIL  %s%s', name,
            detail and ('  -- ' .. tostring(detail)) or '')
        print(msg)
        failures[#failures + 1] = msg
    end
end

local function eq(name, got, want)
    if got == want then ok(name, true)
    else ok(name, false, string.format('got=%s want=%s', tostring(got), tostring(want))) end
end

local function head(t) print('\n== ' .. t .. ' ==') end

-- ============================================================================
-- 1. shared schema + per-player pools (recommended layout)
-- ============================================================================
head('schema / new / create / get / has / destroy')

-- built ONCE (e.g. at thread init); pk column defaults to "id"
local item_schema = xrecord.schema({
    { name = 'hp',   type = 'int'    },
    { name = 'name', type = 'string' },
    { name = 'dead', type = 'bool'   },
})

-- one pool per player over the shared schema
local items = item_schema:new(4)

ok('has() false before create', items:has(1001) == false)

-- create(table): upsert a whole record (id read from the pk column)
ok('create from table', items:create({ id = 1001, hp = 100, name = 'sword', dead = false }))
ok('has() true after create', items:has(1001) == true)
eq('created hp',   items:get(1001, 'hp'), 100)
eq('created name', items:get(1001, 'name'), 'sword')
eq('created dead', items:get(1001, 'dead'), false)

-- create(int): just reserve an id, fields default-zeroed
ok('create from id', items:create(1002))
eq('reserved hp defaults 0',   items:get(1002, 'hp'), 0)
eq('reserved name defaults empty', items:get(1002, 'name'), '')

-- create is upsert: create(table) on an existing id updates its fields
ok('create upsert existing', items:create({ id = 1001, hp = 90 }))
eq('upsert updated hp', items:get(1001, 'hp'), 90)
eq('upsert left name intact', items:get(1001, 'name'), 'sword')

-- single-field set/get
ok('set hp', items:set(1001, 'hp', 75))
eq('get hp', items:get(1001, 'hp'), 75)

-- string grow/shrink/empty (rpmalloc realloc-in-place path)
ok('set long name',  items:set(1001, 'name', 'a rather long legendary sword name'))
eq('get long name',  items:get(1001, 'name'), 'a rather long legendary sword name')
ok('set short name', items:set(1001, 'name', 'x'))
eq('get short name', items:get(1001, 'name'), 'x')

-- destroy removes a record
ok('destroy', items:destroy(1002))
ok('has() false after destroy', items:has(1002) == false)
local d, derr = items:destroy(1002)
ok('destroy missing returns false', d == false and derr == 'id not bound')

-- errors: unbound id -> false; unknown field / bad value -> raise
local sv, sverr = items:set(999999, 'hp', 1)
ok('set on unbound id returns false', sv == false and sverr == 'id not bound')
ok('unknown field raises', pcall(function() items:get(1001, 'nope') end) == false)
ok('type mismatch raises', pcall(function() items:set(1001, 'hp', 'not a number') end) == false)

-- ============================================================================
-- 2. narrow int widths + float, with hard-error range checking
-- ============================================================================
head('int8 / int16 / int32 / float (range-checked)')

-- realistic per-item stat block: level 0-100, quality, sockets, drop rate
local stat_schema = xrecord.schema({
    { name = 'level',   type = 'int8'  },  -- 1..100
    { name = 'quality', type = 'int8'  },  -- 0..5 stars
    { name = 'attack',  type = 'int16' },  -- up to ~32k
    { name = 'price',   type = 'int32' },  -- gold, up to ~2.1e9
    { name = 'droprate',type = 'float' },  -- 0.0..1.0
})
local stats = stat_schema:new(4)
stats:create({ id = 1, level = 80, quality = 5, attack = 3000, price = 1500000000, droprate = 0.05 })

eq('int8  level',   stats:get(1, 'level'), 80)
eq('int8  quality', stats:get(1, 'quality'), 5)
eq('int16 attack',  stats:get(1, 'attack'), 3000)
eq('int32 price',   stats:get(1, 'price'), 1500000000)
ok('float droprate approx', math.abs(stats:get(1, 'droprate') - 0.05) < 1e-6)

-- negative narrow ints
ok('set int16 negative', stats:set(1, 'attack', -1234))
eq('get int16 negative',  stats:get(1, 'attack'), -1234)

-- out-of-range / non-integral / NaN / Inf are hard errors, never clamped
ok('int8 overflow raises',  pcall(function() stats:set(1, 'level', 200) end) == false)
ok('int16 overflow raises', pcall(function() stats:set(1, 'attack', 40000) end) == false)
ok('int32 overflow raises', pcall(function() stats:set(1, 'price', 5e9) end) == false)
ok('fractional int8 raises', pcall(function() stats:set(1, 'level', 3.5) end) == false)
ok('float NaN raises',       pcall(function() stats:set(1, 'droprate', 0/0) end) == false)
ok('float Inf raises',       pcall(function() stats:set(1, 'droprate', 1/0) end) == false)
eq('level unchanged after rejected writes', stats:get(1, 'level'), 80)

-- ============================================================================
-- 3. quest system -- a second object type, custom primary key
-- ============================================================================
head('quest system (custom pk = "quest_id")')

-- quests keyed by "quest_id" instead of the default "id"
local quest_schema = xrecord.schema({
    { name = 'progress', type = 'int16' },  -- e.g. mobs killed
    { name = 'target',   type = 'int16' },  -- goal count
    { name = 'state',    type = 'int8'  },  -- 0=active 1=done 2=claimed
    { name = 'note',     type = 'string'},  -- free-form / activity data
}, 'quest_id')

local quests = quest_schema:new(8)

-- login: bulk-load this player's quests from DB rows
ok('quest load_all', quests:load_all({
    { quest_id = 5001, progress = 3,  target = 10, state = 0, note = 'slay slimes' },
    { quest_id = 5002, progress = 10, target = 10, state = 1, note = 'gather herbs' },
}))
eq('quest 5001 progress', quests:get(5001, 'progress'), 3)
eq('quest 5002 state',    quests:get(5002, 'state'), 1)

-- gameplay: advance progress, then complete
ok('advance progress', quests:set(5001, 'progress', 10))
ok('mark done',        quests:set(5001, 'state', 1))
eq('quest 5001 done',  quests:get(5001, 'state'), 1)

-- accept a new quest at runtime
ok('accept new quest', quests:create({ quest_id = 5003, progress = 0, target = 5, state = 0, note = 'find the relic' }))
eq('new quest count via save', #quests:save_all(), 3)

-- ============================================================================
-- 4. login <-> logout round-trip (load_all / save_all)
-- ============================================================================
head('load_all <-> save_all round-trip')

-- logout: serialize the whole quest pool -> Lua tables (then cmsgpack/json -> DB)
local rows = quests:save_all()
ok('save_all returns whole pool', type(rows) == 'table' and #rows == 3)
ok('saved record carries its pk', rows[1].quest_id ~= nil)

-- the dump round-trips: load it into a fresh pool over the same schema
local quests2 = quest_schema:new(8)
ok('load_all(save_all()) restores', quests2:load_all(rows))
eq('restored 5001 progress', quests2:get(5001, 'progress'), 10)
eq('restored 5002 note',     quests2:get(5002, 'note'), 'gather herbs')
eq('restored 5003 target',   quests2:get(5003, 'target'), 5)

-- filtered save: only a subset of ids (e.g. dirty quests)
local subset = quests:save_all({ 5001, 5003 })
eq('filtered save_all subset', #subset, 2)
-- unbound ids in the list are skipped
local partial = quests:save_all({ 5001, 999999 })
eq('save_all skips unbound ids', #partial, 1)

-- ============================================================================
-- 4b. load_rows -- columnar DB result (text protocol: every cell a string)
-- ============================================================================
head('load_rows (columnar DB fast path)')

-- shape of xmysql result: `fields` = column names, `values` = positional rows,
-- every cell a STRING (MySQL text protocol). Note an extra "updated_at" column
-- the schema doesn't model, and a SQL NULL (nil) cell.
local db_fields = { 'quest_id', 'progress', 'target', 'state', 'note', 'updated_at' }
local db_values = {
    { '6001', '2', '8',  '0', 'hunt wolves', '2026-07-04 10:00:00' },
    { '6002', '8', '8',  '1', nil,           '2026-07-04 10:05:00' },  -- note IS NULL
}
local quests3 = quest_schema:new(8)
ok('load_rows from string cells', quests3:load_rows(db_fields, db_values))
eq('load_rows coerced int16', quests3:get(6001, 'progress'), 2)   -- "2" -> 2
eq('load_rows coerced int8',  quests3:get(6001, 'state'), 0)      -- "0" -> 0
eq('load_rows kept string',   quests3:get(6001, 'note'), 'hunt wolves')
eq('load_rows SQL NULL -> default', quests3:get(6002, 'note'), '') -- nil cell left default
eq('load_rows unknown column ignored', quests3:get(6002, 'progress'), 8)

-- a bad numeric cell is a hard error (row/column named)
ok('load_rows rejects non-numeric int cell',
    pcall(function()
        quest_schema:new(4):load_rows({ 'quest_id', 'progress' }, { { '7001', 'abc' } })
    end) == false)

-- a large id from a string cell is parsed in C. NOTE: ids must stay <= 2^53 to
-- remain addressable from Lua (a LuaJIT number is a double); this one is.
local big_schema = xrecord.schema({ { name = 'v', type = 'int' } })
local big = big_schema:new(4)
local big_id = 4503599627000000   -- ~4.5e15, < 2^53, exactly representable
ok('load_rows large id', big:load_rows({ 'id', 'v' }, { { '4503599627000000', '9' } }))
ok('large id addressable', big:has(big_id))
eq('large id value', big:get(big_id, 'v'), 9)
big:close()

-- ============================================================================
-- 5. per-player teardown (close) + shared-schema lifetime
-- ============================================================================
head('close + shared-schema lifetime')

-- two players share one schema; closing one must not disturb the other
local a = item_schema:new(4)
local b = item_schema:new(4)
a:create({ id = 1, name = 'a-item' })
b:create({ id = 1, name = 'b-item' })
eq('pools independent (a)', a:get(1, 'name'), 'a-item')
eq('pools independent (b)', b:get(1, 'name'), 'b-item')

a:close()
ok('closed pool has() false', a:has(1) == false)
ok('other pool still works after close', b:get(1, 'name') == 'b-item')
a:close()  -- second close is a no-op, must not crash

-- CRITICAL: a pool pins its schema. Drop every user-facing schema/pool ref and
-- force GC; a still-live pool must NOT lose the schema out from under it.
local orphan = item_schema:new(4)
orphan:create({ id = 7, name = 'anchored' })
item_schema = nil
b = nil
collectgarbage('collect'); collectgarbage('collect')
eq('pool survives GC after schema ref dropped', orphan:get(7, 'name'), 'anchored')
ok('pool still writable after GC', orphan:set(7, 'hp', 5))
orphan:close()

-- ============================================================================
-- 6. auto-grow past initial capacity (grow_pool: realloc + zero-extend)
-- ============================================================================
head('auto-grow')

-- tiny initial capacity, then force several doublings (2 -> 4 -> 8 -> 16 -> 32)
local g = xrecord.schema({ { name = 'n', type = 'int' }, { name = 's', type = 'string' } }):new(2)
local N = 25
for i = 1, N do
    g:create({ id = i, n = i * 10, s = 'row-' .. i })
end
local all_readable, mismatch = true, nil
for i = 1, N do
    if g:get(i, 'n') ~= i * 10 or g:get(i, 's') ~= ('row-' .. i) then
        all_readable = false; mismatch = i; break
    end
end
ok('all records survive grow', all_readable, mismatch and ('bad at id ' .. mismatch))
eq('grown pool count via save_all', #g:save_all(), N)
-- freshly grown slots default-zero correctly, and old data untouched
g:create(9999)
eq('grown fresh slot default', g:get(9999, 'n'), 0)
eq('pre-grow record intact', g:get(1, 's'), 'row-1')
g:close()

-- ============================================================================
-- 7. one-shot xrecord.create + schema validation
-- ============================================================================
head('one-shot create + validation')

-- module-level create: private schema + pool in one call, default pk "id"
local one = xrecord.create({ { name = 'x', type = 'int' } }, 4)
ok('one-shot create works', one:create({ id = 1, x = 42 }))
eq('one-shot get', one:get(1, 'x'), 42)
one:close()

-- one-shot create with a custom pk
local one2 = xrecord.create({ { name = 'x', type = 'int' } }, 4, 'key')
ok('one-shot custom pk', one2:create({ key = 5, x = 7 }))
eq('one-shot custom pk get', one2:get(5, 'x'), 7)
one2:close()

-- a field named the same as the pk is rejected at schema build
ok('pk/field collision rejected',
    pcall(function() xrecord.schema({ { name = 'id', type = 'int' } }) end) == false)
-- unknown field type rejected
ok('unknown field type rejected',
    pcall(function() xrecord.schema({ { name = 'x', type = 'int128' } }) end) == false)

-- ============================================================================
-- 8. multi-field get + slot-cache invalidation
-- ============================================================================
head('multi-field get + slot cache')

local m = xrecord.schema({
    { name = 'hp',   type = 'int'    },
    { name = 'name', type = 'string' },
    { name = 'dead', type = 'bool'   },
}):new(4)
m:create({ id = 11, hp = 70, name = 'mace', dead = false })

-- one call, three values, declaration order of the arguments
local hp, nm, dd = m:get(11, 'hp', 'name', 'dead')
ok('multi-get values', hp == 70 and nm == 'mace' and dd == false,
    string.format('%s/%s/%s', tostring(hp), tostring(nm), tostring(dd)))
-- single-field form unchanged
eq('single get still works', m:get(11, 'hp'), 70)
-- unbound id -> nil + msg (not partial values)
local v1, v2 = m:get(999, 'hp', 'name')
ok('multi-get unbound id', v1 == nil and v2 == 'id not bound')
-- unknown field mid-list raises
ok('multi-get unknown field raises',
    pcall(function() m:get(11, 'hp', 'nope') end) == false)

-- slot-cache invalidation: hammer one id (cache it), destroy it, then make a
-- new record that reuses the freed slot -- reads of the OLD id must miss, and
-- a stale cache would wrongly serve the new record's slot here.
m:set(11, 'hp', 1)                      -- cache primed on id=11
m:destroy(11)                            -- must invalidate the cache
m:create({ id = 22, hp = 999, name = 'axe', dead = true })  -- likely reuses the slot
ok('destroyed id not readable', m:get(11, 'hp') == nil)
ok('destroyed id has() false', m:has(11) == false)
eq('new occupant reads its own data', m:get(22, 'hp'), 999)
-- rebinding the old id starts from defaults, not the old slot contents
m:create(11)
eq('recreated id gets defaults', m:get(11, 'hp'), 0)
m:close()

print('\n========================================')
print(string.format('PASS %d   FAIL %d', pass, fail))
if fail > 0 then
    for _, m in ipairs(failures) do print(m) end
end
print('========================================')

-- xnet_main.c lifecycle: return a table with __init that asks the runner to stop.
return {
    __init = function()
        xthread.stop(fail == 0)
    end,
}
