/* lua_xwatch.c - recursive change notification for one directory tree.
**
**   local w = xwatch.open(root [, { skip_hidden = true }]) -> watcher | nil, err
**   w:read([timeout_ms]) -> paths, structural, overflow | nil, err
**   w:close()
**   xwatch.backend -> 'win32' | 'inotify' | 'fsevents' | nil (unsupported)
**
** read() returns what changed since the previous call without blocking, or
** waits up to timeout_ms for the first change. A change that completed
** before read() was called is always included. `paths` lists changed paths
** relative to root with '/' separators; one path may repeat. `structural` is
** true when anything was created, removed or renamed (a directory event
** names only the directory, not the files below it). `overflow` is true when
** the OS dropped events: the caller must rescan the whole tree. After an
** error the watcher is unusable; close it and rescan.
**
** Backends:
**   Windows  ReadDirectoryChangesW on the root, recursive, overlapped I/O.
**   Linux    inotify, one watch per directory; new directories are added as
**            they appear. Bounded by fs.inotify.max_user_watches: open()
**            fails when the tree needs more. skip_hidden leaves directories
**            whose name starts with '.' (such as .git) unwatched.
**   macOS    FSEvents with file-level events on a private dispatch queue.
**            The kernel hands events to fseventsd some milliseconds late, so
**            each read writes a numbered file in a private $TMPDIR directory
**            that the same stream watches and waits for its event: events
**            arrive in order, so every earlier change has arrived too. When
**            $TMPDIR is on another volume this ordering is not guaranteed and
**            a change made just before read() may show up one read later.
**
** skip_hidden only saves watches; Windows and macOS watch the whole tree, so
** callers still filter the paths they get back. Memory comes from libc, not
** rpmalloc: FSEvents calls back on a GCD thread rpmalloc never saw. */

#include <stdlib.h>
#include <string.h>
#include <stdio.h>
#include <errno.h>
#include <limits.h>

#if defined(__APPLE__)
#include <TargetConditionals.h>
#endif

#if defined(_WIN32)
#define XW_WIN32 1
#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif
#include <windows.h>
#elif defined(__linux__)
#define XW_INOTIFY 1
#include <sys/inotify.h>
#include <sys/stat.h>
#include <dirent.h>
#include <fcntl.h>
#include <poll.h>
#include <unistd.h>
#elif defined(__APPLE__) && !TARGET_OS_IPHONE
#define XW_FSEVENTS 1
#include <CoreServices/CoreServices.h>
#include <dispatch/dispatch.h>
#include <pthread.h>
#include <sys/time.h>
#include <sys/stat.h>
#include <fcntl.h>
#include <unistd.h>
#include <strings.h>
#endif

#if defined(LUA_EMBEDDED)
#include "../3rd/minilua.h"
#else
#include "lua.h"
#include "lauxlib.h"
#include "xlua_compat.h"
#endif

#define XWATCH_META "xwatch.watcher"

/* Queued paths beyond this are dropped and reported as an overflow: a
** checkout touching more files is cheaper to rescan than to replay. */
#define XW_MAX_QUEUED 65536

/* ---- change queue ------------------------------------------------------ */

typedef struct {
    char **items;
    size_t n, cap;
    int structural, overflow;
} xw_changes;

static void xw_push(xw_changes *c, const char *path, size_t len) {
    if (c->overflow) return;
    if (c->n >= XW_MAX_QUEUED) { c->overflow = 1; return; }
    if (c->n == c->cap) {
        size_t cap = c->cap ? c->cap * 2 : 64;
        char **items = (char **)realloc(c->items, cap * sizeof(char *));
        if (!items) { c->overflow = 1; return; }
        c->items = items;
        c->cap = cap;
    }
    char *s = (char *)malloc(len + 1);
    if (!s) { c->overflow = 1; return; }
    memcpy(s, path, len);
    s[len] = '\0';
    for (size_t i = 0; i < len; i++) if (s[i] == '\\') s[i] = '/';
    c->items[c->n++] = s;
}

static void xw_clear(xw_changes *c) {
    for (size_t i = 0; i < c->n; i++) free(c->items[i]);
    free(c->items);
    memset(c, 0, sizeof(*c));
}

/* Push paths, structural, overflow and release the queue. */
static int xw_return(lua_State *L, xw_changes *c) {
    lua_createtable(L, (int)c->n, 0);
    for (size_t i = 0; i < c->n; i++) {
        lua_pushstring(L, c->items[i]);
        lua_rawseti(L, -2, (int)i + 1);
    }
    lua_pushboolean(L, c->structural);
    lua_pushboolean(L, c->overflow);
    xw_clear(c);
    return 3;
}

/* ---- backends ---------------------------------------------------------- */

typedef struct xw_watcher xw_watcher;

#if XW_WIN32

#define XW_FILTER (FILE_NOTIFY_CHANGE_FILE_NAME | FILE_NOTIFY_CHANGE_DIR_NAME | \
                   FILE_NOTIFY_CHANGE_SIZE | FILE_NOTIFY_CHANGE_LAST_WRITE | \
                   FILE_NOTIFY_CHANGE_CREATION)

struct xw_watcher {
    HANDLE dir, event;
    OVERLAPPED ov;
    DWORD *buf;          /* DWORD-aligned, as the API requires */
    DWORD buflen;
    int pending;
};

static DWORD xw_start(xw_watcher *w) {
    memset(&w->ov, 0, sizeof(w->ov));
    w->ov.hEvent = w->event;
    if (!ReadDirectoryChangesW(w->dir, w->buf, w->buflen, TRUE, XW_FILTER, NULL, &w->ov, NULL))
        return GetLastError();
    w->pending = 1;
    return 0;
}

static void xw_close_backend(xw_watcher *w) {
    if (w->pending) {
        DWORD n;
        CancelIoEx(w->dir, &w->ov);
        /* The kernel writes into buf until the cancellation completes. */
        GetOverlappedResult(w->dir, &w->ov, &n, TRUE);
        w->pending = 0;
    }
    if (w->dir != INVALID_HANDLE_VALUE) CloseHandle(w->dir);
    if (w->event) CloseHandle(w->event);
    free(w->buf);
    w->dir = INVALID_HANDLE_VALUE;
    w->event = NULL;
    w->buf = NULL;
}

static int xw_open_backend(xw_watcher *w, const char *root, int skip_hidden, char *err, size_t errcap) {
    (void)skip_hidden;
    w->dir = INVALID_HANDLE_VALUE;
    int wlen = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, root, -1, NULL, 0);
    if (wlen <= 0) { snprintf(err, errcap, "invalid UTF-8 path: %s", root); return -1; }
    WCHAR *wroot = (WCHAR *)malloc((size_t)wlen * sizeof(WCHAR));
    if (!wroot) { snprintf(err, errcap, "out of memory"); return -1; }
    MultiByteToWideChar(CP_UTF8, 0, root, -1, wroot, wlen);
    w->dir = CreateFileW(wroot, FILE_LIST_DIRECTORY,
                         FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE, NULL,
                         OPEN_EXISTING, FILE_FLAG_BACKUP_SEMANTICS | FILE_FLAG_OVERLAPPED, NULL);
    free(wroot);
    if (w->dir == INVALID_HANDLE_VALUE) {
        snprintf(err, errcap, "cannot open %s (error %lu)", root, (unsigned long)GetLastError());
        return -1;
    }
    w->event = CreateEventW(NULL, TRUE, FALSE, NULL);
    if (!w->event) { snprintf(err, errcap, "CreateEvent failed"); return -1; }
    /* The first call sizes the kernel's buffer for the handle's lifetime, so
    ** ask for 1 MiB; network shares cap requests at 64 KiB. */
    DWORD sizes[2] = { 1u << 20, 64u << 10 };
    DWORD e = 0;
    for (int i = 0; i < 2; i++) {
        free(w->buf);
        w->buflen = sizes[i];
        w->buf = (DWORD *)malloc(w->buflen);
        if (!w->buf) { snprintf(err, errcap, "out of memory"); return -1; }
        e = xw_start(w);
        if (e != ERROR_INVALID_PARAMETER) break;
    }
    if (e) { snprintf(err, errcap, "ReadDirectoryChangesW failed (error %lu)", (unsigned long)e); return -1; }
    return 0;
}

static void xw_parse(xw_watcher *w, DWORD len, xw_changes *c) {
    const BYTE *p = (const BYTE *)w->buf, *end = p + len;
    while (p + sizeof(FILE_NOTIFY_INFORMATION) <= end) {
        const FILE_NOTIFY_INFORMATION *fi = (const FILE_NOTIFY_INFORMATION *)p;
        int wn = (int)(fi->FileNameLength / sizeof(WCHAR));
        int n = WideCharToMultiByte(CP_UTF8, 0, fi->FileName, wn, NULL, 0, NULL, NULL);
        char *path = n > 0 ? (char *)malloc((size_t)n) : NULL;
        if (path && WideCharToMultiByte(CP_UTF8, 0, fi->FileName, wn, path, n, NULL, NULL) == n)
            xw_push(c, path, (size_t)n);
        else
            c->overflow = 1;
        free(path);
        if (fi->Action != FILE_ACTION_MODIFIED) c->structural = 1;
        if (!fi->NextEntryOffset) break;
        p += fi->NextEntryOffset;
    }
}

static int xw_read_backend(xw_watcher *w, int timeout_ms, xw_changes *c, char *err, size_t errcap) {
    if (!w->pending) { snprintf(err, errcap, "watcher stopped"); return -1; }
    if (timeout_ms > 0) WaitForSingleObject(w->event, (DWORD)timeout_ms);
    /* A restarted request completes at once when changes queued meanwhile;
    ** bound the loop so a busy tree cannot pin the caller. */
    for (int round = 0; round < 64; round++) {
        DWORD n = 0;
        if (!GetOverlappedResult(w->dir, &w->ov, &n, FALSE)) {
            DWORD e = GetLastError();
            if (e == ERROR_IO_INCOMPLETE) return 0;
            w->pending = 0;
            if (e != ERROR_NOTIFY_ENUM_DIR) {
                snprintf(err, errcap, "ReadDirectoryChangesW failed (error %lu)", (unsigned long)e);
                return -1;
            }
            c->overflow = 1;
        } else {
            w->pending = 0;
            if (n == 0) c->overflow = 1;     /* the kernel buffer overflowed */
            else xw_parse(w, n, c);
        }
        ResetEvent(w->event);
        DWORD e = xw_start(w);
        if (e) { snprintf(err, errcap, "ReadDirectoryChangesW failed (error %lu)", (unsigned long)e); return -1; }
    }
    return 0;
}

#define XW_BACKEND "win32"

#elif XW_INOTIFY

#define XW_MASK (IN_MODIFY | IN_ATTRIB | IN_CREATE | IN_DELETE | IN_MOVED_FROM | IN_MOVED_TO | \
                 IN_DELETE_SELF | IN_MOVE_SELF | IN_ONLYDIR | IN_DONT_FOLLOW | IN_EXCL_UNLINK)

struct xw_watcher {
    int fd;
    int skip_hidden;
    char *root;
    char **dirs;         /* watch descriptor -> directory relative to root */
    int ndirs;
    int root_wd;
};

static char *xw_join(const char *a, const char *b) {
    size_t la = strlen(a), lb = strlen(b);
    char *s = (char *)malloc(la + lb + 2);
    if (!s) return NULL;
    memcpy(s, a, la);
    size_t at = la;
    if (la && lb) s[at++] = '/';
    memcpy(s + at, b, lb);
    s[at + lb] = '\0';
    return s;
}

static int xw_set_dir(xw_watcher *w, int wd, const char *rel) {
    if (wd >= w->ndirs) {
        int n = w->ndirs ? w->ndirs : 256;
        while (n <= wd) n *= 2;
        char **dirs = (char **)realloc(w->dirs, (size_t)n * sizeof(char *));
        if (!dirs) return -1;
        memset(dirs + w->ndirs, 0, (size_t)(n - w->ndirs) * sizeof(char *));
        w->dirs = dirs;
        w->ndirs = n;
    }
    char *copy = strdup(rel);
    if (!copy) return -1;
    free(w->dirs[wd]);
    w->dirs[wd] = copy;
    return 0;
}

/* Watch rel and every directory below it. Vanished or unreadable
** directories are skipped; running out of watches is an error. */
static int xw_add_tree(xw_watcher *w, const char *rel, char *err, size_t errcap) {
    char *full = rel[0] ? xw_join(w->root, rel) : strdup(w->root);
    if (!full) { snprintf(err, errcap, "out of memory"); return -1; }
    int wd = inotify_add_watch(w->fd, full, XW_MASK);
    if (wd < 0) {
        int e = errno;
        free(full);
        if (e == ENOSPC) {
            snprintf(err, errcap, "inotify watch limit reached; raise fs.inotify.max_user_watches");
            return -1;
        }
        if (e == ENOMEM) { snprintf(err, errcap, "out of memory"); return -1; }
        return 0;
    }
    if (!rel[0]) w->root_wd = wd;
    if (xw_set_dir(w, wd, rel) != 0) { free(full); snprintf(err, errcap, "out of memory"); return -1; }
    DIR *dp = opendir(full);
    if (!dp) { free(full); return 0; }
    int rc = 0;
    struct dirent *ent;
    while (rc == 0 && (ent = readdir(dp)) != NULL) {
        const char *name = ent->d_name;
        if (name[0] == '.' && (name[1] == '\0' || (name[1] == '.' && name[2] == '\0'))) continue;
        if (w->skip_hidden && name[0] == '.') continue;
        int is_dir = 0;
#ifdef DT_DIR
        if (ent->d_type == DT_DIR) is_dir = 1;
        else if (ent->d_type == DT_UNKNOWN)
#endif
        {
            struct stat st;
            if (fstatat(dirfd(dp), name, &st, AT_SYMLINK_NOFOLLOW) == 0) is_dir = S_ISDIR(st.st_mode);
        }
        if (!is_dir) continue;
        char *child = xw_join(rel, name);
        if (!child) { snprintf(err, errcap, "out of memory"); rc = -1; break; }
        rc = xw_add_tree(w, child, err, errcap);
        free(child);
    }
    closedir(dp);
    free(full);
    return rc;
}

/* A directory moved away: drop the watches below it, whose recorded paths
** are now wrong. A move within the tree re-adds them on IN_MOVED_TO. */
static void xw_drop_tree(xw_watcher *w, const char *rel) {
    size_t n = strlen(rel);
    for (int wd = 0; wd < w->ndirs; wd++) {
        const char *d = w->dirs[wd];
        if (d && strncmp(d, rel, n) == 0 && (d[n] == '\0' || d[n] == '/')) {
            inotify_rm_watch(w->fd, wd);
            free(w->dirs[wd]);
            w->dirs[wd] = NULL;
        }
    }
}

static void xw_close_backend(xw_watcher *w) {
    if (w->fd >= 0) close(w->fd);
    w->fd = -1;
    for (int i = 0; i < w->ndirs; i++) free(w->dirs[i]);
    free(w->dirs);
    free(w->root);
    w->dirs = NULL;
    w->root = NULL;
    w->ndirs = 0;
}

static int xw_open_backend(xw_watcher *w, const char *root, int skip_hidden, char *err, size_t errcap) {
    w->fd = inotify_init1(IN_NONBLOCK | IN_CLOEXEC);
    w->root_wd = -1;
    if (w->fd < 0) { snprintf(err, errcap, "inotify_init1 failed: %s", strerror(errno)); return -1; }
    w->skip_hidden = skip_hidden;
    w->root = strdup(root);
    if (!w->root) { snprintf(err, errcap, "out of memory"); return -1; }
    if (xw_add_tree(w, "", err, errcap) != 0) return -1;
    if (w->root_wd < 0) { snprintf(err, errcap, "cannot watch %s", root); return -1; }
    return 0;
}

static int xw_read_backend(xw_watcher *w, int timeout_ms, xw_changes *c, char *err, size_t errcap) {
    if (w->fd < 0) { snprintf(err, errcap, "watcher stopped"); return -1; }
    if (timeout_ms > 0) {
        struct pollfd p = { w->fd, POLLIN, 0 };
        poll(&p, 1, timeout_ms);
    }
    char buf[16 * 1024] __attribute__((aligned(__alignof__(struct inotify_event))));
    for (;;) {
        ssize_t len = read(w->fd, buf, sizeof(buf));
        if (len < 0) {
            if (errno == EINTR) continue;
            if (errno == EAGAIN || errno == EWOULDBLOCK) return 0;
            snprintf(err, errcap, "inotify read failed: %s", strerror(errno));
            return -1;
        }
        if (len == 0) return 0;
        for (char *p = buf; p < buf + len; ) {
            const struct inotify_event *ev = (const struct inotify_event *)p;
            p += sizeof(struct inotify_event) + ev->len;
            if (ev->mask & IN_Q_OVERFLOW) { c->overflow = 1; continue; }
            if (ev->wd < 0 || ev->wd >= w->ndirs || !w->dirs[ev->wd]) continue;
            if (ev->mask & IN_IGNORED) {
                free(w->dirs[ev->wd]);
                w->dirs[ev->wd] = NULL;
                continue;
            }
            if (ev->mask & (IN_DELETE_SELF | IN_MOVE_SELF)) {
                if (ev->wd == w->root_wd) { snprintf(err, errcap, "watched root was removed or moved"); return -1; }
                continue;            /* the parent reports the same change by name */
            }
            const char *dir = w->dirs[ev->wd];
            char *rel = ev->len ? xw_join(dir, ev->name) : strdup(dir);
            if (!rel) { c->overflow = 1; continue; }
            if (ev->mask & (IN_CREATE | IN_DELETE | IN_MOVED_FROM | IN_MOVED_TO)) c->structural = 1;
            int hidden = ev->len && ev->name[0] == '.';
            if (ev->mask & IN_ISDIR) {
                if (ev->mask & IN_MOVED_FROM) xw_drop_tree(w, rel);
                if ((ev->mask & (IN_CREATE | IN_MOVED_TO)) && !(w->skip_hidden && hidden)
                    && xw_add_tree(w, rel, err, errcap) != 0) {
                    free(rel);
                    return -1;
                }
            }
            xw_push(c, rel, strlen(rel));
            free(rel);
        }
    }
}

#define XW_BACKEND "inotify"

#elif XW_FSEVENTS

struct xw_watcher {
    FSEventStreamRef stream;
    dispatch_queue_t queue;
    pthread_mutex_t mu;
    pthread_cond_t cv;
    int sync_ready;
    xw_changes pending;  /* filled on the dispatch queue, drained by read() */
    char *root;          /* canonical root, as FSEvents spells paths */
    size_t root_len;
    int broken;
    char *barrier;       /* private directory for read barriers, or NULL */
    size_t barrier_len;
    unsigned long barrier_sent, barrier_seen;
    int barrier_off;
};

/* Whether p is dir or a path below it. */
static int xw_under(const char *p, const char *dir, size_t len) {
    return strncmp(p, dir, len) == 0 && (p[len] == '/' || p[len] == '\0');
}

static struct timespec xw_deadline(int ms) {
    struct timeval now;
    gettimeofday(&now, NULL);
    long long ns = (long long)now.tv_usec * 1000 + (long long)ms * 1000000;
    struct timespec until = { now.tv_sec + (time_t)(ns / 1000000000), (long)(ns % 1000000000) };
    return until;
}

static void xw_callback(ConstFSEventStreamRef stream, void *info, size_t n, void *paths,
                        const FSEventStreamEventFlags flags[], const FSEventStreamEventId ids[]) {
    (void)stream; (void)ids;
    xw_watcher *w = (xw_watcher *)info;
    char **list = (char **)paths;
    pthread_mutex_lock(&w->mu);
    for (size_t i = 0; i < n; i++) {
        FSEventStreamEventFlags f = flags[i];
        const char *p = list[i];
        if (f & (kFSEventStreamEventFlagMustScanSubDirs | kFSEventStreamEventFlagUserDropped |
                 kFSEventStreamEventFlagKernelDropped)) w->pending.overflow = 1;
        if (w->barrier && xw_under(p, w->barrier, w->barrier_len)) {
            const char *name = p + w->barrier_len;
            if (f & kFSEventStreamEventFlagRootChanged) w->barrier_off = 1;
            else if (name[0] == '/' && name[1] == 'b') {
                unsigned long seq = strtoul(name + 2, NULL, 10);
                if (seq > w->barrier_seen) w->barrier_seen = seq;
            }
            continue;
        }
        if (f & kFSEventStreamEventFlagRootChanged) { w->broken = 1; continue; }
        if (f & (kFSEventStreamEventFlagItemCreated | kFSEventStreamEventFlagItemRemoved |
                 kFSEventStreamEventFlagItemRenamed)) w->pending.structural = 1;
        /* Volumes are case-insensitive by default and FSEvents uses the
        ** on-disk spelling, so compare the prefix without case. */
        if (strlen(p) > w->root_len && p[w->root_len] == '/' && strncasecmp(p, w->root, w->root_len) == 0) {
            const char *rel = p + w->root_len + 1;
            xw_push(&w->pending, rel, strlen(rel));
        }
    }
    pthread_cond_broadcast(&w->cv);
    pthread_mutex_unlock(&w->mu);
}

static void xw_noop(void *ctx) { (void)ctx; }

static void xw_close_backend(xw_watcher *w) {
    if (w->stream) {
        FSEventStreamStop(w->stream);
        FSEventStreamInvalidate(w->stream);
        FSEventStreamRelease(w->stream);
        w->stream = NULL;
    }
    if (w->queue) {
        dispatch_sync_f(w->queue, NULL, xw_noop);   /* let a running callback finish */
        dispatch_release(w->queue);
        w->queue = NULL;
    }
    if (w->sync_ready) {
        xw_clear(&w->pending);
        pthread_cond_destroy(&w->cv);
        pthread_mutex_destroy(&w->mu);
        w->sync_ready = 0;
    }
    if (w->barrier) rmdir(w->barrier);
    free(w->barrier);
    free(w->root);
    w->barrier = NULL;
    w->root = NULL;
}

/* Canonical spelling of an existing directory (on-disk case, symlinks
** resolved), as FSEvents reports it. */
static int xw_canonical(const char *dir, char out[PATH_MAX]) {
    int fd = open(dir, O_RDONLY | O_DIRECTORY);
    if (fd < 0) return -1;
    int ok = fcntl(fd, F_GETPATH, out) != -1;
    close(fd);
    if (!ok) return -1;
    size_t n = strlen(out);
    while (n > 1 && out[n - 1] == '/') out[--n] = '\0';
    return 0;
}

/* Make the barrier directory when it shares the root's volume. */
static void xw_setup_barrier(xw_watcher *w) {
    const char *tmp = getenv("TMPDIR");
    if (!tmp || !*tmp) tmp = "/tmp";
    char made[PATH_MAX], canon[PATH_MAX];
    if (snprintf(made, sizeof(made), "%s/xwatch.XXXXXX", tmp) >= (int)sizeof(made)) return;
    if (!mkdtemp(made)) return;
    struct stat a, b;
    if (xw_canonical(made, canon) != 0 || stat(w->root, &a) != 0 || stat(canon, &b) != 0
        || a.st_dev != b.st_dev || !(w->barrier = strdup(canon))) {
        rmdir(made);
        return;
    }
    w->barrier_len = strlen(w->barrier);
}

/* Write the next barrier file and wait until its event arrives. */
static void xw_barrier(xw_watcher *w) {
    unsigned long seq = w->barrier_sent + 1;
    char file[PATH_MAX];
    if (snprintf(file, sizeof(file), "%s/b%lu", w->barrier, seq) >= (int)sizeof(file)) return;
    int fd = open(file, O_CREAT | O_WRONLY | O_TRUNC, 0600);
    if (fd < 0) return;
    close(fd);
    w->barrier_sent = seq;
    /* The event reaches fseventsd after the flush would return, and then
    ** waits out the stream latency: flush again every few milliseconds. */
    pthread_mutex_lock(&w->mu);
    for (int waited = 0; w->barrier_seen < seq && !w->broken && !w->barrier_off && waited < 1000; waited += 2) {
        pthread_mutex_unlock(&w->mu);
        FSEventStreamFlushSync(w->stream);
        pthread_mutex_lock(&w->mu);
        if (w->barrier_seen >= seq) break;
        struct timespec until = xw_deadline(2);
        pthread_cond_timedwait(&w->cv, &w->mu, &until);
    }
    /* No barrier event: earlier events may still be in flight. */
    if (w->barrier_seen < seq && !w->barrier_off) w->pending.overflow = 1;
    pthread_mutex_unlock(&w->mu);
    unlink(file);
}

static int xw_open_backend(xw_watcher *w, const char *root, int skip_hidden, char *err, size_t errcap) {
    (void)skip_hidden;
    pthread_mutex_init(&w->mu, NULL);
    pthread_cond_init(&w->cv, NULL);
    w->sync_ready = 1;
    char canon[PATH_MAX];
    if (xw_canonical(root, canon) != 0) { snprintf(err, errcap, "cannot open %s: %s", root, strerror(errno)); return -1; }
    w->root_len = strlen(canon);
    w->root = strdup(canon);
    if (!w->root) { snprintf(err, errcap, "out of memory"); return -1; }
    xw_setup_barrier(w);
    CFStringRef watched[2] = { NULL, NULL };
    CFIndex count = w->barrier ? 2 : 1;
    watched[0] = CFStringCreateWithCString(NULL, w->root, kCFStringEncodingUTF8);
    if (w->barrier) watched[1] = CFStringCreateWithCString(NULL, w->barrier, kCFStringEncodingUTF8);
    CFArrayRef paths = NULL;
    if (watched[0] && (!w->barrier || watched[1]))
        paths = CFArrayCreate(NULL, (const void **)watched, count, &kCFTypeArrayCallBacks);
    for (CFIndex i = 0; i < 2; i++) if (watched[i]) CFRelease(watched[i]);
    if (!paths) { snprintf(err, errcap, "invalid UTF-8 path: %s", root); return -1; }
    FSEventStreamContext ctx = { 0, w, NULL, NULL, NULL };
    w->stream = FSEventStreamCreate(NULL, xw_callback, &ctx, paths, kFSEventStreamEventIdSinceNow, 0.05,
                                    kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer |
                                    kFSEventStreamCreateFlagWatchRoot);
    CFRelease(paths);
    if (!w->stream) { snprintf(err, errcap, "FSEventStreamCreate failed"); return -1; }
    w->queue = dispatch_queue_create("xwatch", DISPATCH_QUEUE_SERIAL);
    if (!w->queue) { snprintf(err, errcap, "dispatch_queue_create failed"); return -1; }
    FSEventStreamSetDispatchQueue(w->stream, w->queue);
    if (!FSEventStreamStart(w->stream)) { snprintf(err, errcap, "FSEventStreamStart failed"); return -1; }
    /* Changes made just before open() arrive late too: wait them out and
    ** drop them, so reads report only what changed after open() returned. */
    if (w->barrier) {
        xw_barrier(w);
        pthread_mutex_lock(&w->mu);
        xw_clear(&w->pending);
        pthread_mutex_unlock(&w->mu);
    }
    return 0;
}

static int xw_read_backend(xw_watcher *w, int timeout_ms, xw_changes *c, char *err, size_t errcap) {
    if (!w->stream) { snprintf(err, errcap, "watcher stopped"); return -1; }
    /* Deliver everything up to now, so a read right after a save sees it as
    ** with the other backends; without a barrier, flush what has arrived. */
    if (w->barrier && !w->barrier_off) xw_barrier(w);
    else FSEventStreamFlushSync(w->stream);
    pthread_mutex_lock(&w->mu);
    if (timeout_ms > 0 && !w->pending.n && !w->pending.overflow && !w->broken) {
        struct timespec until = xw_deadline(timeout_ms);
        pthread_cond_timedwait(&w->cv, &w->mu, &until);
    }
    *c = w->pending;
    memset(&w->pending, 0, sizeof(w->pending));
    int broken = w->broken;
    pthread_mutex_unlock(&w->mu);
    if (broken) { snprintf(err, errcap, "watched root was removed or moved"); return -1; }
    return 0;
}

#define XW_BACKEND "fsevents"

#endif

/* ---- Lua binding ------------------------------------------------------- */

#ifdef XW_BACKEND

typedef struct {
    xw_watcher w;
    int open;
} xw_ud;

static xw_ud *check_ud(lua_State *L) {
    return (xw_ud *)luaL_checkudata(L, 1, XWATCH_META);
}

static int l_close(lua_State *L) {
    xw_ud *u = check_ud(L);
    if (u->open) { xw_close_backend(&u->w); u->open = 0; }
    return 0;
}

static int l_read(lua_State *L) {
    xw_ud *u = check_ud(L);
    lua_Integer timeout = luaL_optinteger(L, 2, 0);
    luaL_argcheck(L, timeout >= 0 && timeout <= 86400000, 2, "invalid timeout");
    if (!u->open) { lua_pushnil(L); lua_pushstring(L, "watcher closed"); return 2; }
    xw_changes c;
    memset(&c, 0, sizeof(c));
    char err[256] = { 0 };
    if (xw_read_backend(&u->w, (int)timeout, &c, err, sizeof(err)) != 0) {
        xw_clear(&c);
        lua_pushnil(L);
        lua_pushstring(L, err);
        return 2;
    }
    return xw_return(L, &c);
}

static int l_open(lua_State *L) {
    size_t n;
    const char *root = luaL_checklstring(L, 1, &n);
    luaL_argcheck(L, n > 0 && !memchr(root, 0, n), 1, "invalid path");
    int skip_hidden = 0;
    if (!lua_isnoneornil(L, 2)) {
        luaL_checktype(L, 2, LUA_TTABLE);
        lua_getfield(L, 2, "skip_hidden");
        skip_hidden = lua_toboolean(L, -1);
        lua_pop(L, 1);
    }
    xw_ud *u = (xw_ud *)lua_newuserdata(L, sizeof(xw_ud));
    memset(u, 0, sizeof(*u));
    luaL_setmetatable(L, XWATCH_META);
    char err[256] = { 0 };
    u->open = 1;
    if (xw_open_backend(&u->w, root, skip_hidden, err, sizeof(err)) != 0) {
        xw_close_backend(&u->w);
        u->open = 0;
        lua_pushnil(L);
        lua_pushstring(L, err[0] ? err : "cannot watch directory");
        return 2;
    }
    return 1;
}

static const luaL_Reg watcher_methods[] = {
    { "read",  l_read },
    { "close", l_close },
    { NULL, NULL }
};

#endif

static const luaL_Reg xwatch_funcs[] = {
#ifdef XW_BACKEND
    { "open", l_open },
#endif
    { NULL, NULL }
};

LUALIB_API int luaopen_xwatch(lua_State *L) {
#ifdef XW_BACKEND
    if (luaL_newmetatable(L, XWATCH_META)) {
        lua_pushcfunction(L, l_close);
        lua_setfield(L, -2, "__gc");
        lua_newtable(L);
        luaL_setfuncs(L, watcher_methods, 0);
        lua_setfield(L, -2, "__index");
    }
    lua_pop(L, 1);
#endif
    lua_newtable(L);
    luaL_setfuncs(L, xwatch_funcs, 0);
#ifdef XW_BACKEND
    lua_pushstring(L, XW_BACKEND);
    lua_setfield(L, -2, "backend");
#endif
    return 1;
}
