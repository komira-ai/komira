/* variants_load: load one variant of libkomira from a native directory, as a
 * language package's loader opens it, and check where everything came from.
 *
 * usage: variants_load --dir <dir> --variant <name> --out <file>
 *                      [--host-lib <file>]... [--expect-failure <line>]
 *
 * Each --host-lib is opened first, RTLD_NOW | RTLD_GLOBAL: the C++ runtime a
 * host provides as it provides glibc (libstdc++.so.6, libgcc_s.so.1), which the
 * directory does not carry and a build worker does not have.
 *
 * It reads <dir>/VARIANTS (one line per variant: the name, the path relative
 * to <dir> and the CPU features, separated by tabs; fields after the third are
 * ignored), takes the line named <name>, and opens <dir>/<path> by absolute
 * path with RTLD_NOW | RTLD_LOCAL, with no library path: only the library's run
 * path finds what it needs. Then:
 *   - komira_abi_version() is the version komira.h states;
 *   - the libkomira the process maps is that file and no other variant;
 *   - every library the process maps whose name is a file of <dir>/lib is
 *     mapped from <dir>/lib, and libKGENCompilerRTShared.so, which every
 *     libkomira needs, is one of them.
 * <file> is written, holding `PASS <name>`, only if all of that held. With
 * --expect-failure, <file> is written only if the first failure is exactly
 * <line>, with <dir> written as `<dir>`; it is then a check that refuses.
 * Every failure is one line on stderr starting `variants_load: `. */
#define _GNU_SOURCE
#include <dirent.h>
#include <dlfcn.h>
#include <limits.h>
#include <link.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "komira.h"

static const char *g_dir;
static char g_failure[8192];

/* Records the first failure, with every occurrence of the directory written
 * `<dir>` so an expected line does not depend on where the action ran. */
static int fail_line(const char *fmt, const char *a, const char *b) {
    char raw[8192];
    snprintf(raw, sizeof raw, fmt, a ? a : "", b ? b : "");
    if (g_failure[0] != '\0') return 1;
    size_t dl = strlen(g_dir);
    size_t o = 0;
    for (const char *p = raw; *p != '\0' && o + 6 < sizeof g_failure;) {
        if (dl > 0 && strncmp(p, g_dir, dl) == 0) {
            memcpy(g_failure + o, "<dir>", 5);
            o += 5;
            p += dl;
        } else {
            g_failure[o++] = *p++;
        }
    }
    g_failure[o] = '\0';
    return 1;
}

/* Does the relative path `rel` have a segment `..`? */
static int has_dotdot_segment(const char *rel) {
    for (const char *p = rel; *p != '\0';) {
        const char *end = strchr(p, '/');
        size_t len = end ? (size_t)(end - p) : strlen(p);
        if (len == 2 && p[0] == '.' && p[1] == '.') return 1;
        if (end == NULL) break;
        p = end + 1;
    }
    return 0;
}

static const char *base_name(const char *path) {
    const char *slash = strrchr(path, '/');
    return slash ? slash + 1 : path;
}

/* The line of <dir>/VARIANTS named `want`: its path into `path`. */
static int find_variant(const char *want, char *path, size_t cap) {
    char manifest[PATH_MAX];
    snprintf(manifest, sizeof manifest, "%s/VARIANTS", g_dir);
    FILE *f = fopen(manifest, "r");
    if (f == NULL) return fail_line("variants_load: cannot read %s/VARIANTS", g_dir, NULL);
    char line[4096];
    int found = 0;
    while (fgets(line, sizeof line, f) != NULL) {
        size_t len = strlen(line);
        if (len == 0 || line[len - 1] != '\n') {
            fclose(f);
            return fail_line("variants_load: <dir>/VARIANTS: a line does not end in a newline: %s", line, NULL);
        }
        line[len - 1] = '\0';
        char *name = line;
        char *tab1 = strchr(name, '\t');
        char *tab2 = tab1 ? strchr(tab1 + 1, '\t') : NULL;
        if (tab1 == NULL || tab2 == NULL || tab1 == name || tab2 == tab1 + 1) {
            fclose(f);
            return fail_line("variants_load: <dir>/VARIANTS: a line has no name, path and features: %s", line, NULL);
        }
        *tab1 = '\0';
        *tab2 = '\0';
        const char *rel = tab1 + 1;
        if (rel[0] == '/' || has_dotdot_segment(rel)) {
            fclose(f);
            return fail_line("variants_load: <dir>/VARIANTS: variant %s has a path outside the directory: %s", name, rel);
        }
        if (strcmp(name, want) == 0) {
            snprintf(path, cap, "%s", rel);
            found = 1;
        }
    }
    fclose(f);
    if (!found) return fail_line("variants_load: <dir>/VARIANTS has no variant %s", want, NULL);
    return 0;
}

struct mapped {
    const char *want_lib; /* realpath of the variant's file */
    const char *lib_dir;  /* realpath of <dir>/lib */
    int saw_variant;
    int saw_runtime;
    int bad;
};

/* Is `name` a file of <dir>/lib? */
static int in_lib_dir(const char *lib_dir, const char *name) {
    char p[PATH_MAX];
    snprintf(p, sizeof p, "%s/%s", lib_dir, name);
    FILE *f = fopen(p, "r");
    if (f == NULL) return 0;
    fclose(f);
    return 1;
}

static int each_object(struct dl_phdr_info *info, size_t size, void *data) {
    (void)size;
    struct mapped *m = data;
    if (info->dlpi_name == NULL || info->dlpi_name[0] == '\0') return 0;
    char real[PATH_MAX];
    if (realpath(info->dlpi_name, real) == NULL) return 0;
    const char *base = base_name(real);
    if (strncmp(base, "libkomira.", strlen("libkomira.")) == 0) {
        if (strcmp(real, m->want_lib) == 0) {
            m->saw_variant = 1;
        } else {
            m->bad = fail_line("variants_load: another libkomira is mapped: %s", real, NULL);
        }
        return 0;
    }
    if (in_lib_dir(m->lib_dir, base)) {
        char dir[PATH_MAX];
        snprintf(dir, sizeof dir, "%s", real);
        char *slash = strrchr(dir, '/');
        if (slash) *slash = '\0';
        if (strcmp(dir, m->lib_dir) != 0) {
            m->bad = fail_line("variants_load: %s is mapped from %s, not from <dir>/lib", base, dir);
        } else if (strcmp(base, "libKGENCompilerRTShared.so") == 0) {
            m->saw_runtime = 1;
        }
    }
    return 0;
}

static int check(const char *variant) {
    char rel[PATH_MAX];
    if (find_variant(variant, rel, sizeof rel)) return 1;
    char full[PATH_MAX];
    snprintf(full, sizeof full, "%s/%s", g_dir, rel);
    void *lib = dlopen(full, RTLD_NOW | RTLD_LOCAL);
    if (lib == NULL) return fail_line("variants_load: cannot load %s: %s", full, dlerror());
    void *sym = dlsym(lib, "komira_abi_version");
    if (sym == NULL) return fail_line("variants_load: %s has no komira_abi_version", full, NULL);
    __typeof__(komira_abi_version) *version;
    memcpy(&version, &sym, sizeof sym);
    int32_t want = KOMIRA_ABI_VERSION_MAJOR * 1000 + KOMIRA_ABI_VERSION_MINOR;
    if (version() != want) {
        char got[32];
        snprintf(got, sizeof got, "%d", (int)version());
        return fail_line("variants_load: %s answers komira_abi_version() %s, not the header's", full, got);
    }
    char want_lib[PATH_MAX];
    char lib_dir_in[PATH_MAX];
    char lib_dir[PATH_MAX];
    snprintf(lib_dir_in, sizeof lib_dir_in, "%s/lib", g_dir);
    if (realpath(full, want_lib) == NULL || realpath(lib_dir_in, lib_dir) == NULL) {
        return fail_line("variants_load: cannot resolve %s or %s/lib", full, g_dir);
    }
    struct mapped m = {want_lib, lib_dir, 0, 0, 0};
    dl_iterate_phdr(each_object, &m);
    if (m.bad) return 1;
    if (!m.saw_variant) return fail_line("variants_load: %s is not among the mapped objects", full, NULL);
    if (!m.saw_runtime) return fail_line("variants_load: libKGENCompilerRTShared.so is not mapped from <dir>/lib", NULL, NULL);
    return 0;
}

int main(int argc, char **argv) {
    const char *variant = NULL;
    const char *out = NULL;
    const char *expect = NULL;
    const char *host_libs[8];
    int n_host = 0;
    for (int i = 1; i + 1 < argc; i += 2) {
        if (strcmp(argv[i], "--host-lib") == 0) {
            if (n_host == 8) {
                fprintf(stderr, "variants_load: more than 8 --host-lib\n");
                return 2;
            }
            host_libs[n_host++] = argv[i + 1];
        }
        else if (strcmp(argv[i], "--dir") == 0) g_dir = argv[i + 1];
        else if (strcmp(argv[i], "--variant") == 0) variant = argv[i + 1];
        else if (strcmp(argv[i], "--out") == 0) out = argv[i + 1];
        else if (strcmp(argv[i], "--expect-failure") == 0) expect = argv[i + 1];
        else {
            fprintf(stderr, "variants_load: unknown argument %s\n", argv[i]);
            return 2;
        }
    }
    if (g_dir == NULL || variant == NULL || out == NULL || argc % 2 != 1) {
        fprintf(stderr, "variants_load: usage: variants_load --dir <dir> --variant <name> --out <file> [--host-lib <file>]... [--expect-failure <line>]\n");
        return 2;
    }
    static char abs_dir[PATH_MAX];
    if (realpath(g_dir, abs_dir) == NULL) {
        fprintf(stderr, "variants_load: no directory %s\n", g_dir);
        return 2;
    }
    g_dir = abs_dir;
    for (int i = 0; i < n_host; i++) {
        if (dlopen(host_libs[i], RTLD_NOW | RTLD_GLOBAL) == NULL) {
            fprintf(stderr, "variants_load: cannot open the host library %s: %s\n", host_libs[i], dlerror());
            return 2;
        }
    }
    int failed = check(variant);
    if (failed) fprintf(stderr, "%s\n", g_failure);
    if (expect != NULL) {
        if (!failed) {
            fprintf(stderr, "variants_load: variant %s loaded, but the failure `%s` was expected\n", variant, expect);
            return 1;
        }
        if (strcmp(g_failure, expect) != 0) {
            fprintf(stderr, "variants_load: expected the failure `%s`\n", expect);
            return 1;
        }
    } else if (failed) {
        return 1;
    }
    FILE *f = fopen(out, "w");
    if (f == NULL || fprintf(f, "PASS %s\n", variant) < 0 || fclose(f) != 0) {
        fprintf(stderr, "variants_load: cannot write %s\n", out);
        return 1;
    }
    return 0;
}
