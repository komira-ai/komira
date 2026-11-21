/* A C caller of libkomira's native directory (`//src/so:libkomira[dist]`),
 * the directory every language package carries as it is.
 *
 *   dist_load --dir <dir> [--host-lib <lib>]... --out <marker>
 *             [--expect-failure <line>]
 *
 * In order:
 *
 * - no library path is set: LD_LIBRARY_PATH and LD_PRELOAD are unset or empty;
 * - each --host-lib is opened by path with RTLD_GLOBAL: the C++ runtime
 *   (libstdc++, libgcc_s) a user's system provides and a build worker does
 *   not;
 * - <dir>/libkomira.so is opened with RTLD_NOW | RTLD_LOCAL, and nothing else
 *   is named: the loader finds the native owners and the Mojo runtime through
 *   the library's own run path;
 * - komira_abi_version() is the version komira.h states;
 * - the process maps libkomira.so from <dir>, and every native owner
 *   (libkomira_*) and each of the three Mojo runtime libraries from <dir>/lib,
 *   and none of them from anywhere else.
 *
 * The first check that fails is one line, `dist_load: <reason>`, with the
 * directory written `<dir>`. Without --expect-failure, the run passes when no
 * check fails; with it, only when the first failure is exactly that line. A
 * pass writes `PASS` to <marker> and exits 0; anything else exits 1 and writes
 * no marker. */
#define _GNU_SOURCE
#include <dlfcn.h>
#include <limits.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "komira.h"

#define MAX_HOST_LIBS 8

/* The Mojo runtime libraries: libkomira needs the first, which needs the
 * other two. */
static const char *const RUNTIME[] = {
    "libKGENCompilerRTShared.so",
    "libAsyncRTRuntimeGlobals.so",
    "libMSupportGlobals.so",
};

static char failure[4096];
static char dir_real[PATH_MAX];

/* Records the first failure only, with every spelling of the directory
 * replaced by `<dir>`. */
static void fail(const char *dir, const char *fmt, ...) __attribute__((format(printf, 2, 3)));

static void fail(const char *dir, const char *fmt, ...) {
    if (failure[0] != '\0') return;
    char raw[4096];
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(raw, sizeof raw, fmt, ap);
    va_end(ap);
    const char *spellings[2] = {dir_real, dir};
    size_t out = 0;
    const char *p = raw;
    while (*p != '\0' && out + 1 < sizeof failure) {
        int replaced = 0;
        for (int i = 0; i < 2; i++) {
            size_t n = strlen(spellings[i]);
            if (n > 0 && strncmp(p, spellings[i], n) == 0) {
                const char *token = "<dir>";
                size_t t = strlen(token);
                if (out + t + 1 >= sizeof failure) break;
                memcpy(failure + out, token, t);
                out += t;
                p += n;
                replaced = 1;
                break;
            }
        }
        if (!replaced) failure[out++] = *p++;
    }
    failure[out] = '\0';
}

static const char *base_name(const char *path) {
    const char *slash = strrchr(path, '/');
    return slash == NULL ? path : slash + 1;
}

/* Whether `path` is a file directly in `dir`. */
static int directly_in(const char *path, const char *dir) {
    size_t n = strlen(dir);
    return strncmp(path, dir, n) == 0 && path[n] == '/' && strchr(path + n + 1, '/') == NULL;
}

/* Holds every mapping of a file named `name`, or (with `prefix` set) of every
 * file whose name starts with `name`, to the directory `want`; at least one
 * must be mapped. */
static void check_mapped(const char *dir, const char *name, int prefix, const char *want) {
    FILE *maps = fopen("/proc/self/maps", "r");
    if (maps == NULL) {
        fail(dir, "dist_load: cannot read /proc/self/maps");
        return;
    }
    char line[PATH_MAX + 256];
    int seen = 0;
    while (fgets(line, sizeof line, maps) != NULL) {
        char *path = strchr(line, '/');
        if (path == NULL) continue;
        path[strcspn(path, "\n")] = '\0';
        const char *b = base_name(path);
        int match = prefix ? strncmp(b, name, strlen(name)) == 0 : strcmp(b, name) == 0;
        if (!match) continue;
        seen = 1;
        if (!directly_in(path, want)) fail(dir, "dist_load: %s is mapped from %s, not from %s", b, path, want);
    }
    fclose(maps);
    if (!seen) fail(dir, "dist_load: no %s%s is mapped", name, prefix ? "*" : "");
}

static void run(const char *dir, const char *const *host_libs, int n_host) {
    const char *vars[2] = {"LD_LIBRARY_PATH", "LD_PRELOAD"};
    for (int i = 0; i < 2; i++) {
        const char *v = getenv(vars[i]);
        if (v != NULL && v[0] != '\0') {
            fail(dir, "dist_load: %s is set: %s", vars[i], v);
            return;
        }
    }
    for (int i = 0; i < n_host; i++) {
        if (dlopen(host_libs[i], RTLD_NOW | RTLD_GLOBAL) == NULL) {
            fail(dir, "dist_load: cannot open the host library %s: %s", host_libs[i], dlerror());
            return;
        }
    }
    if (realpath(dir, dir_real) == NULL) {
        fail(dir, "dist_load: %s is not a directory", dir);
        return;
    }
    char lib[PATH_MAX];
    snprintf(lib, sizeof lib, "%s/libkomira.so", dir_real);
    void *h = dlopen(lib, RTLD_NOW | RTLD_LOCAL);
    if (h == NULL) {
        fail(dir, "dist_load: cannot load %s: %s", lib, dlerror());
        return;
    }
    void *sym = dlsym(h, "komira_abi_version");
    if (sym == NULL) {
        fail(dir, "dist_load: %s has no komira_abi_version", lib);
        return;
    }
    __typeof__(komira_abi_version) *abi_version;
    memcpy(&abi_version, &sym, sizeof sym);
    int32_t got = abi_version();
    int32_t want = KOMIRA_ABI_VERSION_MAJOR * 1000 + KOMIRA_ABI_VERSION_MINOR;
    if (got != want) {
        fail(dir, "dist_load: komira_abi_version() is %d, komira.h says %d", (int)got, (int)want);
        return;
    }
    char lib_dir[PATH_MAX];
    snprintf(lib_dir, sizeof lib_dir, "%s/lib", dir_real);
    check_mapped(dir, "libkomira.so", 0, dir_real);
    check_mapped(dir, "libkomira_", 1, lib_dir);
    for (size_t i = 0; i < sizeof RUNTIME / sizeof RUNTIME[0]; i++) check_mapped(dir, RUNTIME[i], 0, lib_dir);
}

static int usage(const char *msg) {
    fprintf(stderr, "dist_load: %s\n", msg);
    return 2;
}

int main(int argc, char **argv) {
    const char *dir = NULL, *out = NULL, *expect = NULL;
    const char *host_libs[MAX_HOST_LIBS];
    int n_host = 0;
    for (int i = 1; i < argc; i += 2) {
        if (i + 1 >= argc) return usage("every flag needs a value");
        const char *flag = argv[i], *value = argv[i + 1];
        if (strcmp(flag, "--dir") == 0) {
            dir = value;
        } else if (strcmp(flag, "--out") == 0) {
            out = value;
        } else if (strcmp(flag, "--expect-failure") == 0) {
            expect = value;
        } else if (strcmp(flag, "--host-lib") == 0) {
            if (n_host == MAX_HOST_LIBS) return usage("too many --host-lib");
            host_libs[n_host++] = value;
        } else {
            return usage("unknown flag");
        }
    }
    if (dir == NULL || out == NULL) return usage("--dir and --out are required");

    run(dir, host_libs, n_host);

    if (expect == NULL && failure[0] != '\0') {
        fprintf(stderr, "%s\n", failure);
        return 1;
    }
    if (expect != NULL && failure[0] == '\0') {
        fprintf(stderr, "dist_load: was expected to fail with '%s', and it passed\n", expect);
        return 1;
    }
    if (expect != NULL && strcmp(failure, expect) != 0) {
        fprintf(stderr, "dist_load: was expected to fail with '%s', it failed with '%s'\n", expect, failure);
        return 1;
    }
    FILE *f = fopen(out, "w");
    if (f == NULL || fputs("PASS\n", f) < 0 || fclose(f) != 0) {
        fprintf(stderr, "dist_load: cannot write %s\n", out);
        return 1;
    }
    if (expect != NULL) {
        printf("dist_load: PASS (failed as expected: %s)\n", expect);
    } else {
        printf("dist_load: PASS\n");
    }
    return 0;
}
