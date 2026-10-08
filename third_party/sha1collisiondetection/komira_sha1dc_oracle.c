/*
 * Read access to sha1collisiondetection's internals for the conformance
 * tests that use it as an oracle (src/tests/conformance/komira_git_conformance).
 * Compiled into the library beside upstream's sha1.c and ubc_check.c.
 *
 * The context size lets a caller allocate a SHA1_CTX it cannot declare and
 * komira_sha1dc_last_recompression reads two of its fields; the
 * disturbance-vector accessors read upstream's sha1_dvs table, which is data
 * a caller outside C cannot address by name.
 */

#include <stddef.h>
#include <stdint.h>

#include "sha1.h"
#include "ubc_check.h"

/* sizeof(SHA1_CTX). */
size_t komira_sha1dc_ctx_size(void) { return sizeof(SHA1_CTX); }

/* The number of entries of sha1_dvs before its all-zero terminator. */
int komira_sha1dc_dv_count(void) {
  int n = 0;
  while (sha1_dvs[n].dvType != 0) {
    n++;
  }
  return n;
}

/* Field `field` of sha1_dvs[dv]: 0 dvType, 1 dvK, 2 dvB, 3 testt, 4 maski,
 * 5 maskb; -1 for any other field. */
int komira_sha1dc_dv_field(int dv, int field) {
  switch (field) {
    case 0: return sha1_dvs[dv].dvType;
    case 1: return sha1_dvs[dv].dvK;
    case 2: return sha1_dvs[dv].dvB;
    case 3: return sha1_dvs[dv].testt;
    case 4: return sha1_dvs[dv].maski;
    case 5: return sha1_dvs[dv].maskb;
    default: return -1;
  }
}

/* Word t (0 <= t < 80) of sha1_dvs[dv].dm, the disturbance vector's
 * expanded message difference. */
uint32_t komira_sha1dc_dv_word(int dv, int t) { return sha1_dvs[dv].dm[t]; }

/* The last disturbance vector the context's block check recompressed:
 * ctx->m2, its 80-word expanded message, into m2, and ctx->ihv2, the
 * chaining value that recompression started from, into ihv2. */
void komira_sha1dc_last_recompression(const SHA1_CTX *ctx, uint32_t ihv2[5],
                                      uint32_t m2[80]) {
  for (int i = 0; i < 5; i++) {
    ihv2[i] = ctx->ihv2[i];
  }
  for (int t = 0; t < 80; t++) {
    m2[t] = ctx->m2[t];
  }
}
