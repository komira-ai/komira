/* komira_crypto's exported entry to aws-lc's SHA-NI block function.
 *
 * internal/asm/sha256_compress.mojo calls aws-lc's hand-tuned
 * sha256_block_data_order_hw. aws-lc's assembly declares that function
 * `.hidden`, so no shared object can export it; this wrapper is the name the
 * Mojo code calls instead. It is compiled with aws-lc's prefix header (an
 * exported flag of //third_party/aws-lc:crypto), so the call below binds to
 * komira_awslc_sha256_block_data_order_hw. Like the function it wraps, it
 * needs a CPU with the SHA extensions and reads `num` 64-byte blocks; it
 * checks neither.
 */
#include <stddef.h>
#include <stdint.h>

void sha256_block_data_order_hw(uint32_t state[8], const uint8_t *data, size_t num);

__attribute__((visibility("default"))) void komira_crypto_sha256_block_data_order_hw(uint32_t state[8],
                                                                                      const uint8_t *data,
                                                                                      size_t num) {
    sha256_block_data_order_hw(state, data, num);
}
