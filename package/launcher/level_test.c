/* level_test.c -- komira_x86_level() against made-up CPUs, and the level of
 * the CPU running the test (informational). Exit 1 on any mismatch. */
#include <stdio.h>
#include "cpu_models.h"

int main(void) {
    int bad = 0;
    for (unsigned i = 0; i < KOMIRA_CPU_MODEL_COUNT; i++) {
        const struct komira_cpu_model *m = &komira_cpu_models[i];
        struct komira_cpu_source src = {komira_model_cpuid, komira_model_xcr0, m};
        int got = komira_x86_level(&src);
        printf("%s %s: got %d want %d\n", got == m->want ? "ok " : "BAD", m->name, got, m->want);
        bad |= got != m->want;
        bad |= komira_cpu_model_named(m->name) != m; /* names are unique */
    }
    struct komira_cpu_source hw = {komira_hw_cpuid, komira_hw_xcr0, 0};
    printf("this cpu: level %d\n", komira_x86_level(&hw));
    return bad;
}
