#include "xchannel.h"

#include "xpoll.h"

#include <stdint.h>
#include <limits.h>
#include <stdlib.h>
#include <string.h>
#include <stdio.h>

#ifdef __linux__
#include <sys/sendfile.h>
#include <sys/stat.h>
#include <fcntl.h>
#include <unistd.h>
#elif !defined(_WIN32)
#include <sys/types.h>
#endif

#ifndef XCHANNEL_READ_CHUNK
#define XCHANNEL_READ_CHUNK 8192
#endif

#ifndef XCHANNEL_DEFAULT_MAX_PACKET
#define XCHANNEL_DEFAULT_MAX_PACKET (16u * 1024u * 1024u)
#endif

struct xChannel {
    SOCKET_T fd;
    int refcount;
    bool closed;
    bool attached;
    bool connected;
    bool connect_pending;

    xChannelFrame frame;
    size_t max_packet;

    char* inbuf;
    size_t inlen;
    size_t incap;

    char* outbuf;
    size_t outlen;
    size_t outcap;

#ifdef __linux__
    int file_fd;
    long long file_offset;
#else
    FILE* file_fp;
#endif
    bool file_pending;
    long long file_remaining;

    xChannelConnectProc connect_cb;
    xChannelPacketProc packet_cb;
    xChannelCloseProc close_cb;
    void* userdata;
};

static void xchannel_read_event(SOCKET_T fd, int mask, void* clientData);
static void xchannel_write_event(SOCKET_T fd, int mask, void* clientData);
static void xchannel_connect_event(SOCKET_T fd, int mask, void* clientData);
static void xchannel_error_event(SOCKET_T fd, int mask, void* clientData);

static bool has_pending_file(xChannel* ch) {
    return ch && ch->file_pending && ch->file_remaining > 0;
}

static void close_pending_file(xChannel* ch) {
    if (!ch) return;
#ifdef __linux__
    if (ch->file_fd >= 0) {
        close(ch->file_fd);
        ch->file_fd = -1;
    }
#else
    if (ch->file_fp) {
        fclose(ch->file_fp);
        ch->file_fp = NULL;
    }
#endif
    ch->file_pending = false;
    ch->file_remaining = 0;
}

static bool valid_frame(xChannelFrame frame) {
    return frame == XCHANNEL_FRAME_RAW ||
           frame == XCHANNEL_FRAME_LEN32 ||
           frame == XCHANNEL_FRAME_CRLF;
}

static void write_u32be(char* p, uint32_t v) {
    p[0] = (char)((v >> 24) & 0xff);
    p[1] = (char)((v >> 16) & 0xff);
    p[2] = (char)((v >> 8) & 0xff);
    p[3] = (char)(v & 0xff);
}

static uint32_t read_u32be(const char* p) {
    const unsigned char* b = (const unsigned char*)p;
    return ((uint32_t)b[0] << 24) |
           ((uint32_t)b[1] << 16) |
           ((uint32_t)b[2] << 8) |
           (uint32_t)b[3];
}

static void xchannel_retain(xChannel* ch) {
    if (ch) ch->refcount++;
}

static void xchannel_free_storage(xChannel* ch) {
    if (!ch) return;
    close_pending_file(ch);
    free(ch->inbuf);
    free(ch->outbuf);
    free(ch);
}

static void xchannel_release(xChannel* ch) {
    if (!ch) return;
    ch->refcount--;
    if (ch->refcount <= 0) {
        xchannel_free_storage(ch);
    }
}

static bool buffer_reserve(char** buf, size_t* cap, size_t need) {
    if (need <= *cap) return true;
    size_t ncap = (*cap > 0) ? *cap : 4096;
    while (ncap < need) {
        if (ncap > (SIZE_MAX / 2)) return false;
        ncap *= 2;
    }
    char* nbuf = (char*)realloc(*buf, ncap);
    if (!nbuf) return false;
    *buf = nbuf;
    *cap = ncap;
    return true;
}

static bool buffer_append(char** buf, size_t* len, size_t* cap,
                          const char* data, size_t data_len) {
    if (data_len == 0) return true;
    if (*len > SIZE_MAX - data_len) return false;
    if (!buffer_reserve(buf, cap, *len + data_len)) return false;
    memcpy(*buf + *len, data, data_len);
    *len += data_len;
    return true;
}

static void buffer_consume(char* buf, size_t* len, size_t n) {
    if (n >= *len) {
        *len = 0;
        return;
    }
    memmove(buf, buf + n, *len - n);
    *len -= n;
}

static size_t find_crlf(const char* buf, size_t len) {
    if (len < 2) return SIZE_MAX;
    for (size_t i = 0; i <= len - 2; i++) {
        if (buf[i] == '\r' && buf[i + 1] == '\n') return i;
    }
    return SIZE_MAX;
}

static size_t emit_packet(xChannel* ch, const char* data, size_t len) {
    if (!ch || ch->closed || !ch->packet_cb) return 0;
    xchannel_retain(ch);
    size_t consumed = ch->packet_cb(ch, data, len, ch->userdata);
    xchannel_release(ch);
    return consumed;
}

static void close_internal(xChannel* ch, const char* reason, bool notify) {
    if (!ch || ch->closed) return;

    ch->closed = true;
    ch->attached = false;
    ch->connected = false;
    ch->connect_pending = false;

    if (ch->fd != INVALID_SOCKET_VAL) {
        xpoll_del_event(ch->fd, XPOLL_ALL);
        xsock_close(ch->fd);
        ch->fd = INVALID_SOCKET_VAL;
    }
    close_pending_file(ch);

    if (notify && ch->close_cb) {
        ch->close_cb(ch, reason ? reason : "closed", ch->userdata);
    }
}

static void process_input(xChannel* ch) {
    while (ch && !ch->closed && ch->inlen > 0) {
        if (ch->frame == XCHANNEL_FRAME_RAW) {
            if (ch->inlen > ch->max_packet) {
                xchannel_close(ch, "packet_too_large");
                return;
            }

            size_t consumed = emit_packet(ch, ch->inbuf, ch->inlen);
            if (ch->closed) return;
            if (consumed == 0) return;
            if (consumed > ch->inlen) {
                xchannel_close(ch, "consume_error");
                return;
            }

            buffer_consume(ch->inbuf, &ch->inlen, consumed);
            continue;
        }

        if (ch->frame == XCHANNEL_FRAME_LEN32) {
            if (ch->inlen < 4) return;

            uint32_t body_len = read_u32be(ch->inbuf);
            if ((size_t)body_len > ch->max_packet) {
                xchannel_close(ch, "packet_too_large");
                return;
            }
            if (ch->inlen < (size_t)body_len + 4) return;

            char* pkt = NULL;
            if (body_len > 0) {
                pkt = (char*)malloc(body_len);
                if (!pkt) {
                    xchannel_close(ch, "out_of_memory");
                    return;
                }
                memcpy(pkt, ch->inbuf + 4, body_len);
            }
            buffer_consume(ch->inbuf, &ch->inlen, (size_t)body_len + 4);
            emit_packet(ch, pkt ? pkt : "", body_len);
            free(pkt);
            continue;
        }

        if (ch->frame == XCHANNEL_FRAME_CRLF) {
            size_t pos = find_crlf(ch->inbuf, ch->inlen);
            if (pos == SIZE_MAX) {
                if (ch->inlen > ch->max_packet) {
                    xchannel_close(ch, "packet_too_large");
                }
                return;
            }
            if (pos > ch->max_packet) {
                xchannel_close(ch, "packet_too_large");
                return;
            }

            char* pkt = NULL;
            if (pos > 0) {
                pkt = (char*)malloc(pos);
                if (!pkt) {
                    xchannel_close(ch, "out_of_memory");
                    return;
                }
                memcpy(pkt, ch->inbuf, pos);
            }
            buffer_consume(ch->inbuf, &ch->inlen, pos + 2);
            emit_packet(ch, pkt ? pkt : "", pos);
            free(pkt);
            continue;
        }

        xchannel_close(ch, "bad_frame");
        return;
    }
}

static void flush_output(xChannel* ch) {
    if (!ch || ch->closed || ch->connect_pending) return;

    while (ch->outlen > 0) {
        size_t remaining = ch->outlen;
        int chunk = (remaining > INT_MAX) ? INT_MAX : (int)remaining;
        int n = send(ch->fd, ch->outbuf, chunk, 0);
        if (n > 0) {
            buffer_consume(ch->outbuf, &ch->outlen, (size_t)n);
            continue;
        }
        if (n < 0 && socket_check_eagain()) return;
        xchannel_close(ch, "write_error");
        return;
    }

    while (!ch->closed && has_pending_file(ch)) {
#ifdef __linux__
        off_t off = (off_t)ch->file_offset;
        size_t chunk = ch->file_remaining > 1024 * 1024
            ? 1024 * 1024
            : (size_t)ch->file_remaining;
        ssize_t n = sendfile((int)ch->fd, ch->file_fd, &off, chunk);
        if (n > 0) {
            ch->file_offset = (long long)off;
            ch->file_remaining -= (long long)n;
            continue;
        }
        if (n == 0) {
            close_pending_file(ch);
            break;
        }
        if (socket_check_eagain()) return;
        xchannel_close(ch, "sendfile_error");
        return;
#else
        char buf[64 * 1024];
        size_t want = ch->file_remaining > (long long)sizeof(buf)
            ? sizeof(buf)
            : (size_t)ch->file_remaining;
        size_t got = fread(buf, 1, want, ch->file_fp);
        if (got == 0) {
            if (ferror(ch->file_fp)) {
                xchannel_close(ch, "sendfile_read_error");
                return;
            }
            close_pending_file(ch);
            break;
        }

        size_t off = 0;
        while (off < got) {
            size_t remaining = got - off;
            int chunk = (remaining > INT_MAX) ? INT_MAX : (int)remaining;
            int n = send(ch->fd, buf + off, chunk, 0);
            if (n > 0) {
                off += (size_t)n;
                ch->file_remaining -= (long long)n;
                continue;
            }
            if (n == 0 || socket_check_eagain()) {
                long long rewind_bytes = (long long)(got - off);
                if (rewind_bytes > 0) {
#ifdef _WIN32
                    _fseeki64(ch->file_fp, -rewind_bytes, SEEK_CUR);
#else
                    fseeko(ch->file_fp, (off_t)-rewind_bytes, SEEK_CUR);
#endif
                }
                return;
            }
            xchannel_close(ch, "sendfile_write_error");
            return;
        }
#endif
    }

    if (!ch->closed && !has_pending_file(ch)) {
        close_pending_file(ch);
        xpoll_del_event(ch->fd, XPOLL_WRITABLE);
    }
}

static int queue_or_send_raw(xChannel* ch, const char* data, size_t len) {
    if (!ch || ch->closed || ch->fd == INVALID_SOCKET_VAL) return -1;
    if (!data && len > 0) return -1;
    if (len == 0) return 0;
    if (has_pending_file(ch)) return -1;

    if (ch->connect_pending || ch->outlen > 0 || !ch->connected) {
        if (!buffer_append(&ch->outbuf, &ch->outlen, &ch->outcap, data, len)) {
            xchannel_close(ch, "out_of_memory");
            return -1;
        }
        if (ch->connect_pending) {
            if (xpoll_add_event(ch->fd, XPOLL_WRITABLE, NULL,
                                xchannel_connect_event, xchannel_error_event, ch) != 0) {
                xchannel_close(ch, "poll_error");
                return -1;
            }
        } else {
            if (xpoll_add_event(ch->fd, XPOLL_WRITABLE, NULL,
                                xchannel_write_event, xchannel_error_event, ch) != 0) {
                xchannel_close(ch, "poll_error");
                return -1;
            }
        }
        xpoll_set_client_data(ch->fd, ch);
        return 0;
    }

    size_t off = 0;
    while (off < len) {
        size_t remaining = len - off;
        int chunk = (remaining > INT_MAX) ? INT_MAX : (int)remaining;
        int n = send(ch->fd, data + off, chunk, 0);
        if (n > 0) {
            off += (size_t)n;
            continue;
        }
        if (n < 0 && socket_check_eagain()) break;
        xchannel_close(ch, "write_error");
        return -1;
    }

    if (off < len) {
        if (!buffer_append(&ch->outbuf, &ch->outlen, &ch->outcap,
                           data + off, len - off)) {
            xchannel_close(ch, "out_of_memory");
            return -1;
        }
        if (xpoll_add_event(ch->fd, XPOLL_WRITABLE, NULL,
                            xchannel_write_event, xchannel_error_event, ch) != 0) {
            xchannel_close(ch, "poll_error");
            return -1;
        }
        xpoll_set_client_data(ch->fd, ch);
    }

    return 0;
}

static bool finish_connect(xChannel* ch) {
    int err = 0;
#ifdef _WIN32
    int err_len = sizeof(err);
    int rc = getsockopt(ch->fd, SOL_SOCKET, SO_ERROR, (char*)&err, &err_len);
#else
    socklen_t err_len = sizeof(err);
    int rc = getsockopt(ch->fd, SOL_SOCKET, SO_ERROR, &err, &err_len);
#endif
    if (rc != 0 || err != 0) {
        xchannel_close(ch, "connect_error");
        return false;
    }

    ch->connect_pending = false;
    ch->connected = true;
    xpoll_del_event(ch->fd, XPOLL_WRITABLE);

    if (xchannel_attach(ch) != 0) {
        xchannel_close(ch, "poll_error");
        return false;
    }

    if (ch->connect_cb && !ch->closed) {
        ch->connect_cb(ch, ch->userdata);
    }
    if (!ch->closed) {
        flush_output(ch);
    }
    return !ch->closed;
}

static void xchannel_read_event(SOCKET_T fd, int mask, void* clientData) {
    (void)fd;
    (void)mask;
    xChannel* ch = (xChannel*)clientData;
    if (!ch || ch->closed) return;

    xchannel_retain(ch);

    char buf[XCHANNEL_READ_CHUNK];
    bool close_after = false;
    const char* close_reason = NULL;

    while (!ch->closed) {
        int n = recv(ch->fd, buf, (int)sizeof(buf), 0);
        if (n > 0) {
            if (!buffer_append(&ch->inbuf, &ch->inlen, &ch->incap, buf, (size_t)n)) {
                xchannel_close(ch, "out_of_memory");
                break;
            }
            continue;
        }
        if (n == 0) {
            close_after = true;
            close_reason = "eof";
            break;
        }
        if (socket_check_eagain()) break;
        close_after = true;
        close_reason = "read_error";
        break;
    }

    if (!ch->closed) process_input(ch);
    if (close_after && !ch->closed) xchannel_close(ch, close_reason);

    xchannel_release(ch);
}

static void xchannel_write_event(SOCKET_T fd, int mask, void* clientData) {
    (void)fd;
    (void)mask;
    xChannel* ch = (xChannel*)clientData;
    if (!ch || ch->closed) return;
    xchannel_retain(ch);
    flush_output(ch);
    xchannel_release(ch);
}

static void xchannel_connect_event(SOCKET_T fd, int mask, void* clientData) {
    (void)fd;
    (void)mask;
    xChannel* ch = (xChannel*)clientData;
    if (!ch || ch->closed) return;
    xchannel_retain(ch);
    finish_connect(ch);
    xchannel_release(ch);
}

static void xchannel_error_event(SOCKET_T fd, int mask, void* clientData) {
    (void)fd;
    (void)mask;
    xChannel* ch = (xChannel*)clientData;
    if (!ch || ch->closed) return;
    xchannel_retain(ch);
    xchannel_close(ch, "socket_error");
    xchannel_release(ch);
}

xChannel* xchannel_create(SOCKET_T fd, const xChannelConfig* cfg) {
    xChannel* ch = (xChannel*)calloc(1, sizeof(*ch));
    if (!ch) return NULL;
    ch->fd = fd;
    ch->refcount = 1;
    ch->closed = false;
    ch->attached = false;
    ch->connected = true;
    ch->connect_pending = false;
    ch->frame = XCHANNEL_FRAME_RAW;
    ch->max_packet = XCHANNEL_DEFAULT_MAX_PACKET;
#ifdef __linux__
    ch->file_fd = -1;
#endif

    if (cfg) {
        if (!valid_frame(cfg->frame)) {
            free(ch);
            return NULL;
        }
        ch->frame = cfg->frame;
        if (cfg->max_packet > 0) ch->max_packet = cfg->max_packet;
        if (cfg->connect_cb) ch->connect_cb = cfg->connect_cb;
        if (cfg->packet_cb) ch->packet_cb = cfg->packet_cb;
        if (cfg->close_cb) ch->close_cb = cfg->close_cb;
        if (cfg->userdata) ch->userdata = cfg->userdata;
    }

    return ch;
}

void xchannel_destroy(xChannel* ch) {
    if (!ch) return;
    if (!ch->closed) {
        ch->closed = true;
        ch->attached = false;
        ch->connected = false;
        ch->connect_pending = false;
        if (ch->fd != INVALID_SOCKET_VAL) {
            xpoll_del_event(ch->fd, XPOLL_ALL);
            xsock_close(ch->fd);
            ch->fd = INVALID_SOCKET_VAL;
        }
        close_pending_file(ch);
    }
    xchannel_release(ch);
}

int xchannel_set_framing(xChannel* ch, const xChannelConfig* cfg) {
    if (!ch || ch->closed || !cfg || !valid_frame(cfg->frame)) return -1;
    if (cfg->max_packet > 0) ch->max_packet = cfg->max_packet;
    ch->frame = cfg->frame;
    return 0;
}

SOCKET_T xchannel_fd(xChannel* ch) {
    return ch ? ch->fd : INVALID_SOCKET_VAL;
}

bool xchannel_is_closed(xChannel* ch) {
    return !ch || ch->closed;
}

bool xchannel_is_connected(xChannel* ch) {
    return ch && ch->connected && !ch->closed;
}

void xchannel_set_userdata(xChannel* ch, void* ud) {
    if (ch) ch->userdata = ud;
}

void* xchannel_get_userdata(xChannel* ch) {
    return ch ? ch->userdata : NULL;
}

void xchannel_set_max_packet(xChannel* ch, size_t max_packet) {
    if (ch && max_packet > 0) ch->max_packet = max_packet;
}

int xchannel_attach(xChannel* ch) {
    if (!ch || ch->closed || ch->fd == INVALID_SOCKET_VAL) return -1;
    if (xpoll_add_event(ch->fd, XPOLL_READABLE,
                        xchannel_read_event, NULL, xchannel_error_event, ch) != 0) {
        return -1;
    }
    xpoll_set_client_data(ch->fd, ch);
    ch->attached = true;
    ch->connected = true;
    return 0;
}

int xchannel_attach_connect(xChannel* ch) {
    if (!ch || ch->closed || ch->fd == INVALID_SOCKET_VAL) return -1;
    ch->connect_pending = true;
    ch->connected = false;
    if (xpoll_add_event(ch->fd, XPOLL_WRITABLE,
                        NULL, xchannel_connect_event, xchannel_error_event, ch) != 0) {
        return -1;
    }
    xpoll_set_client_data(ch->fd, ch);
    ch->attached = true;
    return 0;
}

void xchannel_detach(xChannel* ch) {
    if (!ch || ch->fd == INVALID_SOCKET_VAL) return;
    xpoll_del_event(ch->fd, XPOLL_ALL);
    ch->attached = false;
}

int xchannel_send_raw(xChannel* ch, const char* data, size_t len) {
    return queue_or_send_raw(ch, data, len);
}

int xchannel_send_packet(xChannel* ch, const char* data, size_t len) {
    if (!ch || ch->closed || (!data && len > 0)) return -1;
    if (has_pending_file(ch)) return -1;

    if (ch->frame == XCHANNEL_FRAME_LEN32) {
        if (len > UINT32_MAX || len > SIZE_MAX - 4) return -1;
        char* pkt = (char*)malloc(len + 4);
        if (!pkt) return -1;
        write_u32be(pkt, (uint32_t)len);
        if (len > 0) memcpy(pkt + 4, data, len);
        int rc = queue_or_send_raw(ch, pkt, len + 4);
        free(pkt);
        return rc;
    }

    if (ch->frame == XCHANNEL_FRAME_CRLF) {
        if (len > SIZE_MAX - 2) return -1;
        char* pkt = (char*)malloc(len + 2);
        if (!pkt) return -1;
        if (len > 0) memcpy(pkt, data, len);
        pkt[len] = '\r';
        pkt[len + 1] = '\n';
        int rc = queue_or_send_raw(ch, pkt, len + 2);
        free(pkt);
        return rc;
    }

    return queue_or_send_raw(ch, data, len);
}

int xchannel_send_file_raw(xChannel* ch,
                           const char* header, size_t header_len,
                           const char* path,
                           long long offset, long long length) {
    if (!ch || ch->closed || ch->fd == INVALID_SOCKET_VAL || !path) return -1;
    if (!header && header_len > 0) return -1;
    if (has_pending_file(ch)) return -1;
    if (offset < 0) offset = 0;

#ifdef __linux__
    int fd = open(path, O_RDONLY);
    if (fd < 0) return -1;

    struct stat st;
    if (fstat(fd, &st) != 0 || !S_ISREG(st.st_mode)) {
        close(fd);
        return -1;
    }

    long long size = (long long)st.st_size;
    if (offset > size) offset = size;
    long long available = size - offset;
    if (length < 0 || length > available) length = available;
    if (length == 0) {
        close(fd);
        return queue_or_send_raw(ch, header, header_len);
    }
#else
    FILE* fp = fopen(path, "rb");
    if (!fp) return -1;

#ifdef _WIN32
    if (_fseeki64(fp, 0, SEEK_END) != 0) {
        fclose(fp);
        return -1;
    }
    long long size = _ftelli64(fp);
#else
    if (fseeko(fp, 0, SEEK_END) != 0) {
        fclose(fp);
        return -1;
    }
    long long size = (long long)ftello(fp);
#endif
    if (size < 0) {
        fclose(fp);
        return -1;
    }
    if (offset > size) offset = size;
    long long available = size - offset;
    if (length < 0 || length > available) length = available;
    if (length == 0) {
        fclose(fp);
        return queue_or_send_raw(ch, header, header_len);
    }
#ifdef _WIN32
    if (_fseeki64(fp, offset, SEEK_SET) != 0) {
#else
    if (fseeko(fp, (off_t)offset, SEEK_SET) != 0) {
#endif
        fclose(fp);
        return -1;
    }
#endif

    if (!buffer_append(&ch->outbuf, &ch->outlen, &ch->outcap,
                       header ? header : "", header_len)) {
#ifdef __linux__
        close(fd);
#else
        fclose(fp);
#endif
        xchannel_close(ch, "out_of_memory");
        return -1;
    }

#ifdef __linux__
    ch->file_fd = fd;
    ch->file_offset = offset;
#else
    ch->file_fp = fp;
#endif
    ch->file_pending = true;
    ch->file_remaining = length;

    flush_output(ch);
    if (!ch->closed && (ch->outlen > 0 || has_pending_file(ch))) {
        if (xpoll_add_event(ch->fd, XPOLL_WRITABLE, NULL,
                            xchannel_write_event, xchannel_error_event, ch) != 0) {
            xchannel_close(ch, "poll_error");
            return -1;
        }
        xpoll_set_client_data(ch->fd, ch);
    }
    return ch->closed ? -1 : 0;
}

void xchannel_close(xChannel* ch, const char* reason) {
    if (!ch) return;
    xchannel_retain(ch);
    close_internal(ch, reason, true);
    xchannel_release(ch);
}
