#include "lua_xdebug.h"

#if XNET_WITH_XDEBUG

#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "../xsock.h"
#include "../xthread.h"

#if defined(LUA_EMBEDDED)
#include "../3rd/minilua.h"
#else
#include "lauxlib.h"
#include "lualib.h"
#endif

#ifdef _WIN32
#include <process.h>
typedef CRITICAL_SECTION xdbg_mutex;
typedef CONDITION_VARIABLE xdbg_cond;
typedef HANDLE xdbg_thread;
#define xdbg_mutex_init InitializeCriticalSection
#define xdbg_mutex_destroy DeleteCriticalSection
#define xdbg_mutex_lock EnterCriticalSection
#define xdbg_mutex_unlock LeaveCriticalSection
#define xdbg_cond_init(c) InitializeConditionVariable(c)
#define xdbg_cond_wait(c, m) SleepConditionVariableCS((c), (m), INFINITE)
#define xdbg_cond_signal WakeAllConditionVariable
#else
#include <pthread.h>
#include <unistd.h>
typedef pthread_mutex_t xdbg_mutex;
typedef pthread_cond_t xdbg_cond;
typedef pthread_t xdbg_thread;
#define xdbg_mutex_init pthread_mutex_init
#define xdbg_mutex_destroy pthread_mutex_destroy
#define xdbg_mutex_lock pthread_mutex_lock
#define xdbg_mutex_unlock pthread_mutex_unlock
static void xdbg_cond_init(xdbg_cond* c) { pthread_cond_init(c, NULL); }
#define xdbg_cond_wait(c, m) pthread_cond_wait((c), (m))
#define xdbg_cond_signal pthread_cond_broadcast
#endif

#include "../xmacro.h"

#ifndef LUA_OK
#define LUA_OK 0
#endif

#define XDBG_MAX_STATES 128
#define XDBG_MAX_BREAKS 512
#define XDBG_RESP_SIZE 16384
#define XDBG_LINE_SIZE 2048

typedef enum {
    XDBG_STEP_NONE = 0,
    XDBG_STEP_INTO,
    XDBG_STEP_OVER,
    XDBG_STEP_OUT
} XDbgStep;

typedef enum {
    XDBG_REQ_NONE = 0,
    XDBG_REQ_STACK,
    XDBG_REQ_LOCALS
} XDbgReq;

typedef struct {
    char file[512];
    int line;
} XDbgBreak;

typedef struct {
    lua_State* L;
    lua_State* stop_L;
    int active;
    int hook_enabled;
    int thread_id;
    int stopped;
    int pause_requested;
    int stop_line;
    int stop_depth;
    int req_frame;
    XDbgStep step_mode;
    XDbgReq req;
    char script[512];
    char stop_file[512];
    char response[XDBG_RESP_SIZE];
} XDbgState;

static struct {
    int inited;
    int enabled;
    int running;
    int thread_started;
    int wait_on_attach;
    int port;
    SOCKET_T listen_fd;
    xdbg_mutex lock;
    xdbg_cond cond;
    xdbg_thread thread;
    XDbgState states[XDBG_MAX_STATES];
    XDbgBreak breaks[XDBG_MAX_BREAKS];
    int break_count;
} g_dbg;

static char g_xdbg_state_key;
static char g_xdbg_wrap_key;

static void xdbg_hook(lua_State* L, lua_Debug* ar);

static int xdbg_truthy(const char* v) {
    return v && *v && strcmp(v, "0") != 0 && strcmp(v, "false") != 0 &&
           strcmp(v, "off") != 0 && strcmp(v, "no") != 0;
}

static void xdbg_init_sync(void) {
    if (g_dbg.inited) return;
#ifdef _WIN32
    xdbg_mutex_init(&g_dbg.lock);
#else
    xdbg_mutex_init(&g_dbg.lock, NULL);
#endif
    xdbg_cond_init(&g_dbg.cond);
    g_dbg.inited = 1;
}

static void xdbg_path(char* out, size_t cap, const char* src) {
    size_t i = 0;
    if (!out || cap == 0) return;
    out[0] = '\0';
    if (!src) return;
    if (*src == '@') src++;
    while (*src == '.' && (src[1] == '/' || src[1] == '\\')) src += 2;
    for (; *src && i + 1 < cap; src++) out[i++] = (*src == '\\') ? '/' : *src;
    out[i] = '\0';
}

static int xdbg_ends_with(const char* s, const char* suffix) {
    size_t n, m;
    if (!s || !suffix) return 0;
    n = strlen(s);
    m = strlen(suffix);
    return n >= m && strcmp(s + n - m, suffix) == 0;
}

static int xdbg_file_match(const char* a, const char* b) {
    if (!a || !b) return 0;
    return strcmp(a, b) == 0 || xdbg_ends_with(a, b) || xdbg_ends_with(b, a);
}

static XDbgState* xdbg_find_state_locked(lua_State* L, int thread_id) {
    int i;
    for (i = 0; i < XDBG_MAX_STATES; i++) {
        XDbgState* st = &g_dbg.states[i];
        if (!st->active) continue;
        if (L && st->L == L) return st;
        if (!L && st->thread_id == thread_id) return st;
    }
    return NULL;
}

static XDbgState* xdbg_state_from_lua(lua_State* L) {
    XDbgState* st;
    lua_pushlightuserdata(L, &g_xdbg_state_key);
    lua_rawget(L, LUA_REGISTRYINDEX);
    st = (XDbgState*)lua_touserdata(L, -1);
    lua_pop(L, 1);
    return st;
}

static void xdbg_set_state(lua_State* L, XDbgState* st) {
    lua_pushlightuserdata(L, &g_xdbg_state_key);
    if (st) lua_pushlightuserdata(L, st);
    else lua_pushnil(L);
    lua_rawset(L, LUA_REGISTRYINDEX);
}

static int xdbg_hook_coroutine(lua_State* L) {
    lua_State* co = lua_tothread(L, 1);
    if (co) lua_sethook(co, xdbg_hook, LUA_MASKLINE, 0);
    return 0;
}

static void xdbg_install_coroutine_hook(lua_State* L) {
    static const char* code =
        "local hook = __xnet_xdebug_hook_coroutine\n"
        "__xnet_xdebug_hook_coroutine = nil\n"
        "local create = coroutine.create\n"
        "local resume = coroutine.resume\n"
        "local unpack = table.unpack or unpack\n"
        "local function pack(...) return { n = select('#', ...), ... } end\n"
        "coroutine.create = function(f)\n"
        "  local co = create(f)\n"
        "  hook(co)\n"
        "  return co\n"
        "end\n"
        "coroutine.wrap = function(f)\n"
        "  local co = coroutine.create(f)\n"
        "  return function(...)\n"
        "    local r = pack(resume(co, ...))\n"
        "    if not r[1] then error(r[2], 2) end\n"
        "    return unpack(r, 2, r.n)\n"
        "  end\n"
        "end\n";

    lua_pushlightuserdata(L, &g_xdbg_wrap_key);
    lua_rawget(L, LUA_REGISTRYINDEX);
    if (lua_toboolean(L, -1)) {
        lua_pop(L, 1);
        return;
    }
    lua_pop(L, 1);

    lua_pushcfunction(L, xdbg_hook_coroutine);
    lua_setglobal(L, "__xnet_xdebug_hook_coroutine");
    if (luaL_dostring(L, code) != LUA_OK) {
        fprintf(stderr, "[xdebug] coroutine hook install failed: %s\n", lua_tostring(L, -1));
        lua_pop(L, 1);
        return;
    }

    lua_pushlightuserdata(L, &g_xdbg_wrap_key);
    lua_pushboolean(L, 1);
    lua_rawset(L, LUA_REGISTRYINDEX);
}

static void xdbg_enable_state_locked(XDbgState* st, lua_State* current_L, int wait) {
    if (!st || !st->active || !st->L) return;
    if (wait) st->pause_requested = 1;
    if (!st->hook_enabled) {
        xdbg_install_coroutine_hook(st->L);
        lua_sethook(st->L, xdbg_hook, LUA_MASKLINE, 0);
        st->hook_enabled = 1;
    }
    if (current_L && current_L != st->L) {
        lua_sethook(current_L, xdbg_hook, LUA_MASKLINE, 0);
    }
}

static int xdbg_stack_depth(lua_State* L) {
    int depth = 0;
    lua_Debug ar;
    while (lua_getstack(L, depth, &ar)) depth++;
    return depth;
}

static void xdbg_append(char* buf, size_t cap, const char* fmt, ...) {
    size_t n = strlen(buf);
    va_list ap;
    if (n >= cap) return;
    va_start(ap, fmt);
    vsnprintf(buf + n, cap - n, fmt, ap);
    va_end(ap);
}

static void xdbg_value(char* out, size_t cap, lua_State* L, int idx) {
    int t = lua_type(L, idx);
    switch (t) {
    case LUA_TNIL:
        snprintf(out, cap, "nil");
        break;
    case LUA_TBOOLEAN:
        snprintf(out, cap, "%s", lua_toboolean(L, idx) ? "true" : "false");
        break;
    case LUA_TNUMBER:
        snprintf(out, cap, "%.17g", (double)lua_tonumber(L, idx));
        break;
    case LUA_TSTRING: {
        size_t len = 0;
        const char* s = lua_tolstring(L, idx, &len);
        size_t i, o = 0;
        out[o++] = '"';
        for (i = 0; s && i < len && o + 3 < cap; i++) {
            char c = s[i];
            if (c == '\n') { out[o++] = '\\'; out[o++] = 'n'; }
            else if (c == '\r') { out[o++] = '\\'; out[o++] = 'r'; }
            else if (c == '\t') { out[o++] = '\\'; out[o++] = 't'; }
            else if (c == '"') { out[o++] = '\\'; out[o++] = '"'; }
            else out[o++] = c;
        }
        if (o + 1 < cap) out[o++] = '"';
        out[o] = '\0';
        break;
    }
    default:
        snprintf(out, cap, "%s:%p", lua_typename(L, t), lua_topointer(L, idx));
        break;
    }
}

static void xdbg_build_stack(XDbgState* st) {
    int level = 0;
    lua_Debug ar;
    lua_State* L = st->stop_L ? st->stop_L : st->L;
    st->response[0] = '\0';
    xdbg_append(st->response, sizeof(st->response), "OK stack %d\n", st->thread_id);
    while (lua_getstack(L, level, &ar)) {
        char file[512];
        lua_getinfo(L, "nSl", &ar);
        xdbg_path(file, sizeof(file), ar.source ? ar.source : ar.short_src);
        xdbg_append(st->response, sizeof(st->response), "%d\t%s\t%d\t%s\n",
                    level, file, ar.currentline, ar.name ? ar.name : "?");
        level++;
    }
    xdbg_append(st->response, sizeof(st->response), "END\n");
}

static void xdbg_build_locals(XDbgState* st, int frame) {
    int i;
    lua_Debug ar;
    lua_State* L = st->stop_L ? st->stop_L : st->L;
    st->response[0] = '\0';
    if (!lua_getstack(L, frame, &ar)) {
        snprintf(st->response, sizeof(st->response), "ERR frame not found\nEND\n");
        return;
    }
    xdbg_append(st->response, sizeof(st->response), "OK locals %d %d\n", st->thread_id, frame);
    for (i = 1;; i++) {
        char val[512];
        const char* name = lua_getlocal(L, &ar, i);
        if (!name) break;
        xdbg_value(val, sizeof(val), L, -1);
        xdbg_append(st->response, sizeof(st->response), "%s\t%s\n", name, val);
        lua_pop(L, 1);
    }
    xdbg_append(st->response, sizeof(st->response), "END\n");
}

static int xdbg_has_break_locked(const char* file, int line) {
    int i;
    for (i = 0; i < g_dbg.break_count; i++) {
        if (g_dbg.breaks[i].line == line && xdbg_file_match(file, g_dbg.breaks[i].file)) return 1;
    }
    return 0;
}

static void xdbg_stop_locked(XDbgState* st, lua_State* L, const char* file, int line, int depth) {
    st->stopped = 1;
    st->stop_L = L;
    st->pause_requested = 0;
    st->step_mode = XDBG_STEP_NONE;
    st->stop_depth = depth;
    st->stop_line = line;
    strncpy(st->stop_file, file ? file : "", sizeof(st->stop_file) - 1);
    st->stop_file[sizeof(st->stop_file) - 1] = '\0';
    xdbg_cond_signal(&g_dbg.cond);

    while (g_dbg.running && st->active && st->stopped) {
        while (g_dbg.running && st->active && st->stopped && st->req == XDBG_REQ_NONE) {
            xdbg_cond_wait(&g_dbg.cond, &g_dbg.lock);
        }
        if (!g_dbg.running || !st->active || !st->stopped) break;
        if (st->req == XDBG_REQ_STACK) xdbg_build_stack(st);
        else if (st->req == XDBG_REQ_LOCALS) xdbg_build_locals(st, st->req_frame);
        st->req = XDBG_REQ_NONE;
        xdbg_cond_signal(&g_dbg.cond);
    }
}

static void xdbg_hook(lua_State* L, lua_Debug* ar) {
    XDbgState* st;
    char file[512];
    int line;
    int depth;
    int should_stop = 0;

    if (!g_dbg.enabled || !g_dbg.running || ar->event != LUA_HOOKLINE) return;

    lua_getinfo(L, "Sl", ar);
    xdbg_path(file, sizeof(file), ar->source ? ar->source : ar->short_src);
    line = ar->currentline;
    depth = xdbg_stack_depth(L);

    xdbg_mutex_lock(&g_dbg.lock);
    st = xdbg_find_state_locked(L, 0);
    if (!st) st = xdbg_state_from_lua(L);
    if (st && st->active) {
        if (st->pause_requested) should_stop = 1;
        else if (st->step_mode == XDBG_STEP_INTO) should_stop = 1;
        else if (st->step_mode == XDBG_STEP_OVER && depth <= st->stop_depth) should_stop = 1;
        else if (st->step_mode == XDBG_STEP_OUT && depth < st->stop_depth) should_stop = 1;
        else if (xdbg_has_break_locked(file, line)) should_stop = 1;
        if (should_stop) xdbg_stop_locked(st, L, file, line, depth);
    }
    xdbg_mutex_unlock(&g_dbg.lock);
}

static void xdbg_send(SOCKET_T fd, const char* fmt, ...) {
    char buf[XDBG_RESP_SIZE];
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(buf, sizeof(buf), fmt, ap);
    va_end(ap);
    xsock_write(fd, buf, (int)strlen(buf));
}

static int xdbg_readline(SOCKET_T fd, char* out, int cap) {
    int n = 0;
    while (n + 1 < cap) {
        char c;
        int r = recv(fd, &c, 1, 0);
        if (r <= 0) return n > 0 ? n : -1;
        if (c == '\n') break;
        if (c != '\r') out[n++] = c;
    }
    out[n] = '\0';
    return n;
}

static void xdbg_cmd_threads(SOCKET_T fd) {
    int i;
    xdbg_send(fd, "OK threads\n");
    xdbg_mutex_lock(&g_dbg.lock);
    for (i = 0; i < XDBG_MAX_STATES; i++) {
        XDbgState* st = &g_dbg.states[i];
        if (!st->active) continue;
        xdbg_send(fd, "%d\t%s\t%s\t%d\t%s\n", st->thread_id,
                  st->stopped ? "stopped" : "running",
                  st->stop_file, st->stop_line, st->script);
    }
    xdbg_mutex_unlock(&g_dbg.lock);
    xdbg_send(fd, "END\n");
}

static void xdbg_cmd_break(SOCKET_T fd, char* file, int line) {
    xdbg_mutex_lock(&g_dbg.lock);
    if (g_dbg.break_count >= XDBG_MAX_BREAKS) {
        xdbg_mutex_unlock(&g_dbg.lock);
        xdbg_send(fd, "ERR too many breakpoints\nEND\n");
        return;
    }
    xdbg_path(g_dbg.breaks[g_dbg.break_count].file, sizeof(g_dbg.breaks[0].file), file);
    g_dbg.breaks[g_dbg.break_count].line = line;
    g_dbg.break_count++;
    xdbg_mutex_unlock(&g_dbg.lock);
    xdbg_send(fd, "OK break\nEND\n");
}

static void xdbg_cmd_clear(SOCKET_T fd) {
    xdbg_mutex_lock(&g_dbg.lock);
    g_dbg.break_count = 0;
    xdbg_mutex_unlock(&g_dbg.lock);
    xdbg_send(fd, "OK clear\nEND\n");
}

static void xdbg_cmd_pause(SOCKET_T fd, const char* id) {
    int i, tid = atoi(id ? id : "0");
    xdbg_mutex_lock(&g_dbg.lock);
    for (i = 0; i < XDBG_MAX_STATES; i++) {
        XDbgState* st = &g_dbg.states[i];
        if (!st->active) continue;
        if ((id && strcmp(id, "all") == 0) || st->thread_id == tid) st->pause_requested = 1;
    }
    xdbg_mutex_unlock(&g_dbg.lock);
    xdbg_send(fd, "OK pause\nEND\n");
}

static void xdbg_continue_locked(XDbgState* st, XDbgStep mode) {
    st->step_mode = mode;
    st->stopped = 0;
    st->stop_L = NULL;
    st->req = XDBG_REQ_NONE;
}

static void xdbg_cmd_continue(SOCKET_T fd, const char* id, XDbgStep mode) {
    int i, tid = atoi(id ? id : "0");
    xdbg_mutex_lock(&g_dbg.lock);
    for (i = 0; i < XDBG_MAX_STATES; i++) {
        XDbgState* st = &g_dbg.states[i];
        if (!st->active) continue;
        if ((id && strcmp(id, "all") == 0) || st->thread_id == tid) xdbg_continue_locked(st, mode);
    }
    xdbg_cond_signal(&g_dbg.cond);
    xdbg_mutex_unlock(&g_dbg.lock);
    xdbg_send(fd, "OK continue\nEND\n");
}

static void xdbg_cmd_request(SOCKET_T fd, int tid, XDbgReq req, int frame) {
    XDbgState* st;
    xdbg_mutex_lock(&g_dbg.lock);
    st = xdbg_find_state_locked(NULL, tid);
    if (!st || !st->stopped) {
        xdbg_mutex_unlock(&g_dbg.lock);
        xdbg_send(fd, "ERR thread not stopped\nEND\n");
        return;
    }
    st->req = req;
    st->req_frame = frame;
    st->response[0] = '\0';
    xdbg_cond_signal(&g_dbg.cond);
    while (g_dbg.running && st->active && st->req != XDBG_REQ_NONE) {
        xdbg_cond_wait(&g_dbg.cond, &g_dbg.lock);
    }
    xdbg_send(fd, "%s", st->response[0] ? st->response : "ERR no response\nEND\n");
    xdbg_mutex_unlock(&g_dbg.lock);
}

static void xdbg_help(SOCKET_T fd) {
    xdbg_send(fd,
        "OK help\n"
        "threads\n"
        "break <file> <line>\n"
        "clear\n"
        "pause <thread|all>\n"
        "continue <thread|all>\n"
        "step <thread> into|over|out\n"
        "stack <thread>\n"
        "locals <thread> <frame>\n"
        "END\n");
}

static int xdbg_handle_line(SOCKET_T fd, char* line) {
    char* cmd = strtok(line, " \t");
    if (!cmd || !*cmd) return 1;
    if (strcmp(cmd, "quit") == 0) return 0;
    if (strcmp(cmd, "help") == 0) xdbg_help(fd);
    else if (strcmp(cmd, "threads") == 0) xdbg_cmd_threads(fd);
    else if (strcmp(cmd, "clear") == 0) xdbg_cmd_clear(fd);
    else if (strcmp(cmd, "break") == 0) {
        char* file = strtok(NULL, " \t");
        char* line_s = strtok(NULL, " \t");
        if (!file || !line_s) xdbg_send(fd, "ERR usage: break <file> <line>\nEND\n");
        else xdbg_cmd_break(fd, file, atoi(line_s));
    } else if (strcmp(cmd, "pause") == 0) {
        xdbg_cmd_pause(fd, strtok(NULL, " \t"));
    } else if (strcmp(cmd, "continue") == 0) {
        xdbg_cmd_continue(fd, strtok(NULL, " \t"), XDBG_STEP_NONE);
    } else if (strcmp(cmd, "step") == 0) {
        char* id = strtok(NULL, " \t");
        char* kind = strtok(NULL, " \t");
        XDbgStep mode = XDBG_STEP_INTO;
        if (kind && strcmp(kind, "over") == 0) mode = XDBG_STEP_OVER;
        else if (kind && strcmp(kind, "out") == 0) mode = XDBG_STEP_OUT;
        xdbg_cmd_continue(fd, id, mode);
    } else if (strcmp(cmd, "stack") == 0) {
        char* id = strtok(NULL, " \t");
        if (!id) xdbg_send(fd, "ERR usage: stack <thread>\nEND\n");
        else xdbg_cmd_request(fd, atoi(id), XDBG_REQ_STACK, 0);
    } else if (strcmp(cmd, "locals") == 0) {
        char* id = strtok(NULL, " \t");
        char* frame = strtok(NULL, " \t");
        if (!id) xdbg_send(fd, "ERR usage: locals <thread> <frame>\nEND\n");
        else xdbg_cmd_request(fd, atoi(id), XDBG_REQ_LOCALS, frame ? atoi(frame) : 0);
    } else {
        xdbg_send(fd, "ERR unknown command\nEND\n");
    }
    return 1;
}

static void xdbg_client(SOCKET_T fd) {
    char line[XDBG_LINE_SIZE];
    xdbg_send(fd, "OK xnet-xdebug\n");
    xdbg_help(fd);
    while (g_dbg.running && xdbg_readline(fd, line, sizeof(line)) >= 0) {
        if (!xdbg_handle_line(fd, line)) break;
    }
}

#ifdef _WIN32
static unsigned __stdcall xdbg_server_main(void* arg)
#else
static void* xdbg_server_main(void* arg)
#endif
{
    char err[XSOCK_ERR_LEN] = {0};
    (void)arg;
    rpmalloc_thread_initialize();
    socket_init();
    g_dbg.listen_fd = xsock_listen(err, "127.0.0.1", g_dbg.port);
    if (g_dbg.listen_fd == INVALID_SOCKET_VAL) {
        fprintf(stderr, "[xdebug] listen failed: %s\n", err);
        g_dbg.running = 0;
    } else {
        fprintf(stderr, "[xdebug] listening on 127.0.0.1:%d\n", g_dbg.port);
    }
    while (g_dbg.running && g_dbg.listen_fd != INVALID_SOCKET_VAL) {
        SOCKET_T fd = xsock_accept(err, g_dbg.listen_fd, NULL, NULL);
        if (fd == INVALID_SOCKET_VAL) {
            if (g_dbg.running) fprintf(stderr, "[xdebug] accept failed: %s\n", err);
            continue;
        }
        xdbg_client(fd);
        xsock_close(fd);
    }
    if (g_dbg.listen_fd != INVALID_SOCKET_VAL) {
        xsock_close(g_dbg.listen_fd);
        g_dbg.listen_fd = INVALID_SOCKET_VAL;
    }
    socket_cleanup();
    rpmalloc_thread_finalize();
#ifdef _WIN32
    return 0;
#else
    return NULL;
#endif
}

static int xdbg_start_server(const char* port, const char* wait, char* err, int errcap) {
    xdbg_init_sync();
    if (g_dbg.enabled && g_dbg.running) return 1;
    g_dbg.enabled = 1;
    g_dbg.running = 1;
    g_dbg.port = (port && *port) ? atoi(port) : 19090;
    g_dbg.wait_on_attach = xdbg_truthy(wait);
    if (g_dbg.port <= 0) g_dbg.port = 19090;
    g_dbg.listen_fd = INVALID_SOCKET_VAL;
#ifdef _WIN32
    g_dbg.thread = (HANDLE)_beginthreadex(NULL, 0, xdbg_server_main, NULL, 0, NULL);
    if (!g_dbg.thread) g_dbg.running = 0;
    else g_dbg.thread_started = 1;
#else
    if (pthread_create(&g_dbg.thread, NULL, xdbg_server_main, NULL) != 0) g_dbg.running = 0;
    else g_dbg.thread_started = 1;
#endif
    if (!g_dbg.running) {
        g_dbg.enabled = 0;
        if (err && errcap > 0) snprintf(err, (size_t)errcap, "xdebug server start failed");
        return 0;
    }
    return 1;
}

void xdebug_configure(const char* enabled, const char* port, const char* wait) {
    int i;
    if (!xdbg_truthy(enabled)) return;
    if (!xdbg_start_server(port, wait, NULL, 0)) return;
    xdbg_mutex_lock(&g_dbg.lock);
    for (i = 0; i < XDBG_MAX_STATES; i++) {
        if (g_dbg.states[i].active) {
            xdbg_enable_state_locked(&g_dbg.states[i], NULL, g_dbg.wait_on_attach);
        }
    }
    xdbg_mutex_unlock(&g_dbg.lock);
}

void xdebug_shutdown(void) {
    if (!g_dbg.inited || !g_dbg.enabled) return;
    xdbg_mutex_lock(&g_dbg.lock);
    g_dbg.running = 0;
    xdbg_cond_signal(&g_dbg.cond);
    xdbg_mutex_unlock(&g_dbg.lock);
    if (g_dbg.port > 0) {
        char err[XSOCK_ERR_LEN];
        SOCKET_T fd = xsock_tcp_connect(err, "127.0.0.1", g_dbg.port);
        if (fd != INVALID_SOCKET_VAL) xsock_close(fd);
    }
#ifdef _WIN32
    if (g_dbg.thread_started && g_dbg.thread) {
        WaitForSingleObject(g_dbg.thread, INFINITE);
        CloseHandle(g_dbg.thread);
        g_dbg.thread = NULL;
    }
#else
    if (g_dbg.thread_started) pthread_join(g_dbg.thread, NULL);
#endif
    g_dbg.thread_started = 0;
    g_dbg.enabled = 0;
}

void xdebug_attach_state(lua_State* L, int thread_id, const char* script_path) {
    int i;
    XDbgState* slot = NULL;
    if (!L) return;
    xdbg_init_sync();
    xdbg_mutex_lock(&g_dbg.lock);
    slot = xdbg_find_state_locked(L, 0);
    for (i = 0; i < XDBG_MAX_STATES; i++) {
        if (slot) break;
        if (!g_dbg.states[i].active) {
            slot = &g_dbg.states[i];
            break;
        }
    }
    if (slot) {
        memset(slot, 0, sizeof(*slot));
        slot->L = L;
        slot->active = 1;
        slot->thread_id = thread_id;
        slot->pause_requested = g_dbg.wait_on_attach;
        xdbg_path(slot->script, sizeof(slot->script), script_path ? script_path : "");
        xdbg_set_state(L, slot);
        if (g_dbg.enabled && g_dbg.running) {
            xdbg_enable_state_locked(slot, L, g_dbg.wait_on_attach);
            fprintf(stderr, "[xdebug] attached thread %d (%s)\n", thread_id, slot->script);
        }
    }
    xdbg_mutex_unlock(&g_dbg.lock);
}

void xdebug_update_state(lua_State* L) {
    XDbgState* st;
    if (!g_dbg.inited || !g_dbg.enabled || !g_dbg.running || !L) return;
    st = xdbg_state_from_lua(L);
    xdbg_mutex_lock(&g_dbg.lock);
    if (!st || !st->active) st = xdbg_find_state_locked(L, 0);
    if (st && st->active && !st->hook_enabled) {
        xdbg_enable_state_locked(st, L, g_dbg.wait_on_attach);
        fprintf(stderr, "[xdebug] enabled thread %d (%s)\n", st->thread_id, st->script);
    }
    xdbg_mutex_unlock(&g_dbg.lock);
}

void xdebug_detach_state(lua_State* L) {
    XDbgState* st;
    if (!g_dbg.inited || !L) return;
    xdbg_mutex_lock(&g_dbg.lock);
    st = xdbg_find_state_locked(L, 0);
    if (st) {
        lua_sethook(L, NULL, 0, 0);
        xdbg_set_state(L, NULL);
        st->active = 0;
        st->hook_enabled = 0;
        st->stopped = 0;
        st->stop_L = NULL;
        st->req = XDBG_REQ_NONE;
        xdbg_cond_signal(&g_dbg.cond);
    }
    xdbg_mutex_unlock(&g_dbg.lock);
}

int xdebug_start_current(lua_State* L, const char* port, const char* wait,
                         char* err, int errcap) {
    XDbgState* st;
    int tid;
    if (err && errcap > 0) err[0] = '\0';
    if (!L) {
        if (err && errcap > 0) snprintf(err, (size_t)errcap, "missing lua state");
        return 0;
    }
    if (!xdbg_start_server(port, wait, err, errcap)) return 0;

    st = xdbg_state_from_lua(L);
    xdbg_mutex_lock(&g_dbg.lock);
    if (!st || !st->active) st = xdbg_find_state_locked(L, 0);
    if (!st) {
        int i;
        for (i = 0; i < XDBG_MAX_STATES; i++) {
            if (!g_dbg.states[i].active) {
                st = &g_dbg.states[i];
                memset(st, 0, sizeof(*st));
                st->L = L;
                st->active = 1;
                tid = xthread_current_id();
                st->thread_id = tid > 0 ? tid : 0;
                snprintf(st->script, sizeof(st->script), "thread:%d", st->thread_id);
                xdbg_set_state(L, st);
                break;
            }
        }
    }
    if (!st) {
        xdbg_mutex_unlock(&g_dbg.lock);
        if (err && errcap > 0) snprintf(err, (size_t)errcap, "too many debug states");
        return 0;
    }
    xdbg_enable_state_locked(st, L, xdbg_truthy(wait));
    fprintf(stderr, "[xdebug] enabled thread %d (%s)\n", st->thread_id, st->script);
    xdbg_mutex_unlock(&g_dbg.lock);
    return 1;
}

int xdebug_status(int* port) {
    if (port) *port = g_dbg.port;
    return g_dbg.enabled && g_dbg.running;
}

#endif /* XNET_WITH_XDEBUG */
