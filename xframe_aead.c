#include "xframe_aead.h"

#include <stdlib.h>
#include <string.h>

#include "xmacro.h"

#if defined(XNET_WITH_HTTPS) && XNET_WITH_HTTPS
#include "mbedtls/chachapoly.h"
#define XFRAME_AEAD_ENABLED 1
#else
#define XFRAME_AEAD_ENABLED 0
#endif

struct xFrameAead {
#if XFRAME_AEAD_ENABLED
    mbedtls_chachapoly_context send_ctx;
    mbedtls_chachapoly_context recv_ctx;
#endif
    uint64_t send_seq;       /* next seq to use when encrypting */
    uint64_t recv_max_seq;   /* highest accepted seq from peer; 0 = none yet */
    int recv_seen_any;       /* 0 until first packet decrypted */
};

#if XFRAME_AEAD_ENABLED
static void seq_to_nonce(uint64_t seq, uint8_t nonce[12]) {
    /* 4 zero bytes + 8-byte BE seq. */
    memset(nonce, 0, 4);
    for (int i = 0; i < 8; i++) {
        nonce[4 + i] = (uint8_t)((seq >> (56 - 8 * i)) & 0xff);
    }
}

static void seq_write_be(uint8_t* p, uint64_t seq) {
    for (int i = 0; i < 8; i++) {
        p[i] = (uint8_t)((seq >> (56 - 8 * i)) & 0xff);
    }
}

static uint64_t seq_read_be(const uint8_t* p) {
    uint64_t v = 0;
    for (int i = 0; i < 8; i++) {
        v = (v << 8) | (uint64_t)p[i];
    }
    return v;
}
#endif

xFrameAead* xframe_aead_create(const uint8_t send_key[32],
                                const uint8_t recv_key[32]) {
#if !XFRAME_AEAD_ENABLED
    (void)send_key; (void)recv_key;
    return NULL;
#else
    if (!send_key || !recv_key) return NULL;
    xFrameAead* a = (xFrameAead*)calloc(1, sizeof(*a));
    if (!a) return NULL;
    mbedtls_chachapoly_init(&a->send_ctx);
    mbedtls_chachapoly_init(&a->recv_ctx);
    if (mbedtls_chachapoly_setkey(&a->send_ctx, send_key) != 0 ||
        mbedtls_chachapoly_setkey(&a->recv_ctx, recv_key) != 0) {
        mbedtls_chachapoly_free(&a->send_ctx);
        mbedtls_chachapoly_free(&a->recv_ctx);
        free(a);
        return NULL;
    }
    a->send_seq = 1;     /* skip 0 so it can mean "uninitialised" */
    a->recv_max_seq = 0;
    a->recv_seen_any = 0;
    return a;
#endif
}

void xframe_aead_destroy(xFrameAead* a) {
    if (!a) return;
#if XFRAME_AEAD_ENABLED
    mbedtls_chachapoly_free(&a->send_ctx);
    mbedtls_chachapoly_free(&a->recv_ctx);
#endif
    free(a);
}

void xframe_aead_dtor(void* ud) {
    xframe_aead_destroy((xFrameAead*)ud);
}

int xframe_aead_encrypt(xChannel* ch,
                         const char* in, size_t in_len,
                         char** out, size_t* out_len,
                         void* ud) {
    (void)ch;
#if !XFRAME_AEAD_ENABLED
    (void)in; (void)in_len; (void)out; (void)out_len; (void)ud;
    return -1;
#else
    xFrameAead* a = (xFrameAead*)ud;
    if (!a || !out || !out_len) return -1;
    if (in_len > 0 && !in) return -1;

    size_t total = 8 + in_len + 16;
    uint8_t* buf = (uint8_t*)malloc(total > 0 ? total : 1);
    if (!buf) return -1;

    uint64_t seq = a->send_seq;
    if (seq == 0) { free(buf); return -1; }  /* exhausted */

    uint8_t nonce[12];
    seq_to_nonce(seq, nonce);
    seq_write_be(buf, seq);

    int rc = mbedtls_chachapoly_encrypt_and_tag(
        &a->send_ctx, in_len, nonce, NULL, 0,
        (const unsigned char*)in, buf + 8, buf + 8 + in_len);
    if (rc != 0) {
        free(buf);
        return -1;
    }

    a->send_seq = seq + 1;
    *out = (char*)buf;
    *out_len = total;
    return 0;
#endif
}

int xframe_aead_decrypt(xChannel* ch,
                         const char* in, size_t in_len,
                         char** out, size_t* out_len,
                         void* ud) {
    (void)ch;
#if !XFRAME_AEAD_ENABLED
    (void)in; (void)in_len; (void)out; (void)out_len; (void)ud;
    return -1;
#else
    xFrameAead* a = (xFrameAead*)ud;
    if (!a || !in || !out || !out_len) return -1;
    if (in_len < 8 + 16) return -1;  /* must hold at least seq + tag */

    uint64_t seq = seq_read_be((const uint8_t*)in);
    if (seq == 0) return -1;
    if (a->recv_seen_any && seq <= a->recv_max_seq) return -1;  /* replay */

    size_t ct_len = in_len - 8 - 16;
    char* plain = (char*)malloc(ct_len > 0 ? ct_len : 1);
    if (!plain) return -1;

    uint8_t nonce[12];
    seq_to_nonce(seq, nonce);

    int rc = mbedtls_chachapoly_auth_decrypt(
        &a->recv_ctx, ct_len, nonce, NULL, 0,
        (const unsigned char*)in + 8 + ct_len,                /* tag */
        (const unsigned char*)in + 8,                          /* ct  */
        (unsigned char*)plain);
    if (rc != 0) {
        free(plain);
        return -1;
    }

    a->recv_max_seq = seq;
    a->recv_seen_any = 1;
    *out = plain;
    *out_len = ct_len;
    return 0;
#endif
}
