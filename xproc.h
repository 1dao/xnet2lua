#ifndef XPROC_H
#define XPROC_H

#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

/* xproc — spawn a child process and hand back pollable stream-socket fds.
 *
 * This module does NO I/O. It starts the process, returns the parent ends of
 * its stdin/stdout/stderr channels as non-blocking fds, and later reaps it.
 * Each data channel is a POSIX socketpair, so its parent endpoint goes straight
 * through the existing xchannel socket path, including epoll/kqueue, io_uring,
 * framing, buffering and backpressure. The child endpoint is dup2'd onto the
 * usual descriptor and behaves like ordinary redirected stdio.
 *
 *   xproc_spawn(...)                 -> pid + three fds
 *   xnet.attach(stdout_fd, handler)  -> output arrives via on_packet
 *   conn:send_raw(data)              -> feeds stdin, queued and backpressured
 *   conn:close_after_flush("eof")     -> flushes input, then sends EOF
 *   xproc_wait(pid, ...)             -> exit status once the fds report EOF
 *
 * PLATFORM
 * POSIX is the real implementation and the deployment target. On Windows
 * xproc_supported() returns 0 and xproc_spawn() fails. Callers keep their
 * existing file-staging path on Windows; POSIX is the deployment target.
 */

typedef struct {
    long pid;         /* child process id */
    int  stdin_fd;    /* parent channel feeding child stdin,  -1 if absent */
    int  stdout_fd;   /* parent channel reading child stdout, -1 if absent */
    int  stderr_fd;   /* parent channel reading child stderr, -1 if absent */
} xProcHandles;

/* Options for xproc_spawn. Zero-initialise and set what you need. */
typedef struct {
    const char* cwd;            /* run the child here; NULL keeps ours        */
    const char* const* env;     /* NULL-terminated "K=V"; MERGED over ours,
                                   not a replacement — dropping the parent
                                   environment would take PATH with it        */
    int merge_stderr;           /* 1: child's stderr uses the stdout channel */
} xProcSpawnOpts;

/* Is a real implementation available on this platform? */
int xproc_supported(void);

/* Start `argv[0]` with `argv` (NULL-terminated). Returns 0 on success and fills
 * `out`; returns -1 and writes a message into `err` otherwise.
 *
 * A failure to exec is reported HERE, not as a mysterious exit status: the
 * child hands its errno back over a close-on-exec pipe before dying, so
 * "no such file or directory" names the missing binary instead of surfacing as
 * exit code 127 several layers away.
 *
 * All returned fds are non-blocking and close-on-exec. The caller owns them and
 * must close each one (or hand it to a channel, which will).
 */
int xproc_spawn(const char* const* argv, const xProcSpawnOpts* opts,
                xProcHandles* out, char* err, size_t errlen);

/* Reap the child.
 *   nohang != 0 : return 0 immediately when it is still running
 * Returns 1 and sets *exit_code when it has exited, 0 when still running,
 * -1 on error. A child killed by signal N reports 128 + N, matching a shell. */
int xproc_wait(long pid, int nohang, int* exit_code);

/* Signal the child. force == 0 sends SIGTERM, non-zero sends SIGKILL.
 * Targets the child's process GROUP, so a shell's grandchildren go too —
 * without that, killing a timed-out `sh -c "..."` leaves the real work running
 * and still holding the stdio channels open. */
int xproc_kill(long pid, int force);

#define XPROC_ERR_LEN 256

#ifdef __cplusplus
}
#endif
#endif /* XPROC_H */
