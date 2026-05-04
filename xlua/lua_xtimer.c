/* lua_xtimer.c - Lua bindings for xtimer.
**
** xtimer keeps a per-thread min-heap of timers (the C side stores the heap
** in __thread storage, so each Lua state has its own timer pool). The
** standard pattern in a thread script:
**
**   local timer = xtimer.add(1000, function(self) ... end, -1)
**   ...
**   timer:del()                -- cancel
**
** Once xtimer.init() has been called the thread runner auto-drives
** xtimer.update() each tick and auto-runs xtimer.uninit() on shutdown - the
** script does not need its own __update / __uninit just for timers. If
** xpoll has not been brought up by the script (via xnet.init), the runner
** also auto-inits it so the tick loop has a precise sleep-with-wakeup.
**
** Timer userdata holds a strong self-ref while it is live, so callers may
** safely discard the returned handle for fire-and-forget timers.
*/

#include <stdlib.h>
#include <string.h>
#include <stdio.h>
#include <stdint.h>

#if defined(LUA_EMBEDDED)
#include "../3rd/minilua.h"
#else
#include "lua.h"
#include "lauxlib.h"
#endif

#include "xtimer.h"
#include "xlog.h"

#define LUA_XTIMER_META "xtimer.handle"

typedef struct LuaTimer {
    lua_State* L;
    xtimerHandler handle;     /* NULL once the C heap node is gone */
    int callback_ref;
    int self_ref;
    int repeat_remaining;     /* -1 = infinite; otherwise calls left */
} LuaTimer;

static LuaTimer* check_timer(lua_State* L, int idx) {
    return (LuaTimer*)luaL_checkudata(L, idx, LUA_XTIMER_META);
}

static void lua_timer_release_refs(LuaTimer* t) {
    if (!t || !t->L) return;
    if (t->callback_ref != LUA_NOREF) {
        luaL_unref(t->L, LUA_REGISTRYINDEX, t->callback_ref);
        t->callback_ref = LUA_NOREF;
    }
    if (t->self_ref != LUA_NOREF) {
        luaL_unref(t->L, LUA_REGISTRYINDEX, t->self_ref);
        t->self_ref = LUA_NOREF;
    }
}

static void timer_callback_bridge(void* ud) {
    LuaTimer* t = (LuaTimer*)ud;
    if (!t || !t->L) return;

    int last_call = 0;
    if (t->repeat_remaining > 0) {
        if (--t->repeat_remaining == 0) last_call = 1;
    }
    /* repeat_remaining < 0 means infinite (already mapped from -1) */

    if (last_call) {
        /* C side has already extracted and will free the heap node after we
        ** return - clear handle so xtimer.del becomes a no-op. */
        t->handle = NULL;
    }

    lua_State* L = t->L;
    int base = lua_gettop(L);
    if (t->callback_ref != LUA_NOREF) {
        lua_rawgeti(L, LUA_REGISTRYINDEX, t->callback_ref);
        if (lua_isfunction(L, -1)) {
            if (t->self_ref != LUA_NOREF)
                lua_rawgeti(L, LUA_REGISTRYINDEX, t->self_ref);
            else
                lua_pushnil(L);
            if (lua_pcall(L, 1, 0, 0) != LUA_OK) {
                XLOGE("xtimer: callback error: %s", lua_tostring(L, -1));
                lua_pop(L, 1);
            }
        } else {
            lua_pop(L, 1);
        }
    }
    lua_settop(L, base);

    if (last_call) lua_timer_release_refs(t);
}

/* ------------------------------------------------------------------------ */

static int l_timer_gc(lua_State* L) {
    LuaTimer* t = (LuaTimer*)luaL_checkudata(L, 1, LUA_XTIMER_META);
    if (t->handle) {
        xtimer_del(t->handle);
        t->handle = NULL;
    }
    if (t->callback_ref != LUA_NOREF) {
        luaL_unref(L, LUA_REGISTRYINDEX, t->callback_ref);
        t->callback_ref = LUA_NOREF;
    }
    /* self_ref must already be released (otherwise we wouldn't be GC'd). */
    t->self_ref = LUA_NOREF;
    t->L = NULL;
    return 0;
}

static int l_timer_del(lua_State* L) {
    LuaTimer* t = check_timer(L, 1);
    if (t->handle) {
        xtimer_del(t->handle);
        t->handle = NULL;
    }
    lua_timer_release_refs(t);
    return 0;
}

static int l_timer_active(lua_State* L) {
    LuaTimer* t = check_timer(L, 1);
    lua_pushboolean(L, t->handle != NULL ? 1 : 0);
    return 1;
}

/* ------------------------------------------------------------------------ */

static int l_xtimer_init(lua_State* L) {
    int cap = (int)luaL_optinteger(L, 1, 64);
    if (cap < 1) cap = 1;
    xtimer_init(cap);
    return 0;
}

static int l_xtimer_uninit(lua_State* L) {
    (void)L;
    xtimer_uninit();
    return 0;
}

static int l_xtimer_inited(lua_State* L) {
    lua_pushboolean(L, xtimer_inited());
    return 1;
}

static int l_xtimer_update(lua_State* L) {
    lua_pushinteger(L, (lua_Integer)xtimer_update());
    return 1;
}

static int l_xtimer_last(lua_State* L) {
    lua_pushinteger(L, (lua_Integer)xtimer_last());
    return 1;
}

static int l_xtimer_show(lua_State* L) {
    (void)L;
    xtimer_show();
    return 0;
}

/* Build the LuaTimer userdata, register it in the C heap, and leave it on
** top of the Lua stack. callback_idx is the absolute stack index of the Lua
** callback function; the caller is responsible for type-checking it. */
static int xtimer_create_lua(lua_State* L, const char* fname, int interval_ms,
                             int callback_idx, int repeat_num) {
    LuaTimer* t = (LuaTimer*)lua_newuserdata(L, sizeof(*t));
    t->L = L;
    t->handle = NULL;
    t->callback_ref = LUA_NOREF;
    t->self_ref = LUA_NOREF;
    t->repeat_remaining = repeat_num;
    luaL_setmetatable(L, LUA_XTIMER_META);

    /* Strong self-ref keeps the userdata alive while the timer is live. */
    lua_pushvalue(L, -1);
    t->self_ref = luaL_ref(L, LUA_REGISTRYINDEX);

    lua_pushvalue(L, callback_idx);
    t->callback_ref = luaL_ref(L, LUA_REGISTRYINDEX);

    t->handle = xtimer_add(interval_ms, timer_callback_bridge, t, repeat_num);
    if (!t->handle) {
        lua_timer_release_refs(t);
        return luaL_error(L, "%s: xtimer_add failed", fname);
    }
    return 1;
}

static int l_xtimer_add(lua_State* L) {
    int interval_ms = (int)luaL_checkinteger(L, 1);
    luaL_checktype(L, 2, LUA_TFUNCTION);
    int repeat_num = (int)luaL_optinteger(L, 3, 1);

    if (interval_ms < 0)
        return luaL_error(L, "xtimer.add: interval_ms must be >= 0");
    if (repeat_num != -1 && repeat_num < 1)
        return luaL_error(L, "xtimer.add: repeat_num must be -1 (infinite) or >= 1");

    return xtimer_create_lua(L, "xtimer.add", interval_ms, 2, repeat_num);
}

/* xtimer.delay(interval_ms, callback, [name]) -> timer
** Convenience for a one-shot timer (repeat_num = 1). The returned handle
** can be used to cancel before it fires. */
static int l_xtimer_delay(lua_State* L) {
    int interval_ms = (int)luaL_checkinteger(L, 1);
    luaL_checktype(L, 2, LUA_TFUNCTION);
    if (interval_ms < 0)
        return luaL_error(L, "xtimer.delay: interval_ms must be >= 0");

    return xtimer_create_lua(L, "xtimer.delay", interval_ms, 2, 1);
}

static int l_xtimer_del(lua_State* L) {
    return l_timer_del(L);
}

/* ------------------------------------------------------------------------ */

static int l_xtimer_now_ms(lua_State* L) {
    lua_pushinteger(L, (lua_Integer)time_clock_ms());
    return 1;
}

static int l_xtimer_now_us(lua_State* L) {
    lua_pushinteger(L, (lua_Integer)time_clock_us());
    return 1;
}

static int l_xtimer_day_ms(lua_State* L) {
    lua_pushinteger(L, (lua_Integer)time_day_ms());
    return 1;
}

static int l_xtimer_day_us(lua_State* L) {
    lua_pushinteger(L, (lua_Integer)time_day_us());
    return 1;
}

static int l_xtimer_format(lua_State* L) {
    lua_Integer ms = luaL_optinteger(L, 1, (lua_Integer)time_day_ms());
    char buf[24];
    time_get_dt((uint64_t)ms, buf);
    lua_pushstring(L, buf);
    return 1;
}

/* ------------------------------------------------------------------------ */

static const luaL_Reg timer_methods[] = {
    { "del",    l_timer_del },
    { "active", l_timer_active },
    { NULL, NULL }
};

static const luaL_Reg xtimer_funcs[] = {
    { "init",   l_xtimer_init },
    { "uninit", l_xtimer_uninit },
    { "inited", l_xtimer_inited },
    { "update", l_xtimer_update },
    { "last",   l_xtimer_last },
    { "show",   l_xtimer_show },
    { "add",    l_xtimer_add },
    { "delay",  l_xtimer_delay },
    { "del",    l_xtimer_del },
    { "now_ms", l_xtimer_now_ms },
    { "now_us", l_xtimer_now_us },
    { "day_ms", l_xtimer_day_ms },
    { "day_us", l_xtimer_day_us },
    { "format", l_xtimer_format },
    { NULL, NULL }
};

LUALIB_API int luaopen_xtimer(lua_State* L) {
    if (luaL_newmetatable(L, LUA_XTIMER_META)) {
        lua_pushcfunction(L, l_timer_gc);
        lua_setfield(L, -2, "__gc");
        lua_newtable(L);
        luaL_setfuncs(L, timer_methods, 0);
        lua_setfield(L, -2, "__index");
    }
    lua_pop(L, 1);

    luaL_newlib(L, xtimer_funcs);
    return 1;
}
