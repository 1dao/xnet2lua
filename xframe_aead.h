#ifndef XFRAME_AEAD_H
#define XFRAME_AEAD_H

#include <stddef.h>
#include <stdint.h>

#include "xchannel.h"

#ifdef __cplusplus
extern "C" {
#endif

/* Per-channel AEAD state. Two independent keys + sequence counters, plus a
** 4-byte nonce salt per direction. Wire format per framed packet:
**
**   [ seq:8 BE | ct:N | tag:16 ]
**
** The 12-byte ChaCha20-Poly1305 nonce is built as send_salt:4 || seq:8 (BE).
** The seq travels with each frame so the receiver can rebuild the nonce;
** integrity is enforced by the tag.
**
** ---- Salt uniqueness: skeleton-grade, not production-grade ----
** The 4-byte salt is a 32-bit random value generated per connection. With
** birthday bounds, expect a salt collision under the same key around:
**   ~10K connections   ->  ~1% collision probability
**   ~65K connections   -> ~50% collision probability
** A collision means two connections share the same (key, salt) prefix, so
** their seq=1 packets reuse the same (key, nonce) pair. ChaCha20-Poly1305
** loses BOTH confidentiality (XOR of plaintexts leaks) and integrity (the
** Poly1305 subkey is recoverable, enabling arbitrary tag forgery).
**
** Why we accept this for v0: the gate/client demo uses pre-shared static
** keys as a placeholder, and the salt swap only buys per-connection nonce
** separation up to the birthday bound. For production deployments do ONE
** of the following instead:
**   (a) derive a fresh per-session key via ECDH at connection open; the
**       salt becomes redundant under unique keys.
**   (b) widen the salt and/or include a counter in the salt namespace
**       (e.g. gate-assigned monotonic prefix), ensuring true uniqueness
**       under a single key across the program lifetime.
**
** Anti-replay is strict monotonic: a received seq <= the highest accepted
** seq is rejected. Correct for in-order TCP and avoids a window. */
typedef struct xFrameAead xFrameAead;

/* Keys are 32 bytes each, salts are 4 bytes each.
** send_salt becomes the prefix of every nonce this side encrypts under.
** recv_salt is the peer's send_salt, used to rebuild nonces on decrypt.
** See the salt-uniqueness section above before reusing keys across many
** connections. Returns NULL on alloc/key failure or when built without
** WITH_HTTPS. */
xFrameAead* xframe_aead_create(const uint8_t send_key[32],
                                const uint8_t recv_key[32],
                                const uint8_t send_salt[4],
                                const uint8_t recv_salt[4]);

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
