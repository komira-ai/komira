/* cpu_models.h -- made-up CPUs, for tests only. Never included by a
 * release launcher.
 *
 * Each model lists the cpuid words komira_x86_level() reads, XCR0, and the
 * level glibc would assign it.
 */
#ifndef KOMIRA_CPU_MODELS_H
#define KOMIRA_CPU_MODELS_H

#include <string.h>
#include "cpu_level.h"

struct komira_cpu_model {
    const char *name;
    uint32_t max_leaf, l1_ecx, l1_edx, l7_ebx, e1_ecx;
    uint64_t xcr0;
    int want;
};

#define M_BASE_EDX 0x07808101u /* FPU CX8 CMOV MMX FXSR SSE SSE2 */
#define M_V2_ECX 0x009C2201u   /* SSE3 SSSE3 CX16 SSE4_1 SSE4_2 POPCNT */
#define M_V3_ECX 0x38401000u   /* FMA MOVBE OSXSAVE AVX F16C */
#define M_V3_L7 0x00000128u    /* BMI1 AVX2 BMI2 */
#define M_V4_L7 0xD0030000u    /* AVX512F DQ CD BW VL */

static const struct komira_cpu_model komira_cpu_models[] = {
    {"qemu64", 13, 0x00802001u, M_BASE_EDX, 0, 0x1, 0, 1},
    {"nehalem", 11, M_V2_ECX, M_BASE_EDX, 0, 0x1, 0, 2},
    {"nehalem-no-lahf", 11, M_V2_ECX, M_BASE_EDX, 0, 0x0, 0, 1},
    {"nehalem-no-popcnt", 11, M_V2_ECX & ~(1u << 23), M_BASE_EDX, 0, 0x1, 0, 1},
    {"haswell", 13, M_V2_ECX | M_V3_ECX, M_BASE_EDX, M_V3_L7, 0x21, 0x7, 3},
    {"haswell-no-osxsave", 13, (M_V2_ECX | M_V3_ECX) & ~(1u << 27), M_BASE_EDX, M_V3_L7, 0x21, 0x7, 2},
    {"haswell-ymm-off", 13, M_V2_ECX | M_V3_ECX, M_BASE_EDX, M_V3_L7, 0x21, 0x3, 2},
    {"haswell-no-lzcnt", 13, M_V2_ECX | M_V3_ECX, M_BASE_EDX, M_V3_L7, 0x01, 0x7, 2},
    {"haswell-max-leaf-6", 6, M_V2_ECX | M_V3_ECX, M_BASE_EDX, M_V3_L7, 0x21, 0x7, 2},
    {"skylake-x", 22, M_V2_ECX | M_V3_ECX, M_BASE_EDX, M_V3_L7 | M_V4_L7, 0x21, 0xe7, 4},
    {"skylake-x-zmm-off", 22, M_V2_ECX | M_V3_ECX, M_BASE_EDX, M_V3_L7 | M_V4_L7, 0x21, 0x7, 3},
    {"avx512-no-vl", 22, M_V2_ECX | M_V3_ECX, M_BASE_EDX, (M_V3_L7 | M_V4_L7) & ~(1u << 31), 0x21, 0xe7, 3},
    {"no-sse2", 13, 0, M_BASE_EDX & ~(1u << 26), 0, 0, 0, 0},
};

#define KOMIRA_CPU_MODEL_COUNT (sizeof(komira_cpu_models) / sizeof(komira_cpu_models[0]))

static void komira_model_cpuid(const struct komira_cpu_source *src, uint32_t leaf, uint32_t sub,
                               struct komira_cpuid *r) {
    const struct komira_cpu_model *m = (const struct komira_cpu_model *)src->data;
    (void)sub;
    r->eax = r->ebx = r->ecx = r->edx = 0;
    if (leaf == 0) {
        r->eax = m->max_leaf;
    } else if (leaf == 1) {
        r->ecx = m->l1_ecx;
        r->edx = m->l1_edx;
    } else if (leaf == 7) {
        if (m->max_leaf >= 7) r->ebx = m->l7_ebx;
    } else if (leaf == 0x80000000u) {
        r->eax = 0x80000008u;
    } else if (leaf == 0x80000001u) {
        r->ecx = m->e1_ecx;
    }
}

static uint64_t komira_model_xcr0(const struct komira_cpu_source *src) {
    return ((const struct komira_cpu_model *)src->data)->xcr0;
}

static const struct komira_cpu_model *komira_cpu_model_named(const char *name) {
    for (unsigned i = 0; i < KOMIRA_CPU_MODEL_COUNT; i++)
        if (strcmp(komira_cpu_models[i].name, name) == 0) return &komira_cpu_models[i];
    return 0;
}

#endif
