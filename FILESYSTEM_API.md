# Native filesystem utilities

These `require('xutils')` APIs work without shell commands on Windows, Linux,
macOS and Android. Lua `io.open`, `file:read/write`, `os.rename` and `os.remove`
provide file contents, renames and single-path removal.

- `mkdir_p(path)` creates parents and returns `true` or `nil, error`. An existing
  directory succeeds; an existing regular file fails.
- `list_dir(path [, limit])` lists one level, including empty directories.
  Returns `{ { name = string, dir = boolean }, ... }, truncated` or `nil, error`.
  `limit` is a positive integer; omitting it preserves unlimited enumeration.
- `stat(path)` returns `{ exists = true, type = "file" | "directory" | "link" |
  "other", size = bytes, mtime = Unix_seconds }`. Missing paths return
  `{ exists = false }`; other OS errors return `nil, error`. It does not follow
  symbolic links; Windows reparse points are reported as links.
- `rmtree(path)` recursively removes a tree without following links.
- `scan_dir(path)` is the older recursive files-only listing and follows links.

For bounded traversal, use `list_dir` and `stat` and skip `type == "link"`.
These are filesystem primitives, not a sandbox: callers enforce allowed roots
and obtain user permission for mutations. Windows path encoding follows the
existing ANSI filesystem bindings; POSIX/Android paths preserve UTF-8 bytes.

Regression: `bin/xnet tests/lua/xutils_filesystem_spec.lua` (use `xnet.exe` on Windows).
