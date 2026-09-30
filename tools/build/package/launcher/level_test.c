/* level_test.c -- komira_x86_level() against made-up CPUs.
 *
 * 1. The hand-written models in cpu_models.h.
 * 2. For each feature glibc requires for a level (komira_level_features), and
 *    each base model at or above that level: the model with just that bit
 *    cleared must get the level just under the feature's.
 * Then prints "this cpu: level N" for the CPU running it, which the callers
 * compare with glibc's own view (tools/build/tests/functional/glibc_level.sh).
 * Exit 1 on any mismatch. */
#include <stdio.h>
#include "cpu_models.h"

/* `m` with feature `f` cleared; returns 0 when `m` does not have it. */
static int komira_model_without(const struct komira_cpu_model *m, const struct komira_level_feature *f,
                                struct komira_cpu_model *out) {
    *out = *m;
    uint64_t bit = (uint64_t)1 << f->bit;
    uint32_t *w32 = f->word == W_L1_ECX   ? &out->l1_ecx
                    : f->word == W_L1_EDX ? &out->l1_edx
                    : f->word == W_L7_EBX ? &out->l7_ebx
                    : f->word == W_E1_ECX ? &out->e1_ecx
                                          : 0;
    if (w32) {
        if (!(*w32 & (uint32_t)bit)) return 0;
        *w32 &= ~(uint32_t)bit;
    } else {
        if (!(out->xcr0 & bit)) return 0;
        out->xcr0 &= ~bit;
    }
    out->want = f->level - 1;
    return 1;
}

static int judge(const struct komira_cpu_model *m) {
    struct komira_cpu_source src = {komira_model_cpuid, komira_model_xcr0, m};
    return komira_x86_level(&src);
}

int main(void) {
    int bad = 0;
    unsigned models = 0, cleared = 0;
    for (unsigned i = 0; i < KOMIRA_CPU_MODEL_COUNT; i++) {
        const struct komira_cpu_model *m = &komira_cpu_models[i];
        int got = judge(m);
        printf("%s %s: got %d want %d\n", got == m->want ? "ok " : "BAD", m->name, got, m->want);
        bad |= got != m->want;
        bad |= komira_cpu_model_named(m->name) != m; /* names are unique */
        models++;
    }
    for (unsigned i = 0; i < KOMIRA_LEVEL_FEATURE_COUNT; i++) {
        const struct komira_level_feature *f = &komira_level_features[i];
        unsigned bases = 0;
        for (unsigned b = 0; b < sizeof(komira_level_bases) / sizeof(komira_level_bases[0]); b++) {
            const struct komira_cpu_model *base = komira_cpu_model_named(komira_level_bases[b]);
            if (!base || base->want != (int)b + 1) {
                printf("BAD base %s: missing or not level %u\n", komira_level_bases[b], b + 1);
                bad = 1;
                continue;
            }
            if (base->want < f->level) continue;
            struct komira_cpu_model m;
            if (!komira_model_without(base, f, &m)) {
                /* a base that lacks the bit would make this row vacuous */
                printf("BAD %s-no-%s: the base does not have the bit\n", base->name, f->name);
                bad = 1;
                continue;
            }
            int got = judge(&m);
            printf("%s %s-no-%s: got %d want %d\n", got == m.want ? "ok " : "BAD", base->name, f->name,
                   got, m.want);
            bad |= got != m.want;
            bases++;
            cleared++;
        }
        if (bases == 0) {
            printf("BAD %s: no base model at level %d or above\n", f->name, f->level);
            bad = 1;
        }
    }
    printf("models: %u hand-written, %u with one feature cleared (%u features)\n", models, cleared,
           (unsigned)KOMIRA_LEVEL_FEATURE_COUNT);
    struct komira_cpu_source hw = {komira_hw_cpuid, komira_hw_xcr0, 0};
    printf("this cpu: level %d\n", komira_x86_level(&hw));
    return bad;
}
