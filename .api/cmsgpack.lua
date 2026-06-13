---@meta
---@diagnostic disable: unreachable-code, unused-local
do return end

-- LuaLS metadata for the native cmsgpack module.
-- LuaLS 使用的 cmsgpack 原生模块元数据。
-- This file is metadata-only and does not execute at runtime.
-- 本文件仅用于元数据，不会在运行时执行。
--
-- MessagePack encode/decode (Salvatore Sanfilippo's lua-cmsgpack). Statically
-- linked and pre-required into every xnet Lua state, so `require("cmsgpack")`
-- always succeeds. xthread uses it as the wire format for post/rpc payloads.
-- MessagePack 编解码（Salvatore Sanfilippo 的 lua-cmsgpack）。静态链接并预加载到
-- 每个 xnet Lua 状态机中，因此 require("cmsgpack") 始终可用；xthread 用它作为
-- post/rpc 消息的线缆格式。

---@class cmsgpack
local cmsgpack = {}

-- Pack / 打包

---Serialize one or more Lua values into a single MessagePack byte string.
---将一个或多个 Lua 值序列化为单个 MessagePack 字节串。
---Each argument is encoded independently and the results are concatenated, so
---`pack(a, b)` produces a buffer that `unpack` decodes back into `a, b`.
---每个参数独立编码后拼接，因此 pack(a, b) 得到的缓冲区可由 unpack 还原为 a, b。
---@param ... any One or more values (nil/boolean/number/string/table). / 一个或多个值（nil/布尔/数字/字符串/表）。
---@return string packed MessagePack byte string. / MessagePack 字节串。
function cmsgpack.pack(...) end

-- Unpack / 解包

---Decode every top-level value contained in a MessagePack string.
---解码 MessagePack 字符串中的所有顶层值。
---Raises a Lua error on truncated or malformed input.
---输入被截断或格式错误时抛出 Lua 错误。
---@param data string MessagePack byte string. / MessagePack 字节串。
---@return any ... All decoded values, in order. / 按顺序解码出的所有值。
function cmsgpack.unpack(data) end

---Decode exactly one value starting at a byte offset, for streaming buffers.
---从指定字节偏移开始只解码一个值，用于流式缓冲。
---@param data string MessagePack byte string. / MessagePack 字节串。
---@param offset? integer 0-based start offset, defaults to 0. / 从 0 开始的起始偏移，默认 0。
---@return integer nextOffset Offset of the next value, or -1 when the buffer is fully consumed. / 下一个值的偏移；缓冲区读完时为 -1。
---@return any value The single decoded value. / 解码出的单个值。
function cmsgpack.unpack_one(data, offset) end

---Decode up to `limit` values starting at a byte offset.
---从指定字节偏移开始最多解码 limit 个值。
---@param data string MessagePack byte string. / MessagePack 字节串。
---@param limit integer Maximum number of values to decode. / 最多解码的值个数。
---@param offset? integer 0-based start offset, defaults to 0. / 从 0 开始的起始偏移，默认 0。
---@return integer nextOffset Offset of the next value, or -1 when the buffer is fully consumed. / 下一个值的偏移；缓冲区读完时为 -1。
---@return any ... Up to `limit` decoded values. / 最多 limit 个解码出的值。
function cmsgpack.unpack_limit(data, limit, offset) end

-- Metadata / 元数据

---Module name string. / 模块名称字符串。
cmsgpack._NAME = ""
---Module version string. / 模块版本字符串。
cmsgpack._VERSION = ""
---Copyright string. / 版权字符串。
cmsgpack._COPYRIGHT = ""
---Short description string. / 简短描述字符串。
cmsgpack._DESCRIPTION = ""

return cmsgpack
