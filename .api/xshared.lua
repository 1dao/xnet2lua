---@meta
---@diagnostic disable: unreachable-code, unused-local
do return end

-- LuaLS metadata for the native xshared module.
-- LuaLS 使用的 xshared 原生模块元数据。
-- This file is metadata-only and does not execute at runtime.
-- 本文件仅用于元数据，不会在运行时执行。
--
-- Process-global scalar key/value store shared across xnet's shared-nothing
-- Lua threads (one lua_State per OS thread). It holds GLOBAL MUTABLE state a
-- per-thread copy cannot: rate-limit counters, dedup nonces, kill switches,
-- ban lists, session tokens, single-flight locks. Within-process only -- it is
-- NOT Redis. Values are scalars on purpose (number / boolean / string), stored
-- natively with zero decode on the hot path; tables are out of scope.
-- 进程级全局标量键值存储，跨 xnet 的 shared-nothing Lua 线程（每个 OS 线程一个
-- lua_State）共享。它承载每线程副本无法表达的“全局可变状态”：限流计数、去重
-- nonce、熔断开关、封禁名单、会话令牌、单飞锁。仅限进程内，不是 Redis。值刻意限定
-- 为标量（数字/布尔/字符串），原生存储、热路径零解码；表不在范围内。
--
-- Lifecycle: create dicts from the MAIN thread at boot, then resolve them from
-- any thread. TTL reclamation is the runtime's job (no flush_* is exposed).
-- 生命周期：在 MAIN 线程启动时创建字典，随后任意线程都可解析使用。TTL 回收由运行时
-- 负责（不暴露 flush_* 接口）。

---@class xshared
local xshared = {}

-- A handle over a shared dict. The C registry owns the dict's lifetime (freed
-- once at process shutdown), so the handle carries no __gc and is a thin view.
-- 共享字典的句柄。字典生命周期由 C 注册表持有（进程退出时统一释放），故句柄无 __gc，
-- 只是一个轻量视图。
---@class xshared.dict
local dict = {}

---Read a key's value.
---读取某个键的值。
---@param key string Key (binary-safe). / 键（二进制安全）。
---@return number|boolean|string|nil value Stored value, or nil when absent/expired. / 已存的值；不存在或已过期时为 nil。
function dict:get(key) end

---Set a key unconditionally, optionally with a TTL.
---无条件设置某个键，可附带 TTL。
---@param key string Key (binary-safe). / 键（二进制安全）。
---@param value number|boolean|string Scalar value to store. / 要存储的标量值。
---@param ttl_ms? integer Time-to-live in ms; 0 (default) means persistent. / 存活毫秒数；0（默认）表示永久。
---@return boolean ok Always true on success. / 成功时恒为 true。
function dict:set(key, value, ttl_ms) end

---Set a key only if it does NOT already exist.
---仅当键尚不存在时才设置。
---@param key string Key (binary-safe). / 键（二进制安全）。
---@param value number|boolean|string Scalar value to store. / 要存储的标量值。
---@param ttl_ms? integer Time-to-live in ms; 0 (default) means persistent. / 存活毫秒数；0（默认）表示永久。
---@return boolean|nil ok True on insert; nil + "exists" when the key is present. / 插入成功返回 true；键已存在时返回 nil + "exists"。
---@return string? reason "exists" when the key already exists. / 键已存在时为 "exists"。
function dict:add(key, value, ttl_ms) end

---Set a key only if it ALREADY exists.
---仅当键已存在时才设置。
---@param key string Key (binary-safe). / 键（二进制安全）。
---@param value number|boolean|string Scalar value to store. / 要存储的标量值。
---@param ttl_ms? integer Time-to-live in ms; 0 (default) means persistent. / 存活毫秒数；0（默认）表示永久。
---@return boolean|nil ok True on update; nil + "notfound" when the key is absent. / 更新成功返回 true；键不存在时返回 nil + "notfound"。
---@return string? reason "notfound" when the key does not exist. / 键不存在时为 "notfound"。
function dict:replace(key, value, ttl_ms) end

---Delete a key.
---删除某个键。
---@param key string Key (binary-safe). / 键（二进制安全）。
---@return boolean deleted True when a value was removed. / 确实移除了值时返回 true。
function dict:delete(key) end

---Atomically add `delta` to a numeric key, creating it from `init` if absent.
---对一个数字键原子加上 delta；若不存在则以 init 创建。
---@param key string Key (binary-safe). / 键（二进制安全）。
---@param delta? number Amount to add, defaults to 1. / 增量，默认 1。
---@param init? number Initial value when the key is absent, defaults to 0. / 键不存在时的初始值，默认 0。
---@param init_ttl_ms? integer TTL applied only when the key is created, defaults to 0 (persistent). / 仅在创建键时应用的 TTL，默认 0（永久）。
---@return number|nil value New value, or nil + "not a number" when the key holds a non-number. / 新值；键存的不是数字时返回 nil + "not a number"。
---@return string? reason "not a number" when the existing value is not numeric. / 现有值非数字时为 "not a number"。
function dict:incr(key, delta, init, init_ttl_ms) end

---(Re)set the TTL of an existing key.
---（重新）设置已存在键的 TTL。
---@param key string Key (binary-safe). / 键（二进制安全）。
---@param ttl_ms integer New time-to-live in milliseconds. / 新的存活毫秒数。
---@return boolean|nil ok True on success; nil + "notfound" when the key is absent. / 成功返回 true；键不存在时返回 nil + "notfound"。
---@return string? reason "notfound" when the key does not exist. / 键不存在时为 "notfound"。
function dict:expire(key, ttl_ms) end

---Get the remaining TTL of a key in milliseconds.
---获取某个键剩余的 TTL（毫秒）。
---@param key string Key (binary-safe). / 键（二进制安全）。
---@return integer|nil ms Remaining ms, -1 when persistent, or nil when the key is absent. / 剩余毫秒数；永久键为 -1；键不存在时为 nil。
function dict:ttl(key) end

---Return per-dict statistics.
---返回该字典的统计信息。
---@return { capacity: integer, used: integer, items: integer, evicted: integer, expired: integer, shards: integer } stats Byte budget, bytes used, item count, eviction/expiry counters, and shard count. / 字节预算、已用字节、条目数、淘汰/过期计数与分片数。
function dict:stats() end

-- Module functions / 模块函数

---Create (or fetch, if already created) a shared dict. Call at boot from MAIN.
---创建（若已创建则获取）一个共享字典。应在 MAIN 线程启动时调用。
---Idempotent: a second create of the same name returns the existing dict, so
---re-running a main script does not error. The dict enforces a hard byte budget
---with LRU eviction per shard.
---幂等：对同名再次创建会返回既有字典，因此重跑主脚本不会报错。字典按分片以 LRU
---淘汰强制执行字节上限。
---@param name string Unique dict name. / 唯一的字典名称。
---@param size_bytes? integer Total byte budget, defaults to 1 MiB. / 总字节预算，默认 1 MiB。
---@param nshards? integer Shard count (more shards = less contention), defaults to 8. / 分片数（越多争用越少），默认 8。
---@return xshared.dict dict The shared dict handle. / 共享字典句柄。
function xshared.create(name, size_bytes, nshards) end

---Resolve an existing shared dict by name.
---按名称解析一个已创建的共享字典。
---Errors if the dict was not created (create it in MAIN before workers spawn).
---若字典尚未创建则报错（请在工作线程启动前于 MAIN 中创建）。
---@param name string Dict name passed to xshared.create. / 传给 xshared.create 的字典名称。
---@return xshared.dict dict The shared dict handle. / 共享字典句柄。
function xshared.dict(name) end

return xshared
