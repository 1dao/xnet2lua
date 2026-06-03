#include "xjs.h"
#include "xjs_actor.h"

#include <stdbool.h>
#include <stdatomic.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

#include "../xchannel.h"
#include "../xlog.h"
#include "../xpoll.h"
#include "../xsock.h"
#include "../xthread.h"
#include "../xtimer.h"
#include "../xmacro.h"

#ifdef _WIN32
#include <windows.h>
#include <bcrypt.h>
#else
#include <fcntl.h>
#include <unistd.h>
#include <errno.h>
#endif

#ifndef countof
#define countof(x) ((int)(sizeof(x) / sizeof((x)[0])))
#endif

#if defined(_MSC_VER)
#define XJS_TLS __declspec(thread)
#elif defined(__STDC_VERSION__) && __STDC_VERSION__ >= 201112L
#define XJS_TLS _Thread_local
#else
#define XJS_TLS __thread
#endif

typedef struct XJSNetConn {
    JSContext *ctx;
    xChannel *ch;
    JSValue self;
    JSValue handler;
    bool closed;
    char peer_ip[64];
    int peer_port;
    struct XJSNetConn *prev;
    struct XJSNetConn *next;
} XJSNetConn;

typedef struct XJSNetListener {
    JSContext *ctx;
    SOCKET_T fd;
    JSValue self;
    JSValue handler;
    bool closed;
    struct XJSNetListener *prev;
    struct XJSNetListener *next;
} XJSNetListener;

/* per-thread (poller is thread-private); refcount so several actors on one
** thread share one poller and one actor's uninit cannot tear it down. */
static XJS_TLS int g_xpoll_refs = 0;
/* process-global: socket_init/WSAStartup is process scoped (D3). */
static _Atomic int g_socket_refs = 0;

static void listener_accept_cb(SOCKET_T fd, int mask, void *clientData,
                               xPollRequest *submit_arg);
static void listener_accept_fd_cb(SOCKET_T fd, int mask, void *clientData,
                                  xPollRequest *submit_arg);
static void listener_error_cb(SOCKET_T fd, int mask, void *clientData,
                              xPollRequest *submit_arg);

static void conn_list_add(XJSActor *a, XJSNetConn *c) {
    c->prev = NULL;
    c->next = a->conns;
    if (a->conns) a->conns->prev = c;
    a->conns = c;
}

static void conn_list_remove(XJSActor *a, XJSNetConn *c) {
    if (c->prev) c->prev->next = c->next;
    else if (a && a->conns == c) a->conns = c->next;
    if (c->next) c->next->prev = c->prev;
    c->prev = NULL;
    c->next = NULL;
}

static void listener_list_add(XJSActor *a, XJSNetListener *s) {
    s->prev = NULL;
    s->next = a->listeners;
    if (a->listeners) a->listeners->prev = s;
    a->listeners = s;
}

static void listener_list_remove(XJSActor *a, XJSNetListener *s) {
    if (s->prev) s->prev->next = s->next;
    else if (a && a->listeners == s) a->listeners = s->next;
    if (s->next) s->next->prev = s->prev;
    s->prev = NULL;
    s->next = NULL;
}

static XJSNetConn *check_conn(JSContext *ctx, JSValueConst val) {
    return (XJSNetConn *)JS_GetOpaque2(ctx, val, g_xjs_conn_class_id);
}

static XJSNetListener *check_listener(JSContext *ctx, JSValueConst val) {
    return (XJSNetListener *)JS_GetOpaque2(ctx, val, g_xjs_listener_class_id);
}

static void conn_release_refs_ctx(XJSNetConn *c) {
    if (!c || !c->ctx) return;
    JSContext *ctx = c->ctx;
    JSValue handler = c->handler;
    JSValue self = c->self;
    c->handler = JS_UNDEFINED;
    c->self = JS_UNDEFINED;
    JS_FreeValue(ctx, handler);
    JS_FreeValue(ctx, self);
}

static void listener_release_refs_ctx(XJSNetListener *s) {
    if (!s || !s->ctx) return;
    JSContext *ctx = s->ctx;
    JSValue handler = s->handler;
    JSValue self = s->self;
    s->handler = JS_UNDEFINED;
    s->self = JS_UNDEFINED;
    JS_FreeValue(ctx, handler);
    JS_FreeValue(ctx, self);
}

static void conn_destroy_channel(XJSNetConn *c) {
    if (!c || !c->ch) return;
    xChannel *ch = c->ch;
    c->ch = NULL;
    xchannel_set_userdata(ch, NULL);
    xchannel_destroy(ch);
}

static JSValue get_handler_func(JSContext *ctx, JSValueConst handler,
                                const char **names, int name_count) {
    if (JS_IsFunction(ctx, handler)) {
        return JS_DupValue(ctx, handler);
    }
    if (!JS_IsObject(handler)) {
        return JS_UNDEFINED;
    }
    for (int i = 0; i < name_count; i++) {
        JSValue f = JS_GetPropertyStr(ctx, handler, names[i]);
        if (JS_IsException(f)) return f;
        if (JS_IsFunction(ctx, f)) return f;
        JS_FreeValue(ctx, f);
    }
    return JS_UNDEFINED;
}

static int conn_send_bytes(XJSNetConn *c, const char *data, size_t len, int raw) {
    if (!c || !c->ch || c->closed) return -1;
    return raw ? xchannel_send_raw(c->ch, data, len)
               : xchannel_send_packet(c->ch, data, len);
}

static JSValue send_result(JSContext *ctx, int rc) {
    (void)ctx;
    if (rc == 0) return JS_TRUE;
    if (rc == -2) return JS_FALSE;
    return JS_FALSE;
}

static void maybe_send_return_value(JSContext *ctx, XJSNetConn *c, JSValueConst v) {
    if (JS_IsUndefined(v) || JS_IsNull(v) || JS_IsNumber(v)) return;
    if (JS_IsArray(v)) {
        uint32_t len = 0;
        JSValue lenv = JS_GetPropertyStr(ctx, v, "length");
        JS_ToUint32(ctx, &len, lenv);
        JS_FreeValue(ctx, lenv);
        for (uint32_t i = 0; i < len && !c->closed; i++) {
            JSValue item = JS_GetPropertyUint32(ctx, v, i);
            maybe_send_return_value(ctx, c, item);
            JS_FreeValue(ctx, item);
        }
        return;
    }

    XJSBytes bytes;
    if (xjs_to_bytes(ctx, v, &bytes) == 0) {
        conn_send_bytes(c, bytes.data, bytes.len, 0);
        xjs_free_bytes(ctx, &bytes);
    }
}

static size_t packet_consumed(JSContext *ctx, JSValueConst v, size_t max_len) {
    if (!JS_IsNumber(v)) return 0;
    double n = 0;
    if (JS_ToFloat64(ctx, &n, v) < 0) return 0;
    if (n <= 0) return 0;
    if (n > (double)max_len) return max_len == SIZE_MAX ? SIZE_MAX : max_len + 1;
    return (size_t)n;
}

static void js_conn_connect_cb(xChannel *ch, void *ud) {
    (void)ch;
    XJSNetConn *c = (XJSNetConn *)ud;
    if (!c || c->closed || !c->ctx) return;

    JSContext *ctx = c->ctx;
    JSValue self = JS_DupValue(ctx, c->self);        /* keepalive: prevents c free mid-call */
    JSValue handler = JS_DupValue(ctx, c->handler);  /* keepalive: `this` may be freed mid-call */

    const char *names[] = { "onConnect", "on_connect", "connect" };
    JSValue func = get_handler_func(ctx, handler, names, countof(names));
    if (JS_IsException(func)) {
        xjs_dump_error_with_prefix(ctx, "xnet onConnect: ");
        JS_FreeValue(ctx, handler);
        JS_FreeValue(ctx, self);
        return;
    }
    if (JS_IsUndefined(func)) {
        JS_FreeValue(ctx, func);
        JS_FreeValue(ctx, handler);
        JS_FreeValue(ctx, self);
        return;
    }

    JSValue args[3];
    args[0] = JS_DupValue(ctx, c->self);
    args[1] = c->peer_ip[0] ? JS_NewString(ctx, c->peer_ip) : JS_NULL;
    args[2] = c->peer_port > 0 ? JS_NewInt32(ctx, c->peer_port) : JS_NULL;
    JSValue ret = JS_Call(ctx, func, handler, 3, (JSValueConst *)args);
    for (int i = 0; i < 3; i++) JS_FreeValue(ctx, args[i]);
    JS_FreeValue(ctx, func);
    if (JS_IsException(ret)) {
        xjs_dump_error_with_prefix(ctx, "xnet onConnect: ");
        if (!c->closed && c->ch) xchannel_close(c->ch, "handler_error");
        JS_FreeValue(ctx, handler);
        JS_FreeValue(ctx, self);
        return;
    }
    if (!c->closed && (JS_IsObject(ret) || JS_IsFunction(ctx, ret))) {
        JS_FreeValue(ctx, c->handler);
        c->handler = JS_DupValue(ctx, ret);
    }
    JS_FreeValue(ctx, ret);
    JS_FreeValue(ctx, handler);
    JS_FreeValue(ctx, self);
}

static size_t js_conn_packet_cb(xChannel *ch, const char *data, size_t len, void *ud) {
    (void)ch;
    XJSNetConn *c = (XJSNetConn *)ud;
    if (!c || c->closed || !c->ctx) return 0;

    JSContext *ctx = c->ctx;
    JSValue self = JS_DupValue(ctx, c->self);        /* keepalive: prevents c free mid-call */
    JSValue handler = JS_DupValue(ctx, c->handler);  /* keepalive: `this` may be freed mid-call */

    const char *names[] = { "onPacket", "on_packet", "onMessage", "on_message", "onRecv", "on_recv" };
    JSValue func = get_handler_func(ctx, handler, names, countof(names));
    if (JS_IsException(func)) {
        xjs_dump_error_with_prefix(ctx, "xnet onPacket: ");
        JS_FreeValue(ctx, handler);
        JS_FreeValue(ctx, self);
        return 0;
    }
    if (JS_IsUndefined(func)) {
        JS_FreeValue(ctx, func);
        JS_FreeValue(ctx, handler);
        JS_FreeValue(ctx, self);
        return 0;
    }

    JSValue args[2];
    args[0] = JS_DupValue(ctx, c->self);
    args[1] = JS_NewUint8ArrayCopy(ctx, (const uint8_t *)data, len);
    JSValue ret = JS_Call(ctx, func, handler, 2, (JSValueConst *)args);
    JS_FreeValue(ctx, args[0]);
    JS_FreeValue(ctx, args[1]);
    JS_FreeValue(ctx, func);
    if (JS_IsException(ret)) {
        xjs_dump_error_with_prefix(ctx, "xnet onPacket: ");
        if (!c->closed && c->ch) xchannel_close(c->ch, "handler_error");
        JS_FreeValue(ctx, handler);
        JS_FreeValue(ctx, self);
        return 0;
    }

    size_t consumed = packet_consumed(ctx, ret, len);
    /* D1-b: a non-numeric, non-empty return is data to auto-send and means the
    ** whole input was processed; consume `len` (RAW mode would otherwise keep
    ** the bytes buffered forever). Framed modes ignore `consumed` in xchannel. */
    if (!JS_IsNumber(ret) && !JS_IsUndefined(ret) && !JS_IsNull(ret)) {
        consumed = len;
    }
    maybe_send_return_value(ctx, c, ret);
    JS_FreeValue(ctx, ret);
    JS_FreeValue(ctx, handler);
    JS_FreeValue(ctx, self);
    return consumed;
}

static void js_conn_close_cb(xChannel *ch, const char *reason, void *ud) {
    XJSNetConn *c = (XJSNetConn *)ud;
    if (!c || !c->ctx) return;

    JSContext *ctx = c->ctx;
    if (!c->closed) {
        const char *names[] = { "onClose", "on_close", "onDisconnect", "on_disconnect" };
        JSValue func = get_handler_func(ctx, c->handler, names, countof(names));
        if (!JS_IsException(func) && !JS_IsUndefined(func)) {
            JSValue args[2] = {
                JS_DupValue(ctx, c->self),
                JS_NewString(ctx, reason ? reason : "closed")
            };
            JSValue ret = JS_Call(ctx, func, c->handler, 2, (JSValueConst *)args);
            JS_FreeValue(ctx, args[0]);
            JS_FreeValue(ctx, args[1]);
            if (JS_IsException(ret)) xjs_dump_error_with_prefix(ctx, "xnet onClose: ");
            else JS_FreeValue(ctx, ret);
        } else if (JS_IsException(func)) {
            xjs_dump_error_with_prefix(ctx, "xnet onClose: ");
        }
        JS_FreeValue(ctx, func);

        uint64_t bs = 0, br = 0;
        xchannel_get_stats(ch, NULL, NULL, &bs, &br);
        XJSActor *a = xjs_actor(c->ctx);
        if (a) {
            a->acc_sent += bs;
            a->acc_recv += br;
            a->conn_count--;
        }
    }

    c->closed = true;
    if (c->ch == ch) {
        xchannel_set_userdata(ch, NULL);
        c->ch = NULL;
    }
    conn_release_refs_ctx(c);
}

static const xChannelConfig s_js_conn_cfg = {
    .connect_cb = js_conn_connect_cb,
    .packet_cb = js_conn_packet_cb,
    .close_cb = js_conn_close_cb,
};

static int ensure_xnet_classes(JSContext *ctx);

static XJSNetConn *push_conn(JSContext *ctx, JSValue *out_obj, xChannel *ch,
                             JSValueConst handler, const char *ip, int port) {
    if (ensure_xnet_classes(ctx) != 0) return NULL;
    JSValue obj = JS_NewObjectClass(ctx, g_xjs_conn_class_id);
    if (JS_IsException(obj)) return NULL;

    XJSNetConn *c = (XJSNetConn *)js_mallocz(ctx, sizeof(*c));
    if (!c) {
        JS_FreeValue(ctx, obj);
        JS_ThrowOutOfMemory(ctx);
        return NULL;
    }
    c->ctx = ctx;
    c->ch = ch;
    c->self = JS_DupValue(ctx, obj);
    c->handler = JS_DupValue(ctx, handler);
    c->closed = false;
    if (ip) {
        strncpy(c->peer_ip, ip, sizeof(c->peer_ip) - 1);
        c->peer_ip[sizeof(c->peer_ip) - 1] = '\0';
    }
    c->peer_port = port;
    JS_SetOpaque(obj, c);
    conn_list_add(xjs_actor(ctx), c);
    xchannel_set_userdata(ch, c);
    *out_obj = obj;
    return c;
}

static void listener_close_internal(XJSNetListener *s, const char *reason, int call_handler) {
    if (!s || s->closed) return;
    s->closed = true;
    if (s->fd != INVALID_SOCKET_VAL) {
        xpoll_del_event(s->fd, XPOLL_ALL);
        xsock_close(s->fd);
        s->fd = INVALID_SOCKET_VAL;
    }

    if (call_handler && s->ctx) {
        JSContext *ctx = s->ctx;
        const char *names[] = { "onClose", "on_close" };
        JSValue func = get_handler_func(ctx, s->handler, names, countof(names));
        if (!JS_IsException(func) && !JS_IsUndefined(func)) {
            JSValue args[2] = {
                JS_DupValue(ctx, s->self),
                JS_NewString(ctx, reason ? reason : "closed")
            };
            JSValue ret = JS_Call(ctx, func, s->handler, 2, (JSValueConst *)args);
            JS_FreeValue(ctx, args[0]);
            JS_FreeValue(ctx, args[1]);
            if (JS_IsException(ret)) xjs_dump_error_with_prefix(ctx, "xnet listener onClose: ");
            else JS_FreeValue(ctx, ret);
        } else if (JS_IsException(func)) {
            xjs_dump_error_with_prefix(ctx, "xnet listener onClose: ");
        }
        JS_FreeValue(ctx, func);
    }

    listener_release_refs_ctx(s);
}

static SOCKET_T listener_accept_one(XJSNetListener *s, char *ip, int *port,
                                    bool *retry) {
    *retry = false;
    char err[XSOCK_ERR_LEN] = {0};
    SOCKET_T cfd = xsock_accept(err, s->fd, ip, port);
    if (cfd == INVALID_SOCKET_VAL) {
        if (!socket_check_eagain())
            listener_close_internal(s, err[0] ? err : "accept_error", 1);
        return INVALID_SOCKET_VAL;
    }
    if (xsock_set_nonblock(err, cfd) != XSOCK_OK) {
        xsock_close(cfd);
        *retry = true;
        return INVALID_SOCKET_VAL;
    }
    return cfd;
}

static void listener_accept_cb(SOCKET_T fd, int mask, void *clientData,
                               xPollRequest *submit_arg) {
    (void)fd;
    (void)mask;
    (void)submit_arg;
    XJSNetListener *s = (XJSNetListener *)clientData;
    if (!s || s->closed || !s->ctx) return;
    JSValue ls = JS_DupValue(s->ctx, s->self);   /* keepalive: handler may close listener */

    while (!s->closed) {
        char ip[64] = {0};
        int port = 0;
        bool retry = false;
        SOCKET_T cfd = listener_accept_one(s, ip, &port, &retry);
        if (cfd == INVALID_SOCKET_VAL) {
            if (retry) continue;
            break;
        }

        xChannel *ch = xchannel_create(cfd, &s_js_conn_cfg);
        if (!ch) {
            xsock_close(cfd);
            continue;
        }

        JSValue conn_obj = JS_UNDEFINED;
        XJSNetConn *c = push_conn(s->ctx, &conn_obj, ch, s->handler, ip, port);
        if (!c) {
            xchannel_destroy(ch);
            continue;
        }
        xjs_actor(s->ctx)->conn_count++;
        js_conn_connect_cb(ch, c);
        if (!c->closed && c->ch && xchannel_attach(c->ch) != 0) {
            xchannel_close(c->ch, "poll_error");
        }
        JS_FreeValue(s->ctx, conn_obj);
    }
    JS_FreeValue(s->ctx, ls);
}

static void listener_accept_fd_cb(SOCKET_T fd, int mask, void *clientData,
                                  xPollRequest *submit_arg) {
    (void)fd;
    (void)mask;
    (void)submit_arg;
    XJSNetListener *s = (XJSNetListener *)clientData;
    if (!s || s->closed || !s->ctx) return;

    JSContext *ctx = s->ctx;
    while (!s->closed) {
        char ip[64] = {0};
        int port = 0;
        bool retry = false;
        SOCKET_T cfd = listener_accept_one(s, ip, &port, &retry);
        if (cfd == INVALID_SOCKET_VAL) {
            if (retry) continue;
            break;
        }

        bool transfer = false;
        const char *names[] = { "onAccept", "on_accept", "accept", "onFd", "on_fd" };
        JSValue func = get_handler_func(ctx, s->handler, names, countof(names));
        if (!JS_IsException(func) && !JS_IsUndefined(func)) {
            JSValue args[4] = {
                JS_DupValue(ctx, s->self),
                JS_NewInt32(ctx, (int)cfd),
                ip[0] ? JS_NewString(ctx, ip) : JS_NULL,
                port > 0 ? JS_NewInt32(ctx, port) : JS_NULL
            };
            JSValue ret = JS_Call(ctx, func, s->handler, 4, (JSValueConst *)args);
            for (int i = 0; i < 4; i++) JS_FreeValue(ctx, args[i]);
            if (JS_IsException(ret)) {
                xjs_dump_error_with_prefix(ctx, "xnet onAccept: ");
            } else {
                int b = JS_ToBool(ctx, ret);
                transfer = (b < 0) ? true : (b != 0);
                JS_FreeValue(ctx, ret);
            }
        } else if (JS_IsException(func)) {
            xjs_dump_error_with_prefix(ctx, "xnet onAccept: ");
        }
        JS_FreeValue(ctx, func);

        if (!transfer) {
            xsock_close(cfd);
        }
    }
}

static void listener_error_cb(SOCKET_T fd, int mask, void *clientData,
                              xPollRequest *submit_arg) {
    (void)fd;
    (void)mask;
    (void)submit_arg;
    listener_close_internal((XJSNetListener *)clientData, "socket_error", 1);
}

static JSValue js_conn_fd(JSContext *ctx, JSValueConst this_val,
                          int argc, JSValueConst *argv) {
    (void)argc;
    (void)argv;
    XJSNetConn *c = check_conn(ctx, this_val);
    if (!c) return JS_EXCEPTION;
    if (!c->ch || c->closed) return JS_NULL;
    return JS_NewInt32(ctx, (int)xchannel_fd(c->ch));
}

static JSValue js_conn_peer(JSContext *ctx, JSValueConst this_val,
                            int argc, JSValueConst *argv) {
    (void)argc;
    (void)argv;
    XJSNetConn *c = check_conn(ctx, this_val);
    if (!c) return JS_EXCEPTION;
    JSValue obj = JS_NewObject(ctx);
    xjs_set_string_prop(ctx, obj, "ip", c->peer_ip[0] ? c->peer_ip : NULL);
    if (c->peer_port > 0) xjs_set_i32_prop(ctx, obj, "port", c->peer_port);
    else JS_SetPropertyStr(ctx, obj, "port", JS_NULL);
    return obj;
}

static JSValue js_conn_is_closed(JSContext *ctx, JSValueConst this_val,
                                 int argc, JSValueConst *argv) {
    (void)argc;
    (void)argv;
    XJSNetConn *c = check_conn(ctx, this_val);
    if (!c) return JS_EXCEPTION;
    return JS_NewBool(ctx, c->closed || !c->ch || xchannel_is_closed(c->ch));
}

static JSValue js_conn_close(JSContext *ctx, JSValueConst this_val,
                             int argc, JSValueConst *argv) {
    XJSNetConn *c = check_conn(ctx, this_val);
    if (!c) return JS_EXCEPTION;
    const char *reason = "closed";
    int free_reason = 0;
    if (argc >= 1 && !JS_IsUndefined(argv[0]) && !JS_IsNull(argv[0])) {
        reason = JS_ToCString(ctx, argv[0]);
        if (!reason) return JS_EXCEPTION;
        free_reason = 1;
    }
    if (c->ch && !c->closed) xchannel_close(c->ch, reason);
    if (free_reason) JS_FreeCString(ctx, reason);
    return JS_TRUE;
}

static JSValue conn_send_common(JSContext *ctx, JSValueConst this_val,
                                int argc, JSValueConst *argv, int raw) {
    XJSNetConn *c = check_conn(ctx, this_val);
    if (!c) return JS_EXCEPTION;
    if (argc < 1) return JS_ThrowTypeError(ctx, "xnet.conn.send: data expected");
    XJSBytes bytes;
    if (xjs_to_bytes(ctx, argv[0], &bytes) != 0) return JS_EXCEPTION;
    int rc = conn_send_bytes(c, bytes.data, bytes.len, raw);
    xjs_free_bytes(ctx, &bytes);
    return send_result(ctx, rc);
}

static JSValue js_conn_send(JSContext *ctx, JSValueConst this_val,
                            int argc, JSValueConst *argv) {
    return conn_send_common(ctx, this_val, argc, argv, 0);
}

static JSValue js_conn_send_raw(JSContext *ctx, JSValueConst this_val,
                                int argc, JSValueConst *argv) {
    return conn_send_common(ctx, this_val, argc, argv, 1);
}

static JSValue js_conn_send_file_response(JSContext *ctx, JSValueConst this_val,
                                          int argc, JSValueConst *argv) {
    XJSNetConn *c = check_conn(ctx, this_val);
    if (!c) return JS_EXCEPTION;
    if (argc < 2) {
        return JS_ThrowTypeError(ctx, "xnet.conn.sendFileResponse: header and path expected");
    }
    XJSBytes header;
    if (xjs_to_bytes(ctx, argv[0], &header) != 0) return JS_EXCEPTION;
    const char *path = JS_ToCString(ctx, argv[1]);
    if (!path) {
        xjs_free_bytes(ctx, &header);
        return JS_EXCEPTION;
    }
    int64_t offset = 0;
    int64_t length = -1;
    if (argc >= 3 && JS_ToInt64(ctx, &offset, argv[2]) < 0) {
        JS_FreeCString(ctx, path);
        xjs_free_bytes(ctx, &header);
        return JS_EXCEPTION;
    }
    if (argc >= 4 && JS_ToInt64(ctx, &length, argv[3]) < 0) {
        JS_FreeCString(ctx, path);
        xjs_free_bytes(ctx, &header);
        return JS_EXCEPTION;
    }

    int rc = (c && c->ch && !c->closed)
        ? xchannel_send_file_raw(c->ch, header.data, header.len, path,
                                 (long long)offset, (long long)length)
        : -1;
    JS_FreeCString(ctx, path);
    xjs_free_bytes(ctx, &header);
    return send_result(ctx, rc);
}

static JSValue js_conn_set_handler(JSContext *ctx, JSValueConst this_val,
                                   int argc, JSValueConst *argv) {
    XJSNetConn *c = check_conn(ctx, this_val);
    if (!c) return JS_EXCEPTION;
    if (argc < 1 || (!JS_IsObject(argv[0]) && !JS_IsFunction(ctx, argv[0]))) {
        return JS_ThrowTypeError(ctx, "xnet.conn.setHandler: handler object/function expected");
    }
    JS_FreeValue(ctx, c->handler);
    c->handler = JS_DupValue(ctx, argv[0]);
    return JS_DupValue(ctx, this_val);
}

static int valid_crlf_delim(const char *delim, size_t delim_len) {
    return !delim || (delim_len == 2 && delim[0] == '\r' && delim[1] == '\n');
}

static int apply_framing(XJSNetConn *c, const char *mode,
                         const char *delim, size_t delim_len) {
    if (!c->ch || c->closed) return -2;
    xChannelConfig cfg = XCHANNEL_CONFIG_INIT;
    if (strcmp(mode, "raw") == 0) {
        cfg.frame = XCHANNEL_FRAME_RAW;
    } else if (strcmp(mode, "len32") == 0 || strcmp(mode, "len32be") == 0) {
        cfg.frame = XCHANNEL_FRAME_LEN32;
    } else if (strcmp(mode, "len16") == 0 || strcmp(mode, "len16be") == 0) {
        cfg.frame = XCHANNEL_FRAME_LEN16;
    } else if (strcmp(mode, "line") == 0 ||
               strcmp(mode, "crlf") == 0 ||
               strcmp(mode, "delimiter") == 0) {
        if (!valid_crlf_delim(delim, delim_len)) return -1;
        cfg.frame = XCHANNEL_FRAME_CRLF;
    } else {
        return -1;
    }
    return xchannel_set_framing(c->ch, &cfg);
}

static void apply_size_option(JSContext *ctx, JSValueConst obj, const char *a,
                              const char *b, void (*setter)(xChannel *, size_t),
                              xChannel *ch) {
    JSValue v = JS_GetPropertyStr(ctx, obj, a);
    if (JS_IsUndefined(v) && b) {
        JS_FreeValue(ctx, v);
        v = JS_GetPropertyStr(ctx, obj, b);
    }
    int64_t n = 0;
    if (!JS_IsUndefined(v) && !JS_IsNull(v) && JS_ToInt64(ctx, &n, v) == 0 && n >= 0) {
        setter(ch, (size_t)n);
    }
    JS_FreeValue(ctx, v);
}

static JSValue js_conn_set_framing(JSContext *ctx, JSValueConst this_val,
                                   int argc, JSValueConst *argv) {
    XJSNetConn *c = check_conn(ctx, this_val);
    if (!c) return JS_EXCEPTION;
    if (!c->ch || c->closed) {
        return JS_ThrowInternalError(ctx, "xnet.conn.setFraming on closed connection");
    }
    if (argc < 1) return JS_DupValue(ctx, this_val);

    const char *mode = NULL;
    const char *delim = NULL;
    size_t delim_len = 0;
    JSValue mode_val = JS_UNDEFINED;
    JSValue delim_val = JS_UNDEFINED;

    if (JS_IsObject(argv[0]) && !JS_IsString(argv[0])) {
        apply_size_option(ctx, argv[0], "maxPacket", "max_packet",
                          xchannel_set_max_packet, c->ch);
        apply_size_option(ctx, argv[0], "maxSend", "max_send",
                          xchannel_set_max_send, c->ch);
        apply_size_option(ctx, argv[0], "maxRecv", "max_recv",
                          xchannel_set_max_recv, c->ch);
        mode_val = JS_GetPropertyStr(ctx, argv[0], "type");
        if (JS_IsUndefined(mode_val)) {
            JS_FreeValue(ctx, mode_val);
            mode_val = JS_GetPropertyStr(ctx, argv[0], "mode");
        }
        if (JS_IsUndefined(mode_val) || JS_IsNull(mode_val)) {
            JS_FreeValue(ctx, mode_val);
            return JS_DupValue(ctx, this_val);
        }
        mode = JS_ToCString(ctx, mode_val);
        delim_val = JS_GetPropertyStr(ctx, argv[0], "delimiter");
        if (!JS_IsUndefined(delim_val) && !JS_IsNull(delim_val)) {
            delim = JS_ToCStringLen(ctx, &delim_len, delim_val);
        }
    } else {
        mode = JS_ToCString(ctx, argv[0]);
        if (argc >= 2) {
            delim = JS_ToCStringLen(ctx, &delim_len, argv[1]);
        }
    }

    if (!mode) {
        JS_FreeValue(ctx, mode_val);
        JS_FreeValue(ctx, delim_val);
        return JS_EXCEPTION;
    }
    int rc = apply_framing(c, mode, delim, delim_len);
    JS_FreeCString(ctx, mode);
    if (delim) JS_FreeCString(ctx, delim);
    JS_FreeValue(ctx, mode_val);
    JS_FreeValue(ctx, delim_val);
    if (rc != 0) {
        return JS_ThrowInternalError(ctx, "unsupported framing mode");
    }
    return JS_DupValue(ctx, this_val);
}

static JSValue js_conn_detach(JSContext *ctx, JSValueConst this_val,
                              int argc, JSValueConst *argv) {
    (void)argc;
    (void)argv;
    XJSNetConn *c = check_conn(ctx, this_val);
    if (!c) return JS_EXCEPTION;
    if (!c->ch || c->closed) {
        return JS_ThrowInternalError(ctx, "xnet.conn.detach on closed connection");
    }
    SOCKET_T fd = xchannel_release_fd(c->ch);
    if (fd == INVALID_SOCKET_VAL) {
        return JS_ThrowInternalError(ctx, "xnet.conn.detach failed");
    }
    c->closed = true;
    XJSActor *a = xjs_actor(c->ctx);
    if (a) a->conn_count--;   /* detach bypasses close_cb's decrement */
    conn_destroy_channel(c);
    return JS_NewInt32(ctx, (int)fd);
}

static JSValue js_listener_fd(JSContext *ctx, JSValueConst this_val,
                              int argc, JSValueConst *argv) {
    (void)argc;
    (void)argv;
    XJSNetListener *s = check_listener(ctx, this_val);
    if (!s) return JS_EXCEPTION;
    if (s->closed || s->fd == INVALID_SOCKET_VAL) return JS_NULL;
    return JS_NewInt32(ctx, (int)s->fd);
}

static JSValue js_listener_close(JSContext *ctx, JSValueConst this_val,
                                 int argc, JSValueConst *argv) {
    XJSNetListener *s = check_listener(ctx, this_val);
    if (!s) return JS_EXCEPTION;
    const char *reason = "closed";
    int free_reason = 0;
    if (argc >= 1 && !JS_IsUndefined(argv[0]) && !JS_IsNull(argv[0])) {
        reason = JS_ToCString(ctx, argv[0]);
        if (!reason) return JS_EXCEPTION;
        free_reason = 1;
    }
    listener_close_internal(s, reason, 1);
    if (free_reason) JS_FreeCString(ctx, reason);
    return JS_TRUE;
}

static void xjs_conn_finalizer(JSRuntime *rt, JSValueConst val) {
    XJSNetConn *c = (XJSNetConn *)JS_GetOpaque(val, g_xjs_conn_class_id);
    if (!c) return;
    conn_destroy_channel(c);
    if (c->ctx) conn_list_remove(xjs_actor(c->ctx), c);
    if (!JS_IsUndefined(c->handler)) JS_FreeValueRT(rt, c->handler);
    js_free_rt(rt, c);
}

static void xjs_conn_mark(JSRuntime *rt, JSValueConst val, JS_MarkFunc *mark_func) {
    XJSNetConn *c = (XJSNetConn *)JS_GetOpaque(val, g_xjs_conn_class_id);
    if (!c) return;
    JS_MarkValue(rt, c->handler, mark_func);
}

static void xjs_listener_finalizer(JSRuntime *rt, JSValueConst val) {
    XJSNetListener *s = (XJSNetListener *)JS_GetOpaque(val, g_xjs_listener_class_id);
    if (!s) return;
    if (!s->closed && s->fd != INVALID_SOCKET_VAL) {
        xpoll_del_event(s->fd, XPOLL_ALL);
        xsock_close(s->fd);
        s->fd = INVALID_SOCKET_VAL;
    }
    if (s->ctx) listener_list_remove(xjs_actor(s->ctx), s);
    if (!JS_IsUndefined(s->handler)) JS_FreeValueRT(rt, s->handler);
    js_free_rt(rt, s);
}

static void xjs_listener_mark(JSRuntime *rt, JSValueConst val, JS_MarkFunc *mark_func) {
    XJSNetListener *s = (XJSNetListener *)JS_GetOpaque(val, g_xjs_listener_class_id);
    if (!s) return;
    JS_MarkValue(rt, s->handler, mark_func);
}

static const JSCFunctionListEntry conn_proto_funcs[] = {
    JS_CFUNC_DEF("fd", 0, js_conn_fd),
    JS_CFUNC_DEF("peer", 0, js_conn_peer),
    JS_CFUNC_DEF("isClosed", 0, js_conn_is_closed),
    JS_CFUNC_DEF("is_closed", 0, js_conn_is_closed),
    JS_CFUNC_DEF("close", 1, js_conn_close),
    JS_CFUNC_DEF("send", 1, js_conn_send),
    JS_CFUNC_DEF("sendRaw", 1, js_conn_send_raw),
    JS_CFUNC_DEF("send_raw", 1, js_conn_send_raw),
    JS_CFUNC_DEF("sendPacket", 1, js_conn_send),
    JS_CFUNC_DEF("send_packet", 1, js_conn_send),
    JS_CFUNC_DEF("sendFileResponse", 4, js_conn_send_file_response),
    JS_CFUNC_DEF("send_file_response", 4, js_conn_send_file_response),
    JS_CFUNC_DEF("setHandler", 1, js_conn_set_handler),
    JS_CFUNC_DEF("set_handler", 1, js_conn_set_handler),
    JS_CFUNC_DEF("setFraming", 1, js_conn_set_framing),
    JS_CFUNC_DEF("set_framing", 1, js_conn_set_framing),
    JS_CFUNC_DEF("detach", 0, js_conn_detach),
};

static const JSCFunctionListEntry listener_proto_funcs[] = {
    JS_CFUNC_DEF("fd", 0, js_listener_fd),
    JS_CFUNC_DEF("close", 1, js_listener_close),
};

static int ensure_xnet_classes(JSContext *ctx) {
    JSRuntime *rt = JS_GetRuntime(ctx);
    xjs_alloc_class_ids(rt);

    if (!JS_IsRegisteredClass(rt, g_xjs_conn_class_id)) {
        JSClassDef def = {
            "XNetConn",
            .finalizer = xjs_conn_finalizer,
            .gc_mark = xjs_conn_mark,
        };
        if (JS_NewClass(rt, g_xjs_conn_class_id, &def) < 0) return -1;
    }
    if (!JS_IsRegisteredClass(rt, g_xjs_listener_class_id)) {
        JSClassDef def = {
            "XNetListener",
            .finalizer = xjs_listener_finalizer,
            .gc_mark = xjs_listener_mark,
        };
        if (JS_NewClass(rt, g_xjs_listener_class_id, &def) < 0) return -1;
    }

    JSValue conn_proto = JS_NewObject(ctx);
    if (JS_IsException(conn_proto)) return -1;
    JS_SetPropertyFunctionList(ctx, conn_proto, conn_proto_funcs, countof(conn_proto_funcs));
    JS_SetClassProto(ctx, g_xjs_conn_class_id, conn_proto);

    JSValue listener_proto = JS_NewObject(ctx);
    if (JS_IsException(listener_proto)) return -1;
    JS_SetPropertyFunctionList(ctx, listener_proto, listener_proto_funcs,
                               countof(listener_proto_funcs));
    JS_SetClassProto(ctx, g_xjs_listener_class_id, listener_proto);
    return 0;
}

static int xnet_os_random(unsigned char *out, size_t n) {
    if (n == 0) return 0;
#ifdef _WIN32
    NTSTATUS rc = BCryptGenRandom(NULL, (PUCHAR)out, (ULONG)n,
                                  BCRYPT_USE_SYSTEM_PREFERRED_RNG);
    return rc == 0 ? 0 : -1;
#else
    int fd = open("/dev/urandom", O_RDONLY | O_CLOEXEC);
    if (fd < 0) return -1;
    size_t off = 0;
    while (off < n) {
        ssize_t r = read(fd, out + off, n - off);
        if (r > 0) {
            off += (size_t)r;
            continue;
        }
        if (r < 0 && (errno == EINTR || errno == EAGAIN)) continue;
        close(fd);
        return -1;
    }
    close(fd);
    return 0;
#endif
}

static int xjs_socket_acquire(void) {
    if (atomic_fetch_add(&g_socket_refs, 1) == 0) {
        if (socket_init() != 0) {
            atomic_fetch_sub(&g_socket_refs, 1);
            return -1;
        }
    }
    return 0;
}

static void xjs_socket_release(void) {
    if (atomic_fetch_sub(&g_socket_refs, 1) == 1) {
        socket_cleanup();
    }
}

static JSValue js_xnet_init(JSContext *ctx, JSValueConst this_val,
                            int argc, JSValueConst *argv) {
    (void)this_val;
    /* Acquire the process socket ref and the poller together, only on the
    ** thread's first init (g_xpoll_refs 0->1), so they pair 1:1 with the
    ** release in js_xnet_uninit at 1->0. Acquiring unconditionally would
    ** leave g_socket_refs stuck above zero after repeated init/uninit. */
    if (g_xpoll_refs == 0) {
        if (xjs_socket_acquire() != 0) {
            return JS_ThrowInternalError(ctx, "xnet.init: socket_init failed");
        }
        int rc = xpoll_init();
        if (rc != 0) {
            xjs_socket_release();
            return JS_ThrowInternalError(ctx, "xnet.init: xpoll_init failed: %d", rc);
        }
        if (xthread_current()) xthread_wakeup_init();
    }
    g_xpoll_refs++;
    if (argc >= 1) {
        int32_t setsize = 0;
        if (JS_ToInt32(ctx, &setsize, argv[0]) < 0) return JS_EXCEPTION;
        if (setsize > 0) xpoll_resize(setsize);
    }
    return JS_TRUE;
}

static JSValue js_xnet_uninit(JSContext *ctx, JSValueConst this_val,
                              int argc, JSValueConst *argv) {
    (void)this_val;
    (void)argc;
    (void)argv;
    xjs_xnet_release_context(ctx);
    if (g_xpoll_refs > 0 && --g_xpoll_refs == 0) {
        if (xthread_current()) xthread_wakeup_uninit();
        xpoll_uninit();
        xjs_socket_release();
    }
    return JS_UNDEFINED;
}

static JSValue js_xnet_poll(JSContext *ctx, JSValueConst this_val,
                            int argc, JSValueConst *argv) {
    (void)this_val;
    int32_t timeout_ms = 0;
    if (argc >= 1 && JS_ToInt32(ctx, &timeout_ms, argv[0]) < 0) return JS_EXCEPTION;
    return JS_NewInt32(ctx, xpoll_poll((int)timeout_ms));
}

static JSValue js_xnet_name(JSContext *ctx, JSValueConst this_val,
                            int argc, JSValueConst *argv) {
    (void)this_val;
    (void)argc;
    (void)argv;
    return JS_NewString(ctx, xpoll_name());
}

static JSValue js_xnet_get_stats(JSContext *ctx, JSValueConst this_val,
                                 int argc, JSValueConst *argv) {
    (void)this_val;
    (void)argc;
    (void)argv;
    XJSActor *a = xjs_actor(ctx);
    int cur_id = xthread_current_id();
    JSValue obj = JS_NewObject(ctx);
    if (JS_IsException(obj)) return obj;
    xjs_set_i32_prop(ctx, obj, "fdCount", xpoll_fd_count());
    xjs_set_i32_prop(ctx, obj, "fd_count", xpoll_fd_count());
    xjs_set_i32_prop(ctx, obj, "connCount", a->conn_count < 0 ? 0 : a->conn_count);
    xjs_set_i32_prop(ctx, obj, "conn_count", a->conn_count < 0 ? 0 : a->conn_count);
    xjs_set_i64_prop(ctx, obj, "bytesSent", (int64_t)a->acc_sent);
    xjs_set_i64_prop(ctx, obj, "bytes_sent", (int64_t)a->acc_sent);
    xjs_set_i64_prop(ctx, obj, "bytesRecv", (int64_t)a->acc_recv);
    xjs_set_i64_prop(ctx, obj, "bytes_recv", (int64_t)a->acc_recv);
    xjs_set_i32_prop(ctx, obj, "timerCount", xtimer_count());
    xjs_set_i32_prop(ctx, obj, "timer_count", xtimer_count());
    int qdepth = xthread_get_queue_depth(cur_id);
    int qmax = xthread_get_queue_max(cur_id);
    xjs_set_i32_prop(ctx, obj, "queueDepth", qdepth < 0 ? 0 : qdepth);
    xjs_set_i32_prop(ctx, obj, "queue_depth", qdepth < 0 ? 0 : qdepth);
    xjs_set_i32_prop(ctx, obj, "queueMax", qmax < 0 ? 0 : qmax);
    xjs_set_i32_prop(ctx, obj, "queue_max", qmax < 0 ? 0 : qmax);
    return obj;
}

static JSValue xnet_listen_common(JSContext *ctx, int argc, JSValueConst *argv,
                                  xFileProc accept_cb) {
    const char *host = NULL;
    int32_t port = 0;
    int handler_idx = 0;

    if (argc < 2) {
        return JS_ThrowTypeError(ctx, "xnet.listen: port/handler expected");
    }
    if (JS_IsNumber(argv[0]) && !JS_IsString(argv[0])) {
        if (JS_ToInt32(ctx, &port, argv[0]) < 0) return JS_EXCEPTION;
        handler_idx = 1;
    } else {
        if (!JS_IsNull(argv[0]) && !JS_IsUndefined(argv[0])) {
            host = JS_ToCString(ctx, argv[0]);
            if (!host) return JS_EXCEPTION;
        }
        if (JS_ToInt32(ctx, &port, argv[1]) < 0) {
            if (host) JS_FreeCString(ctx, host);
            return JS_EXCEPTION;
        }
        handler_idx = 2;
    }
    if (handler_idx >= argc || (!JS_IsObject(argv[handler_idx]) &&
                                !JS_IsFunction(ctx, argv[handler_idx]))) {
        if (host) JS_FreeCString(ctx, host);
        return JS_ThrowTypeError(ctx, "xnet.listen: handler object/function expected");
    }

    char err[XSOCK_ERR_LEN] = {0};
    SOCKET_T fd = xsock_listen(err, host, port);
    if (host) JS_FreeCString(ctx, host);
    if (fd == INVALID_SOCKET_VAL) {
        return JS_ThrowInternalError(ctx, "%s", err[0] ? err : "listen failed");
    }
    if (xsock_set_nonblock(err, fd) != XSOCK_OK) {
        xsock_close(fd);
        return JS_ThrowInternalError(ctx, "%s", err[0] ? err : "set nonblock failed");
    }

    if (ensure_xnet_classes(ctx) != 0) {
        xsock_close(fd);
        return JS_EXCEPTION;
    }
    JSValue obj = JS_NewObjectClass(ctx, g_xjs_listener_class_id);
    if (JS_IsException(obj)) {
        xsock_close(fd);
        return obj;
    }
    XJSNetListener *s = (XJSNetListener *)js_mallocz(ctx, sizeof(*s));
    if (!s) {
        xsock_close(fd);
        JS_FreeValue(ctx, obj);
        return JS_ThrowOutOfMemory(ctx);
    }
    s->ctx = ctx;
    s->fd = fd;
    s->self = JS_DupValue(ctx, obj);
    s->handler = JS_DupValue(ctx, argv[handler_idx]);
    s->closed = false;
    JS_SetOpaque(obj, s);
    listener_list_add(xjs_actor(ctx), s);

    if (xpoll_add_event(fd, XPOLL_READABLE, accept_cb, NULL, listener_error_cb, s) != 0) {
        listener_close_internal(s, "poll_error", 0);
        JS_FreeValue(ctx, obj);
        return JS_ThrowInternalError(ctx, "xpoll_add_event failed");
    }
    return obj;
}

static JSValue js_xnet_listen(JSContext *ctx, JSValueConst this_val,
                              int argc, JSValueConst *argv) {
    (void)this_val;
    return xnet_listen_common(ctx, argc, argv, listener_accept_cb);
}

static JSValue js_xnet_listen_fd(JSContext *ctx, JSValueConst this_val,
                                 int argc, JSValueConst *argv) {
    (void)this_val;
    return xnet_listen_common(ctx, argc, argv, listener_accept_fd_cb);
}

static JSValue js_xnet_attach(JSContext *ctx, JSValueConst this_val,
                              int argc, JSValueConst *argv) {
    (void)this_val;
    if (argc < 2) return JS_ThrowTypeError(ctx, "xnet.attach: fd and handler expected");
    int32_t fd_i = 0;
    if (JS_ToInt32(ctx, &fd_i, argv[0]) < 0) return JS_EXCEPTION;
    if (!JS_IsObject(argv[1]) && !JS_IsFunction(ctx, argv[1])) {
        return JS_ThrowTypeError(ctx, "xnet.attach: handler object/function expected");
    }
    const char *ip = NULL;
    int32_t port = 0;
    if (argc >= 3 && !JS_IsUndefined(argv[2]) && !JS_IsNull(argv[2])) {
        ip = JS_ToCString(ctx, argv[2]);
        if (!ip) return JS_EXCEPTION;
    }
    if (argc >= 4 && JS_ToInt32(ctx, &port, argv[3]) < 0) {
        if (ip) JS_FreeCString(ctx, ip);
        return JS_EXCEPTION;
    }

    SOCKET_T fd = (SOCKET_T)fd_i;
    if (fd == INVALID_SOCKET_VAL) {
        if (ip) JS_FreeCString(ctx, ip);
        return JS_ThrowInternalError(ctx, "invalid fd");
    }
    char err[XSOCK_ERR_LEN] = {0};
    if (xsock_set_nonblock(err, fd) != XSOCK_OK) {
        xsock_close(fd);
        if (ip) JS_FreeCString(ctx, ip);
        return JS_ThrowInternalError(ctx, "%s", err[0] ? err : "set nonblock failed");
    }
    xChannel *ch = xchannel_create(fd, &s_js_conn_cfg);
    if (!ch) {
        xsock_close(fd);
        if (ip) JS_FreeCString(ctx, ip);
        return JS_ThrowInternalError(ctx, "xchannel_create failed");
    }
    JSValue obj = JS_UNDEFINED;
    XJSNetConn *c = push_conn(ctx, &obj, ch, argv[1], ip, port);
    if (ip) JS_FreeCString(ctx, ip);
    if (!c) {
        xchannel_destroy(ch);
        return JS_EXCEPTION;
    }
    xjs_actor(ctx)->conn_count++;
    js_conn_connect_cb(ch, c);
    if (!c->closed && c->ch && xchannel_attach(c->ch) != 0) {
        xchannel_close(c->ch, "poll_error");
    }
    return obj;
}

static JSValue js_xnet_connect(JSContext *ctx, JSValueConst this_val,
                               int argc, JSValueConst *argv) {
    (void)this_val;
    if (argc < 3) return JS_ThrowTypeError(ctx, "xnet.connect: host, port and handler expected");
    const char *host = JS_ToCString(ctx, argv[0]);
    if (!host) return JS_EXCEPTION;
    int32_t port = 0;
    if (JS_ToInt32(ctx, &port, argv[1]) < 0) {
        JS_FreeCString(ctx, host);
        return JS_EXCEPTION;
    }
    if (!JS_IsObject(argv[2]) && !JS_IsFunction(ctx, argv[2])) {
        JS_FreeCString(ctx, host);
        return JS_ThrowTypeError(ctx, "xnet.connect: handler object/function expected");
    }
    char err[XSOCK_ERR_LEN] = {0};
    SOCKET_T fd = xsock_tcp_aconnect(err, host, port);
    if (fd == INVALID_SOCKET_VAL) {
        JS_FreeCString(ctx, host);
        return JS_ThrowInternalError(ctx, "%s", err[0] ? err : "connect failed");
    }
    xChannel *ch = xchannel_create(fd, &s_js_conn_cfg);
    if (!ch) {
        xsock_close(fd);
        JS_FreeCString(ctx, host);
        return JS_ThrowInternalError(ctx, "xchannel_create failed");
    }
    JSValue obj = JS_UNDEFINED;
    XJSNetConn *c = push_conn(ctx, &obj, ch, argv[2], host, port);
    JS_FreeCString(ctx, host);
    if (!c) {
        xchannel_destroy(ch);
        return JS_EXCEPTION;
    }
    xjs_actor(ctx)->conn_count++;
    if (xchannel_attach_connect(ch) != 0) {
        xjs_actor(ctx)->conn_count--;
        conn_destroy_channel(c);
        conn_release_refs_ctx(c);
        JS_FreeValue(ctx, obj);
        return JS_ThrowInternalError(ctx, "xchannel_attach_connect failed");
    }
    return obj;
}

static JSValue js_xnet_close_fd(JSContext *ctx, JSValueConst this_val,
                                int argc, JSValueConst *argv) {
    (void)this_val;
    if (argc < 1) return JS_ThrowTypeError(ctx, "xnet.closeFd: fd expected");
    int32_t fd = 0;
    if (JS_ToInt32(ctx, &fd, argv[0]) < 0) return JS_EXCEPTION;
    if (fd < 0) return JS_ThrowRangeError(ctx, "xnet.closeFd: bad fd");
    xsock_close((SOCKET_T)fd);
    return JS_UNDEFINED;
}

static JSValue js_xnet_random_bytes(JSContext *ctx, JSValueConst this_val,
                                    int argc, JSValueConst *argv) {
    (void)this_val;
    if (argc < 1) return JS_ThrowTypeError(ctx, "xnet.randomBytes: length expected");
    int32_t n = 0;
    if (JS_ToInt32(ctx, &n, argv[0]) < 0) return JS_EXCEPTION;
    if (n <= 0 || n > 4096) {
        return JS_ThrowRangeError(ctx, "xnet.randomBytes: length must be 1..4096");
    }
    unsigned char buf[4096];
    if (xnet_os_random(buf, (size_t)n) != 0) {
        return JS_ThrowInternalError(ctx, "xnet.randomBytes: OS RNG failed");
    }
    return JS_NewUint8ArrayCopy(ctx, buf, (size_t)n);
}

static const JSCFunctionListEntry xnet_funcs[] = {
    JS_CFUNC_DEF("init", 1, js_xnet_init),
    JS_CFUNC_DEF("uninit", 0, js_xnet_uninit),
    JS_CFUNC_DEF("poll", 1, js_xnet_poll),
    JS_CFUNC_DEF("name", 0, js_xnet_name),
    JS_CFUNC_DEF("getStats", 0, js_xnet_get_stats),
    JS_CFUNC_DEF("get_stats", 0, js_xnet_get_stats),
    JS_CFUNC_DEF("listen", 3, js_xnet_listen),
    JS_CFUNC_DEF("listenFd", 3, js_xnet_listen_fd),
    JS_CFUNC_DEF("listen_fd", 3, js_xnet_listen_fd),
    JS_CFUNC_DEF("connect", 3, js_xnet_connect),
    JS_CFUNC_DEF("attach", 4, js_xnet_attach),
    JS_CFUNC_DEF("connectFd", 4, js_xnet_attach),
    JS_CFUNC_DEF("connect_fd", 4, js_xnet_attach),
    JS_CFUNC_DEF("closeFd", 1, js_xnet_close_fd),
    JS_CFUNC_DEF("close_fd", 1, js_xnet_close_fd),
    JS_CFUNC_DEF("randomBytes", 1, js_xnet_random_bytes),
    JS_CFUNC_DEF("random_bytes", 1, js_xnet_random_bytes),
    JS_PROP_INT32_DEF("READABLE", XPOLL_READABLE, JS_PROP_ENUMERABLE),
    JS_PROP_INT32_DEF("WRITABLE", XPOLL_WRITABLE, JS_PROP_ENUMERABLE),
    JS_PROP_INT32_DEF("ERROR", XPOLL_ERROR, JS_PROP_ENUMERABLE),
    JS_PROP_INT32_DEF("CLOSE", XPOLL_CLOSE, JS_PROP_ENUMERABLE),
};

JSValue xjs_new_xnet_object(JSContext *ctx) {
    if (ensure_xnet_classes(ctx) != 0) return JS_EXCEPTION;
    JSValue obj = JS_NewObject(ctx);
    if (JS_IsException(obj)) return obj;
    JS_SetPropertyFunctionList(ctx, obj, xnet_funcs, countof(xnet_funcs));
    return obj;
}

static int js_xnet_module_init(JSContext *ctx, JSModuleDef *m) {
    if (ensure_xnet_classes(ctx) != 0) return -1;
    if (JS_SetModuleExportList(ctx, m, xnet_funcs, countof(xnet_funcs)) < 0) {
        return -1;
    }
    JS_SetModuleExport(ctx, m, "default", xjs_new_xnet_object(ctx));
    return 0;
}

JSModuleDef *js_init_module_xnet(JSContext *ctx, const char *module_name) {
    JSModuleDef *m = JS_NewCModule(ctx, module_name, js_xnet_module_init);
    if (!m) return NULL;
    JS_AddModuleExportList(ctx, m, xnet_funcs, countof(xnet_funcs));
    JS_AddModuleExport(ctx, m, "default");
    return m;
}

void xjs_xnet_release_context(JSContext *ctx) {
    XJSActor *a = xjs_actor(ctx);
    if (!a) return;

    XJSNetListener *s = a->listeners;
    while (s) {
        XJSNetListener *next = s->next;
        if (!s->closed && s->fd != INVALID_SOCKET_VAL) {
            xpoll_del_event(s->fd, XPOLL_ALL);
            xsock_close(s->fd);
            s->fd = INVALID_SOCKET_VAL;
        }
        s->closed = true;
        listener_list_remove(a, s);
        listener_release_refs_ctx(s);
        s = next;
    }

    XJSNetConn *c = a->conns;
    while (c) {
        XJSNetConn *next = c->next;
        c->closed = true;
        conn_destroy_channel(c);
        conn_list_remove(a, c);
        conn_release_refs_ctx(c);
        c = next;
    }
}
