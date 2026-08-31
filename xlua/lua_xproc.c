/* lua_xproc.c — Lua binding for xproc (spawn a child, get socketpair fds).
**
** The module is deliberately thin: spawn, wait, kill, and nothing else. Byte
** movement belongs to xnet.attach, which puts a child's fd on the event loop
** as a regular socket channel with the usual buffering and backpressure.
** Adding read/write here would fork that machinery for no gain.
**
**   local xproc = require('xproc')
**   if not xproc.supported() then ... end          -- 0 on Windows
**
**   local h, err = xproc.spawn({
**       argv = { 'git', 'upload-pack', '--stateless-rpc', '.' },
**       cwd  = repo_dir,
**       env  = { GIT_PROTOCOL = 'version=2' },      -- merged over ours
**       merge_stderr = false,
**   })
**   -- h = { pid = , stdin_fd = , stdout_fd = , stderr_fd = }
**
**   local out = xnet.attach(h.stdout_fd, handler)
**   local inp = xnet.attach(h.stdin_fd,  { })
**   inp:send_raw(body); inp:close_after_flush('eof')
**
**   local exited, code = xproc.wait(h.pid, true)    -- true = don't block
*/

#include "xlua.h"
#include "xproc.h"

#include <string.h>
#include <stdlib.h>
#include <stdint.h>

/* Read spec.argv into a NULL-terminated char* array. The strings stay owned by
** Lua for as long as the table is on the stack, which covers the spawn call. */
static const char** read_argv(lua_State* L, int tbl) {
    lua_getfield(L, tbl, "argv");
    if (!lua_istable(L, -1)) {
        lua_pop(L, 1);
        return NULL;
    }
    lua_Integer n = (lua_Integer)lua_rawlen(L, -1);
    if (n <= 0 || n > 1024) {
        lua_pop(L, 1);
        return NULL;
    }

    const char** argv = (const char**)calloc((size_t)n + 1, sizeof(char*));
    if (!argv) { lua_pop(L, 1); return NULL; }

    for (lua_Integer i = 1; i <= n; i++) {
        lua_rawgeti(L, -1, i);
        size_t len = 0;
        const char* s = lua_type(L, -1) == LUA_TSTRING
            ? lua_tolstring(L, -1, &len)
            : NULL;
        if (!s || memchr(s, '\0', len) != NULL) {
            lua_pop(L, 2);
            free(argv);
            return NULL;
        }
        argv[i - 1] = s;
        lua_pop(L, 1);
    }
    lua_pop(L, 1);            /* the argv table; strings stay reachable via it */
    return argv;
}

static void free_env(char** env, size_t n) {
    if (!env) return;
    for (size_t i = 0; i < n; i++) free(env[i]);
    free(env);
}

/* spec.env is a { KEY = "value" } map; the child wants { "KEY=value", NULL }.
** The joined strings are malloc'd here and freed by the caller. */
static char** read_env(lua_State* L, int tbl, size_t* count_out, int* ok_out) {
    *count_out = 0;
    *ok_out = 1;
    lua_getfield(L, tbl, "env");
    if (lua_isnil(L, -1)) { lua_pop(L, 1); return NULL; }
    if (!lua_istable(L, -1)) {
        lua_pop(L, 1);
        *ok_out = 0;
        return NULL;
    }

    size_t cap = 16, n = 0;
    char** env = (char**)calloc(cap + 1, sizeof(char*));
    if (!env) {
        lua_pop(L, 1);
        *ok_out = 0;
        return NULL;
    }

    lua_pushnil(L);
    while (lua_next(L, -2) != 0) {
        size_t klen = 0, vlen = 0;
        const char* k = lua_type(L, -2) == LUA_TSTRING
            ? lua_tolstring(L, -2, &klen) : NULL;
        const char* v = lua_type(L, -1) == LUA_TSTRING
            ? lua_tolstring(L, -1, &vlen) : NULL;
        if (!k || !v || klen == 0 || memchr(k, '=', klen) != NULL ||
            memchr(k, '\0', klen) != NULL || memchr(v, '\0', vlen) != NULL ||
            klen > SIZE_MAX - vlen - 2) {
            lua_pop(L, 2);
            *ok_out = 0;
            goto fail;
        }

        if (n == cap) {
            size_t ncap = cap * 2;
            char** grown = (char**)realloc(env, (ncap + 1) * sizeof(char*));
            if (!grown) {
                lua_pop(L, 2);
                *ok_out = 0;
                goto fail;
            }
            env = grown;
            cap = ncap;
        }

        size_t len = klen + vlen + 2;
        char* entry = (char*)malloc(len);
        if (!entry) {
            lua_pop(L, 2);
            *ok_out = 0;
            goto fail;
        }
        memcpy(entry, k, klen);
        entry[klen] = '=';
        memcpy(entry + klen + 1, v, vlen);
        entry[len - 1] = '\0';
        env[n++] = entry;
        lua_pop(L, 1);
    }
    env[n] = NULL;
    lua_pop(L, 1);            /* the env table */
    *count_out = n;
    return env;

fail:
    lua_pop(L, 1);            /* the env table */
    free_env(env, n);
    return NULL;
}

static int l_xproc_supported(lua_State* L) {
    lua_pushboolean(L, xproc_supported());
    return 1;
}

static int l_xproc_spawn(lua_State* L) {
    luaL_checktype(L, 1, LUA_TTABLE);

    const char** argv = read_argv(L, 1);
    if (!argv) {
        lua_pushnil(L);
        lua_pushstring(L, "spawn: argv must be a non-empty array of strings");
        return 2;
    }

    size_t env_n = 0;
    int env_ok = 1;
    char** env = read_env(L, 1, &env_n, &env_ok);
    if (!env_ok) {
        free(argv);
        lua_pushnil(L);
        lua_pushstring(L, "spawn: env must be a string-to-string map with valid keys");
        return 2;
    }

    xProcSpawnOpts opts;
    memset(&opts, 0, sizeof(opts));

    lua_getfield(L, 1, "cwd");
    if (!lua_isnil(L, -1) && lua_type(L, -1) != LUA_TSTRING) {
        lua_pop(L, 1);
        free(argv);
        free_env(env, env_n);
        lua_pushnil(L);
        lua_pushstring(L, "spawn: cwd must be a string");
        return 2;
    }
    size_t cwd_len = 0;
    opts.cwd = lua_tolstring(L, -1, &cwd_len); /* stays alive until we pop */
    if (opts.cwd && memchr(opts.cwd, '\0', cwd_len) != NULL) {
        lua_pop(L, 1);
        free(argv);
        free_env(env, env_n);
        lua_pushnil(L);
        lua_pushstring(L, "spawn: cwd contains a NUL byte");
        return 2;
    }

    lua_getfield(L, 1, "merge_stderr");
    opts.merge_stderr = lua_toboolean(L, -1);
    lua_pop(L, 1);

    opts.env = (const char* const*)env;

    xProcHandles h;
    memset(&h, 0, sizeof(h));
    char err[XPROC_ERR_LEN] = { 0 };
    int rc = xproc_spawn(argv, &opts, &h, err, sizeof(err));

    lua_pop(L, 1);                            /* cwd */
    free(argv);
    free_env(env, env_n);

    if (rc != 0) {
        lua_pushnil(L);
        lua_pushstring(L, err[0] ? err : "spawn failed");
        return 2;
    }

    lua_newtable(L);
    lua_pushinteger(L, (lua_Integer)h.pid);       lua_setfield(L, -2, "pid");
    lua_pushinteger(L, (lua_Integer)h.stdin_fd);  lua_setfield(L, -2, "stdin_fd");
    lua_pushinteger(L, (lua_Integer)h.stdout_fd); lua_setfield(L, -2, "stdout_fd");
    lua_pushinteger(L, (lua_Integer)h.stderr_fd); lua_setfield(L, -2, "stderr_fd");
    return 1;
}

/* xproc.wait(pid [, nohang]) -> exited(boolean), exit_code
** exited=false with no error means "still running" (only possible with nohang). */
static int l_xproc_wait(lua_State* L) {
    lua_Integer pid_arg = luaL_checkinteger(L, 1);
    long pid = (long)pid_arg;
    luaL_argcheck(L, (lua_Integer)pid == pid_arg, 1, "pid is out of range");
    luaL_argcheck(L, pid > 0, 1, "pid must be positive");
    int nohang = lua_toboolean(L, 2);
    int code = -1;
    int rc = xproc_wait(pid, nohang, &code);
    if (rc < 0) {
        lua_pushnil(L);
        lua_pushstring(L, "wait failed");
        return 2;
    }
    lua_pushboolean(L, rc == 1);
    lua_pushinteger(L, rc == 1 ? code : -1);
    return 2;
}

static int l_xproc_kill(lua_State* L) {
    lua_Integer pid_arg = luaL_checkinteger(L, 1);
    long pid = (long)pid_arg;
    luaL_argcheck(L, (lua_Integer)pid == pid_arg, 1, "pid is out of range");
    luaL_argcheck(L, pid > 1, 1, "pid must be greater than 1");
    int force = lua_toboolean(L, 2);
    lua_pushboolean(L, xproc_kill(pid, force) == 0);
    return 1;
}

static const luaL_Reg xproc_funcs[] = {
    { "supported", l_xproc_supported },
    { "spawn",     l_xproc_spawn },
    { "wait",      l_xproc_wait },
    { "kill",      l_xproc_kill },
    { NULL, NULL }
};

LUALIB_API int luaopen_xproc(lua_State* L) {
    luaL_newlib(L, xproc_funcs);
    return 1;
}
