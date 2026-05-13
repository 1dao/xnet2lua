#ifndef LUA_XDEBUG_H
#define LUA_XDEBUG_H

/*
** lua_xdebug.h - optional native Lua debugger integration for xnet2lua.
**
** Build-time switch:
**   XNET_WITH_XDEBUG=0
**     All APIs below compile to no-ops. This is the production/default path.
**
**   XNET_WITH_XDEBUG=1
**     xnet links xlua/lua_xdebug.c and can expose a local TCP debug server.
**
** Runtime model:
**   - WITH_XDEBUG only compiles the capability in; it does not start debugging.
**   - XDEBUG_BOOT=1 starts the debug server during process boot.
**   - xthread.xdebug_start(port, wait) can start it later from Lua, for
**     example through the xadmin remote script executor.
**
** Threading rules:
**   Each xnet thread owns an independent lua_State. Debug hooks must be
**   installed by the same OS thread that owns that lua_State. Do not call Lua
**   APIs for another thread's state from the debug server thread or from a
**   different xnet thread.
**
** Implementation pattern:
**   - xdebug_attach_state registers a lua_State as a potential debug target.
**   - xdebug_configure / xdebug_start_current start the TCP debug service.
**   - xdebug_update_state is called from each Lua thread's update loop; once
**     the server is running, it installs hooks for that thread safely in-place.
**   - xdebug_detach_state removes hooks before lua_close.
**
** Current debugger transport:
**   The native server listens on 127.0.0.1:XDEBUG_PORT (default 19090) and is
**   normally reached by VSCode through tools/xdebug_dap.js. For remote devices,
**   use port forwarding (ssh -L, adb forward, iproxy) instead of exposing the
**   debug port directly.
*/

#ifndef XNET_WITH_XDEBUG
#define XNET_WITH_XDEBUG 0
#endif

#if XNET_WITH_XDEBUG

typedef struct lua_State lua_State;

/* Start the debug server during process boot when 'enabled' is truthy.
** 'port' and 'wait' are string forms of XDEBUG_PORT and XDEBUG_WAIT.
** If states were registered before the call, they are enabled on their next
** xdebug_update_state call in the owning Lua thread.
*/
void xdebug_configure(const char* enabled, const char* port, const char* wait);

/* Stop the debug server and release its worker thread. Called during process
** shutdown. Any stopped Lua thread is released before the server exits.
*/
void xdebug_shutdown(void);

/* Register a lua_State as a debuggable xnet thread.
** Safe to call even before the debug server is running; it only records the
** state and script path. Hooks are installed later when debugging is active.
*/
void xdebug_attach_state(lua_State* L, int thread_id, const char* script_path);

/* Called by the owning Lua thread from its update loop.
** If the debug service has been started on demand, this installs the line hook
** and coroutine hook for this Lua state in the correct OS thread.
*/
void xdebug_update_state(lua_State* L);

/* Remove debug hooks and unregister the Lua state before lua_close. */
void xdebug_detach_state(lua_State* L);

/* Start the debug service from the current Lua state, used by
** xthread.xdebug_start(port, wait). This enables the current state immediately;
** other registered states will enable themselves from xdebug_update_state.
** Returns 1 on success, 0 on failure and writes a short error to err.
*/
int xdebug_start_current(lua_State* L, const char* port, const char* wait,
                         char* err, int errcap);

/* Return whether the debug service is running; optionally returns its port. */
int xdebug_status(int* port);

#else

typedef struct lua_State lua_State;
static inline void xdebug_configure(const char* enabled, const char* port, const char* wait) {
    (void)enabled;
    (void)port;
    (void)wait;
}
static inline void xdebug_shutdown(void) {}
static inline void xdebug_attach_state(lua_State* L, int thread_id, const char* script_path) {
    (void)L;
    (void)thread_id;
    (void)script_path;
}
static inline void xdebug_update_state(lua_State* L) {
    (void)L;
}
static inline void xdebug_detach_state(lua_State* L) {
    (void)L;
}
static inline int xdebug_start_current(lua_State* L, const char* port, const char* wait,
                                       char* err, int errcap) {
    (void)L;
    (void)port;
    (void)wait;
    if (err && errcap > 0) err[0] = '\0';
    return 0;
}
static inline int xdebug_status(int* port) {
    if (port) *port = 0;
    return 0;
}

#endif

#endif /* LUA_XDEBUG_H */
