#ifndef XDAEMON_H
#define XDAEMON_H

/* Initialise daemon support: install termination-signal handlers, then
** daemonize if (and only if) `daemonize` is nonzero. The caller owns the policy
** of how that flag is derived (e.g. parsing --daemon / DAEMON config), so this
** module stays free of any argument/config dependency.
**
** Handlers (SIGINT/SIGTERM/SIGHUP on POSIX, console-control events on Windows)
** are always installed first -- even in the foreground -- so kill/Ctrl-C during
** startup is caught. The handler only sets an internal stop flag (async-signal
** safe); poll it with xdaemon_should_stop() and unwind through the normal
** teardown chain.
**
** Returns 0 when not requested (signals hooked, stay in foreground) or on
** successful daemonization; -1 on failure (or when daemonization was requested
** on a platform without support). */
int xdaemon_init(int daemonize);

/* Release daemon resources (restore the default signal disposition). */
void xdaemon_uninit(void);

/* Nonzero once a termination signal has been received. */
int xdaemon_should_stop(void);

/* Nonzero if the process successfully daemonized. */
int xdaemon_is_daemon(void);

#endif
