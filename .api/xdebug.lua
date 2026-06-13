---@meta
---@diagnostic disable: unreachable-code, unused-local, lowercase-global
do return end

-- LuaLS metadata for the native xdebug subsystem.
-- LuaLS 使用的 xdebug 原生子系统元数据。
-- This file is metadata-only and does not execute at runtime.
-- 本文件仅用于元数据，不会在运行时执行。
--
-- IMPORTANT: xdebug is NOT a require-able Lua module. There is no
-- `require("xdebug")`. It is an optional native Lua debugger compiled into the
-- runtime; its Lua-facing entry points live on the xthread module
-- (xthread.xdebug_start / xthread.xdebug_status). This file documents the
-- subsystem -- build switch, boot configuration, transport, and the on-wire
-- command set -- so the behaviour is discoverable alongside the other modules.
-- 重要：xdebug 不是可 require 的 Lua 模块，不存在 require("xdebug")。它是编译进运行时
-- 的可选原生 Lua 调试器；其面向 Lua 的入口位于 xthread 模块上
-- （xthread.xdebug_start / xthread.xdebug_status）。本文件记录该子系统——编译开关、
-- 启动配置、传输方式与线上命令集——以便与其他模块一同被检索查阅。
--
-- ===========================================================================
-- Build switch / 编译开关
--   XNET_WITH_XDEBUG=0  (default)  All hooks compile to no-ops. Production path.
--   XNET_WITH_XDEBUG=1             Links xlua/lua_xdebug.c; a local TCP debug
--                                  server can be exposed. Compiling it in does
--                                  NOT start debugging on its own.
--   XNET_WITH_XDEBUG=0（默认）所有钩子编译为空操作，即生产路径。
--   XNET_WITH_XDEBUG=1           链接 xlua/lua_xdebug.c，可暴露本地 TCP 调试服务；
--                                仅编译进来本身不会启动调试。
--
-- Boot configuration (read from config/args via xargs, see xnet_main.c) / 启动配置
--   XDEBUG_BOOT=1     Start the debug server during process boot.
--   XDEBUG_PORT       Listen port for the debug server (default 19090).
--   XDEBUG_WAIT=1     Block boot until a debugger attaches.
--   XDEBUG_BOOT=1     进程启动时拉起调试服务。
--   XDEBUG_PORT       调试服务监听端口（默认 19090）。
--   XDEBUG_WAIT=1     启动时阻塞，直到调试器连接。
--
-- Transport / 传输方式
--   Native line-oriented TCP server on 127.0.0.1:<XDEBUG_PORT>. VSCode reaches
--   it through tools/xdebug_dap(.exe) (a DAP<->line-protocol bridge);
--   tools/xdebug_dap.js is the fallback. For remote devices, port-forward
--   (ssh -L / adb forward / iproxy) rather than exposing the port directly.
--   本机监听 127.0.0.1:<XDEBUG_PORT> 的行式 TCP 服务。VSCode 经 tools/xdebug_dap(.exe)
--   （DAP <-> 行协议桥接）连接；tools/xdebug_dap.js 为后备。远程设备请用端口转发
--   （ssh -L / adb forward / iproxy），不要直接暴露端口。
--
-- Wire commands (handled by the bridge; for reference) / 线上命令（由桥接器处理，供参考）
--   help · threads · clear · break · pause · continue · step (into/over/out) ·
--   stack · locals · fields · quit
--
-- Threading model / 线程模型
--   Each xnet thread owns an independent lua_State. Debug hooks must be installed
--   by the OS thread that owns that state; the runtime does this in-place from
--   each thread's update loop once the server is running. xdebug also wraps
--   coroutine.create / coroutine.wrap so coroutines inherit the line hook (it
--   briefly installs the internal global __xnet_xdebug_hook_coroutine, which it
--   immediately consumes -- not a public API).
--   每个 xnet 线程拥有独立的 lua_State。调试钩子必须由拥有该状态的 OS 线程安装；服务
--   运行后，运行时会在各线程的更新循环中就地完成安装。xdebug 还包装 coroutine.create /
--   coroutine.wrap，使协程继承行钩子（其间会短暂设置并随即消费内部全局
--   __xnet_xdebug_hook_coroutine，非公开接口）。
-- ===========================================================================

-- Documentation namespace only -- there is no runtime `xdebug` table to require.
-- The two functions below mirror the real entry points on the xthread module.
-- 仅作文档命名空间——运行时没有可 require 的 xdebug 表。下面两个函数对应 xthread
-- 模块上的真实入口。
---@class xdebug
local xdebug = {}

---Start the in-process Lua debug server for the current thread's state.
---为当前线程的状态机启动进程内 Lua 调试服务。
---This is the same call as xthread.xdebug_start; use that name at runtime
---(e.g. through the xadmin remote script executor). Listens on
---127.0.0.1:<port> and installs the line hook for this Lua state.
---这与 xthread.xdebug_start 是同一调用；运行时请使用该名称（例如经 xadmin 远程脚本
---执行器）。在 127.0.0.1:<port> 监听，并为本 Lua 状态安装行钩子。
---@param port? integer TCP port, defaults to 19090. / TCP 端口，默认 19090。
---@param wait? boolean Block until a debugger attaches. / 是否阻塞等待调试器连接。
---@return boolean ok True on success; false + error otherwise. / 成功返回 true；否则返回 false + 错误。
---@return string? message Status message, or error string on failure. / 状态信息；失败时为错误字符串。
---@see xthread.xdebug_start
function xdebug.start(port, wait) end

---Query whether the debug server is running and on which port.
---查询调试服务是否在运行，以及监听端口。
---Same call as xthread.xdebug_status; use that name at runtime.
---与 xthread.xdebug_status 是同一调用；运行时请使用该名称。
---@return boolean running True when the debug server is up. / 调试服务运行中时返回 true。
---@return integer port Listening port (0 when not running). / 监听端口（未运行时为 0）。
---@see xthread.xdebug_status
function xdebug.status() end

return xdebug
