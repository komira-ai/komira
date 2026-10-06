/* elfsyms: the probe's nm/readelf (EXPERIMENT, never merged; see BUCK).
 *
 * The C toolchain provides no nm or readelf (tools/build/mojo/cxx.bzl), and
 * an action may not take one from the worker, so the probe reads ELF itself.
 *
 *   elfsyms armap <lib.a>   every name in the archive's symbol table (the
 *                           GNU "/" or "/SYM64/" member): the defined
 *                           non-local symbols of its members, one per line
 *   elfsyms dynsym <x.so>   the dynamic section (SONAME, NEEDED, RUNPATH,
 *                           RPATH, FLAGS) and every dynamic symbol:
 *                           DEF|UND <bind> <type> <visibility> <name>
 */
#include <elf.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static unsigned char *slurp(const char *path, size_t *len) {
    FILE *f = fopen(path, "rb");
    if (!f) {
        perror(path);
        exit(2);
    }
    fseek(f, 0, SEEK_END);
    long n = ftell(f);
    fseek(f, 0, SEEK_SET);
    unsigned char *buf = malloc((size_t)n + 1);
    if (!buf || fread(buf, 1, (size_t)n, f) != (size_t)n) {
        fprintf(stderr, "elfsyms: cannot read %s\n", path);
        exit(2);
    }
    fclose(f);
    buf[n] = 0;
    *len = (size_t)n;
    return buf;
}

static uint64_t be(const unsigned char *p, int width) {
    uint64_t v = 0;
    for (int i = 0; i < width; i++) v = (v << 8) | p[i];
    return v;
}

static int armap(const char *path) {
    size_t len;
    unsigned char *b = slurp(path, &len);
    if (len < 8 || memcmp(b, "!<arch>\n", 8) != 0) {
        fprintf(stderr, "elfsyms: %s is not an ar archive\n", path);
        return 2;
    }
    size_t off = 8;
    while (off + 60 <= len) {
        const unsigned char *h = b + off;
        char sz[11];
        memcpy(sz, h + 48, 10);
        sz[10] = 0;
        size_t msize = (size_t)strtoull(sz, NULL, 10);
        const unsigned char *m = h + 60;
        int width = 0;
        if (memcmp(h, "/               ", 16) == 0) width = 4;
        if (memcmp(h, "/SYM64/         ", 16) == 0) width = 8;
        if (width) {
            uint64_t count = be(m, width);
            const char *names = (const char *)m + width + count * width;
            const char *end = (const char *)m + msize;
            for (uint64_t i = 0; i < count && names < end; i++) {
                puts(names);
                names += strlen(names) + 1;
            }
            return 0;
        }
        off += 60 + msize + (msize & 1);
    }
    fprintf(stderr, "elfsyms: %s has no symbol table member\n", path);
    return 2;
}

static const char *bind_name(int b) {
    switch (b) {
        case STB_LOCAL: return "LOCAL";
        case STB_GLOBAL: return "GLOBAL";
        case STB_WEAK: return "WEAK";
        case STB_GNU_UNIQUE: return "UNIQUE";
        default: return "BIND?";
    }
}

static const char *type_name(int t) {
    switch (t) {
        case STT_NOTYPE: return "NOTYPE";
        case STT_OBJECT: return "OBJECT";
        case STT_FUNC: return "FUNC";
        case STT_SECTION: return "SECTION";
        case STT_FILE: return "FILE";
        case STT_TLS: return "TLS";
        case STT_GNU_IFUNC: return "IFUNC";
        default: return "TYPE?";
    }
}

static const char *vis_name(int v) {
    switch (v) {
        case STV_DEFAULT: return "DEFAULT";
        case STV_INTERNAL: return "INTERNAL";
        case STV_HIDDEN: return "HIDDEN";
        case STV_PROTECTED: return "PROTECTED";
        default: return "VIS?";
    }
}

static int dynsym(const char *path) {
    size_t len;
    unsigned char *b = slurp(path, &len);
    Elf64_Ehdr *eh = (Elf64_Ehdr *)b;
    if (len < sizeof(*eh) || memcmp(eh->e_ident, ELFMAG, SELFMAG) != 0 || eh->e_ident[EI_CLASS] != ELFCLASS64) {
        fprintf(stderr, "elfsyms: %s is not a 64-bit ELF file\n", path);
        return 2;
    }
    Elf64_Shdr *sh = (Elf64_Shdr *)(b + eh->e_shoff);
    int found = 0;
    for (int i = 0; i < eh->e_shnum; i++) {
        if (sh[i].sh_type == SHT_DYNAMIC) {
            const char *str = (const char *)b + sh[sh[i].sh_link].sh_offset;
            Elf64_Dyn *d = (Elf64_Dyn *)(b + sh[i].sh_offset);
            for (; d->d_tag != DT_NULL; d++) {
                switch (d->d_tag) {
                    case DT_SONAME: printf("SONAME %s\n", str + d->d_un.d_val); break;
                    case DT_NEEDED: printf("NEEDED %s\n", str + d->d_un.d_val); break;
                    case DT_RUNPATH: printf("RUNPATH %s\n", str + d->d_un.d_val); break;
                    case DT_RPATH: printf("RPATH %s\n", str + d->d_un.d_val); break;
                    case DT_SYMBOLIC: printf("SYMBOLIC\n"); break;
                    case DT_FLAGS: printf("FLAGS 0x%llx%s\n", (unsigned long long)d->d_un.d_val,
                                          (d->d_un.d_val & DF_SYMBOLIC) ? " (DF_SYMBOLIC)" : ""); break;
                    default: break;
                }
            }
        }
    }
    for (int i = 0; i < eh->e_shnum; i++) {
        if (sh[i].sh_type != SHT_DYNSYM) continue;
        found = 1;
        const char *str = (const char *)b + sh[sh[i].sh_link].sh_offset;
        Elf64_Sym *s = (Elf64_Sym *)(b + sh[i].sh_offset);
        size_t n = sh[i].sh_size / sizeof(Elf64_Sym);
        for (size_t k = 1; k < n; k++) {
            printf("%s %s %s %s %s\n", s[k].st_shndx == SHN_UNDEF ? "UND" : "DEF",
                   bind_name(ELF64_ST_BIND(s[k].st_info)), type_name(ELF64_ST_TYPE(s[k].st_info)),
                   vis_name(ELF64_ST_VISIBILITY(s[k].st_other)), str + s[k].st_name);
        }
    }
    if (!found) {
        fprintf(stderr, "elfsyms: %s has no dynamic symbol table\n", path);
        return 2;
    }
    return 0;
}

int main(int argc, char **argv) {
    if (argc == 3 && strcmp(argv[1], "armap") == 0) return armap(argv[2]);
    if (argc == 3 && strcmp(argv[1], "dynsym") == 0) return dynsym(argv[2]);
    fprintf(stderr, "usage: elfsyms armap <lib.a> | elfsyms dynsym <x.so>\n");
    return 2;
}
