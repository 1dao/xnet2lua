#ifndef XFRAME_AEAD_H
#define XFRAME_AEAD_H

#include <stddef.h>
#include <stdint.h>

#include "xchannel.h"

#ifdef __cplusplus
extern "C" {
#endif

/* Per-channel AEAD state. Holds two independent keys (one per direction)
** plus the send/recv sequence counters. Wire format per framed packet:
**
**   [ seq:8 BE | ct:N | tag:16 ]
**
** The 12-byte ChaCha20-Poly1305 nonce is built as 4 zero bytes followed by
** the 8-byte BE seq. The seq travels in cleartext so the receiver knows
** which nonce to verify against; integrity is guaranteed by the tag, so
** an attacker flipping seq bits causes auth failure.
**
** Anti-replay is strict monotonic: a received seq <= the highest accepted
** seq is rejected. This is correct for in-order TCP and avoids a window. */
typedef struct xFrameAead xFrameAead;

/* Both keys must be 32 bytes. Returns NULL on alloc/key failure. */
xFrameAead* xframe_aead_create(const uint8_t send_key[32],
                                const uint8_t recv_key[32]);

void        xframe_aead_destroy(xFrameAead* a);

/* xChannelSendTransform — encrypts `in` and writes a malloc'd buffer to
** *out / *out_len. Caller frees. Returns 0 on success, negative on error. */
int  xframe_aead_encrypt(xChannel* ch,
                          const char* in, size_t in_len,
                          char** out, size_t* out_len,
                          void* ud);

/* xChannelRecvTransform — verifies + decrypts `in`. Returns 0 on success,
** negative if too short, replayed, or tag mismatch. */
int  xframe_aead_decrypt(xChannel* ch,
                          const char* in, size_t in_len,
                          char** out, size_t* out_len,
                          void* ud);

/* Convenience: xChannelTransformDtor that casts ud back to xFrameAead*. */
void xframe_aead_dtor(void* ud);

#define XFRAME_AEAD_OVERHEAD 24  /* 8B seq + 16B tag */

#ifdef __cplusplus
}
#endif

#endif /* XFRAME_AEAD_H */
