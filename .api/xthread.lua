---@meta
---@diagnostic disable: unreachable-code, unused-local
do return end

-- LuaLS metadata for the native xthread module.
-- LuaLS 使用的 xthread 原生模块元数据。
-- This file is metadata-only and does not execute at runtime.
-- 本文件仅用于元数据，不会在运行时执行。
--
-- Shared-nothing threading: each OS thread owns an independent lua_State and
-- they communicate only by passing cmsgpack-encoded messages through bounded
-- per-thread queues. xthread provides:
--   * messaging  -- post (fire-and-forget) and rpc (request/reply, coroutine)
--   * threads    -- create_thread / shutdown_thread, current_id, stats
--   * logging    -- log_* helpers routed to the central log thread
-- Wire formats (handled for you):
--   POST  ->  pack(nil,          pt, args...)        handler(nil, pt, args...)
--   RPC   ->  pack(reply_router, co_id, 0, pt, ...)  handler(reply_router, co_id, sk, pt, ...)
-- shared-nothing 线程模型：每个 OS 线程拥有独立的 lua_State，线程间仅通过有界的每线程
-- 队列传递 cmsgpack 编码的消息来通信。xthread 提供：
--   * 消息    —— post（即发即忘）与 rpc（请求/应答，基于协程）
--   * 线程    —— create_thread / shutdown_thread、current_id、stats
--   * 日志    —— 路由到中央日志线程的 log_* 辅助函数
-- 线缆格式（已为你处理）见上方英文注释。

---@class xthread
local xthread = {}

-- ===========================================================================
-- Lifecycle & messaging / 生命周期与消息
-- ===========================================================================

---Initialize messaging on the current thread and register its message handler.
---初始化当前线程的消息收发，并注册其消息处理器。
---Caches cmsgpack.pack/unpack, sets up the pending-RPC tables, and stores the
---handler. If `handler` is omitted, falls back to the global `__thread_handle`
---(or `__exports.__thread_handle`). Must run on a registered xthread before
---post/rpc can be used. The handler is invoked as handler(reply_router, key,
---sk, pt, ...) per the wire format above.
---缓存 cmsgpack.pack/unpack，建立挂起 RPC 表，并保存处理器。若省略 handler，则回退到
---全局 __thread_handle（或 __exports.__thread_handle）。必须在已注册的 xthread 上调用，
---之后才能使用 post/rpc。处理器按上文线缆格式以 handler(reply_router, key, sk, pt, ...)
---被调用。
---@param handler? fun(...) Message handler; defaults to __thread_handle. / 消息处理器；默认使用 __thread_handle。
function xthread.init(handler) end

---Fire-and-forget: post a message to another thread's queue.
---即发即忘：向另一个线程的队列投递一条消息。
---@param target_id integer Destination thread id (see the XTHR_* constants). / 目标线程 id（见 XTHR_* 常量）。
---@param pt string Packet/message type string used by the receiver to route. / 接收方用于路由的包/消息类型字符串。
---@param ... any Additional arguments (cmsgpack-encodable). / 附加参数（可被 cmsgpack 编码）。
---@return boolean ok True on enqueue; false + error otherwise. / 入队成功返回 true；否则返回 false + 错误。
---@return string? err "queue full" or "unavailable" on failure. / 失败时为 "queue full" 或 "unavailable"。
function xthread.post(target_id, pt, ...) end

---Request/reply RPC to another thread. MUST be called from inside a coroutine.
---对另一个线程发起请求/应答 RPC。必须在协程内调用。
---Yields the current coroutine until the reply (or timeout) arrives, then returns
---the remote stub's results. The Lua wrapper handles the yield/resume; on
---transport failure it returns false + error without yielding.
---挂起当前协程，直到应答（或超时）到达，然后返回远端 stub 的结果。Lua 包装层处理
---yield/resume；传输失败时不挂起，直接返回 false + 错误。
---@param target_id integer Destination thread id. / 目标线程 id。
---@param pt string Packet/message type the remote side dispatches on. / 远端据以分派的包/消息类型。
---@param timeout_ms integer Reply timeout in ms; 0 means wait indefinitely. / 应答超时毫秒数；0 表示无限等待。
---@param ... any Request arguments. / 请求参数。
---@return any ... On success, the remote results; on failure, false + error string. / 成功时返回远端结果；失败时返回 false + 错误字符串。
function xthread.rpc(target_id, pt, timeout_ms, ...) end

---Set a thread's inbound queue cap.
---设置某线程入站队列的上限。
---@param target_id integer Thread id to configure. / 要配置的线程 id。
---@param new_max integer Cap (> 0 to enable, 0 = unlimited). / 上限（> 0 启用，0 = 不限）。
---@return boolean ok True on success; false + error otherwise. / 成功返回 true；否则返回 false + 错误。
---@return string? err Error message on failure. / 失败时的错误信息。
function xthread.set_queue_max(target_id, new_max) end

---The id of the current thread.
---当前线程的 id。
---@return integer id Thread id (<= 0 if not a registered xthread). / 线程 id（非注册 xthread 时 <= 0）。
function xthread.current_id() end

-- ===========================================================================
-- Threads / 线程
-- ===========================================================================

---Spawn a new OS thread that loads and runs a Lua script in its own state.
---创建一个新的 OS 线程，在其独立状态机中加载并运行一个 Lua 脚本。
---@param id integer Unique thread id to assign. / 要分配的唯一线程 id。
---@param name string Human-readable thread name (used in logs). / 可读的线程名称（用于日志）。
---@param script_path string Path to the Lua script the new thread runs. / 新线程运行的 Lua 脚本路径。
---@return boolean ok True on success; false + error otherwise. / 成功返回 true；否则返回 false + 错误。
---@return string? err Error message on failure. / 失败时的错误信息。
function xthread.create_thread(id, name, script_path) end

---Unregister and shut down a dynamically created thread (runs its __uninit).
---注销并关停一个动态创建的线程（会运行其 __uninit）。
---@param id integer Thread id to shut down. / 要关停的线程 id。
---@return boolean ok True on success; false + error otherwise. / 成功返回 true；否则返回 false + 错误。
---@return string? err Error message on failure. / 失败时的错误信息。
function xthread.shutdown_thread(id) end

---Queue stats for one thread.
---单个线程的队列统计。
---@param id integer Thread id. / 线程 id。
---@return { id: integer, name: string, queue_depth: integer, queue_max: integer }|nil stats Stats table, or nil + error. / 统计表；失败时返回 nil + 错误。
---@return string? err Error message on failure. / 失败时的错误信息。
function xthread.stats(id) end

---Queue stats for every registered thread.
---所有已注册线程的队列统计。
---@return { id: integer, name: string, queue_depth: integer, queue_max: integer }[] stats Array of per-thread stats. / 每线程统计组成的数组。
function xthread.all_stats() end

-- ===========================================================================
-- Logging / 日志
--
-- log_* take a printf-style format plus args (string.format), or any value(s)
-- joined by tabs when the first arg is not a format string. They route to the
-- central log thread unless log_init() has marked this thread as logging
-- locally. Calling log_init() also redirects global print() to log_info and
-- io.stderr:write to log_error.
-- log_* 接受 printf 风格的格式串加参数（string.format）；当首参非格式串时，多个值以
-- 制表符拼接。日志默认路由到中央日志线程，除非 log_init() 已将本线程标记为本地写日志。
-- 调用 log_init() 还会把全局 print() 重定向到 log_info，io.stderr:write 重定向到
-- log_error。
-- ===========================================================================

---Mark the current thread for local logging and register its log label.
---把当前线程标记为本地写日志，并注册其日志标签。
---@return boolean ok True on success; false + error otherwise. / 成功返回 true；否则返回 false + 错误。
---@return string? err Error message on failure. / 失败时的错误信息。
function xthread.log_init() end

---Log at VERBOSE level (2). / 以 VERBOSE 级别（2）记录日志。
---@param fmt any Format string or first value. / 格式串或首个值。
---@param ... any Format arguments / extra values. / 格式参数 / 额外值。
---@return boolean ok True when written or filtered out. / 写入或被过滤时返回 true。
function xthread.log_verbose(fmt, ...) end
---Log at DEBUG level (3). / 以 DEBUG 级别（3）记录日志。
---@param fmt any Format string or first value. / 格式串或首个值。
---@param ... any Format arguments / extra values. / 格式参数 / 额外值。
---@return boolean ok True when written or filtered out. / 写入或被过滤时返回 true。
function xthread.log_debug(fmt, ...) end
---Log at INFO level (4). Also the target of redirected print(). / 以 INFO 级别（4）记录日志；也是被重定向的 print() 的目标。
---@param fmt any Format string or first value. / 格式串或首个值。
---@param ... any Format arguments / extra values. / 格式参数 / 额外值。
---@return boolean ok True when written or filtered out. / 写入或被过滤时返回 true。
function xthread.log_info(fmt, ...) end
---Log at SYSTEM level (5). / 以 SYSTEM 级别（5）记录日志。
---@param fmt any Format string or first value. / 格式串或首个值。
---@param ... any Format arguments / extra values. / 格式参数 / 额外值。
---@return boolean ok True when written or filtered out. / 写入或被过滤时返回 true。
function xthread.log_system(fmt, ...) end
---Log at WARN level (6). / 以 WARN 级别（6）记录日志。
---@param fmt any Format string or first value. / 格式串或首个值。
---@param ... any Format arguments / extra values. / 格式参数 / 额外值。
---@return boolean ok True when written or filtered out. / 写入或被过滤时返回 true。
function xthread.log_warn(fmt, ...) end
---Log at ERROR level (7). Also the target of redirected io.stderr:write. / 以 ERROR 级别（7）记录日志；也是被重定向的 io.stderr:write 的目标。
---@param fmt any Format string or first value. / 格式串或首个值。
---@param ... any Format arguments / extra values. / 格式参数 / 额外值。
---@return boolean ok True when written or filtered out. / 写入或被过滤时返回 true。
function xthread.log_error(fmt, ...) end
---Log at FATAL level (8). / 以 FATAL 级别（8）记录日志。
---@param fmt any Format string or first value. / 格式串或首个值。
---@param ... any Format arguments / extra values. / 格式参数 / 额外值。
---@return boolean ok True when written or filtered out. / 写入或被过滤时返回 true。
function xthread.log_fatal(fmt, ...) end

---Set the global log level threshold.
---设置全局日志级别阈值。
---@param level integer Level constant (2..8). / 级别常量（2..8）。
---@return boolean ok Always true. / 恒为 true。
---@return integer level The effective level after the change. / 变更后的有效级别。
function xthread.set_level(level) end

---Alias of xthread.set_level. / xthread.set_level 的别名。
---@param level integer Level constant (2..8). / 级别常量（2..8）。
---@return boolean ok Always true. / 恒为 true。
---@return integer level The effective level after the change. / 变更后的有效级别。
function xthread.set_log_level(level) end

---Get the current global log level.
---获取当前全局日志级别。
---@return integer level Current level constant. / 当前级别常量。
function xthread.get_level() end

---Alias of xthread.get_level. / xthread.get_level 的别名。
---@return integer level Current level constant. / 当前级别常量。
function xthread.get_log_level() end

-- ===========================================================================
-- Debugger (only when built with XNET_WITH_XDEBUG) / 调试器（仅 XNET_WITH_XDEBUG 构建）
-- ===========================================================================

---Start the in-process Lua debug server on this thread's state.
---在本线程状态机上启动进程内 Lua 调试服务。
---Listens on 127.0.0.1:<port>, normally reached by VSCode via tools/xdebug_dap.
---在 127.0.0.1:<port> 监听，通常由 VSCode 经 tools/xdebug_dap 连接。
---@param port? integer TCP port, defaults to 19090. / TCP 端口，默认 19090。
---@param wait? boolean Block until a debugger attaches. / 是否阻塞等待调试器连接。
---@return boolean ok True on success; false + error otherwise. / 成功返回 true；否则返回 false + 错误。
---@return string? message Status message, or error string on failure. / 状态信息；失败时为错误字符串。
function xthread.xdebug_start(port, wait) end

---Query whether the debug server is running and on which port.
---查询调试服务是否在运行，以及监听端口。
---@return boolean running True when the debug server is up. / 调试服务运行中时返回 true。
---@return integer port Listening port (0 when not running). / 监听端口（未运行时为 0）。
function xthread.xdebug_status() end

-- ===========================================================================
-- Thread id constants / 线程 id 常量
-- Single-purpose threads use ids 1..8; worker groups are 20-wide bases (a group
-- spans base .. base+19), so group threads sit above 8.
-- 单一用途线程使用 id 1..8；工作线程组以 20 为跨度的基址（一个组覆盖 base .. base+19），
-- 因此组内线程 id 均大于 8。
-- ===========================================================================
xthread.MAIN = 1
xthread.REDIS = 2
xthread.MYSQL = 3
xthread.LOG = 4
xthread.IO = 5
xthread.COMPUTE = 6
xthread.NATS = 7
xthread.HTTP = 8
xthread.WORKER_GRP1 = 20
xthread.WORKER_GRP2 = 40
xthread.WORKER_GRP3 = 60
xthread.WORKER_GRP4 = 80
xthread.WORKER_GRP5 = 100

return xthread
