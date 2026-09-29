# 变更日志

本文件记录 xnet2lua 的主要变更，自 2026-09-25 起。项目尚未发布版本标签，最新变更位于“未发布”。

## 未发布

### 新增

- `xproc` 支持 Windows：子进程使用匿名管道作为 stdin/stdout/stderr，经转发线程桥接到本机回环 socket，调用方仍用 `xnet.attach` 读写，接口与 POSIX 一致。只继承三个管道句柄；子进程置于 Job 对象，`xproc.kill` 结束整个进程树并报告 143 / 137。按合并后环境的 PATH 查找 `.exe`/`.com`；`.bat`/`.cmd` 需经 `cmd.exe /d /c` 运行。参数、路径与环境变量按 UTF-8 转为宽字符调用 Win32 W 接口，中文路径与参数不受系统代码页影响。
- `xsock_socketpair`：跨平台连接的 socket 对。POSIX 为 `socketpair(AF_UNIX)` 并设置 close-on-exec；Windows 为本机回环 TCP，校验接受的对端、不可继承、关闭 Nagle。两端保持阻塞，由调用方决定是否非阻塞。
- `xutils.to_utf8`：校验 UTF-8（含 BOM），并用系统能力将 GBK 严格转为 UTF-8，不内置映射表。Windows 使用代码页 936，Linux/macOS 使用 iconv，iOS 使用 CoreFoundation，Android 使用 JNI CharsetDecoder（宿主需调用一次 `xutils_android_init`）。
- `xutils` 新增 `read_stdin`、`random_bytes`、`realpath`、`replace_file`、`temp_file`；`LOG_STDERR=1` 或 `STDIO=1` 时控制台日志改写到 stderr，stdout 仅保留协议输出。
- `xscan`：可配置的源码词法扫描器，支持 Lua 长括号、JS 模板与正则、Rust 生命周期与原始字符串。

### 变更

- xthread 唤醒通道与 xproc 数据通道统一使用 `xsock_socketpair`，删除各自的实现。Windows 上唤醒 socket 不再被 `os.execute`/`popen` 子进程继承，并关闭 Nagle。
- 本项目文本文件统一为 LF，新增 `.gitattributes`；`3rd/` 下的第三方代码保持上游原样。
- `tests/lua/xproc_pipe_test.lua` 改为跨平台，新增行请求/响应往返、进程树结束与批处理拒绝用例。
- 线程上限 `XTHR_MAX` 由 120 调至 512。

### 修复

- JSON 空数组经 `json_unpack` / `json_pack` 往返后保持为 `[]`。
- xtimer 回调在 VM 主协程上执行，而不是在设置定时器的协程上。
- 关闭的连接释放其 channel，不再泄漏；补充对应测试。
- xscan 正确处理控制条件后的正则、嵌套注释与续行。
- `build.bat` 运行 Lua 测试时 `==>` 被解析为重定向，每次都会把第一个测试脚本覆盖成一行日志。
- `build.bat nohttps` 构建缺少 AES 源文件导致链接失败（与 Makefile 的列表对齐）。

### 构建

- MSVC 构建默认启用 xproc，可用 `xproc` / `noxproc` 切换。
- 新增 MPSCQ 构建开关：Makefile `WITH_MPSCQ=1`、build.bat `mpscq` / `nompscq`，定义 `XTHREAD_MPSCQ`，线程队列改用无锁 MPSC 实现（背压变为软限制）。默认关闭；发布构建开启。
