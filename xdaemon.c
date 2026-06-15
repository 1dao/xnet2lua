#include "xdaemon.h"

#include <signal.h>
#include <string.h>

static int g_xdaemon_is_daemon = 0;
/* Set only by the signal handler; read via xdaemon_should_stop(). */
static volatile sig_atomic_t g_stop_requested = 0;

int xdaemon_is_daemon(void) {
    return g_xdaemon_is_daemon;
}

int xdaemon_should_stop(void) {
    return g_stop_requested != 0;
}

/* ---------- termination-signal handling ---------- */

#ifdef _WIN32
#define WIN32_LEAN_AND_MEAN
#include <windows.h>

static BOOL WINAPI xdaemon_ctrl_handler(DWORD type) {
    switch (type) {
    case CTRL_C_EVENT:
    case CTRL_BREAK_EVENT:
    case CTRL_CLOSE_EVENT:
    case CTRL_LOGOFF_EVENT:
    case CTRL_SHUTDOWN_EVENT:
        g_stop_requested = 1;
        return TRUE;
    default:
        return FALSE;
    }
}

static void xdaemon_install_signals(void) {
    SetConsoleCtrlHandler(xdaemon_ctrl_handler, TRUE);
}

static void xdaemon_restore_signals(void) {
    SetConsoleCtrlHandler(xdaemon_ctrl_handler, FALSE);
}
#else

static void xdaemon_signal_handler(int sig) {
    (void)sig;
    g_stop_requested = 1;
}

static void xdaemon_install_signals(void) {
    struct sigaction sa;
    memset(&sa, 0, sizeof(sa));
    sa.sa_handler = xdaemon_signal_handler;
    sigemptyset(&sa.sa_mask);
    sa.sa_flags = 0;   /* no SA_RESTART: let a blocked poll/select return so the
                       ** loop re-checks the stop flag promptly. */
    sigaction(SIGINT, &sa, NULL);
    sigaction(SIGTERM, &sa, NULL);
#ifdef SIGHUP
    sigaction(SIGHUP, &sa, NULL);
#endif
    /* Don't die on writes to a peer that closed during teardown. */
    signal(SIGPIPE, SIG_IGN);
}

static void xdaemon_restore_signals(void) {
    signal(SIGINT, SIG_DFL);
    signal(SIGTERM, SIG_DFL);
#ifdef SIGHUP
    signal(SIGHUP, SIG_DFL);
#endif
    signal(SIGPIPE, SIG_DFL);
}
#endif

/* ---------- init / uninit ---------- */

#if defined(__linux__) && !defined(__ANDROID__)
#include <fcntl.h>
#include <stdlib.h>
#include <sys/types.h>
#include <unistd.h>

int xdaemon_init(int daemonize) {
    /* Hook signals first so a kill/Ctrl-C during startup is caught. */
    xdaemon_install_signals();

    if (!daemonize) {
        return 0;   /* not requested -> success, run in the foreground. */
    }

    pid_t pid = fork();
    if (pid < 0) {
        return -1;
    }
    if (pid > 0) {
        _exit(EXIT_SUCCESS);
    }

    if (setsid() < 0) {
        return -1;
    }

    /* A daemon must not be terminated by SIGHUP; this overrides the handler
    ** installed above. */
    signal(SIGHUP, SIG_IGN);

    pid = fork();
    if (pid < 0) {
        return -1;
    }
    if (pid > 0) {
        _exit(EXIT_SUCCESS);
    }

    int dev_null = open("/dev/null", O_RDWR);
    if (dev_null < 0) {
        return -1;
    }

    if (dup2(dev_null, STDIN_FILENO) < 0 ||
        dup2(dev_null, STDOUT_FILENO) < 0 ||
        dup2(dev_null, STDERR_FILENO) < 0) {
        close(dev_null);
        return -1;
    }

    if (dev_null > STDERR_FILENO) {
        close(dev_null);
    }

    g_xdaemon_is_daemon = 1;
    return 0;
}

#else

int xdaemon_init(int daemonize) {
    /* Hook signals first so a kill/Ctrl-C during startup is caught. */
    xdaemon_install_signals();

    if (!daemonize) {
        return 0;   /* not requested -> success, run in the foreground. */
    }
    return -1;       /* daemonization unsupported on this platform. */
}

#endif

void xdaemon_uninit(void) {
    xdaemon_restore_signals();
}
