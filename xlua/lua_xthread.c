/* lua_xthread.c - Lua bindings for xthread
**
** Message wire format (cmsgpack packed):
**
**   POST  ->  pack(nil,           pt, arg1, arg2, ...)
**   RPC   ->  pack(reply_router,  co_id, 0 (sk), pt, arg1, ...)
**   REPLY ->  pack(nil, "@async_resume", co_id, 0 (sk), req_pt, ok, r, ...)
**
** Lua handler convention (__thread_handle__):
**
**   POST: handler(nil,           pt, arg1, ...)
**   RPC:  handler(reply_router,  co_id, sk, pt, arg1, ...)
**         -> finds stubs[pt], calls it
**         -> calls reply(co_id, sk, pt, ok, results...)
**             which posts REPLY back to caller thread
**
** The REPLY is intercepted in C (thread_message_handler) before reaching Lua,
** and directly resumes the waiting coroutine.
**
** _thread_replys["xthread:<id>"] is auto-created on first access via a
** metatable __index hook registered by xthread.init().
**
** Wakeup flow:
**   xthread.rpc(target, pt, ...)
**     -> pack + xthread_post(target, thread_message_handler)
**     -> lua_yield(coroutine, 0)               [coroutine suspends]
**   target thread: handler runs -> calls reply(co_id, ...)
**   reply (C closure): packs @async_resume, xthread_post(caller, ...)
**   caller thread: @async_resume detected -> pending_pop(co_id) -> lua_resume
*/

#include <stdlib.h>
#include <string.h>
#include <stdio.h>

/* Use embedded minilua when building with xlua_test */
#if defined(LUA_EMBEDDED)
#include "../3rd/minilua.h"
#else
#include "lua.h"
#include "lauxlib.h"
#endif

#include "xthread.h"
#include "xlog.h"

/* ============================================================================
** Registry keys (per lua_State)
** ========================================================================== */
#define XTHREAD_PACK_KEY    "xthread.pack"       /* cmsgpack.pack function    */
#define XTHREAD_UNPACK_KEY  "xthread.unpack"     /* cmsgpack.unpack function  */
#define XTHREAD_HANDLER_KEY "xthread.handler"    /* Lua message handler func  */
#define XTHREAD_PENDING_KEY "xthread.pending"    /* {[co_id] = coroutine}     */
#define XTHREAD_COID_KEY    "xthread.next_co_id" /* integer auto-increment    */

/* ============================================================================
** Per-OS-thread Lua state table
** ========================================================================== */
static lua_State* _lua_states[XTHR_MAX];

/* ============================================================================
** ThreadMsg: heap buffer carrying a packed message across OS threads
** ========================================================================== */
typedef struct {
    size_t len;
    char   data[1]; /* flexible – allocate sizeof(ThreadMsg) + len - 1 */
} ThreadMsg;

static ThreadMsg* msg_alloc(const char* buf, size_t len) {
    ThreadMsg* m = (ThreadMsg*)malloc(offsetof(ThreadMsg, data) + len);
    if (m) { m->len = len; memcpy(m->data, buf, len); }
    return m;
}

/* Forward declaration */
static void thread_message_handler(xThread* thr, void* arg);

/* ============================================================================
** pack_to_msg
**
** Calls cmsgpack.pack with the top `nargs` values currently on the stack.
** Pops those values; leaves the stack otherwise unchanged.
** Returns the packed ThreadMsg*, or NULL on error.
** ========================================================================== */
static ThreadMsg* pack_to_msg(lua_State* L, int nargs) {
    /* Fetch pack function and insert it *below* the args */
    lua_getfield(L, LUA_REGISTRYINDEX, XTHREAD_PACK_KEY);
    lua_insert(L, -(nargs + 1));

    if (lua_pcall(L, nargs, 1, 0) != LUA_OK) {
        XLOGE("xthread: cmsgpack.pack error: %s", lua_tostring(L, -1));
        lua_pop(L, 1);
        return NULL;
    }
    size_t len;
    const char* buf = lua_tolstring(L, -1, &len);
    ThreadMsg* msg = msg_alloc(buf, len);
    lua_pop(L, 1); /* pop packed string */
    return msg;
}

/* ============================================================================
** unpack_msg
**
** Unpacks ThreadMsg onto L's stack.
** Returns number of values pushed, or -1 on error.
** ========================================================================== */
static int unpack_msg(lua_State* L, ThreadMsg* msg) {
    int base = lua_gettop(L);
    lua_getfield(L, LUA_REGISTRYINDEX, XTHREAD_UNPACK_KEY);
    lua_pushlstring(L, msg->data, msg->len);
    if (lua_pcall(L, 1, LUA_MULTRET, 0) != LUA_OK) {
        XLOGE("xthread: cmsgpack.unpack error: %s", lua_tostring(L, -1));
        lua_pop(L, 1);
        return -1;
    }
    return lua_gettop(L) - base;
}

/* ============================================================================
** Coroutine pending-RPC table helpers
** pending table: LUA_REGISTRYINDEX[XTHREAD_PENDING_KEY] = { [co_id] = thread }
** The table lives in the CALLER thread's registry; each thread tracks its own
** pending RPCs.
** ========================================================================== */

/* Increment and return next co_id (operates on caller thread's L) */
static lua_Integer next_co_id(lua_State* L) {
    lua_getfield(L, LUA_REGISTRYINDEX, XTHREAD_COID_KEY);
    lua_Integer id = lua_tointeger(L, -1) + 1;
    lua_pop(L, 1);
    lua_pushinteger(L, id);
    lua_setfield(L, LUA_REGISTRYINDEX, XTHREAD_COID_KEY);
    return id;
}

/* Store coroutine co in pending[co_id] (operates on caller thread's L) */
static void pending_put(lua_State* L, lua_Integer co_id, lua_State* co) {
    lua_getfield(L, LUA_REGISTRYINDEX, XTHREAD_PENDING_KEY);
    lua_pushinteger(L, co_id);
    /* Push the coroutine thread value onto co's stack, then xmove to L */
    lua_pushthread(co);
    lua_xmove(co, L, 1);
    lua_rawset(L, -3); /* pending[co_id] = coroutine */
    lua_pop(L, 1);     /* pop pending table */
}

/* Retrieve and remove coroutine from pending[co_id] (operates on caller thread's L).
** Returns the coroutine lua_State*, or NULL if not found. */
static lua_State* pending_pop(lua_State* L, lua_Integer co_id) {
    lua_getfield(L, LUA_REGISTRYINDEX, XTHREAD_PENDING_KEY);
    lua_pushinteger(L, co_id);
    lua_rawget(L, -2); /* pending[co_id] */

    if (!lua_isthread(L, -1)) {
        lua_pop(L, 2); /* pop nil + table */
        return NULL;
    }
    lua_State* co = lua_tothread(L, -1);
    lua_pop(L, 1); /* pop thread value */

    /* Remove from table: pending[co_id] = nil */
    lua_pushinteger(L, co_id);
    lua_pushnil(L);
    lua_rawset(L, -3);
    lua_pop(L, 1); /* pop pending table */
    return co;
}

/* ============================================================================
** l_reply_func  (C closure, upvalue = caller_id:integer)
**
** Registered as _thread_replys["xthread:<caller_id>"] on TARGET threads.
** Called by Lua as: reply(co_id, sk, req_pt, ok, r, ...)
** Packs a REPLY message and posts it back to the caller thread.
** Returns: true on success, false on failure.
** ========================================================================== */
static int l_reply_func(lua_State* L) {
    int caller_id = (int)lua_tointeger(L, lua_upvalueindex(1));
    int nargs = lua_gettop(L); /* (co_id, sk, req_pt, ok, r, ...) */

    /* Pack: (nil, "@async_resume", co_id, sk, req_pt, ok, r, ...) */
    lua_pushnil(L);
    lua_pushstring(L, "@async_resume");
    for (int i = 1; i <= nargs; i++)
        lua_pushvalue(L, i);

    ThreadMsg* msg = pack_to_msg(L, 2 + nargs);
    if (!msg) {
        lua_pushboolean(L, 0);
        return 1;
    }

    bool ok = xthread_post(caller_id, thread_message_handler, msg);
    if (!ok) {
        free(msg);
        XLOGE("xthread reply: xthread_post(%d) failed", caller_id);
    }
    lua_pushboolean(L, ok ? 1 : 0);
    return 1;
}

/* ============================================================================
** l_replys_index  (__index metamethod for _thread_replys)
**
** Auto-creates a C reply closure for keys matching "xthread:<id>".
** Caches the closure back into the table so __index is only called once.
** ========================================================================== */
static int l_replys_index(lua_State* L) {
    /* args: (table, key) */
    const char* key = lua_tostring(L, 2);
    if (key) {
        int caller_id = 0;
        if (sscanf(key, "xthread:%d", &caller_id) == 1 && caller_id > 0) {
            /* Create C closure capturing caller_id */
            lua_pushinteger(L, caller_id);
            lua_pushcclosure(L, l_reply_func, 1);

            /* Cache: _thread_replys[key] = closure (rawset to avoid re-triggering __index) */
            lua_pushvalue(L, 2);   /* key */
            lua_pushvalue(L, -2);  /* closure */
            lua_rawset(L, 1);      /* table[key] = closure */

            return 1; /* return closure */
        }
    }
    lua_pushnil(L);
    return 1;
}

/* ============================================================================
** thread_message_handler  (xthread C task)
**
** Runs on the TARGET thread (for POST/RPC) or CALLER thread (for REPLY).
** Unpacks the message and either:
**   a) Intercepts "@async_resume" → resumes the waiting coroutine directly
**   b) Dispatches to the registered Lua handler
** ============================================================================ */
static void thread_message_handler(xThread* thr, void* arg) {
    ThreadMsg* msg = (ThreadMsg*)arg;
    int id = xthread_get_id(thr);
    lua_State* L = _lua_states[id];

    if (!L) {
        XLOGE("xthread: no lua state for thread %d", id);
        free(msg);
        return;
    }

    int base = lua_gettop(L);
    int nvals = unpack_msg(L, msg);
    free(msg);
    if (nvals < 0) return; /* unpack failed */

    /* Unpacked layout (1-based, relative to base):
    **   base+1 : reply_router  (nil for POST/REPLY, string for RPC)
    **   base+2 : k1            (pt for POST, co_id for REPLY, co_id for RPC)
    **   base+3 : k2            (arg1 for POST, sk for REPLY/RPC)
    **   base+4 : k3            (arg2 for POST, req_pt for REPLY, pt for RPC)
    **   base+5+: rest
    */

    /* ── Intercept @async_resume (REPLY from target → resume coroutine) ── */
    /* REPLY always has base+1 = nil (reply_router is nil), base+2 = "@async_resume" */
    if (nvals >= 2) {
        int type = lua_type(L, base + 1);
        int b1isnil = lua_isnil(L, base + 1);
        const char* tname = lua_typename(L, type);
        const char* k1 = (nvals >= 2) ? lua_tostring(L, base + 2) : "(none)";
        XLOGD("thread_message_handler [id=%d]: base=%d nvals=%d base+1-type=%s base+1-isnil=%d base+2=%s",
              xthread_current_id(), (int)base, (int)nvals, tname, b1isnil, k1 ? k1 : "(null)");
    }
    if (nvals >= 2 && lua_isnil(L, base + 1)) {
        const char* k1 = lua_tostring(L, base + 2);
        if (k1 && strcmp(k1, "@async_resume") == 0) {
            XLOGI("C INTERCEPT: @async_resume on thread %d will resume coroutine", xthread_current_id());
            /* Got it - intercept this in C, do NOT pass to Lua handler */
            /* Layout: nil (reply_router), "@async_resume", co_id, sk, req_pt, ok, r, ...
            **   base+1 = nil               (reply_router = nil for REPLY)
            **   base+2 = "@async_resume"   (k1 = function name)
            **   base+3 = co_id             (k2 = coroutine id to resume)
            **   base+4 = sk                (k3 = unused)
            **   base+5 = req_pt            (unused)
            **   base+6 = ok                (RPC result status)
            **   base+7 += results          (result values)
            ** nresume = (ok + results) = nvals - 5
            */
            if (nvals < 6) {
                XLOGE("xthread: malformed @async_resume (nvals=%d)", nvals);
                lua_settop(L, base);
                return;
            }
            lua_Integer co_id = lua_tointeger(L, base + 3);
            int nresume = nvals - 5; /* ok + results */

            XLOGD("xthread: @async_resume looking up co_id=%lld in thread %d pending table", (long long)co_id, xthread_current_id());
            lua_State* co = pending_pop(L, co_id);
            if (!co) {
                XLOGE("xthread: @async_resume co_id=%lld not found", (long long)co_id);
                lua_settop(L, base);
                return;
            }

            /* Copy (ok, results...) to top of L's stack for xmove */
            for (int i = 0; i < nresume; i++) {
                lua_pushvalue(L, base + 6 + i);
            }

            lua_xmove(L, co, nresume);     /* move n values from top of L to co */
            lua_settop(L, base);           /* restore original stack height */

            int nresults = 0;
            int status = lua_resume(co, L, nresume, &nresults);
            if (status != LUA_OK && status != LUA_YIELD) {
                XLOGE("xthread: coroutine error: %s", lua_tostring(co, -1));
                lua_settop(co, 0);
            }
            return; /* INTERCEPTED - DONE! do NOT continue to Lua handler */
        }
    }

    /* Not @async_resume - go to normal Lua handler dispatch */
    /* ── Normal dispatch: call Lua handler ── */
    lua_getfield(L, LUA_REGISTRYINDEX, XTHREAD_HANDLER_KEY);
    if (!lua_isfunction(L, -1)) {
        XLOGE("xthread: no handler on thread %d (did you call xthread.init?)", id);
        lua_settop(L, base);
        return;
    }
    /* Move handler below all unpacked values */
    lua_insert(L, base + 1);
    /* Call: handler(reply_router, k1, k2, k3, ...) */
    if (lua_pcall(L, nvals, 0, 0) != LUA_OK) {
        XLOGE("xthread: handler error on thread %d: %s", id, lua_tostring(L, -1));
        lua_settop(L, base);
    }
}

/* ============================================================================
** Lua API
** ========================================================================== */

/* xthread.init([handler_func])
**
** Must be called once per thread (in on_init or at startup).
** Associates the current lua_State with the current xthread.
** Sets up:
**   • cmsgpack pack/unpack refs in registry
**   • pending RPC tracking table
**   • _thread_replys metatable for auto-creating reply closures
**   • message handler function
**
** handler_func: the Lua function called for incoming messages.
**   Defaults to __exports.__thread_handle__ if not provided. */
static int l_xthread_init(lua_State* L) {
    int id = xthread_current_id();
    if (id <= 0 || id >= XTHR_MAX)
        return luaL_error(L, "xthread.init: must be called from a registered xthread");

    _lua_states[id] = L;

    /* Load and cache cmsgpack.pack / cmsgpack.unpack */
    lua_getglobal(L, "require");
    lua_pushstring(L, "cmsgpack");
    if (lua_pcall(L, 1, 1, 0) != LUA_OK)
        return luaL_error(L, "xthread.init: cmsgpack required: %s", lua_tostring(L, -1));
    lua_getfield(L, -1, "pack");
    lua_setfield(L, LUA_REGISTRYINDEX, XTHREAD_PACK_KEY);
    lua_getfield(L, -1, "unpack");
    lua_setfield(L, LUA_REGISTRYINDEX, XTHREAD_UNPACK_KEY);
    lua_pop(L, 1); /* pop cmsgpack module */

    /* Store message handler */
    if (lua_isfunction(L, 1)) {
        lua_pushvalue(L, 1);
    } else {
        /* Default: __thread_handle__ (global) */
        lua_getglobal(L, "__thread_handle__");
        if (!lua_isfunction(L, -1)) {
            lua_pop(L, 1);
            /* Fallback: try __exports.__thread_handle__ */
            lua_getglobal(L, "__exports");
            if (lua_istable(L, -1)) {
                lua_getfield(L, -1, "__thread_handle__");
                lua_remove(L, -2); /* remove __exports */
            } else {
                lua_pop(L, 1);
                lua_pushnil(L);
            }
        }
    }
    if (!lua_isfunction(L, -1)) {
        lua_pop(L, 1);
        XLOGW("xthread.init: no handler set for thread %d – "
              "call xthread.init(handler) or ensure __thread_handle__ exists", id);
        lua_pushnil(L);
    }
    lua_setfield(L, LUA_REGISTRYINDEX, XTHREAD_HANDLER_KEY);

    /* Initialise pending-RPC table and co_id counter */
    lua_newtable(L);
    lua_setfield(L, LUA_REGISTRYINDEX, XTHREAD_PENDING_KEY);
    lua_pushinteger(L, 0);
    lua_setfield(L, LUA_REGISTRYINDEX, XTHREAD_COID_KEY);

    /* Set up _thread_replys with __index that auto-creates C reply closures
    ** for keys matching "xthread:<id>". */
    lua_getglobal(L, "_thread_replys");
    if (!lua_istable(L, -1)) {
        lua_pop(L, 1);
        lua_newtable(L);
        lua_pushvalue(L, -1);
        lua_setglobal(L, "_thread_replys");
    }
    lua_newtable(L); /* metatable */
    lua_pushcfunction(L, l_replys_index);
    lua_setfield(L, -2, "__index");
    lua_setmetatable(L, -2); /* setmetatable(_thread_replys, mt) */
    lua_pop(L, 1); /* pop _thread_replys */

    XLOGI("xthread.init: thread %d initialised", id);
    return 0;
}

/* xthread.post(target_id, pt, ...)
**
** Fire-and-forget: post a message to another thread.
** Wire format: pack(nil, pt, args...)
** Returns: true on success, or false + error_string on failure. */
static int l_xthread_post(lua_State* L) {
    int target_id = (int)luaL_checkinteger(L, 1);
    luaL_checkstring(L, 2); /* pt */
    int top = lua_gettop(L);

    /* Push pack args: nil, pt, arg1, ..., argN */
    lua_pushnil(L);
    for (int i = 2; i <= top; i++)
        lua_pushvalue(L, i);
    /* nargs = 1 (nil) + (top-1) (pt + rest) = top */
    ThreadMsg* msg = pack_to_msg(L, top);
    if (!msg) {
        lua_pushboolean(L, 0);
        lua_pushstring(L, "xthread.post: cmsgpack.pack failed");
        return 2;
    }

    if (!xthread_post(target_id, thread_message_handler, msg)) {
        free(msg);
        lua_pushboolean(L, 0);
        lua_pushfstring(L, "xthread.post: thread %d unavailable", target_id);
        return 2;
    }
    lua_pushboolean(L, 1);
    return 1;
}

/* xthread.rpc(target_id, pt, ...)   [must be called from a coroutine]
**
** Yields the calling coroutine; resumes with (ok, results...) when the
** target thread has executed the handler and replied.
**
** Wire format sent to target: pack(reply_router, co_id, 0, pt, args...)
**   reply_router = "xthread:<caller_id>"
**
** Errors: raises if not in a coroutine, or if the post fails.
*/
static int l_xthread_rpc(lua_State* L) {
    int target_id = (int)luaL_checkinteger(L, 1);
    luaL_checkstring(L, 2); /* pt */
    int top = lua_gettop(L);

    if (!lua_isyieldable(L))
        return luaL_error(L, "xthread.rpc: must be called from a coroutine");

    int caller_id = xthread_current_id();
    if (caller_id <= 0 || caller_id >= XTHR_MAX)
        return luaL_error(L, "xthread.rpc: calling thread not registered");

    lua_State* main_L = _lua_states[caller_id];
    if (!main_L)
        return luaL_error(L, "xthread.rpc: xthread.init() not called on this thread");

    /* Generate a unique co_id and store the coroutine */
    lua_Integer co_id = next_co_id(main_L);
    pending_put(main_L, co_id, L); /* L is the coroutine; main_L holds registry */

    /* Build reply_router: "xthread:<caller_id>" */
    char reply_router[32];
    snprintf(reply_router, sizeof(reply_router), "xthread:%d", caller_id);

    /* Push pack args: reply_router, co_id, 0 (sk), pt, arg1, ..., argN */
    lua_pushstring(L, reply_router);
    lua_pushinteger(L, co_id);
    lua_pushinteger(L, 0); /* sk = 0 (unused in xthread, kept for Lua compat) */
    for (int i = 2; i <= top; i++)
        lua_pushvalue(L, i); /* pt, args */
    /* nargs = 3 + (top-1) = top+2 */
    ThreadMsg* msg = pack_to_msg(L, top + 2);
    if (!msg) {
        pending_pop(main_L, co_id); /* roll back */
        return luaL_error(L, "xthread.rpc: cmsgpack.pack failed");
    }

    if (!xthread_post(target_id, thread_message_handler, msg)) {
        pending_pop(main_L, co_id); /* roll back */
        free(msg);
        return luaL_error(L, "xthread.rpc: thread %d unavailable", target_id);
    }

    /* Yield; thread_message_handler on caller thread will resume us */
    return lua_yield(L, 0);
}

/* xthread.current_id()  →  integer */
static int l_current_id(lua_State* L) {
    lua_pushinteger(L, xthread_current_id());
    return 1;
}

/* ============================================================================
** Module registration
** ========================================================================== */

static const luaL_Reg xthread_funcs[] = {
    { "init",       l_xthread_init },
    { "post",       l_xthread_post },
    { "rpc",        l_xthread_rpc  },
    { "current_id", l_current_id   },
    { NULL, NULL }
};

static const struct { const char* name; int val; } THREAD_CONSTS[] = {
    { "MAIN",        XTHR_MAIN        },
    { "REDIS",       XTHR_REDIS       },
    { "MYSQL",       XTHR_MYSQL       },
    { "LOG",         XTHR_LOG         },
    { "IO",          XTHR_IO          },
    { "COMPUTE",     XTHR_COMPUTE     },
    { "WORKER_GRP1", XTHR_WORKER_GRP1 },
    { "WORKER_GRP2", XTHR_WORKER_GRP2 },
    { "WORKER_GRP3", XTHR_WORKER_GRP3 },
    { "WORKER_GRP4", XTHR_WORKER_GRP4 },
    { "WORKER_GRP5", XTHR_WORKER_GRP5 },
    { NULL, 0 }
};

/* luaopen_xthread
**
** Compatible with luaL_requiref and require().
** NOTE: only builds the module table; call xthread.init() separately once
**       the thread and __exports are fully set up.
**
** Typical usage per thread:
**   luaL_requiref(L, "xthread", luaopen_xthread, 1); lua_pop(L, 1);
**   -- load thread_router.lua so __exports is available
**   xthread.init()   -- or xthread.init(my_handler) */
LUALIB_API int luaopen_xthread(lua_State* L) {
    luaL_newlib(L, xthread_funcs);

    for (int i = 0; THREAD_CONSTS[i].name; i++) {
        lua_pushinteger(L, THREAD_CONSTS[i].val);
        lua_setfield(L, -2, THREAD_CONSTS[i].name);
    }

    return 1; /* return module table */
}
