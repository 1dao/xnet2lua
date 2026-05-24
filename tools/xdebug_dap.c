#define _DEFAULT_SOURCE

#include "../xpoll.h"
#include "../xsock.h"

#include <ctype.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#ifdef _WIN32
#include <direct.h>
#define getcwd _getcwd
#else
#include <signal.h>
#include <strings.h>
#endif

#define DAP_BUF_INIT 4096
#define XDAP_LINE_MAX 2048

typedef struct { char *p; size_t n, cap; } Str;
typedef struct { char **v; int n, cap; } Lines;
typedef struct { int id, stopped, line; char *file, *script; } Thread;
typedef struct { Thread *v; int n, cap; } Threads;
typedef struct { char *file; int *lines; int n, cap; } BpFile;
typedef struct { BpFile *v; int n, cap; } Breakpoints;
typedef struct { int id, tid, frame; } FrameRef;
typedef struct { FrameRef *v; int n, cap; } Frames;
typedef struct { int id, kind, tid, frame; char *path; } VarRef;
typedef struct { VarRef *v; int n, cap; } Vars;
typedef struct { int tid; char reason[32]; } Reason;
typedef struct { Reason *v; int n, cap; } Reasons;

typedef struct {
    int listen, xdebug_port;
    char xdebug_host[128];
    char cwd[1024];
} Options;

typedef struct {
    int seq;
    char *command;
    const char *json;
    const char *end;
} Request;

typedef struct Session {
    SOCKET_T fd, xfd;
    Options opts;
    int seq, next_frame, next_var, polling, closed, configured, received_set_breakpoints;
    long64 next_poll;
    char *in;
    size_t in_len, in_cap;
    Breakpoints bps;
    Threads threads;
    Frames frames;
    Vars vars;
    Reasons reasons;
} Session;

typedef struct {
    Options opts;
    SOCKET_T lfd;
    Session *session;
    int running;
} App;

static App g = {0};

static int reserve_vec(void **p, int *cap, int need, size_t item) {
    int nc = *cap ? *cap : 8;
    if (need <= *cap) return 1;
    while (nc < need) nc *= 2;
    void *q = realloc(*p, item * (size_t)nc);
    if (!q) return 0;
    *p = q;
    *cap = nc;
    return 1;
}

static char *sdup(const char *s) {
    size_t n = strlen(s ? s : "");
    char *p = (char *)malloc(n + 1);
    if (p) memcpy(p, s ? s : "", n + 1);
    return p;
}

static char *sndup(const char *s, size_t n) {
    char *p = (char *)malloc(n + 1);
    if (p) {
        memcpy(p, s, n);
        p[n] = 0;
    }
    return p;
}

static int sb_reserve(Str *s, size_t add) {
    size_t need = s->n + add + 1;
    size_t nc = s->cap ? s->cap : 256;
    if (need <= s->cap) return 1;
    while (nc < need) nc *= 2;
    char *p = (char *)realloc(s->p, nc);
    if (!p) return 0;
    s->p = p;
    s->cap = nc;
    if (s->n == 0) s->p[0] = 0;
    return 1;
}

static int sb_addn(Str *s, const char *p, size_t n) {
    if (!sb_reserve(s, n)) return 0;
    memcpy(s->p + s->n, p, n);
    s->n += n;
    s->p[s->n] = 0;
    return 1;
}

static int sb_add(Str *s, const char *p) {
    return sb_addn(s, p, strlen(p));
}

static int sb_printf(Str *s, const char *fmt, ...) {
    char stack[512];
    va_list ap;
    va_start(ap, fmt);
    int n = vsnprintf(stack, sizeof(stack), fmt, ap);
    va_end(ap);
    if (n < 0) return 0;
    if ((size_t)n < sizeof(stack)) return sb_addn(s, stack, (size_t)n);
    char *buf = (char *)malloc((size_t)n + 1);
    if (!buf) return 0;
    va_start(ap, fmt);
    vsnprintf(buf, (size_t)n + 1, fmt, ap);
    va_end(ap);
    int ok = sb_addn(s, buf, (size_t)n);
    free(buf);
    return ok;
}

static void sb_json(Str *s, const char *p) {
    sb_add(s, "\"");
    for (; p && *p; p++) {
        unsigned char c = (unsigned char)*p;
        if (c == '"' || c == '\\') sb_printf(s, "\\%c", c);
        else if (c == '\n') sb_add(s, "\\n");
        else if (c == '\r') sb_add(s, "\\r");
        else if (c == '\t') sb_add(s, "\\t");
        else if (c < 0x20) sb_printf(s, "\\u%04x", (unsigned)c);
        else sb_addn(s, (const char *)&c, 1);
    }
    sb_add(s, "\"");
}

static void sb_free(Str *s) {
    free(s->p);
    memset(s, 0, sizeof(*s));
}

static void slash_inplace(char *s) {
    for (; s && *s; s++) if (*s == '\\') *s = '/';
}

static char *slash_dup(const char *s) {
    char *p = sdup(s);
    slash_inplace(p);
    return p;
}

static int starts_ci(const char *s, const char *pfx) {
    while (*pfx) {
        if (tolower((unsigned char)*s++) != tolower((unsigned char)*pfx++)) return 0;
    }
    return 1;
}

static const char *base_name(const char *p) {
    const char *b = p ? p : "";
    for (const char *s = b; *s; s++) if (*s == '/' || *s == '\\') b = s + 1;
    return b;
}

static int is_abs_path(const char *p) {
    return p && ((isalpha((unsigned char)p[0]) && p[1] == ':' && (p[2] == '/' || p[2] == '\\')) ||
                 p[0] == '/' || p[0] == '\\');
}

static char *source_path(const char *cwd, const char *file) {
    char *f = slash_dup(file);
    if (!f || !*f || is_abs_path(f)) return f;
    char *c = slash_dup(cwd);
    size_t n = strlen(c), m = strlen(f);
    char *out = (char *)malloc(n + m + 2);
    if (out) snprintf(out, n + m + 2, "%s/%s", c, f);
    free(c);
    free(f);
    return out;
}

static char *debug_path(const char *cwd, const char *file) {
    char *p = slash_dup(file);
    char *c = slash_dup(cwd);
    size_t n = c ? strlen(c) : 0;
    if (p && c && starts_ci(p, c) && p[n] == '/') memmove(p, p + n + 1, strlen(p + n + 1) + 1);
    free(c);
    return p;
}

static const char *skip_ws(const char *p, const char *e) {
    while (p < e && isspace((unsigned char)*p)) p++;
    return p;
}

static const char *skip_json_string(const char *p, const char *e) {
    if (p >= e || *p != '"') return p;
    for (p++; p < e; p++) {
        if (*p == '\\') {
            if (++p >= e) break;
        } else if (*p == '"') {
            return p + 1;
        }
    }
    return e;
}

static const char *find_key(const char *p, const char *e, const char *key) {
    size_t klen = strlen(key);
    while (p < e) {
        if (*p != '"') {
            p++;
            continue;
        }
        if ((size_t)(e - p) > klen + 2 && memcmp(p + 1, key, klen) == 0 && p[1 + klen] == '"') {
            const char *q = skip_ws(p + klen + 2, e);
            if (q < e && *q == ':') return skip_ws(q + 1, e);
        }
        p = skip_json_string(p, e);
    }
    return NULL;
}

static int json_int_at(const char *p, const char *e, int dflt) {
    p = skip_ws(p, e);
    if (p < e && *p == '"') {
        const char *q = p + 1;
        while (q < e && *q != '"') {
            if (*q == '\\') return dflt;
            q++;
        }
        if (q >= e) return dflt;
        return json_int_at(p + 1, q, dflt);
    }
    int sign = 1, v = 0, any = 0;
    if (p < e && *p == '-') { sign = -1; p++; }
    while (p < e && isdigit((unsigned char)*p)) {
        any = 1;
        v = v * 10 + (*p++ - '0');
    }
    return any ? sign * v : dflt;
}

static int json_get_int(const char *j, const char *e, const char *key, int dflt) {
    const char *p = find_key(j, e, key);
    return p ? json_int_at(p, e, dflt) : dflt;
}

static int json_get_bool(const char *j, const char *e, const char *key, int dflt) {
    const char *p = find_key(j, e, key);
    if (!p) return dflt;
    if (e - p >= 4 && memcmp(p, "true", 4) == 0) return 1;
    if (e - p >= 5 && memcmp(p, "false", 5) == 0) return 0;
    return dflt;
}

static char *json_string_at(const char *p, const char *e) {
    Str out = {0};
    p = skip_ws(p, e);
    if (p >= e || *p != '"') return NULL;
    for (p++; p < e; p++) {
        unsigned char c = (unsigned char)*p;
        if (c == '"') return out.p ? out.p : sdup("");
        if (c != '\\') {
            sb_addn(&out, (const char *)&c, 1);
            continue;
        }
        if (++p >= e) break;
        switch (*p) {
        case '"': case '\\': case '/': sb_addn(&out, p, 1); break;
        case 'b': sb_addn(&out, "\b", 1); break;
        case 'f': sb_addn(&out, "\f", 1); break;
        case 'n': sb_addn(&out, "\n", 1); break;
        case 'r': sb_addn(&out, "\r", 1); break;
        case 't': sb_addn(&out, "\t", 1); break;
        case 'u': sb_add(&out, "?"); p += (e - p > 4) ? 4 : (e - p); break;
        default: sb_addn(&out, p, 1); break;
        }
    }
    sb_free(&out);
    return NULL;
}

static char *json_get_string(const char *j, const char *e, const char *key) {
    const char *p = find_key(j, e, key);
    return p ? json_string_at(p, e) : NULL;
}

static const char *match_bracket(const char *p, const char *e, char open, char close) {
    int depth = 0;
    for (; p < e; p++) {
        if (*p == '"') {
            p = skip_json_string(p, e) - 1;
        } else if (*p == open) {
            depth++;
        } else if (*p == close && --depth == 0) {
            return p + 1;
        }
    }
    return NULL;
}

static int json_object_range(const char *j, const char *e, const char *key, const char **a, const char **b) {
    const char *p = find_key(j, e, key);
    if (!p || *skip_ws(p, e) != '{') return 0;
    p = skip_ws(p, e);
    const char *q = match_bracket(p, e, '{', '}');
    if (!q) return 0;
    *a = p;
    *b = q;
    return 1;
}

static int json_array_range(const char *j, const char *e, const char *key, const char **a, const char **b) {
    const char *p = find_key(j, e, key);
    if (!p || *skip_ws(p, e) != '[') return 0;
    p = skip_ws(p, e);
    const char *q = match_bracket(p, e, '[', ']');
    if (!q) return 0;
    *a = p;
    *b = q;
    return 1;
}

static int wait_fd(SOCKET_T fd, int write, int timeout_ms) {
    fd_set set;
    struct timeval tv;
    FD_ZERO(&set);
    FD_SET(fd, &set);
    tv.tv_sec = timeout_ms / 1000;
    tv.tv_usec = (timeout_ms % 1000) * 1000;
    return select((int)fd + 1, write ? NULL : &set, write ? &set : NULL, NULL, &tv) > 0;
}

static int send_all(SOCKET_T fd, const char *buf, size_t len) {
    size_t off = 0;
    while (off < len) {
        int n = send(fd, buf + off, (int)(len - off), 0);
        if (n > 0) {
            off += (size_t)n;
        } else if (socket_check_eagain()) {
            if (!wait_fd(fd, 1, 5000)) return 0;
        } else {
            return 0;
        }
    }
    return 1;
}

static void dap_send(Session *s, Str *json) {
    char h[64];
    int n = snprintf(h, sizeof(h), "Content-Length: %zu\r\n\r\n", json->n);
    send_all(s->fd, h, (size_t)n);
    send_all(s->fd, json->p ? json->p : "", json->n);
    sb_free(json);
}

static void send_response(Session *s, Request *req, const char *body, int ok, const char *msg) {
    Str out = {0};
    sb_printf(&out, "{\"type\":\"response\",\"seq\":%d,\"request_seq\":%d,\"command\":", s->seq++, req->seq);
    sb_json(&out, req->command ? req->command : "");
    sb_printf(&out, ",\"success\":%s", ok ? "true" : "false");
    if (msg && *msg) {
        sb_add(&out, ",\"message\":");
        sb_json(&out, msg);
    }
    sb_add(&out, ",\"body\":");
    sb_add(&out, body ? body : "{}");
    sb_add(&out, "}");
    dap_send(s, &out);
}

static void send_event(Session *s, const char *event, const char *body) {
    Str out = {0};
    sb_printf(&out, "{\"type\":\"event\",\"seq\":%d,\"event\":", s->seq++);
    sb_json(&out, event);
    sb_add(&out, ",\"body\":");
    sb_add(&out, body ? body : "{}");
    sb_add(&out, "}");
    dap_send(s, &out);
}

static void output(Session *s, const char *fmt, ...) {
    char text[2048];
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(text, sizeof(text), fmt, ap);
    va_end(ap);
    size_t n = strlen(text);
    if (n + 1 < sizeof(text) && (n == 0 || text[n - 1] != '\n')) {
        text[n] = '\n';
        text[n + 1] = 0;
    }
    Str b = {0};
    sb_add(&b, "{\"category\":\"console\",\"output\":");
    sb_json(&b, text);
    sb_add(&b, "}");
    send_event(s, "output", b.p);
    sb_free(&b);
}

static int lines_push(Lines *ls, const char *s) {
    if (!reserve_vec((void **)&ls->v, &ls->cap, ls->n + 1, sizeof(char *))) return 0;
    ls->v[ls->n++] = sdup(s);
    return ls->v[ls->n - 1] != NULL;
}

static void lines_free(Lines *ls) {
    for (int i = 0; i < ls->n; i++) free(ls->v[i]);
    free(ls->v);
    memset(ls, 0, sizeof(*ls));
}

static void thread_free(Thread *t) {
    free(t->file);
    free(t->script);
}

static void threads_free(Threads *ts) {
    for (int i = 0; i < ts->n; i++) thread_free(&ts->v[i]);
    free(ts->v);
    memset(ts, 0, sizeof(*ts));
}

static int threads_push(Threads *ts, Thread t) {
    if (!reserve_vec((void **)&ts->v, &ts->cap, ts->n + 1, sizeof(Thread))) return 0;
    ts->v[ts->n++] = t;
    return 1;
}

static Thread *threads_find(Threads *ts, int id) {
    for (int i = 0; i < ts->n; i++) if (ts->v[i].id == id) return &ts->v[i];
    return NULL;
}

static BpFile *bp_find(Breakpoints *bps, const char *file) {
    for (int i = 0; i < bps->n; i++) if (strcmp(bps->v[i].file, file) == 0) return &bps->v[i];
    return NULL;
}

static int bp_set(Breakpoints *bps, const char *file, int *lines, int n) {
    BpFile *bp = bp_find(bps, file);
    if (!bp) {
        if (!reserve_vec((void **)&bps->v, &bps->cap, bps->n + 1, sizeof(BpFile))) return 0;
        bp = &bps->v[bps->n++];
        memset(bp, 0, sizeof(*bp));
        bp->file = sdup(file);
    }
    free(bp->lines);
    bp->lines = NULL;
    bp->n = bp->cap = 0;
    if (n > 0) {
        bp->lines = (int *)malloc(sizeof(int) * (size_t)n);
        if (!bp->lines) return 0;
        memcpy(bp->lines, lines, sizeof(int) * (size_t)n);
    }
    bp->n = bp->cap = n;
    return 1;
}

static int bp_add_line(Breakpoints *bps, const char *file, int line) {
    BpFile *bp = bp_find(bps, file);
    if (!bp) {
        int one = line;
        return bp_set(bps, file, &one, 1);
    }
    for (int i = 0; i < bp->n; i++) {
        if (bp->lines[i] == line) return 1;
    }
    int *new_lines = (int *)realloc(bp->lines, sizeof(int) * (size_t)(bp->n + 1));
    if (!new_lines) return 0;
    bp->lines = new_lines;
    bp->lines[bp->n++] = line;
    bp->cap = bp->n;
    return 1;
}

static void breakpoints_free(Breakpoints *bps) {
    for (int i = 0; i < bps->n; i++) {
        free(bps->v[i].file);
        free(bps->v[i].lines);
    }
    free(bps->v);
}

static int frames_add(Session *s, int tid, int frame) {
    if (!reserve_vec((void **)&s->frames.v, &s->frames.cap, s->frames.n + 1, sizeof(FrameRef))) return 0;
    int id = s->next_frame++;
    s->frames.v[s->frames.n++] = (FrameRef){ id, tid, frame };
    return id;
}

static FrameRef *frames_find(Session *s, int id) {
    for (int i = 0; i < s->frames.n; i++) if (s->frames.v[i].id == id) return &s->frames.v[i];
    return NULL;
}

static int vars_add(Session *s, int kind, int tid, int frame, const char *path) {
    if (!reserve_vec((void **)&s->vars.v, &s->vars.cap, s->vars.n + 1, sizeof(VarRef))) return 0;
    int id = s->next_var++;
    s->vars.v[s->vars.n++] = (VarRef){ id, kind, tid, frame, path && *path ? sdup(path) : NULL };
    return id;
}

static VarRef *vars_find(Session *s, int id) {
    for (int i = 0; i < s->vars.n; i++) if (s->vars.v[i].id == id) return &s->vars.v[i];
    return NULL;
}

static void reason_set(Session *s, int tid, const char *reason) {
    for (int i = 0; i < s->reasons.n; i++) {
        if (s->reasons.v[i].tid == tid) {
            snprintf(s->reasons.v[i].reason, sizeof(s->reasons.v[i].reason), "%s", reason);
            return;
        }
    }
    if (!reserve_vec((void **)&s->reasons.v, &s->reasons.cap, s->reasons.n + 1, sizeof(Reason))) return;
    s->reasons.v[s->reasons.n].tid = tid;
    snprintf(s->reasons.v[s->reasons.n].reason, sizeof(s->reasons.v[s->reasons.n].reason), "%s", reason);
    s->reasons.n++;
}

static const char *reason_take(Session *s, int tid, char out[32]) {
    for (int i = 0; i < s->reasons.n; i++) {
        if (s->reasons.v[i].tid == tid) {
            snprintf(out, 32, "%s", s->reasons.v[i].reason);
            s->reasons.v[i] = s->reasons.v[--s->reasons.n];
            return out;
        }
    }
    snprintf(out, 32, "breakpoint");
    return out;
}

static void session_close(Session *s) {
    if (!s || s->closed) return;
    s->closed = 1;
    if (s->fd != INVALID_SOCKET_VAL) {
        xpoll_del_event(s->fd, XPOLL_ALL);
        xsock_close(s->fd);
        s->fd = INVALID_SOCKET_VAL;
    }
    if (s->xfd != INVALID_SOCKET_VAL) {
        send_all(s->xfd, "continue all\n", 13);
        send_all(s->xfd, "clear\n", 6);
        send_all(s->xfd, "quit\n", 5);
        xsock_close(s->xfd);
        s->xfd = INVALID_SOCKET_VAL;
    }
    g.running = 0;
}

static void session_free(Session *s) {
    if (!s) return;
    session_close(s);
    free(s->in);
    breakpoints_free(&s->bps);
    threads_free(&s->threads);
    free(s->frames.v);
    for (int i = 0; i < s->vars.n; i++) free(s->vars.v[i].path);
    free(s->vars.v);
    free(s->reasons.v);
    free(s);
}

static int xreadline(SOCKET_T fd, char *out, int cap) {
    int n = 0;
    while (n + 1 < cap) {
        char c;
        int r = recv(fd, &c, 1, 0);
        if (r <= 0) return n > 0 ? n : -1;
        if (c == '\n') break;
        if (c != '\r') out[n++] = c;
    }
    out[n] = 0;
    return n;
}

static int xcmd(Session *s, Lines *out, char *err, const char *fmt, ...) {
    char cmd[XDAP_LINE_MAX], line[XDAP_LINE_MAX];
    va_list ap;
    memset(out, 0, sizeof(*out));
    va_start(ap, fmt);
    vsnprintf(cmd, sizeof(cmd), fmt, ap);
    va_end(ap);
    if (s->xfd == INVALID_SOCKET_VAL) {
        snprintf(err, XSOCK_ERR_LEN, "xdebug is not connected");
        return 0;
    }
    if (!send_all(s->xfd, cmd, strlen(cmd)) || !send_all(s->xfd, "\n", 1)) {
        snprintf(err, XSOCK_ERR_LEN, "xdebug write failed");
        return 0;
    }
    for (;;) {
        if (xreadline(s->xfd, line, sizeof(line)) < 0) {
            snprintf(err, XSOCK_ERR_LEN, "xdebug connection closed");
            lines_free(out);
            return 0;
        }
        if (strcmp(line, "END") == 0) return 1;
        if (!lines_push(out, line)) {
            snprintf(err, XSOCK_ERR_LEN, "out of memory");
            lines_free(out);
            return 0;
        }
    }
}

static int ensure_xdebug(Session *s, Request *req, char *err) {
    if (s->xfd != INVALID_SOCKET_VAL) return 1;
    char *host = json_get_string(req->json, req->end, "xdebugHost");
    if (!host) host = json_get_string(req->json, req->end, "host");
    char *cwd = json_get_string(req->json, req->end, "cwd");
    if (host) snprintf(s->opts.xdebug_host, sizeof(s->opts.xdebug_host), "%s", host);
    if (cwd) snprintf(s->opts.cwd, sizeof(s->opts.cwd), "%s", cwd);
    s->opts.xdebug_port = json_get_int(req->json, req->end, "xdebugPort",
                           json_get_int(req->json, req->end, "port", s->opts.xdebug_port));
    free(host);
    free(cwd);

    s->xfd = xsock_tcp_connect(err, s->opts.xdebug_host, s->opts.xdebug_port);
    if (s->xfd == INVALID_SOCKET_VAL) return 0;
    xsock_set_tcp_nodelay(NULL, s->xfd);

    char line[XDAP_LINE_MAX];
    int got_end = 0;
    while (xreadline(s->xfd, line, sizeof(line)) >= 0) {
        if (strcmp(line, "END") == 0) {
            got_end = 1;
            break;
        }
    }
    if (!got_end) {
        xsock_close(s->xfd);
        s->xfd = INVALID_SOCKET_VAL;
        snprintf(err, XSOCK_ERR_LEN, "xdebug greeting failed");
        return 0;
    }
    output(s, "xnet xdebug connected: %s:%d", s->opts.xdebug_host, s->opts.xdebug_port);
    return 1;
}

static int seed_default_breakpoints(Session *s, Request *req) {
    const char *a, *b, *p;
    if (!json_array_range(req->json, req->end, "defaultBreakpoints", &a, &b)) return 1;
    p = skip_ws(a + 1, b);
    while (p < b && *p && *p != ']') {
        if (*p == '{') {
            const char *q = match_bracket(p, b, '{', '}');
            if (!q) return 0;
            char *path = json_get_string(p, q, "path");
            if (!path) path = json_get_string(p, q, "file");
            int line = json_get_int(p, q, "line", 0);
            if (path && line > 0) {
                if (!bp_add_line(&s->bps, path, line)) {
                    free(path);
                    return 0;
                }
            }
            free(path);
            p = q;
        } else {
            p++;
        }
        p = skip_ws(p, b);
        if (p < b && *p == ',') p++;
        p = skip_ws(p, b);
    }
    return 1;
}

static int apply_breakpoints(Session *s, char *err) {
    Lines lines;
    if (s->xfd == INVALID_SOCKET_VAL) return 1;
    if (!xcmd(s, &lines, err, "clear")) return 0;
    lines_free(&lines);
    for (int i = 0; i < s->bps.n; i++) {
        char *p = debug_path(s->opts.cwd, s->bps.v[i].file);
        if (s->bps.v[i].n > 0) {
            Str msg = {0};
            sb_printf(&msg, "[xnet] apply break %s -> [", p ? p : "");
            for (int j = 0; j < s->bps.v[i].n; j++) {
                if (j) sb_add(&msg, ", ");
                sb_printf(&msg, "%d", s->bps.v[i].lines[j]);
            }
            sb_add(&msg, "]");
            output(s, "%s", msg.p ? msg.p : "");
            sb_free(&msg);
        }
        for (int j = 0; j < s->bps.v[i].n; j++) {
            if (!xcmd(s, &lines, err, "break %s %d", p, s->bps.v[i].lines[j])) {
                free(p);
                lines_free(&lines);
                return 0;
            }
            lines_free(&lines);
        }
        free(p);
    }
    return 1;
}

static int split_tabs(char *s, char **p, int max) {
    int n = 0;
    p[n++] = s;
    while (n < max) {
        char *t = strchr(p[n - 1], '\t');
        if (!t) break;
        *t = 0;
        p[n++] = t + 1;
    }
    return n;
}

static int get_threads(Session *s, Threads *out, char *err) {
    Lines lines;
    memset(out, 0, sizeof(*out));
    if (!xcmd(s, &lines, err, "threads")) return 0;
    for (int i = 0; i < lines.n; i++) {
        if (!lines.v[i][0] || strncmp(lines.v[i], "OK ", 3) == 0) continue;
        char *tmp = sdup(lines.v[i]), *p[5] = {0};
        if (!tmp) continue;
        split_tabs(tmp, p, 5);
        Thread t = {
            atoi(p[0] ? p[0] : "0"),
            p[1] && strcmp(p[1], "stopped") == 0,
            atoi(p[3] ? p[3] : "0"),
            sdup(p[2] ? p[2] : ""),
            sdup(p[4] ? p[4] : "")
        };
        if (t.id > 0) threads_push(out, t);
        else thread_free(&t);
        free(tmp);
    }
    lines_free(&lines);
    return 1;
}

static char *thread_name(Thread *t) {
    char *script = slash_dup(t->script);
    const char *bn = base_name(script);
    char buf[2048];
    if (t->stopped && t->file && *t->file) {
        char *f = slash_dup(t->file);
        snprintf(buf, sizeof(buf), "T%d stopped %s:%d (%s)", t->id, f, t->line, *bn ? bn : "lua");
        free(f);
    } else {
        snprintf(buf, sizeof(buf), "T%d %s (%s)", t->id, t->stopped ? "stopped" : "running", *bn ? bn : "lua");
    }
    free(script);
    return sdup(buf);
}

static void stopped_output(Session *s, Thread *t, const char *reason) {
    char *file = slash_dup(t->file && *t->file ? t->file : "unknown");
    char *script = slash_dup(t->script);
    output(s, "[xnet] %s: T%d stopped at %s:%d%s%s",
           reason, t->id, file, t->line, script && *script ? " script=" : "", script && *script ? script : "");
    free(file);
    free(script);
}

static int poll_threads(Session *s) {
    char err[XSOCK_ERR_LEN] = {0}, reason[32];
    Threads next;
    if (!s || s->xfd == INVALID_SOCKET_VAL) return 0;
    if (!get_threads(s, &next, err)) return 0;
    for (int i = 0; i < next.n; i++) {
        Thread *t = &next.v[i], *prev = threads_find(&s->threads, t->id);
        if (!prev) {
            Str b = {0};
            sb_printf(&b, "{\"reason\":\"started\",\"threadId\":%d}", t->id);
            send_event(s, "thread", b.p);
            sb_free(&b);
        }
        if (t->stopped && (!prev || !prev->stopped || strcmp(prev->file, t->file) != 0 || prev->line != t->line)) {
            if (s->configured) {
                const char *r = reason_take(s, t->id, reason);
                stopped_output(s, t, r);
                Str b = {0};
                sb_add(&b, "{\"reason\":");
                sb_json(&b, r);
                sb_printf(&b, ",\"threadId\":%d,\"allThreadsStopped\":false}", t->id);
                send_event(s, "stopped", b.p);
                sb_free(&b);
            }
        }
    }
    for (int i = 0; i < s->threads.n; i++) {
        if (!threads_find(&next, s->threads.v[i].id)) {
            Str b = {0};
            sb_printf(&b, "{\"reason\":\"exited\",\"threadId\":%d}", s->threads.v[i].id);
            send_event(s, "thread", b.p);
            sb_free(&b);
        }
    }
    threads_free(&s->threads);
    s->threads = next;
    return 1;
}

static void add_source(Str *b, const char *cwd, const char *file) {
    char *full = source_path(cwd, file);
    sb_add(b, "\"source\":{\"name\":");
    sb_json(b, base_name(full));
    sb_add(b, ",\"path\":");
    sb_json(b, full ? full : "");
    sb_add(b, "}");
    free(full);
}

static void on_initialize(Session *s, Request *req) {
    const char *body =
        "{\"supportsConfigurationDoneRequest\":true,"
        "\"supportsPauseRequest\":true,"
        "\"supportsTerminateRequest\":true,"
        "\"supportsSingleThreadExecutionRequests\":true,"
        "\"supportsStepInTargetsRequest\":false,"
        "\"supportsEvaluateForHovers\":false,"
        "\"supportsSetVariable\":false}";
    send_response(s, req, body, 1, NULL);
    send_event(s, "initialized", "{}");
}

static void on_attach(Session *s, Request *req) {
    char err[XSOCK_ERR_LEN] = {0};
    s->received_set_breakpoints = 0;
    s->configured = 0;
    if (!seed_default_breakpoints(s, req)) {
        send_response(s, req, "{}", 0, "out of memory");
        return;
    }
    if (!ensure_xdebug(s, req, err) || !apply_breakpoints(s, err)) {
        send_response(s, req, "{}", 0, err[0] ? err : "attach failed");
        return;
    }
    s->polling = 1;
    s->next_poll = time_get_ms();
    send_response(s, req, "{}", 1, NULL);
}

static void on_config_done(Session *s, Request *req) {
    s->configured = 1;
    for (int i = 0; i < s->threads.n; i++) {
        s->threads.v[i].stopped = 0;
    }
    send_response(s, req, "{}", 1, NULL);
    poll_threads(s);
}

static int parse_breakpoint_lines(Request *req, int **out, int *out_n) {
    const char *a, *b, *p;
    int *lines = NULL, n = 0, cap = 0;
    *out = NULL;
    *out_n = 0;
    if (!json_array_range(req->json, req->end, "breakpoints", &a, &b)) return 1;
    p = a;
    while ((p = find_key(p, b, "line")) != NULL) {
        int line = json_int_at(p, b, 0);
        if (line > 0) {
            if (!reserve_vec((void **)&lines, &cap, n + 1, sizeof(int))) {
                free(lines);
                return 0;
            }
            lines[n++] = line;
        }
        p++;
    }
    *out = lines;
    *out_n = n;
    return 1;
}

static char *request_source_path(Request *req) {
    const char *a, *b;
    if (json_object_range(req->json, req->end, "source", &a, &b)) {
        char *path = json_get_string(a, b, "path");
        if (path) return path;
    }
    return sdup("");
}

static void on_set_breakpoints(Session *s, Request *req) {
    char *file = request_source_path(req);
    int *lines = NULL, n = 0;
    s->received_set_breakpoints = 1;
    if (!parse_breakpoint_lines(req, &lines, &n) || !bp_set(&s->bps, file, lines, n)) {
        free(file);
        free(lines);
        send_response(s, req, "{}", 0, "out of memory");
        return;
    }
    {
        Str msg = {0};
        sb_printf(&msg, "[xnet] setBreakpoints %s -> [", file ? file : "");
        for (int i = 0; i < n; i++) {
            if (i) sb_add(&msg, ", ");
            sb_printf(&msg, "%d", lines[i]);
        }
        sb_add(&msg, "]");
        output(s, "%s", msg.p ? msg.p : "");
        sb_free(&msg);
    }
    free(lines);

    char err[XSOCK_ERR_LEN] = {0};
    if (!apply_breakpoints(s, err)) {
        free(file);
        send_response(s, req, "{}", 0, err);
        return;
    }
    Str body = {0};
    sb_add(&body, "{\"breakpoints\":[");
    BpFile *bp = bp_find(&s->bps, file);
    for (int i = 0; bp && i < bp->n; i++) {
        if (i) sb_add(&body, ",");
        sb_printf(&body, "{\"verified\":true,\"line\":%d}", bp->lines[i]);
    }
    sb_add(&body, "]}");
    send_response(s, req, body.p, 1, NULL);
    sb_free(&body);
    free(file);
}

static void on_threads(Session *s, Request *req) {
    char err[XSOCK_ERR_LEN] = {0};
    Threads ts;
    if (!get_threads(s, &ts, err)) {
        send_response(s, req, "{}", 0, err);
        return;
    }
    Str body = {0};
    sb_add(&body, "{\"threads\":[");
    for (int i = 0; i < ts.n; i++) {
        char *name = thread_name(&ts.v[i]);
        if (i) sb_add(&body, ",");
        sb_printf(&body, "{\"id\":%d,\"name\":", ts.v[i].id);
        sb_json(&body, name);
        sb_add(&body, "}");
        free(name);
    }
    sb_add(&body, "]}");
    threads_free(&ts);
    send_response(s, req, body.p, 1, NULL);
    sb_free(&body);
}

static void on_stack_trace(Session *s, Request *req) {
    int tid = json_get_int(req->json, req->end, "threadId", 0);
    char err[XSOCK_ERR_LEN] = {0};
    Lines lines;
    if (!xcmd(s, &lines, err, "stack %d", tid)) {
        send_response(s, req, "{}", 0, err);
        return;
    }
    Str arr = {0};
    int count = 0;
    sb_add(&arr, "[");
    for (int i = 0; i < lines.n; i++) {
        if (!lines.v[i][0] || strncmp(lines.v[i], "OK ", 3) == 0) continue;
        if (strncmp(lines.v[i], "ERR ", 4) == 0) break;
        char *tmp = sdup(lines.v[i]), *p[4] = {0};
        split_tabs(tmp, p, 4);
        int level = atoi(p[0] ? p[0] : "0");
        int id = frames_add(s, tid, level);
        char name[512];
        if (level == 0) snprintf(name, sizeof(name), "[T%d] %s", tid, p[3] ? p[3] : "?");
        else snprintf(name, sizeof(name), "%s", p[3] ? p[3] : "?");
        if (count) sb_add(&arr, ",");
        sb_printf(&arr, "{\"id\":%d,\"name\":", id);
        sb_json(&arr, name);
        sb_add(&arr, ",");
        add_source(&arr, s->opts.cwd, p[1] ? p[1] : "");
        sb_printf(&arr, ",\"line\":%d,\"column\":1}", atoi(p[2] ? p[2] : "0"));
        count++;
        free(tmp);
    }
    lines_free(&lines);
    sb_add(&arr, "]");

    Str body = {0};
    sb_add(&body, "{\"stackFrames\":");
    sb_add(&body, arr.p ? arr.p : "[]");
    sb_printf(&body, ",\"totalFrames\":%d}", count);
    sb_free(&arr);
    send_response(s, req, body.p, 1, NULL);
    sb_free(&body);
}

static void on_scopes(Session *s, Request *req) {
    FrameRef *fr = frames_find(s, json_get_int(req->json, req->end, "frameId", 0));
    Str body = {0};
    sb_add(&body, "{\"scopes\":[");
    if (fr) {
        int thread_ref = vars_add(s, 1, fr->tid, fr->frame, NULL);
        int locals_ref = vars_add(s, 2, fr->tid, fr->frame, NULL);
        sb_printf(&body,
            "{\"name\":\"XNet Thread\",\"variablesReference\":%d,\"expensive\":false},"
            "{\"name\":\"Locals\",\"variablesReference\":%d,\"expensive\":false}",
            thread_ref, locals_ref);
    }
    sb_add(&body, "]}");
    send_response(s, req, body.p, 1, NULL);
    sb_free(&body);
}

static void add_var(Session *s, Str *arr, int *count, int tid, int frame,
                    const char *name, const char *value, const char *path, int expandable) {
    int ref = expandable && path && *path ? vars_add(s, 3, tid, frame, path) : 0;
    if ((*count)++) sb_add(arr, ",");
    sb_add(arr, "{\"name\":");
    sb_json(arr, name);
    sb_add(arr, ",\"value\":");
    sb_json(arr, value ? value : "");
    sb_printf(arr, ",\"variablesReference\":%d}", ref);
}

static void on_variables(Session *s, Request *req) {
    VarRef *vr = vars_find(s, json_get_int(req->json, req->end, "variablesReference", 0));
    Str arr = {0};
    int count = 0;
    sb_add(&arr, "[");
    if (vr && vr->kind == 1) {
        Thread *t = threads_find(&s->threads, vr->tid);
        char tmp[64], at[1200] = "";
        snprintf(tmp, sizeof(tmp), "%d", vr->tid);
        add_var(s, &arr, &count, 0, 0, "xnet_thread_id", tmp, NULL, 0);
        add_var(s, &arr, &count, 0, 0, "status", t && t->stopped ? "stopped" : "running", NULL, 0);
        add_var(s, &arr, &count, 0, 0, "script", t ? t->script : "", NULL, 0);
        if (t && t->file && *t->file) snprintf(at, sizeof(at), "%s:%d", t->file, t->line);
        add_var(s, &arr, &count, 0, 0, "stopped_at", at, NULL, 0);
    } else if (vr) {
        char err[XSOCK_ERR_LEN] = {0};
        Lines lines;
        int ok = vr->kind == 3
            ? xcmd(s, &lines, err, "fields %d %d %s", vr->tid, vr->frame, vr->path ? vr->path : "")
            : xcmd(s, &lines, err, "locals %d %d", vr->tid, vr->frame);
        if (!ok) {
            sb_free(&arr);
            send_response(s, req, "{}", 0, err);
            return;
        }
        for (int i = 0; i < lines.n; i++) {
            if (!lines.v[i][0] || strncmp(lines.v[i], "OK ", 3) == 0) continue;
            if (strncmp(lines.v[i], "ERR ", 4) == 0) break;
            char *tmp = sdup(lines.v[i]), *p[4] = {0};
            split_tabs(tmp, p, 4);
            if (p[0] && p[1]) add_var(s, &arr, &count, vr->tid, vr->frame,
                                      p[0], p[1], p[2] ? p[2] : "", p[3] && atoi(p[3]) != 0);
            free(tmp);
        }
        lines_free(&lines);
    }
    sb_add(&arr, "]");
    Str body = {0};
    sb_add(&body, "{\"variables\":");
    sb_add(&body, arr.p ? arr.p : "[]");
    sb_add(&body, "}");
    sb_free(&arr);
    send_response(s, req, body.p, 1, NULL);
    sb_free(&body);
}

static void resume_req(Session *s, Request *req, int tid, const char *cmd, const char *reason, int all) {
    char err[XSOCK_ERR_LEN] = {0};
    Lines lines;
    if (!xcmd(s, &lines, err, "%s", cmd)) {
        send_response(s, req, "{}", 0, err);
        return;
    }
    lines_free(&lines);
    if (all) {
        for (int i = 0; i < s->threads.n; i++) s->threads.v[i].stopped = 0;
    } else {
        Thread *t = threads_find(&s->threads, tid);
        if (t) t->stopped = 0;
    }
    if (reason) reason_set(s, tid, reason);

    Str b = {0};
    sb_printf(&b, "{\"threadId\":%d,\"allThreadsContinued\":%s}", tid, all ? "true" : "false");
    send_event(s, "continued", b.p);
    sb_free(&b);

    sb_printf(&b, "{\"allThreadsContinued\":%s}", all ? "true" : "false");
    send_response(s, req, b.p, 1, NULL);
    sb_free(&b);
}

static void handle_request(Session *s, Request *req) {
    const char *cmd = req->command ? req->command : "";
    if (strcmp(cmd, "initialize") == 0) on_initialize(s, req);
    else if (strcmp(cmd, "attach") == 0 || strcmp(cmd, "launch") == 0) on_attach(s, req);
    else if (strcmp(cmd, "configurationDone") == 0) on_config_done(s, req);
    else if (strcmp(cmd, "setBreakpoints") == 0) on_set_breakpoints(s, req);
    else if (strcmp(cmd, "threads") == 0) on_threads(s, req);
    else if (strcmp(cmd, "stackTrace") == 0) on_stack_trace(s, req);
    else if (strcmp(cmd, "scopes") == 0) on_scopes(s, req);
    else if (strcmp(cmd, "variables") == 0) on_variables(s, req);
    else if (strcmp(cmd, "continue") == 0) {
        int tid = json_get_int(req->json, req->end, "threadId", 0);
        char c[64];
        if (json_get_bool(req->json, req->end, "singleThread", 0)) {
            snprintf(c, sizeof(c), "continue %d", tid);
            resume_req(s, req, tid, c, NULL, 0);
        } else {
            resume_req(s, req, tid, "continue all", NULL, 1);
        }
    } else if (strcmp(cmd, "next") == 0) {
        char c[64]; int tid = json_get_int(req->json, req->end, "threadId", 0);
        snprintf(c, sizeof(c), "step %d over", tid);
        resume_req(s, req, tid, c, "step", 0);
    } else if (strcmp(cmd, "stepIn") == 0) {
        char c[64]; int tid = json_get_int(req->json, req->end, "threadId", 0);
        snprintf(c, sizeof(c), "step %d into", tid);
        resume_req(s, req, tid, c, "step", 0);
    } else if (strcmp(cmd, "stepOut") == 0) {
        char c[64]; int tid = json_get_int(req->json, req->end, "threadId", 0);
        snprintf(c, sizeof(c), "step %d out", tid);
        resume_req(s, req, tid, c, "step", 0);
    } else if (strcmp(cmd, "pause") == 0) {
        int tid = json_get_int(req->json, req->end, "threadId", 0);
        char err[XSOCK_ERR_LEN] = {0};
        Lines lines;
        reason_set(s, tid, "pause");
        if (!xcmd(s, &lines, err, "pause %d", tid)) send_response(s, req, "{}", 0, err);
        else { lines_free(&lines); send_response(s, req, "{}", 1, NULL); }
    } else if (strcmp(cmd, "disconnect") == 0 || strcmp(cmd, "terminate") == 0) {
        send_response(s, req, "{}", 1, NULL);
        session_close(s);
    } else if (strcmp(cmd, "evaluate") == 0) {
        send_response(s, req, "{\"result\":\"\",\"variablesReference\":0}", 1, NULL);
    } else {
        send_response(s, req, "{}", 1, NULL);
    }
}

static char *find_header_end(char *buf, size_t len) {
    for (size_t i = 3; i < len; i++)
        if (buf[i - 3] == '\r' && buf[i - 2] == '\n' && buf[i - 1] == '\r' && buf[i] == '\n')
            return buf + i - 3;
    return NULL;
}

static int content_length(char *hdr) {
    char *p = strstr(hdr, "Content-Length:");
    return p ? atoi(p + 15) : 0;
}

static void dap_feed(Session *s) {
    for (;;) {
        char *he = find_header_end(s->in, s->in_len);
        if (!he) return;
        size_t hlen = (size_t)(he - s->in);
        char *hdr = sndup(s->in, hlen);
        int len = hdr ? content_length(hdr) : 0;
        free(hdr);
        size_t start = hlen + 4;
        if (len <= 0 || s->in_len < start + (size_t)len) return;
        char *body = sndup(s->in + start, (size_t)len);
        memmove(s->in, s->in + start + (size_t)len, s->in_len - start - (size_t)len);
        s->in_len -= start + (size_t)len;
        if (body) {
            Request req = {0};
            req.json = body;
            req.end = body + len;
            req.seq = json_get_int(req.json, req.end, "seq", 0);
            req.command = json_get_string(req.json, req.end, "command");
            if (req.command) handle_request(s, &req);
            free(req.command);
            free(body);
        }
        if (s->closed) return;
    }
}

static void dap_read(SOCKET_T fd, int mask, void *ud, xPollRequest *r) {
    (void)mask; (void)r;
    Session *s = (Session *)ud;
    char buf[4096];
    for (;;) {
        int n = recv(fd, buf, sizeof(buf), 0);
        if (n > 0) {
            if (s->in_len + (size_t)n > s->in_cap) {
                size_t nc = s->in_cap ? s->in_cap : DAP_BUF_INIT;
                while (nc < s->in_len + (size_t)n) nc *= 2;
                char *p = (char *)realloc(s->in, nc);
                if (!p) { session_close(s); return; }
                s->in = p;
                s->in_cap = nc;
            }
            memcpy(s->in + s->in_len, buf, (size_t)n);
            s->in_len += (size_t)n;
            dap_feed(s);
            if (s->closed) return;
        } else if (n == 0) {
            session_close(s);
            return;
        } else if (socket_check_eagain()) {
            return;
        } else {
            session_close(s);
            return;
        }
    }
}

static void dap_error(SOCKET_T fd, int mask, void *ud, xPollRequest *r) {
    (void)fd; (void)mask; (void)r;
    session_close((Session *)ud);
}

static Session *session_new(SOCKET_T fd, Options *opts) {
    Session *s = (Session *)calloc(1, sizeof(*s));
    if (!s) return NULL;
    s->fd = fd;
    s->xfd = INVALID_SOCKET_VAL;
    s->opts = *opts;
    s->seq = 1;
    s->next_frame = 1000;
    s->next_var = 1;
    return s;
}

static void accept_client(SOCKET_T fd, int mask, void *ud, xPollRequest *r) {
    (void)mask; (void)r;
    App *app = (App *)ud;
    char err[XSOCK_ERR_LEN] = {0};
    SOCKET_T c = xsock_accept(err, fd, NULL, NULL);
    if (c == INVALID_SOCKET_VAL) return;
    if (app->session) {
        xsock_close(c);
        return;
    }
    xsock_set_nonblock(NULL, c);
    xsock_set_tcp_nodelay(NULL, c);
    app->session = session_new(c, &app->opts);
    if (!app->session) {
        xsock_close(c);
        return;
    }
    xpoll_add_event(c, XPOLL_READABLE, dap_read, NULL, dap_error, app->session);
}

static void parse_args(Options *o, int argc, char **argv) {
    o->listen = 4711;
    o->xdebug_port = 19090;
    snprintf(o->xdebug_host, sizeof(o->xdebug_host), "127.0.0.1");
    getcwd(o->cwd, sizeof(o->cwd));
    for (int i = 1; i < argc; i++) {
        const char *a = argv[i], *v = i + 1 < argc ? argv[i + 1] : NULL;
        if (v && strcmp(a, "--listen") == 0) o->listen = atoi(argv[++i]);
        else if (v && strcmp(a, "--xdebug-host") == 0) snprintf(o->xdebug_host, sizeof(o->xdebug_host), "%s", argv[++i]);
        else if (v && strcmp(a, "--xdebug-port") == 0) o->xdebug_port = atoi(argv[++i]);
        else if (v && strcmp(a, "--cwd") == 0) snprintf(o->cwd, sizeof(o->cwd), "%s", argv[++i]);
    }
}

int main(int argc, char **argv) {
    char err[XSOCK_ERR_LEN] = {0};
#ifndef _WIN32
    signal(SIGPIPE, SIG_IGN);
#endif
    parse_args(&g.opts, argc, argv);
    (void)socket_init();
    if (xpoll_init() != 0) {
        fprintf(stderr, "xnet-xdebug-dap error: xpoll init failed\n");
        return 1;
    }
    fprintf(stderr, "xnet-xdebug-dap starting (%s)\n", xpoll_name());
    g.lfd = xsock_listen(err, "127.0.0.1", g.opts.listen);
    if (g.lfd == INVALID_SOCKET_VAL) {
        fprintf(stderr, "xnet-xdebug-dap error: %s\n", err);
        return 1;
    }
    xsock_set_nonblock(NULL, g.lfd);
    xpoll_add_event(g.lfd, XPOLL_READABLE, accept_client, NULL, NULL, &g);
    fprintf(stderr, "xnet-xdebug-dap listening on 127.0.0.1:%d\n", g.opts.listen);

    g.running = 1;
    while (g.running) {
        int timeout = 100;
        Session *s = g.session;
        if (s && s->closed) {
            session_free(s);
            g.session = NULL;
            continue;
        }
        if (s && s->polling && s->xfd != INVALID_SOCKET_VAL) {
            long64 now = time_get_ms();
            if (now >= s->next_poll) {
                poll_threads(s);
                s->next_poll = time_get_ms() + 250;
                timeout = 0;
            } else if (s->next_poll - now < timeout) {
                timeout = (int)(s->next_poll - now);
            }
        }
        if (xpoll_poll(timeout) < 0) break;
    }
    session_free(g.session);
    if (g.lfd != INVALID_SOCKET_VAL) xsock_close(g.lfd);
    xpoll_uninit();
    socket_cleanup();
    return 0;
}
