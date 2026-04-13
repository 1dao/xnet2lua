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
void xtimer_update();
int  xtimer_last();
void xtimer_show();

xtimerHandler xtimer_add(int interval_ms, const char* name, fnOnTime callback, void* ud, int repeat_num);
void          xtimer_del(xtimerHandler handler);

// utils
#ifdef _WIN32
#include <windows.h>
#include <time.h>
static inline long64 time_get_ms() {
    FILETIME ft;
    GetSystemTimeAsFileTime(&ft);

    ULARGE_INTEGER ull;
    ull.LowPart = ft.dwLowDateTime;
    ull.HighPart = ft.dwHighDateTime;
    return ull.QuadPart / 10000 - 11644473600000LL;
}

static long64 time_get_us() {
    FILETIME ft;
    GetSystemTimeAsFileTime(&ft);

    ULARGE_INTEGER uli;
    uli.LowPart = ft.dwLowDateTime;
    uli.HighPart = ft.dwHighDateTime;

    return (uli.QuadPart / 10);
}
#else
#include <sys/time.h>
#include <time.h>
#include <unistd.h>

static long64 time_get_ms() {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);

    return (long64)ts.tv_sec * 1000 + ts.tv_nsec / 1000000;
}

static long64 time_get_us() {
    struct timeval tv;
    gettimeofday(&tv, NULL);

    return (long64)tv.tv_sec * 1000000LL + tv.tv_usec;
}
#endif

static void time_get_dt(long64 millis, char out[24]) {
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
