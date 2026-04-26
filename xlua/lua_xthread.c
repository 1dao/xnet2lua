/* lua_xthread.c - Lua bindings for xthread
**
** Message wire format (cmsgpack packed):
**
**   POST  ->  pack(nil,           pt, arg1, arg2, ...)
**   RPC   ->  pack(reply_router,  co_id, 0 (sk), pt, arg1, ...)
**   REPLY ->  pack(nil, "@async_resume", co_id, 0 (sk), req_pt, ok, r, ...)
**
** Lua handler convention (__thread_handle):
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

LUALIB_API int luaopen_cmsgpack(lua_State* L);
LUALIB_API int luaopen_xthread(lua_State* L);
LUALIB_API int luaopen_xnet(lua_State* L);

/* ============================================================================
** Registry keys (per lua_State)
** ========================================================================== */
#define XTHREAD_PACK_KEY    "xthread.pack"       /* cmsgpack.pack function    */
#define XTHREAD_UNPACK_KEY  "xthread.unpack"     /* cmsgpack.unpack function  */
#define XTHREAD_HANDLER_KEY "xthread.handler"    /* Lua message handler func  */
#define XTHREAD_PENDING_KEY "xthread.pending"    /* {[co_id] = coroutine}     */
#define XTHREAD_COID_KEY    "xthread.next_co_id" /* integer auto-increment    */

/* ============================================================================
** ThreadData - Stores per-thread Lua state and callback references
** ========================================================================== */
typedef struct {
    lua_State* L;                /* Thread's Lua state */
    lua_State* owner_L;          /* State that owns the ThreadData userdata */
    char* script_path;           /* path to script file (loaded by new thread) */
    int sync_handler_ref;        /* sync message handler reference (in registry) */
    int init_ref;                /* lifecycle: init callback reference */
    int update_ref;              /* lifecycle: update callback reference */
    int uninit_ref;              /* lifecycle: uninit callback reference */
    int sentinel_ref;            /* GC protection reference (keeps ThreadData alive) */
} ThreadData;

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
static int thread_data_gc(lua_State* L);

/* ThreadData metatable name */
static const char* THREAD_DATA_META = "xthread.ThreadData";

/* ============================================================================
** pack_to_msg
** Pack Lua stack values into a ThreadMsg using cmsgpack
** ========================================================================== */
static ThreadMsg* pack_to_msg(lua_State* L, int nargs) {
    /* Call cmsgpack.pack(...) */
    lua_getfield(L, LUA_REGISTRYINDEX, XTHREAD_PACK_KEY);
    if (!lua_isfunction(L, -1)) {
        XLOGE("xthread: pack function not found (did you call xthread.init?)");
        return NULL;
    }
    lua_insert(L, lua_gettop(L) - nargs); /* move function before args */
    if (lua_pcall(L, nargs, 1, 0) != LUA_OK) {
        XLOGE("xthread: pack failed: %s", lua_tostring(L, -1));
        return NULL;
    }
    /* Result is a string on top */
    if (!lua_isstring(L, -1)) {
        XLOGE("xthread: pack did not return a string");
        lua_pop(L, 1);
        return NULL;
    }
    size_t len;
    const char* data = lua_tolstring(L, -1, &len);
    ThreadMsg* msg = msg_alloc(data, len);
    lua_pop(L, 1);
    return msg;
}

/* ============================================================================
** unpack_msg
** Unpack ThreadMsg into Lua stack, returns number of values or -1 on error
** ========================================================================== */
static int unpack_msg(lua_State* L, ThreadMsg* msg) {
    int base = lua_gettop(L);
    /* Call cmsgpack.unpack(buf) */
    lua_getfield(L, LUA_REGISTRYINDEX, XTHREAD_UNPACK_KEY);
    if (!lua_isfunction(L, -1)) {
        XLOGE("xthread: unpack function not found (did you call xthread.init?)");
        lua_settop(L, base);
        return -1;
    }
    lua_pushlstring(L, msg->data, msg->len);
    if (lua_pcall(L, 1, LUA_MULTRET, 0) != LUA_OK) {
        XLOGE("xthread: unpack failed: %s", lua_tostring(L, -1));
        lua_settop(L, base);
        return -1;
    }
    return lua_gettop(L) - base;
}

/* ============================================================================
** next_co_id - Atomically increment the coroutine ID counter
** ========================================================================== */
static lua_Integer next_co_id(lua_State* L) {
    lua_getfield(L, LUA_REGISTRYINDEX, XTHREAD_COID_KEY);
    lua_Integer id = lua_tointeger(L, -1);
    lua_pop(L, 1);
    lua_pushinteger(L, id + 1);
    lua_setfield(L, LUA_REGISTRYINDEX, XTHREAD_COID_KEY);
    return id;
}

/* ============================================================================
** pending_put / pending_pop - Track waiting RPC coroutines
** ========================================================================== */
static bool pending_put(lua_State* L, lua_Integer co_id, lua_State* co) {
    lua_getfield(L, LUA_REGISTRYINDEX, XTHREAD_PENDING_KEY);
    if (!lua_istable(L, -1)) {
        lua_pop(L, 1);
        return false;
    }
    lua_pushinteger(L, co_id);
    lua_pushthread(co);
    lua_xmove(co, L, 1);
    lua_settable(L, -3);
    lua_pop(L, 1);
    return true;
}

static lua_State* pending_pop(lua_State* L, lua_Integer co_id, bool keep_ref) {
    lua_getfield(L, LUA_REGISTRYINDEX, XTHREAD_PENDING_KEY);
    if (!lua_istable(L, -1)) {
        lua_pop(L, 1);
        return NULL;
    }
    lua_pushinteger(L, co_id);
    lua_gettable(L, -2);
    lua_State* co = lua_tothread(L, -1);
    if (co) {
        /* Remove from pending table */
        lua_pushinteger(L, co_id);
        lua_pushnil(L);
        lua_settable(L, -4);

        if (keep_ref) {
            lua_remove(L, -2); /* remove pending table; keep coroutine on stack */
        } else {
            lua_pop(L, 2);     /* pop coroutine and pending table */
        }
    } else {
        lua_pop(L, 2);         /* pop nil and pending table */
    }
    return co;
}

/* ============================================================================
** l_replys_index - Metatable __index for _thread_replys
** Auto-creates reply closures for keys "xthread:<id>"
** ============================================================================ */
static int l_reply_func(lua_State* L) {
    /* Closure created with upvalue 1 = target_id (integer) */
    int target_id = luaL_checkinteger(L, lua_upvalueindex(1));
    /* reply(co_id, sk, pt, ok, ...) */
    int nargs = lua_gettop(L);
    /* Need at least: reply(co_id) */
    if (nargs < 1) {
        luaL_error(L, "reply: too few arguments");
        return 0;
    }

    /* Pack: nil, "@async_resume", co_id, sk, pt, ok, ... */
    lua_pushstring(L, "@async_resume");
    lua_insert(L, 1);
    lua_pushnil(L);                    /* reply_router = nil */
    lua_insert(L, 1);
    /* co_id, sk, pt, ok... are already on stack after that */

    ThreadMsg* msg = pack_to_msg(L, nargs + 2); /* +2 for nil + "@async_resume" */
    if (!msg) {
        XLOGE("xthread.reply: failed to pack message");
        lua_settop(L, 0);
        lua_pushboolean(L, 0);
        return 1;
    }

    bool ok = xthread_post(target_id, thread_message_handler, msg);
    if (!ok) {
        XLOGE("xthread.reply: failed to post to thread %d", target_id);
        free(msg);
    }
    lua_pushboolean(L, ok);
    return 1;
}

static int l_replys_index(lua_State* L) {
    /* _thread_replys, "xthread:<id>" */
    const char* key = luaL_checkstring(L, 2);
    if (strncmp(key, "xthread:", 8) != 0) {
        lua_pushnil(L);
        return 1;
    }
    int id = atoi(key + 8);
    if (id <= 0) {
        lua_pushnil(L);
        return 1;
    }
    /* Create C closure that captures id */
    lua_pushinteger(L, id);
    lua_pushcclosure(L, l_reply_func, 1);
    /* Store it in _thread_replys so it's cached */
    lua_pushvalue(L, 2);  /* original "xthread:<id>" key */
    lua_pushvalue(L, -2); /* closure */
    lua_settable(L, 1); /* _thread_replys[key] = closure */
    return 1;
}

/* ============================================================================
** thread_data_gc - GC garbage collection for ThreadData
** ========================================================================== */
static void thread_data_unref_callbacks(ThreadData* td, lua_State* L) {
    if (!td || !L) {
        return;
    }

    if (td->sync_handler_ref != LUA_NOREF) {
        luaL_unref(L, LUA_REGISTRYINDEX, td->sync_handler_ref);
        td->sync_handler_ref = LUA_NOREF;
    }
    if (td->init_ref != LUA_NOREF) {
        luaL_unref(L, LUA_REGISTRYINDEX, td->init_ref);
        td->init_ref = LUA_NOREF;
    }
    if (td->update_ref != LUA_NOREF) {
        luaL_unref(L, LUA_REGISTRYINDEX, td->update_ref);
        td->update_ref = LUA_NOREF;
    }
    if (td->uninit_ref != LUA_NOREF) {
        luaL_unref(L, LUA_REGISTRYINDEX, td->uninit_ref);
        td->uninit_ref = LUA_NOREF;
    }
}

static int thread_data_gc(lua_State* L) {
    ThreadData* td = (ThreadData*)luaL_checkudata(L, 1, THREAD_DATA_META);
    if (!td) return 0;

    XLOGD("thread_data_gc: reclaiming ThreadData for thread");

    /* Free script path copy */
    if (td->script_path) {
        free(td->script_path);
        td->script_path = NULL;
    }

    if (td->L == L) {
        thread_data_unref_callbacks(td, L);
    }

    if (td->owner_L == L && td->sentinel_ref != LUA_NOREF) {
        luaL_unref(L, LUA_REGISTRYINDEX, td->sentinel_ref);
        td->sentinel_ref = LUA_NOREF;
    }

    td->L = NULL;
    td->owner_L = NULL;
    return 0;
}

/* ============================================================================
** thread_message_handler - Entry point for all cross-thread messages
**
** Unpacks the message and either:
**   a) Intercepts "@async_resume" → resumes the waiting coroutine directly
**   b) Dispatches to the registered Lua handler
** ============================================================================ */
static void thread_message_handler(xThread* thr, void* arg) {
    ThreadMsg* msg = (ThreadMsg*)arg;
    ThreadData* td = (ThreadData*)xthread_get_userdata(thr);

    if (!td || !td->L) {
        XLOGE("xthread: no lua state for thread %d", xthread_get_id(thr));
        free(msg);
        return;
    }

    lua_State* L = td->L;
    int id = xthread_get_id(thr);
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
            lua_State* co = pending_pop(L, co_id, true);
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

            int nresults = 0;
            int status = lua_resume(co, L, nresume, &nresults);
            if (status != LUA_OK && status != LUA_YIELD) {
                XLOGE("xthread: coroutine error: %s", lua_tostring(co, -1));
                lua_settop(co, 0);
            }
            lua_settop(L, base);           /* restore original stack height */
            return; /* INTERCEPTED - DONE! do NOT continue to Lua handler */
        }
    }

    /* Not @async_resume - go to normal Lua handler dispatch */
    /* ── Normal dispatch: call Lua handler ── */
    if (td->sync_handler_ref != LUA_NOREF) {
        lua_rawgeti(L, LUA_REGISTRYINDEX, td->sync_handler_ref);
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
    } else {
        XLOGE("xthread: no handler on thread %d (did you call xthread.init(handler)?)", id);
        lua_settop(L, base);
    }
}

/* ============================================================================
** Lua API - Original core API (preserved for compatibility)
** ============================================================================ */

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
**   Defaults to __thread_handle if not provided. */
static int l_xthread_init(lua_State* L) {
    xThread* thr = xthread_current();
    if (!thr)
        return luaL_error(L, "xthread.init: must be called from a registered xthread");

    /* Get or create ThreadData for this thread */
    ThreadData* td = (ThreadData*)xthread_get_userdata(thr);
    if (!td) {
        /* Create new ThreadData userdata */
        td = (ThreadData*)lua_newuserdata(L, sizeof(ThreadData));
        td->L = L;
        td->owner_L = L;
        td->script_path = NULL;
        td->sync_handler_ref = LUA_NOREF;
        td->init_ref = LUA_NOREF;
        td->update_ref = LUA_NOREF;
        td->uninit_ref = LUA_NOREF;
        td->sentinel_ref = LUA_NOREF;

        /* Get or create metatable */
        luaL_getmetatable(L, THREAD_DATA_META);
        if (lua_isnil(L, -1)) {
            lua_pop(L, 1);
            luaL_newmetatable(L, THREAD_DATA_META);
            lua_pushcfunction(L, thread_data_gc);
            lua_setfield(L, -2, "__gc");
            /* Set metatable */
        }
        lua_setmetatable(L, -2);
        /* Store reference to self in registry to prevent GC */
        td->sentinel_ref = luaL_ref(L, LUA_REGISTRYINDEX);

        /* Attach to xthread */
        xthread_set_userdata(thr, td);
    }

    td->L = L;

    /* Load and cache cmsgpack.pack / cmsgpack.unpack in registry */
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
        /* Default: __thread_handle (global) */
        lua_getglobal(L, "__thread_handle");
        if (!lua_isfunction(L, -1)) {
            lua_pop(L, 1);
            /* Fallback: try __exports.__thread_handle */
            lua_getglobal(L, "__exports");
            if (lua_istable(L, -1)) {
                lua_getfield(L, -1, "__thread_handle");
                lua_remove(L, -2); /* remove __exports */
            } else {
                lua_pop(L, 1);
                lua_pushnil(L);
            }
        }
    }
    if (lua_isfunction(L, -1)) {
        if (td->sync_handler_ref != LUA_NOREF) {
            luaL_unref(L, LUA_REGISTRYINDEX, td->sync_handler_ref);
        }
        td->sync_handler_ref = luaL_ref(L, LUA_REGISTRYINDEX);
    } else {
        lua_pop(L, 1);
        XLOGW("xthread.init: no handler set for thread %d – "
              "call xthread.init(handler) or ensure __thread_handle exists", xthread_get_id(thr));
    }

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

    XLOGI("xthread.init: thread %d initialised", xthread_get_id(thr));
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
    if (caller_id <= 0)
        return luaL_error(L, "xthread.rpc: calling thread not registered");

    xThread* caller_thr = xthread_current();
    ThreadData* caller_td = (ThreadData*)xthread_get_userdata(caller_thr);
    if (!caller_td || !caller_td->L)
        return luaL_error(L, "xthread.rpc: xthread.init() not called on this thread");

    lua_State* main_L = caller_td->L;

    /* Generate a unique co_id and store the coroutine */
    lua_Integer co_id = next_co_id(main_L);
    if (!pending_put(main_L, co_id, L)) { /* L is the coroutine; main_L holds registry */
        return luaL_error(L, "xthread.rpc: pending table not initialized");
    }

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
        pending_pop(main_L, co_id, false); /* roll back */
        return luaL_error(L, "xthread.rpc: cmsgpack.pack failed");
    }

    if (!xthread_post(target_id, thread_message_handler, msg)) {
        pending_pop(main_L, co_id, false); /* roll back */
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
** New API - Dynamic thread creation from Lua
** ============================================================================ */

/* Lifecycle callbacks that bridge from C xthread to Lua
** This runs in the new thread's context after the OS thread has started
*/
static void lua_thread_on_init(xThread* thr) {
    ThreadData* td = (ThreadData*)xthread_get_userdata(thr);
    if (!td) {
        XLOGE("lua_thread_on_init: no ThreadData for thread %d", xthread_get_id(thr));
        return;
    }

    /* Create NEW Lua state for this thread */
    lua_State* L = luaL_newstate();
    if (!L) {
        XLOGE("lua_thread_on_init: failed to create Lua state for thread %d", xthread_get_id(thr));
        return;
    }
    td->L = L;

    /* Open standard libraries */
    luaL_openlibs(L);

    /* Preload cmsgpack (statically linked) */
    luaL_requiref(L, "cmsgpack", luaopen_cmsgpack, 1);
    lua_pop(L, 1);

    /* Open xthread module */
    luaL_requiref(L, "xthread", luaopen_xthread, 1);
    lua_pop(L, 1);

    /* Open xnet module so dynamic Lua threads can use network polling too. */
    luaL_requiref(L, "xnet", luaopen_xnet, 1);
    lua_pop(L, 1);

    /* Load the script in THIS THREAD'S own Lua state
    ** Script returns the definition table with callbacks */
    XLOGI("lua_thread_on_init: loading script '%s' for thread %d", td->script_path, xthread_get_id(thr));
    if (luaL_dofile(L, td->script_path) != LUA_OK) {
        XLOGE("lua_thread_on_init: failed to load script '%s': %s",
              td->script_path, lua_tostring(L, -1));
        lua_close(L);
        td->L = NULL;
        return;
    }

    /* Script should return the definition table */
    if (!lua_istable(L, -1)) {
        XLOGE("lua_thread_on_init: script '%s' did not return a definition table", td->script_path);
        lua_close(L);
        td->L = NULL;
        return;
    }

    /* Extract callbacks from returned table and store as references */
    lua_getfield(L, -1, "__thread_handle");
    if (lua_isfunction(L, -1)) {
        td->sync_handler_ref = luaL_ref(L, LUA_REGISTRYINDEX);
    } else {
        lua_pop(L, 1);
        XLOGW("lua_thread_on_init: no __thread_handle in script '%s'", td->script_path);
        td->sync_handler_ref = LUA_NOREF;
    }

    lua_getfield(L, -1, "__init");
    if (lua_isfunction(L, -1)) {
        td->init_ref = luaL_ref(L, LUA_REGISTRYINDEX);
    } else {
        lua_pop(L, 1);
        td->init_ref = LUA_NOREF;
    }

    lua_getfield(L, -1, "__update");
    if (lua_isfunction(L, -1)) {
        td->update_ref = luaL_ref(L, LUA_REGISTRYINDEX);
    } else {
        lua_pop(L, 1);
        td->update_ref = LUA_NOREF;
    }

    lua_getfield(L, -1, "__uninit");
    if (lua_isfunction(L, -1)) {
        td->uninit_ref = luaL_ref(L, LUA_REGISTRYINDEX);
    } else {
        lua_pop(L, 1);
        td->uninit_ref = LUA_NOREF;
    }

    /* Pop the definition table from stack */
    lua_pop(L, 1);

    /* Initialize xthread for this thread */
    int base = lua_gettop(L);
    lua_getglobal(L, "xthread");
    lua_getfield(L, -1, "init");
    lua_remove(L, -2); /* remove xthread table, keep init function */
    int nargs = 0;
    if (td->sync_handler_ref != LUA_NOREF) {
        lua_rawgeti(L, LUA_REGISTRYINDEX, td->sync_handler_ref);
        nargs = 1;
    }
    if (lua_pcall(L, nargs, 0, 0) != LUA_OK) {
        XLOGE("lua_thread_on_init: xthread.init failed: %s", lua_tostring(L, -1));
        lua_settop(L, base);
    }

    /* Call user's __init callback if provided */
    if (td->init_ref != LUA_NOREF) {
        base = lua_gettop(L);
        lua_rawgeti(L, LUA_REGISTRYINDEX, td->init_ref);
        if (lua_pcall(L, 0, 0, 0) != LUA_OK) {
            XLOGE("lua_thread_on_init: user init callback error: %s", lua_tostring(L, -1));
            lua_settop(L, base);
        }
    }

    XLOGI("lua_thread_on_init: thread %d fully initialized", xthread_get_id(thr));
}

static void lua_thread_on_update(xThread* thr) {
    ThreadData* td = (ThreadData*)xthread_get_userdata(thr);
    if (!td || td->update_ref == LUA_NOREF || !td->L) {
        return;
    }

    lua_State* L = td->L;
    int base = lua_gettop(L);

    lua_rawgeti(L, LUA_REGISTRYINDEX, td->update_ref);
    if (lua_pcall(L, 0, 0, 0) != LUA_OK) {
        XLOGE("lua_thread_on_update: thread %d error: %s", xthread_get_id(thr), lua_tostring(L, -1));
        lua_settop(L, base);
    }
}

static void lua_thread_on_cleanup(xThread* thr) {
    ThreadData* td = (ThreadData*)xthread_get_userdata(thr);
    if (!td) {
        return;
    }

    if (td->uninit_ref != LUA_NOREF && td->L) {
        lua_State* L = td->L;
        int base = lua_gettop(L);

        lua_rawgeti(L, LUA_REGISTRYINDEX, td->uninit_ref);
        if (lua_pcall(L, 0, 0, 0) != LUA_OK) {
            XLOGE("lua_thread_on_cleanup: thread %d error: %s", xthread_get_id(thr), lua_tostring(L, -1));
            lua_settop(L, base);
        }
    }

    if (td->L) {
        lua_State* L = td->L;
        thread_data_unref_callbacks(td, L);
        td->L = NULL;
        lua_close(L);
    }

    /* xthread will unregister, clear the userdata reference */
    xthread_set_userdata(thr, NULL);
    XLOGI("lua_thread_on_cleanup: thread %d cleaned up", xthread_get_id(thr));
}

/* xthread.create_thread(id, name, script_path) → boolean
**
** id: integer - thread ID
** name: string - thread name
** script_path: string - path to Lua script that defines the thread
**   The script should return a table with:
**     {
**       __init = function() end,              -- optional: called after Lua init
**       __update = function() end,            -- optional: called each update
**       __uninit = function() end,            -- optional: called before exit
**       __thread_handle = function -- required: message handler
**     }
**
** Creates a new OS thread with its own independent Lua state.
** The new thread will:
**   1. Create new Lua state
**   2. Load standard libraries
**   3. Preload cmsgpack and xthread modules
**   4. Load and execute the script - script returns definition table
**   5. Extract callbacks from definition table
**   6. Call xthread.init with sync handler
**   7. Call __init callback
**   8. Run xthread_update loop calling __update each iteration
**   9. On shutdown: call __uninit then exit
*/
static int l_xthread_create_thread(lua_State* L) {
    int id = luaL_checkinteger(L, 1);
    const char* name = luaL_checkstring(L, 2);
    const char* script_path = luaL_checkstring(L, 3);

    /* Check if thread already exists */
    if (xthread_get(id) != NULL) {
        lua_pushboolean(L, 0);
        lua_pushfstring(L, "xthread.create_thread: thread %d already exists", id);
        return 2;
    }

    /* Create ThreadData that will hold all references */
    ThreadData* td = (ThreadData*)lua_newuserdata(L, sizeof(ThreadData));
    td->L = NULL;
    td->owner_L = L;
    td->script_path = NULL;
    td->sync_handler_ref = LUA_NOREF;
    td->init_ref = LUA_NOREF;
    td->update_ref = LUA_NOREF;
    td->uninit_ref = LUA_NOREF;
    td->sentinel_ref = LUA_NOREF;

    /* Get metatable and set GC */
    luaL_getmetatable(L, THREAD_DATA_META);
    if (lua_isnil(L, -1)) {
        lua_pop(L, 1);
        luaL_newmetatable(L, THREAD_DATA_META);
        lua_pushcfunction(L, thread_data_gc);
        lua_setfield(L, -2, "__gc");
    }
    lua_setmetatable(L, -2);

    /* Store script path copy - the new thread will load it in its own Lua state */
    td->script_path = malloc(strlen(script_path) + 1);
    if (!td->script_path) {
        XLOGE("xthread.create_thread: out of memory copying script path");
        lua_pushboolean(L, 0);
        lua_pushstring(L, "xthread.create_thread: out of memory");
        return 2;
    }
    strcpy((char*)td->script_path, script_path);

    /* Store reference in registry to prevent GC while thread is running */
    td->sentinel_ref = luaL_ref(L, LUA_REGISTRYINDEX);

    /* Register with xthread - this creates the OS thread */
    /* Attach ThreadData immediately after creation */
    /* The new thread will get it from xthread_get_userdata in lua_thread_on_init */
    bool ok = xthread_register_ex(id, name,
                                lua_thread_on_init,
                                lua_thread_on_update,
                                lua_thread_on_cleanup
                                , td);
    if (!ok) {
        XLOGE("xthread.create_thread: failed to register thread %d", id);
        /* Clean up references */
        if (td->sync_handler_ref != LUA_NOREF)
            luaL_unref(L, LUA_REGISTRYINDEX, td->sync_handler_ref);
        if (td->init_ref != LUA_NOREF)
            luaL_unref(L, LUA_REGISTRYINDEX, td->init_ref);
        if (td->update_ref != LUA_NOREF)
            luaL_unref(L, LUA_REGISTRYINDEX, td->update_ref);
        if (td->uninit_ref != LUA_NOREF)
            luaL_unref(L, LUA_REGISTRYINDEX, td->uninit_ref);
        if (td->sentinel_ref != LUA_NOREF) {
            luaL_unref(L, LUA_REGISTRYINDEX, td->sentinel_ref);
            td->sentinel_ref = LUA_NOREF;
        }
        lua_pushboolean(L, 0);
        lua_pushstring(L, "xthread.create_thread: xthread_register failed");
        return 2;
    }

    /* Get the xThread pointer and attach ThreadData */
    xThread* thr = xthread_get(id);
    if (!thr) {
        XLOGE("xthread.create_thread: xthread_get failed after registration");
        lua_pushboolean(L, 0);
        lua_pushstring(L, "xthread.create_thread: xthread_get failed");
        return 2;
    }

    XLOGI("xthread.create_thread: created thread %d '%s'", id, name);
    lua_pushboolean(L, 1);
    return 1;
}

/* xthread.shutdown_thread(id) → boolean
**
** Unregister and shut down a dynamically created thread.
** This will trigger the cleanup process: call __uninit and exit the thread.
*/
static int l_xthread_shutdown_thread(lua_State* L) {
    int id = luaL_checkinteger(L, 1);
    xThread* thr = xthread_get(id);
    if (!thr) {
        lua_pushboolean(L, 0);
        lua_pushfstring(L, "xthread.shutdown_thread: thread %d not found", id);
        return 2;
    }

    ThreadData* td = (ThreadData*)xthread_get_userdata(thr);
    xthread_unregister(id);
    if (td && td->owner_L == L && td->sentinel_ref != LUA_NOREF) {
        luaL_unref(L, LUA_REGISTRYINDEX, td->sentinel_ref);
        td->sentinel_ref = LUA_NOREF;
    }
    XLOGI("xthread.shutdown_thread: unregistered thread %d", id);
    lua_pushboolean(L, 1);
    return 1;
}

/* ============================================================================
** Module registration
** ========================================================================== */

static const luaL_Reg xthread_funcs[] = {
    { "init",             l_xthread_init },
    { "post",             l_xthread_post },
    { "rpc",              l_xthread_rpc  },
    { "current_id",       l_current_id   },
    { "create_thread",    l_xthread_create_thread },
    { "shutdown_thread",  l_xthread_shutdown_thread },
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
    /* Create ThreadData metatable on first load */
    luaL_newmetatable(L, THREAD_DATA_META);
    lua_pushcfunction(L, thread_data_gc);
    lua_setfield(L, -2, "__gc");
    lua_pop(L, 1);

    luaL_newlib(L, xthread_funcs);

    for (int i = 0; THREAD_CONSTS[i].name; i++) {
        lua_pushinteger(L, THREAD_CONSTS[i].val);
        lua_setfield(L, -2, THREAD_CONSTS[i].name);
    }

    return 1; /* return module table */
}
