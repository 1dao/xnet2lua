#ifndef XJS_ACTOR_H
#define XJS_ACTOR_H

#include "xjs.h"   /* JSContext / JSValue / JS_GetContextOpaque */

#ifdef __cplusplus
extern "C" {
#endif

/* Node definitions stay private to their modules; we only hold list heads. */
typedef struct XJSNetConn     XJSNetConn;
typedef struct XJSNetListener XJSNetListener;
typedef struct XJSTimer       XJSTimer;

/* Per-actor (per-JSContext) state. One JSRuntime/pool thread hosts many of
** these. Reached from any callback via the node's ->ctx field. */
typedef struct XJSActor {
    JSContext      *ctx;
    /* xnet */
    XJSNetConn     *conns;
    XJSNetListener *listeners;
    int             conn_count;
    uint64_t        acc_sent;
    uint64_t        acc_recv;
    /* xtimer */
    XJSTimer       *timers;
    /* xthread message handler (teardown-correct only; routing is L3) */
    JSValue         msg_handler;
    bool            msg_handler_set;
} XJSActor;

static inline XJSActor *xjs_actor(JSContext *ctx) {
    return (XJSActor *)JS_GetContextOpaque(ctx);
}

#ifdef __cplusplus
}
#endif

#endif /* XJS_ACTOR_H */
