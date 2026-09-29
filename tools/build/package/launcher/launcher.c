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
 * Exit status: the program's; 126 and the refusal line when the CPU is below
 * the minimum (126, not 1, so a supervisor can tell "wrong CPU" from "the
 * program failed"); 127 when the program cannot be loaded. The program's own
 * status may of course also be 126 or 127; a caller that must tell them apart
 * reads the message on stderr.
 *
 * lib<name>.so is found through the run path, so LD_LIBRARY_PATH, which glibc
 * searches first, can put another file of that name (or of a runtime library)
 * in its place. That is how RUNPATH works and it is accepted.
 *
 * Compile-time settings: KOMIRA_NAME (string), KOMIRA_MIN_LEVEL (2..4).
 * KOMIRA_TEST_CPU_HOOK builds a TEST launcher that judges the made-up CPU
 * named by $KOMIRA_TEST_CPU instead of the real one; a bundle never ships it.
 */
#include <dlfcn.h>
#include <limits.h>
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
#define KOMIRA_STR2(x) #x
#define KOMIRA_STR(x) KOMIRA_STR2(x)
#define KOMIRA_LEVEL_DIR "x86-64-v" KOMIRA_STR(KOMIRA_MIN_LEVEL)
#define KOMIRA_REFUSED 126

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

/* After a failed dlopen: is the library in the bundle, in the directory of
 * its level? Then the file is there but the loader did not search that
 * directory, which means it does not accept the level the launcher found. */
static int library_in_bundle(void) {
    static const char rel[] = "/../lib/glibc-hwcaps/" KOMIRA_LEVEL_DIR "/lib" KOMIRA_NAME ".so";
    char path[PATH_MAX];
    ssize_t n = readlink("/proc/self/exe", path, sizeof(path) - sizeof(rel));
    if (n <= 0) return 0;
    path[n] = 0;
    char *slash = strrchr(path, '/');
    if (!slash) return 0;
    memcpy(slash, rel, sizeof(rel));
    return access(path, R_OK) == 0;
}

int main(int argc, char **argv) {
    struct komira_cpu_source src = {komira_hw_cpuid, komira_hw_xcr0, 0};
#ifdef KOMIRA_TEST_CPU_HOOK
    const char *model = getenv("KOMIRA_TEST_CPU");
    if (model && *model) {
        const struct komira_cpu_model *m = komira_cpu_model_named(model);
        if (!m) {
            say("test launcher: unknown KOMIRA_TEST_CPU\n");
            return 2;
        }
        src.cpuid = komira_model_cpuid;
        src.xcr0 = komira_model_xcr0;
        src.data = m;
    }
#endif
    if (komira_x86_level(&src) < KOMIRA_MIN_LEVEL) {
        say(KOMIRA_NAME " requires " KOMIRA_MIN_TEXT "\n");
        return KOMIRA_REFUSED;
    }
    void *lib = dlopen("lib" KOMIRA_NAME ".so", RTLD_NOW | RTLD_GLOBAL);
    if (!lib) {
        const char *e = dlerror();
        say(KOMIRA_NAME ": cannot load its library: ");
        say(e ? e : "unknown error");
        say("\n");
        if (library_in_bundle())
            say(KOMIRA_NAME ": lib" KOMIRA_NAME ".so is present only for " KOMIRA_LEVEL_DIR
                            " and the system loader did not accept that level (glibc older than"
                            " 2.33, or hwcaps masked by GLIBC_TUNABLES or --glibc-hwcaps-mask)\n");
        return 127;
    }
    komira_main_fn entry = (komira_main_fn)dlsym(lib, "komira_main");
    if (!entry) {
        say(KOMIRA_NAME ": lib" KOMIRA_NAME ".so has no komira_main\n");
        return 127;
    }
    return entry(argc, argv);
}
