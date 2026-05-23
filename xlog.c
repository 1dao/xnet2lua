#include "xlog.h"
#include "xthread.h"

#ifndef __ANDROID__

#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#ifdef _WIN32
#define WIN32_LEAN_AND_MEAN
#include <direct.h>
#include <windows.h>
#else
#include <errno.h>
#include <pthread.h>
#include <sys/stat.h>
#include <sys/types.h>
#endif

#include "xmacro.h"

#if defined(_MSC_VER)
#define XLOG_TLS __declspec(thread)
#elif defined(__STDC_VERSION__) && __STDC_VERSION__ >= 201112L
#define XLOG_TLS _Thread_local
#else
#define XLOG_TLS __thread
#endif

typedef struct {
    int id;
    int file_open_attempted;
    char name[64];
    char file_name[64];
    char path[512];
    FILE* file;
} xLogThreadState;

static char g_log_dir[256] = "logs";
static char g_process_name[64] = "xnet";
static int g_configured = 0;
static int g_min_level = XLOG_LEVEL_VERBOSE;
static int g_console_enabled = 1;

static XLOG_TLS xLogThreadState g_thread_log;

#ifdef _WIN32
static SRWLOCK g_console_lock = SRWLOCK_INIT;

static void xlog_console_lock(void) {
    AcquireSRWLockExclusive(&g_console_lock);
}

static void xlog_console_unlock(void) {
    ReleaseSRWLockExclusive(&g_console_lock);
}
#else
static pthread_mutex_t g_console_lock = PTHREAD_MUTEX_INITIALIZER;

static void xlog_console_lock(void) {
    pthread_mutex_lock(&g_console_lock);
}

static void xlog_console_unlock(void) {
    pthread_mutex_unlock(&g_console_lock);
}
#endif

static void xlog_mkdir(const char* dir) {
    if (!dir || !dir[0]) return;
#ifdef _WIN32
    _mkdir(dir);
#else
    if (mkdir(dir, 0777) != 0 && errno != EEXIST) return;
#endif
}

static void xlog_copy(char* dst, size_t cap, const char* src, const char* fallback) {
    const char* s = (src && src[0]) ? src : fallback;
    if (!dst || cap == 0) return;
    if (!s) s = "";
    snprintf(dst, cap, "%s", s);
}

static void xlog_sanitize(char* s) {
    if (!s) return;
    for (; *s; ++s) {
        unsigned char c = (unsigned char)*s;
        if ((c >= 'a' && c <= 'z') ||
            (c >= 'A' && c <= 'Z') ||
            (c >= '0' && c <= '9') ||
            c == '-' || c == '_') {
            continue;
        }
        *s = '_';
    }
}

#ifdef _WIN32
static int g_vt_enabled = 0;

static void xlog_enable_vt100(void) {
    if (g_vt_enabled) return;

    HANDLE handles[2] = {
        GetStdHandle(STD_OUTPUT_HANDLE),
        GetStdHandle(STD_ERROR_HANDLE),
    };

    for (int i = 0; i < 2; ++i) {
        HANDLE h = handles[i];
        if (h == INVALID_HANDLE_VALUE) continue;

        DWORD mode = 0;
        if (!GetConsoleMode(h, &mode)) continue;
        mode |= ENABLE_VIRTUAL_TERMINAL_PROCESSING;
        SetConsoleMode(h, mode);
    }

    g_vt_enabled = 1;
}
#else
static void xlog_enable_vt100(void) {}
#endif

static int xlog_is_system_level_name(const char* level_name) {
    return level_name && strcmp(level_name, XLOG_LEVEL_NAME_SYSM) == 0;
}

static FILE* xlog_console_stream(int level, const char* level_name) {
    if (xlog_is_system_level_name(level_name)) return stdout;
    return (level >= XLOG_LEVEL_WARN) ? stderr : stdout;
}

static void xlog_now(char* buf, size_t cap) {
    time_t now = time(NULL);
    struct tm tmv;
#ifdef _WIN32
    localtime_s(&tmv, &now);
#else
    localtime_r(&now, &tmv);
#endif
    strftime(buf, cap, "%Y-%m-%d %H:%M:%S", &tmv);
}

typedef struct {
    char ts[32];
    const char* level_name;
    const char* console_tag;
    const char* thread_name;
    char thread_tag[32];
    int thread_id;
} xLogRecordContext;

static int xlog_is_group_thread(int id) {
    static const int bases[] = {
        XTHR_WORKER_GRP1,
        XTHR_WORKER_GRP2,
        XTHR_WORKER_GRP3,
        XTHR_WORKER_GRP4,
        XTHR_WORKER_GRP5
    };
    for (int i = 0; i < (int)(sizeof(bases) / sizeof(bases[0])); ++i) {
        if (id >= bases[i] && id < bases[i] + XTHR_GROUP_MAX) {
            return 1;
        }
    }
    return 0;
}

static void xlog_format_thread_tag(char* buf, size_t cap, int id, const char* name) {
    if (xlog_is_group_thread(id)) {
        snprintf(buf, cap, "[G%d:%s]", id, name && name[0] ? name : "unknown");
    } else if (id == XTHR_MAIN) {
        snprintf(buf, cap, "[T%d:MAIN]", id);
    } else {
        snprintf(buf, cap, "[T%d:%s]", id, name && name[0] ? name : "unknown");
    }
}

static void xlog_record_context(const char* level_name, const char* console_tag, xLogRecordContext* ctx) {
    xLogThreadState* st = &g_thread_log;
    xlog_now(ctx->ts, sizeof(ctx->ts));
    ctx->level_name = (level_name && level_name[0]) ? level_name : "LOG";
    ctx->console_tag = (console_tag && console_tag[0]) ? console_tag : NULL;
    ctx->thread_name = st->name[0] ? st->name : "unknown";
    ctx->thread_id = st->id;
    xlog_format_thread_tag(ctx->thread_tag, sizeof(ctx->thread_tag),
                           ctx->thread_id, ctx->thread_name);
}

static int xlog_format_needs_newline(const char* fmt) {
    size_t len = strlen(fmt);
    return len == 0 || fmt[len - 1] != '\n';
}

static void xlog_copy_record_bytes(char* buf, size_t cap, size_t* pos, const char* src, size_t len) {
    if (buf && cap > 0 && *pos < cap) {
        size_t room = cap - *pos;
        size_t n = len < room ? len : room;
        if (n > 0) memcpy(buf + *pos, src, n);
    }
    *pos += len;
}

static size_t xlog_copied_len(size_t need, size_t cap) {
    return need < cap ? need : cap;
}

static size_t xlog_record_max_bytes(void) {
    size_t max = (size_t)XLOG_RECORD_MAX_BYTES;
    if (max < (size_t)XLOG_RECORD_STACK_BYTES) {
        max = (size_t)XLOG_RECORD_STACK_BYTES;
    }
    return max;
}

static size_t xlog_format_prefix(const xLogRecordContext* ctx, int console, char* buf, size_t cap) {
    char prefix[256];
    int prefix_len;
    size_t pos = 0;

    if (console && ctx->console_tag) {
        prefix_len = snprintf(prefix, sizeof(prefix), "%s [%s] %s ",
                              ctx->console_tag, ctx->ts, ctx->thread_tag);
    } else {
        prefix_len = snprintf(prefix, sizeof(prefix), "[%s] [%s] %s ",
                              ctx->level_name, ctx->ts, ctx->thread_tag);
    }

    if (prefix_len < 0) prefix_len = 0;
    if ((size_t)prefix_len >= sizeof(prefix)) prefix_len = (int)sizeof(prefix) - 1;
    xlog_copy_record_bytes(buf, cap, &pos, prefix, (size_t)prefix_len);
    return pos;
}

static size_t xlog_format_message_record(const xLogRecordContext* ctx, int console,
                                         const char* msg, size_t len,
                                         int append_newline, char* buf, size_t cap) {
    size_t pos;
    int need_newline;

    if (!msg) {
        msg = "";
        len = 0;
    }

    need_newline = append_newline && (len == 0 || msg[len - 1] != '\n');
    pos = xlog_format_prefix(ctx, console, buf, cap);
    xlog_copy_record_bytes(buf, cap, &pos, msg, len);
    if (need_newline) {
        xlog_copy_record_bytes(buf, cap, &pos, "\n", 1);
    }
    return pos;
}

static size_t xlog_format_vrecord(const xLogRecordContext* ctx, int console,
                                  const char* fmt, va_list ap,
                                  int append_newline, char* buf, size_t cap) {
    static const char format_error[] = "(log format error)";
    size_t prefix_len = xlog_format_prefix(ctx, console, buf, cap);
    size_t copied = xlog_copied_len(prefix_len, cap);
    size_t room = cap > copied ? cap - copied : 0;
    int body_len;

    if (buf && room > 0) {
        body_len = vsnprintf(buf + copied, room + 1u, fmt, ap);
    } else {
        char tmp[1];
        body_len = vsnprintf(tmp, sizeof(tmp), fmt, ap);
    }

    if (body_len < 0) {
        size_t pos = prefix_len;
        xlog_copy_record_bytes(buf, cap, &pos, format_error, sizeof(format_error) - 1u);
        if (append_newline) xlog_copy_record_bytes(buf, cap, &pos, "\n", 1);
        return pos;
    }

    prefix_len += (size_t)body_len;
    if (append_newline) {
        xlog_copy_record_bytes(buf, cap, &prefix_len, "\n", 1);
    }
    return prefix_len;
}

typedef struct {
    char* data;
    char* heap;
    size_t len;
} xLogFormattedRecord;

static void xlog_record_init(xLogFormattedRecord* rec, char* stack_buf, size_t stack_cap, size_t need) {
    size_t heap_cap;
    rec->data = stack_buf;
    rec->heap = NULL;
    rec->len = xlog_copied_len(need, stack_cap);

    if (need <= stack_cap) return;

    heap_cap = need;
    if (heap_cap > xlog_record_max_bytes()) heap_cap = xlog_record_max_bytes();
    if (heap_cap <= stack_cap) return;

    rec->heap = (char*)malloc(heap_cap + 1u);
    if (!rec->heap) return;
    rec->data = rec->heap;
    rec->len = heap_cap;
}

static void xlog_record_free(xLogFormattedRecord* rec) {
    if (rec->heap) free(rec->heap);
    rec->heap = NULL;
}

static void xlog_build_message_record(const xLogRecordContext* ctx, int console,
                                      const char* msg, size_t len, int append_newline,
                                      char* stack_buf, size_t stack_cap,
                                      xLogFormattedRecord* rec) {
    size_t need = xlog_format_message_record(ctx, console, msg, len, append_newline,
                                             stack_buf, stack_cap);
    xlog_record_init(rec, stack_buf, stack_cap, need);
    if (rec->heap) {
        need = xlog_format_message_record(ctx, console, msg, len, append_newline,
                                          rec->data, rec->len);
        rec->len = xlog_copied_len(need, rec->len);
    }
}

static void xlog_build_vrecord(const xLogRecordContext* ctx, int console,
                               const char* fmt, va_list ap, int append_newline,
                               char* stack_buf, size_t stack_cap,
                               xLogFormattedRecord* rec) {
    va_list stack_ap;
    size_t need;

    va_copy(stack_ap, ap);
    need = xlog_format_vrecord(ctx, console, fmt, stack_ap, append_newline,
                               stack_buf, stack_cap);
    va_end(stack_ap);

    xlog_record_init(rec, stack_buf, stack_cap, need);
    if (rec->heap) {
        va_list heap_ap;
        va_copy(heap_ap, ap);
        need = xlog_format_vrecord(ctx, console, fmt, heap_ap, append_newline,
                                   rec->data, rec->len);
        va_end(heap_ap);
        rec->len = xlog_copied_len(need, rec->len);
    }
}

static void xlog_flush_record(FILE* out, const xLogFormattedRecord* rec) {
    if (rec->len > 0) fwrite(rec->data, 1, rec->len, out);
    fflush(out);
}

void xlog_init(const char* log_dir, const char* process_name, int enable_console) {
    xlog_copy(g_log_dir, sizeof(g_log_dir), log_dir, "logs");
    xlog_copy(g_process_name, sizeof(g_process_name), process_name, "xnet");
    xlog_sanitize(g_process_name);
    xlog_mkdir(g_log_dir);
    g_console_enabled = enable_console ? 1 : 0;
    if (g_console_enabled) xlog_enable_vt100();
    g_configured = 1;
    xlog_set_thread(1, "main");
}

void xlog_uninit(void) {
    xlog_clear_thread();
    g_configured = 0;
}

void xlog_set_thread(int id, const char* name) {
    xLogThreadState* st = &g_thread_log;
    char display_name[64];
    char file_name[64];
    xlog_copy(display_name, sizeof(display_name), name, id == 1 ? "main" : "thread");
    xlog_copy(file_name, sizeof(file_name), display_name, id == 1 ? "main" : "thread");
    xlog_sanitize(file_name);

    if ((st->file || st->file_open_attempted) &&
        st->id == id &&
        strcmp(st->name, display_name) == 0 &&
        strcmp(st->file_name, file_name) == 0) {
        return;
    }
    xlog_clear_thread();
    st->id = id;
    xlog_copy(st->name, sizeof(st->name), display_name, id == 1 ? "main" : "thread");
    xlog_copy(st->file_name, sizeof(st->file_name), file_name, st->name);
}

void xlog_clear_thread(void) {
    xLogThreadState* st = &g_thread_log;
    if (st->file) {
        fflush(st->file);
        fclose(st->file);
    }
    memset(st, 0, sizeof(*st));
}

void xlog_set_level(int min_level) {
    if (min_level < XLOG_LEVEL_VERBOSE) min_level = XLOG_LEVEL_VERBOSE;
    if (min_level > XLOG_LEVEL_FATAL) min_level = XLOG_LEVEL_FATAL;
    g_min_level = min_level;
}

int xlog_get_level(void) {
    return g_min_level;
}

int xlog_is_enabled(int level) {
    return level >= g_min_level;
}

size_t xlog_format(int level, const char* level_name, const char* msg, size_t len, int append_newline, char* buf, size_t cap) {
    (void)level;
    xLogRecordContext ctx;
    size_t data_cap = cap > 0 ? cap - 1u : 0u;
    size_t need;

    xlog_record_context(level_name, NULL, &ctx);
    need = xlog_format_message_record(&ctx, 0, msg, len, append_newline, buf, data_cap);
    if (buf && cap > 0) {
        buf[xlog_copied_len(need, data_cap)] = '\0';
    }
    return need;
}

static FILE* xlog_open_thread_file(void) {
    xLogThreadState* st = &g_thread_log;
    if (st->file) return st->file;
    if (st->file_open_attempted) return NULL;
    if (!g_configured) xlog_init(NULL, NULL, 1);
    if (st->id == 0) {
        st->id = 0;
        xlog_copy(st->name, sizeof(st->name), "unknown", "unknown");
        xlog_copy(st->file_name, sizeof(st->file_name), "unknown", "unknown");
    }

    char proc[64];
    char name[64];
    xlog_copy(proc, sizeof(proc), g_process_name, "xnet");
    xlog_copy(name, sizeof(name), st->file_name, st->id == 1 ? "main" : "thread");
    xlog_sanitize(proc);
    xlog_sanitize(name);

    snprintf(st->path, sizeof(st->path), "%s/%s-t%03d-%s.log",
             g_log_dir, proc, st->id, name);
    st->file_open_attempted = 1;
    st->file = fopen(st->path, "ab");
    return st->file;
}

void xlog_write(int level, const char* level_name, const char* console_tag, const char* msg, size_t len, int append_newline) {
    if (!xlog_is_enabled(level)) return;

    FILE* file = xlog_open_thread_file();
    xLogRecordContext ctx;
    xlog_record_context(level_name, console_tag, &ctx);

    if (file) {
        char stack[XLOG_RECORD_STACK_BYTES + 1u];
        xLogFormattedRecord rec;
        xlog_build_message_record(&ctx, 0, msg, len, append_newline,
                                  stack, (size_t)XLOG_RECORD_STACK_BYTES, &rec);
        xlog_flush_record(file, &rec);
        xlog_record_free(&rec);
    }

    if (g_console_enabled) {
        FILE* console = xlog_console_stream(level, ctx.level_name);
        char stack[XLOG_RECORD_STACK_BYTES + 1u];
        xLogFormattedRecord rec;
        xlog_build_message_record(&ctx, 1, msg, len, append_newline,
                                  stack, (size_t)XLOG_RECORD_STACK_BYTES, &rec);
        xlog_console_lock();
        xlog_flush_record(console, &rec);
        xlog_console_unlock();
        xlog_record_free(&rec);
    }
}

void xlog_write_raw(const char* msg, size_t len) {
    if (!msg || len == 0) return;

    FILE* file = xlog_open_thread_file();
    if (file) {
        fwrite(msg, 1, len, file);
        fflush(file);
    }
}

void xlog_printf(int level, const char* level_name, const char* console_tag, const char* fmt, ...) {
    if (!xlog_is_enabled(level)) return;
    if (!fmt) fmt = "";

    FILE* file = xlog_open_thread_file();
    if (!file && !g_console_enabled) return;

    xLogRecordContext ctx;
    xlog_record_context(level_name, console_tag, &ctx);
    int append_newline = xlog_format_needs_newline(fmt);

    va_list ap;
    va_start(ap, fmt);

    if (file) {
        char stack[XLOG_RECORD_STACK_BYTES + 1u];
        xLogFormattedRecord rec;
        xlog_build_vrecord(&ctx, 0, fmt, ap, append_newline,
                           stack, (size_t)XLOG_RECORD_STACK_BYTES, &rec);
        xlog_flush_record(file, &rec);
        xlog_record_free(&rec);
    }

    if (g_console_enabled) {
        FILE* console = xlog_console_stream(level, ctx.level_name);
        char stack[XLOG_RECORD_STACK_BYTES + 1u];
        xLogFormattedRecord rec;
        xlog_build_vrecord(&ctx, 1, fmt, ap, append_newline,
                           stack, (size_t)XLOG_RECORD_STACK_BYTES, &rec);
        xlog_console_lock();
        xlog_flush_record(console, &rec);
        xlog_console_unlock();
        xlog_record_free(&rec);
    }

    va_end(ap);
}

#else

#include <stdarg.h>
#include <stdio.h>
#include <string.h>

static int g_android_min_level = XLOG_LEVEL_VERBOSE;

void xlog_init(const char* log_dir, const char* process_name, int enable_console) {
    (void)log_dir;
    (void)process_name;
    (void)enable_console;
}

void xlog_uninit(void) {}
void xlog_set_thread(int id, const char* name) { (void)id; (void)name; }
void xlog_clear_thread(void) {}
void xlog_set_level(int min_level) {
    if (min_level < XLOG_LEVEL_VERBOSE) min_level = XLOG_LEVEL_VERBOSE;
    if (min_level > XLOG_LEVEL_FATAL) min_level = XLOG_LEVEL_FATAL;
    g_android_min_level = min_level;
}
int xlog_get_level(void) { return g_android_min_level; }
int xlog_is_enabled(int level) { return level >= g_android_min_level; }

static int xlog_is_system_level_name(const char* level_name) {
    return level_name && strcmp(level_name, XLOG_LEVEL_NAME_SYSM) == 0;
}

static int xlog_android_level(int level, const char* level_name) {
    if (xlog_is_system_level_name(level_name)) return ANDROID_LOG_INFO;
    switch (level) {
    case XLOG_LEVEL_VERBOSE: return ANDROID_LOG_VERBOSE;
    case XLOG_LEVEL_DEBUG:   return ANDROID_LOG_DEBUG;
    case XLOG_LEVEL_INFO:    return ANDROID_LOG_INFO;
    case XLOG_LEVEL_WARN:    return ANDROID_LOG_WARN;
    case XLOG_LEVEL_ERROR:   return ANDROID_LOG_ERROR;
    case XLOG_LEVEL_FATAL:   return ANDROID_LOG_FATAL;
    default:                 return ANDROID_LOG_INFO;
    }
}

size_t xlog_format(int level, const char* level_name, const char* msg, size_t len, int append_newline, char* buf, size_t cap) {
    (void)level;
    (void)level_name;
    if (!msg) {
        msg = "";
        len = 0;
    }
    size_t need = len + ((append_newline && (len == 0 || msg[len - 1] != '\n')) ? 1 : 0);
    if (buf && cap > 0) {
        size_t n = len < cap - 1 ? len : cap - 1;
        if (n > 0) memcpy(buf, msg, n);
        if (n < cap - 1 && need > len) buf[n++] = '\n';
        buf[n] = '\0';
    }
    return need;
}

void xlog_write(int level, const char* level_name, const char* console_tag, const char* msg, size_t len, int append_newline) {
    if (!xlog_is_enabled(level)) return;
    (void)console_tag;
    (void)append_newline;
    if (!msg) msg = "";
    __android_log_print(xlog_android_level(level, level_name), LOG_TAG, "%.*s", (int)len, msg);
}

void xlog_write_raw(const char* msg, size_t len) {
    if (!msg) msg = "";
    __android_log_print(ANDROID_LOG_INFO, LOG_TAG, "%.*s", (int)len, msg);
}

void xlog_printf(int level, const char* level_name, const char* console_tag, const char* fmt, ...) {
    if (!xlog_is_enabled(level)) return;
    (void)level_name;
    (void)console_tag;
    char buf[1024];
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(buf, sizeof(buf), fmt ? fmt : "", ap);
    va_end(ap);
    xlog_write(level, level_name, console_tag, buf, strlen(buf), 1);
}

#endif /* __ANDROID__ */
