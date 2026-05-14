# xnet2lua Documentation

Version: Based on [github.com/1dao/xnet2lua](https://github.com/1dao/xnet2lua)  
Language: C (Core) + Lua (Scripting Layer)  
Positioning: A high-performance asynchronous networking framework; Lua bindings enable production-grade multi-threaded networking on the scripting layer

---

## Table of Contents

1. Architecture Overview  
2. Building and Integration  
3. Program Entry and Thread Lifecycle  
4. xthread Module — Multithreading and Message Passing  
5. xnet Module — Asynchronous Networking  
6. Frame Protocols (Packetization Strategy)  
7. TLS / HTTPS Support  
8. HTTP Server  
9. cmsgpack Module — MessagePack Serialization  
10. xutils Module — Utility Functions  
11. Configuration Files  
12. Thread ID Constants  
13. Complete Example: TCP Server  
14. Complete Example: HTTP API Service  
15. Complete Example: Cross-thread RPC
16. Best Practices and Considerations
17. xadmin Console
18. xnats Cross-Process RPC
19. Hot Reload Protocol
20. Lua Debugging and VSCode Debugging

---

## 1. Architecture Overview

xnet2lua is divided into four layers:

```
┌─────────────────────────────────────────────────────┐
│            Lua Application Layer (Your business scripts)                 │
├────────────────────────────────────────┬────────────┤
│  xnet（network connections/listening）      │ xthread    │
│  xutils（JSON/Utilities）                   │（threads/RPC） │
│  cmsgpack（MessagePack）               │            │
├────────────────────────────────────────┴────────────┤
│  C core layer: xpoll / xchannel / xsock / xtimer        │
├─────────────────────────────────────────────────────┤
│  Third-party: mbedTLS / yyjson / minilua / libdeflate    │
└─────────────────────────────────────────────────────┘
```

**Key Design:**
- Each thread has an independent Lua State; threads are fully isolated
- Inter-thread communication via POST (asynchronous) or RPC (synchronous; implemented with coroutines internally)
- I/O multiplexing automatically selects epoll / kqueue / WSAPoll / poll depending on platform
- Network framing protocols supported: raw, len32 (4-byte length prefix), CRLF
- Third-party: mbedTLS / yyjson / minilua / libdeflate

---

## 2. Building and Integration

> ⚙️ **Build system reorganized.** The root Makefile now produces all three artifacts —
> `libxsock.a`, `bin/xnet`, and `bin/xthread_test` — in a single pass. The previous
> two-stage build (`make` at root, then `cd demo && make`) is **no longer required**.
> A new top-level `build.bat` provides an MSVC all-source build, and **LuaJIT** is now
> supported as an optional Lua backend.

### 2.1 One-shot build (GCC / MinGW / Linux / macOS)

```bash
cd xnet2lua

# Default: release + minilua + HTTP + HTTPS, output goes to bin/
make

# Build a single sub-target
make xnet            # only bin/xnet
make xthread_test    # only bin/xthread_test
make clean
```

Tunable variables (override on the command line as `KEY=VALUE`):

| Variable | Default | Values | Effect |
|----------|---------|--------|--------|
| `BUILD_MODE` | `release` | `release` / `debug` | `-O2 -DNDEBUG` ↔ `-O0 -g -DDEBUG` |
| `WITH_HTTP` | `1` | `1` / `0` | Compile HTTP code paths |
| `WITH_HTTPS` | `1` | `1` / `0` | Compile mbedTLS / HTTPS code paths |
| `WITH_IO_URING` | `0` | `1` / `0` | On Linux, define `XPOLL_USE_IO_URING` and `XCHANNEL_USE_IO_URING`; links `liburing` |
| `WITH_XDEBUG` | `0` | `1` / `0` | Compile the native Lua debugger into `bin/xnet`; this only adds the capability and does not start the debug service |
| `WITH_RPMALLOC` | `1` | `1` / `0` | Route the project's own `malloc`/`free` through rpmalloc via `xmacro.h`. With `=0` the macros pass through to libc and `rpmalloc.c` is not linked (see §2.7) |
| `LUA_BACKEND` | `minilua` | `minilua` / `luajit` | Use the embedded mini Lua or LuaJIT. For `luajit`, fetch the `3rd/luajit` submodule and build `libluajit.a` first |

```bash
# Examples
make BUILD_MODE=debug
make WITH_HTTPS=0
make WITH_XDEBUG=1                         # compile debugger support; runtime still needs XDEBUG_BOOT or xthread.xdebug_start
make WITH_IO_URING=1                       # Linux only
make LUA_BACKEND=luajit                    # see 2.5
```

> `demo/Makefile` is now a thin wrapper: every target it knows about just forwards to
> the root Makefile (`make -C ..`). Old paths keep working so existing scripts don't
> break.

### 2.2 Windows / MSVC build (`build.bat`)

The repository root now ships `build.bat` — an **all-source** MSVC build (it does
not consume `libxsock.a`) that auto-locates `vcvarsall.bat` and loads the x64
toolchain. `demo/build.bat` still works but only forwards arguments to the root
script.

```bat
:: Default release; produces bin\xnet.exe + bin\xthread_test.exe
build.bat

:: Switch to debug
build.bat debug

:: Disable HTTP / HTTPS
build.bat nohttp
build.bat nohttps

:: Disable rpmalloc; fall back to libc for the project's own allocations (see 2.7)
build.bat norpmalloc

:: Compile native Lua debugger support; this does not start the debug service
build.bat xdebug

:: Switch to the LuaJIT backend
:: (the first run automatically calls 3rd\luajit\src\msvcbuild.bat static
::  to produce lua51.lib if it isn't there yet)
build.bat luajit

:: Build a single target
build.bat xnet
build.bat xthread_test

:: Run the test suites (see 2.4)
build.bat test
build.bat test-c
build.bat test-lua-core
build.bat test-lua-external
build.bat test-lua-all

:: Run a single Lua script through the freshly built xnet
build.bat run-lua demo/xutils_main.lua
build.bat run-lua script=demo/xnet_main.lua

:: Clean
build.bat clean
```

Arguments compose freely, e.g. `build.bat debug luajit nohttps test-lua-core`.

### 2.3 Run demos

`bin/xnet` (or `bin/xnet.exe`) is a **generic Lua runner**. The first argument is
the Lua script to execute; subsequent `KEY=VALUE` pairs override config:

```bash
./bin/xnet demo/xnet_main.lua
./bin/xnet demo/xhttp_main.lua
./bin/xnet demo/xhttps_main.lua          # requires a WITH_HTTPS build
./bin/xnet demo/xredis_main.lua
./bin/xnet demo/xmysql_main.lua
./bin/xnet demo/xnats_main.lua SERVER_NAME=game1
./bin/xnet scripts/xpac/xpac_main.lua
```

CLI `KEY=VALUE` overrides win over `xnet.cfg`, but the key must be on the
whitelist in `g_arg_configs[]` inside `xnet_main.c`. When you add a new Lua
config option that you want to be CLI-overridable, remember to extend that array.

### 2.4 Test targets

The root Makefile bundles a small test harness that works on both the GCC/MinGW
and MSVC paths:

```bash
make test                  # = test-c + test-lua-core
make test-c                # only the C-level xthread_test binary
make test-lua-core         # the core Lua suite:
                           #   demo/xutils_main.lua, xtimer_main.lua, xtimerx_test.lua,
                           #   xlua_main.lua, xnet_main.lua, xrouter_test.lua,
                           #   xhttp_router_test.lua, xhttp_main.lua
make test-lua-external     # scripts that need external services
                           # (HTTPS certs, Redis, MySQL, NATS):
                           #   demo/xhttps_main.lua, xredis_main.lua,
                           #   xmysql_main.lua, xnats_main.lua
make test-lua-all          # core + external

# Run a single script through the freshly built bin/xnet
make run-lua SCRIPT=demo/xnet_main.lua
```

`build.bat` accepts the same target names (`build.bat test`,
`build.bat test-lua-core`, …) with identical semantics.

### 2.5 Lua backend: minilua vs LuaJIT

xnet2lua supports two Lua runtimes side by side:

- **minilua** (default, `-DLUA_EMBEDDED`): the single-header `3rd/minilua.h`,
  Lua 5.4 flavor, no external dependencies.
- **LuaJIT** (`-DXLUA_USE_LUAJIT=1`): links against `3rd/luajit/src/libluajit.a`
  on GCC/MinGW or `lua51.lib` on MSVC. Lua 5.1 + selected 5.2 extensions + JIT.

When LuaJIT is in use, the framework calls — once per Lua state, right after
`luaL_openlibs()`:

```c
luaJIT_setmode(L, 0, LUAJIT_MODE_ENGINE | LUAJIT_MODE_ON);
```

so the JIT is guaranteed to be on for the main thread and every worker thread.
The handful of APIs that Lua 5.1 lacks (`luaL_requiref`, `lua_isinteger`,
`luaL_tolstring`, plus the `LUA_MAXINTEGER` / `LUA_MININTEGER` bounds) are
polyfilled inline in `xnet_main.c`, `xlua/lua_xthread.c`, and
`xlua/lua_xutils.c`. **The xnet/xthread/xutils/cmsgpack binding APIs are
identical between the two backends** — application Lua code does not need any
module-name or signature changes.

> 💡 **Note for application code**: Lua 5.4's bitwise operators `& | ~ << >>`
> are a **syntax error** under LuaJIT (5.1). To stay portable across both
> backends, use the `bit` library (LuaJIT bundles `bit.band` / `bit.bxor` /
> `bit.lshift` / …). `scripts/core/server/xmysql_worker.lua`'s SHA-1 / SHA-256 helpers are a
> good template — they prefer `bit` / `bit32` if available and fall back to a
> pure-Lua implementation otherwise.

### 2.6 Embedding

To embed xnet2lua into your own C project:

1. Link `libxsock.a`.
2. Pick a Lua backend and define the matching macro:
   - `-DLUA_EMBEDDED`: include `3rd/minilua.h` directly (with `#define LUA_IMPL`
     in exactly one `.c` file).
   - `-DXLUA_USE_LUAJIT=1`: include `lua.h`, `lauxlib.h`, `lualib.h`, `luajit.h`
     and link the LuaJIT static library.
3. In your C entry point, follow this initialization sequence:

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
#include "xmacro.h"   // include LAST; the four rpmalloc_* calls below stub to no-ops when -DXMACRO_USE_RPMALLOC=0

// rpmalloc must be initialized before ANY allocation, including the calloc
// inside xthread_init(). This also registers the main thread with rpmalloc.
// Stubs out to a no-op when built with WITH_RPMALLOC=0.
rpmalloc_initialize(NULL);

lua_State* L = luaL_newstate();
luaL_openlibs(L);
#if defined(XLUA_USE_LUAJIT)
    luaJIT_setmode(L, 0, LUAJIT_MODE_ENGINE | LUAJIT_MODE_ON);
#endif

// Register Lua modules
luaL_requiref(L, "xthread",  luaopen_xthread,  1); lua_pop(L, 1);
luaL_requiref(L, "xnet",     luaopen_xnet,     1); lua_pop(L, 1);
luaL_requiref(L, "cmsgpack", luaopen_cmsgpack, 1); lua_pop(L, 1);
luaL_requiref(L, "xutils",   luaopen_xutils,   1); lua_pop(L, 1);

// Initialize the thread system (worker threads handle their own
// rpmalloc_thread_initialize / _finalize automatically inside worker_func).
xthread_init();

// ... event loop ...

// Shutdown
xthread_uninit();
lua_close(L);
rpmalloc_finalize();
```

### 2.7 Memory allocator (rpmalloc + xmacro.h)

By default, xnet2lua routes the project's own `malloc / calloc / realloc / free / strdup` calls to mjansson/rpmalloc (`3rd/rpmalloc/rpmalloc.c`). rpmalloc's per-thread caches plus a deferred cross-thread free queue map cleanly onto the project's actor model — most POST/RPC buffers are allocated by the sender thread and freed by the receiver thread, and rpmalloc handles that workload without a global lock.

The routing is done by a set of function-like macros in `xmacro.h`:

```c
#define malloc(n)     rpmalloc(n)
#define calloc(n,s)   rpcalloc((n),(s))
#define realloc(p,n)  rprealloc((p),(n))
#define free(p)       rpfree(p)
#define strdup(s)     xmacro_rpstrdup(s)
```

**Important boundary**: xnet2lua does **not** hijack the CRT's `malloc/free` symbols (rpmalloc's own `ENABLE_OVERRIDE` is forced off). libc calls, miniz, mbedTLS, and the Lua VM's own GC all stay on libc. The two allocators are strictly partitioned — a pointer that came from rpmalloc must be freed with rpfree, and a pointer that came from libc must be freed with libc `free`. Don't hand a libc-allocated pointer to xnet2lua to free, and don't free an rpmalloc-allocated pointer with the libc `free` directly.

**yyjson is the one exception.** Because JSON pack/unpack is hot in any HTTP/API workload, we redirect its allocator too — but through its first-class `yyjson_alc` hook rather than the macro-based shadow. `xlua/lua_xutils.c` defines a `g_xj_alc` whose `malloc/realloc/free` trampolines call the libc names (which `xmacro.h` routes to rpmalloc when `WITH_RPMALLOC=1`). Every `yyjson_read_opts` / `yyjson_mut_doc_new` / `yyjson_*_write_opts` call passes `&g_xj_alc`, so yyjson docs and output buffers all live in the same rpmalloc pool as the rest of the project — unified accounting, unified release, no heap mismatch. If you add a new yyjson call site, pass `&g_xj_alc` too. Passing `NULL` would silently make the doc libc-allocated and the eventual `free()` (routed by `xmacro.h` to `rpfree`) corrupts the heap (visible as `0xC0000374` on Windows process exit).

**Toggle** (default on, see §2.1 / §2.2):

| Build system | How to disable | Effect |
|---|---|---|
| Makefile | `make WITH_RPMALLOC=0` | macros expand to libc names; `rpmalloc.c` is not linked |
| build.bat | `build.bat norpmalloc` | same |

With `WITH_RPMALLOC=0`, `xmacro.h` also stubs out the four lifecycle entry points `rpmalloc_initialize / _finalize / _thread_initialize / _thread_finalize` as no-ops, so call sites compile unchanged. Useful for AddressSanitizer / Valgrind sessions, or for an A/B perf comparison against libc.

**Embedding rules** (the §2.6 snippet already shows them):
- The main thread must call `rpmalloc_initialize(NULL)` **before** `xthread_init()` and `rpmalloc_finalize()` before process exit.
- Worker threads need no manual care — the framework's `worker_func` calls `rpmalloc_thread_initialize / _finalize` at the thread's entry and exit.
- Cross-thread POST/RPC buffers: the sender allocates via the `xmacro.h`-routed `malloc`, the receiver frees via the same routed `free`. rpmalloc internally hands the deferred free back to the owner thread — **no extra synchronization needed**.

> ⚠️ **Known trap on MinGW.** Upstream rpmalloc's `rpmalloc.c` ends with `#include "malloc.c"`, which replaces the libc `malloc/calloc/free` symbols globally. **MinGW's emulated TLS allocates `_Thread_local` storage by calling `calloc()` internally** — so the first access to any `_Thread_local` variable triggers `calloc → rpcalloc → get_thread_heap → __emutls_get_address → calloc → ...` infinite recursion. The process exits with `0xC00000FD` (stack overflow) **before `main()` runs**, with **no stdout / stderr output at all**. This repo's `Makefile` and `build.bat` already pass `-DENABLE_OVERRIDE=0` to defeat that. **If you migrate the build to another system or write your own compile rules, you must keep that define.** MSVC is unaffected (its `__declspec(thread)` does not go through calloc), but `-DENABLE_OVERRIDE=0` should stay on regardless — otherwise rpmalloc fights every other allocator in the process for the CRT symbols.

> 💡 **Minor trap: 3rd-party headers with `.free` / `.malloc` fields**. The function-like macro `#define free(p) rpfree(p)` will wrongly expand `something.free(ctx, ptr)` field calls into `something.rpfree((ctx, ptr))`. The one place this hits in this repo is `3rd/yyjson.h`'s `yyjson_alc` struct (it has `.malloc`/`.free` fields and the inline json doc free path calls `alc.free(alc.ctx, doc)`). The rule: **`xmacro.h` must be included AFTER `yyjson.h`** in any `.c` that uses both. Same precaution if you pull in any other library with similar field naming.

---

## 3. Program Entry and Thread Lifecycle

### 3.1 Thread Script Protocol

Each Lua thread script (including the main thread) must return a table defining lifecycle callbacks:

```lua
local function __init()
    -- Called once when the thread starts (establish connections, create sub-threads, etc.)
    print("Thread initialized")
end

-- Optional: define this only when the script has periodic Lua work
-- such as timers, reconnect checks, or test timeouts.
-- local function __update()
-- end

local function __uninit()
    -- Called on thread exit (resource cleanup)
    print("Thread exited")
end

local function __thread_handle(reply_router, k1, k2, k3, ...)
    -- Called when receiving cross-thread messages (see Chapter 4)
end

return {
    __init          = __init,
    -- __update     = __update,
    __uninit        = __uninit,
    __thread_handle = __thread_handle,
}
```

### 3.2 __thread_handle Message Distribution Template

> 💡 **Recommended**: use the `scripts/core/share/xrouter.lua` module to skip this
> boilerplate entirely — see [3.3 xrouter module](#33-xrouter-module-recommended).
> The hand-written template below is here only for readers who want to see the
> underlying protocol or need fully custom dispatch.

A by-hand message distribution pattern (compatible with both POST and RPC modes):

```lua
_stubs = {}         -- Registered message handlers
_thread_replys = {} -- RPC reply router table (used internally by the framework)

-- Convenience to register handlers
function xthread.register(pt, h)
    _stubs[pt] = h
end

local function __thread_handle(reply_router, k1, k2, k3, ...)
    if reply_router then
        -- RPC reply routing (internal handling; usually not modified)
        local reply = _thread_replys[reply_router]
        if not reply then return end
        local h = _stubs[k3]  -- k3 is the pt
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
        -- POST messages: k1 is the pt
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

### 3.3 xrouter module (recommended)

`scripts/core/share/xrouter.lua` packages the §3.2 boilerplate (`_stubs / _thread_replys /
__thread_handle` plus the coroutine wrapping and RPC reply routing) into a
small module.

**Two core design principles:**

1. **Unified register**: the registration site does **not** care whether
   the caller will reach this `pt` via POST or RPC — both shapes use the
   same `register(pt, h)`. Dispatch decides what to do based on whether
   `reply_router` is set:
   - Caller used `xthread.post(...)` → handler runs, return values discarded.
   - Caller used `xthread.rpc(...)`  → handler runs, return values become
     the reply `(ok=true, ret...)`; raised errors become `(ok=false, errmsg)`.

   Every handler runs in a coroutine, so **any** handler may yield (e.g.
   internally call `xthread.rpc` out into another thread).

2. **Per-Lua-state singleton**: every `dofile('scripts/core/share/xrouter.lua')` in the
   same thread returns the **same table** (same caching pattern as
   xhttp_router's `__xnet_xhttp_router`), so registrations spread across
   many files all accumulate into one router.

The thread script keeps the §3.1 standard return-table shape; **only the
`__thread_handle` field changes — it is now `router.handle`**.

```lua
-- worker.lua
local router = dofile('scripts/core/share/xrouter.lua')
router.set_log_prefix('MYAPP')                    -- optional

-- One register API. The site doesn't care whether the caller uses POST or RPC.
router.register('print_msg', function(text)
    print('[MYAPP]', text)
end)

router.register('add', function(a, b)
    return a + b                                  -- becomes the reply on RPC
end)

router.register('do_lookup', function(key)
    local ok, val = xthread.rpc(xthread.REDIS, 'xredis_call', 'GET', key)
    return val                                    -- handler may yield freely
end)

-- Registrations may live in other files — they get the SAME router:
dofile('demo/handlers/login.lua')        -- inside: router.register(...)
dofile('demo/handlers/inventory.lua')    -- inside: router.register(...)

local function __init()   assert(xnet.init())     end
local function __uninit() xnet.uninit()            end

return {
    __init   = __init,
    -- __update = __update, -- only for periodic Lua work
    __uninit = __uninit,
    __thread_handle = router.handle,    -- ← this is the only line that changes
}
```

**API summary:**

| Method | Purpose |
|---|---|
| `dofile('scripts/core/share/xrouter.lua')` | Returns the router singleton (same object on every call within a Lua state) |
| `router.register(pt, h)` | Register handler; usable from both POST and RPC; runs in a coroutine, may yield |
| `router.reset(opts)` | Wipe all handlers and callbacks (for tests / explicit teardown) |
| `router.set_log_prefix(s)` | Change the log prefix |
| `router.set_unknown_post(fn)` | Fallback `fn(pt, ...)` when no handler matches a POST |
| `router.set_unknown_rpc(fn)` | Fallback `fn(reply_router, co_id, sk, pt, ...)` when no handler matches an RPC |
| `router.set_handler_error(fn)` | Top-level error in a POST-side coroutine: `fn(pt, err)` (RPC errors auto-reply, no callback) |
| `router.current_request()` | Returns req when the calling coroutine is serving an RPC, nil otherwise |
| `router.handle` | Dispatcher closure — assign directly to `__thread_handle` |

**Hot-reload friendliness:**

- `router` and `router.handle` are stable singletons → the C runtime's
  cached `__thread_handle` ref keeps pointing at the same dispatcher across
  reloads.
- Re-running the worker script just **overwrites handlers in place** via
  `router.register` on the existing stub table; new handlers fire on the
  next message.
- In-flight `rpc_context` survives a reload — already-yielded coroutines
  still see their reply path intact.
- Call `router.reset()` only when you explicitly want to wipe state
  (typically not part of reload).

**Mapping from §3.2 hand-written template:**

- The legacy `xthread.register(pt, h)` ≈ `router.register`.
- `_stubs` / `_thread_replys` are kept inside the module — no globals needed.
- `__thread_handle` is plugged in directly as `router.handle`; the return-table shape stays the same as §3.1.

See `demo/xlua_main.lua` and `demo/xlua_thread.lua` for an actual migration:
running `./demo/xnet demo/xlua_main.lua` exercises the full POST + RPC + nested
RPC-back-to-MAIN test suite using `xrouter` end-to-end.

### 3.4 Exit

```lua
-- Normal exit (exit code 0)
xthread.stop(0)

-- Abnormal exit (exit code 1)
xthread.stop(1)
```

---

## 4. xthread Module — Multithreading and Message Passing

### 4.1 Initialization

```
-- Initialize xthread module (must be done before any other xthread calls)
xthread.init()
```

### 4.2 Create Sub-Threads

```
-- Dynamically create a new thread (runs in a separate Lua State)
-- id: thread ID (integer; see Chapter 12 for constants)
-- name: thread name (for debugging)
-- script_path: Lua script path (relative to the working directory)
-- Returns: true on success; false + error on failure
local ok, err = xthread.create_thread(id, name, script_path)
if not ok then error("Failed to create thread: " .. tostring(err)) end
```

### 4.3 Shut Down Sub-Threads

```
-- Request to close a specified thread (will trigger its __uninit callback)
local ok, err = xthread.shutdown_thread(thread_id)
```

### 4.4 POST — Asynchronous Message (fire-and-forget)

```
-- Post a message to a target thread asynchronously
-- target_id: thread ID
-- pt:        message type string
-- ...:       arguments (will be serialized via MessagePack)
-- Returns: true, or false + error information
local ok, err = xthread.post(target_id, pt, arg1, arg2, ...)
```

**Example:** Pass an accepted fd to a worker thread:
```
xthread.post(WORKER_ID, "accepted_fd", fd, client_ip, client_port)
```

**Worker-side handler registration:**
```
xthread.register("accepted_fd", function(fd, ip, port)
    print("New connection:", fd, ip, port)
    -- Attach this fd in this thread
    local conn, err = xnet.attach(fd, my_handler, ip, port)
end)
```

### 4.5 RPC — Synchronous Remote Call

```
-- Caller (must be in a coroutine)
local ok, result1, result2 = xthread.rpc(target_id, pt, arg1, arg2, ...)

if ok then
    print("RPC succeeded, results:", result1, result2)
else
    print("RPC failed:", result1)  -- result1 is the error string
end
```

**Callee (register RPC handler; may return values):**
```
xthread.register("add", function(a, b)
    return a + b
end)

xthread.register("get_info", function(key)
    return "value", 42, true
end)
```

**Full RPC Example:**
```
-- Main thread: invoke RPC during initialization
local function __init()
    -- Note: RPC must be invoked within a coroutine
    _test_co = coroutine.create(function()
        local ok, sum = xthread.rpc(COMPUTE_ID, "add", 100, 200)
        if ok then
            print("100 + 200 =", sum)  -- Output: 100 + 200 = 300
        end
        xthread.stop(0)
    end)
    coroutine.resume(_test_co)
end
```

### 4.6 Get Current Thread Information

```
-- Get current thread ID
local id = xthread.current_id()

-- Get main thread ID constant
local main_id = xthread.MAIN   -- value 1
```

### 4.7 Native Lua Debugger Control

These APIs are available when xnet is built with `WITH_XDEBUG=1`. In the default
production build they report that debugging is unavailable or disabled.

```lua
-- Start the native Lua debug service at runtime.
-- port: TCP debug port; 19090 is the recommended default.
-- wait: true stops Lua threads on their next line; for remote on-demand
--       startup, false is usually easier to use.
-- Returns: true + message, or false + error.
local ok, msg = xthread.xdebug_start(19090, false)

-- Query debug service status.
-- Returns: running(bool), port(number)
local running, port = xthread.xdebug_status()
```

The usual operational path is to run this from the xadmin script executor:

```lua
local ok, msg = xthread.xdebug_start(19090, false)
return ok, msg
```

The Lua thread that executes the script is enabled immediately. Other
registered Lua threads enable their debug hooks on their next update tick, which
keeps all hook installation inside the owning OS thread and avoids touching
another thread's `lua_State` directly.

---

## 5. xnet Module — Asynchronous Networking

### 5.1 Initialization

```lua
-- Initialize the networking module (in every thread that uses networking)
assert(xnet.init())

-- After initialization, the C layer marks this thread as network-active
-- and drives xpoll_poll() automatically. A Lua __update callback is only
-- needed for periodic Lua-side work.

-- Shutdown the networking module (in __uninit)
xnet.uninit()

-- Get the I/O backend name in use ("epoll" / "kqueue" / "wsapoll" / "poll")
local backend = xnet.name()
```

### 5.2 Create a TCP Listener

```lua
-- Listen on a given address and port, returns a listener object
-- host: bind address (nil or omitted = all interfaces)
-- port: port number
-- handlers: event callbacks
local listener, err = xnet.listen_fd(host, port, {
    on_accept = function(listener, fd, ip, port)
        -- New connection; fd is the raw socket fd
        -- Return true to accept; false to reject
        print("New connection:", ip, port)
        xthread.post(WORKER_ID, "accepted_fd", fd, ip, port)
        return true
    end,

    on_close = function(listener, reason)
        -- Listener closed
        print("Listener closed:", reason)
    end,
})
```

**Listener object methods:**
```
local fd = listener:fd()
listener:close("reason")
```

### 5.3 Connect to a Remote Server

```lua
local conn, err = xnet.connect(host, port, {
    on_connect = function(conn, ip, port)
        print("Connected to:", ip, port)
    end,

    on_packet = function(conn, data)
        -- data is a Lua string
        print("Received data:", #data, "bytes")
    end,

    on_close = function(conn, reason)
        print("Connection closed:", reason)
    end,
})

if not conn then
    error("Connection failed: " .. tostring(err))
end
```

### 5.4 Attach an Existing FD (Attach)

When the main thread accepts a connection and hands the fd to a worker thread, the worker needs to attach it:

```lua
local conn, err = xnet.attach(fd, handlers, ip, port)
-- Alias: xnet.connect_fd(fd, handlers, ip, port)
```

**Complete attach example:**
```
-- In worker thread
xthread.register("new_conn", function(fd, ip, port)
    local conn, err = xnet.attach(fd, {
        on_connect = function(conn, ip, port)
            -- Trigger on_connect immediately after attach
            conn:set_framing({ type = "len32", max_packet = 4 * 1024 * 1024 })
        end,
        on_packet = function(conn, data)
            -- Handle received data packet
            handle_packet(conn, data)
        end,
        on_close = function(conn, reason)
            print("Client disconnected:", reason)
        end,
    }, ip, port)

    if not conn then
        io.stderr:write("attach failed: " .. tostring(err) .. "\n")
    end
end)
```

### 5.5 conn Methods

```lua
local ok = conn:send(data)          -- send data (frames according to framing)
local ok = conn:send_raw(data)      -- raw send (no framing)
local ok = conn:send_packet(data)   -- alias for send
local ok = conn:send_file_response(header, path, offset, length)
conn:set_framing(opts)
local ip, port = conn:peer()
local fd = conn:fd()
local closed = conn:is_closed()
conn:close("reason")
conn:set_handler(handlers)
```

### 5.6 Directory Scanning (Static File Service)

```lua
local files, err = xutils.scan_dir("static/")
if files then
    for _, f in ipairs(files) do
        print(f.rel, f.path)
    end
end
```

---

## 6. Frame Protocols (Packetization Strategy)

TCP is a byte stream; you must define how to packetize at the application layer. xnet2lua provides three built-in framing modes, switchable after a connection is stablished.

### 6.1 Raw Mode (Unframed)

No framing is applied; the on_packet callback receives arbitrary-sized raw byte chunks.

```lua
conn:set_framing({ type = "raw" })
-- If not called, the default is raw
```

The on_packet callback’s return value indicates how many bytes were consumed (0 = keep all data for next time):

```lua
on_packet = function(conn, data)
    -- In raw mode, you must determine if a complete message is present
    if #data < 4 then return 0 end
    local consumed = process(data)
    return consumed
end
```

### 6.2 len32 Mode (Recommended for Binary Protocols)

Each packet is prefixed with a 4-byte big-endian length; the framework handles fragmentation automatically. on_packet receives a complete packet.

```lua
conn:set_framing({
    type = "len32",
    max_packet = 4 * 1024 * 1024,  -- max packet size; default 16MB
})
```

Sending automatically adds the 4-byte length header:

```lua
-- Sender
conn:send(some_binary_data)

-- Receiver on_packet gets the payload (without length header)
on_packet = function(conn, data)
    local pt, arg1, arg2 = cmsgpack.unpack(data)
    -- ...
end
```

### 6.3 CRLF Mode (Text Line Protocol)

Use CRLF as line terminators for fragmentation; suitable for Redis-like and SMTP-style text protocols.

```lua
conn:set_framing({
    type = "crlf",
    max_packet = 65536,
})
```

### 6.4 Custom Delimiter (CRLF Extension)

```lua
conn:set_framing({
    type = "crlf",
    delimiter = "\n",       -- split on LF only
    max_packet = 65536,
})
```

### 6.5 len32 + MessagePack Combination (Best Practice)

This is the most common communication pattern in xnet2lua, combining high performance with structured data transfer:

```lua
local cmsgpack = require("cmsgpack")

-- Sender: serialize message type + args; send adds length header automatically
local function send_msg(conn, pt, ...)
    local body = cmsgpack.pack(pt, ...)
    conn:send(body)
end

-- Example:
send_msg(conn, "login", user_id, token)
send_msg(conn, "chat", room_id, message)

-- Receiver: on_packet -> unpack -> dispatch
on_packet = function(conn, data)
    local pt, arg1, arg2, arg3 = cmsgpack.unpack(data)
    local handler = handlers[pt]
    if handler then handler(conn, arg1, arg2, arg3) end
end
```

---

## 7. TLS / HTTPS Support

TLS/HTTPS support requires enabling HTTPS at build time (`make WITH_HTTPS=1`) and providing certificate files.

### 7.1 Generate Test Certificates

```bash
# Generate a self-signed certificate (for testing)
openssl req -x509 -newkey rsa:2048 -keyout server.key \
    -out server.crt -days 365 -nodes \
    -subj "/CN=localhost"
```

### 7.2 TLS Server (attach_tls)

In the worker thread, when a new fd arrives and TLS handshake is needed:

```lua
local conn, err = xnet.attach_tls(fd, {
    cert_file = "demo/certs/server.crt",
    key_file  = "demo/certs/server.key",
    -- key_password = "optional_password",  -- if the private key is password-protected

    on_connect = function(conn, ip, port)
        print("TLS handshake succeeded:", ip, port)
        conn:set_framing({ type = "len32" })
    end,
    on_packet = function(conn, data)
        handle_packet(conn, data)
    end,
    on_close = function(conn, reason)
        print("TLS connection closed:", reason)
    end,
}, client_ip, client_port)
```

### 7.3 TLS Connection Methods

TLS connection objects expose the same interface as regular connections:

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

## 8. HTTP Server

xnet2lua provides a complete HTTP server implementation (Lua-based, built on xnet).

### 8.1 Quick Start for HTTP Service

```lua
-- In the main thread’s __init
local xhttp = dofile("scripts/core/server/xhttp.lua")

local ok, err = xhttp.start({
    host         = "0.0.0.0",
    port         = 8080,
    worker_count = 4,             -- number of worker threads
    app_script   = "my_app.lua",  -- application routing script path
})

if not ok then error(err) end
```

HTTPS configuration:

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

`xhttp.start` full configuration:

| Config Item | Type | Default | Description |
|-------------|------|---------|-------------|
| host | string | "127.0.0.1" | Bind address |
| port | number | 18080 | Listening port |
| https | bool | false | Whether to enable TLS |
| cert_file | string | "" | TLS certificate path |
| key_file | string | "" | TLS private key path |
| key_password | string | "" | Private key password (optional) |
| worker_count | number | 2 | Number of worker threads |
| worker_base | number | xthread.WORKER_GRP3 | Starting worker thread ID |
| worker_script | string | "scripts/core/server/xhttp_worker.lua" | Worker script path |
| app_script | string | (required) | Application routing script path (for example "demo/xhttp_app.lua") |
| max_request_size | number | 16MB | Maximum request body size (bytes) |

### 8.2 Writing the Application Router (app_script)

Every worker thread will independently load the app_script, so routes are registered within the worker Lua State.

```lua
-- my_app.lua
local router = dofile("scripts/core/share/xhttp_router.lua")

-- Register route: GET /hello
router.get("/hello", function(req)
    local name = req.query.name or "world"
    return {
        status  = 200,
        body    = "Hello, " .. name .. "!\n",
        headers = { ["Content-Type"] = "text/plain; charset=utf-8" },
    }
end)

-- Register route: POST /echo
router.post("/echo", function(req)
    return { status = 200, body = req.body }
end)

-- Register route: POST /api/data（JSON 接口）
router.post("/api/data", function(req)
    -- req.body is the raw request body string
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

-- Custom 404 handler
router.config({
    not_found = function(req)
        return { status = 404, body = "Not Found: " .. req.path .. "\n" }
    end,
})

-- Static directory mapping
router.static_dir("static/", {
    prefix = "/static",
    index  = "index.html",
    index_route = "/",    -- default route
})

-- Must return a handle function for the worker to call
return {
    handle = function(req)
        return router.handle(req)
    end,
}
```

### 8.3 request Object Fields

The req object for on_packet / handler contains:

| Field | Type | Description |
|------|------|-------------|
| req.method | string | HTTP method (e.g., "GET", "POST") |
| req.path | string | Request path (excluding query string) |
| req.query | table | URL query parameters (e.g., ?name=foo yields req.query.name) |
| req.headers | table | Request headers (keys lowercased) |
| req.body | string | Raw request body data |
| req.version | string | HTTP version ("1.1" / "1.0") |

### 8.4 response Object Fields

The response table returned by the router:

| Field | Type | Description |
|------|------|-------------|
| status | number | HTTP status code |
| body | string | Response body (or) |
| file | string | Static file path (framework will serve file; mutually exclusive with body) |
| headers | table | Response headers |

```lua
-- Return JSON
return {
    status  = 200,
    body    = '{"ok":true}',
    headers = { ["Content-Type"] = "application/json" },
}

-- Return static file (zero-copy)
return {
    status  = 200,
    file    = "dist/index.html",
    headers = { ["Content-Type"] = "text/html; charset=utf-8" },
}

-- Return an error
return { status = 500, body = "Internal Server Error\n" }
```

### 8.5 Router API

```lua
local router = dofile("scripts/core/share/xhttp_router.lua")

-- Register GET route
router.get(path, handler)

-- Register POST route
router.post(path, handler)

-- Register HEAD route
router.head(path, handler)

-- Generic register (supports any method)
router.reg(method, path, handler)  -- method is case-insensitive
router.route(method, path, handler) -- alias

-- Path parameters / wildcard
--   :name      matches a single path segment (no '/'), bound to req.params.name
--   *name      only valid as the last segment; matches the rest of the path,
--                bound to req.params.name (anonymous '*' binds to req.params.path)
-- Static routes still take the fast dictionary path; dynamic routes are scanned
-- in registration order on miss.
router.get('/api/user/:id', function(req)
    return { status = 200, body = req.params.id }
end)
router.get('/static/*path', function(req)
    return { status = 200, body = req.params.path }
end)

-- Register a single static file
router.reg_static_file(rel_path, disk_path, opts)

-- Register an entire directory as static routes
router.reg_path(root_dir, {
    prefix      = "/static",
    index       = "index.html",
    index_route = "/",
})
router.static_dir(root_dir, opts) -- alias

-- Configure 404 and other options
router.config({
    not_found = function(req) return { status = 404 } end,
})

-- Dispatch request
local response = router.handle(req)

-- Get Content-Type for a file
local ct = router.content_type_for("index.html")  -- "text/html; charset=utf-8"
```

---

## 9. cmsgpack Module — MessagePack Serialization

MessagePack is a binary JSON alternative; smaller and faster, ideal for inter-thread or inter-process data transfer.

```lua
local cmsgpack = require("cmsgpack")
```

### 9.1 Serialization

```lua
-- Serialize multiple Lua values into one MessagePack binary string
-- Supports nil, boolean, integer, float, string, table (array/dictionary)
local data = cmsgpack.pack(value1, value2, ...)
```

-- Example
```lua
local blob = cmsgpack.pack("login", 12345, true, { level = 99 })
```

### 9.2 Deserialization

```lua
-- Restore all values from a MessagePack binary string
-- Returns all values serialized
local val1, val2, val3, ... = cmsgpack.unpack(data)

-- Example
local pt, user_id, ok, extra = cmsgpack.unpack(blob)
-- pt = "login", user_id = 12345, ok = true, extra = { level = 99 }
```

### 9.3 Typical Usage — Message Protocol

```lua
-- Sender (in any thread)
local function send_msg(conn, pt, ...)
    conn:send(cmsgpack.pack(pt, ...))
end
```

```lua
-- Receiver (on_packet callback)
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

## 10. xutils Module — Utilities

```lua
local xutils = require("xutils")
```

### 10.1 JSON Handling

```lua
-- Serialize Lua value to JSON string
-- Depends on yyjson; very high performance
local json_str = xutils.json_pack(value)

-- Parse JSON string into a Lua value
local value = xutils.json_unpack(json_str)

-- Example
local str = xutils.json_pack({ name = "alice", score = 100, tags = {"vip", "active"} })
-- str = '{"name":"alice","score":100,"tags":["vip","active"]}'

local data = xutils.json_unpack(str)
print(data.name)   -- alice
print(data.score)  -- 100
```

---

## 11. Configuration Files

xnet2lua supports runtime configuration via `.cfg` files; format is `KEY=VALUE`, with `#` as comment.

### 11.1 Configuration File Format

```ini
# xnet.cfg example
# SERVER_NAME=myserver # Move it to startup parameters to support configuration sharing.

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

### 11.2 Load Configuration in Lua

```lua
-- Load configuration file (usually in the main thread’s __init at the very start)
local ok, err = xutils.load_config("xnet.cfg")
if not ok then
    io.stderr:write("Configuration load failed: " .. tostring(err) .. "\n")
end

-- Read configuration items (second parameter is the default)
local host    = xutils.get_config("HTTP_HOST", "127.0.0.1")
local port    = tonumber(xutils.get_config("HTTP_PORT", "8080")) or 8080
local workers = tonumber(xutils.get_config("HTTP_WORKERS", "2")) or 2
local debug   = xutils.get_config("DEBUG", "0") ~= "0"
```

### 11.3 Command-line Overrides

```bash
./xnet my_main.lua SERVER_NAME=prod HTTP_PORT=9090
```

---

## 12. Thread ID Constants

xnet2lua reserves space for thread IDs in the range 0–99, where 0–9 are special-function threads and 10–99 are in the worker groups.

| Constant | Value | Description |
|----------|-------|-------------|
| `xthread.MAIN` | 1 | Main thread |
| `xthread.REDIS` | 2 | Redis I/O thread |
| `xthread.MYSQL` | 3 | MySQL I/O thread |
| `xthread.LOG` | 4 | Logging thread |
| `xthread.IO` | 5 | General I/O thread |
| `xthread.COMPUTE` | 6 | Compute thread |
| `xthread.NATS` | 7 | NATS message queue thread |
| `xthread.HTTP` | 8 | HTTP/HTTPS service thread |
| `xthread.WORKER_GRP1` | 20 | Worker group 1 start (20–39)|
| `xthread.WORKER_GRP2` | 40 | Worker group 2 start (40–59)|
| `xthread.WORKER_GRP3` | 60 | Worker group 3 start (60–79)|
| `xthread.WORKER_GRP4` | 80 | Worker group 4 start (80–99)|
| `xthread.WORKER_GRP5` | 100| Worker group 5 start (100–119)|

**Recommendation:** Use business thread IDs in the 100+ range to avoid conflicts with reserved IDs (note `XTHR_MAX = 100`; after changing this, rebuild all code using thread).

---

## 13. Complete Example: TCP Server

### Main Thread Script (tcp_main.lua)

```lua
-- tcp_main.lua - Main thread: listening and distributing connections to workers

local WORKER_ID = 10
local HOST      = "0.0.0.0"
local PORT      = 9000

local listener
local worker_started = false

-- Standard message distribution template
_stubs = {}
_thread_replys = {}

function xthread.register(pt, h) _stubs[pt] = h end

local function __thread_handle(reply_router, k1, k2, k3, ...)
    if reply_router then return end
    local h = _stubs[k1]
    if h then h(k2, k3, ...) end
end

-- Worker notifies the main thread of results
xthread.register("report", function(msg)
    print("[MAIN] worker report:", msg)
end)

local function __init()
    assert(xnet.init())

    -- Start worker thread
    local ok, err = xthread.create_thread(WORKER_ID, "tcp-worker", "tcp_worker.lua")
    if not ok then error(err) end
    worker_started = true

    -- Start listening
    listener = assert(xnet.listen_fd(HOST, PORT, {
        on_accept = function(_, fd, ip, port)
            print(string.format("[MAIN] New connection: %s:%d fd=%d", ip, port, fd))
            local ok, err = xthread.post(WORKER_ID, "accepted_fd", fd, ip, port)
            if not ok then
                io.stderr:write("[MAIN] post failed: " .. tostring(err) .. "\n")
                return false
            end
            return true
        end,
        on_close = function(_, reason)
            print('[MAIN] Listener closed:', reason)
        end,
    }))
    print(string.format("[MAIN] Listening on %s:%d", HOST, PORT))

    local ok, err = xthread.post(WORKER_ID, "start_client", HOST, PORT)
    if not ok then error(err) end
end

-- No Lua-side timer work is needed here, so __update is omitted.

local function __uninit()
    if listener then
        listener:close('uninit')
        listener = nil
    end
    shutdown_worker()
    xnet.uninit()
    print('[XNET-MAIN] uninit')
end

return {
    __init = __init,
    -- __update = __update,
    __uninit = __uninit,
    __thread_handle = __thread_handle,
}
```

### Worker Thread Script (tcp_worker.lua)

```lua
-- tcp_worker.lua - Worker thread: handle TCP connections and business logic

local cmsgpack = require("cmsgpack")

local MAIN_ID = xthread.MAIN
local conns = {}  -- manage active connections

_stubs = {}
_thread_replys = {}

function xthread.register(pt, h) _stubs[pt] = h end

local function __thread_handle(reply_router, k1, k2, k3, ...)
    if reply_router then return end
    local h = _stubs[k1]
    if h then h(k2, k3, ...) end
end

-- Receive new connections from the main thread
xthread.register("new_conn", function(fd, ip, port)
    local conn, err = xnet.attach(fd, {
        on_connect = function(conn, ip, port)
            print(string.format("[WORKER] Client connected: %s:%d", ip, port))
            -- Set framing to len32 and maximum packet size
            conn:set_framing({ type = "len32", max_packet = 1024 * 1024 })
            conns[fd] = conn
        end,
        on_packet = function(conn, data)
            -- Unpack: (pt, payload)
            local pt, payload = cmsgpack.unpack(data)
            if pt == "echo" then
                -- Echo back
                conn:send(cmsgpack.pack("echo_reply", payload))
            elseif pt == "ping" then
                conn:send(cmsgpack.pack("pong", os.time()))
            else
                io.stderr:write("[WORKER] Unknown pt: " .. tostring(pt) .. "\n")
            end
        end,
        on_close = function(conn, reason)
            local fd = conn:fd()
            conns[fd] = nil
            print("[WORKER] Client disconnected:", reason)
        end,
    }, ip, port)

    if not conn then
        io.stderr:write("[WORKER] attach failed: " .. tostring(err) .. "\n")
    end
end)

local function __init()
    assert(xnet.init())
    print("[WORKER] Initialization complete")
    xthread.post(MAIN_ID, "report", "worker ready")
end

-- No Lua-side timer work is needed here, so __update is omitted.

local function __uninit()
    -- Close all active connections
    for _, conn in pairs(conns) do
        conn:close("worker_shutdown")
    end
    xnet.uninit()
    print("[WORKER] Shutdown")
end

return {
    __init          = __init,
    -- __update     = __update,
    __uninit        = __uninit,
    __thread_handle = __thread_handle,
}
```

Run:

```bash
./xnet tcp_main.lua
```

---

## 14. Complete Example: HTTP API Service

### Main Thread (http_server_main.lua)

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
        app_script   = "api_app.lua",
    })

    if not ok then error(err) end
    print("[SERVER] HTTP service started; press Ctrl+C to exit")
end

-- No Lua-side timer work is needed here, so __update is omitted.

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

### Application Router (api_app.lua)

```lua
-- api_app.lua - Each worker loads this file independently

local router = dofile("scripts/core/share/xhttp_router.lua")

-- Cross-origin headers (optional)
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
            table.unpack(CORS_HEADERS),  -- Expand CORS headers
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

-- GET /api/user?id=123
router.get("/api/user", function(req)
    local id = tonumber(req.query.id)
    if not id then
        return json_response(400, { error = "missing id" })
    end
    -- Mock database lookup
    return json_response(200, {
        id    = id,
        name  = "user_" .. id,
        level = math.random(1, 100),
    })
end)

-- OPTIONS (CORS preflight)
router.reg("OPTIONS", "/api/echo", function()
    return { status = 204, headers = CORS_HEADERS }
end)

-- Static files
router.static_dir("dist/", { prefix = "/", index = "index.html" })

return {
    handle = function(req) return router.handle(req) end,
}
```

### 便利说明

- 通过上述示例，你可以看到在 HTTP API 服务中，与 JSON 相关的打包/解包都可以使用 xutils.json_pack / xutils.json_unpack 来实现。
- 你也可以在需要的地方引入 xutils.json_pack/json_unpack，以统一的方式处理 JSON 数据。

---

## 15. Complete Example: Cross-thread RPC

跨线程 RPC 的完整示例请参考原文相应章节——内容保持一致，无需额外翻译变动。

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
    if not h then reply(k1, k2, k3, false, "pt not found"); return end
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
    print("=== Start RPC tests ===")
 
    -- Test 1: Simple RPC call
    local ok, result = xthread.rpc(COMPUTE_ID, "add", 100, 200)
    assert(ok and result == 300, "add test failed: " .. tostring(result))
    print("[TEST1 PASS] 100 + 200 =", result)
 
    -- Test 2: RPC with multiple returns
    local ok, a, b = xthread.rpc(COMPUTE_ID, "divmod", 17, 5)
    assert(ok and a == 3 and b == 2, "divmod test failed")
    print("[TEST2 PASS] 17 ÷ 5 = quotient", a, "remainder", b)
 
    -- Test 3: RPC calling back to main thread
    local ok, reversed = xthread.rpc(COMPUTE_ID, "process_and_callback", "hello")
    assert(ok and reversed == "olleh", "callback test failed")
    print("[TEST3 PASS] process_and_callback returned:", reversed)
 
    print("=== All tests passed ===")
    xthread.shutdown_thread(COMPUTE_ID)
    xthread.stop(0)
end
 
local function __init()
    local ok, err = xthread.create_thread(COMPUTE_ID, "compute", "rpc_compute.lua")
    if not ok then error(err) end
 
    -- Run tests inside a coroutine (RPC requires a coroutine)
    local co = coroutine.create(run_tests)
    local ok, err = coroutine.resume(co)
    if not ok then
        io.stderr:write("Tests failed: " .. tostring(err) .. "\n")
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
 
-- Provide add service
xthread.register("add", function(a, b)
    return a + b
end)
 
-- Provide divmod service (multiple returns)
xthread.register("divmod", function(a, b)
    return math.floor(a / b), a % b
end)
 
-- Provide process_and_callback service (RPC back to main thread)
xthread.register("process_and_callback", function(s)
    -- RPC back to main thread's reverse_string
    local ok, reversed = xthread.rpc(MAIN_ID, "reverse_string", s)
    if not ok then error("callback RPC failed: " .. tostring(reversed)) end
    return reversed
end)
 
local function __init() print("[COMPUTE] initialized") end
local function __uninit() print("[COMPUTE] exit") end

return {
    __init = __init,
    -- __update = __update,
    __uninit = __uninit, __thread_handle = __thread_handle,
}
```

---

## 16. Best Practices and Considerations

### 16.1 Threading

- **Main thread only distributes**: The main thread is responsible for listening and distributing connections to workers; business logic should live in workers.
- **Every thread calls `xnet.init()`**: Every thread that uses networking must initialize xnet; the C layer then drives network polling for that thread
- **Omit empty `__update` callbacks**: Define `__update` only for periodic Lua-side work such as timers, reconnect checks, or test timeouts
- **Do not pass connection objects across threads**: `conn` objects belong to the Lua State that created them

### 16.2 Messaging

- **POST is suited for notification messages**: low overhead
- **RPC must be invoked within a coroutine**: `xthread.rpc` yields the current coroutine
- **RPC supports nested calls**: a compute thread can callback to the main thread

### 16.3 Networking

- After a connection is established, set the framing immediately in `on_connect`
- **Len32 + cmsgpack is the recommended combination**: binary, efficient, resolves fragmentation
- Check the return values of `conn:send()`; a false indicates failure (often the other side closed)
- Do not attempt to send in `on_close`

### 16.4 Errors

```lua
-- Error handling pattern
local ok, err = xthread.post(WORKER_ID, "do_work", data)
if not ok then
    io.stderr:write("post failed: " .. tostring(err) .. "\n")
    return
end

-- RPC error handling
local ok, result = xthread.rpc(TARGET_ID, "compute", arg)
if not ok then
    io.stderr:write("RPC failed: " .. tostring(result) .. "\n")
end
```

### 16.5 Performance Tuning

| Scenario | Recommendation |
|----------|--------------|
| High concurrency connections | Increase the number of worker threads (usually CPU cores × 1–2) |
| Large data packets | Increase `max_packet`; consider fragmentation and batching |
| Low latency | Keep Lua-side `__update` work small; tune the C-side polling cadence when needed |
| High throughput | Use `conn:send_raw()` + manual fragmentation to reduce copying |
| Static files | Use `conn:send_file_response()`, internal use of sendfile for efficiency |

### 16.6 Common Questions

- **Q: RPC call has no response?**
  A: Check that the called thread registered the `_thread_replys` table and handles the reply_router branch in `__thread_handle`.

- **Q: `xthread.rpc` reports "must be called from a coroutine"?**
  A: RPC must be called within a coroutine. Wrap with `coroutine.create`/`coroutine.resume`.

- **Q: Network connections occasionally drop?**
  A: Ensure `on_packet` returns the correct consumed byte count in raw mode, and confirm `conn:send()` return values aren’t ignored.

- **Q: Build failures on Windows?**
  A: Ensure MSVC or MinGW is installed; Makefile detects platform and links `ws2_32.lib`.

- **Q: How to support more than 99 threads?**
  A: Change the `XTHR_MAX` macro in `xthread.h` and recompile. All code using xthread should be rebuilt.

---

## 17. xadmin Console

`scripts/xadmin/` is a small but complete admin console: HTTP routes + cross-process node discovery + remote script execution + remote hot reload. It also serves as the end-to-end reference for §18 (xnats cross-process RPC) and §19 (hot reload protocol).

### 17.1 Architecture

```
┌──────────── xadmin1 ────────────┐         ┌──────────── xadmin2 ────────────┐
│  MAIN ──── listener (18091)     │   NATS   │  MAIN ──── listener (18092)     │
│   │                              │  ←───→   │   │                              │
│   ├── xnats-worker (NATS I/O)   │ wire 4222│   ├── xnats-worker              │
│   └── xhttp-worker (HTTP I/O)   │          │   └── xhttp-worker              │
└─────────────────────────────────┘          └─────────────────────────────────┘
```

Key design points:

- **HTTP routes run inside a per-request coroutine.** A route handler may call yielding APIs (`xnats.rpc`, `xthread.rpc`) directly and just `return` the response. The worker keeps a per-connection queue so HTTP/1.1 pipelining order is preserved.
- **Local RPC short-circuits at the caller side.** `xnats.rpc(self, ...)` never touches the NATS wire — it hits the local business worker directly via `xthread.rpc`. See §18.4.
- **State survives reload.** Connections, peer cache, in-flight RPC context all live in `_G`, so top-level `dofile` doesn't disturb them. See §19.2.

### 17.2 Start NATS

```bash
nats-server -p 4222
```

### 17.3 Build

```bash
make                       # MSYS2 / MinGW / Linux / macOS
# or
build.bat                  # Windows / MSVC
```

### 17.4 Run nodes

Each node needs a **unique** `SERVER_NAME` and port:

```bash
bin/xnet.exe scripts/xadmin/xadmin_main.lua SERVER_NAME=xadmin1 XADMIN_PORT=18091
bin/xnet.exe scripts/xadmin/xadmin_main.lua SERVER_NAME=xadmin2 XADMIN_PORT=18092
```

Nodes discover each other through the NATS broadcast subject (5s heartbeat, 15s TTL) and surface as peers in `/api/peers`.

### 17.5 HTTP API

| Path | Method | Auth | Purpose |
|---|---|---|---|
| `/api/peers` | GET | no | This node + peers discovered via heartbeat |
| `/api/stats` | GET | no | Per-thread runtime stats (queue depth, etc.) |
| `/api/exec` | POST | optional | Run a Lua chunk on the given node (see 17.6) |
| `/api/reload` | POST | optional | Hot-reload self / a specific node / all nodes (see 17.7) |

When `XADMIN_TOKEN=...` is set, `/api/exec` and `/api/reload` require `X-Xadmin-Token: <token>`. `/api/peers` and `/api/stats` are always public.

### 17.6 Remote exec — `/api/exec`

Body: `{"target": "self"|"name"|"name:N", "script": "..."}`.

```bash
# Local (caller-side short-circuit, no NATS wire)
curl -X POST http://127.0.0.1:18091/api/exec \
  -H 'Content-Type: application/json' \
  -d '{"target":"self","script":"return 1+2, xthread.current_id()"}'
# → {"ok":true,"target":"xadmin1","stdout":"","result":"3\t1"}

# Cross-process (over NATS)
curl -X POST http://127.0.0.1:18091/api/exec \
  -H 'Content-Type: application/json' \
  -d '{"target":"xadmin2","script":"return os.time()"}'
# → {"ok":true,"target":"xadmin2","stdout":"","result":"<timestamp>"}
```

Underneath this is the xrouter builtin `@run_script`. `result` is the script's top-level `return` values joined by tabs; `stdout` is whatever the script printed.

### 17.7 Remote hot-reload — `/api/reload`

Body: `{"target": "self"|"all"|"name"}`.

```bash
# Reload this node only
curl -X POST http://127.0.0.1:18091/api/reload \
  -H 'Content-Type: application/json' -d '{"target":"self"}'

# Reload a specific node (cross-process)
curl -X POST http://127.0.0.1:18091/api/reload \
  -H 'Content-Type: application/json' -d '{"target":"xadmin2"}'

# Reload every discovered node (self + all peers) in one shot
curl -X POST http://127.0.0.1:18091/api/reload \
  -H 'Content-Type: application/json' -d '{"target":"all"}'
```

Sample response:

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

The `current` / `notified` / `deferred` counts are explained in §19.4. Reload never restarts the process; new code takes effect immediately. See §19.2 for how state survives.

### 17.8 End-to-end smoke test (recommended)

```bash
# 1. Start NATS + xadmin1 + xadmin2.
# 2. Edit scripts/xadmin/xadmin_app.lua — add a marker field to the /api/peers response.
# 3. From xadmin1:   curl POST /api/reload {target:"all"}
# 4. curl http://127.0.0.1:18091/api/peers  → marker present
# 5. curl http://127.0.0.1:18092/api/peers  → marker present too (cross-process reload OK)
# 6. Revert the edit + reload all again      → marker gone.
```

No xnet process is restarted at any point.

---

## 18. xnats Cross-Process RPC

`scripts/core/server/xnats.lua` + `scripts/core/server/xnats_worker.lua` implement a NATS-based cross-process transport with two operations: `publish` (broadcast) and `rpc` (synchronous-looking call). All NATS I/O lives on the dedicated `xthread.NATS` thread; business threads talk to it via `xthread.post`/`xthread.rpc`.

### 18.1 Startup

```lua
local xnats = dofile('scripts/core/server/xnats.lua')

xnats.start({
    host    = '127.0.0.1',
    port    = 4222,
    name    = 'game1',                                 -- unique process id
    prefix  = 'xnet.test',                             -- NATS subject prefix
    workers = { xthread.MAIN, xthread.WORKER_GRP3 },   -- local business worker IDs
    reconnect_ms   = 1000,
    rpc_timeout_ms = 10000,
})
```

The `workers` list serves two roles:

- **Inbound routing**: a remote `xnats.rpc("game1:N", pt, ...)` is dispatched to `workers[N]` (1-based). Without `:N`, the local NATS thread round-robins.
- **Caller-side short-circuit routing**: see §18.4.

### 18.2 Propagating routing info to worker threads

`xnats.start` already calls `xnats.bind_local` on the calling thread (usually MAIN). Other business threads have isolated Lua states and need an explicit push:

```lua
-- Main thread, after xhttp.start(...)
xnats.bind_workers(xhttp.worker_ids())
```

`bind_workers` posts `xnats_bind_local` to each target. The target thread's `xnats.lua` top level installs a handler that writes `self_name` and `worker_threads` into **that** thread's `_G.__xnet_xnats_state`, enabling its short-circuit path.

### 18.3 Unified return shape

```lua
local channel_ok, app_ok, ret1, ret2, ... = xnats.rpc(target, pt, ...)
```

- `channel_ok == false` → channel-level failure (not connected, timeout, target not present, missing local handler). Second value is the error string.
- `channel_ok == true`  → channel succeeded. `app_ok` is the callee handler's first return (boolean by convention); the rest are its remaining returns.

**The shape is identical for the local short-circuit and remote NATS paths** — the caller doesn't have to branch. For a handler returning `(true, "done")`, both paths yield `(true, true, "done")`.

```lua
xthread.register('do_lookup', function(key)
    -- ... lookup ...
    return true, value
end)

-- Caller:
local channel_ok, app_ok, value = xnats.rpc('peer:1', 'do_lookup', 'foo')
if not channel_ok then
    io.stderr:write('channel: ' .. tostring(app_ok) .. '\n')
elseif not app_ok then
    io.stderr:write('app: ' .. tostring(value) .. '\n')
else
    print('got', value)
end
```

### 18.4 Caller-side local short-circuit

`xnats.rpc(target, pt, ...)` parses the target:

1. process name == `state.self_name` → skip NATS, call `xthread.rpc(local_worker_tid, pt, 0, ...)` directly.
2. otherwise → route through the NATS thread and serialise to the wire.

Short-circuit requires the thread to have been bound (it called `xnats.start` itself, or received an `xnats_bind_local` post from `bind_workers`). **An unbound thread silently falls back to the NATS wire path** — still correct, just one extra hop.

When the resolved local target id equals the current thread id, xnats.rpc avoids the self-RPC deadlock by looking up the stub directly and `pcall(h, ...)`'ing it, packaging the result in the unified shape.

### 18.5 Target string format

- `"name"` → round-robin over `workers`.
- `"name:N"` → 1-based index into `workers[N]`.
- An out-of-range `N` returns `channel_ok=false, "xnats: local worker idx out of range: N"` (or the remote equivalent).

### 18.6 publish (broadcast)

```lua
xnats.publish(pt, arg1, arg2, ...)
```

Sent to `prefix .. '.broadcast'`. Every process subscribed to that prefix has its NATS thread fan the message out to all of its own `workers` via POST.

---

## 19. Hot Reload Protocol

xnet2lua ships a **no-restart** script hot-reload mechanism: each thread's top-level Lua is re-`dofile`d, new closures take effect in place, in-flight coroutines survive.

### 19.1 What reload does — and doesn't do

**Reload does**:

- For each target thread, call `xnet.__reload()` (a C-side builtin), which runs `luaL_dofile(thread_script)` to re-execute the script's top level.
- Main thread additionally refreshes the refs for `__tick_ms`, `__update`, `__uninit`, `__thread_handle`.
- xrouter is a singleton; `router.register(pt, h)` **overwrites in place** on the existing stub table — new handlers fire on the next message.
- Module state tables stored under `_G[STATE_KEY]` survive untouched; new code reads the old data.

**Reload does not**:

- **Re-run `__init`** — avoids re-bootstrapping listeners, re-`xnet.init()`, etc.
- **Drop in-flight coroutines** — xrouter's `rpc_context` and the C-side pending table keep them alive until their reply lands; top-level dofile does not touch those tables.
- **Change thread IDs or topology** — thread count, worker assignment stay the same.

### 19.2 Persisting state across reload

Reload makes module-local variables (`local connections = {}`) brand-new tables. Old coroutines that captured the previous reference are now looking at a **different** table than the new code reads — silent inconsistency.

The fix is to put any cross-reload state into `_G`:

```lua
local STATE_KEY = '__myapp_state'
local state = rawget(_G, STATE_KEY)
if type(state) ~= 'table' then
    state = {}
    rawset(_G, STATE_KEY, state)
end
if type(state.connections) ~= 'table' then state.connections = {} end
if state.counter == nil then state.counter = 0 end

-- Then alias locally:
local connections = state.connections   -- old code, new code, all coroutines: same table
```

`xhttp.lua`, `xnats.lua`, `xnats_worker.lua`, `xadmin_worker.lua`, `xrouter.lua`, `xhttp_router.lua` all follow this pattern — use them as references.

### 19.3 Three ways to trigger reload

#### Path 1 — xadmin HTTP (recommended for ops)

See §17.7.

#### Path 2 — POST `@reload_thread` to a single thread

```lua
xthread.post(target_tid, '@reload_thread')
```

`@reload_thread` is **intercepted by C** inside the thread message handler and goes straight to `xnet.__reload()`. It never enters the Lua handler path.

#### Path 3 — RPC `@reload` to coordinate a whole-process reload

```lua
local channel_ok, app_ok, msg = xnats.rpc('peer_or_self', '@reload')
-- msg looks like "current=1 notified=2 deferred=2"
```

`@reload` is an xrouter builtin (see `scripts/core/share/xrouter.lua`). It runs on one business worker of the target process, broadcasts `@reload_thread` to every thread of that process, and adds a few **deferred** threads to a defer set.

### 19.4 Defer semantics

The `@reload` coordinator builds the defer set:

| Included when | Why |
|---|---|
| **The reply_router thread** | The RPC reply hasn't been written yet; the thread must finish sending it before reloading itself. |
| **The current handler's own thread** | Reloading mid-handler would invalidate the running handler context. |
| **`explicit_defer_id`** (optional) | Caller-provided extra thread that must also be deferred. |

Deferred threads do NOT get an immediate `@reload_thread` post. Their reload is hooked on `req.after_reply` — once the RPC reply is on the wire, the coordinator posts `@reload_thread` to them.

Returned message format:

```
current=<current_thread_id> notified=<count> deferred=<count>
```

- `current` — the business-worker thread that handled this `@reload` call.
- `notified` — threads that received `@reload_thread` immediately.
- `deferred` — threads whose reload was deferred via the after_reply hook.

### 19.5 Checklist for making your own module reload-safe

1. **Top level only does dofile-safe work** — register handlers, populate `_G` state, define routes. No `xnet.init()`, no opening sockets.
2. **One-shot side effects belong in `__init`** — listener sockets, `xnet.init()`, `xtimer.init(...)`, thread creation.
3. **Cross-reload state lives in `_G[STATE_KEY]`** — connection tables, counters, caches, in-flight bookkeeping.
4. **Register handlers via `xthread.register(pt, h)` or `router.register(pt, h)`** — both go through the xrouter singleton and support in-place overwrite.
5. **Use the `local foo = state.foo` aliasing pattern** so old and new code (and old/new coroutines) reference the same sub-table.
6. **Coroutine-shaped request dispatch** — let yielding APIs (`xnats.rpc`, `xthread.rpc`, `xtimer` callbacks) be called synchronously inside the handler; the response flows back through the coroutine naturally. `scripts/xadmin/xadmin_worker.lua`'s `start_request` + per-connection `queue` is the reference implementation.
7. **Smoke-test**: change one line → `POST /api/reload {target:"self"}` → confirm new behavior live → revert + reload again → confirm gone. No process restart in either step.

---

## 20. Lua Debugging and VSCode Debugging

xnet2lua includes a native Lua debugger for its multi-OS-thread,
multi-`lua_State`, coroutine-heavy runtime. It is not based on `Local Lua
Debugger`. Instead, xnet starts a small in-process TCP debug service, and
`tools/xdebug_dap.js` bridges that protocol to VSCode's Debug Adapter Protocol.

### 20.1 Files and Responsibilities

| File | Purpose |
|---|---|
| `xlua/lua_xdebug.c` / `xlua/lua_xdebug.h` | Native C debug core: TCP service, breakpoints, stepping, stacks, locals, thread state |
| `tools/xdebug_dap.js` | VSCode DAP bridge, run by Node.js on the development host |
| `.vscode/launch.json` | VSCode attach configuration |
| `.vscode/tasks.json` | Background task that starts the DAP bridge |
| `xdebug.md` | Short debugger guide and raw TCP protocol reference |

### 20.2 Build

The default build does not include the debugger:

```bash
make xnet
```

Compile debugger support into `bin/xnet`:

```bash
mingw32-make -B BUILD_MODE=debug WITH_HTTPS=0 WITH_XDEBUG=1 xnet
```

LuaJIT is supported too:

```bash
mingw32-make -B BUILD_MODE=debug WITH_HTTPS=0 WITH_XDEBUG=1 LUA_BACKEND=luajit xnet
```

MSVC:

```bat
build.bat debug nohttps xdebug xnet
```

Keep the switches separate:

| Switch | Phase | Meaning |
|---|---|---|
| `WITH_XDEBUG=1` | Build time | Compile debugger support into the executable; does not start debugging |
| `XDEBUG_BOOT=1` | Process startup | Start the debug service during process boot |
| `xthread.xdebug_start(...)` | Runtime | Start the debug service on demand after the process is already running |

The old `XDEBUG=1` startup flag is no longer used.

### 20.3 Start Debugging at Process Boot

Useful for local development when you want to debug from the first line:

```bat
bin\xnet.exe scripts/xadmin/xadmin_main.lua SERVER_NAME=xadmin1 XADMIN_PORT=18091 XDEBUG_BOOT=1 XDEBUG_PORT=19090 XDEBUG_WAIT=1
```

Arguments:

| Argument | Meaning |
|---|---|
| `XDEBUG_BOOT=1` | Start the debug service during process boot |
| `XDEBUG_PORT=19090` | Native debug TCP port; `19090` is the recommended default |
| `XDEBUG_WAIT=1` | Stop each Lua state on its first executable Lua line so VSCode can attach before it continues |

If you do not want the process to stop during startup:

```bat
XDEBUG_BOOT=1 XDEBUG_PORT=19090 XDEBUG_WAIT=0
```

### 20.4 Start Debugging On Demand

This is the recommended path for test environments or remote incidents. Start
the process without any debug startup flags:

```bat
bin\xnet.exe scripts/xadmin/xadmin_main.lua SERVER_NAME=xadmin1 XADMIN_PORT=18091
```

When debugging is needed, run this from xadmin's script executor:

```lua
local ok, msg = xthread.xdebug_start(19090, false)
return ok, msg
```

Check status:

```lua
local running, port = xthread.xdebug_status()
return running, port
```

For on-demand remote startup, pass `false` as the second argument: start the
service, attach VSCode, set breakpoints, then trigger the request again. Passing
`true` makes Lua threads stop on their next executable line, which is useful
only when the debugger is ready to attach immediately.

### 20.5 VSCode Workflow

The debugger itself does not require VSCode, but the recommended client is
VSCode with its built-in DAP debugger. This section gives **copy-paste ready**
`.vscode/` files. These files are **not committed** to the repo; each developer
creates them locally under the workspace root.

#### 20.5.1 Prerequisites

- `bin/xnet.exe` built with `WITH_XDEBUG=1` (see §20.2).
- Node.js installed (≥ 18 recommended). `tools/xdebug_dap.js` is the Node
  bridge that translates xnet's native debug protocol into DAP for VSCode.
- An xnet process is running with the debug service enabled via either
  `XDEBUG_BOOT=1` (§20.3) or `xthread.xdebug_start(...)` (§20.4).

#### 20.5.2 Create `.vscode/tasks.json`

Wire the DAP bridge as a pre-launch task. VSCode will run
`node tools/xdebug_dap.js ...` on F5 and the bridge listens for DAP on
`127.0.0.1:4711`.

```json
{
    "version": "2.0.0",
    "tasks": [
        {
            "label": "xnet-xdebug-dap",
            "type": "shell",
            "command": "node",
            "args": [
                "${workspaceFolder}/tools/xdebug_dap.js",
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

`beginsPattern` / `endsPattern` exactly match the strings
`tools/xdebug_dap.js` prints (`xnet-xdebug-dap starting` and
`xnet-xdebug-dap listening on 127.0.0.1:4711`) so VSCode can tell when the
background task is ready.

Bridge flags:

| Flag | Default | Meaning |
|---|---|---|
| `--listen` | `4711` | Local port the bridge exposes to VSCode (DAP side). |
| `--xdebug-host` | `127.0.0.1` | Host where the native debug service listens. For remote debugging, keep `127.0.0.1` and use port-forwarding (see §20.7). |
| `--xdebug-port` | `19090` | Native debug port — must match `XDEBUG_PORT`. |
| `--cwd` | process CWD | Used to normalize absolute breakpoint paths down to repo-relative paths; always pass `${workspaceFolder}` explicitly. |

#### 20.5.3 Create `.vscode/launch.json`

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

Key fields:

| Field | Required | Meaning |
|---|---|---|
| `type` | yes | Hard-coded `node`. VSCode talks DAP directly via `debugServer`; it does not actually launch a Node debugger. |
| `debugServer` | yes | Must match `--listen` in `tasks.json` (default `4711`). |
| `preLaunchTask` | yes | Auto-starts the `xnet-xdebug-dap` background task; without it, you must start the bridge manually. |
| `cwd` | yes | Repo root. Lua source resolution and breakpoint path normalization are anchored here. |
| `xdebugHost` / `xdebugPort` | no | Passed through to the bridge so you can switch targets purely from `launch.json`; keep them aligned with `tasks.json` to avoid confusion. |

Add more `configurations` entries (with different `debugServer` and
`xdebugPort` values) to attach to multiple targets concurrently — for example
one local and one remote process.

#### 20.5.4 One-shot Debug Flow

1. Start xnet with debug enabled (§20.3 or §20.4).
2. Open the workspace in VSCode; confirm both JSON files exist under `.vscode/`.
3. Open Run and Debug, pick `XNet Lua Attach :19090`, press F5.
4. VSCode auto-runs the `xnet-xdebug-dap` background task (terminal shows
   `xnet-xdebug-dap listening on 127.0.0.1:4711`), then attaches.
5. Set breakpoints in Lua files and trigger the matching request.

Connection chain: `VSCode ──DAP──▶ 127.0.0.1:4711 (Node bridge) ──native──▶ 127.0.0.1:19090 (xnet built-in)`.

When a breakpoint hits, the current xnet thread is visible in three places:

| Location | Example |
|---|---|
| Call Stack thread name | `T60 stopped scripts/xadmin/xadmin_app.lua:165 (xadmin_worker.lua)` |
| Debug Console | `[xnet] breakpoint: T60 stopped at scripts/xadmin/xadmin_app.lua:165 ...` |
| Variables panel | `XNet Thread` scope with `xnet_thread_id`, `script`, and `stopped_at` |

#### 20.5.5 `.vscode/` Layout and Setup

Place both JSON snippets under a `.vscode/` directory at the repo root. The
file names are fixed:

```
xnet2lua/
├── .vscode/
│   ├── tasks.json    ← see §20.5.2
│   └── launch.json   ← see §20.5.3
├── tools/xdebug_dap.js
├── bin/xnet.exe
└── ...
```

Steps:

1. Create the `.vscode` folder at the repo root (skip if it exists).
   On Windows:

   ```bat
   mkdir .vscode
   ```

   Or right-click the empty area in the VSCode file tree ▶ *New Folder* ▶
   name it `.vscode`.

2. Create `.vscode/tasks.json` and paste the content from §20.5.2.
3. Create `.vscode/launch.json` and paste the content from §20.5.3.
4. Reload the VSCode window (`Ctrl+Shift+P` ▶ *Developer: Reload Window*) or
   refresh the Run and Debug panel; `XNet Lua Attach :19090` will appear in
   the dropdown.

Common tweaks:

- **Port conflicts**: change `--listen` in `tasks.json` and `debugServer` in
  `launch.json` together — they must match. When you change `XDEBUG_PORT` on
  the xnet side, also sync `--xdebug-port` in `tasks.json` and `xdebugPort`
  in `launch.json`.
- **Attach multiple targets in parallel**: duplicate the task (change `label`
  and `--listen`) and duplicate the configuration (change `name`,
  `debugServer`, `preLaunchTask`). Pick the right entry when hitting F5.
- **Node not on PATH**: replace `"command": "node"` in `tasks.json` with an
  absolute path, e.g. `"C:/Program Files/nodejs/node.exe"`.
- **JSON parse errors**: standard `.json` forbids comments. Rename the file
  to `.jsonc` or add a `files.associations` entry mapping `tasks.json` /
  `launch.json` to `jsonc` if you want inline comments.
- **Config not picked up**: make sure the workspace was opened as a folder
  (not as a single file) and `.vscode/` sits directly under the workspace
  root, not nested deeper.

Whether to commit `.vscode/` to git is up to each project. Because ports and
Node paths differ per developer, a common pattern is to add `.vscode/` to a
local `.gitignore` and let everyone maintain their own copy based on the
templates above.

### 20.6 Threads and Coroutines

Each xnet OS thread owns an independent `lua_State`. The debugger installs a
line hook for each registered Lua state and wraps `coroutine.create` /
`coroutine.wrap`, so new coroutines inherit debug hooks.

These paths are debuggable:

- Main-thread scripts such as `scripts/xadmin/xadmin_main.lua`
- Dynamic worker scripts such as `scripts/xadmin/xadmin_worker.lua`
- xadmin HTTP request coroutines such as `scripts/xadmin/xadmin_app.lua`
- xrouter RPC handler coroutines
- The `/api/exec` path used by the xadmin script executor

Debug hooks must be installed by the OS thread that owns the target
`lua_State`. During on-demand startup, other threads enable themselves on their
next update tick, which avoids touching another thread's Lua state directly.

### 20.7 Remote Debugging

The native debug service listens on the target machine's own `127.0.0.1`.
Do not expose the debug port directly to the public network. Use port
forwarding instead.

SSH remote host:

```bash
ssh -L 19090:127.0.0.1:19090 user@remote-host
```

Then keep VSCode attached to local `127.0.0.1:19090`.

Android device or emulator:

```bash
adb forward tcp:19090 tcp:19090
```

iOS device:

```bash
iproxy 19090 19090
```

iOS Simulator or local macOS usually works with the local port directly. The
preferred rule is simple: keep VSCode configured for a local port and forward
that local port to the target device or machine.

### 20.8 Performance and Security

Performance impact has three levels:

| State | Impact |
|---|---|
| `WITH_XDEBUG=0` | Debugger is not compiled; no runtime impact |
| `WITH_XDEBUG=1`, service not started | Only lightweight state registration; no line hook; very small impact |
| Debug service running | Every Lua line enters the debug hook; hot loops and high-frequency code slow down noticeably |

Security recommendations:

- Build production binaries with `WITH_XDEBUG=0`.
- Test binaries may use `WITH_XDEBUG=1`, but should not boot with `XDEBUG_BOOT=1` by default.
- Protect xadmin's remote script executor with authentication.
- Do not expose `XDEBUG_PORT` publicly; use SSH/ADB/iproxy forwarding.

### 20.9 Troubleshooting

**1. Why can I debug after building with `WITH_XDEBUG=1`?**

Either the process was started with `XDEBUG_BOOT=1`, or someone already called
`xthread.xdebug_start(...)`. `WITH_XDEBUG=1` alone only compiles the capability.

**2. Does the old `XDEBUG=1` flag still work?**

No. Startup now only recognizes `XDEBUG_BOOT=1`.

**3. Breakpoints do not hit.**

Check that VSCode is attached to the same port as `XDEBUG_PORT`; make sure local
files match the running code; and place breakpoints on executable Lua lines, not
on comments, blank lines, or some function declaration lines.

**4. The process is suspended after startup.**

That is expected when `XDEBUG_WAIT=1` is used. Attach VSCode and continue, or
use `XDEBUG_WAIT=0`.

**5. Which thread am I stopped in?**

Look at the Call Stack thread name or the `XNet Thread` scope in the Variables
panel.
