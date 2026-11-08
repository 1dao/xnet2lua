#ifndef XUDP_H
#define XUDP_H

#ifndef XNET_WITH_UDP
#define XNET_WITH_UDP 0
#endif

#if XNET_WITH_UDP
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include "xsock.h"

#ifdef __cplusplus
extern "C" {
#endif

/* Optional, unconnected IPv4 datagrams. All operations, including destruction,
 * run on the thread owning xpoll. Close/destroy before tearing down that poll.
 * This layer provides neither framing, reliability, authentication nor crypto.
 */
#define XUDP_MAX_DATAGRAM 65507u
#define XUDP_DEFAULT_RECV_BUDGET 64u
#define XUDP_MAX_RECV_BUDGET 65536u

typedef struct xUdp xUdp;
typedef struct xUdpAddress {
    int family;                 /* AF_INET; reserved for future IPv6 support */
    char ip[64];                /* numeric address, never resolved during I/O */
    uint16_t port;              /* host byte order */
} xUdpAddress;

typedef struct xUdpStats {
    uint64_t datagrams_sent, bytes_sent;
    uint64_t datagrams_received, bytes_received;
    uint64_t dropped_oversize, receive_errors, send_errors, send_would_block;
    uint64_t receive_calls, budget_yields;
    int last_error;             /* native errno/WSA error; zero initially */
} xUdpStats;

typedef struct xUdpConfig {
    size_t max_datagram;        /* 0: XUDP_MAX_DATAGRAM; applies to send/receive */
    unsigned recv_budget;      /* 0: default; bounded receive attempts/event */
    /* data/address are borrowed until callback returns. A callback may close
     * or destroy its socket. Oversize/truncated datagrams never reach it. */
    void (*on_datagram)(xUdp*, const char*, size_t, const xUdpAddress*, void*);
    /* Destination errors do not close a shared socket. Fatal local errors
     * close the fd before this callback. No error callback for sync sendto. */
    void (*on_error)(xUdp*, int system_error, bool fatal, void*);
    void* userdata;
} xUdpConfig;

enum {
    XUDP_OK = 0,
    XUDP_WOULD_BLOCK = -1,
    XUDP_TOO_LARGE = -2,
    XUDP_INVALID_ADDRESS = -3,
    XUDP_CLOSED = -4,
    XUDP_SYSTEM_ERROR = -5
};

/* Numeric IPv4 only. Bind accepts NULL/empty for INADDR_ANY and port 0. */
int xudp_address(const char* ip, int port, xUdpAddress* out);
xUdp* xudp_bind(const char* host, int port, const xUdpConfig* config,
                char error[XSOCK_ERR_LEN]);
int xudp_sendto(xUdp*, const void* data, size_t len, const xUdpAddress*,
                int* system_error);
int xudp_sockname(const xUdp*, xUdpAddress* out);
SOCKET_T xudp_fd(const xUdp*);
void xudp_close(xUdp*);         /* idempotent; immediately unregisters/closes fd */
bool xudp_is_closed(const xUdp*);
void xudp_get_stats(const xUdp*, xUdpStats* out);
void xudp_destroy(xUdp*);       /* releases owner reference; call exactly once */
int xudp_live_count(void);      /* per-thread allocated objects */
int xudp_socket_count(void);    /* per-thread open sockets */
const char* xudp_result_name(int result);

#ifdef __cplusplus
}
#endif
#endif /* XNET_WITH_UDP */
#endif /* XUDP_H */
