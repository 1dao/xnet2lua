#ifndef XSOCK_H
#define XSOCK_H

#include "socket_util.h"

#ifdef __cplusplus
extern "C" {
#endif

#define XSOCK_OK 0
#define XSOCK_ERR -1
#define XSOCK_ERR_LEN 256

/* Connection flags */
#define XSOCK_CONNECT_NONE 0
#define XSOCK_CONNECT_NONBLOCK 1

/** ========== Client Connection ==========**\
 * Connect to a remote address.
 * If port is -1, 'addr' is treated as a Unix Domain Socket path.
 * Otherwise, 'addr' is treated as an IP or Hostname.
 */
SOCKET_T xsock_connect(char *err, const char *addr, int port, int flags);

/* Helper wrappers */
SOCKET_T xsock_tcp_connect(char *err, const char *addr, int port);
SOCKET_T xsock_tcp_aconnect(char *err, const char *addr, int port);

/* ========== Server Logic ========== **\
 * Create a listening socket.
 * If port is -1, 'bindaddr' is the path for Unix Domain Socket.
 * If port > 0, 'bindaddr' is the local IP to bind (NULL for any).
 */
SOCKET_T xsock_listen(char *err, const char *bindaddr, int port);

/**
 * Accept a new connection.
 * Supports both TCP and Unix Domain Sockets.
 */
SOCKET_T xsock_accept(char *err, SOCKET_T serversock, char *ip, int *port);

/* ========== I/O Operations ========== */
int xsock_read(SOCKET_T fd, char *buf, int count);
int xsock_read_with_timeout(SOCKET_T fd, char *buf, int count, long long timeout_ms);
int xsock_write(SOCKET_T fd, const char *buf, int count);

/* ========== Socket Configuration ========== */
int xsock_set_nonblock(char *err, SOCKET_T fd);
int xsock_set_tcp_nodelay(char *err, SOCKET_T fd);
int xsock_set_keepalive(char *err, SOCKET_T fd);
int xsock_set_send_buffer(char *err, SOCKET_T fd, int buffsize);

/* ========== Utilities ========== */
int xsock_resolve(char *err, const char *host, char *ipbuf);
int xsock_get_peer_info(SOCKET_T fd, char *ip, int *port);
void xsock_close(SOCKET_T fd);

#ifdef __cplusplus
}
#endif

#endif /* XSOCK_H */
