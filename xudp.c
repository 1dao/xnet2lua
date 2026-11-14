#include "xudp.h"

#if XNET_WITH_UDP
#include "xpoll.h"
#include <limits.h>
#ifndef _WIN32
#include <time.h>
#endif
#ifdef _WIN32
#include <mswsock.h>
#ifndef SIO_UDP_CONNRESET
#define SIO_UDP_CONNRESET _WSAIOW(IOC_VENDOR, 12)
#endif
#endif
#include "xmacro.h"

#ifdef _MSC_VER
#define XUDP_TLS __declspec(thread)
#else
#define XUDP_TLS __thread
#endif

struct xUdp {
    SOCKET_T fd;
    unsigned refs;
    bool receiving;
    bool read_paused;
    bool write_waiting;
    xUdpConfig config;
    xUdpStats stats;
    uint64_t last_read_event_ms, last_write_event_ms;
    char* buffer;
};

static XUDP_TLS int g_udp_live;
static XUDP_TLS int g_udp_sockets;
static uint64_t udp_now_ms(void) {
#ifdef _WIN32
    return GetTickCount64();
#else
    struct timespec ts; clock_gettime(CLOCK_MONOTONIC, &ts);
    return (uint64_t)ts.tv_sec*1000 + ts.tv_nsec/1000000;
#endif
}

static void udp_release(xUdp* udp) {
    if (--udp->refs) return;
    free(udp->buffer);
    free(udp);
    --g_udp_live;
}

int xudp_address(const char* ip, int port, xUdpAddress* out) {
    struct in_addr addr;
    if (!out || !ip || port < 0 || port > 65535 ||
        inet_pton(AF_INET, ip, &addr) != 1) return XUDP_INVALID_ADDRESS;
    memset(out, 0, sizeof(*out));
    out->family = AF_INET;
    out->port = (uint16_t)port;
    inet_ntop(AF_INET, &addr, out->ip, sizeof(out->ip));
    return XUDP_OK;
}

static void udp_native_address(const xUdpAddress* addr, struct sockaddr_in* out) {
    memset(out, 0, sizeof(*out));
    out->sin_family = AF_INET;
    out->sin_port = htons(addr->port);
    inet_pton(AF_INET, addr->ip, &out->sin_addr);
}

static bool udp_would_block(int error) {
#ifdef _WIN32
    return error == WSAEWOULDBLOCK;
#else
    return error == EAGAIN || error == EWOULDBLOCK;
#endif
}

static bool udp_interrupted(int error) {
#ifdef _WIN32
    return error == WSAEINTR;
#else
    return error == EINTR;
#endif
}

static bool udp_message_size(int error) {
#ifdef _WIN32
    return error == WSAEMSGSIZE;
#else
    return error == EMSGSIZE;
#endif
}

static bool udp_fatal(int error) {
#ifdef _WIN32
    return error == WSAENOTSOCK || error == WSAENETDOWN ||
           error == WSAESHUTDOWN || error == WSANOTINITIALISED;
#else
    return error == EBADF || error == ENOTSOCK || error == ENETDOWN;
#endif
}

void xudp_close(xUdp* udp) {
    if (!udp || udp->fd == INVALID_SOCKET_VAL) return;
    xpoll_del_event(udp->fd, XPOLL_ALL);
    CLOSE_SOCKET(udp->fd);
    udp->fd = INVALID_SOCKET_VAL;
    --g_udp_sockets;
}

static void udp_report_error(xUdp* udp, int error) {
    bool fatal = udp_fatal(error);
    ++udp->stats.receive_errors;
    udp->stats.last_error = error;
    if (fatal) xudp_close(udp);
    if (udp->config.on_error)
        udp->config.on_error(udp, error, fatal, udp->config.userdata);
}

static void udp_read_event(SOCKET_T fd, int mask, void* data, xPollRequest* req) {
    xUdp* udp = (xUdp*)data;
    unsigned attempts;
    (void)mask;
    (void)req;
    if (udp->receiving || udp->read_paused || udp->fd != fd) return;
    ++udp->stats.read_events; udp->last_read_event_ms=udp_now_ms();
    ++udp->refs; /* callbacks may release the owner reference */
    udp->receiving = true;
    for (attempts = 0; attempts < udp->config.recv_budget; ++attempts) {
        struct sockaddr_in from;
#ifdef _WIN32
        int from_len = sizeof(from);
#else
        socklen_t from_len = sizeof(from);
#endif
        int n, error;
        if (udp->fd == INVALID_SOCKET_VAL || udp->read_paused) break;
        ++udp->stats.receive_calls;
        /* One extra byte detects truncation on POSIX recvfrom without relying
         * on Linux-specific MSG_TRUNC behavior. Winsock returns WSAEMSGSIZE. */
        n = (int)recvfrom(udp->fd, udp->buffer,
                         (int)udp->config.max_datagram + 1, 0,
                         (struct sockaddr*)&from, &from_len);
        if (n < 0) {
            error = GET_ERRNO();
            if (udp_would_block(error)) break;
            if (udp_interrupted(error)) continue;
            if (udp_message_size(error)) {
                ++udp->stats.dropped_oversize;
                continue;
            }
            udp_report_error(udp, error);
            /* Consume destination ICMP errors and give queued datagrams a
             * chance. Every syscall/error consumes budget, including EINTR. */
            continue;
        }
        if ((size_t)n > udp->config.max_datagram) {
            ++udp->stats.dropped_oversize;
            continue;
        }
        if ((size_t)from_len < sizeof(from) || from.sin_family != AF_INET) continue;
        ++udp->stats.datagrams_received;
        udp->stats.bytes_received += (size_t)n;
        if (udp->config.on_datagram) {
            xUdpAddress addr;
            memset(&addr, 0, sizeof(addr));
            addr.family = AF_INET;
            addr.port = ntohs(from.sin_port);
            inet_ntop(AF_INET, &from.sin_addr, addr.ip, sizeof(addr.ip));
            udp->config.on_datagram(udp, udp->buffer, (size_t)n, &addr,
                                    udp->config.userdata);
        }
    }
    if (attempts == udp->config.recv_budget && !xudp_is_closed(udp))
        ++udp->stats.budget_yields;
    udp->receiving = false;
    udp_release(udp);
}

static void udp_error_event(SOCKET_T fd, int mask, void* data, xPollRequest* req) {
    xUdp* udp = (xUdp*)data;
    int error = 0;
#ifdef _WIN32
    int len = sizeof(error);
#else
    socklen_t len = sizeof(error);
#endif
    (void)mask;
    (void)req;
    if (udp->fd != fd) return;
    ++udp->refs;
    /* xpoll maps EPOLLERR to ERROR|CLOSE for stream users. UDP must consume
     * SO_ERROR and classify it, never treat a peer's failure as stream EOF. */
    if (getsockopt(fd, SOL_SOCKET, SO_ERROR, (char*)&error, &len) != 0)
        error = GET_ERRNO();
    if (error && !udp_would_block(error) && !udp_interrupted(error))
        udp_report_error(udp, error);
    udp_release(udp);
}

void xudp_pause_read(xUdp* udp) {
    if (xudp_is_closed(udp) || udp->read_paused) return;
    udp->read_paused = true;
    ++udp->stats.read_pauses;
    xpoll_del_event(udp->fd, XPOLL_READABLE);
}

static void udp_write_event(SOCKET_T fd, int mask, void* data, xPollRequest* req) {
    xUdp* udp = data;
    (void)mask;
    (void)req;
    if (udp->fd != fd) return;
    /* The owner retries after poll returns, never inside the DTLS callback. */
    ++udp->stats.write_events; udp->last_write_event_ms=udp_now_ms();
    xudp_wait_writable(udp, false);
}

int xudp_wait_writable(xUdp* udp, bool enabled) {
    if (xudp_is_closed(udp)) return XUDP_CLOSED;
    if (enabled == udp->write_waiting) return XUDP_OK;
    if (enabled) {
        if (xpoll_add_event(udp->fd, XPOLL_WRITABLE, NULL, udp_write_event,
                           NULL, udp) != 0) return XUDP_SYSTEM_ERROR;
    } else xpoll_del_event(udp->fd, XPOLL_WRITABLE);
    udp->write_waiting = enabled;
    return XUDP_OK;
}

int xudp_resume_read(xUdp* udp) {
    if (xudp_is_closed(udp)) return XUDP_CLOSED;
    if (!udp->read_paused) return XUDP_OK;
    if (xpoll_add_event(udp->fd, XPOLL_READABLE | XPOLL_ERROR, udp_read_event, NULL,
                       udp_error_event, udp) != 0) return XUDP_SYSTEM_ERROR;
    udp->read_paused = false;
    ++udp->stats.read_resumes;
    return XUDP_OK;
}

xUdp* xudp_bind(const char* host, int port, const xUdpConfig* config,
                char error[XSOCK_ERR_LEN]) {
    xUdpConfig cfg = {0};
    xUdpAddress addr;
    struct sockaddr_in native_addr;
    xUdp* udp;
    SOCKET_T fd;
    int system_error;
    const char* operation = "socket";
    if (error) error[0] = '\0';
    if (config) cfg = *config;
    if (!cfg.max_datagram) cfg.max_datagram = XUDP_MAX_DATAGRAM;
    if (!cfg.recv_budget) cfg.recv_budget = XUDP_DEFAULT_RECV_BUDGET;
    if (cfg.max_datagram > XUDP_MAX_DATAGRAM ||
        cfg.recv_budget > XUDP_MAX_RECV_BUDGET || !xpoll_inited() ||
        xudp_address(host && host[0] ? host : "0.0.0.0", port, &addr)) {
        if (error) snprintf(error, XSOCK_ERR_LEN, "invalid UDP address/options or xpoll not initialized");
        return NULL;
    }
    fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP);
    if (fd == INVALID_SOCKET_VAL) goto system_failed;
    socket_set_cloexec(fd);
    operation = "nonblocking";
    if (socket_set_nonblocking(fd) != 0) goto system_failed;
#ifdef _WIN32
    {
        BOOL report_resets = FALSE;
        DWORD returned;
        /* A shared unconnected socket serves many clients. Suppress Windows
         * ICMP PORT_UNREACHABLE -> WSAECONNRESET; still classify any reported
         * reset as a nonfatal destination error in the receive path. */
        operation = "SIO_UDP_CONNRESET";
        if (WSAIoctl(fd, SIO_UDP_CONNRESET, &report_resets, sizeof(report_resets),
                     NULL, 0, &returned, NULL, NULL) != 0) goto system_failed;
    }
#endif
    udp_native_address(&addr, &native_addr);
    operation = "bind";
    if (bind(fd, (struct sockaddr*)&native_addr, sizeof(native_addr)) != 0)
        goto system_failed;
    udp = (xUdp*)calloc(1, sizeof(*udp));
    if (!udp) goto allocation_failed;
    udp->buffer = (char*)malloc(cfg.max_datagram + 1);
    if (!udp->buffer) { free(udp); goto allocation_failed; }
    udp->fd = fd;
    udp->refs = 1;
    udp->config = cfg;
    /* Keep error monitoring while reads are paused, including when this is
     * the only fd (WSAPoll rejects an empty descriptor set). */
    if (xpoll_add_event(fd, XPOLL_READABLE | XPOLL_ERROR, udp_read_event, NULL,
                        udp_error_event, udp) != 0) {
        free(udp->buffer);
        free(udp);
        CLOSE_SOCKET(fd);
        if (error) snprintf(error, XSOCK_ERR_LEN, "UDP xpoll_add_event failed");
        return NULL;
    }
    ++g_udp_live;
    ++g_udp_sockets;
    return udp;

allocation_failed:
    CLOSE_SOCKET(fd);
    if (error) snprintf(error, XSOCK_ERR_LEN, "UDP allocation failed");
    return NULL;
system_failed:
    system_error = GET_ERRNO();
    if (fd != INVALID_SOCKET_VAL) CLOSE_SOCKET(fd);
    if (error) snprintf(error, XSOCK_ERR_LEN, "UDP %s failed: %d", operation, system_error);
    return NULL;
}

int xudp_sendto(xUdp* udp, const void* data, size_t len, const xUdpAddress* to,
                int* system_error) {
    struct sockaddr_in addr;
    struct in_addr checked;
    int n, error;
    if (system_error) *system_error = 0;
    if (xudp_is_closed(udp)) return XUDP_CLOSED;
    if (len > udp->config.max_datagram) {
        ++udp->stats.send_errors;
        return XUDP_TOO_LARGE;
    }
    if ((!data && len) || !to || to->family != AF_INET || !to->port ||
        !memchr(to->ip, '\0', sizeof(to->ip)) ||
        inet_pton(AF_INET, to->ip, &checked) != 1) return XUDP_INVALID_ADDRESS;
    udp_native_address(to, &addr);
    n = (int)sendto(udp->fd, data ? (const char*)data : "", (int)len, 0,
                    (struct sockaddr*)&addr, sizeof(addr));
    if (n >= 0 && (size_t)n == len) {
        ++udp->stats.datagrams_sent;
        udp->stats.bytes_sent += len;
        return XUDP_OK;
    }
    error = n < 0 ? GET_ERRNO() : 0;
    udp->stats.last_error = error;
    if (system_error) *system_error = error;
    if (udp_would_block(error) || udp_interrupted(error)) {
        ++udp->stats.send_would_block;
        return XUDP_WOULD_BLOCK;
    }
    ++udp->stats.send_errors;
    return udp_message_size(error) ? XUDP_TOO_LARGE : XUDP_SYSTEM_ERROR;
}

int xudp_sockname(const xUdp* udp, xUdpAddress* out) {
    struct sockaddr_in addr;
#ifdef _WIN32
    int len = sizeof(addr);
#else
    socklen_t len = sizeof(addr);
#endif
    if (xudp_is_closed(udp)) return XUDP_CLOSED;
    if (!out) return XUDP_INVALID_ADDRESS;
    if (getsockname(udp->fd, (struct sockaddr*)&addr, &len) != 0)
        return XUDP_SYSTEM_ERROR;
    memset(out, 0, sizeof(*out));
    out->family = AF_INET;
    out->port = ntohs(addr.sin_port);
    inet_ntop(AF_INET, &addr.sin_addr, out->ip, sizeof(out->ip));
    return XUDP_OK;
}

SOCKET_T xudp_fd(const xUdp* udp) { return udp ? udp->fd : INVALID_SOCKET_VAL; }
bool xudp_is_closed(const xUdp* udp) { return !udp || udp->fd == INVALID_SOCKET_VAL; }
void xudp_get_stats(const xUdp* udp, xUdpStats* out) {
    if (!out) return;
    memset(out,0,sizeof(*out));
    out->read_event_age_ms=out->write_event_age_ms=-1;
    if (!udp) return;
    *out=udp->stats;
    out->read_paused=udp->read_paused; out->write_waiting=udp->write_waiting;
    uint64_t now=udp_now_ms();
    out->read_event_age_ms=udp->stats.read_events ? (int64_t)(now-udp->last_read_event_ms) : -1;
    out->write_event_age_ms=udp->stats.write_events ? (int64_t)(now-udp->last_write_event_ms) : -1;
}
void xudp_destroy(xUdp* udp) {
    if (!udp) return;
    xudp_close(udp);
    udp_release(udp);
}
int xudp_live_count(void) { return g_udp_live; }
int xudp_socket_count(void) { return g_udp_sockets; }
const char* xudp_result_name(int result) {
    switch (result) {
    case XUDP_OK: return "ok";
    case XUDP_WOULD_BLOCK: return "would_block";
    case XUDP_TOO_LARGE: return "too_large";
    case XUDP_INVALID_ADDRESS: return "invalid_address";
    case XUDP_CLOSED: return "closed";
    default: return "system_error";
    }
}
#endif /* XNET_WITH_UDP */
