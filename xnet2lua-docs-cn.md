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
11. [配置文件](#11-配置文件)
12. [线程 ID 常量表](#12-线程-id-常量表)
13. [完整示例：TCP 服务器](#13-完整示例tcp-服务器)
14. [完整示例：HTTP API 服务](#14-完整示例http-api-服务)
15. [完整示例：跨线程 RPC](#15-完整示例跨线程-rpc)
16. [最佳实践与注意事项](#16-最佳实践与注意事项)

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
- 网络帧协议支持 raw、len32（4 字节长度前缀）、CRLF 三种

---

## 2. 编译与集成

### 2.1 编译核心静态库

```bash
# 进入项目根目录
cd xnet2lua

# 编译 libxsock.a（核心 C 库）
make

# 产物：libxsock.a
```

### 2.2 编译 demo 可执行文件

```bash
cd demo

# 不带 HTTPS（默认）
make

# 带 HTTPS 支持（需要 mbedTLS）
make WITH_HTTPS=1

# 产物：xnet（或 xnet.exe）
```

### 2.3 运行 demo

```bash
# 运行 TCP echo demo
./xnet demo/xnet_main.lua

# 运行 HTTP demo
./xnet demo/xhttp_main.lua

# 运行 HTTPS demo（需带 WITH_HTTPS=1 编译）
./xnet demo/xhttps_main.lua

# 运行跨线程 RPC 测试
./xnet demo/xlua_main.lua

# 带参数运行（覆盖配置项）
./xnet demo/xnats_main.lua SERVER_NAME=game1
```

### 2.4 嵌入式集成

若要将 xnet2lua 嵌入自己的 C 项目，只需：

1. 将 `libxsock.a` 链接进你的可执行文件
2. 在 C 入口调用以下初始化序列：

```c
#define LUA_IMPL
#include "3rd/minilua.h"    // 单头文件嵌入 Lua，也可改用系统 Lua

#include "xthread.h"
#include "xlua.h"

// 注册 Lua 模块
luaL_requiref(L, "xthread",  luaopen_xthread,  1); lua_pop(L, 1);
luaL_requiref(L, "xnet",     luaopen_xnet,     1); lua_pop(L, 1);
luaL_requiref(L, "cmsgpack", luaopen_cmsgpack, 1); lua_pop(L, 1);
luaL_requiref(L, "xutils",   luaopen_xutils,   1); lua_pop(L, 1);

// 初始化线程系统
xthread_init();
```

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

local function __update()
    -- 每帧调用（主循环的每次迭代）
    -- 对于网络线程，通常在此调用 xnet.poll(timeout_ms)
    xnet.poll(10)
end

local function __uninit()
    -- 线程退出时调用（资源清理）
    print("线程退出")
end

local function __thread_handle(reply_router, k1, k2, k3, ...)
    -- 收到跨线程消息时调用（见第4章）
end

return {
    __init          = __init,
    __update        = __update,
    __uninit        = __uninit,
    __thread_handle = __thread_handle,
}
```

### 3.2 `__thread_handle` 消息分发模板

这是推荐的消息分发写法（兼容 POST 和 RPC 两种模式）：

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

### 3.3 退出程序

```lua
-- 正常退出（退出码 0）
xthread.stop(0)

-- 异常退出（退出码 1）
xthread.stop(1)
```

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
-- 返回：ok（bool）+ 对端 handler 的所有返回值
local ok, result1, result2 = xthread.rpc(target_id, pt, arg1, arg2, ...)

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
        local ok, sum = xthread.rpc(COMPUTE_ID, "add", 100, 200)
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

---

## 5. xnet 模块——异步网络

### 5.1 初始化与轮询

```lua
-- 初始化网络模块（在每个需要使用网络的线程中调用）
-- 返回：true，或 nil + 错误信息
assert(xnet.init())

-- 驱动事件循环（通常在 __update 中调用）
-- timeout_ms：等待事件的最长毫秒数（0 = 非阻塞，-1 = 永久等待）
xnet.poll(10)

-- 关闭网络模块（在 __uninit 中调用）
xnet.uninit()

-- 获取当前使用的 I/O 后端名称（"epoll" / "kqueue" / "wsapoll" / "poll"）
local backend = xnet.name()
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

-- 设置帧协议（见第6章）
conn:set_framing({ type = "len32", max_packet = 16 * 1024 * 1024 })

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

### 5.6 目录扫描（用于静态文件服务）

```lua
-- 扫描目录，返回文件列表
-- root：目录路径
-- 返回：{ {rel="相对路径", path="完整路径"}, ... }，或 nil + err
local files, err = xnet.scan_dir("static/")
if files then
    for _, f in ipairs(files) do
        print(f.rel, f.path)
    end
end
```

---

## 6. 帧协议（分包策略）

TCP 是字节流，需要在应用层定义如何分包。xnet2lua 内置三种帧协议，可以在连接建立后随时切换。

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

### 6.3 CRLF 模式（文本行协议）

以 `\r\n` 作为行结束符分包，适合 Redis 协议、SMTP 等文本协议。

```lua
conn:set_framing({
    type = "crlf",
    max_packet = 65536,
})
-- 每次 on_packet 收到一行数据（不含 \r\n）
```

### 6.4 自定义分隔符（crlf 扩展）

```lua
conn:set_framing({
    type = "crlf",
    delimiter = "\n",       -- 只用 \n 分行
    max_packet = 65536,
})
```

### 6.5 len32 + MessagePack 组合（最佳实践）

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

---

## 8. HTTP 服务器

xnet2lua 提供了一套完整的 HTTP 服务器实现（纯 Lua，基于 xnet）。

### 8.1 快速启动 HTTP 服务

```lua
-- 在主线程的 __init 中
local xhttp = dofile("demo/xhttp.lua")

local ok, err = xhttp.start({
    host         = "0.0.0.0",
    port         = 8080,
    worker_count = 4,             -- worker 线程数
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
| `worker_script` | string | "demo/xhttp_worker.lua" | worker 脚本路径 |
| `app_script` | string | "demo/xhttp_app.lua" | 应用路由脚本路径 |
| `max_request_size` | number | 16MB | 最大请求体大小（字节）|

### 8.2 编写应用路由（app_script）

每个 worker 线程都会独立加载 `app_script`，因此路由注册在 worker 的 Lua State 中执行。

```lua
-- my_app.lua
local router = dofile("demo/xhttp_router.lua")

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
        return xutils.json.unpack(req.body)
    end)
    if not ok then
        return { status = 400, body = "Invalid JSON\n" }
    end
    return {
        status  = 200,
        body    = xutils.json.pack({ result = "ok", received = data }),
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
| `req.body` | string | 请求体原始数据 |
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
local router = dofile("demo/xhttp_router.lua")

-- 注册 GET 路由
router.get(path, handler)

-- 注册 POST 路由
router.post(path, handler)

-- 注册 HEAD 路由
router.head(path, handler)

-- 通用注册（支持任意 method）
router.reg(method, path, handler)  -- method 不区分大小写
router.route(method, path, handler) -- 同上（别名）

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
local json_str = xutils.json.pack(value)

-- 将 JSON 字符串解析为 Lua 值
local value = xutils.json.unpack(json_str)

-- 示例
local str = xutils.json.pack({ name = "alice", score = 100, tags = {"vip", "active"} })
-- str = '{"name":"alice","score":100,"tags":["vip","active"]}'

local data = xutils.json.unpack(str)
print(data.name)   -- alice
print(data.score)  -- 100
```

---

## 11. 配置文件

xnet2lua 支持通过 `.cfg` 文件管理运行时配置，格式为 `KEY=VALUE`，支持 `#` 注释。

### 11.1 配置文件格式

```ini
# xnet.cfg 示例
SERVER_NAME=myserver

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
local ok, err = xnet.load_config("config/xnet.cfg")
if not ok then
    io.stderr:write("配置加载失败: " .. tostring(err) .. "\n")
end

-- 读取配置项（第二个参数为默认值）
local host    = xnet.get_config("HTTP_HOST", "127.0.0.1")
local port    = tonumber(xnet.get_config("HTTP_PORT", "8080")) or 8080
local workers = tonumber(xnet.get_config("HTTP_WORKERS", "2")) or 2
local debug   = xnet.get_config("DEBUG", "0") ~= "0"
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
| `xthread.WORKER_GRP1` | 10 | worker 组1起始（10–29）|
| `xthread.WORKER_GRP2` | 30 | worker 组2起始（30–49）|
| `xthread.WORKER_GRP3` | 50 | worker 组3起始（50–59）|
| `xthread.WORKER_GRP4` | 60 | worker 组4起始（60–69）|
| `xthread.WORKER_GRP5` | 70 | worker 组5起始（70–99）|

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

local function __update()
    xnet.poll(10)
end

local function __uninit()
    if listener then listener:close("shutdown") end
    if worker_started then xthread.shutdown_thread(WORKER_ID) end
    xnet.uninit()
    print("[MAIN] 已关闭")
end

return {
    __init          = __init,
    __update        = __update,
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

local function __update()
    xnet.poll(10)
end

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
    __update        = __update,
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

local xhttp = dofile("demo/xhttp.lua")

local CONFIG_FILE = "config/xnet.cfg"
xnet.load_config(CONFIG_FILE)

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
        host         = xnet.get_config("HTTP_HOST", "0.0.0.0"),
        port         = tonumber(xnet.get_config("HTTP_PORT", "8080")),
        worker_count = tonumber(xnet.get_config("HTTP_WORKERS", "4")),
        app_script   = "api_app.lua",
    })

    if not ok then error("HTTP 启动失败: " .. tostring(err)) end
    print("[SERVER] HTTP 服务已启动，按 Ctrl+C 退出")
end

local function __update()
    xnet.poll(10)
end

local function __uninit()
    xhttp.stop()
    xnet.uninit()
end

return {
    __init = __init, __update = __update,
    __uninit = __uninit, __thread_handle = __thread_handle,
}
```

### 应用路由（api_app.lua）

```lua
-- api_app.lua - 每个 worker 线程独立加载此文件

local router = dofile("demo/xhttp_router.lua")

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
        body    = xutils.json.pack(data),
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
    local ok, body = pcall(xutils.json.unpack, req.body)
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
    local ok, result = xthread.rpc(COMPUTE_ID, "add", 100, 200)
    assert(ok and result == 300, "add 测试失败: " .. tostring(result))
    print("[TEST1 通过] 100 + 200 =", result)

    -- 测试2：RPC 支持多返回值
    local ok, a, b = xthread.rpc(COMPUTE_ID, "divmod", 17, 5)
    assert(ok and a == 3 and b == 2, "divmod 测试失败")
    print("[TEST2 通过] 17 ÷ 5 = 商", a, "余", b)

    -- 测试3：计算线程回调主线程（RPC 链）
    local ok, reversed = xthread.rpc(COMPUTE_ID, "process_and_callback", "hello")
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

local function __update() end
local function __uninit() end

return {
    __init = __init, __update = __update,
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
    local ok, reversed = xthread.rpc(MAIN_ID, "reverse_string", s)
    if not ok then error("callback RPC 失败: " .. tostring(reversed)) end
    return reversed
end)

local function __init() print("[COMPUTE] 初始化") end
local function __update() end
local function __uninit() print("[COMPUTE] 退出") end

return {
    __init = __init, __update = __update,
    __uninit = __uninit, __thread_handle = __thread_handle,
}
```

---

## 16. 最佳实践与注意事项

### 线程设计

- **主线程只管分发**：主线程负责 `listen_fd` 并通过 `xthread.post` 将 fd 传给 worker，不做任何业务逻辑
- **每个线程调用 `xnet.init()`**：每个使用网络的线程都需要独立初始化 xnet，包括 worker 线程
- **`xnet.poll()` 放在 `__update` 中**：确保事件循环持续驱动，超时时间建议 5–20ms
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
local ok, result = xthread.rpc(TARGET_ID, "compute", arg)
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
| 低延迟 | 减小 `xnet.poll()` 超时时间（如 1ms）|
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
