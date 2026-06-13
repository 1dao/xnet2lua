---@meta
---@diagnostic disable: unreachable-code, unused-local
do return end

-- LuaLS metadata for the native xtimer module.
-- LuaLS 使用的 xtimer 原生模块元数据。
-- This file is metadata-only and does not execute at runtime.
-- 本文件仅用于元数据，不会在运行时执行。
--
-- Per-thread timer wheel (min-heap). Each Lua state owns its own timer pool
-- (the C heap lives in __thread storage), so handles must not be shared across
-- threads. Once xtimer.init() has run, the thread runner auto-drives
-- xtimer.update() each tick and auto-runs xtimer.uninit() on shutdown.
-- 每线程定时器堆（最小堆）。每个 Lua 状态机拥有独立的定时器池（C 堆存于线程局部
-- 存储），因此句柄不可跨线程共享。一旦调用 xtimer.init()，线程运行器每个 tick 会
-- 自动驱动 xtimer.update()，并在退出时自动调用 xtimer.uninit()。

---@class xtimer
local xtimer = {}

-- A live timer handle. While active it holds a strong self-reference, so a
-- fire-and-forget timer stays alive even if the handle is discarded.
-- 一个存活的定时器句柄。激活期间它持有强自引用，因此即便丢弃句柄，
-- “即发即忘”的定时器也不会被回收。
---@class xtimer.handle
local timer = {}

---Cancel the timer and release its callback. A no-op if already fired/cancelled.
---取消定时器并释放其回调。若已触发/已取消则为空操作。
function timer:del() end

---Check whether the timer is still scheduled (has not fired or been cancelled).
---检查定时器是否仍在排程（尚未触发且未取消）。
---@return boolean active True while the timer is live. / 定时器存活时返回 true。
function timer:active() end

-- Lifecycle / 生命周期

---Initialize the per-thread timer heap with an initial capacity.
---以初始容量初始化本线程的定时器堆。
---Normally unnecessary: the runner inits the heap on first use. Call only to
---pre-size it. xtimer.init() also auto-brings-up xpoll if the script has not.
---通常无需手动调用：运行器会在首次使用时初始化。仅用于预分配容量。
---若脚本未启动 xpoll，xtimer.init() 也会自动将其拉起。
---@param capacity? integer Initial heap capacity, defaults to 64 (min 1). / 初始堆容量，默认 64（最小 1）。
function xtimer.init(capacity) end

---Tear down the per-thread timer heap and free all pending timers.
---销毁本线程的定时器堆，释放所有挂起的定时器。
function xtimer.uninit() end

---Report whether the timer heap has been initialized on this thread.
---报告本线程的定时器堆是否已初始化。
---@return boolean inited True when the heap is up. / 堆已建立时返回 true。
function xtimer.inited() end

---Fire all due timers and return the milliseconds until the next one.
---触发所有到期的定时器，并返回距下一个到期定时器的毫秒数。
---Driven automatically by the thread runner; scripts rarely call it directly.
---由线程运行器自动驱动，脚本极少直接调用。
---@return integer nextMs Milliseconds until the next timer, used to size the poll sleep. / 距下一个定时器的毫秒数，用于设定 poll 休眠时长。
function xtimer.update() end

---Return the timestamp (ms) of the most recent xtimer.update() pass.
---返回最近一次 xtimer.update() 的时间戳（毫秒）。
---@return integer ms Last update time in milliseconds. / 上次更新时间（毫秒）。
function xtimer.last() end

---Dump the current timer heap to the log, for debugging.
---将当前定时器堆打印到日志，用于调试。
function xtimer.show() end

-- Scheduling / 排程

---Schedule a repeating or one-shot timer.
---排程一个重复或一次性的定时器。
---The callback receives the timer handle as its only argument.
---回调函数以定时器句柄作为唯一参数。
---@param interval_ms integer Interval in milliseconds (>= 0). / 间隔毫秒数（>= 0）。
---@param callback fun(self: xtimer.handle) Function invoked each time the timer fires. / 每次触发时调用的函数。
---@param repeat_num? integer Times to fire: 1 (default), N, or -1 for infinite. / 触发次数：1（默认）、N，或 -1 表示无限。
---@return xtimer.handle timer Handle usable to cancel the timer. / 可用于取消定时器的句柄。
function xtimer.add(interval_ms, callback, repeat_num) end

---Schedule a one-shot timer (convenience for xtimer.add with repeat_num = 1).
---排程一个一次性定时器（等价于 repeat_num = 1 的 xtimer.add）。
---@param interval_ms integer Delay in milliseconds (>= 0). / 延迟毫秒数（>= 0）。
---@param callback fun(self: xtimer.handle) Function invoked when the timer fires. / 触发时调用的函数。
---@return xtimer.handle timer Handle usable to cancel before it fires. / 触发前可用于取消的句柄。
function xtimer.delay(interval_ms, callback) end

---Cancel a timer by handle (equivalent to handle:del()).
---按句柄取消定时器（等价于 handle:del()）。
---@param timer xtimer.handle Timer handle to cancel. / 要取消的定时器句柄。
function xtimer.del(timer) end

-- Clocks / 时钟

---Monotonic clock in milliseconds (not wall time; good for measuring deltas).
---单调时钟（毫秒），非墙钟时间，适合测量时间差。
---@return integer ms Monotonic milliseconds. / 单调毫秒数。
function xtimer.now_ms() end

---Monotonic clock in microseconds.
---单调时钟（微秒）。
---@return integer us Monotonic microseconds. / 单调微秒数。
function xtimer.now_us() end

---Wall-clock time of day in milliseconds (UNIX epoch based).
---墙钟时间（毫秒），基于 UNIX 纪元。
---@return integer ms Epoch milliseconds. / 纪元毫秒数。
function xtimer.day_ms() end

---Wall-clock time of day in microseconds (UNIX epoch based).
---墙钟时间（微秒），基于 UNIX 纪元。
---@return integer us Epoch microseconds. / 纪元微秒数。
function xtimer.day_us() end

---Format an epoch-millisecond timestamp as a "YYYY-MM-DD HH:MM:SS" string.
---把以毫秒计的纪元时间戳格式化为 "YYYY-MM-DD HH:MM:SS" 字符串。
---@param ms? integer Epoch milliseconds, defaults to the current day time. / 纪元毫秒数，默认当前时间。
---@return string datetime Local datetime string. / 本地日期时间字符串。
function xtimer.format(ms) end

return xtimer
