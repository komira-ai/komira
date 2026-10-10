/* komira_crypto's exported entries to aws-lc's SHA-256 block functions.
 *
 * internal/asm/sha256_compress.mojo calls aws-lc's hand-tuned block bodies.
 * aws-lc's assembly declares them `.hidden`, so no shared object can export
 * them; these wrappers are the names the Mojo code calls instead. They are
 * compiled with aws-lc's prefix header (an exported flag of
 * //third_party/aws-lc:crypto), so the calls below bind to
 * komira_awslc_sha256_block_data_order_{hw,nohw}.
 *
 * sha256_block_data_order_hw executes the x86-64 SHA extensions and dies with
 * SIGILL on a CPU without them, so komira_crypto_sha256_block_data_order
 * checks the CPU first (CPUID leaf 7, sub-leaf 0, EBX bit 29, read once and
 * cached) and otherwise runs sha256_block_data_order_nohw, aws-lc's portable
 * body. On other architectures it always runs the portable body.
 * komira_crypto_sha256_block_data_order_nohw runs the portable body on any
 * CPU, so a test can compare the two on a host that has the extensions.
 * Every entry reads `num` 64-byte blocks from `data` and updates `state[8]`;
 * none checks either length.
 */
#include <stddef.h>
#include <stdint.h>

#if defined(__x86_64__)
#include <cpuid.h>
#endif

void sha256_block_data_order_hw(uint32_t state[8], const uint8_t *data, size_t num);
void sha256_block_data_order_nohw(uint32_t state[8], const uint8_t *data, size_t num);

/* 0: not read yet; 1: no SHA extensions; 2: SHA extensions present. A race
 * between two first callers stores the same value twice. */
static int komira_crypto_sha256_hw_state = 0;

static int komira_crypto_cpu_has_sha_ext(void) {
#if defined(__x86_64__)
    unsigned int eax = 0, ebx = 0, ecx = 0, edx = 0;
    /* __get_cpuid_count returns 0 when the CPU has no leaf 7. */
    if (!__get_cpuid_count(7, 0, &eax, &ebx, &ecx, &edx)) {
        return 0;
    }
    return (ebx & (1u << 29)) != 0;
#else
    return 0;
#endif
}

__attribute__((visibility("default"))) int komira_crypto_sha256_hw_capable(void) {
    int s = __atomic_load_n(&komira_crypto_sha256_hw_state, __ATOMIC_RELAXED);
    if (s == 0) {
        s = komira_crypto_cpu_has_sha_ext() ? 2 : 1;
        __atomic_store_n(&komira_crypto_sha256_hw_state, s, __ATOMIC_RELAXED);
    }
    return s == 2;
}

__attribute__((visibility("default"))) void komira_crypto_sha256_block_data_order(uint32_t state[8],
                                                                                   const uint8_t *data,
                                                                                   size_t num) {
#if defined(__x86_64__)
    if (komira_crypto_sha256_hw_capable()) {
        sha256_block_data_order_hw(state, data, num);
        return;
    }
#endif
    sha256_block_data_order_nohw(state, data, num);
}

__attribute__((visibility("default"))) void komira_crypto_sha256_block_data_order_nohw(uint32_t state[8],
                                                                                        const uint8_t *data,
                                                                                        size_t num) {
    sha256_block_data_order_nohw(state, data, num);
}
