*** Begin Patch
*** Add File: xnet2lua-docs-en.md
---
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

### 2.1 Build Core Static Library

```
# Enter project root
cd xnet2lua

# Build libxsock.a (core C library)
make

# Output: libxsock.a
```

### 2.2 Build demo Executables

```
cd demo

# Without HTTPS (default)
make

# With HTTPS support (requires mbedTLS)
make WITH_HTTPS=1

# Output: xnet (or xnet.exe)
```

### 2.3 Run demos

```
# Run TCP echo demo
./xnet demo/xnet_main.lua

# Run HTTP demo
./xnet demo/xhttp_main.lua

# Run HTTPS demo (requires WITH_HTTPS=1)
./xnet demo/xhttps_main.lua

# Run cross-thread RPC test
./xnet demo/xlua_main.lua

# Run with overrides (config items)
./xnet demo/xnats_main.lua SERVER_NAME=game1
```

### 2.4 Embedding

If you want to embed xnet2lua into your own C project:

1. Link libxsock.a into your executable
2. In your C entry, call the initialization sequence below:

```c
#define LUA_IMPL
#include "3rd/minilua.h"    // Single-header Lua embedding; you can also use system Lua

#include "xthread.h"
#include "xlua.h"

// Register Lua modules
luaL_requiref(L, "xthread",  luaopen_xthread,  1); lua_pop(L, 1);
luaL_requiref(L, "xnet",     luaopen_xnet,     1); lua_pop(L, 1);
luaL_requiref(L, "cmsgpack", luaopen_cmsgpack, 1); lua_pop(L, 1);
luaL_requiref(L, "xutils",   luaopen_xutils,   1); lua_pop(L, 1);

// Initialize thread system
xthread_init();
```

---

## 3. Program Entry and Thread Lifecycle

### 3.1 Thread Script Protocol

Each Lua thread script (including the main thread) must return a table defining lifecycle callbacks:

```lua
local function __init()
    -- Called once when the thread starts (establish connections, create sub-threads, etc.)
    print("Thread initialized")
end

local function __update()
    -- Per-frame / loop iteration
    -- For network threads, typically call xnet.poll(timeout_ms)
    xnet.poll(10)
end

local function __uninit()
    -- Called on thread exit (resource cleanup)
    print("Thread exited")
end

local function __thread_handle(reply_router, k1, k2, k3, ...)
    -- Called when receiving cross-thread messages (see Chapter 4)
end

return {
    __init          = __init,
    __update        = __update,
    __uninit        = __uninit,
    __thread_handle = __thread_handle,
}
```

### 3.2 __thread_handle Message Distribution Template

> 💡 **Recommended**: use the `demo/xthread_base.lua` module to skip this
> boilerplate entirely — see [3.3 xthread_base module](#33-xthread_base-module-recommended).
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

### 3.3 xthread_base module (recommended)

`demo/xthread_base.lua` packages the §3.2 boilerplate (`_stubs /
_thread_replys / __thread_handle` plus the coroutine wrapping and RPC reply
routing) into a small module so thread scripts only have to declare actual
business handlers.

```lua
-- worker.lua
local xth = dofile('demo/xthread_base.lua').new('MYAPP')

-- Plain POST handler: called directly, no coroutine.
xth.register('print_msg', function(text)
    print('[MYAPP]', text)
end)

-- POST handler that needs to RPC out: auto-wrapped in a coroutine, may yield.
xth.register_co('do_lookup', function(key)
    local ok, val = xthread.rpc(xthread.REDIS, 'xredis_call', 'GET', key)
    print('lookup:', ok, val)
end)

-- RPC handler: return values become the reply (true, ret1, ret2, ...).
-- Errors become (false, errmsg). Always runs in a coroutine, may yield freely.
xth.register_rpc('add', function(a, b)
    return a + b
end)

local function __init()  print('init')   end
local function __update() xnet.poll(10)  end
local function __uninit() print('uninit') end

return xth.thread_def({
    __init    = __init,
    __update  = __update,
    __uninit  = __uninit,
    -- __tick_ms = 10,                   -- optional, override default tick
})
```

**API summary:**

| Method | Purpose |
|---|---|
| `M.new(prefix)` | Create a fresh instance; `prefix` is the stderr log tag |
| `xth.register(pt, h)` | POST handler, **no** coroutine; `h(arg1, arg2, ...)` direct call |
| `xth.register_co(pt, h)` | POST handler auto-wrapped in a coroutine so it can RPC out |
| `xth.register_rpc(pt, h)` | RPC handler; return value becomes the reply, error becomes `(false, err)` |
| `xth.set_log_prefix(s)` | Change the log prefix |
| `xth.set_unknown_post(fn)` | Fallback `fn(pt, ...)` when no POST handler matches |
| `xth.set_unknown_rpc(fn)` | Fallback `fn(reply_router, co_id, sk, pt, ...)` when no RPC handler matches |
| `xth.set_handler_error(fn)` | Top-level error in a `register_co` coroutine: `fn(pt, err)` |
| `xth.current_request()` | The req object owned by the calling RPC coroutine (advanced) |
| `xth.thread_def{...}` | Returns the table given to the C runtime, with `__thread_handle` injected |

**Mapping from §3.2 hand-written template:**

- The legacy `xthread.register(pt, h)` ≈ `xth.register_co` (most common shape) or the more precise `xth.register` / `xth.register_rpc`.
- `_stubs` / `_thread_replys` are kept inside the module — no globals needed.
- `__thread_handle` is auto-injected by `xth.thread_def`.

See `demo/xlua_main.lua` and `demo/xlua_thread.lua` for an actual migration:
running `./demo/xnet demo/xlua_main.lua` exercises the full POST + RPC + nested
RPC-back-to-MAIN test suite using `xthread_base` end-to-end.

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

---

## 5. xnet Module — Asynchronous Networking

### 5.1 Initialization and Polling

```lua
-- Initialize the networking module (in every thread that uses networking)
assert(xnet.init())

-- Drive the event loop (usually in __update)
-- timeout_ms: maximum time to wait for events (0 = non-blocking, -1 = wait forever)
xnet.poll(10)

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
local xhttp = dofile("demo/xhttp.lua")

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
| worker_script | string | "demo/xhttp_worker.lua" | Worker script path |
| app_script | string | "demo/xhttp_app.lua" | Application routing script path |
| max_request_size | number | 16MB | Maximum request body size (bytes) |

### 8.2 Writing the Application Router (app_script)

Every worker thread will independently load the app_script, so routes are registered within the worker Lua State.

```lua
-- my_app.lua
local router = dofile("demo/xhttp_router.lua")

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
local router = dofile("demo/xhttp_router.lua")

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

### 11.2 Load Configuration in Lua

```lua
-- Load configuration file (usually in the main thread’s __init at the very start)
local ok, err = xutils.load_config("config/xnet.cfg")
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
| `xthread.WORKER_GRP1` | 10 | Worker group 1 start (10–29)|
| `xthread.WORKER_GRP2` | 30 | Worker group 2 start (30–49)|
| `xthread.WORKER_GRP3` | 50 | Worker group 3 start (50–59)|
| `xthread.WORKER_GRP4` | 60 | Worker group 4 start (60–69)|
| `xthread.WORKER_GRP5` | 70 | Worker group 5 start (70–99)|

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

local function __update()
    xnet.poll(10)
end

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
    __update = __update,
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

local function __update()
    xnet.poll(10)
end

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
    __update        = __update,
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

local xhttp = dofile("demo/xhttp.lua")

local CONFIG_FILE = "config/xnet.cfg"
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

### Application Router (api_app.lua)

```lua
-- api_app.lua - Each worker loads this file independently

local router = dofile("demo/xhttp_router.lua")

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
local function __update() end
local function __uninit() print("[COMPUTE] exit") end
 
return {
    __init = __init, __update = __update,
    __uninit = __uninit, __thread_handle = __thread_handle,
}
```

---

## 16. Best Practices and Considerations

### 16.1 Threading

- **Main thread only distributes**: The main thread is responsible for listening and distributing connections to workers; business logic should live in workers.
- **Every thread calls `xnet.init()`**: Every thread that uses networking must initialize xnet
- **`xnet.poll()` in `__update`**: Ensure the event loop remains driven; a typical poll timeout is 5–20ms
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
| Low latency | Decrease the timeout for `xnet.poll()` (e.g., 1ms) |
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
