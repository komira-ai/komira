#include "add.h"

/* On x86-64 the C toolchain compiles for x86-64-v2, the floor of the
 * linux-x86_64 row's isa_variants (tools/build/platforms/table.bzl): every CPU
 * level of libkomira links the same C, so no C object may need more. SSE4.2 is
 * x86-64-v2 and AVX2 is x86-64-v3, so this compiles only at exactly that
 * floor's feature set of the two. Another CPU (a macOS arm64 target compiles at
 * zig's generic arm64) has no such level and asserts nothing. */
#if defined(__x86_64__)
#ifndef __SSE4_2__
#error "compiled without SSE4.2: the C toolchain's target_cpu (x86-64-v2) was not applied"
#endif
#ifdef __AVX2__
#error "compiled with AVX2: the C toolchain must compile for x86-64-v2, the lowest CPU level libkomira ships"
#endif
#endif

int komira_example_add(int a, int b) { return a + b; }
