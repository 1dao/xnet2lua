# 变更日志

本文件记录 xnet2lua 的主要变更，自 2026-09-25 起。项目尚未发布版本标签，最新变更位于“未发布”。

## 未发布

### 新增

- `xproc` 支持 Windows：子进程使用匿名管道作为 stdin/stdout/stderr，经转发线程桥接到本机回环 socket，调用方仍用 `xnet.attach` 读写，接口与 POSIX 一致。只继承三个管道句柄；子进程置于 Job 对象，`xproc.kill` 结束整个进程树并报告 143 / 137。按合并后环境的 PATH 查找 `.exe`/`.com`；`.bat`/`.cmd` 需经 `cmd.exe /d /c` 运行。参数、路径与环境变量按 UTF-8 转为宽字符调用 Win32 W 接口，中文路径与参数不受系统代码页影响。
- `xsock_socketpair`：跨平台连接的 socket 对。POSIX 为 `socketpair(AF_UNIX)` 并设置 close-on-exec；Windows 为本机回环 TCP，校验接受的对端、不可继承、关闭 Nagle。两端保持阻塞，由调用方决定是否非阻塞。
- `xutils.to_utf8`：校验 UTF-8（含 BOM），并用系统能力将 GBK 严格转为 UTF-8，不内置映射表。Windows 使用代码页 936，Linux/macOS 使用 iconv，iOS 使用 CoreFoundation，Android 使用 JNI CharsetDecoder（宿主需调用一次 `xutils_android_init`）。
- `xutils` 新增 `read_stdin`、`random_bytes`、`realpath`、`replace_file`、`temp_file`；`LOG_STDERR=1` 或 `STDIO=1` 时控制台日志改写到 stderr，stdout 仅保留协议输出。
- `xscan`：可配置的源码词法扫描器，支持 Lua 长括号、JS 模板与正则、Rust 生命周期与原始字符串。
- LuaJIT 后端恢复可用：Lua 5.2–5.4 C API 兼容集中在 `xlua/xlua_compat.h`（内置 Lua 构建下不生效），合并 `lua_xutils.c` 原有的零散补丁。LuaJIT 下注册按 Lua 5.4 语义实现的 `utf8` 库，并新增 `tests/lua/utf8_spec.lua` 在两种后端下对照验证。
- 日志启动参数：`LOG_LEVEL=<级别>`（名称或 2–8）在第一条日志前生效，控制台与文件同样过滤；`LOG_FILE=0` 只输出到控制台，不创建日志目录；`LOG_DIR=<目录>` 替换默认的 `./logs`。默认行为不变。从用户目录启动的工具（如在项目根目录启动的 MCP 服务）可借此不留下文件。

### 变更

- xthread 唤醒通道与 xproc 数据通道统一使用 `xsock_socketpair`，删除各自的实现。Windows 上唤醒 socket 不再被 `os.execute`/`popen` 子进程继承，并关闭 Nagle。
- 本项目文本文件统一为 LF，新增 `.gitattributes`；`3rd/` 下的第三方代码保持上游原样。
- `tests/lua/xproc_pipe_test.lua` 改为跨平台，新增行请求/响应往返、进程树结束与批处理拒绝用例。
- 线程上限 `XTHR_MAX` 由 120 调至 512。
- 核心与 xagent 脚本不再使用 Lua 5.3+ 专有语法，可在 LuaJIT 下加载：`xwebsocket` 帧头改用字节运算，掩码按运行时选用原生 `~` 或 `bit.bxor`；`xproxy`、`xoauth`、`xadmin_auth` 等改用算术运算。
- LuaJIT 下 xdebug 在调试会话的第一个 hook 中清空已编译代码并关闭 JIT，断点与单步不再被 JIT 代码跳过。

### 修复

- JSON 空数组经 `json_unpack` / `json_pack` 往返后保持为 `[]`。
- xtimer 回调在 VM 主协程上执行，而不是在设置定时器的协程上。
- 关闭的连接释放其 channel，不再泄漏；补充对应测试。
- xpoll 分发事件时，回调关闭的 fd 若立即被新 socket 复用，且 malloc 把同一地址分给新的登记，旧 fd 余下的事件会落到新 socket 上：失败连接的错误会关掉在其 `on_close` 中打开的监听 socket。登记现在带代数，分发途中按指针和代数一起确认；补充 `tests/lua/xpoll_fd_reuse_test.lua`。Linux（epoll、glibc malloc）上可稳定复现。
- xscan 正确处理控制条件后的正则、嵌套注释与续行。
- LuaJIT 下在协程内创建的定时器与连接回调到已回收的协程导致崩溃：5.1 没有 `LUA_RIDX_MAINTHREAD`，运行时现在记录主线程供 `main_lua_state` 使用。
- `build.bat` 运行 Lua 测试时 `==>` 被解析为重定向，每次都会把第一个测试脚本覆盖成一行日志。
- `build.bat nohttps` 构建缺少 AES 源文件导致链接失败（与 Makefile 的列表对齐）。
- `demo/xutils_main.lua` 稀疏表 JSON 用例不再依赖表遍历顺序。
- `build.bat luajit` 重新构建时会链接 `luajit.lib`：那是 msvcbuild 生成的 `luajit.exe` 导入库，并非静态库，链接会失败（或让 xnet.exe 依赖 luajit.exe）。现在只使用 `lua51.lib` / `libluajit.lib`。

### 构建

- MSVC 构建默认启用 xproc，可用 `xproc` / `noxproc` 切换。
- 新增 MPSCQ 构建开关：Makefile `WITH_MPSCQ=1`、build.bat `mpscq` / `nompscq`，定义 `XTHREAD_MPSCQ`，线程队列改用无锁 MPSC 实现（背压变为软限制）。默认关闭；发布构建开启。
- `LUA_BACKEND=luajit` 时 Makefile 自动编译 `3rd/luajit` 静态库（macOS 默认 `MACOSX_DEPLOYMENT_TARGET=11.0`）；Makefile 与 build.bat 均开启 `LUAJIT_ENABLE_LUA52COMPAT`，build.bat 让 LuaJIT 与 xnet 使用同一种 CRT。
- CI 新增 ubuntu / macOS 的 LuaJIT 后端测试。
