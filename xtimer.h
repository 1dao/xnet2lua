#ifndef _XTIMER_H_
#define _XTIMER_H_

#ifdef __cplusplus
extern "C" {
#endif

#include "xheapmin.h"

typedef void (*fnOnTime)(void*);
typedef void* xtimerHandler;

// api
void xtimer_init(int cap);
void xtimer_uninit();
int  xtimer_inited();   // 1 if this thread has an active timer pool, 0 otherwise
int  xtimer_update();   // drives expiries; returns ms until next expiry (0 if none / due)
int  xtimer_last();
void xtimer_show();

xtimerHandler xtimer_add(int interval_ms, const char* name, fnOnTime callback, void* ud, int repeat_num);
void          xtimer_del(xtimerHandler handler);

// utils
// time_day_*: wall clock time (calendar time, affected by system time changes)
// time_clock_*: monotonic clock time (since boot, not affected by system time changes)
#ifdef _WIN32
#include <windows.h>
#include <time.h>

static inline uint64_t time_clock_ms() {
    static LARGE_INTEGER freq = {{0,0}};
    if (freq.QuadPart == 0)
        QueryPerformanceFrequency(&freq);
    LARGE_INTEGER counter;
    QueryPerformanceCounter(&counter);
    return (uint64_t)((counter.QuadPart) * 1000 / freq.QuadPart);
}

static inline uint64_t time_clock_us() {
    static LARGE_INTEGER freq = {{0,0}};
    if (freq.QuadPart == 0)
        QueryPerformanceFrequency(&freq);
    LARGE_INTEGER counter;
    QueryPerformanceCounter(&counter);
    return (uint64_t)((double)counter.QuadPart * 1000000.0 / freq.QuadPart);
}

static inline uint64_t time_day_us() {
    FILETIME ft;
    GetSystemTimeAsFileTime(&ft);

    ULARGE_INTEGER uli;
    uli.LowPart = ft.dwLowDateTime;
    uli.HighPart = ft.dwHighDateTime;

    // FILETIME is 100ns ticks since 1601-01-01 UTC. Convert to microseconds
    // and shift the epoch to 1970-01-01 to match Unix time.
    return (uli.QuadPart / 10) - 11644473600000000ULL;
}

static inline uint64_t time_day_ms() {
    return time_day_us() / 1000;
}
#else
#include <sys/time.h>
#include <time.h>
#include <unistd.h>

static inline uint64_t time_clock_ms() {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);

    return (uint64_t)ts.tv_sec * 1000 + ts.tv_nsec / 1000000;
}

static inline uint64_t time_clock_us() {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);

    return (uint64_t)ts.tv_sec * 1000000 + ts.tv_nsec / 1000;
}

static inline uint64_t time_day_us() {
    struct timeval tv;
    gettimeofday(&tv, NULL);

    return (uint64_t)tv.tv_sec * 1000000LL + tv.tv_usec;
}

static inline uint64_t time_day_ms() {
    return time_day_us() / 1000;
}
#endif

static inline void time_get_dt(uint64_t millis, char out[24]) {
    // 转换为秒和毫秒
    time_t seconds = (time_t)(millis / 1000);
    int ms = (int)(millis % 1000);

    struct tm timeinfo;

#ifdef _WIN32
    localtime_s(&timeinfo, &seconds);
#else
    localtime_r(&seconds, &timeinfo);
#endif

    // 直接格式化到输出缓冲区
#ifdef _WIN32
    _snprintf_s(out, 24, _TRUNCATE,
        "%04d-%02d-%02d %02d:%02d:%02d.%03d",
        timeinfo.tm_year + 1900,
        timeinfo.tm_mon + 1,
        timeinfo.tm_mday,
        timeinfo.tm_hour,
        timeinfo.tm_min,
        timeinfo.tm_sec,
        ms);
#else
    snprintf(out, 24,
        "%04d-%02d-%02d %02d:%02d:%02d.%03d",
        timeinfo.tm_year + 1900,
        timeinfo.tm_mon + 1,
        timeinfo.tm_mday,
        timeinfo.tm_hour,
        timeinfo.tm_min,
        timeinfo.tm_sec,
        ms);
#endif
}

#ifdef __cplusplus
}
#endif
#endif // _XTIMER_H_
