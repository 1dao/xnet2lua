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
**   xthread.rpc(target, pt, timeout_ms, ...)
**     -> Lua wrapper calls C rpc(..., timeout_ms, ...)
**     -> pack + xthread_post(target, thread_message_handler)
**     -> coroutine.yield() in Lua              [coroutine suspends]
**   target thread: handler runs -> calls reply(co_id, ...)
**   reply (C closure): packs @async_resume, xthread_post(caller, ...)
**   caller thread: @async_resume detected -> pending_pop(co_id) -> lua_resume
*/

#include <stdlib.h>
#include <string.h>
#include <stdio.h>
#include <limits.h>
#include <stddef.h>
#include "xpoll.h"

/* Use embedded minilua when building with xlua_test */
#if defined(LUA_EMBEDDED)
#include "../3rd/minilua.h"
#else
#include "lua.h"
#include "lauxlib.h"
#include "lualib.h"
#if defined(XLUA_USE_LUAJIT)
#include "luajit.h"
#endif
#endif

#include "xthread.h"
#include "xlog.h"
#include "xtimer.h"      /* transitively pulls xmacro.h via xheapmin.h */
#include "lua_xdebug.h"

#include "../xmacro.h"   /* explicit, in case header chain changes */

#if defined(_MSC_VER)
#define XLUA_TLS __declspec(thread)
#elif defined(__STDC_VERSION__) && __STDC_VERSION__ >= 201112L
#define XLUA_TLS _Thread_local
#else
#define XLUA_TLS __thread
#endif

static XLUA_TLS int _log_local = 0;

#if defined(LUA_VERSION_NUM) && LUA_VERSION_NUM < 502
static void luaL_requiref(lua_State* L, const char* modname,
                          lua_CFunction openf, int glb) {
    lua_pushcfunction(L, openf);
    lua_pushstring(L, modname);
    lua_call(L, 1, 1);

    lua_getfield(L, LUA_REGISTRYINDEX, "_LOADED");
    if (!lua_istable(L, -1)) {
        lua_pop(L, 1);
        lua_newtable(L);
        lua_pushvalue(L, -1);
        lua_setfield(L, LUA_REGISTRYINDEX, "_LOADED");
    }
    lua_pushvalue(L, -2);
    lua_setfield(L, -2, modname);
    lua_pop(L, 1);

    if (glb) {
        lua_pushvalue(L, -1);
        lua_setglobal(L, modname);
    }
}
#endif

LUALIB_API int luaopen_cmsgpack(lua_State* L);
LUALIB_API int luaopen_xthread(lua_State* L);
LUALIB_API int luaopen_xnet(lua_State* L);
LUALIB_API int luaopen_xutils(lua_State* L);
LUALIB_API int luaopen_xtimer(lua_State* L);
LUALIB_API int luaopen_xcompress(lua_State* L);

/* ============================================================================
** Registry keys (per lua_State)
** ========================================================================== */
#define XTHREAD_PACK_KEY    "xthread.pack"       /* cmsgpack.pack function    */
#define XTHREAD_UNPACK_KEY  "xthread.unpack"     /* cmsgpack.unpack function  */
#define XTHREAD_HANDLER_KEY "xthread.handler"    /* Lua message handler func  */
#define XTHREAD_PENDING_KEY "xthread.pending"    /* {[co_id] = coroutine}     */
#define XTHREAD_COID_KEY    "xthread.next_co_id" /* integer auto-increment    */
#ifndef LUA_OK
#define LUA_OK 0
#endif
#ifndef lua_absindex
#define lua_absindex(L, i) \
    (((i) > 0 || (i) <= LUA_REGISTRYINDEX) ? (i) : lua_gettop(L) + (i) + 1)
#endif

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
    int auto_xpoll;       /* runner brought up xpoll on the script's behalf */
} ThreadData;

/* Forward declaration */
static void thread_message_handler(xThread* thr, void* arg, int arg_len);
static int thread_data_gc(lua_State* L);
static int l_xnet_thread_reload(lua_State* L);

static void lua_thread_runtime_post_init(lua_State* L) {
#if defined(XLUA_USE_LUAJIT)
    if (L) luaJIT_setmode(L, 0, LUAJIT_MODE_ENGINE | LUAJIT_MODE_ON);
#else
    (void)L;
#endif
}

static int lua_traceback_handler(lua_State* L) {
    const char* msg = lua_tostring(L, 1);
    if (msg) {
        luaL_traceback(L, L, msg, 1);
    } else if (!lua_isnoneornil(L, 1)) {
        if (!luaL_callmeta(L, 1, "__tostring")) {
            lua_pushliteral(L, "(error object is not a string)");
        }
    } else {
        lua_pushliteral(L, "(no error message)");
    }
    return 1;
}

/* ThreadData metatable name */
static const char* THREAD_DATA_META = "xthread.ThreadData";

/* Push the shared ThreadData metatable, creating it (with its __gc) on first
** use, and leave it on top of the stack. */
static void thread_data_push_meta(lua_State* L) {
    if (luaL_newmetatable(L, THREAD_DATA_META)) {
        lua_pushcfunction(L, thread_data_gc);
        lua_setfield(L, -2, "__gc");
    }
}

/* Allocate and field-initialise a ThreadData userdata, attach the shared
** metatable, and leave the userdata on the Lua stack. bound_L is the state the
** data is tied to: the creating state (xthread.init) or NULL for a thread that
** has not yet created its own Lua state (xthread.create_thread). */
static ThreadData* thread_data_alloc(lua_State* L, lua_State* bound_L) {
    ThreadData* td = (ThreadData*)lua_newuserdata(L, sizeof(ThreadData));
    td->L = bound_L;
    td->owner_L = L;
    td->script_path = NULL;
    td->sync_handler_ref = LUA_NOREF;
    td->init_ref = LUA_NOREF;
    td->update_ref = LUA_NOREF;
    td->uninit_ref = LUA_NOREF;
    td->sentinel_ref = LUA_NOREF;
    td->auto_xpoll = 0;
    thread_data_push_meta(L);
    lua_setmetatable(L, -2);
    return td;
}

/* ============================================================================
** pack_to_lua_stack
** Pack Lua stack values with cmsgpack, leaving the result string on stack.
** Returns the packed byte length, or -1 on failure.
** Successful: stack top = Lua string (data, len via lua_tolstring).
** Failed:     stack unchanged.
** ========================================================================== */
static lua_Integer pack_to_lua_stack(lua_State* L, int nargs) {
    /* Call cmsgpack.pack(...) */
    lua_getfield(L, LUA_REGISTRYINDEX, XTHREAD_PACK_KEY);
    if (!lua_isfunction(L, -1)) {
        xloge("xthread: pack function not found (did you call xthread.init?)");
        return -1;
    }
    lua_insert(L, lua_gettop(L) - nargs); /* move function before args */
    if (lua_pcall(L, nargs, 1, 0) != LUA_OK) {
        xloge("xthread: pack failed: %s", lua_tostring(L, -1));
        return -1;
    }
    /* Result is a string on top */
    if (!lua_isstring(L, -1)) {
        xloge("xthread: pack did not return a string");
        lua_pop(L, 1);
        return -1;
    }
    size_t len;
    lua_tolstring(L, -1, &len);  /* just to get length; string stays on stack */
    return (lua_Integer)len;
}

/* ============================================================================
** unpack_raw
** Unpack raw bytes into Lua stack, returns number of values or -1 on error.
** ========================================================================== */
static int unpack_raw(lua_State* L, const char* data, size_t len) {
    int base = lua_gettop(L);
    /* Call cmsgpack.unpack(buf) */
    lua_getfield(L, LUA_REGISTRYINDEX, XTHREAD_UNPACK_KEY);
    if (!lua_isfunction(L, -1)) {
        xloge("xthread: unpack function not found (did you call xthread.init?)");
        lua_settop(L, base);
        return -1;
    }
    lua_pushlstring(L, data, len);
    if (lua_pcall(L, 1, LUA_MULTRET, 0) != LUA_OK) {
        xloge("xthread: unpack failed: %s", lua_tostring(L, -1));
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

static int xthread_resume_coroutine(lua_State* co, lua_State* from,
                                    int nargs, int* nresults) {
#if defined(LUAJIT_VERSION_NUM) || (defined(LUA_VERSION_NUM) && LUA_VERSION_NUM < 502)
    (void)from;
    int base = lua_gettop(co) - nargs;
    int status = lua_resume(co, nargs);
    if (nresults) {
        if (status == LUA_OK || status == LUA_YIELD)
            *nresults = lua_gettop(co) - base;
        else
            *nresults = 0;
    }
    return status;
#else
    return lua_resume(co, from, nargs, nresults);
#endif
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

    lua_Integer pkt_len = pack_to_lua_stack(L, nargs + 2); /* +2 for nil + "@async_resume" */
    if (pkt_len < 0) {
        xloge("xthread.reply: failed to pack message");
        lua_settop(L, 0);
        lua_pushboolean(L, 0);
        return 1;
    }

    {
        size_t tmp;
        const char* pkt_data = lua_tolstring(L, -1, &tmp);
        /* Reply MUST be delivered: bypass backpressure and pool load-balancing. */
        int err = xthread_post_reply(target_id, thread_message_handler,
                                     pkt_data, (size_t)pkt_len);
        lua_pop(L, 1);  /* pop packed string */
        if (err != 0) {
            xloge("xthread.reply: failed to post to thread %d (err=%d)", target_id, err);
        }
        lua_pushboolean(L, err == 0);
    }
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

static int ref_field_if_function(lua_State* L, int table_idx, const char* field) {
    table_idx = lua_absindex(L, table_idx);
    lua_getfield(L, table_idx, field);
    if (lua_isfunction(L, -1)) {
        return luaL_ref(L, LUA_REGISTRYINDEX);
    }
    lua_pop(L, 1);
    return LUA_NOREF;
}

static void thread_data_apply_callbacks(ThreadData* td, lua_State* L,
                                        int sync_ref, int init_ref,
                                        int update_ref, int uninit_ref) {
    thread_data_unref_callbacks(td, L);
    td->sync_handler_ref = sync_ref;
    td->init_ref = init_ref;
    td->update_ref = update_ref;
    td->uninit_ref = uninit_ref;
}

static int lua_thread_reload_current(lua_State* L) {
    xThread* thr = xthread_current();
    if (!thr) {
        lua_pushboolean(L, 0);
        lua_pushstring(L, "xnet.__reload: current thread is not registered");
        return 2;
    }

    ThreadData* td = (ThreadData*)xthread_get_userdata(thr);
    if (!td || !td->L || !td->script_path || !td->script_path[0]) {
        lua_pushboolean(L, 0);
        lua_pushfstring(L, "xnet.__reload: thread %d has no reloadable script",
                        xthread_get_id(thr));
        return 2;
    }

    int base = lua_gettop(L);
    xlogi("xnet.__reload: loading thread script '%s' for thread %d",
          td->script_path, xthread_get_id(thr));

    if (luaL_dofile(L, td->script_path) != LUA_OK) {
        const char* err = lua_tostring(L, -1);
        char msg[1024];
        snprintf(msg, sizeof(msg), "xnet.__reload: load %s failed: %s",
                 td->script_path, err ? err : "unknown error");
        lua_settop(L, base);
        lua_pushboolean(L, 0);
        lua_pushstring(L, msg);
        return 2;
    }

    if (!lua_istable(L, -1)) {
        lua_settop(L, base);
        lua_pushboolean(L, 0);
        lua_pushfstring(L, "xnet.__reload: %s did not return a table",
                        td->script_path);
        return 2;
    }

    int table_idx = lua_gettop(L);
    int sync_ref = ref_field_if_function(L, table_idx, "__thread_handle");
    int init_ref = ref_field_if_function(L, table_idx, "__init");
    int update_ref = ref_field_if_function(L, table_idx, "__update");
    int uninit_ref = ref_field_if_function(L, table_idx, "__uninit");
    thread_data_apply_callbacks(td, L, sync_ref, init_ref, update_ref, uninit_ref);

    lua_settop(L, base);
    lua_pushboolean(L, 1);
    lua_pushfstring(L, "thread %d reloaded %s", xthread_get_id(thr), td->script_path);
    return 2;
}

static int l_xnet_thread_reload(lua_State* L) {
    return lua_thread_reload_current(L);
}

static void install_xnet_thread_reload(lua_State* L) {
    lua_getglobal(L, "xnet");
    if (lua_istable(L, -1)) {
        lua_pushcfunction(L, l_xnet_thread_reload);
        lua_setfield(L, -2, "__reload");
    }
    lua_pop(L, 1);
}

static void call_xnet_reload_noresult(lua_State* L, int thread_id) {
    int base = lua_gettop(L);
    lua_getglobal(L, "xnet");
    if (!lua_istable(L, -1)) {
        xloge("xthread: xnet table missing while reloading thread %d", thread_id);
        lua_settop(L, base);
        return;
    }
    lua_getfield(L, -1, "__reload");
    if (!lua_isfunction(L, -1)) {
        xloge("xthread: xnet.__reload missing on thread %d", thread_id);
        lua_settop(L, base);
        return;
    }

    if (lua_pcall(L, 0, 2, 0) != LUA_OK) {
        xloge("xthread: xnet.__reload failed on thread %d: %s",
              thread_id, lua_tostring(L, -1));
        lua_settop(L, base);
        return;
    }

    if (!lua_toboolean(L, -2)) {
        xloge("xthread: xnet.__reload reported failure on thread %d: %s",
              thread_id, lua_tostring(L, -1));
    } else {
        xlogi("xthread: %s", lua_tostring(L, -1));
    }
    lua_settop(L, base);
}

static int thread_data_gc(lua_State* L) {
    ThreadData* td = (ThreadData*)luaL_checkudata(L, 1, THREAD_DATA_META);
    if (!td) return 0;

    xlogd("thread_data_gc: reclaiming ThreadData for thread");

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
static void thread_message_handler(xThread* thr, void* arg, int arg_len) {
    ThreadData* td = (ThreadData*)xthread_get_userdata(thr);

    if (!td || !td->L) {
        xloge("xthread: no lua state for thread %d", xthread_get_id(thr));
        return;
    }

    lua_State* L = td->L;
    int id = xthread_get_id(thr);
    int base = lua_gettop(L);

    int nvals = unpack_raw(L, (const char*)arg, (size_t)arg_len);
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
        if (k1 && strcmp(k1, "@reload_thread") == 0) {
            call_xnet_reload_noresult(L, id);
            lua_settop(L, base);
            return;
        }

        if (k1 && strcmp(k1, "@async_resume") == 0) {
            xlogv("C INTERCEPT: @async_resume on thread %d will resume coroutine", xthread_current_id());
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
                xloge("xthread: malformed @async_resume (nvals=%d)", nvals);
                lua_settop(L, base);
                return;
            }
            lua_Integer co_id = lua_tointeger(L, base + 3);
            int nresume = nvals - 5; /* ok + results */

            xlogd("xthread: @async_resume looking up co_id=%lld in thread %d pending table", (long long)co_id, xthread_current_id());
            lua_State* co = pending_pop(L, co_id, true);
            if (!co) {
                xlogd("xthread: @async_resume co_id=%lld not found (late reply or timeout)", (long long)co_id);
                lua_settop(L, base);
                return;
            }

            /* Copy (ok, results...) to top of L's stack for xmove */
            for (int i = 0; i < nresume; i++) {
                lua_pushvalue(L, base + 6 + i);
            }

            lua_xmove(L, co, nresume);     /* move n values from top of L to co */

            int nresults = 0;
            int status = xthread_resume_coroutine(co, L, nresume, &nresults);
            if (status != LUA_OK && status != LUA_YIELD) {
                xloge("xthread: coroutine error: %s", lua_tostring(co, -1));
                lua_settop(co, 0);
            }
            lua_settop(L, base);           /* restore original stack height */
            return; /* INTERCEPTED - DONE! do NOT continue to Lua handler */
        }
    }

    /* Not @async_resume - go to normal Lua handler dispatch */
    /* ── Normal dispatch: call Lua handler ── */
    if (td->sync_handler_ref != LUA_NOREF) {
        lua_pushcfunction(L, lua_traceback_handler);
        lua_insert(L, base + 1);
        int errfunc = base + 1;
        lua_rawgeti(L, LUA_REGISTRYINDEX, td->sync_handler_ref);
        if (!lua_isfunction(L, -1)) {
            xloge("xthread: no handler on thread %d (did you call xthread.init?)", id);
            lua_settop(L, base);
            return;
        }
        /* Move handler below all unpacked values */
        lua_insert(L, base + 2);
        /* Call: handler(reply_router, k1, k2, k3, ...) */
        if (lua_pcall(L, nvals, 0, errfunc) != LUA_OK) {
            xloge("xthread: handler error on thread %d: %s", id, lua_tostring(L, -1));
            lua_settop(L, base);
            return;
        }
        lua_settop(L, base);
    } else {
        xloge("xthread: no handler on thread %d (did you call xthread.init(handler)?)", id);
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
        td = thread_data_alloc(L, L);
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
        xlogw("xthread.init: no handler set for thread %d – "
              "call xthread.init(handler) or ensure __thread_handle exists", xthread_get_id(thr));
    }

    /* Initialise pending-RPC tables and co_id counter */
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

    xlogi("xthread.init: thread %d initialised", xthread_get_id(thr));
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
    lua_Integer pkt_len = pack_to_lua_stack(L, top);
    if (pkt_len < 0) {
        lua_pushboolean(L, 0);
        lua_pushstring(L, "xthread.post: cmsgpack.pack failed");
        return 2;
    }

    {
        size_t tmp;
        const char* pkt_data = lua_tolstring(L, -1, &tmp);
        int post_err = xthread_post(target_id, thread_message_handler,
                                    pkt_data, (size_t)pkt_len);
        lua_pop(L, 1);
        if (post_err != 0) {
            lua_pushboolean(L, 0);
            if (post_err == -2) {
                lua_pushfstring(L, "xthread.post: thread %d queue full", target_id);
            } else {
                lua_pushfstring(L, "xthread.post: thread %d unavailable", target_id);
            }
            return 2;
        }
    }
    lua_pushboolean(L, 1);
    return 1;
}

/* xthread.set_queue_max(target_id, new_max)
**
** Set per-thread queue cap:
**   new_max > 0 : enable cap
**   new_max = 0 : unlimited
** Returns: true on success, or false + error_string on failure.
*/
static int l_xthread_set_queue_max(lua_State* L) {
    int target_id = (int)luaL_checkinteger(L, 1);
    lua_Integer max_i = luaL_checkinteger(L, 2);
    if (max_i < 0 || max_i > INT_MAX) {
        lua_pushboolean(L, 0);
        lua_pushstring(L, "xthread.set_queue_max: new_max must be >= 0");
        return 2;
    }
    if (xthread_set_queue_max(target_id, (int)max_i) != 0) {
        lua_pushboolean(L, 0);
        lua_pushfstring(L, "xthread.set_queue_max: thread %d unavailable", target_id);
        return 2;
    }
    lua_pushboolean(L, 1);
    return 1;
}

/* xthread.rpc(target_id, pt, timeout_ms, ...)
**
** Starts an RPC and returns (true, co_id) or (false, err). This function does
** not yield; the public Lua wrapper performs coroutine.yield() so LuaJIT does
** not need to yield from a C frame.
**
** Wire format sent to target: pack(reply_router, co_id, 0, pt, args...)
**   reply_router = "xthread:<caller_id>"
*/
static int l_xthread_rpc(lua_State* L) {
    int target_id = (int)luaL_checkinteger(L, 1);
    luaL_checkstring(L, 2); /* pt */
    lua_Integer timeout_ms_i = luaL_checkinteger(L, 3);
    int top = lua_gettop(L);

    if (timeout_ms_i < 0) timeout_ms_i = 0;
    if (timeout_ms_i > INT_MAX) {
        lua_pushboolean(L, 0);
        lua_pushstring(L, "xthread.rpc: timeout_ms too large");
        return 2;
    }

    int caller_id = xthread_current_id();
    if (caller_id <= 0) {
        lua_pushboolean(L, 0);
        lua_pushstring(L, "xthread.rpc: calling thread not registered");
        return 2;
    }

    xThread* caller_thr = xthread_current();
    ThreadData* caller_td = (ThreadData*)xthread_get_userdata(caller_thr);
    if (!caller_td || !caller_td->L) {
        lua_pushboolean(L, 0);
        lua_pushstring(L, "xthread.rpc: xthread.init() not called on this thread");
        return 2;
    }

    lua_State* main_L = caller_td->L;
    if (L == main_L) {
        lua_pushboolean(L, 0);
        lua_pushstring(L, "xthread.rpc: must be called from a coroutine");
        return 2;
    }

    /* Generate a unique co_id and store the coroutine */
    lua_Integer co_id = next_co_id(main_L);
    if (!pending_put(main_L, co_id, L)) { /* L is the coroutine; main_L holds registry */
        lua_pushboolean(L, 0);
        lua_pushstring(L, "xthread.rpc: pending table not initialized");
        return 2;
    }

    /* Build reply_router: "xthread:<caller_id>" */
    char reply_router[32];
    snprintf(reply_router, sizeof(reply_router), "xthread:%d", caller_id);

    /* Push pack args: reply_router, co_id, 0 (sk), pt, arg1, ..., argN */
    lua_pushstring(L, reply_router);
    lua_pushinteger(L, co_id);
    lua_pushinteger(L, 0); /* sk = 0 (unused in xthread, kept for Lua compat) */
    lua_pushvalue(L, 2); /* pt */
    for (int i = 4; i <= top; i++)
        lua_pushvalue(L, i); /* args */
    /* nargs = 3 + pt + (top-3) = top+1 */
    lua_Integer pkt_len = pack_to_lua_stack(L, top + 1);
    if (pkt_len < 0) {
        pending_pop(main_L, co_id, false); /* roll back */
        lua_settop(L, top);
        lua_pushboolean(L, 0);
        lua_pushstring(L, "xthread.rpc: cmsgpack.pack failed");
        return 2;
    }

    {
        size_t tmp;
        const char* pkt_data = lua_tolstring(L, -1, &tmp);
        uint64_t deadline_ms = timeout_ms_i > 0
            ? time_clock_ms() + (uint64_t)timeout_ms_i
            : 0;
        int rpc_err = xthread_post_deadline(target_id, thread_message_handler,
                                            pkt_data, (size_t)pkt_len,
                                            deadline_ms);
        lua_pop(L, 1);
        if (rpc_err != 0) {
            pending_pop(main_L, co_id, false); /* roll back */
            lua_settop(L, top);
            lua_pushboolean(L, 0);
            if (rpc_err == -2) {
                lua_pushfstring(L, "xthread.rpc: thread %d queue full", target_id);
            } else {
                lua_pushfstring(L, "xthread.rpc: thread %d unavailable", target_id);
            }
            return 2;
        }
    }

    lua_pushboolean(L, 1);
    lua_pushinteger(L, co_id);
    return 2;
}

static int l_xthread_rpc_timeout(lua_State* L) {
    lua_Integer co_id = luaL_checkinteger(L, 1);
    int top = lua_gettop(L);

    /* Post a synthetic REPLY to self. Resume still happens in the normal
    ** thread_message_handler intercept path, not inside timer callback. */
    lua_pushnil(L);                    /* reply_router */
    lua_pushstring(L, "@async_resume");
    lua_pushinteger(L, co_id);
    lua_pushinteger(L, 0);             /* sk */
    lua_pushstring(L, "rpc_timeout");  /* req_pt */
    lua_pushboolean(L, 0);             /* ok=false */
    lua_pushstring(L, "rpc timeout");

    lua_Integer pkt_len = pack_to_lua_stack(L, 7);
    if (pkt_len < 0) {
        lua_settop(L, top);
        lua_pushboolean(L, 0);
        return 1;
    }

    int self_id = xthread_current_id();
    if (self_id <= 0) {
        lua_pop(L, 1); /* packed string */
        lua_settop(L, top);
        lua_pushboolean(L, 0);
        return 1;
    }

    size_t tmp = 0;
    const char* pkt_data = lua_tolstring(L, -1, &tmp);
    int err = xthread_post_reply(self_id, thread_message_handler,
                                 pkt_data, (size_t)pkt_len);
    lua_pop(L, 1);
    lua_settop(L, top);
    lua_pushboolean(L, err == 0);
    return 1;
}

/* xthread.current_id()  →  integer */
static int l_current_id(lua_State* L) {
    lua_pushinteger(L, xthread_current_id());
    return 1;
}

typedef struct {
    size_t len;
    char msg[1];
} XThreadLogPayload;

static void xthread_log_post_task(xThread* thr, void* arg, int arg_len) {
    (void)thr;
    if (!arg || arg_len < (int)offsetof(XThreadLogPayload, msg)) return;
    XThreadLogPayload* payload = (XThreadLogPayload*)arg;
    size_t cap = (size_t)arg_len - offsetof(XThreadLogPayload, msg);
    size_t len = payload->len <= cap ? payload->len : cap;
    xlog_write_raw(payload->msg, len);
}

static size_t xthread_log_record_cap(size_t header) {
    size_t cap = (size_t)XLOG_RECORD_MAX_BYTES;
    size_t post_cap = header < (size_t)INT_MAX ? (size_t)INT_MAX - header : 0u;

    if (cap == 0u || cap > post_cap) cap = post_cap;
    if (cap == 0u) cap = 1u;
    return cap;
}

static int xthread_log_post_to_main(lua_State* L, int level, const char* level_name) {
    size_t len = 0;
    const char* msg = luaL_optlstring(L, 1, "", &len);
    int append_newline = lua_isnoneornil(L, 2) ? 1 : lua_toboolean(L, 2);
    if (!xlog_is_enabled(level)) {
        lua_pushboolean(L, 1);
        return 1;
    }

    size_t header = offsetof(XThreadLogPayload, msg);
    size_t newline_len = (append_newline && (len == 0 || msg[len - 1] != '\n')) ? 1u : 0u;
    size_t max_record_cap = xthread_log_record_cap(header);
    size_t record_cap = max_record_cap;
    size_t total_alloc;
    size_t record_len;
    size_t total;
    char stack_payload[offsetof(XThreadLogPayload, msg) + XLOG_RECORD_STACK_BYTES + 1u];
    int heap_payload = 1;

    if (len <= ((size_t)-1) - 256u - newline_len) {
        size_t wanted = 256u + len + newline_len;
        if (wanted < record_cap) record_cap = wanted;
    }
    total_alloc = header + record_cap + 1u;

    XThreadLogPayload* payload = (XThreadLogPayload*)malloc(total_alloc);
    if (!payload) {
        record_cap = (size_t)XLOG_RECORD_STACK_BYTES;
        if (record_cap == 0u) record_cap = 1u;
        if (record_cap > max_record_cap) {
            record_cap = max_record_cap;
        }
        payload = (XThreadLogPayload*)stack_payload;
        heap_payload = 0;
    }

    record_len = xlog_format(level, level_name, msg, len, append_newline,
                             payload->msg, record_cap + 1u);
    if (record_len > record_cap) record_len = record_cap;
    payload->len = record_len;
    total = header + record_len;

    int err = xthread_post_reply(XTHR_MAIN, xthread_log_post_task, payload, total);
    if (heap_payload) free(payload);

    lua_pushboolean(L, err == 0);
    if (err != 0) {
        lua_pushfstring(L, "xthread.log: post to main failed (err=%d)", err);
        return 2;
    }
    return 1;
}

static int xthread_log(lua_State* L, int level, const char* level_name, const char* console_tag) {
    if (_log_local) {
        size_t len = 0;
        const char* msg = luaL_optlstring(L, 1, "", &len);
        int append_newline = lua_isnoneornil(L, 2) ? 1 : lua_toboolean(L, 2);
        xlog_write(level, level_name, console_tag, msg, len, append_newline);
        return 0;
    }
    return xthread_log_post_to_main(L, level, level_name);
}

static int l_xthread_log_enabled(lua_State* L) {
    int level = (int)luaL_checkinteger(L, 1);
    lua_pushboolean(L, xlog_is_enabled(level));
    return 1;
}

static int lua_xthread_single_thread_max_id(void) {
    return XTHR_HTTP;
}

static int lua_xthread_is_group_thread_id(int id) {
    return id > lua_xthread_single_thread_max_id();
}

static void lua_xthread_format_log_label(char* dst, size_t cap, int id, const char* name) {
    const char* thread_name = (name && name[0]) ? name : "unknown";
    if (!dst || cap == 0) return;

    if (id == XTHR_MAIN) {
        snprintf(dst, cap, "T%d:MAIN", id);
    } else if (lua_xthread_is_group_thread_id(id)) {
        snprintf(dst, cap, "G%d:%s", id, thread_name);
    } else {
        snprintf(dst, cap, "T%d:%s", id, thread_name);
    }
}

static int l_xthread_log_init(lua_State* L) {
    xThread* thr = xthread_current();
    int id = xthread_current_id();
    const char* name;
    char thread_label[96];
    if (id <= 0 || !thr) {
        lua_pushboolean(L, 0);
        lua_pushliteral(L, "xthread.log_init: current thread is not registered");
        return 2;
    }

    name = xthread_get_name(thr);
    lua_xthread_format_log_label(thread_label, sizeof(thread_label), id, name);
    xlog_set_thread(id, name, thread_label);
    _log_local = 1;
    lua_pushboolean(L, 1);
    return 1;
}

static int l_xthread_log_verbose(lua_State* L) { return xthread_log(L, XLOG_LEVEL_VERBOSE, XLOG_LEVEL_NAME_VERBOSE, XLOG_TAG_VERBOSE); }
static int l_xthread_log_debug(lua_State* L) { return xthread_log(L, XLOG_LEVEL_DEBUG, XLOG_LEVEL_NAME_DEBUG, XLOG_TAG_DEBUG); }
static int l_xthread_log_info(lua_State* L) { return xthread_log(L, XLOG_LEVEL_INFO, XLOG_LEVEL_NAME_INFO, XLOG_TAG_INFO); }
static int l_xthread_log_system(lua_State* L) { return xthread_log(L, XLOG_LEVEL_SYSM, XLOG_LEVEL_NAME_SYSM, XLOG_TAG_SYSM); }
static int l_xthread_log_warn(lua_State* L) { return xthread_log(L, XLOG_LEVEL_WARN, XLOG_LEVEL_NAME_WARN, XLOG_TAG_WARN); }
static int l_xthread_log_error(lua_State* L) { return xthread_log(L, XLOG_LEVEL_ERROR, XLOG_LEVEL_NAME_ERROR, XLOG_TAG_ERROR); }
static int l_xthread_log_fatal(lua_State* L) { return xthread_log(L, XLOG_LEVEL_FATAL, XLOG_LEVEL_NAME_FATAL, XLOG_TAG_FATAL); }

static int l_xthread_set_log_level(lua_State* L) {
    int level = (int)luaL_checkinteger(L, 1);
    xlog_set_level(level);
    lua_pushboolean(L, 1);
    lua_pushinteger(L, xlog_get_level());
    return 2;
}

static int l_xthread_get_log_level(lua_State* L) {
    lua_pushinteger(L, xlog_get_level());
    return 1;
}

static int push_thread_stats(lua_State* L, int id) {
    xThread* thr = xthread_get(id);
    if (!thr) return 0;

    lua_createtable(L, 0, 4);

    lua_pushinteger(L, id);
    lua_setfield(L, -2, "id");

    {
        const char* name = xthread_get_name(thr);
        lua_pushstring(L, name ? name : "");
        lua_setfield(L, -2, "name");
    }

    {
        int qdepth = xthread_get_queue_depth(id);
        lua_pushinteger(L, qdepth < 0 ? 0 : qdepth);
        lua_setfield(L, -2, "queue_depth");
    }

    {
        int qmax = xthread_get_queue_max(id);
        lua_pushinteger(L, qmax < 0 ? 0 : qmax);
        lua_setfield(L, -2, "queue_max");
    }

    return 1;
}

/* xthread.stats(id) -> table | nil, err */
static int l_xthread_stats(lua_State* L) {
    int id = (int)luaL_checkinteger(L, 1);
    if (id <= 0 || id >= XTHR_MAX) {
        lua_pushnil(L);
        lua_pushfstring(L, "xthread.stats: invalid thread id %d", id);
        return 2;
    }

    if (!push_thread_stats(L, id)) {
        lua_pushnil(L);
        lua_pushfstring(L, "xthread.stats: thread %d not found", id);
        return 2;
    }
    return 1;
}

/* xthread.all_stats() -> { {id,name,queue_depth,queue_max}, ... } */
static int l_xthread_all_stats(lua_State* L) {
    int idx = 1;
    lua_createtable(L, 0, 0);
    for (int id = 1; id < XTHR_MAX; ++id) {
        if (!push_thread_stats(L, id)) continue;
        lua_rawseti(L, -2, idx++);
    }
    return 1;
}

/* ============================================================================
** New API - Dynamic thread creation from Lua
** ============================================================================ */

/* C extension modules exposed to every dynamic thread script. cmsgpack is
** statically linked; the rest are this project's own modules. */
static const luaL_Reg k_thread_modules[] = {
    { "cmsgpack",  luaopen_cmsgpack },
    { "xthread",   luaopen_xthread },
    { "xnet",      luaopen_xnet },
    { "xutils",    luaopen_xutils },
    { "xtimer",    luaopen_xtimer },
    { "xcompress", luaopen_xcompress },
    { NULL, NULL }
};

/* Lifecycle callbacks that bridge from C xthread to Lua
** This runs in the new thread's context after the OS thread has started
*/
static void lua_thread_on_init(xThread* thr) {
    ThreadData* td = (ThreadData*)xthread_get_userdata(thr);
    if (!td) {
        xloge("lua_thread_on_init: no ThreadData for thread %d", xthread_get_id(thr));
        return;
    }

    /* Create NEW Lua state for this thread */
    lua_State* L = luaL_newstate();
    if (!L) {
        xloge("lua_thread_on_init: failed to create Lua state for thread %d", xthread_get_id(thr));
        return;
    }
    td->L = L;

    /* Open standard libraries */
    luaL_openlibs(L);
    lua_thread_runtime_post_init(L);

    for (const luaL_Reg* m = k_thread_modules; m->name; m++) {
        luaL_requiref(L, m->name, m->func, 1);
        lua_pop(L, 1);
    }
    install_xnet_thread_reload(L);

    xdebug_attach_state(L, xthread_get_id(thr), td->script_path);

    /* Load the script in THIS THREAD'S own Lua state
    ** Script returns the definition table with callbacks */
    xlogi("lua_thread_on_init: loading script '%s' for thread %d", td->script_path, xthread_get_id(thr));
    if (luaL_dofile(L, td->script_path) != LUA_OK) {
        xloge("lua_thread_on_init: failed to load script '%s': %s",
              td->script_path, lua_tostring(L, -1));
        xdebug_detach_state(L);
        lua_close(L);
        td->L = NULL;
        return;
    }

    /* Script should return the definition table */
    if (!lua_istable(L, -1)) {
        xloge("lua_thread_on_init: script '%s' did not return a definition table", td->script_path);
        xdebug_detach_state(L);
        lua_close(L);
        td->L = NULL;
        return;
    }

    /* Extract callbacks from returned table and store as references */
    td->sync_handler_ref = ref_field_if_function(L, -1, "__thread_handle");
    if (td->sync_handler_ref == LUA_NOREF)
        xlogw("lua_thread_on_init: no __thread_handle in script '%s'", td->script_path);
    td->init_ref   = ref_field_if_function(L, -1, "__init");
    td->update_ref = ref_field_if_function(L, -1, "__update");
    td->uninit_ref = ref_field_if_function(L, -1, "__uninit");

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
        xloge("lua_thread_on_init: xthread.init failed: %s", lua_tostring(L, -1));
        lua_settop(L, base);
    }

    /* Call user's __init callback if provided */
    if (td->init_ref != LUA_NOREF) {
        base = lua_gettop(L);
        lua_rawgeti(L, LUA_REGISTRYINDEX, td->init_ref);
        if (lua_pcall(L, 0, 0, 0) != LUA_OK) {
            xloge("lua_thread_on_init: user init callback error: %s", lua_tostring(L, -1));
            lua_settop(L, base);
        }
    }

    /* If the script started a timer pool but never called xnet.init, bring up
    ** xpoll so the auto-update loop has a precise sleep-with-wakeup mechanism.
    ** Track this so we balance the teardown without disturbing anything the
    ** script may have set up itself via xnet.init. */
    if (xtimer_inited() && !xpoll_inited()) {
        if (socket_init() == 0) {
            if (xpoll_init() == 0) {
                xthread_wakeup_init();
                td->auto_xpoll = 1;
            } else {
                socket_cleanup();
            }
        }
    }

    xlogi("lua_thread_on_init: thread %d fully initialized", xthread_get_id(thr));
}

#define XTHR_AUTO_WAIT_CAP 16

static void lua_thread_on_update(xThread* thr) {
    ThreadData* td = (ThreadData*)xthread_get_userdata(thr);
    if (!td || !td->L) return;

    lua_State* L = td->L;
    xdebug_update_state(L);

    if (td->update_ref != LUA_NOREF) {
        int base = lua_gettop(L);
        lua_pushcfunction(L, lua_traceback_handler);
        int errfunc = base + 1;
        lua_rawgeti(L, LUA_REGISTRYINDEX, td->update_ref);
        if (lua_pcall(L, 0, 0, errfunc) != LUA_OK) {
            xloge("lua_thread_on_update: thread %d error: %s", xthread_get_id(thr), lua_tostring(L, -1));
            lua_settop(L, base);
            return;
        }
        lua_settop(L, base);
    }

    /* Auto-drive timers and xpoll for scripts that don't define their own
    ** __update body (and as a safety net for ones that do). */
    int wait_ms = XTHR_AUTO_WAIT_CAP;
    if (xtimer_inited()) {
        int next = xtimer_update();
        if (next > 0 && next < wait_ms) wait_ms = next;
    }
    if (xpoll_inited()) {
        xpoll_poll(wait_ms);
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
            xloge("lua_thread_on_cleanup: thread %d error: %s", xthread_get_id(thr), lua_tostring(L, -1));
            lua_settop(L, base);
        }
    }

    /* Auto-cleanup. Always reclaim xtimer if still up (idempotent and harmless).
    ** Only tear down xpoll if the runner brought it up - otherwise the script
    ** owns it via xnet.init. */
    if (xtimer_inited()) xtimer_uninit();
    if (td->auto_xpoll) {
        xthread_wakeup_uninit();
        xpoll_uninit();
        socket_cleanup();
        td->auto_xpoll = 0;
    }

    if (td->L) {
        lua_State* L = td->L;
        xdebug_detach_state(L);
        thread_data_unref_callbacks(td, L);
        td->L = NULL;
        lua_close(L);
    }

    /* xthread will unregister, clear the userdata reference */
    xthread_set_userdata(thr, NULL);
    xlogi("lua_thread_on_cleanup: thread %d cleaned up", xthread_get_id(thr));
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
    ThreadData* td = thread_data_alloc(L, NULL);

    /* Store script path copy - the new thread will load it in its own Lua state */
    td->script_path = malloc(strlen(script_path) + 1);
    if (!td->script_path) {
        xloge("xthread.create_thread: out of memory copying script path");
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
        xloge("xthread.create_thread: failed to register thread %d", id);
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
        xloge("xthread.create_thread: xthread_get failed after registration");
        lua_pushboolean(L, 0);
        lua_pushstring(L, "xthread.create_thread: xthread_get failed");
        return 2;
    }

    xlogi("xthread.create_thread: created thread %d '%s'", id, name);
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
    xlogi("xthread.shutdown_thread: unregistered thread %d", id);
    lua_pushboolean(L, 1);
    return 1;
}

static int l_xthread_xdebug_start(lua_State* L) {
    char port_s[32];
    char wait_s[8];
    char err[256];
    int port = (int)luaL_optinteger(L, 1, 19090);
    int wait = lua_toboolean(L, 2);

    snprintf(port_s, sizeof(port_s), "%d", port);
    snprintf(wait_s, sizeof(wait_s), "%d", wait ? 1 : 0);
    if (!xdebug_start_current(L, port_s, wait_s, err, (int)sizeof(err))) {
        lua_pushboolean(L, 0);
        lua_pushstring(L, err[0] ? err : "xdebug is not available");
        return 2;
    }
    lua_pushboolean(L, 1);
    lua_pushfstring(L, "xdebug listening on 127.0.0.1:%d for thread %d",
                    port, xthread_current_id());
    return 2;
}

static int l_xthread_xdebug_status(lua_State* L) {
    int port = 0;
    int running = xdebug_status(&port);
    lua_pushboolean(L, running);
    lua_pushinteger(L, port);
    return 2;
}

/* ============================================================================
** Module registration
** ========================================================================== */

static const luaL_Reg xthread_funcs[] = {
    { "init",             l_xthread_init },
    { "post",             l_xthread_post },
    { "set_queue_max",    l_xthread_set_queue_max },
    { "stats",            l_xthread_stats },
    { "all_stats",        l_xthread_all_stats },
    { "_log_init",        l_xthread_log_init },
    { "_log_enabled",     l_xthread_log_enabled },
    { "_log_verbose",     l_xthread_log_verbose },
    { "_log_debug",       l_xthread_log_debug },
    { "_log_info",        l_xthread_log_info },
    { "_log_system",      l_xthread_log_system },
    { "_log_warn",        l_xthread_log_warn },
    { "_log_error",       l_xthread_log_error },
    { "_log_fatal",       l_xthread_log_fatal },
    { "_set_log_level",   l_xthread_set_log_level },
    { "_get_log_level",   l_xthread_get_log_level },
    { "rpc",              l_xthread_rpc },
    { "_rpc_timeout",     l_xthread_rpc_timeout },
    { "current_id",       l_current_id   },
    { "create_thread",    l_xthread_create_thread },
    { "shutdown_thread",  l_xthread_shutdown_thread },
    { "xdebug_start",     l_xthread_xdebug_start },
    { "xdebug_status",    l_xthread_xdebug_status },
    { NULL, NULL }
};

static const char* XTHREAD_LUA_WRAPPERS =
"local xthread = ...\n"
"local c_rpc = xthread.rpc\n"
"local _rpc_timeout = xthread._rpc_timeout\n"
"local _rpc_timers = {}\n"
"local _unpack = table.unpack or unpack\n"
"local function _pack(...)\n"
"    return { n = select('#', ...), ... }\n"
"end\n"
"local function rpc_wait(timeout_ms, target_id, pt, ...)\n"
"    local running, ismain = coroutine.running()\n"
"    if not running or ismain then\n"
"        return false, 'xthread.rpc: must be called from a coroutine'\n"
"    end\n"
"    timeout_ms = tonumber(timeout_ms) or 0\n"
"    local ok, co_id_or_err = c_rpc(target_id, pt, timeout_ms, ...)\n"
"    if not ok then return false, co_id_or_err end\n"
"    local co_id = co_id_or_err\n"
"    local timer = nil\n"
"    if timeout_ms > 0 then\n"
"        timer = xtimer.delay(timeout_ms, function()\n"
"            _rpc_timers[co_id] = nil\n"
"            _rpc_timeout(co_id)\n"
"        end)\n"
"        _rpc_timers[co_id] = timer\n"
"    end\n"
"    local r = _pack(coroutine.yield())\n"
"    local t = _rpc_timers[co_id]\n"
"    if t then\n"
"        _rpc_timers[co_id] = nil\n"
"        t:del()\n"
"    end\n"
"    return _unpack(r, 1, r.n)\n"
"end\n"
"function xthread.rpc(target_id, pt, timeout_ms, ...)\n"
"    return rpc_wait(timeout_ms, target_id, pt, ...)\n"
"end\n"
"return xthread\n";

static int lua_xthread_load_xlog(lua_State* L) {
    if (luaL_loadfile(L, "xlua/lua_xlog.lua") == LUA_OK) return LUA_OK;
    lua_pop(L, 1);
    return luaL_loadfile(L, "../xlua/lua_xlog.lua");
}

static const struct { const char* name; int val; } THREAD_CONSTS[] = {
    { "MAIN",        XTHR_MAIN        },
    { "REDIS",       XTHR_REDIS       },
    { "MYSQL",       XTHR_MYSQL       },
    { "LOG",         XTHR_LOG         },
    { "IO",          XTHR_IO          },
    { "COMPUTE",     XTHR_COMPUTE     },
    { "NATS",        XTHR_NATS        },
    { "HTTP",        XTHR_HTTP        },
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
    thread_data_push_meta(L);
    lua_pop(L, 1);

    luaL_newlib(L, xthread_funcs);

    for (int i = 0; THREAD_CONSTS[i].name; i++) {
        lua_pushinteger(L, THREAD_CONSTS[i].val);
        lua_setfield(L, -2, THREAD_CONSTS[i].name);
    }

    if (lua_xthread_load_xlog(L) != LUA_OK) {
        return lua_error(L);
    }
    lua_pushvalue(L, -2); /* module table */
    if (lua_pcall(L, 1, 1, 0) != LUA_OK) {
        return lua_error(L);
    }
    lua_pop(L, 1); /* lua_xlog returned module */

    if (luaL_loadstring(L, XTHREAD_LUA_WRAPPERS) != LUA_OK) {
        return lua_error(L);
    }
    lua_pushvalue(L, -2); /* module table */
    if (lua_pcall(L, 1, 1, 0) != LUA_OK) {
        return lua_error(L);
    }
    lua_pop(L, 1); /* wrapper returned module */

    return 1; /* return module table */
}
