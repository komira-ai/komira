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

/* Every feature glibc requires for a level, one row each, written from
 * glibc's sysdeps/x86/get-isa-level.h and NOT from cpu_level.h, so that a
 * check dropped from komira_x86_level() is caught: the level test clears each
 * row's bit, alone, in every model below at or above the row's level, and
 * wants the level just under the row's. */
enum komira_word { W_L1_ECX, W_L1_EDX, W_L7_EBX, W_E1_ECX, W_XCR0 };

struct komira_level_feature {
    const char *name;
    enum komira_word word;
    unsigned bit;
    int level;
};

static const struct komira_level_feature komira_level_features[] = {
    /* baseline */
    {"FPU", W_L1_EDX, 0, 1},
    {"CX8", W_L1_EDX, 8, 1},
    {"CMOV", W_L1_EDX, 15, 1},
    {"MMX", W_L1_EDX, 23, 1},
    {"FXSR", W_L1_EDX, 24, 1},
    {"SSE", W_L1_EDX, 25, 1},
    {"SSE2", W_L1_EDX, 26, 1},
    /* x86-64-v2 */
    {"SSE3", W_L1_ECX, 0, 2},
    {"SSSE3", W_L1_ECX, 9, 2},
    {"CMPXCHG16B", W_L1_ECX, 13, 2},
    {"SSE4_1", W_L1_ECX, 19, 2},
    {"SSE4_2", W_L1_ECX, 20, 2},
    {"POPCNT", W_L1_ECX, 23, 2},
    {"LAHF64_SAHF64", W_E1_ECX, 0, 2},
    /* x86-64-v3; AVX, AVX2, F16C and FMA are usable only with YMM state */
    {"OSXSAVE", W_L1_ECX, 27, 3},
    {"XCR0.SSE", W_XCR0, 1, 3},
    {"XCR0.AVX", W_XCR0, 2, 3},
    {"AVX", W_L1_ECX, 28, 3},
    {"AVX2", W_L7_EBX, 5, 3},
    {"F16C", W_L1_ECX, 29, 3},
    {"FMA", W_L1_ECX, 12, 3},
    {"BMI1", W_L7_EBX, 3, 3},
    {"BMI2", W_L7_EBX, 8, 3},
    {"LZCNT", W_E1_ECX, 5, 3},
    {"MOVBE", W_L1_ECX, 22, 3},
    /* x86-64-v4; usable only with opmask and ZMM state */
    {"XCR0.OPMASK", W_XCR0, 5, 4},
    {"XCR0.ZMM_Hi256", W_XCR0, 6, 4},
    {"XCR0.Hi16_ZMM", W_XCR0, 7, 4},
    {"AVX512F", W_L7_EBX, 16, 4},
    {"AVX512BW", W_L7_EBX, 30, 4},
    {"AVX512CD", W_L7_EBX, 28, 4},
    {"AVX512DQ", W_L7_EBX, 17, 4},
    {"AVX512VL", W_L7_EBX, 31, 4},
};

#define KOMIRA_LEVEL_FEATURE_COUNT (sizeof(komira_level_features) / sizeof(komira_level_features[0]))

/* One model of each level, the ones rows are cleared from. */
static const char *const komira_level_bases[] = {"qemu64", "nehalem", "haswell", "skylake-x"};


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
