/* cpu_level.h -- the x86-64 micro-architecture level of the running CPU.
 *
 * Mirrors the rules glibc's loader applies when it chooses a
 * lib/glibc-hwcaps/x86-64-v<N>/ directory (sysdeps/x86/get-isa-level.h):
 * a level counts only if every feature it lists is present, and the AVX and
 * AVX-512 families count only if the operating system saves their register
 * state (OSXSAVE, and the matching XCR0 bits).
 *
 * The register source is a parameter, so tests can feed made-up CPUs.
 * Compile it for the baseline x86-64 ISA: it must run on every CPU it judges.
 */
#ifndef KOMIRA_CPU_LEVEL_H
#define KOMIRA_CPU_LEVEL_H

#include <stdint.h>

struct komira_cpuid {
    uint32_t eax, ebx, ecx, edx;
};

struct komira_cpu_source {
    /* cpuid(leaf, subleaf) */
    void (*cpuid)(const struct komira_cpu_source *, uint32_t, uint32_t, struct komira_cpuid *);
    /* xgetbv(0); only called when cpuid reports OSXSAVE */
    uint64_t (*xcr0)(const struct komira_cpu_source *);
    const void *data;
};

#define KOMIRA_BIT(r, n) (((r) >> (n)) & 1u)

/* 0 = not even baseline x86-64, 1 = baseline, 2..4 = x86-64-v2..v4. */
static int komira_x86_level(const struct komira_cpu_source *src) {
    struct komira_cpuid l0 = {0}, l1 = {0}, l7 = {0}, e0 = {0}, e1 = {0};
    src->cpuid(src, 0, 0, &l0);
    if (l0.eax < 1) return 0;
    src->cpuid(src, 1, 0, &l1);
    if (l0.eax >= 7) src->cpuid(src, 7, 0, &l7);
    src->cpuid(src, 0x80000000u, 0, &e0);
    if (e0.eax >= 0x80000001u) src->cpuid(src, 0x80000001u, 0, &e1);

    /* baseline: FPU CX8 CMOV MMX FXSR SSE SSE2 */
    if (!(KOMIRA_BIT(l1.edx, 0) && KOMIRA_BIT(l1.edx, 8) && KOMIRA_BIT(l1.edx, 15) &&
          KOMIRA_BIT(l1.edx, 23) && KOMIRA_BIT(l1.edx, 24) && KOMIRA_BIT(l1.edx, 25) &&
          KOMIRA_BIT(l1.edx, 26)))
        return 0;

    /* v2: SSE3 SSSE3 CMPXCHG16B SSE4_1 SSE4_2 POPCNT LAHF-SAHF */
    if (!(KOMIRA_BIT(l1.ecx, 0) && KOMIRA_BIT(l1.ecx, 9) && KOMIRA_BIT(l1.ecx, 13) &&
          KOMIRA_BIT(l1.ecx, 19) && KOMIRA_BIT(l1.ecx, 20) && KOMIRA_BIT(l1.ecx, 23) &&
          KOMIRA_BIT(e1.ecx, 0)))
        return 1;

    /* The OS saves XMM and YMM state (XCR0 bits 1 and 2). */
    uint64_t xcr0 = KOMIRA_BIT(l1.ecx, 27) ? src->xcr0(src) : 0;
    int ymm_os = (xcr0 & 0x6) == 0x6;

    /* v3: AVX AVX2 F16C FMA (usable only with YMM state), BMI1 BMI2 LZCNT MOVBE */
    if (!(ymm_os && KOMIRA_BIT(l1.ecx, 28) && KOMIRA_BIT(l7.ebx, 5) && KOMIRA_BIT(l1.ecx, 29) &&
          KOMIRA_BIT(l1.ecx, 12) && KOMIRA_BIT(l7.ebx, 3) && KOMIRA_BIT(l7.ebx, 8) &&
          KOMIRA_BIT(e1.ecx, 5) && KOMIRA_BIT(l1.ecx, 22)))
        return 2;

    /* v4: AVX512F BW CD DQ VL, with opmask and ZMM state (XCR0 bits 5, 6, 7) */
    if (!((xcr0 & 0xe6) == 0xe6 && KOMIRA_BIT(l7.ebx, 16) && KOMIRA_BIT(l7.ebx, 30) &&
          KOMIRA_BIT(l7.ebx, 28) && KOMIRA_BIT(l7.ebx, 17) && KOMIRA_BIT(l7.ebx, 31)))
        return 3;
    return 4;
}

/* The running CPU. */
static void komira_hw_cpuid(const struct komira_cpu_source *src, uint32_t leaf, uint32_t sub,
                            struct komira_cpuid *r) {
    (void)src;
    __asm__ volatile("cpuid" : "=a"(r->eax), "=b"(r->ebx), "=c"(r->ecx), "=d"(r->edx)
                     : "a"(leaf), "c"(sub));
}

static uint64_t komira_hw_xcr0(const struct komira_cpu_source *src) {
    (void)src;
    uint32_t lo, hi;
    __asm__ volatile("xgetbv" : "=a"(lo), "=d"(hi) : "c"(0));
    return ((uint64_t)hi << 32) | lo;
}

#endif
