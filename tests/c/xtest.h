#ifndef XTEST_H
#define XTEST_H

#include <stdio.h>
#include <string.h>

typedef struct xTestState {
    int total;
    int failed;
} xTestState;

#define XTEST_STATE_INIT { 0, 0 }

static inline void xtest_suite(const char* name) {
    printf("\n== %s ==\n", name);
}

static inline void xtest_check(xTestState* st, int ok,
                               const char* expr,
                               const char* file,
                               int line) {
    st->total++;
    if (ok) {
        printf("PASS %s\n", expr);
    } else {
        st->failed++;
        printf("FAIL %s (%s:%d)\n", expr, file, line);
    }
}

static inline int xtest_summary(const xTestState* st) {
    printf("\n========================================\n");
    printf("C unit tests: %d passed, %d failed\n",
           st->total - st->failed, st->failed);
    printf("========================================\n");
    return st->failed == 0 ? 0 : 1;
}

static inline int xtest_contains_text(const char* got, const char* needle) {
    return got && needle && strstr(got, needle) != NULL;
}

#define XTEST_TRUE(st, expr) \
    xtest_check((st), !!(expr), #expr, __FILE__, __LINE__)

#define XTEST_FALSE(st, expr) \
    xtest_check((st), !(expr), "!(" #expr ")", __FILE__, __LINE__)

#define XTEST_EQ_INT(st, got, want) \
    xtest_check((st), ((got) == (want)), #got " == " #want, __FILE__, __LINE__)

#define XTEST_EQ_PTR(st, got, want) \
    xtest_check((st), ((void*)(got) == (void*)(want)), #got " == " #want, __FILE__, __LINE__)

#define XTEST_EQ_STR(st, got, want) \
    xtest_check((st), ((got) && strcmp((got), (want)) == 0), #got " == \"" want "\"", __FILE__, __LINE__)

#define XTEST_CONTAINS(st, got, needle) \
    xtest_check((st), xtest_contains_text((got), (needle)), #got " contains \"" needle "\"", __FILE__, __LINE__)

#define XTEST_NULL(st, got) \
    xtest_check((st), ((got) == NULL), #got " == NULL", __FILE__, __LINE__)

#endif /* XTEST_H */
