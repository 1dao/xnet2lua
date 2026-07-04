---@meta
---@diagnostic disable: unreachable-code, unused-local
do return end

-- LuaLS metadata for the native xrecord module.
-- LuaLS 使用的 xrecord 原生模块元数据。
-- This file is metadata-only and does not execute at runtime.
-- 本文件仅用于元数据，不会在运行时执行。
--
-- Schema-defined compact record pools. Stores large numbers of same-shaped
-- game objects (items, quests, ...) in a flat C array instead of one Lua table
-- per object, so the records never become Lua-GC-visible: only the pool handle
-- is a Lua object. Trades ~an order of magnitude slower per-field access for
-- removing per-object GC pressure entirely -- worth it only at real scale
-- (tens of thousands of live objects per Lua state).
-- 基于 schema 的紧凑记录池。把大量同结构的游戏对象（道具、任务……）存进一整块 C
-- 数组，而不是每个对象一张 Lua table，因此记录不会进入 Lua GC 视野：只有池子句柄
-- 是 Lua 对象。用“单次字段访问慢约一个数量级”换“彻底消除单个对象的 GC 压力”——
-- 只有在真正的规模下（每个 lua_State 存活对象数以万计）才划算。
--
-- Recommended layout: build one shared schema at thread init with
-- xrecord.schema(...), then one pool PER PLAYER with schema:new(capacity). The
-- schema names a PRIMARY KEY column (default "id"): create()/load_all read the
-- record id from record[pk], save_all writes it back as record[pk]. The id
-- lives only in the index (not a stored field), so set() cannot corrupt it. A
-- pool pins its schema, so the schema stays alive while any pool over it lives.
-- NOT thread-safe: a handle belongs to the Lua state that created it; never
-- share one across xnet's shared-nothing threads.
-- 推荐布局：在线程 init 时用 xrecord.schema(...) 建一个共享 schema，再用
-- schema:new(capacity) 给每个玩家开一个池子。schema 指定一个主键列（默认 "id"）：
-- create()/load_all 从 record[pk] 读记录 id，save_all 把 id 写回为 record[pk]。id
-- 只存在于索引里（不是存储字段），所以 set() 无法把它改坏。池子会钉住其 schema，
-- 只要还有池子在用，schema 就保持存活。非线程安全：句柄属于创建它的 lua_State，
-- 切勿在 xnet 的 shared-nothing 线程间共享。
--
-- ID RANGE. A record id is int64 in C, but crosses the Lua boundary as a Lua
-- number -- under LuaJIT a number is a double, exact only up to 2^53. Keep every
-- id <= 2^53 (9,007,199,254,740,991) or it cannot be addressed back from Lua
-- (get/set/has/save all round-trip it through a double). load_rows parses ids in
-- C with strtoll, but a value > 2^53 is still unreachable from Lua afterwards.
-- For a composite (player_id << N | local_seq) id, choose N so the whole value
-- stays under 2^53. Recommended: player_id << 24 | local_seq -- 29 bits of
-- player_id (up to 536,870,911 accounts) and 24 bits of local_seq (up to
-- 16,777,215 per player), giving a maximum id of exactly 2^53-1. Assert both
-- bounds where you mint ids so an overflow can't silently collide.
-- id 取值范围。记录 id 在 C 里是 int64，但跨 Lua 边界时是 Lua number——LuaJIT 的
-- number 是 double，只在 2^53 以内精确。每个 id 必须 <= 2^53
-- （9,007,199,254,740,991），否则从 Lua 侧就寻址不回来（get/set/has/save 都要把
-- id 过一遍 double）。load_rows 虽然在 C 里用 strtoll 精确解析 id，但 > 2^53 的值
-- 之后从 Lua 仍然够不到。对 (player_id << N | local_seq) 这类复合 id，选 N 让整个值
-- 落在 2^53 内。推荐：player_id << 24 | local_seq——player_id 29 位（up to
-- 536,870,911 账号）、local_seq 24 位（每玩家 up to 16,777,215），max id 正好
-- 2^53-1。铸造 id 的地方对两个上限都加断言，避免溢出后悄悄冲突。

---A field's storage type. Numeric widths are packed at natural alignment; ints
---and float range-check on write (out-of-range / non-integral / NaN / Inf are
---hard errors, never clamped).
---字段的存储类型。数值宽度按自然对齐紧凑打包；整数与 float 在写入时做范围检查
---（越界/非整数/NaN/Inf 都是硬错误，不会被截断）。
---@alias xrecord.fieldtype
---| "int"    # int64_t / 64 位整数
---| "int8"   # int8_t  (-128..127)
---| "int16"  # int16_t (-32768..32767)
---| "int32"  # int32_t
---| "float"  # 32-bit float / 32 位浮点
---| "bool"   # boolean / 布尔
---| "string" # variable-length bytes / 变长字节串

---A single field definition in a schema (the primary-key column is named
---separately in xrecord.schema and must NOT appear here).
---schema 中的单个字段定义（主键列在 xrecord.schema 中单独指定，不能出现在这里）。
---@alias xrecord.field { name: string, type: xrecord.fieldtype }

---A value crossing the field boundary. Numbers cover every numeric width.
---跨字段边界的值。数字覆盖所有数值宽度。
---@alias xrecord.value number|boolean|string

---A record as a Lua table: the primary-key column (an integer id) plus each
---field name -> value. This is what create/load_all accept and save_all returns.
---以 Lua table 表示的记录：主键列（整数 id）加上每个字段名 -> 值。这正是
---create/load_all 接受、save_all 返回的形状。
---@alias xrecord.record table<string, xrecord.value>

---@class xrecord
local xrecord = {}

-- A shared record layout (primary-key column name, field names/types/offsets),
-- built once and reused for every pool of that object type. Create at init.
-- 共享的记录布局（主键列名、字段名/类型/偏移），建一次并供该对象类型的所有池子复用。
-- 在 init 时创建。
---@class xrecord.schema
local schema = {}

-- A per-instance record pool over a schema. One per player per object type is
-- the recommended layout. Holds a borrowed reference to its schema.
-- schema 之上的每实例记录池。推荐每个玩家、每种对象类型各一个。持有对其 schema 的
-- 借用引用。
---@class xrecord.handle
local handle = {}

-- Schema methods / schema 方法

---Create a pool over this schema.
---在该 schema 之上创建一个池子。
---@param capacity integer Initial slot count; the pool grows (doubles) automatically when full. / 初始槽位数；池子满了会自动翻倍扩容。
---@return xrecord.handle pool The record pool handle. / 记录池句柄。
function schema:new(capacity) end

-- Handle methods / 句柄方法

---Create (upsert) a record. Given an integer, reserve that id with zeroed
---fields. Given a record table, read the id from its primary-key column, reserve
---it, and set the other fields. An already-present id is fine -- create with a
---table on an existing record updates its fields. A bad field value raises a
---Lua error.
---创建（upsert）一条记录。传整数时，用清零字段占用该 id；传记录 table 时，从其主键
---列读出 id、占用它，并写入其余字段。id 已存在也没关系——对已有记录用 table 调
---create 会更新其字段。字段值非法会抛 Lua error。
---@param record integer|xrecord.record An integer id, or a `{ [pk] = id, field = value, ... }` table. / 一个整数 id，或 `{ [pk] = id, field = value, ... }` table。
---@return boolean ok Always true on success (errors are raised). / 成功时恒为 true（出错抛异常）。
function handle:create(record) end

---Remove a record, releasing its slot.
---删除一条记录，释放其槽位。
---@param id integer Record id. / 记录 id。
---@return boolean|nil ok True on success; false + "id not bound" if absent. / 成功返回 true；不存在时返回 false + "id not bound"。
---@return string? reason "id not bound" when the id has no record. / id 无记录时为 "id not bound"。
function handle:destroy(id) end

---Whether `id` currently has a record.
---id 当前是否有记录。
---@param id integer Record id. / 记录 id。
---@return boolean exists True when the id is present. / id 存在时为 true。
function handle:has(id) end

---Write one field. Unknown field name or a value that violates the field's
---declared type/range raises a Lua error (treat as a bad-data signal).
---写入单个字段。字段名不存在、或值与字段声明的类型/范围不符会抛 Lua error
---（应视为数据非法的信号）。
---@param id integer Record id (must exist). / 记录 id（必须存在）。
---@param field string Field name from the schema. / schema 中的字段名。
---@param value xrecord.value Value matching the field's type. / 与字段类型匹配的值。
---@return boolean|nil ok True on success; false + "id not bound" when the id has no record. / 成功返回 true；id 无记录时返回 false + "id not bound"。
---@return string? reason "id not bound" when the id has no record. / id 无记录时为 "id not bound"。
function handle:set(id, field, value) end

---Read one or MORE fields in a single call, returning one value per field in
---argument order. The multi-field form amortizes the per-call overhead (the
---dominant cost of a single get): reading 3 fields in one call is ~2x faster
---than 3 calls. Unknown field name raises a Lua error.
---一次调用读取一个或多个字段，按参数顺序逐个返回值。多字段形式把单次调用的固定
---开销（单字段 get 的主要成本）摊薄：一次读 3 个字段比调 3 次快约 2 倍。字段名
---不存在会抛 Lua error。
---@param id integer Record id (must exist). / 记录 id（必须存在）。
---@param field string Field name from the schema. / schema 中的字段名。
---@param ... string More field names. / 更多字段名。
---@return xrecord.value|nil value First field's value; nil + "id not bound" when the id has no record. / 第一个字段的值；id 无记录时返回 nil + "id not bound"。
---@return xrecord.value|string ... Remaining values, or "id not bound". / 其余字段的值；或 "id not bound"。
function handle:get(id, field, ...) end

---Bulk-create an array of records (login path). Each element is a record table
---carrying its id in the primary-key column; each is created (upsert) then
---populated. Bad data raises a Lua error naming the record/field.
---批量创建一个记录数组（登录路径）。每个元素是带主键列（id）的记录 table；逐个
---create（upsert）后填充。数据非法时抛 Lua error 并指明记录/字段。
---@param records xrecord.record[] Array of `{ [pk] = id, field = value, ... }`. / `{ [pk] = id, field = value, ... }` 数组。
---@return boolean ok Always true on success (errors are raised). / 成功时恒为 true（出错抛异常）。
function handle:load_all(records) end

---Columnar bulk-load for a text-protocol DB result (e.g. xmysql's
---`result.fields` + `result.values`). `fields` is the array of column names;
---`values` an array of positional rows (each a `{ cell, ... }` array, `nil` for
---SQL NULL). The pk column is located by name and each id is parsed in C (full
---64-bit); every other string cell is coerced to its schema field's type
---(no keyed Lua table is built, no hand-written string->number pass). Columns
---not in the schema are ignored. Bad data raises a Lua error naming the
---row/column. Prefer this over load_all when loading straight from the DB.
---针对文本协议 DB 结果的列式批量加载（比如 xmysql 的 `result.fields` +
---`result.values`）。`fields` 是列名数组；`values` 是位置行数组（每行一个
---`{ cell, ... }`，SQL NULL 用 `nil`）。按列名定位主键列、每个 id 在 C 里全 64 位
---解析；其余字符串单元格按 schema 字段类型转换（不建 k-v table，也不用手写
---字符串→数字）。schema 里没有的列会被忽略。数据非法时抛 Lua error 指明行/列。
---直接从 DB 加载时优先用它而不是 load_all。
---@param fields string[] Column names (e.g. xmysql result.fields). / 列名（比如 xmysql 的 result.fields）。
---@param values (xrecord.value|nil)[][] Positional rows of cells (e.g. xmysql result.values). / 位置行数组（比如 xmysql 的 result.values）。
---@return boolean ok Always true on success (errors are raised). / 成功时恒为 true（出错抛异常）。
function handle:load_rows(fields, values) end

---Serialize records into an array of record tables (logout / save path). No
---argument saves the WHOLE pool; passing an id array saves just that subset,
---skipping ids with no record. Each element carries its id in the primary-key
---column, so the result round-trips: load_all(save_all()) restores the pool.
---把记录序列化成记录 table 数组（退出/存盘路径）。无参时保存整个池子；传入 id 数组
---则只保存该子集，跳过没有记录的 id。每个元素都在主键列带着自己的 id，因此结果可
---往返：load_all(save_all()) 能还原池子。
---@param ids? integer[] Optional id subset; omit to save the whole pool. / 可选的 id 子集；省略则保存整个池子。
---@return xrecord.record[] records Array of records, each carrying its id in the pk column. / 记录数组，每个都在主键列带着自己的 id。
function handle:save_all(ids) end

---Free the pool's C memory now instead of waiting for GC (logout teardown).
---Idempotent; a closed handle behaves as an empty pool.
---立即释放池子的 C 内存，而不是等 GC（退出销毁）。幂等；已关闭的句柄行为等同空池。
function handle:close() end

-- Module functions / 模块函数

---Build a shared record layout once. `pk` names the primary-key column that
---carries each record's integer id (default "id"); it must NOT also be one of
---`fields`. Field names must be unique. Reuse the schema for every pool of the
---same object type; create at thread init.
---把共享的记录布局建一次。`pk` 指定承载每条记录整数 id 的主键列名（默认 "id"），
---它不能同时是 `fields` 中的字段。字段名必须唯一。供同一对象类型的所有池子复用；
---在线程 init 时创建。
---@param fields xrecord.field[] Ordered non-key field definitions. / 有序的非主键字段定义。
---@param pk? string Primary-key column name, defaults to "id". / 主键列名，默认 "id"。
---@return xrecord.schema schema The shared schema handle. / 共享 schema 句柄。
function xrecord.schema(fields, pk) end

---One-off convenience: build a private schema and a pool over it in one call
---(equivalent to xrecord.schema(fields, pk):new(capacity)).
---一次性便捷写法：一次调用建一个私有 schema 和其上的池子（等价于
---xrecord.schema(fields, pk):new(capacity)）。
---@param fields xrecord.field[] Ordered non-key field definitions. / 有序的非主键字段定义。
---@param capacity integer Initial slot count; the pool grows automatically when full. / 初始槽位数；池子满时自动扩容。
---@param pk? string Primary-key column name, defaults to "id". / 主键列名，默认 "id"。
---@return xrecord.handle pool The record pool handle. / 记录池句柄。
function xrecord.create(fields, capacity, pk) end

return xrecord
