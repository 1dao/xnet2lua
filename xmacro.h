/* xmacro.h — route the libc malloc family through rpmalloc.
**
** Build-time toggle: -DXMACRO_USE_RPMALLOC=0 falls back to libc.
**   • Default (=1): allocation macros expand to rp* equivalents and the
**     lifecycle hooks (rpmalloc_initialize / rpmalloc_thread_initialize /
**     rpmalloc_thread_finalize / rpmalloc_finalize) reach the real functions.
**     rpmalloc.c must be linked.
**   • Disabled (=0): macros expand to the libc names and the lifecycle hooks
**     become no-ops. rpmalloc.c is not needed and not linked. Useful for
**     AddressSanitizer / Valgrind / A-B perf comparisons.
**
** USAGE:
**   - Project .c files: include this header LAST, AFTER all standard headers
**     (<stdlib.h>, <string.h>, etc.) AND after any 3rd-party header that
**     declares fields named `.free` / `.malloc` (notably yyjson.h). Otherwise
**     function-like macros mangle those declarations.
**   - Project .h files that themselves call malloc/free (xhash.h, xheapmin.h):
**     include this at the top so consumers don't have to remember.
**   - Do NOT include in 3rd-party .c (yyjson, miniz, mbedtls, minilua,
**     rpmalloc itself, LuaJIT). Those libs allocate with libc internally and
**     must free with libc internally; mixing allocators corrupts heaps.
**
** Cross-thread alloc/free is fine: rpmalloc routes via the owning thread's
** deferred-free queue. The one invariant that must hold is "allocator stays
** consistent end-to-end" — any pointer that came from rpmalloc must be freed
** with rpfree, and vice versa.
*/
#ifndef XMACRO_H
#define XMACRO_H

#ifndef XMACRO_USE_RPMALLOC
#define XMACRO_USE_RPMALLOC 1
#endif

/* Pull in libc declarations BEFORE shadowing the names. If a translation
** unit later includes <stdlib.h> via some other header, the include guard
** there will short-circuit and the macros never see the prototypes. */
#include <stdlib.h>
#include <string.h>

#if XMACRO_USE_RPMALLOC

#include "3rd/rpmalloc/rpmalloc.h"

/* Kill any prior macro definition (defensive — e.g. CRT debug builds). */
#undef  malloc
#undef  calloc
#undef  realloc
#undef  free
#undef  strdup
#undef  _strdup

#define malloc(n)        rpmalloc(n)
#define calloc(n, s)     rpcalloc((n), (s))
#define realloc(p, n)    rprealloc((p), (n))
#define free(p)          rpfree(p)

/* strdup is not in C standard; libc-strdup'd pointer would crash rpfree. */
static inline char *xmacro_rpstrdup(const char *s) {
    if (!s) return NULL;
    size_t n = strlen(s) + 1;
    char *p = (char *)rpmalloc(n);
    if (p) memcpy(p, s, n);
    return p;
}
#define strdup(s)        xmacro_rpstrdup(s)
#define _strdup(s)       xmacro_rpstrdup(s)   /* MSVC name */

#else /* XMACRO_USE_RPMALLOC == 0 — pass through to libc */

/* Allocation macros: leave malloc/calloc/realloc/free/strdup untouched.
** They resolve to libc the normal way. No #define needed.
**
** Stub out the rpmalloc lifecycle API so call sites (xnet_main, xthread,
** xthread_test) don't have to #ifdef around every call. The cfg arg is
** evaluated for side effects then discarded. */
#define rpmalloc_initialize(cfg)        ((void)(cfg), 0)
#define rpmalloc_finalize()             ((void)0)
#define rpmalloc_thread_initialize()    ((void)0)
#define rpmalloc_thread_finalize()      ((void)0)

#endif /* XMACRO_USE_RPMALLOC */

#endif /* XMACRO_H */
