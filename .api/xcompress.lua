---@meta
---@diagnostic disable: unreachable-code, unused-local
do return end

-- LuaLS metadata for the native xcompress module.
-- LuaLS 使用的 xcompress 原生模块元数据。
-- This file is metadata-only and does not execute at runtime.
-- 本文件仅用于元数据，不会在运行时执行。
--
-- libdeflate bindings: gzip / raw deflate / zlib compression plus CRC-32 and
-- Adler-32 checksums. Two usage styles:
--   * handle-based (preferred for repeated use; the level is held on the handle)
--   * one-shot (allocates a compressor internally; avoid in hot loops)
-- A handle is NOT safe to share across threads; since xnet runs one Lua state
-- per OS thread this is satisfied as long as handles are not smuggled across.
-- libdeflate 绑定：gzip / 原始 deflate / zlib 压缩，以及 CRC-32 与 Adler-32 校验和。
-- 两种用法：
--   * 句柄式（反复使用时优先；压缩级别保存在句柄上）
--   * 一次性（内部临时分配压缩器；避免在热循环中使用）
-- 句柄不可跨线程共享；由于 xnet 每个 OS 线程一个 Lua 状态机，只要不把句柄偷渡到
-- 别的线程即满足要求。

---@class xcompress
local xcompress = {}

-- A reusable compressor. Holds a compression level; the underlying libdeflate
-- compressor is allocated lazily on first use and re-allocated if the level
-- changes. Methods accept variadic string parts that are concatenated then
-- compressed in one shot.
-- 可复用的压缩器。保存压缩级别；底层 libdeflate 压缩器在首次使用时惰性分配，级别变化
-- 时重新分配。方法接受可变数量的字符串分片，先拼接再一次性压缩。
---@class xcompress.compressor
local compressor = {}

---Set the compression level, freeing the cached compressor if it changed.
---设置压缩级别；若级别变化则释放已缓存的压缩器。
---@param level integer 0..12, or -1 for the default (6). / 0..12，或 -1 表示默认（6）。
---@return xcompress.compressor self The compressor, for chaining. / 压缩器本身，便于链式调用。
function compressor:set_level(level) end

---Get the current compression level.
---获取当前压缩级别。
---@return integer level Current level. / 当前级别。
function compressor:level() end

---Gzip-compress the concatenation of all string arguments.
---对所有字符串参数拼接后进行 gzip 压缩。
---@param ... string One or more byte-string parts. / 一个或多个字节串分片。
---@return string compressed Gzip stream. / gzip 数据流。
function compressor:gzip(...) end

---Raw-deflate-compress the concatenation of all string arguments.
---对所有字符串参数拼接后进行原始 deflate 压缩。
---@param ... string One or more byte-string parts. / 一个或多个字节串分片。
---@return string compressed Raw DEFLATE stream. / 原始 DEFLATE 数据流。
function compressor:deflate(...) end

---Zlib-compress the concatenation of all string arguments.
---对所有字符串参数拼接后进行 zlib 压缩。
---@param ... string One or more byte-string parts. / 一个或多个字节串分片。
---@return string compressed Zlib stream. / zlib 数据流。
function compressor:zlib(...) end

---Free the underlying compressor immediately (also done on GC).
---立即释放底层压缩器（GC 时也会释放）。
function compressor:close() end

-- A reusable decompressor. The underlying libdeflate decompressor is allocated
-- lazily on first use. Each method needs an upper bound on the decompressed
-- size, since the format does not always carry the original length.
-- 可复用的解压器。底层 libdeflate 解压器在首次使用时惰性分配。每个方法都需要一个解压
-- 后大小的上界，因为压缩格式并不总是携带原始长度。
---@class xcompress.decompressor
local decompressor = {}

---Gunzip a gzip stream, capped at `max_out` bytes.
---对 gzip 数据流解压，输出上限为 max_out 字节。
---@param data string Gzip byte string. / gzip 字节串。
---@param max_out integer Maximum decompressed size in bytes (> 0). / 解压后最大字节数（> 0）。
---@return string|nil data Decompressed bytes, or nil + error on failure. / 解压后的字节；失败时返回 nil + 错误。
---@return string? err Error code: "bad_data" / "short_output" / "insufficient_space". / 错误码。
function decompressor:gzip(data, max_out) end

---Inflate a raw DEFLATE stream, capped at `max_out` bytes.
---对原始 DEFLATE 数据流解压，输出上限为 max_out 字节。
---@param data string Raw DEFLATE byte string. / 原始 DEFLATE 字节串。
---@param max_out integer Maximum decompressed size in bytes (> 0). / 解压后最大字节数（> 0）。
---@return string|nil data Decompressed bytes, or nil + error on failure. / 解压后的字节；失败时返回 nil + 错误。
---@return string? err Error code on failure. / 失败时的错误码。
function decompressor:deflate(data, max_out) end

---Decompress a zlib stream, capped at `max_out` bytes.
---对 zlib 数据流解压，输出上限为 max_out 字节。
---@param data string Zlib byte string. / zlib 字节串。
---@param max_out integer Maximum decompressed size in bytes (> 0). / 解压后最大字节数（> 0）。
---@return string|nil data Decompressed bytes, or nil + error on failure. / 解压后的字节；失败时返回 nil + 错误。
---@return string? err Error code on failure. / 失败时的错误码。
function decompressor:zlib(data, max_out) end

---Free the underlying decompressor immediately (also done on GC).
---立即释放底层解压器（GC 时也会释放）。
function decompressor:close() end

-- Handles / 句柄

---Create a reusable compressor.
---创建一个可复用的压缩器。
---@param level? integer 0..12, or -1/omitted for the default (6). / 0..12，或 -1/省略表示默认（6）。
---@return xcompress.compressor compressor New compressor handle. / 新的压缩器句柄。
function xcompress.new_compressor(level) end

---Create a reusable decompressor.
---创建一个可复用的解压器。
---@return xcompress.decompressor decompressor New decompressor handle. / 新的解压器句柄。
function xcompress.new_decompressor() end

-- One-shot helpers / 一次性辅助函数

---Gzip-compress a single string (allocates a compressor internally).
---对单个字符串进行 gzip 压缩（内部临时分配压缩器）。
---@param data string Input bytes. / 输入字节。
---@param level? integer 0..12, or -1/omitted for the default (6). / 0..12，或 -1/省略表示默认（6）。
---@return string compressed Gzip stream. / gzip 数据流。
function xcompress.gzip(data, level) end

---Gunzip a single gzip string.
---对单个 gzip 字符串解压。
---@param data string Gzip bytes. / gzip 字节。
---@param max_out integer Maximum decompressed size in bytes (> 0). / 解压后最大字节数（> 0）。
---@return string|nil data Decompressed bytes, or nil + error on failure. / 解压后的字节；失败时返回 nil + 错误。
---@return string? err Error code on failure. / 失败时的错误码。
function xcompress.gunzip(data, max_out) end

---Raw-deflate-compress a single string.
---对单个字符串进行原始 deflate 压缩。
---@param data string Input bytes. / 输入字节。
---@param level? integer 0..12, or -1/omitted for the default (6). / 0..12，或 -1/省略表示默认（6）。
---@return string compressed Raw DEFLATE stream. / 原始 DEFLATE 数据流。
function xcompress.deflate(data, level) end

---Inflate a single raw DEFLATE string.
---对单个原始 DEFLATE 字符串解压。
---@param data string Raw DEFLATE bytes. / 原始 DEFLATE 字节。
---@param max_out integer Maximum decompressed size in bytes (> 0). / 解压后最大字节数（> 0）。
---@return string|nil data Decompressed bytes, or nil + error on failure. / 解压后的字节；失败时返回 nil + 错误。
---@return string? err Error code on failure. / 失败时的错误码。
function xcompress.inflate(data, max_out) end

---Zlib-compress a single string.
---对单个字符串进行 zlib 压缩。
---@param data string Input bytes. / 输入字节。
---@param level? integer 0..12, or -1/omitted for the default (6). / 0..12，或 -1/省略表示默认（6）。
---@return string compressed Zlib stream. / zlib 数据流。
function xcompress.zlib_compress(data, level) end

---Decompress a single zlib string.
---对单个 zlib 字符串解压。
---@param data string Zlib bytes. / zlib 字节。
---@param max_out integer Maximum decompressed size in bytes (> 0). / 解压后最大字节数（> 0）。
---@return string|nil data Decompressed bytes, or nil + error on failure. / 解压后的字节；失败时返回 nil + 错误。
---@return string? err Error code on failure. / 失败时的错误码。
function xcompress.zlib_decompress(data, max_out) end

-- Checksums (variadic, state-free) / 校验和（可变参数、无状态）

---CRC-32 over the concatenation of all string arguments, seeded from 0.
---对所有字符串参数拼接后计算 CRC-32，初始种子为 0。
---@param ... string One or more byte-string parts. / 一个或多个字节串分片。
---@return integer crc 32-bit CRC value. / 32 位 CRC 值。
function xcompress.crc32(...) end

---Continue a running CRC-32 with more string parts.
---以更多字符串分片续算一个进行中的 CRC-32。
---@param running integer Previous CRC value to continue from. / 续算所用的上一个 CRC 值。
---@param ... string Additional byte-string parts. / 追加的字节串分片。
---@return integer crc Updated 32-bit CRC value. / 更新后的 32 位 CRC 值。
function xcompress.crc32_update(running, ...) end

---Adler-32 over the concatenation of all string arguments, seeded from 1.
---对所有字符串参数拼接后计算 Adler-32，初始种子为 1。
---@param ... string One or more byte-string parts. / 一个或多个字节串分片。
---@return integer adler 32-bit Adler value. / 32 位 Adler 值。
function xcompress.adler32(...) end

---Continue a running Adler-32 with more string parts.
---以更多字符串分片续算一个进行中的 Adler-32。
---@param running integer Previous Adler value to continue from. / 续算所用的上一个 Adler 值。
---@param ... string Additional byte-string parts. / 追加的字节串分片。
---@return integer adler Updated 32-bit Adler value. / 更新后的 32 位 Adler 值。
function xcompress.adler32_update(running, ...) end

return xcompress
