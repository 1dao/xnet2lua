# xnet2lua

A small C networking runtime with an embedded Lua scripting layer. The C core handles cross-platform polling, threading, and timers; the Lua layer exposes an actor-style API where every OS thread owns an isolated Lua state and communicates through asynchronous POST or coroutine-backed RPC.

## Features

- Cross-platform polling: epoll on Linux, kqueue on macOS/BSD, WSAPoll on Windows, `poll` fallback.
- Per-thread Lua state with framework-managed worker threads (`xthread`).
- Asynchronous messages (`xthread.post`) and synchronous RPC over coroutines (`xthread.rpc`).
- Embedded Lua via `minilua` by default; LuaJIT optional via `LUA_BACKEND=luajit`.
- Lua bindings: `xnet` (sockets / TLS), `xthread` (threads / RPC / logging), `xtimer` (timer wheel), `xutils` (JSON via yyjson, config, filesystem), `cmsgpack` (MessagePack), `xdebug` (optional VSCode debug adapter).
- Lua share modules: `xhttp` (HTTP/1.x server with router), `xrouter` (unified POST/RPC dispatch), `xredis` / `xmysql` / `xnats` worker stacks, `xsession` (HTTP session helper).
- Hot reload protocol, cross-process RPC over NATS, and an `xadmin` console for remote exec/reload.
- In-tree regression tests with a CI matrix that covers both stripped and full-featured build flags.

## Architecture

```
+-----------------------------------------------------------+
|  Lua Application Layer (your scripts)                     |
+--------------------------------------+--------------------+
|  xnet (sockets / TLS)                | xthread            |
|  xutils (JSON / config)              | (threads / RPC)    |
|  cmsgpack (MessagePack)              | xtimer             |
+--------------------------------------+--------------------+
|  C core: xpoll / xchannel / xsock / xtimer / xthread      |
+-----------------------------------------------------------+
|  Third-party: minilua / LuaJIT / mbedTLS / yyjson /       |
|               rpmalloc / libdeflate / lpegrex             |
+-----------------------------------------------------------+
```

Key design choices:

- **One Lua state per OS thread.** Threads are fully isolated; nothing is shared by reference.
- **Two messaging primitives.** `post` is fire-and-forget; `rpc` runs the caller on a coroutine and resumes it with the reply.
- **One polling backend per platform, chosen at compile time.** Same Lua API regardless of which OS interface is underneath.

See [`xnet2lua-docs-en.md`](xnet2lua-docs-en.md) (or the Chinese version) for the full design rationale.

## Project Layout

```
xnet2lua/
  Makefile / build.bat       GNU make + MSVC entry points
  xnet_main.c                "xnet" runner — the embeddable example main()
  x{poll,sock,thread,timer,channel,args,daemon,log}.[ch]
                             C core (event loop, thread pool, sockets, ...)
  xlua/                      C->Lua bindings (luaopen_xnet, luaopen_xthread, ...)
  scripts/core/share/        Reusable pure-Lua modules (xrouter, xhttp_router, xsession, ...)
  scripts/core/server/       Service threads (xhttp, xredis, xmysql, xnats workers)
  demo/                      Runnable example scripts + the xthread C regression
  tests/                     Unit tests (C + Lua) and the CI test orchestrator
  tools/                     xdebug_dap — DAP adapter for VSCode Lua debugging
  3rd/                       Vendored or submoduled third-party code
```

## Requirements

- GCC/Clang with `make` on Linux and macOS.
- MSYS2 MinGW-w64 GCC with `make`, or MSVC through `build.bat`, on Windows.
- The default `LUA_BACKEND=minilua` build needs **no** external dependency — `3rd/minilua.h` is in-tree.

### Optional third-party components

Each is activated by a build flag and lives under `3rd/` as a submodule (or in-tree single-file lib).

| Component   | Activated by                  | Used for                              | Submodule path     |
| ----------- | ----------------------------- | ------------------------------------- | ------------------ |
| LuaJIT      | `LUA_BACKEND=luajit`          | LuaJIT 2.1 runtime instead of minilua | `3rd/luajit/`      |
| mbedTLS     | `WITH_HTTPS=1` (default on)   | TLS for `xnet.attach_tls` / HTTPS     | `3rd/mbedtls3/`    |
| rpmalloc    | `WITH_RPMALLOC=1` (default on)| Per-thread allocator routed via `xmacro.h` | `3rd/rpmalloc/` |
| yyjson      | always                        | JSON in `xutils.json_*`                | `3rd/yyjson.c`     |
| libdeflate  | always                        | `Content-Encoding: gzip/deflate` in xhttp | `3rd/libdeflate/` |
| lpegrex     | optional, embed yourself      | PEG parser library                    | `3rd/lpegrex/`     |

Fetch all submodules:

```sh
git submodule update --init --recursive
```

## Build

Build the static library, the `xnet` runner, and the debug adapter helper:

```sh
make all
```

Fast CI-style build without TLS and rpmalloc:

```sh
make all BUILD_MODE=debug WITH_HTTPS=0 WITH_RPMALLOC=0
```

On Windows with MSVC:

```bat
build.bat
```

Useful build flags:

- `BUILD_MODE=debug|release`
- `WITH_HTTP=0|1`
- `WITH_HTTPS=0|1`
- `WITH_RPMALLOC=0|1`
- `WITH_XDEBUG=0|1`  (compile the Lua debugger into `bin/xnet`; runtime is opt-in)
- `LUA_BACKEND=minilua|luajit`

Build artifacts:

- `bin/xnet` (`.exe`) — Lua runner; `./bin/xnet script.lua [KEY=VAL ...]`
- `libxnet.a` — the C core, link this to embed xnet2lua into another program
- `tools/xdebug_dap` (`.exe`) — DAP adapter that fronts the in-process Lua debugger for VSCode
- `bin/test_core` (`.exe`) — C unit binary (built by the test targets, not by `all`)
- `bin/xthread_test` (`.exe`) — C threading regression binary (built by the test targets)

## Test

Test orchestration lives in `tests/Makefile`. The root `Makefile` keeps compatibility shortcuts such as `make test` and delegates them into `tests/`. You can also call targets directly from inside the tests directory — `ROOT` defaults to `..`, so `cd tests && make <target>` works without extra arguments.

### Target hierarchy

From fastest to most thorough:

| Target      | Scope                                                                                              |
| ----------- | -------------------------------------------------------------------------------------------------- |
| `unit-c`    | C unit binary only (`tests/c/test_core.c`).                                                        |
| `unit-lua`  | Lua unit specs only (`tests/lua/*_spec.lua`).                                                      |
| `unit`      | `unit-c` + `unit-lua`.                                                                             |
| `test`      | `unit` + the C `xthread_test` + the `test-lua-core` regression scripts under `demo/`.              |
| `matrix`    | `ci-fast` (debug, no TLS, no rpmalloc, full `test`) **and** `ci-feature` (release, TLS + rpmalloc, `unit` only), both with forced rebuild. |

`matrix` is the **default** target of `tests/Makefile`, so `cd tests && make` with no argument runs the full two-tier matrix. This is intentional: someone who descends into `tests/` is usually there to validate broadly, and the two configurations cover code paths a single default cannot — rpmalloc lifecycle, TLS compile gates, release-mode optimization behavior. Pick a narrower target explicitly when you want a faster turnaround.

### Common invocations

```sh
make test                                # root delegates to tests/
make -C tests test                       # direct invocation
cd tests && make test                    # same, from inside tests/
cd tests && make                         # full matrix (default)
make unit                                # unit layer only
make run-lua SCRIPT=demo/xutils_main.lua # single Lua example through the embedded runtime
```

On Windows:

```bat
build.bat unit
build.bat test
build.bat run-lua script=demo/xutils_main.lua
```

### CI matrix

The CI matrix runs the same two tiers as the local `matrix` target on Linux, macOS, and Windows:

- `debug-nohttps-norpmalloc`: full `make test` with TLS and rpmalloc disabled for fast regression feedback.
- `release-https-rpmalloc`: `make unit` after compiling with TLS and rpmalloc enabled to keep those build paths covered.

The Ubuntu debug lane also runs a `gcov` smoke check for the C unit layer.

### Coverage

Generate local C unit coverage data:

```sh
make coverage-c
# or: cd tests && make coverage-c
```

This emits `*.gcov` summaries next to the checkout and raw `gcda/gcno` data under `coverage/`.

## Quick Start: minimal HTTP server

Two files — a main thread that boots the worker pool, and an app script that registers routes. Both run under `bin/xnet`.

**`hello_main.lua`** — main thread:

```lua
local xhttp = dofile("scripts/core/server/xhttp.lua")

local function __init()
    assert(xhttp.start({
        host         = "127.0.0.1",
        port         = 8080,
        worker_count = 2,
        worker_name  = "hello",
        app_script   = "hello_app.lua",
    }))
end

local function __uninit() end

return { __init = __init, __uninit = __uninit }
```

**`hello_app.lua`** — runs inside each worker thread:

```lua
local router = dofile("scripts/core/share/xhttp_router.lua")

router.get("/hello", function(req)
    local name = req.query.name or "world"
    return {
        status  = 200,
        body    = "Hello, " .. name .. "!\n",
        headers = { ["Content-Type"] = "text/plain; charset=utf-8" },
    }
end)

return { handle = function(req) return router.handle(req) end }
```

Build and run:

```sh
make all WITH_HTTPS=0
./bin/xnet hello_main.lua
curl http://127.0.0.1:8080/hello?name=xnet2lua
```

More entry points:

- `demo/xhttp_main.lua` — HTTP server + client smoke test
- `demo/xnet_main.lua`  — raw TCP + `xsession` RPC
- `demo/xrouter_test.lua` / `demo/xhttp_router_test.lua` — router unit checks
- `demo/xnats_main.lua` — cross-process RPC over NATS (needs a NATS server)

## Lua Modules

C-registered (auto-loaded via `luaL_requiref` in `xnet_main.c`; `require()` works without a search path):

| Module      | Purpose                                                            | Reference            |
| ----------- | ------------------------------------------------------------------ | -------------------- |
| `xthread`   | thread lifecycle, POST / RPC, log levels, optional debugger control | docs §4              |
| `xnet`      | TCP listen / connect / attach, frame protocols, TLS                | docs §5–§7           |
| `xtimer`    | hashed timer-wheel bindings                                        | docs §3 (overview)   |
| `xutils`    | JSON (yyjson), config files, directory scan, base64/hex            | docs §10             |
| `cmsgpack`  | MessagePack encode / decode                                        | docs §9              |

Pure-Lua, loaded via `dofile`:

| Path                                              | Purpose                                       | Reference   |
| ------------------------------------------------- | --------------------------------------------- | ----------- |
| `scripts/core/share/xrouter.lua`                  | unified POST + RPC dispatch with coroutines   | docs §3.3   |
| `scripts/core/share/xhttp_router.lua`             | HTTP path/method router with path params      | docs §8.5   |
| `scripts/core/share/xhttp_codec.lua`              | HTTP request/response parsing                 | docs §8     |
| `scripts/core/share/xsession.lua`                 | request/reply session helper over raw `xnet`  | docs §5     |
| `scripts/core/share/xtimerx.lua`                  | higher-level timer scheduling on top of xtimer | docs §3    |
| `scripts/core/server/xhttp.lua` + `xhttp_worker.lua` | HTTP/HTTPS server boot + worker pool       | docs §8     |
| `scripts/core/server/xredis*.lua`                 | Redis client thread                            | docs (examples) |
| `scripts/core/server/xmysql*.lua`                 | MySQL client thread                            | docs (examples) |
| `scripts/core/server/xnats*.lua`                  | NATS publish/subscribe + cross-process RPC    | docs §18    |

## Troubleshooting

Two traps you will hit if you stray from the provided build files. Both are documented in detail in docs §2.7.

- **MinGW: rpmalloc must be built with `-DENABLE_OVERRIDE=0`.** Otherwise rpmalloc replaces the libc `calloc` that MinGW's emulated TLS uses, and the first access to any `_Thread_local` variable recurses through `calloc → rpcalloc → get_thread_heap → __emutls_get_address → calloc → …` and blows the stack **before `main()` runs**, with no stdout/stderr at all. The project's `Makefile` and `build.bat` already pass this flag; if you write your own build rules, keep it.
- **`xmacro.h` must be included after `yyjson.h`.** `xmacro.h` does `#define free(p) rpfree(p)` (function-like macro), and yyjson's `yyjson_alc` struct has a `.free` field — without the right include order, the macro mangles `alc.free(ctx, doc)` into `alc.rpfree((ctx, doc))` and the program either fails to compile or corrupts the heap. Same rule applies to any third-party header with `.malloc`/`.free`/`.realloc` member fields.

## Documentation

Long-form reference docs live in:

- [`xnet2lua-docs-en.md`](xnet2lua-docs-en.md) (English)
- [`xnet2lua-docs-cn.md`](xnet2lua-docs-cn.md) (Chinese)

Task-oriented index:

| When you want to...                                  | Read                                   |
| ---------------------------------------------------- | -------------------------------------- |
| Understand the threading + Lua-state model           | docs §1, §3, §4                        |
| Embed xnet2lua into a C program                      | docs §2.6                              |
| Pick a Lua backend (minilua vs LuaJIT)               | docs §2.5                              |
| Configure / disable rpmalloc                         | docs §2.7                              |
| Write a TCP server with framing                      | docs §5, §6 + complete example §13     |
| Add TLS to a listener                                | docs §7                                |
| Build an HTTP/HTTPS API service                      | docs §8 + complete example §14         |
| Do cross-thread RPC                                  | docs §4.5 + complete example §15       |
| Do cross-process RPC over NATS                       | docs §18                               |
| Make a module hot-reload safe                        | docs §19                               |
| Debug Lua from VSCode                                | docs §20                               |
| Operate the xadmin console (remote exec / reload)    | docs §17                               |

## Contributing

See [`CONTRIBUTING.md`](CONTRIBUTING.md) for the development workflow, coding style, and the local checks expected before opening a PR.

## License

The project code is distributed under the BSD 2-Clause License. See [`LICENSE`](LICENSE).

Third-party code under `3rd/` keeps its own upstream license and copyright.
