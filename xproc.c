/* xproc.c — spawn a child and return pollable socket fds. See xproc.h. */

#if !defined(_WIN32) && !defined(_GNU_SOURCE)
#define _GNU_SOURCE
#endif

#include "xproc.h"
#include "xsock.h"

#include <string.h>
#include <stdio.h>
#include <stdlib.h>
#include <limits.h>
#include <stdint.h>

#ifdef _WIN32

/* ── Windows ──────────────────────────────────────────────────────────────
 *
 * The event loop here is WSAPoll, which only watches sockets, while a child's
 * stdio has to be a pipe: plenty of programs (and the CRT) misbehave when
 * handed a socket as stdin/stdout. So each data channel is two halves joined
 * by a pump thread (the socket pair comes from xsock_socketpair):
 *
 *   child <-> anonymous pipe <-> pump thread <-> loopback socket pair <-> xnet
 *
 * The parent end of the socket pair is what the caller gets, so xnet.attach,
 * framing and backpressure work unchanged. A pump ends when its pipe or socket
 * does and closes the other side, which carries EOF across in both directions.
 *
 * Only the three pipe ends are inherited (PROC_THREAD_ATTRIBUTE_HANDLE_LIST),
 * so a concurrent spawn cannot leak another child's channels into this one.
 * The child runs in its own job object, which is what xproc_kill terminates:
 * the Windows counterpart of signalling the POSIX process group.
 */

#include <process.h>
#include <wchar.h>

#define PUMP_BUF (64 * 1024)

/* Exit codes a POSIX shell reports for SIGTERM / SIGKILL, used for kills. */
#define KILL_TERM_CODE 143
#define KILL_FORCE_CODE 137

typedef struct WinChild {
    DWORD pid;
    HANDLE process;
    HANDLE job;                 /* NULL when job assignment was refused */
    struct WinChild* next;
} WinChild;

static SRWLOCK g_children_lock = SRWLOCK_INIT;
static WinChild* g_children = NULL;

static void set_err_win(char* err, size_t errlen, const char* what, DWORD code) {
    if (!err || !errlen) return;
    wchar_t wmsg[256];
    char msg[512];
    DWORD n = FormatMessageW(FORMAT_MESSAGE_FROM_SYSTEM | FORMAT_MESSAGE_IGNORE_INSERTS,
                             NULL, code, MAKELANGID(LANG_ENGLISH, SUBLANG_DEFAULT),
                             wmsg, (DWORD)(sizeof(wmsg) / sizeof(wmsg[0])), NULL);
    if (!n) n = FormatMessageW(FORMAT_MESSAGE_FROM_SYSTEM | FORMAT_MESSAGE_IGNORE_INSERTS,
                               NULL, code, 0, wmsg, (DWORD)(sizeof(wmsg) / sizeof(wmsg[0])), NULL);
    while (n && (wmsg[n - 1] == L'\r' || wmsg[n - 1] == L'\n' || wmsg[n - 1] == L'.')) wmsg[--n] = 0;
    /* UTF-8, not the ANSI code page: the message ends up in Lua strings. */
    if (!n || !WideCharToMultiByte(CP_UTF8, 0, wmsg, -1, msg, (int)sizeof(msg), NULL, NULL))
        snprintf(msg, sizeof(msg), "error %lu", (unsigned long)code);
    snprintf(err, errlen, "%s: %s", what, msg);
}

static void set_err_msg(char* err, size_t errlen, const char* what, const char* msg) {
    if (err && errlen) snprintf(err, errlen, "%s: %s", what, msg);
}

static wchar_t* utf8_to_wide(const char* s) {
    int n = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, s, -1, NULL, 0);
    if (n <= 0) return NULL;
    wchar_t* w = (wchar_t*)malloc((size_t)n * sizeof(wchar_t));
    if (w && MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, s, -1, w, n) != n) {
        free(w);
        w = NULL;
    }
    return w;
}

/* ── growable wide string ── */
typedef struct { wchar_t* p; size_t len, cap; int oom; } WBuf;

static void wb_putn(WBuf* b, const wchar_t* s, size_t n) {
    if (b->oom) return;
    if (b->len + n + 1 > b->cap) {
        size_t cap = b->cap ? b->cap : 256;
        while (b->len + n + 1 > cap) cap *= 2;
        wchar_t* p = (wchar_t*)realloc(b->p, cap * sizeof(wchar_t));
        if (!p) { b->oom = 1; return; }
        b->p = p;
        b->cap = cap;
    }
    memcpy(b->p + b->len, s, n * sizeof(wchar_t));
    b->len += n;
    b->p[b->len] = 0;
}
static void wb_putc(WBuf* b, wchar_t c) { wb_putn(b, &c, 1); }
static void wb_puts(WBuf* b, const wchar_t* s) { wb_putn(b, s, wcslen(s)); }

/* Quote one argument so CommandLineToArgvW / the MSVC CRT read it back as-is:
 * backslashes are literal except in front of a quote, where they double. */
static void append_arg(WBuf* b, const wchar_t* a) {
    if (a[0] && !wcspbrk(a, L" \t\n\v\"")) { wb_puts(b, a); return; }
    wb_putc(b, L'"');
    for (const wchar_t* p = a;; p++) {
        size_t slashes = 0;
        while (*p == L'\\') { slashes++; p++; }
        if (!*p) {
            for (size_t i = 0; i < slashes * 2; i++) wb_putc(b, L'\\');
            break;
        }
        if (*p == L'"') {
            for (size_t i = 0; i < slashes * 2 + 1; i++) wb_putc(b, L'\\');
        } else {
            for (size_t i = 0; i < slashes; i++) wb_putc(b, L'\\');
        }
        wb_putc(b, *p);
    }
    wb_putc(b, L'"');
}

static size_t key_len(const wchar_t* e) {
    /* Hidden per-drive entries look like "=C:=C:\dir"; their key starts at 1. */
    const wchar_t* eq = wcschr(e + (e[0] == L'=' ? 1 : 0), L'=');
    return eq ? (size_t)(eq - e) : wcslen(e);
}

/* Our environment with `over` merged in (keys are case-insensitive here).
 * Returns a CREATE_UNICODE_ENVIRONMENT block and, via *path_out, the PATH the
 * child will see — used to find the program the same way POSIX does. */
static wchar_t* merge_env_block(const char* const* over, wchar_t** path_out, int* oom) {
    size_t n_over = 0;
    *oom = 0;
    *path_out = NULL;
    if (over) while (over[n_over]) n_over++;
    wchar_t** wover = NULL;
    if (n_over) {
        wover = (wchar_t**)calloc(n_over, sizeof(wchar_t*));
        if (!wover) { *oom = 1; return NULL; }
        for (size_t i = 0; i < n_over; i++) {
            if (!(wover[i] = utf8_to_wide(over[i]))) {
                for (size_t j = 0; j < i; j++) free(wover[j]);
                free(wover);
                return NULL;
            }
        }
    }

    wchar_t* cur = GetEnvironmentStringsW();
    WBuf b = { 0 };
    const wchar_t* path = NULL;
    for (const wchar_t* e = cur; e && *e; e += wcslen(e) + 1) {
        size_t kl = key_len(e);
        int replaced = 0;
        for (size_t i = 0; i < n_over && !replaced; i++)
            replaced = key_len(wover[i]) == kl && _wcsnicmp(wover[i], e, kl) == 0;
        if (replaced) continue;
        if (kl == 4 && _wcsnicmp(e, L"PATH", 4) == 0) path = e + 5;
        wb_puts(&b, e);
        wb_putc(&b, 0);
    }
    for (size_t i = 0; i < n_over; i++) {
        size_t kl = key_len(wover[i]);
        if (kl == 4 && _wcsnicmp(wover[i], L"PATH", 4) == 0) path = wover[i] + 5;
        wb_puts(&b, wover[i]);
        wb_putc(&b, 0);
    }
    wb_putc(&b, 0);
    if (path) {
        *path_out = _wcsdup(path);
        if (!*path_out) b.oom = 1;
    }
    if (cur) FreeEnvironmentStringsW(cur);
    for (size_t i = 0; i < n_over; i++) free(wover[i]);
    free(wover);
    if (b.oom) {
        free(b.p);
        free(*path_out);
        *path_out = NULL;
        *oom = 1;
        return NULL;
    }
    return b.p;
}

static int is_file(const wchar_t* p) {
    DWORD a = GetFileAttributesW(p);
    return a != INVALID_FILE_ATTRIBUTES && !(a & FILE_ATTRIBUTE_DIRECTORY);
}

static const wchar_t* ext_of(const wchar_t* p) {
    const wchar_t* dot = wcsrchr(p, L'.');
    const wchar_t* last_sep = NULL;
    for (const wchar_t* q = wcspbrk(p, L"\\/"); q; q = wcspbrk(q + 1, L"\\/")) last_sep = q;
    return (dot && (!last_sep || dot > last_sep)) ? dot : NULL;
}

/* Try `base` as given, then with .exe / .com when it has no extension. */
static wchar_t* try_candidates(const wchar_t* base) {
    static const wchar_t* exts[] = { L"", L".exe", L".com" };
    int has_ext = ext_of(base) != NULL;
    for (int i = 0; i < 3; i++) {
        if (i > 0 && has_ext) break;
        size_t n = wcslen(base) + wcslen(exts[i]) + 1;
        wchar_t* c = (wchar_t*)malloc(n * sizeof(wchar_t));
        if (!c) return NULL;
        swprintf(c, n, L"%ls%ls", base, exts[i]);
        if (is_file(c)) return c;
        free(c);
    }
    return NULL;
}

/* Resolve argv[0] like the POSIX side: a path is used as given (relative to
 * `cwd` when one is set, matching chdir-before-exec); a bare name is searched
 * on the child's PATH. Only .exe/.com are run directly; a batch file needs
 * cmd.exe, whose argument quoting differs, so it is refused with a hint. */
static wchar_t* resolve_program_w(const wchar_t* file, const wchar_t* cwd,
                                  const wchar_t* path, char* err, size_t errlen,
                                  const char* name) {
    wchar_t* found = NULL;
    if (wcspbrk(file, L"\\/:")) {
        int absolute = file[0] == L'\\' || file[0] == L'/' || (file[0] && file[1] == L':');
        if (!absolute && cwd && cwd[0]) {
            size_t n = wcslen(cwd) + wcslen(file) + 2;
            wchar_t* joined = (wchar_t*)malloc(n * sizeof(wchar_t));
            if (joined) {
                swprintf(joined, n, L"%ls\\%ls", cwd, file);
                found = try_candidates(joined);
                free(joined);
            }
        } else {
            found = try_candidates(file);
        }
    } else if (path) {
        const wchar_t* part = path;
        while (!found) {
            const wchar_t* semi = wcschr(part, L';');
            size_t dl = semi ? (size_t)(semi - part) : wcslen(part);
            if (dl) {
                size_t n = dl + wcslen(file) + 2;
                wchar_t* c = (wchar_t*)malloc(n * sizeof(wchar_t));
                if (!c) break;
                swprintf(c, n, L"%.*ls\\%ls", (int)dl, part, file);
                found = try_candidates(c);
                free(c);
            }
            if (!semi) break;
            part = semi + 1;
        }
    }
    if (!found) {
        set_err_msg(err, errlen, name, "No such file or directory");
        return NULL;
    }
    const wchar_t* ext = ext_of(found);
    if (ext && (_wcsicmp(ext, L".bat") == 0 || _wcsicmp(ext, L".cmd") == 0)) {
        free(found);
        set_err_msg(err, errlen, name,
                    "is a batch file; run it through cmd.exe /d /c instead");
        return NULL;
    }
    return found;
}

/* ── socket pair ── */

static int ensure_winsock(void) {
    static volatile LONG done = 0;
    if (InterlockedCompareExchange(&done, 0, 0)) return 0;
    WSADATA wsa;
    if (WSAStartup(MAKEWORD(2, 2), &wsa) != 0) return -1;   /* refcounted; never cleaned */
    InterlockedExchange(&done, 1);
    return 0;
}

/* ── pumps ── */

typedef struct {
    HANDLE pipe;        /* our end of the child's pipe */
    SOCKET sock;        /* bridge end of the socket pair (blocking) */
    HANDLE process;     /* stdin pump only: stop when the child is gone */
    int to_child;
    char buf[PUMP_BUF];
} Pump;

static int send_all(SOCKET s, const char* p, int n) {
    while (n > 0) {
        int w = send(s, p, n, 0);
        if (w <= 0) return -1;
        p += w;
        n -= w;
    }
    return 0;
}

static unsigned __stdcall pump_main(void* arg) {
    Pump* pm = (Pump*)arg;
    if (pm->to_child) {
        /* socket -> pipe. Poll with a timeout so a child that exits without
         * reading does not strand this thread until the caller closes stdin. */
        for (;;) {
            fd_set rd;
            FD_ZERO(&rd);
            FD_SET(pm->sock, &rd);
            struct timeval tv = { 0, 200 * 1000 };
            int r = select(0, &rd, NULL, NULL, &tv);
            if (r < 0) break;
            if (r == 0) {
                if (WaitForSingleObject(pm->process, 0) == WAIT_OBJECT_0) break;
                continue;
            }
            int n = recv(pm->sock, pm->buf, PUMP_BUF, 0);
            if (n <= 0) break;
            const char* p = pm->buf;
            while (n > 0) {
                DWORD w = 0;
                if (!WriteFile(pm->pipe, p, (DWORD)n, &w, NULL) || w == 0) goto done;
                p += w;
                n -= (int)w;
            }
        }
    } else {
        /* pipe -> socket. ReadFile fails with ERROR_BROKEN_PIPE once every
         * writer (the child and anything it passed the handle to) is gone. */
        for (;;) {
            DWORD n = 0;
            if (!ReadFile(pm->pipe, pm->buf, PUMP_BUF, &n, NULL) || n == 0) break;
            if (send_all(pm->sock, pm->buf, (int)n) != 0) break;
        }
        shutdown(pm->sock, SD_SEND);
    }
done:
    CloseHandle(pm->pipe);         /* child sees EOF on stdin / a failed write */
    closesocket(pm->sock);
    if (pm->process) CloseHandle(pm->process);
    free(pm);
    return 0;
}

static int start_pump(HANDLE pipe, SOCKET sock, HANDLE process, int to_child) {
    Pump* pm = (Pump*)malloc(sizeof(Pump));
    if (!pm) return -1;
    pm->pipe = pipe;
    pm->sock = sock;
    pm->process = NULL;
    pm->to_child = to_child;
    if (process && !DuplicateHandle(GetCurrentProcess(), process, GetCurrentProcess(),
                                    &pm->process, SYNCHRONIZE, FALSE, 0)) {
        free(pm);
        return -1;
    }
    uintptr_t th = _beginthreadex(NULL, 64 * 1024, pump_main, pm, 0, NULL);
    if (!th) {
        if (pm->process) CloseHandle(pm->process);
        free(pm);
        return -1;
    }
    CloseHandle((HANDLE)th);
    return 0;
}

/* ── channel = pipe for the child + socket pair for us ── */

typedef struct {
    HANDLE child;       /* inheritable pipe end given to the child */
    HANDLE ours;        /* our pipe end, owned by the pump once started */
    SOCKET parent;      /* returned to the caller */
    SOCKET bridge;      /* owned by the pump once started */
} Chan;

static void chan_init(Chan* c) {
    c->child = c->ours = NULL;
    c->parent = c->bridge = INVALID_SOCKET;
}

static void chan_close(Chan* c) {
    if (c->child) CloseHandle(c->child);
    if (c->ours) CloseHandle(c->ours);
    if (c->parent != INVALID_SOCKET) closesocket(c->parent);
    if (c->bridge != INVALID_SOCKET) closesocket(c->bridge);
    chan_init(c);
}

static int chan_open(Chan* c, int to_child) {
    SECURITY_ATTRIBUTES sa = { sizeof(sa), NULL, FALSE };
    HANDLE rd = NULL, wr = NULL;
    SOCKET_T pair[2];
    chan_init(c);
    if (!CreatePipe(&rd, &wr, &sa, PUMP_BUF)) return -1;
    c->child = to_child ? rd : wr;
    c->ours = to_child ? wr : rd;
    /* Blocking pair: the bridge end is read/written by the pump thread. */
    if (!SetHandleInformation(c->child, HANDLE_FLAG_INHERIT, HANDLE_FLAG_INHERIT) ||
        xsock_socketpair(NULL, pair) != XSOCK_OK) {
        DWORD e = GetLastError();
        if (!e) e = (DWORD)WSAGetLastError();
        chan_close(c);
        SetLastError(e);
        return -1;
    }
    c->parent = pair[0];
    c->bridge = pair[1];
    return 0;
}

static void register_child(WinChild* ch) {
    AcquireSRWLockExclusive(&g_children_lock);
    ch->next = g_children;
    g_children = ch;
    ReleaseSRWLockExclusive(&g_children_lock);
}

/* Find the record for `pid`; with remove != 0 it is also unlinked. */
static WinChild* find_child(DWORD pid, int remove) {
    AcquireSRWLockExclusive(&g_children_lock);
    WinChild** pp = &g_children;
    while (*pp && (*pp)->pid != pid) pp = &(*pp)->next;
    WinChild* ch = *pp;
    if (ch && remove) *pp = ch->next;
    ReleaseSRWLockExclusive(&g_children_lock);
    return ch;
}

int xproc_supported(void) { return 1; }

int xproc_spawn(const char* const* argv, const xProcSpawnOpts* opts,
                xProcHandles* out, char* err, size_t errlen) {
    xProcSpawnOpts def;
    memset(&def, 0, sizeof(def));
    if (!opts) opts = &def;
    if (!argv || !argv[0] || !argv[0][0] || !out) {
        set_err_msg(err, errlen, "xproc_spawn", "invalid argument");
        return -1;
    }
    out->pid = -1;
    out->stdin_fd = out->stdout_fd = out->stderr_fd = -1;
    if (ensure_winsock() != 0) {
        set_err_win(err, errlen, "WSAStartup", (DWORD)WSAGetLastError());
        return -1;
    }

    int rc = -1, oom = 0;
    wchar_t *wcwd = NULL, *wfile = NULL, *program = NULL, *path = NULL, *envb = NULL;
    WBuf cmd = { 0 };
    Chan in, o, e;
    chan_init(&in); chan_init(&o); chan_init(&e);
    LPPROC_THREAD_ATTRIBUTE_LIST attrs = NULL;
    int attrs_ready = 0;
    PROCESS_INFORMATION pi;
    memset(&pi, 0, sizeof(pi));
    HANDLE job = NULL;
    WinChild* rec = NULL;
    HANDLE inherit[3];
    DWORD n_inherit = 0;
    SIZE_T attr_size = 0;
    STARTUPINFOEXW si;
    DWORD flags;
    u_long nb = 1;

    if (opts->cwd && opts->cwd[0] && !(wcwd = utf8_to_wide(opts->cwd))) {
        set_err_msg(err, errlen, "cwd", "not valid UTF-8");
        goto out;
    }
    if (!(envb = merge_env_block(opts->env, &path, &oom))) {
        set_err_msg(err, errlen, "environment", oom ? "out of memory" : "not valid UTF-8");
        goto out;
    }
    if (!(wfile = utf8_to_wide(argv[0]))) {
        set_err_msg(err, errlen, argv[0], "not valid UTF-8");
        goto out;
    }
    if (!(program = resolve_program_w(wfile, wcwd, path, err, errlen, argv[0]))) goto out;

    for (size_t i = 0; argv[i]; i++) {
        wchar_t* w = utf8_to_wide(argv[i]);
        if (!w) { set_err_msg(err, errlen, "argv", "not valid UTF-8"); goto out; }
        if (i) wb_putc(&cmd, L' ');
        append_arg(&cmd, w);
        free(w);
    }
    if (cmd.oom || cmd.len >= 32767) {
        set_err_msg(err, errlen, "argv", cmd.oom ? "out of memory" : "command line too long");
        goto out;
    }

    if (chan_open(&in, 1) != 0 || chan_open(&o, 0) != 0 ||
        (!opts->merge_stderr && chan_open(&e, 0) != 0)) {
        set_err_win(err, errlen, "channel", GetLastError());
        goto out;
    }

    inherit[n_inherit++] = in.child;
    inherit[n_inherit++] = o.child;
    if (!opts->merge_stderr) inherit[n_inherit++] = e.child;

    InitializeProcThreadAttributeList(NULL, 1, 0, &attr_size);
    attrs = (LPPROC_THREAD_ATTRIBUTE_LIST)malloc(attr_size);
    if (!attrs || !InitializeProcThreadAttributeList(attrs, 1, 0, &attr_size)) {
        set_err_win(err, errlen, "attributes", GetLastError());
        goto out;
    }
    attrs_ready = 1;
    if (!UpdateProcThreadAttribute(attrs, 0, PROC_THREAD_ATTRIBUTE_HANDLE_LIST,
                                   inherit, n_inherit * sizeof(HANDLE), NULL, NULL)) {
        set_err_win(err, errlen, "attributes", GetLastError());
        goto out;
    }

    memset(&si, 0, sizeof(si));
    si.StartupInfo.cb = sizeof(si);
    si.StartupInfo.dwFlags = STARTF_USESTDHANDLES;
    si.StartupInfo.hStdInput = in.child;
    si.StartupInfo.hStdOutput = o.child;
    si.StartupInfo.hStdError = opts->merge_stderr ? o.child : e.child;
    si.lpAttributeList = attrs;

    /* Suspended until it is inside the job, so nothing it starts can escape.
     * CREATE_NO_WINDOW keeps a console child from flashing a window when the
     * parent (a GUI, say) has no console of its own. */
    flags = CREATE_UNICODE_ENVIRONMENT | CREATE_SUSPENDED |
            EXTENDED_STARTUPINFO_PRESENT | CREATE_NO_WINDOW;
    if (!CreateProcessW(program, cmd.p, NULL, NULL, TRUE, flags, envb, wcwd,
                        &si.StartupInfo, &pi)) {
        set_err_win(err, errlen, argv[0], GetLastError());
        goto out;
    }

    job = CreateJobObjectW(NULL, NULL);
    if (job && !AssignProcessToJobObject(job, pi.hProcess)) {
        CloseHandle(job);          /* e.g. an enclosing job that forbids nesting */
        job = NULL;
    }
    if (!(rec = (WinChild*)calloc(1, sizeof(WinChild)))) {
        set_err_msg(err, errlen, "xproc_spawn", "out of memory");
        goto kill_child;
    }

    /* The child owns its ends now; ours must go or EOF never arrives. */
    CloseHandle(in.child); in.child = NULL;
    CloseHandle(o.child); o.child = NULL;
    if (e.child) { CloseHandle(e.child); e.child = NULL; }

    if (start_pump(in.ours, in.bridge, pi.hProcess, 1) != 0) goto pump_fail;
    in.ours = NULL; in.bridge = INVALID_SOCKET;
    if (start_pump(o.ours, o.bridge, NULL, 0) != 0) goto pump_fail;
    o.ours = NULL; o.bridge = INVALID_SOCKET;
    if (!opts->merge_stderr) {
        if (start_pump(e.ours, e.bridge, NULL, 0) != 0) goto pump_fail;
        e.ours = NULL; e.bridge = INVALID_SOCKET;
    }

    rec->pid = pi.dwProcessId;
    rec->process = pi.hProcess;
    rec->job = job;
    register_child(rec);
    ResumeThread(pi.hThread);
    pi.hProcess = NULL;
    job = NULL;
    rec = NULL;

    ioctlsocket(in.parent, FIONBIO, &nb);
    ioctlsocket(o.parent, FIONBIO, &nb);
    if (e.parent != INVALID_SOCKET) ioctlsocket(e.parent, FIONBIO, &nb);
    /* Socket handles fit in 32 bits (they are kernel handles). */
    out->pid = (long)pi.dwProcessId;
    out->stdin_fd = (int)in.parent;  in.parent = INVALID_SOCKET;
    out->stdout_fd = (int)o.parent;  o.parent = INVALID_SOCKET;
    if (e.parent != INVALID_SOCKET) { out->stderr_fd = (int)e.parent; e.parent = INVALID_SOCKET; }
    rc = 0;
    goto out;

pump_fail:
    set_err_win(err, errlen, "pump thread", GetLastError());
kill_child:
    if (job) TerminateJobObject(job, KILL_FORCE_CODE);
    else TerminateProcess(pi.hProcess, KILL_FORCE_CODE);
    ResumeThread(pi.hThread);
    WaitForSingleObject(pi.hProcess, 5000);

out:
    if (pi.hThread) CloseHandle(pi.hThread);
    if (pi.hProcess) CloseHandle(pi.hProcess);
    if (job) CloseHandle(job);
    free(rec);
    if (attrs_ready) DeleteProcThreadAttributeList(attrs);
    free(attrs);
    chan_close(&in);
    chan_close(&o);
    chan_close(&e);
    free(cmd.p);
    free(envb);
    free(path);
    free(program);
    free(wfile);
    free(wcwd);
    return rc;
}

int xproc_wait(long pid, int nohang, int* exit_code) {
    if (pid <= 0) return -1;
    WinChild* ch = find_child((DWORD)pid, 0);
    if (!ch) return -1;
    DWORD r = WaitForSingleObject(ch->process, nohang ? 0 : INFINITE);
    if (r == WAIT_TIMEOUT) return 0;
    if (r != WAIT_OBJECT_0) return -1;
    DWORD code = 0;
    if (!GetExitCodeProcess(ch->process, &code)) return -1;
    /* Reap once: a second waiter on the same pid finds no record, as on POSIX. */
    if (find_child((DWORD)pid, 1) != ch) return -1;
    if (exit_code) *exit_code = (int)code;
    CloseHandle(ch->process);
    if (ch->job) CloseHandle(ch->job);
    free(ch);
    return 1;
}

int xproc_kill(long pid, int force) {
    if (pid <= 1) return -1;
    AcquireSRWLockShared(&g_children_lock);
    WinChild* ch = g_children;
    while (ch && ch->pid != (DWORD)pid) ch = ch->next;
    int rc = -1;
    if (ch) {
        UINT code = force ? KILL_FORCE_CODE : KILL_TERM_CODE;
        /* Windows has no SIGTERM for arbitrary processes; both end the tree. */
        if (WaitForSingleObject(ch->process, 0) == WAIT_OBJECT_0) rc = 0;
        else if (ch->job) rc = TerminateJobObject(ch->job, code) ? 0 : -1;
        else rc = TerminateProcess(ch->process, code) ? 0 : -1;
    }
    ReleaseSRWLockShared(&g_children_lock);
    return rc;
}

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
    /* close-on-exec on both ends; errno is preserved on failure */
    return xsock_socketpair(NULL, fds) == XSOCK_OK ? 0 : -1;
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
