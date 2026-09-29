/* launcher.c -- bin/<name> of an x86-64 bundle.
 *
 * Built for the baseline x86-64 ISA, so it runs on every x86-64 CPU. It
 * checks that the CPU reaches the bundle's minimum micro-architecture level
 * and refuses with one readable line when it does not, before anything of
 * the program is loaded. Otherwise it loads the program, lib<name>.so, by
 * name: its own run path ($ORIGIN/../lib) is searched, and glibc (2.33 and
 * later) looks first in the glibc-hwcaps/x86-64-v<N>/ subdirectories the CPU
 * supports. It then calls the program's C entry point, komira_main, with its
 * own argv; the environment, pid and signals are this process's.
 *
 * Exit status: the program's; 1 and the refusal line when the CPU is below
 * the minimum; 127 when the program cannot be loaded.
 *
 * Compile-time settings: KOMIRA_NAME (string), KOMIRA_MIN_LEVEL (2..4).
 * KOMIRA_TEST_CPU_HOOK builds a TEST launcher that judges the made-up CPU
 * named by $KOMIRA_TEST_CPU instead of the real one; a bundle never ships it.
 */
#include <dlfcn.h>
#include <string.h>
#include <unistd.h>

#include "cpu_level.h"
#ifdef KOMIRA_TEST_CPU_HOOK
#include <stdlib.h>
#include "cpu_models.h"
#endif

#if !defined(KOMIRA_NAME) || !defined(KOMIRA_MIN_LEVEL)
#error "KOMIRA_NAME and KOMIRA_MIN_LEVEL must be defined"
#endif
#if KOMIRA_MIN_LEVEL == 2
#define KOMIRA_MIN_TEXT "an x86-64-v2 CPU (Nehalem or newer)"
#elif KOMIRA_MIN_LEVEL == 3
#define KOMIRA_MIN_TEXT "an x86-64-v3 CPU (Haswell or newer)"
#elif KOMIRA_MIN_LEVEL == 4
#define KOMIRA_MIN_TEXT "an x86-64-v4 CPU (with AVX-512)"
#else
#error "KOMIRA_MIN_LEVEL must be 2, 3 or 4"
#endif

static void say(const char *s) {
    size_t n = strlen(s);
    while (n > 0) {
        ssize_t w = write(2, s, n);
        if (w <= 0) return;
        s += w;
        n -= (size_t)w;
    }
}

typedef int (*komira_main_fn)(int, char **);

int main(int argc, char **argv) {
    struct komira_cpu_source src = {komira_hw_cpuid, komira_hw_xcr0, 0};
#ifdef KOMIRA_TEST_CPU_HOOK
    const char *model = getenv("KOMIRA_TEST_CPU");
    if (model && *model) {
        const struct komira_cpu_model *m = komira_cpu_model_named(model);
        if (!m) {
            say("test launcher: unknown KOMIRA_TEST_CPU\n");
            return 126;
        }
        src.cpuid = komira_model_cpuid;
        src.xcr0 = komira_model_xcr0;
        src.data = m;
    }
#endif
    if (komira_x86_level(&src) < KOMIRA_MIN_LEVEL) {
        say(KOMIRA_NAME " requires " KOMIRA_MIN_TEXT "\n");
        return 1;
    }
    void *lib = dlopen("lib" KOMIRA_NAME ".so", RTLD_NOW | RTLD_GLOBAL);
    if (!lib) {
        const char *e = dlerror();
        say(KOMIRA_NAME ": cannot load its library: ");
        say(e ? e : "unknown error");
        say("\n");
        return 127;
    }
    komira_main_fn entry = (komira_main_fn)dlsym(lib, "komira_main");
    if (!entry) {
        say(KOMIRA_NAME ": lib" KOMIRA_NAME ".so has no komira_main\n");
        return 127;
    }
    return entry(argc, argv);
}
