/* Includes the generated header and defines every function it declares: a
 * prototype that is not valid C, or a definition with other types than its
 * prototype, fails the compile. The version is checked at compile time. */
#include "example.h"

_Static_assert(KOMIRA_ABI_VERSION_MAJOR == 1, "major");
_Static_assert(KOMIRA_ABI_VERSION_MINOR == 1, "minor");
_Static_assert(sizeof(komira_handle) == sizeof(void *), "handle");
_Static_assert(sizeof(ptrdiff_t) == sizeof(size_t), "Int and UInt");

int32_t abi_add(int32_t a, int32_t b) { return a + b; }

int64_t abi_sum_bytes(uint8_t *data, ptrdiff_t n) {
    int64_t s = 0;
    for (ptrdiff_t i = 0; i < n; i++) s += data[i];
    return s;
}

void abi_fill(uint8_t *buf, ptrdiff_t n, uint8_t value) {
    for (ptrdiff_t i = 0; i < n; i++) buf[i] = value;
}

double abi_scale(double x, double k) { return x * k; }

int32_t abi_touch(void *handle) {
    komira_handle h = (komira_handle)handle;
    (void)h;
    return 7;
}
