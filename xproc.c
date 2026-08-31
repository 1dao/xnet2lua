/* xproc.c — spawn a child and return pollable socket fds. See xproc.h. */

#if !defined(_WIN32) && !defined(_GNU_SOURCE)
#define _GNU_SOURCE
#endif

#include "xproc.h"

#include <string.h>
#include <stdio.h>
#include <stdlib.h>
#include <limits.h>
#include <stdint.h>

#ifdef _WIN32

int xproc_supported(void) { return 0; }

int xproc_spawn(const char* const* argv, const xProcSpawnOpts* opts,
                xProcHandles* out, char* err, size_t errlen) {
    (void)argv; (void)opts; (void)out;
    if (err && errlen) {
        snprintf(err, errlen,
                 "xproc is POSIX-only; use the file-staging path on Windows");
    }
    return -1;
}

int xproc_wait(long pid, int nohang, int* exit_code) {
    (void)pid; (void)nohang; (void)exit_code; return -1;
}

int xproc_kill(long pid, int force) { (void)pid; (void)force; return -1; }

#else /* ── POSIX ─────────────────────────────────────────────────────────── */

#include <unistd.h>
#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <sys/socket.h>
#include <sys/wait.h>
#include <sys/types.h>

extern char** environ;

static void set_err(char* err, size_t errlen, const char* what, int e) {
    if (!err || !errlen) return;
    snprintf(err, errlen, "%s: %s", what, strerror(e));
}

/* CLOEXEC matters on every original endpoint: otherwise an unrelated later
 * child can inherit it and keep a data channel alive indefinitely. */
static int set_cloexec_pair(int fds[2]) {
    for (int i = 0; i < 2; i++) {
        int fl = fcntl(fds[i], F_GETFD, 0);
        if (fl == -1 || fcntl(fds[i], F_SETFD, fl | FD_CLOEXEC) == -1) {
            int e = errno;
            close(fds[0]);
            close(fds[1]);
            fds[0] = fds[1] = -1;
            errno = e;
            return -1;
        }
    }
    return 0;
}

/* The exec-status channel is internal and never enters xpoll. */
static int make_pipe(int fds[2]) {
#if defined(__linux__)
    if (pipe2(fds, O_CLOEXEC) == 0) return 0;
    if (errno != ENOSYS && errno != EINVAL) return -1;
#endif
    if (pipe(fds) != 0) return -1;
    return set_cloexec_pair(fds);
}

/* Use Unix stream sockets for the three data channels. The parent endpoints
 * can then use xnet's existing send/recv, epoll/kqueue and io_uring paths with
 * no generic-fd branch inside xchannel. dup2 makes the child endpoints ordinary
 * stdin/stdout/stderr descriptors, so child programs still use read/write. */
static int make_data_channel(int fds[2]) {
#ifdef SOCK_CLOEXEC
    if (socketpair(AF_UNIX, SOCK_STREAM | SOCK_CLOEXEC, 0, fds) == 0) return 0;
    if (errno != EINVAL && errno != EPROTONOSUPPORT) return -1;
#endif
    if (socketpair(AF_UNIX, SOCK_STREAM, 0, fds) != 0) return -1;
    return set_cloexec_pair(fds);
}

static int set_nonblock(int fd) {
    int fl = fcntl(fd, F_GETFL, 0);
    if (fl == -1) return -1;
    return fcntl(fd, F_SETFL, fl | O_NONBLOCK);
}

static void close_if(int* fd) {
    if (*fd >= 0) { close(*fd); *fd = -1; }
}

/* Build the child's environment: ours, with `over` entries replacing same-named
 * keys and appending new ones.
 *
 * Merged rather than replaced because a bare environment has no PATH, and
 * execvp would then fail to find anything not given as an absolute path — while
 * looking, to the caller, exactly like "the binary is missing".
 *
 * Returns a NULL-terminated array the caller frees (one allocation for the
 * vector; the strings are either borrowed from environ/over or malloc'd — so
 * only the vector is freed, and only before exec or in the parent). */
static char** merge_env(const char* const* over) {
    size_t n_env = 0, n_over = 0;
    while (environ[n_env]) n_env++;
    if (over) while (over[n_over]) n_over++;
    if (n_over == 0) return NULL;   /* NULL means "just use environ" */

    char** out = (char**)calloc(n_env + n_over + 1, sizeof(char*));
    if (!out) return NULL;

    size_t n = 0;
    for (size_t i = 0; i < n_env; i++) {
        const char* eq = strchr(environ[i], '=');
        size_t klen = eq ? (size_t)(eq - environ[i]) : strlen(environ[i]);
        int overridden = 0;
        for (size_t j = 0; j < n_over; j++) {
            const char* oeq = strchr(over[j], '=');
            size_t olen = oeq ? (size_t)(oeq - over[j]) : strlen(over[j]);
            if (olen == klen && strncmp(environ[i], over[j], klen) == 0) {
                overridden = 1;
                break;
            }
        }
        if (!overridden) out[n++] = environ[i];
    }
    for (size_t j = 0; j < n_over; j++) out[n++] = (char*)over[j];
    out[n] = NULL;
    return out;
}

static const char* env_get(char* const* envp, const char* key) {
    size_t klen = strlen(key);
    if (!envp) return NULL;
    for (size_t i = 0; envp[i]; i++) {
        if (strncmp(envp[i], key, klen) == 0 && envp[i][klen] == '=')
            return envp[i] + klen + 1;
    }
    return NULL;
}

/* Resolve before fork so the child can use execve with the merged environment
 * without calling allocation-heavy PATH helpers in a multi-threaded process. */
static char* resolve_program(const char* file, char* const* envp, int* err_out) {
    if (!file || !file[0]) {
        if (err_out) *err_out = EINVAL;
        return NULL;
    }
    if (strchr(file, '/')) {
        char* copy = strdup(file);
        if (!copy && err_out) *err_out = ENOMEM;
        return copy;
    }

    const char* path = env_get(envp, "PATH");
    if (!path) path = "/bin:/usr/bin";

    size_t flen = strlen(file);
    if (flen > SIZE_MAX - 2) {
        if (err_out) *err_out = ENAMETOOLONG;
        return NULL;
    }
    int saw_eacces = 0;
    const char* part = path;
    for (;;) {
        const char* colon = strchr(part, ':');
        size_t dlen = colon ? (size_t)(colon - part) : strlen(part);
        if (dlen > SIZE_MAX - flen - 2) {
            if (err_out) *err_out = ENAMETOOLONG;
            return NULL;
        }

        size_t len = dlen + (dlen ? 1u : 0u) + flen + 1u;
        char* candidate = (char*)malloc(len);
        if (!candidate) {
            if (err_out) *err_out = ENOMEM;
            return NULL;
        }
        if (dlen) {
            memcpy(candidate, part, dlen);
            candidate[dlen] = '/';
            memcpy(candidate + dlen + 1, file, flen + 1);
        } else {
            memcpy(candidate, file, flen + 1);
        }

        if (access(candidate, X_OK) == 0) return candidate;
        if (errno == EACCES) saw_eacces = 1;
        free(candidate);

        if (!colon) break;
        part = colon + 1;
    }

    if (err_out) *err_out = saw_eacces ? EACCES : ENOENT;
    return NULL;
}

static void child_fail(int status_fd, int e) {
    ssize_t n;
    do {
        n = write(status_fd, &e, sizeof(e));
    } while (n < 0 && errno == EINTR);
    (void)n;
    _exit(127);
}

static int child_dup_to(int from, int to) {
    if (from != to) return dup2(from, to);
    int fl = fcntl(to, F_GETFD, 0);
    if (fl < 0) return -1;
    return fcntl(to, F_SETFD, fl & ~FD_CLOEXEC);
}

int xproc_supported(void) { return 1; }

int xproc_spawn(const char* const* argv, const xProcSpawnOpts* opts,
                xProcHandles* out, char* err, size_t errlen) {
    xProcSpawnOpts def;
    memset(&def, 0, sizeof(def));
    if (!opts) opts = &def;
    if (!argv || !argv[0] || !argv[0][0] || !out) {
        set_err(err, errlen, "xproc_spawn", EINVAL);
        return -1;
    }

    out->pid = -1;
    out->stdin_fd = out->stdout_fd = out->stderr_fd = -1;

    int has_env_overrides = opts->env && opts->env[0];
    char** envp = merge_env(opts->env);
    if (has_env_overrides && !envp) {
        set_err(err, errlen, "environment", ENOMEM);
        return -1;
    }

    int resolve_errno = 0;
    char* program = resolve_program(argv[0], envp ? envp : environ,
                                    &resolve_errno);
    if (!program) {
        free(envp);
        set_err(err, errlen, argv[0], resolve_errno ? resolve_errno : ENOENT);
        return -1;
    }

    int in_p[2]  = { -1, -1 };
    int out_p[2] = { -1, -1 };
    int err_p[2] = { -1, -1 };
    int exec_p[2] = { -1, -1 };    /* child -> parent errno on exec failure */

    if (make_data_channel(in_p) != 0 ||
        make_data_channel(out_p) != 0 ||
        (!opts->merge_stderr && make_data_channel(err_p) != 0) ||
        make_pipe(exec_p) != 0) {
        int e = errno;
        close_if(&in_p[0]);  close_if(&in_p[1]);
        close_if(&out_p[0]); close_if(&out_p[1]);
        close_if(&err_p[0]); close_if(&err_p[1]);
        close_if(&exec_p[0]); close_if(&exec_p[1]);
        free(program);
        free(envp);
        set_err(err, errlen, "channel", e);
        return -1;
    }

    pid_t pid = fork();
    if (pid < 0) {
        int e = errno;
        free(program);
        free(envp);
        close_if(&in_p[0]);  close_if(&in_p[1]);
        close_if(&out_p[0]); close_if(&out_p[1]);
        close_if(&err_p[0]); close_if(&err_p[1]);
        close_if(&exec_p[0]); close_if(&exec_p[1]);
        set_err(err, errlen, "fork", e);
        return -1;
    }

    if (pid == 0) {
        /* ── child ──────────────────────────────────────────────────────────
         * Only async-signal-safe calls from here to exec: this process shares
         * the parent's address space image, and the parent is multi-threaded,
         * so any lock held by another thread at fork() time is held forever
         * here. dup2/close/chdir/setpgid/execv* are all safe; malloc is not,
         * which is why the environment was built BEFORE the fork.
         */

        /* Own process group, so xproc_kill can take the whole tree. Without it
         * a timed-out `sh -c` dies while the work it started keeps running and
         * keeps the stdio channels open. */
        if (setpgid(0, 0) != 0) child_fail(exec_p[1], errno);

        /* SIG_IGN survives exec. The daemon path sets SIGPIPE to SIG_IGN, and
         * a child that inherits that writes into a closed channel and gets EPIPE
         * from every write instead of dying quietly — git in particular treats
         * that as a hard error. */
        if (signal(SIGPIPE, SIG_DFL) == SIG_ERR)
            child_fail(exec_p[1], errno);

        if (child_dup_to(in_p[0], STDIN_FILENO) < 0)
            child_fail(exec_p[1], errno);
        if (child_dup_to(out_p[1], STDOUT_FILENO) < 0)
            child_fail(exec_p[1], errno);
        if (opts->merge_stderr) {
            if (child_dup_to(out_p[1], STDERR_FILENO) < 0)
                child_fail(exec_p[1], errno);
        } else {
            if (child_dup_to(err_p[1], STDERR_FILENO) < 0)
                child_fail(exec_p[1], errno);
        }

        /* The dup2'd descriptors are now 0/1/2 with CLOEXEC cleared by dup2
         * itself; every original still carries CLOEXEC and closes at exec. */

        if (opts->cwd && opts->cwd[0] && chdir(opts->cwd) != 0) {
            child_fail(exec_p[1], errno);
        }

        execve(program, (char* const*)argv, envp ? envp : environ);
        child_fail(exec_p[1], errno);
    }

    /* ── parent ─────────────────────────────────────────────────────────── */
    free(program);
    free(envp);
    setpgid(pid, pid);          /* race-free: both sides set it */

    close_if(&in_p[0]);         /* child's ends */
    close_if(&out_p[1]);
    close_if(&err_p[1]);
    close_if(&exec_p[1]);

    /* If exec failed the child wrote its errno; if it succeeded the write end
     * closed on exec and we read EOF. Either way this blocks only as long as
     * the exec takes. */
    int child_errno = 0;
    ssize_t got;
    do {
        got = read(exec_p[0], &child_errno, sizeof(child_errno));
    } while (got < 0 && errno == EINTR);
    int status_errno = got < 0 ? errno : 0;
    close_if(&exec_p[0]);

    if (got != 0) {
        if (got != (ssize_t)sizeof(child_errno) || child_errno == 0) {
            child_errno = status_errno ? status_errno : EIO;
            (void)xproc_kill((long)pid, 1);
        }
        int status = 0;
        while (waitpid(pid, &status, 0) < 0 && errno == EINTR) { }
        close_if(&in_p[1]);
        close_if(&out_p[0]);
        close_if(&err_p[0]);
        set_err(err, errlen, argv[0], child_errno);
        return -1;
    }

    if ((in_p[1]  >= 0 && set_nonblock(in_p[1])  != 0) ||
        (out_p[0] >= 0 && set_nonblock(out_p[0]) != 0) ||
        (err_p[0] >= 0 && set_nonblock(err_p[0]) != 0)) {
        int e = errno;
        (void)xproc_kill((long)pid, 1);
        while (waitpid(pid, NULL, 0) < 0 && errno == EINTR) { }
        close_if(&in_p[1]);
        close_if(&out_p[0]);
        close_if(&err_p[0]);
        set_err(err, errlen, "set_nonblock", e);
        return -1;
    }

    out->pid       = (long)pid;
    out->stdin_fd  = in_p[1];
    out->stdout_fd = out_p[0];
    out->stderr_fd = err_p[0];
    return 0;
}

int xproc_wait(long pid, int nohang, int* exit_code) {
    pid_t child = (pid_t)pid;
    if (pid <= 0 || (long)child != pid) {
        errno = EINVAL;
        return -1;
    }
    int status = 0;
    pid_t r;
    do {
        r = waitpid(child, &status, nohang ? WNOHANG : 0);
    } while (r < 0 && errno == EINTR);

    if (r == 0) return 0;                 /* still running */
    if (r < 0)  return -1;

    if (exit_code) {
        if (WIFEXITED(status))        *exit_code = WEXITSTATUS(status);
        /* 128 + N is what a shell reports for a signalled child, and what every
         * caller here already expects to see for a killed process. */
        else if (WIFSIGNALED(status)) *exit_code = 128 + WTERMSIG(status);
        else                          *exit_code = -1;
    }
    return 1;
}

int xproc_kill(long pid, int force) {
    pid_t child = (pid_t)pid;
    if (pid <= 1 || (long)child != pid) {
        errno = EINVAL;
        return -1;
    }
    int sig = force ? SIGKILL : SIGTERM;
    /* Negative pid = the process group, which is why the child called setpgid. */
    if (kill(-child, sig) == 0) return 0;
    /* The group may already be gone while the child itself is still a zombie;
     * fall back to the single process rather than reporting a failure. */
    if (errno == ESRCH && kill(child, sig) == 0) return 0;
    return -1;
}

#endif /* _WIN32 */
