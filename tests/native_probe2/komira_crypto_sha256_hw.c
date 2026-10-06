/* The exported entry to aws-lc's SHA-NI block function (EXPERIMENT; see BUCK).
 *
 * komira_crypto calls sha256_block_data_order_hw by name. aws-lc's assembly
 * declares it `.hidden`, so no linker flag can export it from a shared
 * object; this wrapper is the exported name. It is compiled with the prefix
 * header, so the call below binds to komira_awslc_sha256_block_data_order_hw
 * inside libkomira_native.so.1. The caller must have checked for SHA-NI, as
 * komira_crypto does today.
 */
#include <stddef.h>
#include <stdint.h>

void sha256_block_data_order_hw(uint32_t state[8], const uint8_t *data, size_t num);

__attribute__((visibility("default"))) void komira_crypto_sha256_block_data_order_hw(uint32_t state[8],
                                                                                      const uint8_t *data,
                                                                                      size_t num) {
    sha256_block_data_order_hw(state, data, num);
}
