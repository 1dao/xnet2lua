---@meta
---@diagnostic disable: unreachable-code, unused-local
do return end

-- LuaLS metadata for the native xutils module.
-- LuaLS 使用的 xutils 原生模块元数据。
-- This file is metadata-only and does not execute at runtime.
-- 本文件仅用于元数据，不会在运行时执行。
--
-- Grab-bag of C helpers: JSON (yyjson), config access, recursive directory
-- scan, and one canonical C implementation of the hashes / HMAC / base64 / hex
-- used across the project (replacing the per-module pure-Lua copies).
-- C 辅助函数集合：JSON（yyjson）、配置读取、递归目录扫描，以及项目中通用的哈希 /
-- HMAC / base64 / hex 的唯一 C 实现（替代各模块各自的纯 Lua 副本）。

---@class xutils
local xutils = {}

-- A unique sentinel that round-trips JSON `null`. Use it as a table value to
-- emit null, and test decoded values against it (`v == xutils.json_null`).
-- 用于往返 JSON null 的唯一哨兵值。作为表的值写入即输出 null，解码后可用
-- v == xutils.json_null 判断。
xutils.json_null = {}

-- JSON / JSON

---Encode a Lua value to a JSON string.
---把一个 Lua 值编码为 JSON 字符串。
---Tables with sequential integer keys become arrays, otherwise objects.
---Use xutils.json_null for an explicit JSON null. Returns nil (NOT an error)
---when the value contains invalid UTF-8, so sanitize strings beforehand.
---具有连续整数键的表编码为数组，否则编码为对象。用 xutils.json_null 表示显式的
---JSON null。当值含非法 UTF-8 时返回 nil（而非抛错），因此请先清洗字符串。
---@param value any Value to serialize (nil/boolean/number/string/table). / 要序列化的值。
---@return string|nil json JSON text, or nil + error on failure. / JSON 文本；失败时返回 nil + 错误。
---@return string? err Error message on failure. / 失败时的错误信息。
function xutils.json_pack(value) end

---Decode a JSON string to a Lua value.
---把 JSON 字符串解码为 Lua 值。
---JSON null decodes to xutils.json_null.
---JSON 的 null 解码为 xutils.json_null。
---@param json string JSON text. / JSON 文本。
---@return any|nil value Decoded value, or nil + error on parse failure. / 解码出的值；解析失败时返回 nil + 错误。
---@return string? err Parse error with byte position on failure. / 失败时带字节位置的解析错误。
function xutils.json_unpack(json) end

-- Config / 配置

---Load a key=value config file into the process-global config store.
---把 key=value 配置文件加载到进程级配置存储。
---@param path string Config file path. / 配置文件路径。
---@return boolean ok True on success; false + error on failure. / 成功返回 true；失败返回 false + 错误。
---@return string? err Error message on failure. / 失败时的错误信息。
function xutils.load_config(path) end

---Read a config value by key, with an optional default.
---按键读取配置值，可带默认值。
---@param key string Config key. / 配置键。
---@param default? string Value returned when the key is absent. / 键不存在时返回的值。
---@return string|nil value Config value, the default, or nil. / 配置值、默认值或 nil。
function xutils.get_config(key, default) end

-- Filesystem / 文件系统

---Recursively scan a directory for regular files (symlinks followed).
---递归扫描目录中的常规文件（会跟随符号链接）。
---Returns a flat array; each entry has the absolute-ish `path` (joined onto
---`root`) and the `rel` path relative to `root` (always forward-slashed).
---返回扁平数组；每项含 path（拼接在 root 之上）与相对 root 的 rel（始终使用正斜杠）。
---@param root string Directory to scan. / 要扫描的目录。
---@return { path: string, rel: string }[]|nil files Array of file entries, or nil + error. / 文件条目数组；失败时返回 nil + 错误。
---@return string? err Error message on failure. / 失败时的错误信息。
function xutils.scan_dir(root) end

-- Hashes (raw digest + lowercase-hex variant) / 哈希（原始摘要 + 小写十六进制变体）

---SHA-1 digest (20 raw bytes). / SHA-1 摘要（20 个原始字节）。
---@param data string Input bytes. / 输入字节。
---@return string digest 20-byte raw digest. / 20 字节原始摘要。
function xutils.sha1(data) end
---SHA-1 digest as 40 lowercase hex chars. / SHA-1 摘要的 40 位小写十六进制字符串。
---@param data string Input bytes. / 输入字节。
---@return string hex Lowercase hex digest. / 小写十六进制摘要。
function xutils.sha1_hex(data) end

---SHA-256 digest (32 raw bytes). / SHA-256 摘要（32 个原始字节）。
---@param data string Input bytes. / 输入字节。
---@return string digest 32-byte raw digest. / 32 字节原始摘要。
function xutils.sha256(data) end
---SHA-256 digest as 64 lowercase hex chars. / SHA-256 摘要的 64 位小写十六进制字符串。
---@param data string Input bytes. / 输入字节。
---@return string hex Lowercase hex digest. / 小写十六进制摘要。
function xutils.sha256_hex(data) end

---SHA-512 digest (64 raw bytes). / SHA-512 摘要（64 个原始字节）。
---@param data string Input bytes. / 输入字节。
---@return string digest 64-byte raw digest. / 64 字节原始摘要。
function xutils.sha512(data) end
---SHA-512 digest as 128 lowercase hex chars. / SHA-512 摘要的 128 位小写十六进制字符串。
---@param data string Input bytes. / 输入字节。
---@return string hex Lowercase hex digest. / 小写十六进制摘要。
function xutils.sha512_hex(data) end

---MD5 digest (16 raw bytes). / MD5 摘要（16 个原始字节）。
---@param data string Input bytes. / 输入字节。
---@return string digest 16-byte raw digest. / 16 字节原始摘要。
function xutils.md5(data) end
---MD5 digest as 32 lowercase hex chars. / MD5 摘要的 32 位小写十六进制字符串。
---@param data string Input bytes. / 输入字节。
---@return string hex Lowercase hex digest. / 小写十六进制摘要。
function xutils.md5_hex(data) end

-- HMAC / HMAC

---HMAC-SHA-256 (32 raw bytes). / HMAC-SHA-256（32 个原始字节）。
---@param key string Secret key. / 密钥。
---@param message string Message bytes. / 消息字节。
---@return string mac 32-byte raw MAC. / 32 字节原始 MAC。
function xutils.hmac_sha256(key, message) end
---HMAC-SHA-256 as 64 lowercase hex chars. / HMAC-SHA-256 的 64 位小写十六进制字符串。
---@param key string Secret key. / 密钥。
---@param message string Message bytes. / 消息字节。
---@return string hex Lowercase hex MAC. / 小写十六进制 MAC。
function xutils.hmac_sha256_hex(key, message) end

---HMAC-SHA-1 (20 raw bytes). / HMAC-SHA-1（20 个原始字节）。
---@param key string Secret key. / 密钥。
---@param message string Message bytes. / 消息字节。
---@return string mac 20-byte raw MAC. / 20 字节原始 MAC。
function xutils.hmac_sha1(key, message) end
---HMAC-SHA-1 as 40 lowercase hex chars. / HMAC-SHA-1 的 40 位小写十六进制字符串。
---@param key string Secret key. / 密钥。
---@param message string Message bytes. / 消息字节。
---@return string hex Lowercase hex MAC. / 小写十六进制 MAC。
function xutils.hmac_sha1_hex(key, message) end

-- Encodings / 编码

---Standard base64 encode (padded with `=`). / 标准 base64 编码（用 = 补位）。
---@param data string Input bytes. / 输入字节。
---@return string b64 Base64 text. / base64 文本。
function xutils.base64_encode(data) end

---Decode base64 (accepts standard and url-safe alphabets; padding/whitespace ignored).
---解码 base64（兼容标准与 url-safe 字母表；忽略补位与空白）。
---@param text string Base64 text. / base64 文本。
---@return string|nil data Decoded bytes, or nil + "invalid base64". / 解码字节；失败时返回 nil + "invalid base64"。
---@return string? err "invalid base64" on a bad character. / 遇非法字符时为 "invalid base64"。
function xutils.base64_decode(text) end

---URL-safe base64 encode (no padding, `-_` alphabet). / url-safe base64 编码（无补位，使用 -_ 字母表）。
---@param data string Input bytes. / 输入字节。
---@return string b64 URL-safe base64 text. / url-safe base64 文本。
function xutils.base64url_encode(data) end

---Decode url-safe base64 (alias of base64_decode; both alphabets accepted).
---解码 url-safe base64（base64_decode 的别名；两种字母表皆可）。
---@param text string URL-safe base64 text. / url-safe base64 文本。
---@return string|nil data Decoded bytes, or nil + "invalid base64". / 解码字节；失败时返回 nil + "invalid base64"。
---@return string? err "invalid base64" on a bad character. / 遇非法字符时为 "invalid base64"。
function xutils.base64url_decode(text) end

---Lowercase-hex encode. / 小写十六进制编码。
---@param data string Input bytes. / 输入字节。
---@return string hex Lowercase hex string. / 小写十六进制字符串。
function xutils.hex_encode(data) end

---Decode a hex string (case-insensitive). / 解码十六进制字符串（大小写不敏感）。
---@param hex string Hex text (even length). / 十六进制文本（长度需为偶数）。
---@return string|nil data Decoded bytes, or nil + error. / 解码字节；失败时返回 nil + 错误。
---@return string? err "odd hex length" or "invalid hex" on failure. / 失败时为 "odd hex length" 或 "invalid hex"。
function xutils.hex_decode(hex) end

return xutils
