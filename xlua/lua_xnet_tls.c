#ifndef XNET_WITH_HTTPS
#define XNET_WITH_HTTPS 0
#endif

#if XNET_WITH_HTTPS

#include "lua_xnet_tls.h"

#include <stdlib.h>
#include <string.h>
#include <stdbool.h>
#include <stdint.h>
#include <limits.h>
#include <stdio.h>
#ifndef _WIN32
#include <sys/types.h>
#endif

#if defined(LUA_EMBEDDED)
#include "../3rd/minilua.h"
#else
#include "lua.h"
#include "lauxlib.h"
#endif

#include "xpoll.h"
#include "xsock.h"
#include "xlog.h"

#include "mbedtls/ctr_drbg.h"
#include "mbedtls/entropy.h"
#include "mbedtls/error.h"
#include "mbedtls/net_sockets.h"
#include "mbedtls/pk.h"
#include "mbedtls/ssl.h"
#include "mbedtls/x509_crt.h"
#include "psa/crypto.h"

#ifndef lua_absindex
#define lua_absindex(L, i) \
    (((i) > 0 || (i) <= LUA_REGISTRYINDEX) ? (i) : lua_gettop(L) + (i) + 1)
#endif

#define LUA_XNET_TLS_META "xnet.tls_connection"

static void ref_unref(lua_State* L, int* ref) {
    if (*ref != LUA_NOREF && *ref != LUA_REFNIL) {
        luaL_unref(L, LUA_REGISTRYINDEX, *ref);
    }
    *ref = LUA_NOREF;
}

static void ref_from_stack(lua_State* L, int idx, int* ref) {
    idx = lua_absindex(L, idx);
    ref_unref(L, ref);
    lua_pushvalue(L, idx);
    *ref = luaL_ref(L, LUA_REGISTRYINDEX);
}

static bool push_handler(lua_State* L, int handler_ref,
                         const char* name1,
                         const char* name2,
                         const char* name3) {
    if (handler_ref == LUA_NOREF || handler_ref == LUA_REFNIL) return false;

    int base = lua_gettop(L);
    lua_rawgeti(L, LUA_REGISTRYINDEX, handler_ref);
    if (!lua_istable(L, -1)) {
        lua_settop(L, base);
        return false;
    }

    lua_getfield(L, -1, name1);
    if (!lua_isfunction(L, -1) && name2) {
        lua_pop(L, 1);
        lua_getfield(L, -1, name2);
    }
    if (!lua_isfunction(L, -1) && name3) {
        lua_pop(L, 1);
        lua_getfield(L, -1, name3);
    }
    if (!lua_isfunction(L, -1)) {
        lua_settop(L, base);
        return false;
    }

    lua_remove(L, -2);
    return true;
}


static size_t packet_consumed_return(lua_State* L, int idx, size_t max_len) {
    if (lua_type(L, idx) != LUA_TNUMBER) return 0;
    lua_Number n = lua_tonumber(L, idx);
    if (n <= 0) return 0;
    if (n > (lua_Number)max_len) return max_len == SIZE_MAX ? SIZE_MAX : max_len + 1;
    return (size_t)n;
}

typedef struct LuaTlsConn {
    lua_State* L;
    SOCKET_T fd;
    int self_ref;
    int handler_ref;
    bool closed;
    bool handshake_done;
    char peer_ip[64];
    int peer_port;
    size_t max_packet;

    char* inbuf;
    size_t inlen;
    size_t incap;

    char* outbuf;
    size_t outlen;
    size_t outcap;
    size_t max_send;

    mbedtls_ssl_context ssl;
    mbedtls_ssl_config conf;
    mbedtls_x509_crt cert;
    mbedtls_pk_context pkey;
    mbedtls_entropy_context entropy;
    mbedtls_ctr_drbg_context ctr_drbg;
} LuaTlsConn;

static int push_tls_send_result(lua_State* L, LuaTlsConn* c, int rc) {
    if (rc == 0) {
        lua_pushboolean(L, 1);
        return 1;
    }
    lua_pushboolean(L, 0);
    if (rc == -2) {
        lua_pushstring(L, "send buffer full");
    } else if (!c || c->closed || c->fd == INVALID_SOCKET_VAL) {
        lua_pushstring(L, "closed");
    } else {
        lua_pushstring(L, "write_error");
    }
    return 2;
}

static int s_psa_ready = 0;

static void tls_read_event(SOCKET_T fd, int mask,
                           void* clientData, xPollRequest* submit_arg);
static void tls_write_event(SOCKET_T fd, int mask,
                            void* clientData, xPollRequest* submit_arg);
static void tls_error_event(SOCKET_T fd, int mask,
                            void* clientData, xPollRequest* submit_arg);

static LuaTlsConn* check_tls_conn(lua_State* L, int idx) {
    return (LuaTlsConn*)luaL_checkudata(L, idx, LUA_XNET_TLS_META);
}

static void push_tls_self(lua_State* L, LuaTlsConn* c) {
    if (!c || c->self_ref == LUA_NOREF || c->self_ref == LUA_REFNIL)
        lua_pushnil(L);
    else
        lua_rawgeti(L, LUA_REGISTRYINDEX, c->self_ref);
}

static bool tls_reserve(char** buf, size_t* cap, size_t need) {
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

static bool tls_append(char** buf, size_t* len, size_t* cap,
                       const char* data, size_t data_len) {
    if (data_len == 0) return true;
    if (*len > SIZE_MAX - data_len) return false;
    if (!tls_reserve(buf, cap, *len + data_len)) return false;
    memcpy(*buf + *len, data, data_len);
    *len += data_len;
    return true;
}

static void tls_consume(char* buf, size_t* len, size_t n) {
    if (n >= *len) {
        *len = 0;
        return;
    }
    memmove(buf, buf + n, *len - n);
    *len -= n;
}

static void tls_errmsg(int rc, char* buf, size_t len) {
    if (!buf || len == 0) return;
    mbedtls_strerror(rc, buf, len);
    buf[len - 1] = '\0';
}

static int tls_net_send(void* ctx, const unsigned char* buf, size_t len) {
    LuaTlsConn* c = (LuaTlsConn*)ctx;
    if (!c || c->closed || c->fd == INVALID_SOCKET_VAL) return MBEDTLS_ERR_NET_SEND_FAILED;

    size_t chunk_len = len > INT_MAX ? INT_MAX : len;
    int n = send(c->fd, (const char*)buf, (int)chunk_len, 0);
    if (n >= 0) return n;
    if (socket_check_eagain()) return MBEDTLS_ERR_SSL_WANT_WRITE;
    return MBEDTLS_ERR_NET_SEND_FAILED;
}

static int tls_net_recv(void* ctx, unsigned char* buf, size_t len) {
    LuaTlsConn* c = (LuaTlsConn*)ctx;
    if (!c || c->closed || c->fd == INVALID_SOCKET_VAL) return MBEDTLS_ERR_NET_RECV_FAILED;

    size_t chunk_len = len > INT_MAX ? INT_MAX : len;
    int n = recv(c->fd, (char*)buf, (int)chunk_len, 0);
    if (n > 0) return n;
    if (n == 0) return 0;
    if (socket_check_eagain()) return MBEDTLS_ERR_SSL_WANT_READ;
    return MBEDTLS_ERR_NET_RECV_FAILED;
}

static void tls_unref_lua(LuaTlsConn* c) {
    if (!c || !c->L) return;
    ref_unref(c->L, &c->handler_ref);
    ref_unref(c->L, &c->self_ref);
}

static void tls_free_crypto(LuaTlsConn* c) {
    if (!c) return;
    mbedtls_ssl_free(&c->ssl);
    mbedtls_ssl_config_free(&c->conf);
    mbedtls_x509_crt_free(&c->cert);
    mbedtls_pk_free(&c->pkey);
    mbedtls_ctr_drbg_free(&c->ctr_drbg);
    mbedtls_entropy_free(&c->entropy);
}

static void tls_close_internal(LuaTlsConn* c, const char* reason, bool notify) {
    if (!c || c->closed) return;

    if (c->fd != INVALID_SOCKET_VAL) {
        xpoll_del_event(c->fd, XPOLL_ALL);
        (void)mbedtls_ssl_close_notify(&c->ssl);
        xsock_close(c->fd);
        c->fd = INVALID_SOCKET_VAL;
    }

    c->closed = true;

    if (notify && c->L && c->handler_ref != LUA_NOREF && c->handler_ref != LUA_REFNIL) {
        lua_State* L = c->L;
        int base = lua_gettop(L);
        if (push_handler(L, c->handler_ref, "on_close", "on_disconnect", NULL)) {
            push_tls_self(L, c);
            lua_pushstring(L, reason ? reason : "closed");
            if (lua_pcall(L, 2, 0, 0) != LUA_OK) {
                XLOGE("xnet: tls on_close error: %s", lua_tostring(L, -1));
            }
        }
        lua_settop(L, base);
    }

    tls_unref_lua(c);
}

static int tls_arm_read(LuaTlsConn* c) {
    if (!c || c->closed || c->fd == INVALID_SOCKET_VAL) return -1;
    if (xpoll_add_event(c->fd, XPOLL_READABLE,
                        tls_read_event, NULL, tls_error_event, c) != 0) {
        return -1;
    }
    xpoll_set_client_data(c->fd, c);
    return 0;
}

static int tls_arm_write(LuaTlsConn* c) {
    if (!c || c->closed || c->fd == INVALID_SOCKET_VAL) return -1;
    if (xpoll_add_event(c->fd, XPOLL_WRITABLE,
                        NULL, tls_write_event, tls_error_event, c) != 0) {
        return -1;
    }
    xpoll_set_client_data(c->fd, c);
    return 0;
}

static void tls_disarm_write(LuaTlsConn* c) {
    if (!c || c->closed || c->fd == INVALID_SOCKET_VAL) return;
    xpoll_del_event(c->fd, XPOLL_WRITABLE);
}

static void tls_call_connect(LuaTlsConn* c) {
    if (!c || c->closed || !c->L) return;

    lua_State* L = c->L;
    int base = lua_gettop(L);
    push_tls_self(L, c);

    if (push_handler(L, c->handler_ref, "on_connect", "connect", NULL)) {
        push_tls_self(L, c);
        if (c->peer_ip[0]) lua_pushstring(L, c->peer_ip);
        else lua_pushnil(L);
        if (c->peer_port > 0) lua_pushinteger(L, c->peer_port);
        else lua_pushnil(L);

        if (lua_pcall(L, 3, LUA_MULTRET, 0) != LUA_OK) {
            XLOGE("xnet: tls on_connect error: %s", lua_tostring(L, -1));
            lua_settop(L, base);
            tls_close_internal(c, "handler_error", true);
            return;
        }

        if (lua_gettop(L) >= base + 2 && lua_istable(L, base + 2)) {
            ref_from_stack(L, base + 2, &c->handler_ref);
        }
    }

    lua_settop(L, base);
}

static int tls_send_raw_c(LuaTlsConn* c, const char* data, size_t len);

static void tls_handle_packet_returns(LuaTlsConn* c, int first, int last) {
    lua_State* L = c->L;
    for (int i = first; i <= last && !c->closed; i++) {
        if (lua_type(L, i) != LUA_TSTRING) continue;
        size_t len = 0;
        const char* data = lua_tolstring(L, i, &len);
        tls_send_raw_c(c, data, len);
    }
}

static void tls_process_input(LuaTlsConn* c) {
    while (c && !c->closed && c->inlen > 0) {
        if (c->inlen > c->max_packet) {
            tls_close_internal(c, "packet_too_large", true);
            return;
        }

        lua_State* L = c->L;
        int base = lua_gettop(L);
        push_tls_self(L, c);
        if (!push_handler(L, c->handler_ref, "on_packet", "on_message", "on_recv")) {
            lua_settop(L, base);
            return;
        }

        push_tls_self(L, c);
        lua_pushlstring(L, c->inbuf, c->inlen);
        if (lua_pcall(L, 2, LUA_MULTRET, 0) != LUA_OK) {
            XLOGE("xnet: tls on_packet error: %s", lua_tostring(L, -1));
            lua_settop(L, base);
            tls_close_internal(c, "handler_error", true);
            return;
        }

        int first_ret = base + 2;
        int last_ret = lua_gettop(L);
        size_t consumed = (first_ret <= last_ret)
            ? packet_consumed_return(L, first_ret, c->inlen)
            : 0;
        tls_handle_packet_returns(c, first_ret, last_ret);
        lua_settop(L, base);

        if (c->closed) return;
        if (consumed == 0) return;
        if (consumed > c->inlen) {
            tls_close_internal(c, "consume_error", true);
            return;
        }
        tls_consume(c->inbuf, &c->inlen, consumed);
    }
}

static void tls_flush_output(LuaTlsConn* c);
static void tls_read_plain(LuaTlsConn* c);

static void tls_drive_handshake(LuaTlsConn* c) {
    if (!c || c->closed || c->handshake_done) return;

    while (!c->closed && !c->handshake_done) {
        int rc = mbedtls_ssl_handshake(&c->ssl);
        if (rc == 0) {
            c->handshake_done = true;
            tls_disarm_write(c);
            tls_call_connect(c);
            if (!c->closed) tls_flush_output(c);
            if (!c->closed) tls_read_plain(c);
            return;
        }
        if (rc == MBEDTLS_ERR_SSL_WANT_READ) {
            tls_disarm_write(c);
            return;
        }
        if (rc == MBEDTLS_ERR_SSL_WANT_WRITE) {
            if (tls_arm_write(c) != 0) {
                tls_close_internal(c, "poll_error", true);
            }
            return;
        }

        char errbuf[160];
        tls_errmsg(rc, errbuf, sizeof(errbuf));
        XLOGE("xnet: tls handshake failed: %s (%d)", errbuf, rc);
        tls_close_internal(c, "tls_handshake_error", true);
        return;
    }
}

static void tls_flush_output(LuaTlsConn* c) {
    if (!c || c->closed) return;
    if (!c->handshake_done) {
        tls_drive_handshake(c);
        return;
    }

    while (!c->closed && c->outlen > 0) {
        int rc = mbedtls_ssl_write(&c->ssl, (const unsigned char*)c->outbuf, c->outlen);
        if (rc > 0) {
            tls_consume(c->outbuf, &c->outlen, (size_t)rc);
            continue;
        }
        if (rc == MBEDTLS_ERR_SSL_WANT_READ) {
            tls_disarm_write(c);
            return;
        }
        if (rc == MBEDTLS_ERR_SSL_WANT_WRITE) {
            if (tls_arm_write(c) != 0) {
                tls_close_internal(c, "poll_error", true);
            }
            return;
        }

        char errbuf[160];
        tls_errmsg(rc, errbuf, sizeof(errbuf));
        XLOGE("xnet: tls write failed: %s (%d)", errbuf, rc);
        tls_close_internal(c, "tls_write_error", true);
        return;
    }

    if (!c->closed && c->outlen == 0) {
        tls_disarm_write(c);
    }
}

static int tls_send_raw_c(LuaTlsConn* c, const char* data, size_t len) {
    if (!c || c->closed || (!data && len > 0)) return -1;
    if (len == 0) return 0;
    if (c->max_send > 0) {
        if (c->outlen >= c->max_send) return -2;
        if (len > c->max_send - c->outlen) return -2;
    }
    if (!tls_append(&c->outbuf, &c->outlen, &c->outcap, data, len)) {
        tls_close_internal(c, "out_of_memory", true);
        return -1;
    }
    tls_flush_output(c);
    if (!c->closed && c->outlen > 0) {
        if (tls_arm_write(c) != 0) {
            tls_close_internal(c, "poll_error", true);
            return -1;
        }
    }
    return c->closed ? -1 : 0;
}

static void tls_read_plain(LuaTlsConn* c) {
    if (!c || c->closed) return;
    if (!c->handshake_done) {
        tls_drive_handshake(c);
        return;
    }

    unsigned char buf[8192];
    while (!c->closed) {
        int rc = mbedtls_ssl_read(&c->ssl, buf, sizeof(buf));
        if (rc > 0) {
            if (!tls_append(&c->inbuf, &c->inlen, &c->incap, (const char*)buf, (size_t)rc)) {
                tls_close_internal(c, "out_of_memory", true);
                return;
            }
            continue;
        }
        if (rc == 0 || rc == MBEDTLS_ERR_SSL_PEER_CLOSE_NOTIFY) {
            tls_close_internal(c, "eof", true);
            return;
        }
        if (rc == MBEDTLS_ERR_SSL_WANT_READ) {
            break;
        }
        if (rc == MBEDTLS_ERR_SSL_WANT_WRITE) {
            if (tls_arm_write(c) != 0) {
                tls_close_internal(c, "poll_error", true);
            }
            break;
        }

        char errbuf[160];
        tls_errmsg(rc, errbuf, sizeof(errbuf));
        XLOGE("xnet: tls read failed: %s (%d)", errbuf, rc);
        tls_close_internal(c, "tls_read_error", true);
        return;
    }

    if (!c->closed) {
        tls_process_input(c);
    }
}

static void tls_read_event(SOCKET_T fd, int mask,
                           void* clientData, xPollRequest* submit_arg) {
    (void)fd;
    (void)mask;
    (void)submit_arg;
    LuaTlsConn* c = (LuaTlsConn*)clientData;
    if (!c || c->closed) return;

    if (!c->handshake_done) tls_drive_handshake(c);
    else tls_read_plain(c);
    if (!c->closed && c->outlen > 0) tls_flush_output(c);
}

static void tls_write_event(SOCKET_T fd, int mask,
                            void* clientData, xPollRequest* submit_arg) {
    (void)fd;
    (void)mask;
    (void)submit_arg;
    LuaTlsConn* c = (LuaTlsConn*)clientData;
    if (!c || c->closed) return;

    if (!c->handshake_done) tls_drive_handshake(c);
    else tls_flush_output(c);
}

static void tls_error_event(SOCKET_T fd, int mask,
                            void* clientData, xPollRequest* submit_arg) {
    (void)fd;
    (void)mask;
    (void)submit_arg;
    LuaTlsConn* c = (LuaTlsConn*)clientData;
    if (!c || c->closed) return;
    tls_close_internal(c, "socket_error", true);
}

static int tls_setup_context(lua_State* L, LuaTlsConn* c, int cfg_idx) {
    const char* cert_file = NULL;
    const char* key_file = NULL;
    const char* password = NULL;
    size_t max_packet = 0;
    size_t max_send = 0;
    bool has_max_send = false;

    lua_getfield(L, cfg_idx, "cert_file");
    if (lua_isstring(L, -1)) cert_file = lua_tostring(L, -1);
    lua_pop(L, 1);
    if (!cert_file) {
        lua_getfield(L, cfg_idx, "cert");
        if (lua_isstring(L, -1)) cert_file = lua_tostring(L, -1);
        lua_pop(L, 1);
    }

    lua_getfield(L, cfg_idx, "key_file");
    if (lua_isstring(L, -1)) key_file = lua_tostring(L, -1);
    lua_pop(L, 1);
    if (!key_file) {
        lua_getfield(L, cfg_idx, "key");
        if (lua_isstring(L, -1)) key_file = lua_tostring(L, -1);
        lua_pop(L, 1);
    }

    lua_getfield(L, cfg_idx, "password");
    if (lua_isstring(L, -1)) password = lua_tostring(L, -1);
    lua_pop(L, 1);

    lua_getfield(L, cfg_idx, "max_packet");
    if (lua_isnumber(L, -1)) {
        lua_Integer mp = lua_tointeger(L, -1);
        if (mp > 0) max_packet = (size_t)mp;
    }
    lua_pop(L, 1);

    lua_getfield(L, cfg_idx, "max_send");
    if (lua_isnumber(L, -1)) {
        lua_Integer ms = lua_tointeger(L, -1);
        if (ms >= 0) {
            max_send = (size_t)ms;
            has_max_send = true;
        }
    }
    lua_pop(L, 1);

    if (!cert_file || !key_file) {
        lua_pushstring(L, "xnet.attach_tls: cert_file and key_file are required");
        return -1;
    }
    if (max_packet > 0) c->max_packet = max_packet;
    if (has_max_send) c->max_send = max_send;

    if (!s_psa_ready) {
        psa_status_t status = psa_crypto_init();
        if (status != PSA_SUCCESS) {
            lua_pushfstring(L, "psa_crypto_init failed: %d", (int)status);
            return -1;
        }
        s_psa_ready = 1;
    }

    mbedtls_ssl_init(&c->ssl);
    mbedtls_ssl_config_init(&c->conf);
    mbedtls_x509_crt_init(&c->cert);
    mbedtls_pk_init(&c->pkey);
    mbedtls_entropy_init(&c->entropy);
    mbedtls_ctr_drbg_init(&c->ctr_drbg);

    const char* pers = "xnet_tls_server";
    int rc = mbedtls_ctr_drbg_seed(&c->ctr_drbg, mbedtls_entropy_func,
                                   &c->entropy, (const unsigned char*)pers,
                                   strlen(pers));
    if (rc != 0) {
        char errbuf[160];
        tls_errmsg(rc, errbuf, sizeof(errbuf));
        lua_pushfstring(L, "ctr_drbg_seed failed: %s", errbuf);
        return -1;
    }

    rc = mbedtls_x509_crt_parse_file(&c->cert, cert_file);
    if (rc != 0) {
        char errbuf[160];
        tls_errmsg(rc, errbuf, sizeof(errbuf));
        lua_pushfstring(L, "parse cert failed: %s: %s", cert_file, errbuf);
        return -1;
    }

    rc = mbedtls_pk_parse_keyfile(&c->pkey, key_file, password,
                                  mbedtls_ctr_drbg_random, &c->ctr_drbg);
    if (rc != 0) {
        char errbuf[160];
        tls_errmsg(rc, errbuf, sizeof(errbuf));
        lua_pushfstring(L, "parse key failed: %s: %s", key_file, errbuf);
        return -1;
    }

    rc = mbedtls_ssl_config_defaults(&c->conf, MBEDTLS_SSL_IS_SERVER,
                                     MBEDTLS_SSL_TRANSPORT_STREAM,
                                     MBEDTLS_SSL_PRESET_DEFAULT);
    if (rc != 0) {
        char errbuf[160];
        tls_errmsg(rc, errbuf, sizeof(errbuf));
        lua_pushfstring(L, "ssl_config_defaults failed: %s", errbuf);
        return -1;
    }

    mbedtls_ssl_conf_rng(&c->conf, mbedtls_ctr_drbg_random, &c->ctr_drbg);
    mbedtls_ssl_conf_authmode(&c->conf, MBEDTLS_SSL_VERIFY_NONE);

    rc = mbedtls_ssl_conf_own_cert(&c->conf, &c->cert, &c->pkey);
    if (rc != 0) {
        char errbuf[160];
        tls_errmsg(rc, errbuf, sizeof(errbuf));
        lua_pushfstring(L, "ssl_conf_own_cert failed: %s", errbuf);
        return -1;
    }

    rc = mbedtls_ssl_setup(&c->ssl, &c->conf);
    if (rc != 0) {
        char errbuf[160];
        tls_errmsg(rc, errbuf, sizeof(errbuf));
        lua_pushfstring(L, "ssl_setup failed: %s", errbuf);
        return -1;
    }

    mbedtls_ssl_set_bio(&c->ssl, c, tls_net_send, tls_net_recv, NULL);
    return 0;
}

int l_xnet_attach_tls(lua_State* L) {
    SOCKET_T fd = (SOCKET_T)luaL_checkinteger(L, 1);
    luaL_checktype(L, 2, LUA_TTABLE);

    const char* ip = NULL;
    int port = 0;
    int cfg_idx = 0;
    if (lua_istable(L, 3)) {
        cfg_idx = 3;
    } else {
        ip = luaL_optstring(L, 3, NULL);
        port = (int)luaL_optinteger(L, 4, 0);
        cfg_idx = 5;
    }
    luaL_checktype(L, cfg_idx, LUA_TTABLE);

    if (fd == INVALID_SOCKET_VAL) {
        lua_pushnil(L);
        lua_pushstring(L, "invalid fd");
        return 2;
    }

    char err[XSOCK_ERR_LEN] = {0};
    if (xsock_set_nonblock(err, fd) != XSOCK_OK) {
        xsock_close(fd);
        lua_pushnil(L);
        lua_pushstring(L, err[0] ? err : "set nonblock failed");
        return 2;
    }

    LuaTlsConn* c = (LuaTlsConn*)lua_newuserdata(L, sizeof(*c));
    memset(c, 0, sizeof(*c));
    c->L = L;
    c->fd = fd;
    c->self_ref = LUA_NOREF;
    c->handler_ref = LUA_NOREF;
    c->closed = false;
    c->handshake_done = false;
    c->max_packet = 16u * 1024u * 1024u;
    c->max_send = 10u * 1024u * 1024u + 4u;
    if (ip) {
        strncpy(c->peer_ip, ip, sizeof(c->peer_ip) - 1);
        c->peer_ip[sizeof(c->peer_ip) - 1] = '\0';
    }
    c->peer_port = port;

    luaL_getmetatable(L, LUA_XNET_TLS_META);
    lua_setmetatable(L, -2);

    int tls_top = lua_gettop(L);
    int rc = tls_setup_context(L, c, cfg_idx);
    if (rc != 0) {
        const char* msg = lua_tostring(L, -1);
        char saved[256];
        snprintf(saved, sizeof(saved), "%s", msg ? msg : "tls setup failed");
        lua_settop(L, tls_top);
        tls_free_crypto(c);
        xsock_close(fd);
        c->fd = INVALID_SOCKET_VAL;
        c->closed = true;
        lua_pushnil(L);
        lua_pushstring(L, saved);
        return 2;
    }
    lua_settop(L, tls_top);

    ref_from_stack(L, 2, &c->handler_ref);
    lua_pushvalue(L, -1);
    c->self_ref = luaL_ref(L, LUA_REGISTRYINDEX);

    if (tls_arm_read(c) != 0) {
        tls_close_internal(c, "poll_error", false);
        lua_pushnil(L);
        lua_pushstring(L, "xpoll_add_event failed");
        return 2;
    }

    tls_drive_handshake(c);
    return 1;
}

static int l_tls_fd(lua_State* L) {
    LuaTlsConn* c = check_tls_conn(L, 1);
    if (!c || c->closed || c->fd == INVALID_SOCKET_VAL) lua_pushnil(L);
    else lua_pushinteger(L, (lua_Integer)c->fd);
    return 1;
}

static int l_tls_peer(lua_State* L) {
    LuaTlsConn* c = check_tls_conn(L, 1);
    if (c->peer_ip[0]) lua_pushstring(L, c->peer_ip);
    else lua_pushnil(L);
    if (c->peer_port > 0) lua_pushinteger(L, c->peer_port);
    else lua_pushnil(L);
    return 2;
}

static int l_tls_is_closed(lua_State* L) {
    LuaTlsConn* c = check_tls_conn(L, 1);
    lua_pushboolean(L, !c || c->closed);
    return 1;
}

static int l_tls_close(lua_State* L) {
    LuaTlsConn* c = check_tls_conn(L, 1);
    const char* reason = luaL_optstring(L, 2, "closed");
    tls_close_internal(c, reason, true);
    lua_pushboolean(L, 1);
    return 1;
}

static int l_tls_send_raw(lua_State* L) {
    LuaTlsConn* c = check_tls_conn(L, 1);
    size_t len = 0;
    const char* data = luaL_checklstring(L, 2, &len);
    return push_tls_send_result(L, c, tls_send_raw_c(c, data, len));
}

static int l_tls_send_file_response(lua_State* L) {
    LuaTlsConn* c = check_tls_conn(L, 1);
    size_t header_len = 0;
    const char* header = luaL_checklstring(L, 2, &header_len);
    const char* path = luaL_checkstring(L, 3);
    lua_Integer offset_arg = luaL_optinteger(L, 4, 0);
    lua_Integer length_arg = luaL_optinteger(L, 5, -1);
    long long offset = (long long)offset_arg;
    long long length = (long long)length_arg;
    if (offset < 0) offset = 0;

    FILE* fp = fopen(path, "rb");
    if (!fp) {
        lua_pushboolean(L, 0);
        lua_pushstring(L, "open_failed");
        return 2;
    }

#ifdef _WIN32
    if (_fseeki64(fp, 0, SEEK_END) != 0) {
#else
    if (fseeko(fp, 0, SEEK_END) != 0) {
#endif
        fclose(fp);
        lua_pushboolean(L, 0);
        lua_pushstring(L, "seek_failed");
        return 2;
    }

#ifdef _WIN32
    long long size = _ftelli64(fp);
#else
    long long size = (long long)ftello(fp);
#endif
    if (size < 0) {
        fclose(fp);
        lua_pushboolean(L, 0);
        lua_pushstring(L, "stat_failed");
        return 2;
    }
    if (offset > size) offset = size;
    long long remaining = size - offset;
    if (length < 0 || length > remaining) length = remaining;

#ifdef _WIN32
    if (_fseeki64(fp, offset, SEEK_SET) != 0) {
#else
    if (fseeko(fp, (off_t)offset, SEEK_SET) != 0) {
#endif
        fclose(fp);
        lua_pushboolean(L, 0);
        lua_pushstring(L, "seek_failed");
        return 2;
    }

    int send_rc = tls_send_raw_c(c, header, header_len);
    int ok = send_rc == 0;
    char buf[64 * 1024];
    while (ok && length > 0 && !c->closed) {
        size_t want = length > (long long)sizeof(buf)
            ? sizeof(buf)
            : (size_t)length;
        size_t got = fread(buf, 1, want, fp);
        if (got == 0) {
            ok = feof(fp) && length == 0;
            if (!ok) tls_close_internal(c, "tls_file_read_error", true);
            break;
        }
        send_rc = tls_send_raw_c(c, buf, got);
        if (send_rc != 0) {
            ok = 0;
            break;
        }
        length -= (long long)got;
    }

    fclose(fp);
    if (ok && !c->closed) {
        lua_pushboolean(L, 1);
        return 1;
    }
    if (send_rc == 0) send_rc = -1;
    return push_tls_send_result(L, c, send_rc);
}

static int l_tls_send(lua_State* L) {
    return l_tls_send_raw(L);
}

static int l_tls_set_handler(lua_State* L) {
    LuaTlsConn* c = check_tls_conn(L, 1);
    luaL_checktype(L, 2, LUA_TTABLE);
    ref_from_stack(L, 2, &c->handler_ref);
    lua_pushvalue(L, 1);
    return 1;
}

static int l_tls_set_framing(lua_State* L) {
    LuaTlsConn* c = check_tls_conn(L, 1);
    if (lua_istable(L, 2)) {
        lua_getfield(L, 2, "max_packet");
        if (lua_isnumber(L, -1)) {
            lua_Integer mp = lua_tointeger(L, -1);
            if (mp > 0) c->max_packet = (size_t)mp;
        }
        lua_pop(L, 1);

        lua_getfield(L, 2, "max_send");
        if (lua_isnumber(L, -1)) {
            lua_Integer ms = lua_tointeger(L, -1);
            if (ms >= 0) c->max_send = (size_t)ms;
        }
        lua_pop(L, 1);
    }
    lua_pushvalue(L, 1);
    return 1;
}

static int l_tls_gc(lua_State* L) {
    LuaTlsConn* c = (LuaTlsConn*)luaL_checkudata(L, 1, LUA_XNET_TLS_META);
    if (c) {
        tls_close_internal(c, "gc", false);
        tls_free_crypto(c);
        free(c->inbuf);
        free(c->outbuf);
        tls_unref_lua(c);
    }
    return 0;
}

static const luaL_Reg tls_methods[] = {
    { "fd",          l_tls_fd },
    { "peer",        l_tls_peer },
    { "is_closed",   l_tls_is_closed },
    { "close",       l_tls_close },
    { "send",        l_tls_send },
    { "send_raw",    l_tls_send_raw },
    { "send_packet", l_tls_send_raw },
    { "send_file_response", l_tls_send_file_response },
    { "set_handler", l_tls_set_handler },
    { "set_framing", l_tls_set_framing },
    { NULL, NULL }
};

void lua_xnet_tls_register(lua_State* L) {
    if (luaL_newmetatable(L, LUA_XNET_TLS_META)) {
        lua_pushcfunction(L, l_tls_gc);
        lua_setfield(L, -2, "__gc");
        lua_newtable(L);
        luaL_setfuncs(L, tls_methods, 0);
        lua_setfield(L, -2, "__index");
    }
    lua_pop(L, 1);
}

#endif /* XNET_WITH_HTTPS */
