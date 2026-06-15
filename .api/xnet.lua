---@meta
---@diagnostic disable: unreachable-code, unused-local
do return end

-- LuaLS metadata for the native xnet module.
-- LuaLS 使用的 xnet 原生模块元数据。
-- This file is metadata-only and does not execute at runtime.
-- 本文件仅用于元数据，不会在运行时执行。
--
-- Event-driven TCP. xpoll owns readiness; xchannel owns connection buffering
-- and the built-in stream framings (raw / len32 / len16 / crlf). The standard
-- pattern per thread:
--   xnet.init()
--   xnet.listen(8080, { on_packet = function(conn, data) conn:send(data) end })
--   -- the thread runner drives xnet.poll() each tick
-- Connections and listeners dispatch to a handler table of on_* callbacks.
-- TLS (attach_tls / connect_tls and the tls_connection methods) is present only
-- in HTTPS builds (XNET_WITH_HTTPS).
-- 事件驱动 TCP。xpoll 负责就绪通知；xchannel 负责连接缓冲与内置的流分帧
-- （raw / len32 / len16 / crlf）。每线程的标准用法：
--   xnet.init()
--   xnet.listen(8080, { on_packet = function(conn, data) conn:send(data) end })
--   -- 线程运行器每个 tick 自动驱动 xnet.poll()
-- 连接与监听器把事件分派到一个由 on_* 回调组成的 handler 表。
-- TLS（attach_tls / connect_tls 及 tls_connection 方法）仅存在于 HTTPS 构建
-- （XNET_WITH_HTTPS）。

---@class xnet
local xnet = {}

-- ===========================================================================
-- Handler callback table / 事件回调表
--
-- Passed to listen / connect / attach and to conn:set_handler. All callbacks
-- are optional; aliases let several names map to the same event.
-- 传给 listen / connect / attach 以及 conn:set_handler。所有回调均可选；别名允许
-- 多个名字映射到同一事件。
-- ===========================================================================

---@class xnet.handler
---Fired once when a connection is established. May return a new handler table to swap handlers. Aliases: `connect`.
---连接建立时触发一次。可返回一个新的 handler 表以切换处理器。别名：connect。
---@field on_connect? fun(conn: xnet.connection, ip: string|nil, port: integer|nil): xnet.handler?
---Fired for each decoded packet/chunk. Return the number of bytes consumed (default = all); return < #data to keep the remainder buffered for redelivery. Returned strings are sent back to the peer. Aliases: `on_message`, `on_recv`.
---每收到一个解析出的包/数据块触发。返回已消费的字节数（默认全部）；返回值小于 #data 时余下部分会缓存等待再次投递。返回的字符串会回发给对端。别名：on_message、on_recv。
---@field on_packet? fun(conn: xnet.connection, data: string): (integer|string)?
---Fired once when the connection closes. Aliases: `on_disconnect`.
---连接关闭时触发一次。别名：on_disconnect。
---@field on_close? fun(conn: xnet.connection, reason: string)
---Listener-only (with xnet.listen_fd): hands the raw accepted fd to you instead of wrapping it. Aliases: `accept`, `on_fd`.
---仅监听器使用（配合 xnet.listen_fd）：把原始的已接受 fd 交给你，而不是自动包装。别名：accept、on_fd。
---@field on_accept? fun(listener: xnet.listener, fd: integer, ip: string, port: integer)

-- Framing options for conn:set_framing. Either pass a mode string directly, or
-- a table with these fields.
-- conn:set_framing 的分帧选项。可直接传模式字符串，或传带这些字段的表。
---@class xnet.framing
---Framing mode (see conn:set_framing). Either `type` or `mode` is accepted.
---分帧模式（见 conn:set_framing）。type 或 mode 均可。
---@field type? string
---@field mode? string
---Delimiter for "line"/"crlf"/"delimiter" mode; only "\r\n" is supported.
---"line"/"crlf"/"delimiter" 模式的分隔符；仅支持 "\r\n"。
---@field delimiter? string
---Maximum decoded packet size in bytes. / 单个解析包的最大字节数。
---@field max_packet? integer
---Maximum send-buffer size in bytes (0 = unlimited). / 发送缓冲上限字节数（0 = 不限）。
---@field max_send? integer
---Maximum receive-buffer size in bytes (0 = unlimited). / 接收缓冲上限字节数（0 = 不限）。
---@field max_recv? integer

-- ===========================================================================
-- Module functions / 模块函数
-- ===========================================================================

---Bring up sockets, xpoll, and (on a worker thread) the wakeup pipe.
---启动套接字、xpoll，以及（在工作线程上）唤醒管道。
---@param setsize? integer Optional initial xpoll fd-set size. / 可选的 xpoll fd 集合初始大小。
---@return boolean ok True on success; false + error on failure. / 成功返回 true；失败返回 false + 错误。
---@return string? err Error message on failure. / 失败时的错误信息。
function xnet.init(setsize) end

---Tear down xpoll and sockets for this thread.
---销毁本线程的 xpoll 与套接字。
function xnet.uninit() end

---Poll for socket readiness and dispatch callbacks once.
---轮询套接字就绪并分派一次回调。
---Driven automatically by the thread runner; scripts rarely call it directly.
---由线程运行器自动驱动，脚本极少直接调用。
---@param timeout_ms? integer Max wait in milliseconds, defaults to 0 (non-blocking). / 最长等待毫秒数，默认 0（非阻塞）。
---@return integer n Number of events processed. / 处理的事件数量。
function xnet.poll(timeout_ms) end

---Name of the active xpoll backend (e.g. "epoll", "kqueue", "iocp", "select").
---当前 xpoll 后端的名称（如 "epoll"、"kqueue"、"iocp"、"select"）。
---@return string name Poll backend name. / 轮询后端名称。
function xnet.name() end

---Per-thread network/runtime counters.
---本线程的网络/运行时计数器。
---@return { fd_count: integer, conn_count: integer, bytes_sent: integer, bytes_recv: integer, timer_count: integer, queue_depth: integer, queue_max: integer } stats
function xnet.get_stats() end

---Listen for inbound TCP and wrap each accepted socket in an xnet.connection.
---监听入站 TCP，并把每个接受的套接字包装为 xnet.connection。
---`host` may be omitted to bind all interfaces. The handler's on_connect /
---on_packet / on_close fire for each accepted connection.
---host 可省略以绑定所有网卡。handler 的 on_connect / on_packet / on_close 会为每个
---接受的连接触发。
---@param host? string Bind address, or omit/nil for all interfaces. / 绑定地址，省略/nil 表示所有网卡。
---@param port integer TCP port to listen on. / 要监听的 TCP 端口。
---@param handler xnet.handler Per-connection callback table. / 每连接的回调表。
---@return xnet.listener|nil listener The listener, or nil + error. / 监听器；失败时返回 nil + 错误。
---@return string? err Error message on failure. / 失败时的错误信息。
function xnet.listen(host, port, handler) end

---Listen for inbound TCP and hand each raw accepted fd to handler.on_accept.
---监听入站 TCP，并把每个原始的已接受 fd 交给 handler.on_accept。
---Use this to migrate the fd to another thread (detach/attach) instead of
---servicing it on the accepting thread.
---用于把 fd 迁移到其他线程（detach/attach），而不是在接受线程上直接处理。
---@param host? string Bind address, or omit/nil for all interfaces. / 绑定地址，省略/nil 表示所有网卡。
---@param port integer TCP port to listen on. / 要监听的 TCP 端口。
---@param handler xnet.handler Table with on_accept(listener, fd, ip, port). / 含 on_accept(listener, fd, ip, port) 的表。
---@return xnet.listener|nil listener The listener, or nil + error. / 监听器；失败时返回 nil + 错误。
---@return string? err Error message on failure. / 失败时的错误信息。
function xnet.listen_fd(host, port, handler) end

---Open an outbound TCP connection (non-blocking; on_connect fires when ready).
---发起一个出站 TCP 连接（非阻塞；就绪时触发 on_connect）。
---@param host string Remote host. / 远端主机。
---@param port integer Remote port. / 远端端口。
---@param handler xnet.handler Connection callback table. / 连接回调表。
---@return xnet.connection|nil conn The connection, or nil + error. / 连接对象；失败时返回 nil + 错误。
---@return string? err Error message on failure. / 失败时的错误信息。
function xnet.connect(host, port, handler) end

---Adopt an existing OS socket fd as an xnet.connection.
---把一个已存在的 OS 套接字 fd 接管为 xnet.connection。
---The fd is set non-blocking and attached to xpoll; on_connect fires
---immediately. Pair with conn:detach() to migrate connections between threads.
---fd 会被设为非阻塞并挂入 xpoll；on_connect 立即触发。与 conn:detach() 配合可在线程
---之间迁移连接。
---@param fd integer OS socket file descriptor. / OS 套接字文件描述符。
---@param handler xnet.handler Connection callback table. / 连接回调表。
---@param ip? string Peer IP to record (for conn:peer). / 记录的对端 IP（供 conn:peer 使用）。
---@param port? integer Peer port to record. / 记录的对端端口。
---@return xnet.connection|nil conn The connection, or nil + error. / 连接对象；失败时返回 nil + 错误。
---@return string? err Error message on failure. / 失败时的错误信息。
function xnet.attach(fd, handler, ip, port) end

---Alias of xnet.attach. / xnet.attach 的别名。
---@param fd integer OS socket file descriptor. / OS 套接字文件描述符。
---@param handler xnet.handler Connection callback table. / 连接回调表。
---@param ip? string Peer IP to record. / 记录的对端 IP。
---@param port? integer Peer port to record. / 记录的对端端口。
---@return xnet.connection|nil conn The connection, or nil + error. / 连接对象；失败时返回 nil + 错误。
---@return string? err Error message on failure. / 失败时的错误信息。
function xnet.connect_fd(fd, handler, ip, port) end

---Close a raw OS socket fd directly (cleanup after a failed detach + post).
---直接关闭一个原始 OS 套接字 fd（detach + post 失败后的清理）。
---@param fd integer OS socket file descriptor. / OS 套接字文件描述符。
function xnet.close_fd(fd) end

---Return `n` cryptographically random bytes from the OS RNG.
---返回 n 个来自操作系统 RNG 的密码学随机字节。
---@param n integer Number of bytes, 1..4096. / 字节数，范围 1..4096。
---@return string bytes Random byte string of length n. / 长度为 n 的随机字节串。
function xnet.random_bytes(n) end

---Adopt an fd and run a server-side TLS handshake before on_connect (HTTPS build).
---接管一个 fd 并在 on_connect 前完成服务端 TLS 握手（HTTPS 构建）。
---`ip`/`port` may be omitted, passing the tls_config as the 3rd argument.
---ip/port 可省略，此时把 tls_config 作为第 3 个参数传入。
---@param fd integer OS socket file descriptor. / OS 套接字文件描述符。
---@param handler xnet.handler Connection callback table. / 连接回调表。
---@param ip? string Peer IP to record. / 记录的对端 IP。
---@param port? integer Peer port to record. / 记录的对端端口。
---@param tls_config xnet.tls_server_config Server certificate/key configuration. / 服务端证书/密钥配置。
---@return xnet.tls_connection|nil conn The TLS connection, or nil + error. / TLS 连接；失败时返回 nil + 错误。
---@return string? err Error message on failure. / 失败时的错误信息。
function xnet.attach_tls(fd, handler, ip, port, tls_config) end

---Open an outbound TLS connection (client handshake, then on_connect; HTTPS build).
---发起一个出站 TLS 连接（客户端握手后触发 on_connect；HTTPS 构建）。
---@param host string Remote host (also used for SNI and cert name check). / 远端主机（同时用于 SNI 与证书名校验）。
---@param port integer Remote port. / 远端端口。
---@param handler xnet.handler Connection callback table. / 连接回调表。
---@param tls_config? xnet.tls_client_config Client TLS options (verify, ca_file, server_name...). / 客户端 TLS 选项。
---@return xnet.tls_connection|nil conn The TLS connection, or nil + error. / TLS 连接；失败时返回 nil + 错误。
---@return string? err Error message on failure. / 失败时的错误信息。
function xnet.connect_tls(host, port, handler, tls_config) end

-- xpoll event mask constants / xpoll 事件掩码常量
xnet.READABLE = 1
xnet.WRITABLE = 2
xnet.ERROR = 4
xnet.CLOSE = 8

-- ===========================================================================
-- Connection / 连接
-- ===========================================================================

---@class xnet.connection
local connection = {}

---The OS socket fd, or nil once closed.
---OS 套接字 fd；关闭后为 nil。
---@return integer|nil fd Socket descriptor or nil. / 套接字描述符或 nil。
function connection:fd() end

---Peer IP and port (nil components when unknown).
---对端 IP 与端口（未知部分为 nil）。
---@return string|nil ip Peer IP. / 对端 IP。
---@return integer|nil port Peer port. / 对端端口。
function connection:peer() end

---Whether the connection is closed (or its channel has shut down).
---连接是否已关闭（或其通道已停止）。
---@return boolean closed True when closed. / 已关闭时返回 true。
function connection:is_closed() end

---Close the connection.
---关闭连接。
---@param reason? string Reason string passed to on_close, defaults to "closed". / 传给 on_close 的原因字符串，默认 "closed"。
---@return boolean ok Always true. / 恒为 true。
function connection:close(reason) end

---Send one framed packet (the framing prefix/delimiter is applied for you).
---发送一个分帧的包（分帧前缀/分隔符会自动添加）。
---@param data string Payload bytes. / 负载字节。
---@return boolean ok True on success; false + reason otherwise. / 成功返回 true；否则返回 false + 原因。
---@return string? err "send buffer full" / "closed" / "write_error". / 错误原因。
function connection:send(data) end

---Send raw bytes with no framing applied.
---发送原始字节，不做任何分帧。
---@param data string Raw bytes to write. / 要写入的原始字节。
---@return boolean ok True on success; false + reason otherwise. / 成功返回 true；否则返回 false + 原因。
---@return string? err "send buffer full" / "closed" / "write_error". / 错误原因。
function connection:send_raw(data) end

---Alias of connection:send (framed packet). / connection:send 的别名（分帧包）。
---@param data string Payload bytes. / 负载字节。
---@return boolean ok True on success; false + reason otherwise. / 成功返回 true；否则返回 false + 原因。
---@return string? err Failure reason. / 失败原因。
function connection:send_packet(data) end

---Send a header followed by a file body, streamed by the C side (zero-copy where possible).
---发送一个头部，随后是文件内容，由 C 侧流式发送（尽可能零拷贝）。
---@param header string Bytes written before the file (e.g. an HTTP response header). / 文件之前写入的字节（如 HTTP 响应头）。
---@param path string File path to stream. / 要流式发送的文件路径。
---@param offset? integer Start offset in the file, defaults to 0. / 文件起始偏移，默认 0。
---@param length? integer Bytes to send, defaults to -1 (to end of file). / 要发送的字节数，默认 -1（到文件末尾）。
---@return boolean ok True on success; false + reason otherwise. / 成功返回 true；否则返回 false + 原因。
---@return string? err Failure reason. / 失败原因。
function connection:send_file_response(header, path, offset, length) end

---Replace the connection's handler callback table.
---替换连接的 handler 回调表。
---@param handler xnet.handler New callback table. / 新的回调表。
---@return xnet.connection self The connection, for chaining. / 连接本身，便于链式调用。
function connection:set_handler(handler) end

---Set the stream framing mode and/or buffer limits.
---设置流分帧模式与/或缓冲限制。
---Modes: "raw", "len32"/"len32be", "len16"/"len16be", "line"/"crlf"/"delimiter".
---Pass a mode string (with optional "\r\n" delimiter) or an xnet.framing table.
---模式："raw"、"len32"/"len32be"、"len16"/"len16be"、"line"/"crlf"/"delimiter"。
---可传模式字符串（带可选 "\r\n" 分隔符）或 xnet.framing 表。
---@param mode string|xnet.framing Mode string or framing options table. / 模式字符串或分帧选项表。
---@param delimiter? string Delimiter when `mode` is a string line/crlf mode. / 当 mode 为字符串行模式时的分隔符。
---@return xnet.connection self The connection, for chaining. / 连接本身，便于链式调用。
function connection:set_framing(mode, delimiter) end

---Enable per-packet AEAD encryption on this channel.
---在该通道上启用逐包 AEAD 加密。
---Keys are 32-byte strings (one per direction); salts are 4-byte nonce prefixes.
---send_salt must be unique per (key, direction) for the program's lifetime; with
---static keys, generate it with xnet.random_bytes(4) and exchange in the clear.
---密钥为 32 字节字符串（每方向一个）；盐为 4 字节 nonce 前缀。send_salt 在程序生命周期内
---对每个 (key, 方向) 必须唯一；静态密钥时用 xnet.random_bytes(4) 生成并明文交换。
---@param send_key string 32-byte key for outbound packets. / 出站包的 32 字节密钥。
---@param recv_key string 32-byte key for inbound packets. / 入站包的 32 字节密钥。
---@param send_salt string 4-byte nonce prefix for this side. / 本端的 4 字节 nonce 前缀。
---@param recv_salt string Peer's send_salt (4 bytes). / 对端的 send_salt（4 字节）。
---@return xnet.connection self The connection, for chaining. / 连接本身，便于链式调用。
function connection:enable_aead(send_key, recv_key, send_salt, recv_salt) end

---Clear AEAD transforms; the channel returns to plaintext.
---清除 AEAD 变换；通道恢复为明文。
---@return xnet.connection self The connection, for chaining. / 连接本身，便于链式调用。
function connection:disable_aead() end

---Detach from xpoll and return the raw fd WITHOUT closing it.
---从 xpoll 分离并返回原始 fd，但不关闭它。
---The Lua conn is closed afterwards (further sends raise). Hand the fd to another
---thread via xthread.post + xnet.attach, or close it with xnet.close_fd.
---之后 Lua 连接对象即关闭（再发送会报错）。可经 xthread.post + xnet.attach 把 fd 交给
---其他线程，或用 xnet.close_fd 关闭它。
---@return integer fd The surrendered OS socket fd. / 交出的 OS 套接字 fd。
function connection:detach() end

-- ===========================================================================
-- Listener / 监听器
-- ===========================================================================

---@class xnet.listener
local listener = {}

---The listening socket fd, or nil once closed.
---监听套接字 fd；关闭后为 nil。
---@return integer|nil fd Socket descriptor or nil. / 套接字描述符或 nil。
function listener:fd() end

---Stop listening and close the socket.
---停止监听并关闭套接字。
---@param reason? string Reason passed to the listener's on_close, defaults to "closed". / 传给监听器 on_close 的原因，默认 "closed"。
---@return boolean ok Always true. / 恒为 true。
function listener:close(reason) end

-- ===========================================================================
-- TLS connection (HTTPS builds only) / TLS 连接（仅 HTTPS 构建）
--
-- Server-side config for xnet.attach_tls.
-- xnet.attach_tls 的服务端配置。
---@class xnet.tls_server_config
---PEM certificate file path. Alias: `cert`. / PEM 证书文件路径。别名：cert。
---@field cert_file? string
---@field cert? string
---PEM private key file path. Alias: `key`. / PEM 私钥文件路径。别名：key。
---@field key_file? string
---@field key? string
---Private key password, if encrypted. / 私钥密码（若加密）。
---@field password? string
---CA file; when present, client certificates are requested and verified. / CA 文件；存在时会请求并校验客户端证书。
---@field ca_file? string
---Maximum decoded packet size in bytes. / 单个解析包的最大字节数。
---@field max_packet? integer
---Maximum send-buffer size in bytes. / 发送缓冲上限字节数。
---@field max_send? integer

-- Client-side config for xnet.connect_tls.
-- xnet.connect_tls 的客户端配置。
---@class xnet.tls_client_config
---Verify the server certificate chain (default true). / 校验服务端证书链（默认 true）。
---@field verify? boolean
---CA bundle file path for verification. / 用于校验的 CA 包文件路径。
---@field ca_file? string
---Override the SNI / cert-check hostname. / 覆盖 SNI / 证书校验所用主机名。
---@field server_name? string
---Maximum decoded packet size in bytes. / 单个解析包的最大字节数。
---@field max_packet? integer
---Maximum send-buffer size in bytes. / 发送缓冲上限字节数。
---@field max_send? integer
-- ===========================================================================

---@class xnet.tls_connection
local tls_connection = {}

---The OS socket fd, or nil once closed. / OS 套接字 fd；关闭后为 nil。
---@return integer|nil fd Socket descriptor or nil. / 套接字描述符或 nil。
function tls_connection:fd() end

---Peer IP and port. / 对端 IP 与端口。
---@return string|nil ip Peer IP. / 对端 IP。
---@return integer|nil port Peer port. / 对端端口。
function tls_connection:peer() end

---Subject DN of the peer's presented certificate, if any.
---对端所出示证书的主体 DN（如有）。
---@return string|nil subject Certificate subject, or nil. / 证书主体；无则为 nil。
function tls_connection:peer_cert_subject() end

---Whether the TLS connection is closed. / TLS 连接是否已关闭。
---@return boolean closed True when closed. / 已关闭时返回 true。
function tls_connection:is_closed() end

---Close the TLS connection. / 关闭 TLS 连接。
---@param reason? string Reason passed to on_close. / 传给 on_close 的原因。
---@return boolean ok Always true. / 恒为 true。
function tls_connection:close(reason) end

---Send a framed packet over TLS. / 通过 TLS 发送一个分帧包。
---@param data string Payload bytes. / 负载字节。
---@return boolean ok True on success; false + reason otherwise. / 成功返回 true；否则返回 false + 原因。
---@return string? err Failure reason. / 失败原因。
function tls_connection:send(data) end

---Send raw bytes over TLS with no framing. / 通过 TLS 发送原始字节，不分帧。
---@param data string Raw bytes. / 原始字节。
---@return boolean ok True on success; false + reason otherwise. / 成功返回 true；否则返回 false + 原因。
---@return string? err Failure reason. / 失败原因。
function tls_connection:send_raw(data) end

---Alias of tls_connection:send_raw. / tls_connection:send_raw 的别名。
---@param data string Raw bytes. / 原始字节。
---@return boolean ok True on success; false + reason otherwise. / 成功返回 true；否则返回 false + 原因。
---@return string? err Failure reason. / 失败原因。
function tls_connection:send_packet(data) end

---Send a header then a file body over TLS. / 通过 TLS 发送头部再发送文件内容。
---@param header string Bytes written before the file. / 文件之前写入的字节。
---@param path string File path to stream. / 要流式发送的文件路径。
---@param offset? integer Start offset, defaults to 0. / 起始偏移，默认 0。
---@param length? integer Bytes to send, defaults to -1 (to end of file). / 要发送的字节数，默认 -1（到文件末尾）。
---@return boolean ok True on success; false + reason otherwise. / 成功返回 true；否则返回 false + 原因。
---@return string? err Failure reason. / 失败原因。
function tls_connection:send_file_response(header, path, offset, length) end

---Replace the handler callback table. / 替换 handler 回调表。
---@param handler xnet.handler New callback table. / 新的回调表。
---@return xnet.tls_connection self The connection, for chaining. / 连接本身，便于链式调用。
function tls_connection:set_handler(handler) end

---Set the stream framing mode and/or buffer limits (see connection:set_framing).
---设置流分帧模式与/或缓冲限制（参见 connection:set_framing）。
---@param mode string|xnet.framing Mode string or framing options table. / 模式字符串或分帧选项表。
---@param delimiter? string Delimiter for line/crlf string mode. / 行/crlf 字符串模式的分隔符。
---@return xnet.tls_connection self The connection, for chaining. / 连接本身，便于链式调用。
function tls_connection:set_framing(mode, delimiter) end

return xnet
