# xnet2lua 使用文档

> 版本：基于 [github.com/1dao/xnet2lua](https://github.com/1dao/xnet2lua)  
> 语言：C（核心） + Lua（脚本层）  
> 定位：高性能异步网络框架，通过 Lua 绑定让脚本层具备生产级多线程网络能力

---

## 目录

1. [架构概览](#1-架构概览)
2. [编译与集成](#2-编译与集成)
3. [程序入口与线程生命周期](#3-程序入口与线程生命周期)
4. [xthread 模块——多线程与消息传递](#4-xthread-模块多线程与消息传递)
5. [xnet 模块——异步网络](#5-xnet-模块异步网络)
6. [帧协议（分包策略）](#6-帧协议分包策略)
7. [TLS / HTTPS 支持](#7-tls--https-支持)
8. [HTTP 服务器](#8-http-服务器)
9. [cmsgpack 模块——MessagePack 序列化](#9-cmsgpack-模块messagepack-序列化)
10. [xutils 模块——工具函数](#10-xutils-模块工具函数)
10A. [xcompress 模块——压缩与校验和](#10a-xcompress-模块压缩与校验和)
11. [配置文件](#11-配置文件)
12. [线程 ID 常量表](#12-线程-id-常量表)
13. [完整示例：TCP 服务器](#13-完整示例tcp-服务器)
14. [完整示例：HTTP API 服务](#14-完整示例http-api-服务)
15. [完整示例：跨线程 RPC](#15-完整示例跨线程-rpc)
16. [最佳实践与注意事项](#16-最佳实践与注意事项)
17. [xadmin 控制台](#17-xadmin-控制台)
18. [xnats 跨进程 RPC](#18-xnats-跨进程-rpc)
19. [热重载协议](#19-热重载协议)
20. [Lua 调试与 VSCode 调试](#20-lua-调试与-vscode-调试)

---

## 1. 架构概览

xnet2lua 分为四层：

```
┌─────────────────────────────────────────────────────┐
│            Lua 应用层（你的业务脚本）                 │
├────────────────────────────────────────┬────────────┤
│  xnet（网络连接/监听）                  │ xthread    │
│  xutils（JSON/工具）                   │（线程/RPC） │
│  cmsgpack（MessagePack）               │            │
├────────────────────────────────────────┴────────────┤
│  C 核心层：xpoll / xchannel / xsock / xtimer        │
├─────────────────────────────────────────────────────┤
│  第三方：mbedTLS / yyjson / minilua / libdeflate    │
└─────────────────────────────────────────────────────┘
```

**关键设计：**
- 每个线程拥有独立的 Lua State，线程间完全隔离
- 跨线程通信通过 **POST（异步）** 或 **RPC（同步，内部用协程实现）**
- I/O 多路复用自动按平台选用 epoll / kqueue / WSAPoll / poll
- 网络帧协议支持 raw、len16（2 字节长度前缀，单包最大 65535B）、len32（4 字节长度前缀）、CRLF 四种

---

## 2. 编译与集成

> ⚙️ **构建系统已重组**：根 Makefile 现在直接构建出 `libxnet.a`、`bin/xnet`、`bin/xthread_test`
> 三件产物，**不再需要先 `make` 再 `cd demo && make` 的两段式构建**。
> 仓库根目录新增了 `build.bat`（MSVC 全源编译），并支持 LuaJIT 作为可选 Lua 后端。

### 2.1 一键构建（GCC / MinGW / Linux / macOS）

```bash
cd xnet2lua

# 默认：release + minilua + HTTP + HTTPS，输出到 bin/
make

# 单独构建子目标
make xnet            # 只构建 bin/xnet
make xthread_test    # 只构建 bin/xthread_test
make clean
```

可调变量（命令行 `KEY=VALUE` 覆盖）：

| 变量 | 默认值 | 取值 | 说明 |
|------|--------|------|------|
| `BUILD_MODE` | `release` | `release` / `debug` | `-O2 -DNDEBUG` ↔ `-O0 -g -DDEBUG` |
| `WITH_HTTP` | `1` | `1` / `0` | 是否编译 HTTP 代码路径 |
| `WITH_HTTPS` | `1` | `1` / `0` | 是否编译 mbedTLS / HTTPS 路径 |
| `WITH_IO_URING` | `0` | `1` / `0` | Linux 下启用 `XPOLL_USE_IO_URING` 与 `XCHANNEL_USE_IO_URING`，需链接 `liburing` |
| `WITH_XDEBUG` | `0` | `1` / `0` | 是否把原生 Lua 调试器编进 `bin/xnet`；只编译能力，不会自动启动调试服务 |
| `WITH_RPMALLOC` | `1` | `1` / `0` | 把项目自己的 `malloc/free` 通过 `xmacro.h` 路由到 rpmalloc；`=0` 时退回 libc，`rpmalloc.c` 不参与链接（详见 §2.7） |
| `LUA_BACKEND` | `minilua` | `minilua` / `luajit` | 内置 Lua 还是 LuaJIT；选 `luajit` 时需要先把 `3rd/luajit` 子模块拉下来并构建 `libluajit.a` |

```bash
# 示例
make BUILD_MODE=debug
make WITH_HTTPS=0
make WITH_XDEBUG=1                         # 编进调试能力，运行时仍需 XDEBUG_BOOT 或 xthread.xdebug_start
make WITH_IO_URING=1                       # Linux only
make LUA_BACKEND=luajit                    # 详见 2.5
```

> `demo/Makefile` 现在是一个薄壳，把同名目标转发到根 Makefile（`make -C ..`），保留旧路径以免破坏既有脚本。

### 2.2 Windows / MSVC 构建（`build.bat`）

仓库根目录的 `build.bat` 是**全源编译**入口（不消费 `libxnet.a`），自动定位 `vcvarsall.bat` 并加载 x64 工具链。`demo/build.bat` 仍可用，但内部仅做参数透传。

```bat
:: 默认 release，构建 bin\xnet.exe + bin\xthread_test.exe
build.bat

:: 切换 debug
build.bat debug

:: 关闭 HTTP / HTTPS
build.bat nohttp
build.bat nohttps

:: 关闭 rpmalloc，自有代码的内存分配退回 libc（详见 2.7）
build.bat norpmalloc

:: 编译原生 Lua 调试器能力（不等于启动调试服务）
build.bat xdebug

:: 切换到 LuaJIT 后端
::（首次会自动调用 3rd\luajit\src\msvcbuild.bat static 把 lua51.lib 编出来）
build.bat luajit

:: 仅构建某个目标
build.bat xnet
build.bat xthread_test

:: 跑测试套件（详见 2.4）
build.bat test
build.bat test-c
build.bat test-lua-core
build.bat test-lua-external
build.bat test-lua-all

:: 单跑一个 Lua 脚本
build.bat run-lua demo/xutils_main.lua
build.bat run-lua script=demo/xnet_main.lua

:: 清理
build.bat clean
```

参数可任意组合，如 `build.bat debug luajit nohttps test-lua-core`。

### 2.3 运行 demo

`bin/xnet`（或 `bin/xnet.exe`）是一个**通用 Lua 运行器**，第一个参数是要执行的 Lua 脚本，后续参数按 `KEY=VALUE` 形式覆盖配置：

```bash
./bin/xnet demo/xnet_main.lua
./bin/xnet demo/xhttp_main.lua
./bin/xnet demo/xhttps_main.lua          # 需 WITH_HTTPS 构建
./bin/xnet demo/xredis_main.lua
./bin/xnet demo/xmysql_main.lua
./bin/xnet demo/xnats_main.lua SERVER_NAME=game1
./bin/xnet scripts/xpac/xpac_main.lua
```

CLI 的 `KEY=VALUE` 优先于 `xnet.cfg`，但被读取的键必须在 `xnet_main.c` 的 `g_arg_configs[]` 白名单中（新增 Lua 配置项时如果想让它支持命令行覆盖，记得同步更新该数组）。

### 2.4 测试目标

根 Makefile 现在内置了一组测试入口（GCC/MinGW 与 MSVC 两条路径都能跑）：

```bash
make test                  # = test-c + test-lua-core
make test-c                # 只跑 C 层 xthread_test
make test-lua-core         # 跑核心 Lua 用例：
                           #   demo/xutils_main.lua, xtimer_main.lua, xtimerx_test.lua,
                           #   xlua_main.lua, xnet_main.lua, xrouter_test.lua,
                           #   xhttp_router_test.lua, xhttp_main.lua
make test-lua-external     # 需要外部依赖（HTTPS/Redis/MySQL/NATS）的脚本：
                           #   demo/xhttps_main.lua, xredis_main.lua, xmysql_main.lua, xnats_main.lua
make test-lua-all          # core + external

# 用 xnet 单跑一个脚本
make run-lua SCRIPT=demo/xnet_main.lua
```

`build.bat` 接受同名目标（`build.bat test` / `build.bat test-lua-core` 等），选项语义一致。

### 2.5 Lua 后端：minilua 与 LuaJIT

xnet2lua 同时支持两种 Lua 运行时：

- **minilua**（默认，`-DLUA_EMBEDDED`）：`3rd/minilua.h` 单头文件，Lua 5.4 风格，不引入外部依赖。
- **LuaJIT**（`-DXLUA_USE_LUAJIT=1`）：链接 `3rd/luajit/src/libluajit.a`（GCC/MinGW）或 `lua51.lib`（MSVC）。Lua 5.1 + 部分 5.2 扩展 + JIT。

启用 LuaJIT 时框架会在每个 Lua state 的 `luaL_openlibs()` 之后自动调用：

```c
luaJIT_setmode(L, 0, LUAJIT_MODE_ENGINE | LUAJIT_MODE_ON);
```

确保主线程和所有 worker 线程的 JIT 都开启。Lua 5.1 缺失的若干 API（`luaL_requiref`、`lua_isinteger`、`luaL_tolstring`，以及 `LUA_MAXINTEGER`/`LUA_MININTEGER` 边界）由 `xnet_main.c`、`xlua/lua_xthread.c`、`xlua/lua_xutils.c` 内联补齐，**绑定层 API 在两种后端下完全一致**，业务代码不需要改 Lua 模块名或函数签名。

> 💡 **业务代码注意**：Lua 5.4 的位运算符 `& | ~ << >>` 在 LuaJIT (5.1) 下会**语法错误**。
> 想同时兼容两个后端，请改用 `bit` 库（LuaJIT 自带 `bit.band` / `bit.bxor` / `bit.lshift` / ...）。
> `scripts/core/server/xmysql_worker.lua` 的 SHA-1 / SHA-256 实现给出了一份完整的 fallback 模板（在
> 检测不到 `bit`/`bit32` 时回退到纯 Lua 位运算），可直接参考。

### 2.6 嵌入式集成

要把 xnet2lua 嵌入自己的 C 项目：

1. 链接 `libxnet.a`；
2. 选择 Lua 后端并定义对应宏：
   - `-DLUA_EMBEDDED`：直接 `#include "3rd/minilua.h"`（在某一个 `.c` 中 `#define LUA_IMPL`）。
   - `-DXLUA_USE_LUAJIT=1`：`#include "lua.h" / "lauxlib.h" / "lualib.h" / "luajit.h"`，并链接 LuaJIT 静态库。
3. 在 C 入口完成下列初始化：

```c
#if defined(LUA_EMBEDDED)
    #define LUA_IMPL
    #include "3rd/minilua.h"
#else
    #include "lua.h"
    #include "lauxlib.h"
    #include "lualib.h"
    #if defined(XLUA_USE_LUAJIT)
        #include "luajit.h"
    #endif
#endif

#include "xthread.h"
#include "xmacro.h"   // 必须最后包含；带 -DXMACRO_USE_RPMALLOC=0 构建时四个 rpmalloc_* 调用自动 stub 成 no-op

// rpmalloc 必须先于一切分配（包括 xthread_init 内部的 calloc）初始化；
// 同时把主线程注册到 rpmalloc。WITH_RPMALLOC=0 构建时这行被 stub 掉。
rpmalloc_initialize(NULL);

lua_State* L = luaL_newstate();
luaL_openlibs(L);
#if defined(XLUA_USE_LUAJIT)
    luaJIT_setmode(L, 0, LUAJIT_MODE_ENGINE | LUAJIT_MODE_ON);
#endif

// 注册 Lua 模块
luaL_requiref(L, "xthread",  luaopen_xthread,  1); lua_pop(L, 1);
luaL_requiref(L, "xnet",     luaopen_xnet,     1); lua_pop(L, 1);
luaL_requiref(L, "cmsgpack", luaopen_cmsgpack, 1); lua_pop(L, 1);
luaL_requiref(L, "xutils",   luaopen_xutils,   1); lua_pop(L, 1);

// 初始化线程系统（worker 线程的 rpmalloc_thread_initialize/_finalize 由框架自动配对）
xthread_init();

// ... 业务循环 ...

// 退出前
xthread_uninit();
lua_close(L);
rpmalloc_finalize();
```

### 2.7 内存分配器（rpmalloc + xmacro.h）

xnet2lua 默认把**项目自己写的 C 代码**的 `malloc / calloc / realloc / free / strdup` 路由到 mjansson/rpmalloc（`3rd/rpmalloc/rpmalloc.c`）。rpmalloc 的每线程 cache + 跨线程 deferred-free 队列正好匹配本项目的 actor 模型——大量 POST/RPC buffer 由 sender 线程分配、receiver 线程释放，这种工况下 rpmalloc 不依赖全局锁。

路由由 `xmacro.h` 中的函数式宏完成：

```c
#define malloc(n)     rpmalloc(n)
#define calloc(n,s)   rpcalloc((n),(s))
#define realloc(p,n)  rprealloc((p),(n))
#define free(p)       rpfree(p)
#define strdup(s)     xmacro_rpstrdup(s)
```

**关键边界**：xnet2lua **不**劫持 CRT 的 `malloc/free` 符号（rpmalloc 自带的 `ENABLE_OVERRIDE` 已强制关闭）。所以 libc 调用、miniz / mbedTLS、以及 Lua VM 自己的 GC 仍然全部走 libc。两套分配器各管各的，绝不交叉——rpmalloc 出来的指针必须用 rpfree 释放，libc 出来的指针必须用 libc free 释放。你写业务 C 代码时不要把 libc 分配的指针交给 xnet2lua 释放，反之亦然。

**yyjson 是个例外**——它在 HTTP/JSON API 场景里调用极频繁，所以特别处理过：`xlua/lua_xutils.c` 定义了一个 `g_xj_alc`（`yyjson_alc` 结构体）将 yyjson 内部的 `malloc/realloc/free` 全部走 `xmacro.h` 路由的同一套分配器。所以**yyjson 的 doc / 输出字符串都和项目其它内存来自同一个 rpmalloc 池**，统一统计、统一释放、无堆错配。如果你在自己代码里直接调 `yyjson_*_opts` / `yyjson_*_doc_new`，记得把 `&g_xj_alc` 传进去而不是 NULL；否则 doc 内存来自 libc，最终被路由后的 `rpfree` 释放 → 堆损坏（症状：进程退出时 Windows 0xC0000374）。

**开关**（默认开，详见 §2.1 / §2.2）：

| 入口 | 关闭方式 | 效果 |
|---|---|---|
| Makefile | `make WITH_RPMALLOC=0` | 宏退化为 libc 名字；`rpmalloc.c` 不参与链接 |
| build.bat | `build.bat norpmalloc` | 同上 |

`WITH_RPMALLOC=0` 时，`xmacro.h` 把 `rpmalloc_initialize / _finalize / _thread_initialize / _thread_finalize` 四个 lifecycle API 同时 stub 成 no-op，调用点无需 `#ifdef` 保护。适合用 AddressSanitizer / Valgrind 调内存问题、或做 rpmalloc vs libc 的对比压测。

**嵌入式使用约定**（§2.6 已含代码）：
- 主线程必须在 `xthread_init()` 之前调一次 `rpmalloc_initialize(NULL)`，进程退出前调一次 `rpmalloc_finalize()`。
- Worker 线程不需要管——框架的 `worker_func` 已经在线程入口/出口配对调用 `rpmalloc_thread_initialize / _finalize`。
- 跨线程 POST/RPC 的 buffer：sender 用 `xmacro.h` 路由后的 `malloc`，receiver 用同一套宏路由后的 `free`，rpmalloc 内部走 deferred-free 队列归还给 owner thread，**无需同步**。

> ⚠️ **MinGW + rpmalloc 已知陷阱**：rpmalloc 上游 `rpmalloc.c` 末尾默认 `#include "malloc.c"`，把 libc 的 `malloc/calloc/free` 符号全局替换。**MinGW 的 emulated TLS 内部用 `calloc` 分配 `_Thread_local` 存储**——首次访问任何 `_Thread_local` 变量就会触发 `calloc → rpcalloc → get_thread_heap → __emutls_get_address → calloc → ...` 无限递归，进程在 `main()` 跑起来**之前**就 `0xC00000FD` (stack overflow) 退出，**没有任何 stdout / stderr 输出**。本仓库的 `Makefile` 和 `build.bat` 已经强制带上 `-DENABLE_OVERRIDE=0` 规避。**如果你把构建系统迁到别处或自己写编译规则，务必保留这个宏**。MSVC 不受影响（它的 `__declspec(thread)` 不经过 calloc），但 `-DENABLE_OVERRIDE=0` 仍然该保留——否则 rpmalloc 会跟你自己代码里的其它分配器抢 CRT 符号。

> 💡 **小坑：3rd-party 头里的 `.free` / `.malloc` 字段**。函数式宏 `#define free(p) rpfree(p)` 遇到 `xxx.free(ctx, ptr)` 这样的字段调用会被错误展开（变成 `xxx.rpfree((ctx, ptr))`）。本仓库已知的中招点是 `3rd/yyjson.h` 里 `yyjson_alc` 的 `.free`/`.malloc` 字段。规则：**`xmacro.h` 必须在 `yyjson.h` 之后**才 include。如果你引入新的 3rd-party 头有同样字段命名，照此处理。

---

## 3. 程序入口与线程生命周期

### 3.1 线程脚本协议

每个 Lua 线程脚本（包括主线程脚本）必须返回一个**定义表**，包含以下生命周期回调：

```lua
-- 每个线程脚本的标准结构
local function __init()
    -- 线程启动时调用一次（可在此建立连接、创建子线程等）
    print("线程初始化")
end

-- 可选：只有脚本有 Lua 侧周期任务时才定义，例如定时器、
-- 重连检查或测试超时。
-- local function __update()
-- end

local function __uninit()
    -- 线程退出时调用（资源清理）
    print("线程退出")
end

local function __thread_handle(reply_router, k1, k2, k3, ...)
    -- 收到跨线程消息时调用（见第4章）
end

return {
    __init          = __init,
    -- __update     = __update,
    __uninit        = __uninit,
    __thread_handle = __thread_handle,
}
```

### 3.2 `__thread_handle` 消息分发模板

> 💡 **推荐**：直接使用 `scripts/core/share/xrouter.lua` 模块，可省去本节模板代码。
> 见 [3.3 xrouter 模块](#33-xrouter-模块推荐)。下面的手写模板仅作为
> 想了解底层协议或需要完全自定义分发行为时的参考。

这是手写消息分发的写法（兼容 POST 和 RPC 两种模式）：

```lua
_stubs = {}         -- 注册的消息处理函数表
_thread_replys = {} -- RPC 回复路由表（由框架内部使用）

-- 注册消息处理函数的便捷方法
function xthread.register(pt, handler)
    _stubs[pt] = handler
end

local function __thread_handle(reply_router, k1, k2, k3, ...)
    if reply_router then
        -- RPC 回复路由（框架内部处理，正常情况下不需要修改）
        local reply = _thread_replys[reply_router]
        if not reply then return end
        local h = _stubs[k3]  -- k3 是 pt（消息类型）
        if not h then
            reply(k1, k2, k3, false, "pt handle not found")
            return
        end
        local co = coroutine.create(function(...)
            if not reply(k1, k2, k3, pcall(h, ...)) then
                io.stderr:write("RPC reply failed\n")
            end
        end)
        coroutine.resume(co, ...)
    else
        -- POST 消息：k1 是 pt（消息类型）
        local h = _stubs[k1]
        if h then
            local co = coroutine.create(function() h(k2, k3, ...) end)
            coroutine.resume(co, ...)
        elseif k1 then
            io.stderr:write("no handler for pt=" .. tostring(k1) .. "\n")
        end
    end
end
```

### 3.3 `xrouter` 模块（推荐）

`scripts/core/share/xrouter.lua` 把 §3.2 的样板代码（`_stubs / _thread_replys /
__thread_handle` 与协程包装、RPC 回复路由）封装成一个小模块。

**两条核心设计原则：**

1. **统一 register**：注册端**不**关心对端用 POST 还是 RPC 调——同一个
   `pt` 在两种调用约定下都用 `register(pt, h)` 注册。dispatch 时按
   `reply_router` 是否为空来决定要不要发 reply：
   - 对端 `xthread.post(...)` → handler 跑完，返回值丢弃
   - 对端 `xthread.rpc(...)`  → handler 跑完，返回值变 reply `(true, ret...)`，抛错变 `(false, errmsg)`

   所有 handler 都在 coroutine 里跑，所以**任何** handler 都可以 yield
   （比如内部再 `xthread.rpc` 出去）。

2. **per-Lua-state 单例**：同一线程里多次 `dofile('scripts/core/share/xrouter.lua')`
   返回**同一张表**（仿 xhttp_router 的 `__xnet_xhttp_router` 模式），
   注册可散落在多个文件里都汇总到同一个 router。

线程脚本仍按 §3.1 的标准形态返回一张表，**只是把 `__thread_handle`
指向 `router.handle` 即可**：

```lua
-- worker.lua
local router = dofile('scripts/core/share/xrouter.lua')
router.set_log_prefix('MYAPP')                    -- 可选

-- 一律用 register 注册。注册端不关心对端 POST 还是 RPC。
router.register('print_msg', function(text)
    print('[MYAPP]', text)
end)

router.register('add', function(a, b)
    return a + b                                  -- 对端用 RPC 时变 reply
end)

router.register('do_lookup', function(key)
    local ok, val = xthread.rpc(xthread.REDIS, 'xredis_call', 1000, 'GET', key)
    return val                                    -- 内部可 RPC 出去（yield）
end)

-- 注册可以散落在其它文件里——它们 dofile 拿到的是同一个 router：
dofile('demo/handlers/login.lua')                 -- 内部 router.register(...)
dofile('demo/handlers/inventory.lua')             -- 内部 router.register(...)

local function __init()   assert(xnet.init())     end
local function __uninit() xnet.uninit()            end

return {
    __init   = __init,
    -- __update = __update, -- 仅在有 Lua 侧周期任务时打开
    __uninit = __uninit,
    __thread_handle = router.handle,    -- ← 只有这一行换写法
}
```

**API 一览：**

| 方法 | 用途 |
|---|---|
| `dofile('scripts/core/share/xrouter.lua')` | 返回 router 单例（同 state 内每次都是同一个对象） |
| `router.register(pt, h)` | 注册 handler；POST/RPC 都可触发；handler 跑在 coroutine 内、可 yield |
| `router.reset(opts)` | 清空所有注册和回调（测试隔离 / 显式 teardown 用） |
| `router.set_log_prefix(s)` | 修改日志前缀 |
| `router.set_unknown_post(fn)` | 未匹配到 POST handler 时的回退 `fn(pt, ...)` |
| `router.set_unknown_rpc(fn)` | 未匹配到 RPC handler 时的回退 `fn(reply_router, co_id, sk, pt, ...)` |
| `router.set_handler_error(fn)` | POST 协程顶层抛错的回调 `fn(pt, err)`（RPC 抛错自动 reply 不走这个） |
| `router.current_request()` | 当前协程是 RPC 调用时返回 req，POST 时返回 nil |
| `router.handle` | C runtime 调用的分发函数，直接赋给 `__thread_handle` |

**热 reload 友好性：**

- `router` 和 `router.handle` 是单例 → C runtime 抓的 `__thread_handle` ref 跨 reload 仍指向同一个分发闭包。
- 重新 `dofile` worker 脚本时，`router.register` 在原 stub 表上**就地覆盖**，新 handler 立即生效。
- 在飞 RPC 的 `rpc_context` 不会被清掉，已有协程的 reply 路径完整保留。
- 想清空状态请显式调 `router.reset()`——平时 reload 不需要。

**与 §3.2 手写模板的对应关系：**

- 旧的 `xthread.register(pt, h)` ≈ `router.register`。
- 旧的 `_stubs` / `_thread_replys` 由模块内部维护，不再需要全局变量。
- `__thread_handle` 字段直接赋为 `router.handle`，return 表的形态与 §3.1 一致。

参考 `demo/xlua_main.lua` 与 `demo/xlua_thread.lua` 的实际迁移示例
（执行 `./demo/xnet demo/xlua_main.lua` 可跑通完整的 POST + RPC + 反向 RPC
测试套件）。

### 3.4 退出程序

```lua
-- 正常退出（退出码 0）
xthread.stop(0)

-- 异常退出（退出码 1）
xthread.stop(1)
```

### 3.5 定时器：业务代码优先使用 `xtimerx`

`xtimer` 是每线程的原生底层定时器绑定；`scripts/core/share/xtimerx.lua` 是在其上提供的 reload-safe 业务封装。线程入口仍需调用一次 `xtimer.init(capacity)`，但可热重载的业务模块应使用 `xtimerx` 声明定时器：它按模块名和定时器名跟踪声明，在 reload 后将回调解析到新版模块，并在旧定时器下次触发时惰性清理未被重新声明的定时器。

底层 `xtimer` 适用于线程初始化、框架基础设施、测试脚本，或确实需要直接管理 timer handle 的代码。

**推荐：可热重载业务模块使用 `xtimerx`：**

```lua
-- game/player_timer.lua；此模块需要通过 require("game.player_timer") 加载
local xtimerx = dofile("scripts/core/share/xtimerx.lua")
local M = xtimerx("game.player_timer")

function M:on_tick(timer)
    print("tick")
end

M.timer_every("heartbeat", 1000, "on_tick")
M.timer_once("flush_once", 5000, "on_tick")

return M
```

reload 时先清除回调缓存，再重新加载业务模块：

```lua
local xtimerx = dofile("scripts/core/share/xtimerx.lua")
xtimerx.__reload()
package.loaded["game.player_timer"] = nil
require("game.player_timer")
```

曾经通过 `xtimerx` 声明过定时器的模块，即使新版已不再声明任何定时器，也必须保留 `xtimerx("模块名")` 的注册步骤，或显式调用 `xtimerx.cancel_module("模块名")`；否则旧 generation 的定时器无法被识别为已删除声明。

| `xtimerx` 接口 | 说明 |
|---|---|
| `M.timer_every(name, interval_ms, func_name, [repeat_num])` | 声明周期或有限次数定时器；缺省为无限重复 |
| `M.timer_once(name, interval_ms, func_name)` / `M.timer_delay(...)` | 声明一次性定时器 |
| `M.timer_cancel(name)` | 取消当前模块声明的一个定时器 |
| `xtimerx.__reload()` | reload 前清除旧回调缓存 |
| `xtimerx.cancel(module_name, name)` / `xtimerx.cancel_module(module_name)` | 按名称或模块显式取消定时器 |
| `xtimerx.__uninit()` / `xtimerx.dump()` | 清理所有 wrapper 定时器或打印诊断信息 |

**底层接口：直接使用 `xtimer`：**

```lua
local xtimer = require("xtimer")
xtimer.init(64)

local heartbeat = xtimer.add(1000, function(timer)
    print("tick at", xtimer.now_ms())
end, -1)                          -- -1 表示无限重复

xtimer.delay(5000, function()
    if heartbeat:active() then heartbeat:del() end
end)
```

| `xtimer` 接口 | 说明 |
|---|---|
| `xtimer.init([capacity])` / `xtimer.uninit()` | 初始化或释放当前线程的定时器集合 |
| `xtimer.add(interval_ms, callback, [repeat_num])` | 创建周期/有限次数定时器；`repeat_num=-1` 为无限次 |
| `xtimer.delay(interval_ms, callback)` | 创建一次性定时器 |
| `timer:active()` / `timer:del()` | 查询或取消定时器 handle |
| `xtimer.now_ms()` / `xtimer.now_us()` | 单调时钟时间，适合超时与耗时计算 |
| `xtimer.day_ms()` / `xtimer.day_us()` / `xtimer.format([ms])` | 日历时间及格式化输出 |
| `xtimer.update()` / `xtimer.last()` / `xtimer.show()` | 手动驱动/诊断接口；常规线程脚本通常无需手动调用 `update()` |

---

## 4. xthread 模块——多线程与消息传递

### 4.1 初始化

```lua
-- 初始化 xthread 模块（必须在任何其他 xthread 调用前执行）
xthread.init()
```

### 4.2 创建子线程

```lua
-- 动态创建一个新线程（在另一个独立的 Lua State 中运行脚本文件）
-- id:          线程 ID（整数，见第12章线程 ID 常量表）
-- name:        线程名称（调试用途）
-- script_path: Lua 脚本路径（相对于工作目录）
-- 返回：true，或 false + 错误信息
local ok, err = xthread.create_thread(id, name, script_path)
if not ok then
    error("创建线程失败: " .. tostring(err))
end
```

**示例：**

```lua
local WORKER_ID = 42

local ok, err = xthread.create_thread(WORKER_ID, "worker-thread", "scripts/worker.lua")
if not ok then error(err) end
```

### 4.3 关闭子线程

```lua
-- 请求关闭指定线程（会触发该线程的 __uninit 回调）
-- 返回：true，或 false + 错误信息
local ok, err = xthread.shutdown_thread(thread_id)
```

`shutdown_thread` 会把目标线程标记为退出、唤醒它，并等待该线程在自己的 OS 线程里完成清理流程。清理顺序包括关闭 wakeup fd、执行 Lua `__uninit`，最后 `lua_close`。即使线程刚创建就被关闭，wakeup 资源也会按创建时保存的 `xThread*` 清理，不依赖已经从 registry 移除后的 `xthread_current()`。

### 4.4 POST——异步消息（fire-and-forget）

```lua
-- 向目标线程异步投递消息，立即返回，不等待对方处理
-- target_id: 目标线程 ID
-- pt:        消息类型字符串（packet type）
-- ...:       任意数量的参数（会被 MessagePack 序列化）
-- 返回：true，或 false + 错误信息
local ok, err = xthread.post(target_id, pt, arg1, arg2, ...)
```

**示例：将接受的连接 fd 传给 worker 线程：**

```lua
xthread.post(WORKER_ID, "accepted_fd", fd, client_ip, client_port)
```

**在 worker 中注册处理函数：**

```lua
xthread.register("accepted_fd", function(fd, ip, port)
    print("收到新连接:", fd, ip, port)
    -- 在本线程中 attach 这个 fd
    local conn, err = xnet.attach(fd, my_handler, ip, port)
end)
```

### 4.5 RPC——同步远程调用

RPC 调用让当前协程挂起，等对端线程执行完处理函数后恢复，效果类似同步调用但不阻塞事件循环。

**调用端（必须在协程中执行）：**

```lua
-- 阻塞当前协程，等待对端执行完毕并返回结果
-- timeout_ms: 0 表示不设置超时；正数表示调用方等待上限
-- 返回：ok（bool）+ 对端 handler 的所有返回值
local ok, result1, result2 = xthread.rpc(target_id, pt, timeout_ms, arg1, arg2, ...)

if ok then
    print("RPC 成功，结果:", result1, result2)
else
    print("RPC 失败:", result1)  -- result1 是错误信息
end
```

**被调用端（注册 RPC handler，可有返回值）：**

```lua
xthread.register("add", function(a, b)
    return a + b           -- 返回值会通过 RPC 传回调用方
end)

-- 也支持多返回值
xthread.register("get_info", function(key)
    return "value", 42, true
end)
```

**完整 RPC 示例：**

```lua
-- 主线程：在初始化时通过协程发起 RPC
local function __init()
    -- 注意：RPC 必须在协程中调用
    _test_co = coroutine.create(function()
        local ok, sum = xthread.rpc(COMPUTE_ID, "add", 1000, 100, 200)
        if ok then
            print("100 + 200 =", sum)  -- 输出: 100 + 200 = 300
        end
        xthread.stop(0)
    end)
    coroutine.resume(_test_co)
end
```

### 4.6 获取当前线程信息

```lua
-- 获取当前线程 ID
local id = xthread.current_id()

-- 获取主线程 ID 常量
local main_id = xthread.MAIN   -- 值为 1
```

### 4.7 原生 Lua 调试器控制

这些 API 只有在构建时启用 `WITH_XDEBUG=1` 时可用；默认生产构建中会返回失败或空状态。

```lua
-- 运行中启动原生 Lua 调试服务。
-- port: 调试 TCP 端口，默认建议 19090。
-- wait: true 表示启用后让 Lua 线程在下一行停住；远程按需开启时通常传 false。
-- 返回：true + 描述信息，或 false + 错误信息。
local ok, msg = xthread.xdebug_start(19090, false)

-- 查询调试服务状态。
-- 返回：running(bool), port(number)
local running, port = xthread.xdebug_status()
```

典型用法是在 xadmin 的“执行脚本”页面中按需启动调试服务：

```lua
local ok, msg = xthread.xdebug_start(19090, false)
return ok, msg
```

服务启动后，当前执行脚本的 Lua 线程会立即启用调试；其它已注册 Lua 线程会在自己的下一次 update tick 中安全启用调试 hook，避免跨线程直接操作别的 `lua_State`。

### 4.8 日志

Lua 侧日志使用明确的 level API，不提供 `XLOGI/XLOGE` 这类宏风格函数：

```lua
xthread.log_info("server started: %s:%d", host, port)
xthread.log_system("config: workers=%d mode=%s", workers, mode)
xthread.log_warn("slow request", path, cost_ms)
xthread.log_error("request failed: %s", tostring(err))
```

可用接口：

| 方法 | 用途 |
|---|---|
| `xthread.log_init()` | 在当前 Lua 线程启用本线程独立日志文件，文件名使用线程创建时注册的名称 |
| `xthread.log_verbose(...)` | verbose 日志 |
| `xthread.log_debug(...)` | debug 日志 |
| `xthread.log_info(...)` | info 日志 |
| `xthread.log_system(...)` | system/lifecycle 日志，用于启动配置、reload、正常退出等重要状态 |
| `xthread.log_warn(...)` | warn 日志 |
| `xthread.log_error(...)` | error 日志 |
| `xthread.log_fatal(...)` | fatal 日志 |
| `xthread.set_level(level)` | 设置最小输出等级；例如 `4` 表示屏蔽 verbose/debug |
| `xthread.get_level()` | 返回当前最小输出等级 |

日志等级数值从 Android log priority 的 verbose/debug/info 起步：
`verbose=2`、`debug=3`、`info=4`、
`system=5`、`warn=6`、`error=7`、`fatal=8`。`set_level(5)` 会显示
system 及以上日志；`set_level(6)` 会进一步屏蔽 system，只保留 warn/error/fatal。

日志参数支持两种写法：

- 首参是格式串且参数足够时，会按 `string.format` 格式化；格式串消耗后的剩余参数用 `\t` 追加。
- 普通多参数写法按 `print` 风格用 `\t` 拼接。

```lua
xthread.log_info("user=%s score=%d", user, score, "trace", trace_id)
-- user=alice score=100    trace    trace-1

xthread.log_info("user", user, "score", score)
-- user    alice    score    100
```

每条日志默认写成一行。`print(...)` 会转为 `xthread.log_info(...)`，`io.stderr:write(...)` 会转为 error 日志。

**推荐初始化策略：**

- 主线程调用 `xthread.log_init()`，让主线程拥有自己的日志文件。
- 业务 worker 线程如果需要独立排查，也在自己的 `__init` 中调用 `xthread.log_init()`。
- 启动配置摘要、reload、正常退出等重要生命周期信息推荐用 `xthread.log_system(...)`。
- Redis / MySQL / NATS / HTTP 等服务类线程通常不要调用 `xthread.log_init`。这些线程里的 Lua 日志默认会先在本线程拼成完整日志记录，再投递到 main 线程，由 main 线程写入主日志文件。
- 服务类线程的业务异常优先返回给请求方，由请求方在自己的上下文里写日志；只有内部错误或无法归属到请求方的异常，才建议 post 到 main 线程统一记录。

### 4.9 队列背压与线程统计

线程消息队列可以设置上限，并读取当前深度，用于在生产环境中发现拥塞或主动降载：

```lua
-- 限制目标 worker 待处理消息数；达到上限时 post/rpc 会返回失败。
assert(xthread.set_queue_max(WORKER_ID, 4096))

local worker, err = xthread.stats(WORKER_ID)
if worker then
    print(worker.id, worker.name, worker.queue_depth, worker.queue_max)
end

for _, st in ipairs(xthread.all_stats()) do
    if st.queue_depth > st.queue_max * 0.8 then
        xthread.log_warn("queue near limit: %s %d/%d",
            st.name, st.queue_depth, st.queue_max)
    end
end
```

`xthread.stats(id)` 返回单线程的 `{ id, name, queue_depth, queue_max }`，找不到目标时返回 `nil, err`。`xthread.all_stats()` 返回所有已注册线程的统计数组；`scripts/xadmin/xadmin_app.lua` 的 `/api/stats` 就基于该接口聚合展示队列状态。

---

## 5. xnet 模块——异步网络

### 5.1 初始化

```lua
-- 初始化网络模块（在每个需要使用网络的线程中调用）
-- 返回：true，或 nil + 错误信息
assert(xnet.init())

-- 初始化后，C 层会把当前线程标记为有网络事件需求，
-- 并自动驱动 xpoll_poll()。只有 Lua 侧有周期任务时才需要 __update。

-- 关闭网络模块（在 __uninit 中调用）
xnet.uninit()

-- 获取当前使用的 I/O 后端名称（"epoll" / "kqueue" / "wsapoll" / "poll"）
local backend = xnet.name()

-- 仅在嵌入式或自驱动事件循环中手动轮询；通用 bin/xnet runner 会自动驱动
local ready_count = xnet.poll(10) -- 最多等待 10 ms
```

### 5.2 创建 TCP 监听服务器

```lua
-- 监听指定地址和端口，返回 listener 对象
-- host：绑定地址（nil 或省略 = 监听所有网卡）
-- port：端口号
-- handlers：事件回调表
local listener, err = xnet.listen_fd(host, port, {
    on_accept = function(listener, fd, ip, port)
        -- 有新连接到来，fd 是原始 socket fd
        -- 返回 true 表示接受，false 表示拒绝
        print("新连接:", ip, port)

        -- 通常将 fd 传给 worker 线程处理
        xthread.post(WORKER_ID, "new_conn", fd, ip, port)
        return true
    end,

    on_close = function(listener, reason)
        -- 监听套接字关闭时回调
        print("监听器关闭:", reason)
    end,
})

if not listener then
    error("监听失败: " .. tostring(err))
end
```

如果连接无需转交其它线程处理，可直接使用 `xnet.listen(host, port, handlers)`；它会在当前线程接受连接并为每条连接触发同一套 `on_connect` / `on_packet` / `on_close` handler。`listen_fd` 则用于将原始 fd 投递给 worker 的模型。

**listener 对象方法：**

```lua
-- 获取 listener 的文件描述符
local fd = listener:fd()

-- 关闭监听器
listener:close("reason")
```

### 5.3 连接到远程服务器

```lua
-- 异步 TCP 连接（非阻塞）
-- host：目标主机（IP 或域名）
-- port：目标端口
-- handlers：事件回调表
local conn, err = xnet.connect(host, port, {
    on_connect = function(conn, ip, port)
        -- 连接建立成功
        print("已连接到:", ip, port)
    end,

    on_packet = function(conn, data)
        -- 收到数据包（data 是 Lua string）
        print("收到数据:", #data, "字节")
    end,

    on_close = function(conn, reason)
        -- 连接关闭
        print("连接关闭:", reason)
    end,
})

if not conn then
    error("连接失败: " .. tostring(err))
end
```

### 5.4 接管已有的 fd（attach）

当主线程接受连接后将 fd 传给 worker 线程，worker 需要 attach 这个 fd：

```lua
-- 在 worker 线程中接管从主线程传来的 fd
-- fd：原始 socket 文件描述符
-- handlers：事件回调表（同 xnet.connect）
-- ip, port：对端地址（可选，用于记录）
local conn, err = xnet.attach(fd, handlers, ip, port)
-- 别名：xnet.connect_fd(fd, handlers, ip, port)
```

**完整 attach 示例：**

```lua
-- worker 线程中
xthread.register("new_conn", function(fd, ip, port)
    local conn, err = xnet.attach(fd, {
        on_connect = function(conn, ip, port)
            -- attach 成功后立即触发 on_connect
            -- 此时设置分包协议
            conn:set_framing({ type = "len32", max_packet = 4 * 1024 * 1024 })
        end,
        on_packet = function(conn, data)
            -- 处理收到的数据包
            handle_packet(conn, data)
        end,
        on_close = function(conn, reason)
            print("客户端断开:", reason)
        end,
    }, ip, port)

    if not conn then
        io.stderr:write("attach 失败: " .. tostring(err) .. "\n")
    end
end)
```

### 5.5 连接对象方法（conn）

```lua
-- 发送数据（遵循当前帧协议，自动加帧头）
-- 返回：true 成功，false 失败
local ok = conn:send(data)

-- 发送原始数据（不加帧头）
local ok = conn:send_raw(data)

-- 发送数据包（send 的别名）
local ok = conn:send_packet(data)

-- 发送 HTTP 文件响应（header + 文件内容，适合 HTTP 静态文件服务）
-- header：HTTP 响应头字符串
-- path：文件路径
-- offset：文件偏移（0 = 从头开始）
-- length：发送字节数（-1 = 整个文件）
local ok = conn:send_file_response(header, path, offset, length)

-- 设置帧协议及收发背压上限（见第6章）
conn:set_framing({
    type = "len32",
    max_packet = 16 * 1024 * 1024,
    max_send = 8 * 1024 * 1024,
    max_recv = 8 * 1024 * 1024,
})

-- 获取对端 IP 和端口
local ip, port = conn:peer()

-- 获取 socket fd
local fd = conn:fd()

-- 检查连接是否已关闭
local closed = conn:is_closed()

-- 关闭连接
conn:close("reason")

-- 更换事件处理回调表
conn:set_handler(new_handlers)
```

### 5.6 运行时统计

`xnet.get_stats()` 返回当前 Lua/网络线程的轻量运行时快照：

```lua
local st = xnet.get_stats()
print("fds", st.fd_count, "connections", st.conn_count)
print("closed-connection bytes", st.bytes_sent, st.bytes_recv)
print("timers", st.timer_count, "queue", st.queue_depth, st.queue_max)
```

| 字段 | 说明 |
|---|---|
| `fd_count` | 当前 poll loop 注册的 fd 数量 |
| `conn_count` | 当前线程活动中的普通 `xnet.connection` 连接数（不含 TLS wrapper） |
| `bytes_sent` / `bytes_recv` | 当前线程中已经关闭的普通 `xnet.connection` 累计收发字节数 |
| `timer_count` | 当前线程的活动定时器数 |
| `queue_depth` / `queue_max` | 当前线程消息队列深度及配置上限 |

该接口用于轻量诊断；若需要包含活动连接流量、HTTP 延迟或状态码分布，应在应用层继续采集指标。

### 5.7 随机数与帧级 AEAD

`xnet.random_bytes(n)` 从操作系统 RNG 返回 `1..4096` 字节的二进制 string。启用 `WITH_HTTPS=1` 的构建还可以对普通 framed 连接安装 AEAD 变换：

```lua
-- 每个方向使用独立 32-byte key；下面假设密钥已安全配置。
local send_key = configured_send_key
local recv_key = configured_recv_key
local my_salt = xnet.random_bytes(4)

-- 在协议握手中与对端交换 my_salt；peer_salt 是对端发来的 4 字节值。
conn:set_framing({ type = "len32", max_packet = 1024 * 1024 })
conn:enable_aead(send_key, recv_key, my_salt, peer_salt)
conn:send("encrypted application packet")

-- 仅在协议明确回退到明文时使用。
conn:disable_aead()
```

`conn:enable_aead(send_key, recv_key, send_salt, recv_salt)` 要求两个 key 各为 32 字节、两个 salt 各为 4 字节；同一 key/方向的 salt 不得重复。该功能保护 `xnet` 帧负载，不替代 TLS 的证书验证与标准握手。

### 5.8 目录扫描（用于静态文件服务）

```lua
-- 扫描目录，返回文件列表
-- root：目录路径
-- 返回：{ {rel="相对路径", path="完整路径"}, ... }，或 nil + err
local files, err = xutils.scan_dir("static/")
if files then
    for _, f in ipairs(files) do
        print(f.rel, f.path)
    end
end
```

---

## 6. 帧协议（分包策略）

TCP 是字节流，需要在应用层定义如何分包。xnet2lua 内置 raw、len16、len32 和 CRLF 帧协议，可以在连接建立后随时切换。

### 6.1 raw 模式（裸流）

不做任何分包，`on_packet` 收到的数据是任意大小的原始字节块。适合自定义协议或 HTTP 这类有自己解析逻辑的场景。

```lua
conn:set_framing({ type = "raw" })
-- 或者不调用 set_framing，默认即为 raw 模式
```

`on_packet` 回调返回值表示已消费的字节数（0 = 保留所有数据等待下次）：

```lua
on_packet = function(conn, data)
    -- raw 模式下，需要自己判断是否有完整数据包
    if #data < 4 then return 0 end  -- 数据不够，等待更多
    local consumed = process(data)
    return consumed  -- 告诉框架已消费多少字节
end
```

### 6.2 len32 模式（推荐，用于二进制协议）

每个数据包前加 4 字节大端序长度，框架自动完成分包。`on_packet` 收到的是完整的一个包。

```lua
conn:set_framing({
    type = "len32",
    max_packet = 4 * 1024 * 1024,  -- 最大包大小（字节），默认 16MB
})
```

发送时 `conn:send(data)` 会自动添加 4 字节长度头：

```lua
-- 发送端
conn:send(some_binary_data)  -- 框架自动加 4 字节长度前缀

-- 接收端 on_packet 收到的就是没有长度头的纯数据
on_packet = function(conn, data)
    local pt, arg1, arg2 = cmsgpack.unpack(data)
    -- ...
end
```

### 6.3 len16 模式（紧凑二进制协议）

`len16` 与 `len32` 相同，但长度前缀为 2 字节大端序，因此每个 payload 最大为 `65535` 字节。它适合小包为主、希望减少帧头开销的自定义协议。

```lua
conn:set_framing({
    type = "len16",
    max_packet = 65535,
    max_send = 8 * 1024 * 1024, -- 待发送缓存达到上限后 send 返回失败
    max_recv = 8 * 1024 * 1024, -- 接收缓存超限时暂停读取直到消费下降
})
```

若同时使用 `conn:enable_aead()`，AEAD 的序号/认证标签开销也包含在 `65535` 字节上限内，应为协议头和密文开销预留空间。

### 6.4 CRLF 模式（文本行协议）

以 `\r\n` 作为行结束符分包，适合 Redis 协议、SMTP 等文本协议。

```lua
conn:set_framing({
    type = "crlf",
    max_packet = 65536,
})
-- 每次 on_packet 收到一行数据（不含 \r\n）
```

### 6.5 自定义分隔符（crlf 扩展）

```lua
conn:set_framing({
    type = "crlf",
    delimiter = "\n",       -- 只用 \n 分行
    max_packet = 65536,
})
```

### 6.6 len32 + MessagePack 组合（最佳实践）

这是 xnet2lua 最常用的通信模式，实现高效的结构化数据传输：

```lua
local cmsgpack = require("cmsgpack")

-- 发送端：序列化消息类型 + 参数，send 自动加 4 字节长度头
local function send_msg(conn, pt, ...)
    local body = cmsgpack.pack(pt, ...)
    conn:send(body)
end

-- 使用示例
send_msg(conn, "login", user_id, token)
send_msg(conn, "chat", room_id, message)

-- 接收端：on_packet 收到完整数据包，解包后分发
on_packet = function(conn, data)
    local pt, arg1, arg2, arg3 = cmsgpack.unpack(data)
    local handler = handlers[pt]
    if handler then handler(conn, arg1, arg2, arg3) end
end
```

---

## 7. TLS / HTTPS 支持

需要编译时开启 HTTPS（`make WITH_HTTPS=1`），同时准备证书文件。

### 7.1 生成测试证书

```bash
# 生成自签名证书（测试用）
openssl req -x509 -newkey rsa:2048 -keyout server.key \
    -out server.crt -days 365 -nodes \
    -subj "/CN=localhost"
```

### 7.2 TLS 服务端（attach_tls）

在 worker 线程中，当收到新的 fd 并需要做 TLS 握手时：

```lua
-- 在 worker 线程中（需已 require xnet 和编译了 TLS）
local conn, err = xnet.attach_tls(fd, {
    -- TLS 配置
    cert_file = "demo/certs/server.crt",
    key_file  = "demo/certs/server.key",
    -- key_password = "optional_password",  -- 如果私钥有密码

    -- 同普通连接的事件回调
    on_connect = function(conn, ip, port)
        print("TLS 握手成功:", ip, port)
        conn:set_framing({ type = "len32" })
    end,
    on_packet = function(conn, data)
        handle_packet(conn, data)
    end,
    on_close = function(conn, reason)
        print("TLS 连接关闭:", reason)
    end,
}, client_ip, client_port)
```

### 7.3 TLS 连接对象方法

TLS 连接对象与普通连接对象接口相同：

```lua
conn:send(data)
conn:send_raw(data)
conn:send_file_response(header, path, offset, length)
conn:set_framing(opts)
conn:peer()
conn:fd()
conn:is_closed()
conn:close(reason)
conn:set_handler(handlers)
```

### 7.4 TLS 客户端（connect_tls）

`xnet.connect_tls(host, port, handlers [, tls_config])` 发起一个非阻塞的出站
TCP 连接，连接建立后以**客户端模式**完成 TLS 握手，再触发 `on_connect`。返回
一个 TLS 连接对象（与 §7.3 相同）或 `nil, err`。与 `attach_tls` 不同，客户端
无需提供证书与私钥——只对服务端做校验。

```lua
local conn, err = xnet.connect_tls("example.com", 443, {
    on_connect = function(conn, host, port)
        conn:send_raw("GET / HTTP/1.1\r\nHost: example.com\r\nConnection: close\r\n\r\n")
    end,
    on_packet = function(conn, data)
        accumulate(data)
        return #data
    end,
    on_close = function(conn, reason)
        print("已关闭:", reason)
    end,
}, {
    verify      = true,          -- 校验服务端证书（默认 true）
    -- ca_file  = "ca.pem",      -- 覆盖 CA；省略时使用 xlua/xnet_cacert.h 内置根证书
    server_name = "example.com", -- SNI 及证书名校验（默认取 host）
    -- max_packet / max_send     -- 与 attach_tls 相同的分帧参数
})
```

`tls_config` 字段：

| 字段 | 类型 | 默认 | 说明 |
|------|------|------|------|
| verify | bool | true | 是否校验服务端证书（`VERIFY_REQUIRED` 或 `VERIFY_NONE`） |
| ca_file | string | （内置） | PEM CA 文件；省略且 `verify=true` 时使用内置 CA 根证书 |
| server_name | string | host | SNI 主机名，同时用于证书名校验 |
| max_packet | number | 16MB | 单次交给 `on_packet` 的最大入站数据 |
| max_send | number | 10MB | 出站缓冲区上限 |

对于常见的 HTTP 场景，建议直接使用 §8.7 的高层客户端，而不是手工拼装
`connect_tls`。

---

## 8. HTTP 服务器

xnet2lua 提供了一套完整的 HTTP 服务器实现（纯 Lua，基于 xnet）。

### 8.1 快速启动 HTTP 服务

```lua
-- 在主线程的 __init 中
local xhttp = dofile("scripts/core/server/xhttp.lua")

local ok, err = xhttp.start({
    host         = "0.0.0.0",
    port         = 8080,
    worker_count = 4,             -- worker 线程数
    worker_name  = "api-worker",  -- worker 名称前缀，实际线程名为 api-worker-01、api-worker-02...
    app_script   = "my_app.lua",  -- 应用路由脚本路径
})

if not ok then error(err) end
```

HTTPS 配置：

```lua
local ok, err = xhttp.start({
    host         = "0.0.0.0",
    port         = 8443,
    https        = true,
    cert_file    = "certs/server.crt",
    key_file     = "certs/server.key",
    worker_count = 2,
    worker_name  = "api-worker",
    app_script   = "my_app.lua",
})
```

`xhttp.start` 完整配置项：

| 配置项 | 类型 | 默认值 | 说明 |
|--------|------|--------|------|
| `host` | string | "127.0.0.1" | 绑定地址 |
| `port` | number | 18080 | 监听端口 |
| `https` | bool | false | 是否启用 TLS |
| `cert_file` | string | "" | TLS 证书路径 |
| `key_file` | string | "" | TLS 私钥路径 |
| `key_password` | string | "" | 私钥密码（可选） |
| `worker_count` | number | 2 | worker 线程数量 |
| `worker_base` | number | xthread.WORKER_GRP3 | worker 线程起始 ID |
| `worker_name` | string | （必填） | worker 名称前缀，`xhttp` 会自动追加 `-01`、`-02` 等序号 |
| `worker_script` | string | "scripts/core/server/xhttp_worker.lua" | worker 脚本路径 |
| `app_script` | string | （必填） | 应用路由脚本路径（例如 "demo/xhttp_app.lua"） |
| `max_request_size` | number | 16MB | 最大请求体大小（字节）|
| `compression.enabled` | bool | true | 根据客户端 `Accept-Encoding` 对可压缩的响应体启用 gzip/deflate |
| `compression.min_size` | number | 256 | 小于此字节数的响应体不压缩 |
| `compression.level` | number | 6 | `xcompress` 压缩级别，范围 `0..12` |
| `decompress_requests` | bool | true | 解压 `Content-Encoding: gzip/deflate` 的请求体后再交给 handler |
| `max_decompressed_size` | number | `max_request_size` | 请求解压后的最大允许字节数 |

### 8.2 编写应用路由（app_script）

每个 worker 线程都会独立加载 `app_script`，因此路由注册在 worker 的 Lua State 中执行。

```lua
-- my_app.lua
local router = dofile("scripts/core/share/xhttp_router.lua")

-- 注册路由：GET /hello
router.get("/hello", function(req)
    local name = req.query.name or "world"
    return {
        status  = 200,
        body    = "Hello, " .. name .. "!\n",
        headers = { ["Content-Type"] = "text/plain; charset=utf-8" },
    }
end)

-- 注册路由：POST /echo
router.post("/echo", function(req)
    return { status = 200, body = req.body }
end)

-- 注册路由：POST /api/data（JSON 接口）
router.post("/api/data", function(req)
    -- req.body 是原始请求体字符串
    local ok, data = pcall(function()
        return xutils.json_unpack(req.body)
    end)
    if not ok then
        return { status = 400, body = "Invalid JSON\n" }
    end
    return {
        status  = 200,
        body    = xutils.json_pack({ result = "ok", received = data }),
        headers = { ["Content-Type"] = "application/json" },
    }
end)

-- 自定义 404 处理
router.config({
    not_found = function(req)
        return { status = 404, body = "Not Found: " .. req.path .. "\n" }
    end,
})

-- 注册静态文件目录
router.static_dir("static/", {
    prefix = "/static",   -- URL 前缀
    index  = "index.html",
    index_route = "/",    -- 默认首页路由
})

-- 必须返回 handle 函数供 worker 调用
return {
    handle = function(req)
        return router.handle(req)
    end,
}
```

### 8.3 request 对象字段

`on_packet` / handler 接收的 `req` 表包含以下字段：

| 字段 | 类型 | 说明 |
|------|------|------|
| `req.method` | string | HTTP 方法（"GET" / "POST" 等） |
| `req.path` | string | 请求路径（不含 query string）|
| `req.query` | table | URL 查询参数（`?name=foo` → `req.query.name = "foo"`）|
| `req.headers` | table | 请求头（键名已转为小写）|
| `req.body` | string | 请求体；开启请求解压且命中支持的 `Content-Encoding` 时为解压后数据 |
| `req.content_encoding` | string/nil | 框架实际解压的编码（`gzip` / `deflate`），未解压时为 nil |
| `req.version` | string | HTTP 版本（"1.1" / "1.0"）|

### 8.4 response 对象字段

handler 返回的响应表：

| 字段 | 类型 | 说明 |
|------|------|------|
| `status` | number | HTTP 状态码（200 / 404 / 500 等）|
| `body` | string | 响应体（与 `file` 二选一）|
| `file` | string | 静态文件路径（框架自动发送，与 `body` 二选一）|
| `headers` | table | 响应头（key-value 表）|

```lua
-- 返回 JSON
return {
    status  = 200,
    body    = '{"ok":true}',
    headers = { ["Content-Type"] = "application/json" },
}

-- 返回静态文件（零拷贝）
return {
    status  = 200,
    file    = "dist/index.html",
    headers = { ["Content-Type"] = "text/html; charset=utf-8" },
}

-- 返回错误
return { status = 500, body = "Internal Server Error\n" }
```

### 8.5 路由器 API

```lua
local router = dofile("scripts/core/share/xhttp_router.lua")

-- 注册 GET 路由
router.get(path, handler)

-- 注册 POST 路由
router.post(path, handler)

-- 注册 HEAD 路由
router.head(path, handler)

-- 通用注册（支持任意 method）
router.reg(method, path, handler)  -- method 不区分大小写
router.route(method, path, handler) -- 同上（别名）

-- 路径参数 / 通配符
--   :name      匹配单个路径段（不含 '/'），绑定到 req.params.name
--   *name      只能作为最后一段，匹配剩余全部路径，绑定到 req.params.name
--                （写成 '*' 时匿名通配，绑定到 req.params.path）
-- 静态路由仍走快速字典；动态路由失配时按注册顺序线性匹配。
router.get('/api/user/:id', function(req)
    return { status = 200, body = req.params.id }
end)
router.get('/static/*path', function(req)
    return { status = 200, body = req.params.path }
end)

-- 注册单个静态文件
router.reg_static_file(rel_path, disk_path, opts)

-- 注册整个目录为静态文件路由
router.reg_path(root_dir, {
    prefix      = "/static",    -- URL 前缀（可选）
    index       = "index.html", -- 目录默认文件名（可选）
    index_route = "/",          -- 默认首页路由（可选）
})
router.static_dir(root_dir, opts) -- 同上（别名）

-- 配置 404 处理等选项
router.config({
    not_found = function(req) return { status = 404 } end,
})

-- 分发请求
local response = router.handle(req)

-- 获取文件的 Content-Type
local ct = router.content_type_for("index.html")  -- "text/html; charset=utf-8"
```

### 8.6 HTTP 压缩与解压

默认 `xhttp` 会为接受 `gzip` 或 `deflate` 的客户端压缩大于等于 256 字节、且内容类型适合压缩的响应。已经设置 `Content-Encoding`、静态文件响应以及图片/音视频/压缩包等类型不会自动重复压缩。

```lua
assert(xhttp.start({
    port = 8080,
    worker_name = "api-worker",
    app_script = "my_app.lua",
    compression = { enabled = true, min_size = 1024, level = 6 },
    decompress_requests = true,
    max_decompressed_size = 4 * 1024 * 1024,
}))
```

客户端发送 `Content-Encoding: gzip` 或 `deflate` 时，handler 默认直接读取解压后的 `req.body`，并可通过 `req.content_encoding` 判断是否由框架执行了解压。需要直接操作压缩字节流或计算校验和时，使用下方的 `xcompress` 模块。

### 8.7 HTTP 客户端

`scripts/core/share/xhttp_client.lua` 是一个异步、基于回调的 HTTP/HTTPS 客户端，
运行在同一个 `xnet` 事件循环上。明文请求使用 `xnet.connect`，`https://` 请求使用
`xnet.connect_tls`（§7.4），因此需要 `WITH_HTTPS=1` 的构建。响应通过
`xhttp_codec.parse_response` 解析，因此 Content-Length、chunked 分块传输、
gzip/deflate `Content-Encoding`、以及 `Connection: close` 框定都能自动处理，
`3xx` 重定向也会自动跟随。

```lua
local httpc = dofile("scripts/core/share/xhttp_client.lua")

-- GET
httpc.get("https://example.com/", function(err, resp)
    if err then return print("error:", err) end
    print(resp.status, resp.headers["content-type"], #resp.body)
end)

-- 带选项的 POST
httpc.post("http://127.0.0.1:8080/echo", '{"hi":1}', {
    headers    = { ["Content-Type"] = "application/json" },
    timeout_ms = 5000,
}, function(err, resp)
    if err then return print("error:", err) end
    print(resp.body)
end)

-- 完整形式
httpc.request({
    url           = "https://api.example.com/v1/things",
    method        = "PUT",
    headers       = { ["Authorization"] = "Bearer ..." },
    body          = payload,
    timeout_ms    = 10000,
    max_redirects = 5,
    verify        = true,     -- TLS 证书校验（默认 true）
    -- ca_file    = "ca.pem", -- 覆盖 CA；省略时使用内置根证书
    decompress    = true,     -- 透明 gunzip/inflate（默认 true）
}, function(err, resp)
    -- ...
end)
```

`opts` 字段（用于 `request`；`get`/`post` 为其薄封装）：

| 字段 | 类型 | 默认 | 说明 |
|------|------|------|------|
| url | string | — | 绝对 URL；或改为提供 `scheme`/`host`/`port`/`path` |
| method | string | "GET" | HTTP 方法 |
| headers | table | nil | 额外请求头（缺省会自动补全 Host/User-Agent/Accept/Content-Length） |
| body | string | nil | 请求体 |
| timeout_ms | number | nil | 整体超时；仅在调用过 `xtimer.init()` 后生效 |
| max_redirects | number | 5 | 最多跟随的 `3xx` 重定向次数（0 表示不跟随） |
| verify | bool | true | TLS 证书校验（仅 https） |
| ca_file | string | （内置） | 覆盖 CA PEM 路径（仅 https） |
| decompress | bool | true | 发送 `Accept-Encoding` 并自动解码 gzip/deflate 响应 |

回调**只会触发一次**：失败时为 `cb(err)`，成功时为 `cb(nil, resp)`，其中
`resp = { status, version, headers, header_list, body }`，`headers` 的键为小写。
端到端示例见 `demo/xhttp_client_main.lua`，覆盖 Content-Length、重定向、chunked
与 gzip 响应。

---

## 9. cmsgpack 模块——MessagePack 序列化

MessagePack 是二进制格式的 JSON 替代，体积更小、解析更快，非常适合线程间或网络间的结构化数据传递。

```lua
local cmsgpack = require("cmsgpack")
```

### 9.1 序列化

```lua
-- 将多个 Lua 值序列化为一个 MessagePack 二进制 string
-- 支持：nil、boolean、integer、float、string、table（数组/字典）
local data = cmsgpack.pack(value1, value2, ...)

-- 示例
local blob = cmsgpack.pack("login", 12345, true, { level = 99 })
```

### 9.2 反序列化

```lua
-- 从 MessagePack 二进制 string 还原所有值
-- 返回序列化时的所有参数
local val1, val2, val3, ... = cmsgpack.unpack(data)

-- 示例
local pt, user_id, ok, extra = cmsgpack.unpack(blob)
-- pt = "login", user_id = 12345, ok = true, extra = { level = 99 }
```

### 9.3 典型用法——消息协议

```lua
-- 发送端（任意线程）
local function send_msg(conn, pt, ...)
    conn:send(cmsgpack.pack(pt, ...))
end

-- 接收端（on_packet 回调）
local function on_packet(conn, data)
    local args = table.pack(cmsgpack.unpack(data))
    local pt   = args[1]
    local handler = msg_handlers[pt]
    if handler then
        handler(conn, table.unpack(args, 2, args.n))
    end
end
```

---

## 10. xutils 模块——工具函数

```lua
local xutils = require("xutils")
```

### 10.1 JSON 处理

```lua
-- 序列化 Lua 值为 JSON 字符串
-- 依赖 yyjson，性能极高
local json_str = xutils.json_pack(value)

-- 将 JSON 字符串解析为 Lua 值
local value = xutils.json_unpack(json_str)

-- 示例
local str = xutils.json_pack({ name = "alice", score = 100, tags = {"vip", "active"} })
-- str = '{"name":"alice","score":100,"tags":["vip","active"]}'

local data = xutils.json_unpack(str)
print(data.name)   -- alice
print(data.score)  -- 100
```

编码规则：

- Lua 空表编码为 JSON object：`{}`。
- 正整数连续下标 `1..N` 的表编码为 JSON array；稀疏表、混合 key、字符串 key 表编码为 JSON object。
- 当前没有单独的 empty array sentinel；需要空数组语义时建议在协议层明确约定字段含义。
- `json_pack` / `json_unpack` 会为最大 JSON 嵌套深度预留 Lua C stack；过深或不支持的输入应返回 `nil, err`，避免破坏 Lua heap。JSON `null` 通过 `xutils.json_null` 往返。

---

## 10A. xcompress 模块——压缩与校验和

`xcompress` 由 `libdeflate` 实现，提供 gzip、raw deflate、zlib 包装格式以及 CRC-32 / Adler-32。HTTP 的 `Content-Encoding: deflate` 使用 zlib 包装格式，即 `zlib_compress` / `zlib_decompress`。

```lua
local xcompress = require("xcompress")
local text = string.rep("hello xnet\n", 100)

local gzip = xcompress.gzip(text, 6)
local plain, err = xcompress.gunzip(gzip, #text * 2)
assert(plain == text, err)

local zlib = xcompress.zlib_compress(text)
assert(xcompress.zlib_decompress(zlib, #text * 2) == text)

print(string.format("crc32=%08x adler32=%08x",
    xcompress.crc32(text), xcompress.adler32(text)))
```

反复处理数据时可以复用 handle，减少重复分配：

```lua
local c = xcompress.new_compressor(6)
local d = xcompress.new_decompressor()
local blob = c:gzip("payload")
local value = assert(d:gzip(blob, 1024))
c:set_level(9)
c:close()
d:close()
```

| 接口 | 说明 |
|---|---|
| `xcompress.gzip(data, [level])` / `gunzip(data, max_out)` | gzip 一次性压缩/解压 |
| `xcompress.deflate(data, [level])` / `inflate(data, max_out)` | raw deflate 一次性压缩/解压 |
| `xcompress.zlib_compress(data, [level])` / `zlib_decompress(data, max_out)` | zlib 包装格式一次性压缩/解压 |
| `xcompress.new_compressor([level])` | 创建可复用 compressor，支持 `gzip`、`deflate`、`zlib`、`level`、`set_level`、`close` |
| `xcompress.new_decompressor()` | 创建可复用 decompressor，支持 `gzip`、`deflate`、`zlib`、`close` |
| `xcompress.crc32(...)` / `crc32_update(current, ...)` | 计算或增量更新 CRC-32 |
| `xcompress.adler32(...)` / `adler32_update(current, ...)` | 计算或增量更新 Adler-32 |

解压 API 的 `max_out` 是强制输出上限；处理外部输入时应使用明确上限，避免压缩包造成不受控的内存增长。完整冒烟示例见 `demo/xcompress_main.lua` 和 `demo/xhttp_compress_main.lua`。

---

## 11. 配置文件

xnet2lua 支持通过 `.cfg` 文件管理运行时配置，格式为 `KEY=VALUE`，支持 `#` 注释。

### 11.1 配置文件格式

```ini
# xnet.cfg 示例
# SERVER_NAME=myserver #移动到启动参数中，为了支持配置共享

HTTP_HOST=0.0.0.0
HTTP_PORT=8080
HTTP_WORKERS=4

REDIS_HOST=127.0.0.1
REDIS_PORT=6379
REDIS_DB=0

MYSQL_HOST=127.0.0.1
MYSQL_PORT=3306
MYSQL_USER=root
MYSQL_PASSWORD=secret
MYSQL_DATABASE=mydb
```

### 11.2 在 Lua 中加载配置

```lua
-- 加载配置文件（通常在主线程 __init 最开始执行）
local ok, err = xutils.load_config("xnet.cfg")
if not ok then
    io.stderr:write("配置加载失败: " .. tostring(err) .. "\n")
end

-- 读取配置项（第二个参数为默认值）
local host    = xutils.get_config("HTTP_HOST", "127.0.0.1")
local port    = tonumber(xutils.get_config("HTTP_PORT", "8080")) or 8080
local workers = tonumber(xutils.get_config("HTTP_WORKERS", "2")) or 2
local debug   = xutils.get_config("DEBUG", "0") ~= "0"
```

### 11.3 命令行覆盖配置

运行时可在命令行追加 `KEY=VALUE` 覆盖配置文件中的值：

```bash
./xnet my_main.lua SERVER_NAME=prod HTTP_PORT=9090
```

---

## 12. 线程 ID 常量表

xnet2lua 预留了 0–99 的线程 ID 空间，其中 0–9 为特殊功能线程，10–99 为 worker 组。

| 常量名 | 值 | 说明 |
|--------|----|------|
| `xthread.MAIN` | 1 | 主线程 |
| `xthread.REDIS` | 2 | Redis I/O 线程 |
| `xthread.MYSQL` | 3 | MySQL I/O 线程 |
| `xthread.LOG` | 4 | 日志线程 |
| `xthread.IO` | 5 | 通用 I/O 线程 |
| `xthread.COMPUTE` | 6 | 计算线程 |
| `xthread.NATS` | 7 | NATS 消息队列线程 |
| `xthread.HTTP` | 8 | HTTP/HTTPS 服务线程 |
| `xthread.WORKER_GRP1` | 20 | worker 组1起始（20–39）|
| `xthread.WORKER_GRP2` | 40 | worker 组2起始（40–59）|
| `xthread.WORKER_GRP3` | 60 | worker 组3起始（60–79）|
| `xthread.WORKER_GRP4` | 80 | worker 组4起始（80–99）|
| `xthread.WORKER_GRP5` | 100| worker 组5起始（100–119）|

**建议：** 业务线程 ID 使用 100+ 范围以避免与预留 ID 冲突（注意 `XTHR_MAX = 100`，自定义线程 ID 需在 99 以内，建议修改 `XTHR_MAX` 后重新编译）。

---

## 13. 完整示例：TCP 服务器

以下示例实现一个支持多客户端的 TCP echo 服务器，主线程负责接受连接，worker 线程负责业务处理。

### 主线程脚本（tcp_main.lua）

```lua
-- tcp_main.lua - 主线程：监听端口，将连接分发给 worker

local WORKER_ID = 10
local HOST      = "0.0.0.0"
local PORT      = 9000

local listener
local worker_started = false

-- 标准消息分发模板
_stubs = {}
_thread_replys = {}

function xthread.register(pt, h) _stubs[pt] = h end

local function __thread_handle(reply_router, k1, k2, k3, ...)
    if reply_router then return end
    local h = _stubs[k1]
    if h then h(k2, k3, ...) end
end

-- worker 通知主线程结果
xthread.register("report", function(msg)
    print("[MAIN] worker 报告:", msg)
end)

local function __init()
    assert(xnet.init())

    -- 启动 worker 线程
    local ok, err = xthread.create_thread(WORKER_ID, "tcp-worker", "tcp_worker.lua")
    if not ok then error("启动 worker 失败: " .. err) end
    worker_started = true

    -- 开始监听
    listener = assert(xnet.listen_fd(HOST, PORT, {
        on_accept = function(_, fd, ip, port)
            print(string.format("[MAIN] 新连接: %s:%d fd=%d", ip, port, fd))
            -- 将 fd 投递给 worker 处理
            local ok, err = xthread.post(WORKER_ID, "new_conn", fd, ip, port)
            if not ok then
                io.stderr:write("[MAIN] post 失败: " .. tostring(err) .. "\n")
                return false
            end
            return true
        end,
        on_close = function(_, reason)
            print("[MAIN] 监听器关闭:", reason)
        end,
    }))

    print(string.format("[MAIN] 监听 %s:%d", HOST, PORT))
end

-- 这里没有 Lua 侧定时任务，因此省略 __update。

local function __uninit()
    if listener then listener:close("shutdown") end
    if worker_started then xthread.shutdown_thread(WORKER_ID) end
    xnet.uninit()
    print("[MAIN] 已关闭")
end

return {
    __init          = __init,
    -- __update     = __update,
    __uninit        = __uninit,
    __thread_handle = __thread_handle,
}
```

### Worker 线程脚本（tcp_worker.lua）

```lua
-- tcp_worker.lua - worker 线程：处理 TCP 连接和业务逻辑

local cmsgpack = require("cmsgpack")

local MAIN_ID = xthread.MAIN
local conns = {}  -- 管理所有活跃连接

_stubs = {}
_thread_replys = {}

function xthread.register(pt, h) _stubs[pt] = h end

local function __thread_handle(reply_router, k1, k2, k3, ...)
    if reply_router then return end
    local h = _stubs[k1]
    if h then h(k2, k3, ...) end
end

-- 接收从主线程传来的新连接 fd
xthread.register("new_conn", function(fd, ip, port)
    local conn, err = xnet.attach(fd, {
        on_connect = function(conn, ip, port)
            print(string.format("[WORKER] 客户端接入: %s:%d", ip, port))
            -- 设置 len32 分包协议，最大包 1MB
            conn:set_framing({ type = "len32", max_packet = 1024 * 1024 })
            conns[fd] = conn
        end,
        on_packet = function(conn, data)
            -- 解包：期望 (pt, payload)
            local pt, payload = cmsgpack.unpack(data)
            if pt == "echo" then
                -- echo 回去
                conn:send(cmsgpack.pack("echo_reply", payload))
            elseif pt == "ping" then
                conn:send(cmsgpack.pack("pong", os.time()))
            else
                io.stderr:write("[WORKER] 未知 pt: " .. tostring(pt) .. "\n")
            end
        end,
        on_close = function(conn, reason)
            local fd = conn:fd()
            conns[fd] = nil
            print("[WORKER] 客户端断开:", reason)
        end,
    }, ip, port)

    if not conn then
        io.stderr:write("[WORKER] attach 失败: " .. tostring(err) .. "\n")
    end
end)

local function __init()
    assert(xnet.init())
    print("[WORKER] 初始化完成")
    xthread.post(MAIN_ID, "report", "worker 就绪")
end

-- 这里没有 Lua 侧定时任务，因此省略 __update。

local function __uninit()
    -- 关闭所有活跃连接
    for _, conn in pairs(conns) do
        conn:close("worker_shutdown")
    end
    xnet.uninit()
    print("[WORKER] 已关闭")
end

return {
    __init          = __init,
    -- __update     = __update,
    __uninit        = __uninit,
    __thread_handle = __thread_handle,
}
```

运行：

```bash
./xnet tcp_main.lua
```

---

## 14. 完整示例：HTTP API 服务

### 主线程（http_server_main.lua）

```lua
-- http_server_main.lua

local xhttp = dofile("scripts/core/server/xhttp.lua")

local CONFIG_FILE = "xnet.cfg"
xutils.load_config(CONFIG_FILE)

_stubs = {}
_thread_replys = {}
function xthread.register(pt, h) _stubs[pt] = h end
local function __thread_handle(reply_router, k1, k2, k3, ...)
    if reply_router then return end
    local h = _stubs[k1]
    if h then h(k2, k3, ...) end
end

local function __init()
    assert(xnet.init())

    local ok, err = xhttp.start({
        host         = xutils.get_config("HTTP_HOST", "0.0.0.0"),
        port         = tonumber(xutils.get_config("HTTP_PORT", "8080")),
        worker_count = tonumber(xutils.get_config("HTTP_WORKERS", "4")),
        worker_name  = "api-worker",
        app_script   = "api_app.lua",
    })

    if not ok then error("HTTP 启动失败: " .. tostring(err)) end
    print("[SERVER] HTTP 服务已启动，按 Ctrl+C 退出")
end

-- 这里没有 Lua 侧定时任务，因此省略 __update。

local function __uninit()
    xhttp.stop()
    xnet.uninit()
end

return {
    __init = __init,
    -- __update = __update,
    __uninit = __uninit, __thread_handle = __thread_handle,
}
```

### 应用路由（api_app.lua）

```lua
-- api_app.lua - 每个 worker 线程独立加载此文件

local router = dofile("scripts/core/share/xhttp_router.lua")

-- 跨域头（可选）
local CORS_HEADERS = {
    ["Access-Control-Allow-Origin"]  = "*",
    ["Access-Control-Allow-Methods"] = "GET, POST, OPTIONS",
    ["Access-Control-Allow-Headers"] = "Content-Type",
}

local function json_response(status, data)
    local xutils = require("xutils")
    return {
        status  = status,
        body    = xutils.json_pack(data),
        headers = {
            ["Content-Type"] = "application/json; charset=utf-8",
            table.unpack(CORS_HEADERS),  -- 展开 CORS 头
        },
    }
end

-- GET /api/status
router.get("/api/status", function(req)
    return json_response(200, {
        ok      = true,
        time    = os.time(),
        version = "1.0.0",
    })
end)

-- POST /api/echo
router.post("/api/echo", function(req)
    local xutils = require("xutils")
    local ok, body = pcall(xutils.json_unpack, req.body)
    if not ok then
        return json_response(400, { error = "invalid json" })
    end
    return json_response(200, { echo = body })
end)

-- GET /api/user/:id（通过 query 参数模拟路径参数）
-- 访问：GET /api/user?id=123
router.get("/api/user", function(req)
    local id = tonumber(req.query.id)
    if not id then
        return json_response(400, { error = "missing id" })
    end
    -- 模拟查数据库
    return json_response(200, {
        id    = id,
        name  = "user_" .. id,
        level = math.random(1, 100),
    })
end)

-- OPTIONS（处理 CORS 预检）
router.reg("OPTIONS", "/api/echo", function()
    return { status = 204, headers = CORS_HEADERS }
end)

-- 静态文件（前端构建产物）
router.static_dir("dist/", { prefix = "/", index = "index.html" })

router.config({
    not_found = function(req)
        return json_response(404, { error = "not found", path = req.path })
    end,
})

return {
    handle = function(req) return router.handle(req) end,
}
```

---

## 15. 完整示例：跨线程 RPC

演示主线程和计算线程之间的双向 RPC 调用。

### 主线程（rpc_main.lua）

```lua
-- rpc_main.lua

local COMPUTE_ID = 99

_stubs = {}
_thread_replys = {}

function xthread.register(pt, h) _stubs[pt] = h end

-- 标准 __thread_handle（支持 RPC）
local function __thread_handle(reply_router, k1, k2, k3, ...)
    if not reply_router then
        local h = _stubs[k1]
        if h then
            local co = coroutine.create(function() h(k2, k3, ...) end)
            coroutine.resume(co, ...)
        end
        return
    end
    -- RPC 回复路由
    local reply = _thread_replys[reply_router]
    if not reply then return end
    local h = _stubs[k3]
    if not h then
        reply(k1, k2, k3, false, "pt not found")
        return
    end
    local co = coroutine.create(function(...)
        if not reply(k1, k2, k3, pcall(h, ...)) then
            io.stderr:write("RPC reply failed\n")
        end
    end)
    coroutine.resume(co, ...)
end

-- 主线程提供的 RPC 服务（供计算线程回调）
xthread.register("reverse_string", function(s)
    return string.reverse(tostring(s))
end)

local function run_tests()
    print("=== 开始 RPC 测试 ===")

    -- 测试1：简单 RPC 调用
    local ok, result = xthread.rpc(COMPUTE_ID, "add", 1000, 100, 200)
    assert(ok and result == 300, "add 测试失败: " .. tostring(result))
    print("[TEST1 通过] 100 + 200 =", result)

    -- 测试2：RPC 支持多返回值
    local ok, a, b = xthread.rpc(COMPUTE_ID, "divmod", 1000, 17, 5)
    assert(ok and a == 3 and b == 2, "divmod 测试失败")
    print("[TEST2 通过] 17 ÷ 5 = 商", a, "余", b)

    -- 测试3：计算线程回调主线程（RPC 链）
    local ok, reversed = xthread.rpc(COMPUTE_ID, "process_and_callback", 1000, "hello")
    assert(ok and reversed == "olleh", "callback 测试失败")
    print("[TEST3 通过] process_and_callback 返回:", reversed)

    print("=== 全部测试通过 ===")
    xthread.shutdown_thread(COMPUTE_ID)
    xthread.stop(0)
end

local function __init()
    local ok, err = xthread.create_thread(COMPUTE_ID, "compute", "rpc_compute.lua")
    if not ok then error(err) end

    -- 在协程中运行（因为 xthread.rpc 需要协程环境）
    local co = coroutine.create(run_tests)
    local ok, err = coroutine.resume(co)
    if not ok then
        io.stderr:write("测试失败: " .. tostring(err) .. "\n")
        xthread.stop(1)
    end
end

local function __uninit() end

return {
    __init = __init,
    -- __update = __update,
    __uninit = __uninit, __thread_handle = __thread_handle,
}
```

### 计算线程（rpc_compute.lua）

```lua
-- rpc_compute.lua

local MAIN_ID = xthread.MAIN

_stubs = {}
_thread_replys = {}

function xthread.register(pt, h) _stubs[pt] = h end

local function __thread_handle(reply_router, k1, k2, k3, ...)
    if not reply_router then
        local h = _stubs[k1]
        if h then h(k2, k3, ...) end
        return
    end
    local reply = _thread_replys[reply_router]
    if not reply then return end
    local h = _stubs[k3]
    if not h then reply(k1, k2, k3, false, "pt not found"); return end
    local co = coroutine.create(function(...)
        if not reply(k1, k2, k3, pcall(h, ...)) then
            io.stderr:write("RPC reply failed\n")
        end
    end)
    coroutine.resume(co, ...)
end

-- 提供 add 服务
xthread.register("add", function(a, b)
    return a + b
end)

-- 提供 divmod 服务（多返回值）
xthread.register("divmod", function(a, b)
    return math.floor(a / b), a % b
end)

-- 提供 process_and_callback 服务（在此函数中 RPC 回调主线程）
xthread.register("process_and_callback", function(s)
    -- 计算线程 RPC 调用主线程的 reverse_string（嵌套 RPC）
    local ok, reversed = xthread.rpc(MAIN_ID, "reverse_string", 1000, s)
    if not ok then error("callback RPC 失败: " .. tostring(reversed)) end
    return reversed
end)

local function __init() print("[COMPUTE] 初始化") end
local function __uninit() print("[COMPUTE] 退出") end

return {
    __init = __init,
    -- __update = __update,
    __uninit = __uninit, __thread_handle = __thread_handle,
}
```

---

## 16. 最佳实践与注意事项

### 线程设计

- **主线程只管分发**：主线程负责 `listen_fd` 并通过 `xthread.post` 将 fd 传给 worker，不做任何业务逻辑
- **每个线程调用 `xnet.init()`**：每个使用网络的线程都需要独立初始化 xnet；之后 C 层会为该线程驱动网络轮询
- **省略空的 `__update` 回调**：只有 Lua 侧确实有周期任务时才定义，例如定时器、重连检查或测试超时
- **不要跨线程传递连接对象**：`conn` 对象属于创建它的 Lua State，不能通过消息传递到另一线程

### 消息传递

- **POST 适合通知类消息**：不需要返回值，开销最小
- **RPC 必须在协程中调用**：`xthread.rpc` 会 yield 当前协程，不能在主线程的同步代码中直接调用（需要先用 `coroutine.create` 包装）
- **RPC 支持嵌套调用**：计算线程可以在处理 RPC 时再回调主线程，框架会正确处理协程恢复

### 网络

- **连接建立后立即设置帧协议**：在 `on_connect` 回调中调用 `conn:set_framing()`
- **len32 + cmsgpack 是最推荐的组合**：二进制高效，且天然解决分包问题
- **发送失败时检查返回值**：`conn:send()` 返回 false 表示发送失败（通常是对方已断开）
- **on_close 中不要再 send**：连接已关闭，send 操作会失败

### 错误处理

```lua
-- 推荐的错误处理模板
local ok, err = xthread.post(WORKER_ID, "do_work", data)
if not ok then
    io.stderr:write("post 失败: " .. tostring(err) .. "\n")
    return
end

-- RPC 错误处理
local ok, result = xthread.rpc(TARGET_ID, "compute", 1000, arg)
if not ok then
    io.stderr:write("RPC 失败: " .. tostring(result) .. "\n")
    -- result 在失败时是错误字符串
end
```

### 性能调优

| 场景 | 建议 |
|------|------|
| 高并发连接 | 增加 worker 线程数（通常 CPU 核数 * 1–2） |
| 大数据包 | 增大 `max_packet`，考虑分片发送 |
| 低延迟 | 减少 Lua 侧 `__update` 工作量；必要时调整 C 层轮询节奏 |
| 高吞吐 | 使用 `conn:send_raw()` + 手动分包，减少内存拷贝 |
| 静态文件 | 使用 `conn:send_file_response()`，框架内部使用 sendfile 优化 |

### 常见问题

**Q: RPC 调用没有响应？**  
A: 检查被调用线程是否正确注册了 `_thread_replys` 表并在 `__thread_handle` 中处理了 reply_router 分支。

**Q: `xthread.rpc` 报错"must be called from a coroutine"？**  
A: `rpc` 只能在协程中调用。在 `__init` 中用 `coroutine.create` + `coroutine.resume` 包装。

**Q: 网络连接偶尔丢包？**  
A: 确认 `on_packet` 的返回值正确（raw 模式需要返回消费字节数），并确认 `conn:send()` 的返回值没有被忽略。

**Q: Windows 下编译失败？**  
A: 确认安装了 MSVC 或 MinGW，Makefile 会自动检测平台并链接 `ws2_32.lib`。

**Q: 如何支持超过 99 个线程？**  
A: 修改 `xthread.h` 中的 `XTHR_MAX` 宏并重新编译。注意修改后所有使用 xthread 的代码都需要重编。

---

## 17. xadmin 控制台

`scripts/xadmin/` 是一个完整的最小管理面：HTTP 路由 + 多进程节点发现 + 远程脚本执行 + 远程热重载。它同时是 §18（xnats 跨进程 RPC）和 §19（热重载协议）的端到端示例。

### 17.1 整体架构

```
┌──────────── xadmin1 ────────────┐         ┌──────────── xadmin2 ────────────┐
│  MAIN ──── listener (18091)     │   NATS   │  MAIN ──── listener (18092)     │
│   │                              │  ←───→   │   │                              │
│   ├── xnats-worker (NATS I/O)   │ wire 4222│   ├── xnats-worker              │
│   └── xhttp-worker (HTTP I/O)   │          │   └── xhttp-worker              │
└─────────────────────────────────┘          └─────────────────────────────────┘
```

关键设计点：

- **HTTP 连接跑在 per-fd session coroutine** 内。`scripts/core/share/xsession.lua` 为每个 fd 创建一个 session 协程；同一连接上解出的完整 HTTP 请求会排进该 session 队列，并在收到请求或 yielding RPC 回来时 resume。这样 handler 仍然可以同步式写法直接调 `xnats.rpc(...)` / `xthread.rpc(...)`，同时保持 HTTP/1.1 pipelining 响应顺序。socket 关闭后，session 会继续处理队列中已解出的请求，但会跳过响应发送，因为此时 fd 可能已经不可写。
- **本机 RPC 经 caller 端短路**：xnats.rpc(self, ...) 不经过 NATS wire，直接 `xthread.rpc` 落到本地业务 worker，详见 §18.4。
- **状态跨 reload 持久化**：连接表、peer 缓存、in-flight RPC context 都存 `_G`，reload 顶层 dofile 不影响它们。

### 17.2 启动 NATS

```bash
nats-server -p 4222
```

### 17.3 构建

```bash
make                       # MSYS2/MinGW / Linux / macOS
# 或
build.bat                  # Windows / MSVC
```

### 17.4 启动 xadmin 节点

每个节点要有**唯一的** `SERVER_NAME` 和端口：

```bash
bin/xnet.exe scripts/xadmin/xadmin_main.lua SERVER_NAME=xadmin1 XADMIN_PORT=18091
bin/xnet.exe scripts/xadmin/xadmin_main.lua SERVER_NAME=xadmin2 XADMIN_PORT=18092
```

节点通过 NATS broadcast 主题互相发现，作为 peer 出现在对方 `/api/peers` 的结果里（默认心跳 5s，TTL 15s）。

### 17.5 HTTP API

| 路径 | 方法 | 鉴权 | 说明 |
|---|---|---|---|
| `/api/peers` | GET | 否 | 本节点 + 通过 heartbeat 发现的其他节点 |
| `/api/stats` | GET | 否 | 所有线程的 queue depth 等运行时统计 |
| `/api/exec` | POST | 可选 | 在指定节点跑一段 Lua（见 17.6） |
| `/api/reload` | POST | 可选 | 热重载本节点 / 指定节点 / 所有节点（见 17.7） |

设置 `XADMIN_TOKEN=...` 后，`/api/exec` 与 `/api/reload` 要求请求头 `X-Xadmin-Token: <token>`。`/api/peers`、`/api/stats` 始终公开。

### 17.6 远程执行 `/api/exec`

请求体：`{"target": "self"|"name"|"name:N", "script": "..."}`。

```bash
# 本机（caller 端短路，不进 NATS wire）
curl -X POST http://127.0.0.1:18091/api/exec \
  -H 'Content-Type: application/json' \
  -d '{"target":"self","script":"return 1+2, xthread.current_id()"}'
# → {"ok":true,"target":"xadmin1","stdout":"","result":"3\t1"}

# 跨进程（走 NATS）
curl -X POST http://127.0.0.1:18091/api/exec \
  -H 'Content-Type: application/json' \
  -d '{"target":"xadmin2","script":"return os.time()"}'
# → {"ok":true,"target":"xadmin2","stdout":"","result":"<timestamp>"}
```

底层走 xrouter 的 `@run_script` builtin。返回 `result` 是脚本顶层 `return` 的值以制表符拼接，`stdout` 是脚本内 `print` 收集到的输出。

### 17.7 远程热重载 `/api/reload`

请求体：`{"target": "self"|"all"|"name"}`。

```bash
# 仅 reload 本节点
curl -X POST http://127.0.0.1:18091/api/reload \
  -H 'Content-Type: application/json' -d '{"target":"self"}'

# reload 指定节点（跨进程）
curl -X POST http://127.0.0.1:18091/api/reload \
  -H 'Content-Type: application/json' -d '{"target":"xadmin2"}'

# 一次 reload 所有发现的节点（本节点 + 所有 peers）
curl -X POST http://127.0.0.1:18091/api/reload \
  -H 'Content-Type: application/json' -d '{"target":"all"}'
```

返回示例：

```json
{
  "ok": true,
  "target": "all",
  "results": [
    {"target":"xadmin1","ok":true,"result":"current=1 notified=1 deferred=2"},
    {"target":"xadmin2","ok":true,"result":"current=1 notified=1 deferred=2"}
  ]
}
```

`current` / `notified` / `deferred` 含义见 §19.4。reload 不重启进程；新代码立即生效。状态持久化机制见 §19.2。

### 17.8 端到端验证（推荐冒烟测试）

```bash
# 1. 启 xadmin1 + xadmin2 + NATS
# 2. 编辑 scripts/xadmin/xadmin_app.lua，给 /api/peers 响应加一个 marker 字段
# 3. 在 xadmin1 发: curl POST /api/reload {target:"all"}
# 4. curl http://127.0.0.1:18091/api/peers  → 看到 marker
# 5. curl http://127.0.0.1:18092/api/peers  → 也看到 marker（说明跨进程 reload 成功）
# 6. 撤回编辑 + 再 reload all → marker 消失
```

整个过程不重启 xnet 进程。

---

## 18. xnats 跨进程 RPC

`scripts/core/server/xnats.lua` + `scripts/core/server/xnats_worker.lua` 用 NATS 协议做跨进程消息传输，提供 `publish`（broadcast）和 `rpc`（同步式调用）两种语义。所有 NATS I/O 集中在 `xthread.NATS` 线程，业务线程只通过 xthread.post/rpc 与之通信。

### 18.1 启动

```lua
local xnats = dofile('scripts/core/server/xnats.lua')

xnats.start({
    host    = '127.0.0.1',
    port    = 4222,
    name    = 'game1',                                 -- 本进程唯一标识
    prefix  = 'xnet.test',                             -- NATS subject prefix
    workers = { xthread.MAIN, xthread.WORKER_GRP3 },   -- 业务 worker 线程 ID
    reconnect_ms   = 1000,
    rpc_timeout_ms = 10000,
})
```

`workers` 列表既是：

- **inbound 路由表**：远端 `xnats.rpc("game1:N", pt, ...)` 会被本地 NATS 线程转发到 `workers[N]`（1-based）；不带 `:N` 时按 round-robin 选一个。
- **本机短路路由表**：见 18.4。

### 18.2 把路由信息推到 worker 线程

`xnats.start` 在调用线程（通常是 MAIN）调过 `xnats.bind_local`，但其他业务线程的 Lua state 是隔离的，需要显式推送：

```lua
-- 主线程：xhttp.start(...) 之后
xnats.bind_workers(xhttp.worker_ids())
```

`bind_workers` 给每个目标线程 POST 一条 `xnats_bind_local`，目标线程的 `xnats.lua` 顶层注册的 handler 会把 `self_name` 和 `worker_threads` 写进**该线程**的 `_G.__xnet_xnats_state`，使本线程的 `xnats.rpc` 短路能力上线。

### 18.3 统一返回形状

```lua
local channel_ok, app_ok, ret1, ret2, ... = xnats.rpc(target, pt, ...)
```

- `channel_ok == false`：通道层失败（连不上、超时、目标进程未发现、本机短路时找不到 handler）。第二个返回值是错误描述。
- `channel_ok == true`：通道完成。`app_ok` 是被调 handler 的第一个返回值（按惯例是 boolean），其后是其余返回值。

**本机短路与 NATS wire 形状一致**，调用方不需要区分路径。例如 handler `return true, "done"` 时两种路径都得到 `(true, true, "done")`。

```lua
xthread.register('do_lookup', function(key)
    -- ... lookup ...
    return true, value
end)

-- 调用端：
local channel_ok, app_ok, value = xnats.rpc('peer:1', 'do_lookup', 'foo')
if not channel_ok then
    io.stderr:write('channel: ' .. tostring(app_ok) .. '\n')
elseif not app_ok then
    io.stderr:write('app: ' .. tostring(value) .. '\n')
else
    print('got', value)
end
```

### 18.4 caller 端本机短路

`xnats.rpc(target, pt, ...)` 解析 target：

1. process name == `state.self_name` → 跳过 NATS，直接 `xthread.rpc(local_worker_tid, pt, 0, ...)`。
2. 否则 → 走 NATS 线程，序列化到 wire。

短路前提是该线程已被 bind_local（自己调过 `xnats.start`，或被 `bind_workers` 推过 `xnats_bind_local`）。**未 bind 的线程会自动降级到 NATS wire**，功能不受影响、只是多一跳。

当本机短路时如果目标 thread id 就是当前线程，xnats.rpc 不会走 xthread.rpc（会死锁），而是直接查 stub 并 `pcall(h, ...)`，结果照 unified shape 包好返回。

### 18.5 target 格式

- `"name"` → 在 workers 列表上 round-robin 选一个。
- `"name:N"` → 1-based index，选 `workers[N]`。
- 错误的 N 会得到 `channel_ok=false, "xnats: local worker idx out of range: N"`（或远端的同名错误）。

### 18.6 publish (broadcast)

```lua
xnats.publish(pt, arg1, arg2, ...)
```

广播到 `prefix .. '.broadcast'`。所有订阅了该 prefix 的进程的 NATS 线程会再向本进程 `workers` 列表中的所有业务线程 POST 这个 pt。

---

## 19. 热重载协议

xnet2lua 内置一套**不重启进程**的脚本热重载机制：每个线程的 Lua 顶层被重新 `dofile`，新闭包就地生效，正在飞的协程不丢。

### 19.1 reload 做什么、不做什么

**reload 时**：

- 对每个目标线程：调 `xnet.__reload()`（C 暴露的 builtin），它执行 `luaL_dofile(thread_script)` 重跑脚本顶层。
- 主线程额外刷新 `__tick_ms`、`__update`、`__uninit`、`__thread_handle` 的 ref。
- xrouter 是 singleton，`router.register(pt, h)` 在原 stub 表上**就地覆盖**——新闭包从下一条消息起生效。
- xhttp_router、xnats 等模块的 state 表通过 `_G[STATE_KEY]` 持久化，新代码读到老数据。

**reload 不做的事**：

- **不重跑 `__init`**——避免重复建监听、重复 `xnet.init()` 等一次性副作用。
- **不释放 in-flight coroutine**——xrouter 的 `rpc_context` 和 C 端 pending 表会持有它们直到 reply 完成；新代码的顶层 dofile 不会触碰这些表。
- **不修改线程 ID / 进程结构**——线程总数、worker 分配不变。

### 19.2 状态跨 reload 持久化

reload 让 module-local 变量（`local connections = {}`）变成**新表**。旧 coroutine 持有的旧引用与新代码读到的新引用**不再是同一张表**，会产生不一致。

正确做法是把需要跨 reload 的状态存到 `_G`：

```lua
local STATE_KEY = '__myapp_state'
local state = rawget(_G, STATE_KEY)
if type(state) ~= 'table' then
    state = {}
    rawset(_G, STATE_KEY, state)
end
if type(state.connections) ~= 'table' then state.connections = {} end
if state.counter == nil then state.counter = 0 end

-- 然后业务用 local alias：
local connections = state.connections    -- 新旧代码、新旧协程都看到同一张表
```

`xhttp.lua` / `xnats.lua` / `xnats_worker.lua` / `xadmin_worker.lua` / `xsession.lua` / `xrouter.lua` / `xhttp_router.lua` 全部按这个模式写——可参考实现。其中 `xsession.lua` 支持调用方传入共享的 `connections` 表，用于 reload 后保留 fd/session 状态。

### 19.3 触发 reload 的三条路径

#### 路径 1：xadmin HTTP（推荐用于运维）

见 §17.7。

#### 路径 2：直接 POST `@reload_thread` 给单个线程

```lua
xthread.post(target_tid, '@reload_thread')
```

`@reload_thread` 由 C 端在 thread message handler 里**直接拦截**，调 `xnet.__reload()` 重 dofile，不进 Lua handler 路径。

#### 路径 3：RPC `@reload` 让目标进程协调全进程 reload

```lua
local channel_ok, app_ok, msg = xnats.rpc('peer_or_self', '@reload')
-- msg 形如 "current=1 notified=2 deferred=2"
```

`@reload` 是 xrouter 内置 builtin（见 `scripts/core/share/xrouter.lua`）。它在目标进程的一个业务 worker 上跑，广播 `@reload_thread` 到本进程所有线程，并把若干**需要延迟**的线程加进 defer 集合。

### 19.4 defer 语义

`@reload` 协调器构造 defer 集合：

| 入选条件 | 为什么 |
|---|---|
| **reply_router 的线程** | 这条 RPC 的应答还没发出去；该线程要先把 reply 写出再 reload |
| **当前 handler 所在线程** | 自己 reload 会破坏正在跑的 handler 上下文 |
| **explicit_defer_id**（可选） | 调用方明确指定的额外需要延迟的线程 |

defer 集合里的线程不立即收到 `@reload_thread`；它们的 reload 挂在 `req.after_reply` 钩子上——RPC reply 已发出之后，再 post `@reload_thread`。

返回 message 的格式：

```
current=<current_thread_id> notified=<count> deferred=<count>
```

- `current`：跑 @reload 这次 handler 的业务 worker 线程 id。
- `notified`：被**立即** post `@reload_thread` 的线程数。
- `deferred`：通过 after_reply 钩子延迟 reload 的线程数。

### 19.5 让自己的模块 reload 安全的清单

1. **顶层只做 dofile-safe 的事**：注册 handler、把状态写到 `_G`、定义路由——不要建 socket、不要 `xnet.init()`。
2. **一次性副作用放 `__init`**：监听 socket、`xnet.init()`、`xtimer.init(...)` 等。
3. **跨 reload 的状态走 `_G[STATE_KEY]`**：连接表、计数器、计时器、缓存等。
4. **handler 注册走 `xthread.register(pt, h)` 或 `router.register(pt, h)`**：两者都基于 xrouter singleton，自动支持"reload 时就地覆盖"。
5. **顶层 `local foo = state.foo` 模式**：让新旧代码、新旧协程引用同一张子表。
6. **协程化的请求 dispatch**：让 yielding API（`xnats.rpc` / `xthread.rpc` / `xtimer` 回调）可以在 handler 内同步式调用，reply / 响应通过 coroutine 自然回到 IO 层。推荐参考 `scripts/core/share/xsession.lua` 与 `scripts/xadmin/xadmin_worker.lua`：每个 fd 一个 session 协程，完整请求入队后 resume；关闭事件到来时先 drain 队列，fd 不可发送时跳过响应并走资源回收。
7. **冒烟测试**：改一行业务代码 → 调 `/api/reload {target:"self"}` → 看新行为生效 → 撤回 + reload → 看新行为消失。不重启进程。

---

## 20. Lua 调试与 VSCode 调试

xnet2lua 提供一套原生 Lua 调试器，用来调试多 OS 线程、多 `lua_State`、多 coroutine 的运行时。它不依赖 `Local Lua Debugger`，而是在进程内启动一个本地 TCP 调试服务，再由 `tools/xdebug_dap.exe`（Windows）或 `tools/xdebug_dap`（Unix-like）把它转换成 VSCode Debug Adapter Protocol。旧的 `tools/xdebug_dap.js` Node 桥仍保留作备用。

### 20.1 文件与职责

| 文件 | 作用 |
|---|---|
| `xlua/lua_xdebug.c` / `xlua/lua_xdebug.h` | C 层原生调试核心，负责 TCP 服务、断点、单步、栈、局部变量、线程状态 |
| `tools/xdebug_dap.c` / `tools/xdebug_dap.exe` | VSCode DAP 桥，使用 `xpoll`/epoll 监听 DAP 端口 |
| `tools/xdebug_dap.js` | 旧版 Node.js DAP 桥，作为无 C 桥产物时的备用 |
| `.vscode/launch.json` | VSCode attach 配置 |
| `.vscode/tasks.json` | 启动 DAP 桥的后台任务 |
| `xdebug.md` | 调试器简版说明与原始 TCP 协议 |

### 20.2 构建

默认 `make` 会构建工具和普通 `bin/xnet`，其中普通 `bin/xnet` 不包含调试器，但会生成 DAP 桥 `tools/xdebug_dap.exe`（Windows）或 `tools/xdebug_dap`（Unix-like）：

```bash
make
```

只编 DAP 桥：

```bash
mingw32-make xdebug_dap
```

要把调试能力编进 `bin/xnet`，同时默认构建 DAP 桥：

```bash
mingw32-make -B BUILD_MODE=debug WITH_HTTPS=0 WITH_XDEBUG=1
```

LuaJIT 后端也支持：

```bash
mingw32-make -B BUILD_MODE=debug WITH_HTTPS=0 WITH_XDEBUG=1 LUA_BACKEND=luajit
```

MSVC：

```bat
build.bat debug nohttps xdebug xnet
```

含义要分清：

| 开关 | 阶段 | 含义 |
|---|---|---|
| `WITH_XDEBUG=1` | 编译期 | 把调试器编进程序，不会自动启动服务 |
| `XDEBUG_BOOT=1` | 启动期 | 进程启动时自动启动调试服务 |
| `xthread.xdebug_start(...)` | 运行期 | 进程已运行后按需启动调试服务 |

旧的 `XDEBUG=1` 不再作为启动开关使用。

### 20.3 启动时自动开启调试

适合本地开发时从第一行开始调试：

```bat
bin\xnet.exe scripts/xadmin/xadmin_main.lua SERVER_NAME=xadmin1 XADMIN_PORT=18091 XDEBUG_BOOT=1 XDEBUG_PORT=19090 XDEBUG_WAIT=1
```

参数说明：

| 参数 | 说明 |
|---|---|
| `XDEBUG_BOOT=1` | 启动时启动调试服务 |
| `XDEBUG_PORT=19090` | 原生调试 TCP 端口，默认建议 `19090` |
| `XDEBUG_WAIT=1` | 每个 Lua state 在第一条可执行 Lua 行停住，方便 VSCode attach 后继续 |

如果不想启动时挂住进程，可以用：

```bat
XDEBUG_BOOT=1 XDEBUG_PORT=19090 XDEBUG_WAIT=0
```

### 20.4 运行中按需开启调试

适合测试环境或远程现场：程序启动时不带任何调试启动参数。

```bat
bin\xnet.exe scripts/xadmin/xadmin_main.lua SERVER_NAME=xadmin1 XADMIN_PORT=18091
```

需要调试时，在 xadmin 网页的执行脚本页面运行：

```lua
local ok, msg = xthread.xdebug_start(19090, false)
return ok, msg
```

查询状态：

```lua
local running, port = xthread.xdebug_status()
return running, port
```

推荐把第二个参数传 `false`：先启动调试服务，再让 VSCode attach、设置断点，然后重新触发要调试的请求。传 `true` 会让 Lua 线程在下一行停住，适合你已经准备好 attach 的情况。

### 20.5 VSCode 使用

调试器自身不依赖 VSCode，但官方推荐的客户端就是 VSCode + 内置 DAP 调试器。本节给出可以**直接复制粘贴**的 `.vscode/` 配置；这两个文件**不入库**，每位开发者在本机仓库根目录下自行建立即可。

#### 20.5.1 前置条件

- 已用 `WITH_XDEBUG=1` 构建 `bin/xnet.exe`（详见 §20.2）。
- 已构建 `tools/xdebug_dap.exe`（Windows）或 `tools/xdebug_dap`（Unix-like）。默认 `make` 会构建它，也可以单独运行 `mingw32-make xdebug_dap`。
- xnet 进程已在运行，并且已经通过 `XDEBUG_BOOT=1` 或 `xthread.xdebug_start(...)` 开启了调试服务（详见 §20.3 / §20.4）。

#### 20.5.2 创建 `.vscode/tasks.json`

把 DAP 桥挂成 attach 前置任务。VSCode 启动调试时会自动运行 `tools/xdebug_dap.exe ...`，在本地 `127.0.0.1:4711` 监听 DAP。

```json
{
    "version": "2.0.0",
    "tasks": [
        {
            "label": "xnet-xdebug-dap",
            "type": "shell",
            "command": "${workspaceFolder}/tools/xdebug_dap.exe",
            "args": [
                "--listen", "4711",
                "--xdebug-host", "127.0.0.1",
                "--xdebug-port", "19090",
                "--cwd", "${workspaceFolder}"
            ],
            "isBackground": true,
            "problemMatcher": {
                "owner": "xnet-xdebug-dap",
                "pattern": { "regexp": ".*" },
                "background": {
                    "activeOnStart": true,
                    "beginsPattern": "xnet-xdebug-dap starting",
                    "endsPattern": "xnet-xdebug-dap listening"
                }
            }
        }
    ]
}
```

`beginsPattern` / `endsPattern` 与原生 DAP 桥实际输出的 `xnet-xdebug-dap starting` 和 `xnet-xdebug-dap listening on 127.0.0.1:4711` 严格对齐，VSCode 才知道后台任务何时算“就绪”。

如果暂时没有编出原生桥，也可以把 `"command"` 改回 `"node"`，并把 `"${workspaceFolder}/tools/xdebug_dap.js"` 放到 `args` 第一项继续使用旧版 JS 桥。

在 Unix-like 系统上，把 `"command"` 改成 `"${workspaceFolder}/tools/xdebug_dap"`。

桥参数说明：

| 参数 | 默认 | 说明 |
|---|---|---|
| `--listen` | `4711` | DAP 桥对外监听的本机端口（VSCode 连这里） |
| `--xdebug-host` | `127.0.0.1` | 原生调试端口所在主机（远程调试时写 `127.0.0.1` 配合端口转发，见 §20.7） |
| `--xdebug-port` | `19090` | 原生调试端口（必须与 `XDEBUG_PORT` 一致） |
| `--cwd` | 进程 CWD | 把 VSCode 设的绝对路径断点映射成相对仓库路径，建议明确传 `${workspaceFolder}` |

#### 20.5.3 创建 `.vscode/launch.json`

```json
{
    "version": "0.2.0",
    "configurations": [
        {
            "name": "XNet Lua Attach :19090",
            "type": "node",
            "request": "attach",
            "debugServer": 4711,
            "preLaunchTask": "xnet-xdebug-dap",
            "cwd": "${workspaceFolder}",
            "xdebugHost": "127.0.0.1",
            "xdebugPort": 19090
        }
    ]
}
```

关键字段：

| 字段 | 必填 | 含义 |
|---|---|---|
| `type` | 是 | 固定 `node`。VSCode 通过 `debugServer` 直接走 DAP，不会真的去拉起 Node 调试器。 |
| `debugServer` | 是 | 与 `tasks.json` 里 `--listen` 保持一致（默认 `4711`）。 |
| `preLaunchTask` | 是 | 自动把上面的 `xnet-xdebug-dap` 任务跑起来；不写则要手动起桥。 |
| `cwd` | 是 | 仓库根。Lua 源文件路径解析与断点路径归一都基于此目录。 |
| `xdebugHost` / `xdebugPort` | 否 | 透传给桥，便于在 launch.json 里直接切换目标，无需改 task；建议两边写一致以免混淆。 |

需要并联多个目标（例如同时调本机和远端）就再加一份 configuration、改 `debugServer` 和 `xdebugPort` 即可。

#### 20.5.4 一键调试流程

1. 启动 xnet 并开启调试服务（参考 §20.3 或 §20.4）。
2. VSCode 打开仓库根目录，确认上面两个 JSON 文件在 `.vscode/` 下。
3. 打开“运行和调试”面板，选择 `XNet Lua Attach :19090`，按 F5。
4. VSCode 自动跑 `xnet-xdebug-dap` 后台任务（终端会看到 `xnet-xdebug-dap listening on 127.0.0.1:4711`），随后 attach。
5. 在 Lua 文件中下断点，触发对应请求即可命中。

VSCode 实际连接路径：`VSCode ──DAP──▶ 127.0.0.1:4711（DAP 桥） ──原生协议──▶ 127.0.0.1:19090（xnet 内置）`。

断点命中后，当前 xnet 线程会显示在三个地方：

| 位置 | 示例 |
|---|---|
| Call Stack 线程名 | `T60 stopped scripts/xadmin/xadmin_app.lua:165 (xadmin_worker.lua)` |
| Debug Console | `[xnet] breakpoint: T60 stopped at scripts/xadmin/xadmin_app.lua:165 ...` |
| Variables 面板 | `XNet Thread` scope，包含 `xnet_thread_id`、`script`、`stopped_at`；`Locals` 里的 Lua table 默认收起，可点开懒加载子字段 |

#### 20.5.5 `.vscode/` 配置方式

把上面两份 JSON 放在仓库根的 `.vscode/` 目录下，文件名固定：

```
xnet2lua/
├── .vscode/
│   ├── tasks.json    ← 见 §20.5.2
│   └── launch.json   ← 见 §20.5.3
├── tools/xdebug_dap.exe
├── bin/xnet.exe
└── ...
```

创建步骤：

1. 在仓库根建 `.vscode` 目录（已有则跳过）。Windows 命令行：

   ```bat
   mkdir .vscode
   ```

   或在 VSCode 文件树空白处右键 ▶ “新建文件夹” ▶ 命名 `.vscode`。

2. 在 `.vscode/` 下新建 `tasks.json`，把 §20.5.2 的内容粘贴进去。
3. 在 `.vscode/` 下新建 `launch.json`，把 §20.5.3 的内容粘贴进去。
4. 重新加载 VSCode 窗口（`Ctrl+Shift+P` ▶ `Developer: Reload Window`）或刷新“运行和调试”面板，`XNet Lua Attach :19090` 会出现在下拉列表里。

调整建议：

- **端口冲突**：同时改 `tasks.json` 的 `--listen` 和 `launch.json` 的 `debugServer`（两者必须相等）。改 xnet 侧 `XDEBUG_PORT` 时，同步改 `tasks.json` 的 `--xdebug-port` 与 `launch.json` 的 `xdebugPort`。
- **多目标并联**：复制一份 task（改 `label` 和 `--listen`）+ 复制一份 configuration（改 `name`、`debugServer`、`preLaunchTask`），F5 时分别选择即可同时 attach 多个 xnet 进程。
- **原生桥不存在**：先运行 `mingw32-make xdebug_dap`，或临时切回 `node tools/xdebug_dap.js` 备用。
- **JSON 校验失败**：标准 `.json` 不允许注释；如果想加注释把文件后缀改成 `jsonc`，或在 VSCode `files.associations` 里把 `tasks.json` / `launch.json` 关联到 `jsonc`。
- **配置不生效**：确认仓库是用“打开文件夹”方式打开（不是单独打开某个文件），且 `.vscode/` 在工作区根目录，不是嵌套子目录。

是否把 `.vscode/` 提交到 git 由项目自行决定。端口和本地工具路径因人而异，常见做法是把 `.vscode/` 加进本地 `.gitignore`，让每位开发者基于本节的样板各自维护一份。

#### 20.5.6 多进程调试（按 F5 选择目标进程）

同一台机器上同时跑多个 xnet 进程（例如 `gate` / `passport` / `game` / `cent` / `manager` / `battl`）时，每个进程都需要**独立的 `XDEBUG_PORT`** —— 一个 `127.0.0.1:port` 不能被两个进程同时监听。

按进程约定端口表，启动各进程时分别带上自己的 `XDEBUG_PORT`：

| 进程 | XDEBUG_PORT |
|---|---|
| xadmin   | 19090 |
| gate     | 19091 |
| passport | 19092 |
| game     | 19093 |
| cent     | 19094 |
| manager  | 19095 |
| battl    | 19096 |

要在 F5 时弹下拉框选择进程，在 `.vscode/launch.json` 和 `.vscode/tasks.json` **都**加一段同 id 的 `pickString` input。VSCode 的 input 变量按文件作用域解析、两个文件之间不共享（[microsoft/vscode#93412](https://github.com/microsoft/vscode/issues/93412)），所以必须复制一份；好在 VSCode ≥ 1.62 在一次 F5 会话内会缓存输入值，下拉框只会弹一次。

`launch.json`：

```json
{
    "version": "0.2.0",
    "configurations": [
        {
            "name": "XNet Lua Attach (pick process)",
            "type": "node",
            "request": "attach",
            "debugServer": 4711,
            "preLaunchTask": "xnet-xdebug-dap",
            "cwd": "${workspaceFolder}",
            "xdebugHost": "127.0.0.1",
            "xdebugPort": "${input:xdebugPort}"
        }
    ],
    "inputs": [
        {
            "id": "xdebugPort",
            "type": "pickString",
            "description": "Which xnet process to debug?",
            "options": [
                { "label": "xadmin   (19090)", "value": "19090" },
                { "label": "gate     (19091)", "value": "19091" },
                { "label": "passport (19092)", "value": "19092" },
                { "label": "game     (19093)", "value": "19093" },
                { "label": "cent     (19094)", "value": "19094" },
                { "label": "manager  (19095)", "value": "19095" },
                { "label": "battl    (19096)", "value": "19096" }
            ],
            "default": "19090"
        }
    ]
}
```

`tasks.json` 把 `--xdebug-port` 也改成 `${input:xdebugPort}`，并在文件末尾追加同样的 `inputs` 段：

```json
{
    "version": "2.0.0",
    "tasks": [
        {
            "label": "xnet-xdebug-dap",
            "type": "shell",
            "command": "${workspaceFolder}/tools/xdebug_dap.exe",
            "args": [
                "--listen", "4711",
                "--xdebug-host", "127.0.0.1",
                "--xdebug-port", "${input:xdebugPort}",
                "--cwd", "${workspaceFolder}"
            ],
            "isBackground": true,
            "problemMatcher": {
                "owner": "xnet-xdebug-dap",
                "pattern": { "regexp": ".*" },
                "background": {
                    "activeOnStart": true,
                    "beginsPattern": "xnet-xdebug-dap starting",
                    "endsPattern": "xnet-xdebug-dap listening"
                }
            }
        }
    ],
    "inputs": [
        {
            "id": "xdebugPort",
            "type": "pickString",
            "description": "Which xnet process to debug?",
            "options": [
                { "label": "xadmin   (19090)", "value": "19090" },
                { "label": "gate     (19091)", "value": "19091" },
                { "label": "passport (19092)", "value": "19092" },
                { "label": "game     (19093)", "value": "19093" },
                { "label": "cent     (19094)", "value": "19094" },
                { "label": "manager  (19095)", "value": "19095" },
                { "label": "battl    (19096)", "value": "19096" }
            ],
            "default": "19090"
        }
    ]
}
```

端口表如有变动，两个文件的 `options` 数组**必须同步**改，否则下拉项不一致。

> **解析陷阱**：`pickString` 的 value 永远是字符串，所以 launch 配置发到桥的 DAP `attach` 报文里 `xdebugPort` 字段是 `"19090"`（带引号）。原先 `tools/xdebug_dap.c` 的 `json_int_at` 只识别裸数字、看到 `"` 直接 fallback 到 `--xdebug-port` 命令行参数；只要 launch 和 task 两边端口选的不一样（或者命令行那段没传），桥就会连到错误的端口并报 `connection failed`。`json_int_at` 已扩成也接受带引号的整数字符串，使用 `pickString` 时不再需要绕过。

切换进程间的注意点：`isBackground: true` 意味着上一次启动的 `xdebug_dap.exe` 不会自动重启 —— VSCode 复用同一个 4711 桥进程接受新的 `attach` 请求即可，桥会主动断掉旧的 xdebug 连接并连到新选的端口。如果桥卡死（极少见），用 **Terminal → Run Task… → Tasks: Terminate Task** 杀掉，再 F5 即可。

### 20.6 多线程和 coroutine 行为

每个 xnet OS 线程都有独立 `lua_State`。调试器会为每个已注册 Lua state 安装 line hook，并包装 `coroutine.create` / `coroutine.wrap`，让新建 coroutine 继承调试 hook。

因此这些场景都能断住：

- 主线程脚本，例如 `scripts/xadmin/xadmin_main.lua`
- 动态创建的 worker 线程，例如 `scripts/xadmin/xadmin_worker.lua`
- xadmin HTTP 请求 coroutine，例如 `scripts/xadmin/xadmin_app.lua`
- xrouter RPC handler coroutine
- 网页“执行脚本”触发的 `/api/exec` 路径

调试 hook 必须在拥有该 `lua_State` 的 OS 线程里安装。运行中按需开启调试时，其它线程会在自己的下一次 update tick 中接入调试，避免跨线程直接操作别的 Lua state。

### 20.7 远程调试

调试服务默认只监听目标机器自己的 `127.0.0.1`，不要直接暴露到公网。远程调试推荐端口转发。

SSH 远程主机（单进程）：

```bash
ssh -L 19090:127.0.0.1:19090 user@remote-host
```

然后本地 VSCode 仍然 attach `127.0.0.1:19090`。

多进程时把每个 `XDEBUG_PORT` 都加一条 `-L`：

```bash
ssh -N -L 19090:127.0.0.1:19090 \
       -L 19091:127.0.0.1:19091 \
       -L 19092:127.0.0.1:19092 \
       -L 19093:127.0.0.1:19093 \
       user@192.168.1.132
```

或者把转发写进 `~/.ssh/config`，平时一条 `ssh -N gameserver` 就能把整段端口转过来：

```sshconfig
Host gameserver
    HostName 192.168.1.132
    User your_user
    LocalForward 19090 127.0.0.1:19090
    LocalForward 19091 127.0.0.1:19091
    LocalForward 19092 127.0.0.1:19092
    LocalForward 19093 127.0.0.1:19093
```

隧道连通后，可以用 telnet 或 PowerShell 直接握手验证某个端口：

```powershell
$c = New-Object System.Net.Sockets.TcpClient
$c.Connect("127.0.0.1", 19090)
$r = New-Object System.IO.StreamReader($c.GetStream())
$r.ReadLine()    # 应当输出: OK xnet-xdebug
$c.Close()
```

收到 `OK xnet-xdebug` 就说明端口转发 + 远端 xdebug 都正常，本地 VSCode 配合 §20.5.6 的 pickString 选对端口即可 attach。

Android 设备或模拟器：

```bash
adb forward tcp:19090 tcp:19090
```

iOS 真机：

```bash
iproxy 19090 19090
```

iOS Simulator 或本机 macOS 通常可以直接使用本机端口。无论哪种方式，VSCode 配置尽量保持不变，让它始终连接本机端口。

### 20.8 性能与安全

性能影响分三层：

| 状态 | 影响 |
|---|---|
| `WITH_XDEBUG=0` | 调试器不参与编译，无运行时影响 |
| `WITH_XDEBUG=1` 但未启动服务 | 只做轻量状态登记，不安装 line hook，影响很小 |
| 调试服务已启动 | 每行 Lua 都会进入 debug hook，热循环和高频业务会明显变慢 |

安全建议：

- 生产包建议 `WITH_XDEBUG=0`。
- 测试包可以 `WITH_XDEBUG=1`，但默认不要 `XDEBUG_BOOT=1`。
- xadmin 远程执行脚本必须有鉴权，避免任何人都能启动调试服务。
- 不建议把 `XDEBUG_PORT` 暴露到公网；使用 SSH/ADB/iproxy 端口转发。

### 20.9 常见问题

**1. `WITH_XDEBUG=1` 后为什么还能直接调试？**

只有两种可能：进程启动时传了 `XDEBUG_BOOT=1`，或者运行中已经执行过 `xthread.xdebug_start(...)`。`WITH_XDEBUG=1` 本身只编译能力，不会启动服务。

**2. 旧的 `XDEBUG=1` 还有效吗？**

无效。启动期开关只认 `XDEBUG_BOOT=1`。

**3. 断点不命中怎么办？**

先确认 VSCode attach 的端口和 `XDEBUG_PORT` 一致；再确认本地代码与运行端代码版本一致；最后确认断点行是 Lua 可执行行，不是函数声明行、空行或注释行。

**4. 进程启动后挂住怎么办？**

如果传了 `XDEBUG_WAIT=1`，这是预期行为。VSCode attach 后点击 Continue，或改用 `XDEBUG_WAIT=0`。

**5. 当前停住的是哪个线程？**

看 VSCode Call Stack 的线程名，或 Variables 面板里的 `XNet Thread` scope。
