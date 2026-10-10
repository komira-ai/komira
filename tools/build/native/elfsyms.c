/* elfsyms: the symbol reader of the prefixed C libraries (README.md).
 *
 * The C toolchain provides no nm or readelf (tools/build/mojo/cxx.bzl), and an
 * action may not take one from the worker, so the build reads ELF itself.
 *
 *   elfsyms armap <lib.a>    every name in the archive's symbol table (the
 *                            GNU "/" or "/SYM64/" member): the defined
 *                            non-local symbols of its members, one per line
 *   elfsyms symtab <lib.a>   every non-local symbol of every ELF member's
 *                            .symtab, one per line:
 *                            DEF|UND <bind> <type> <visibility> <name>
 *
 * Only 64-bit little-endian ELF members are read; any other member, or a
 * header pointing outside its member, is an error (exit 2), so a reader that
 * silently skips what it cannot read cannot pass a check.
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
    if (fseek(f, 0, SEEK_END) != 0) {
        perror(path);
        exit(2);
    }
    long n = ftell(f);
    if (n < 0 || fseek(f, 0, SEEK_SET) != 0) {
        perror(path);
        exit(2);
    }
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

/* One ar member: its header at b + off, its data and size. */
struct member {
    const unsigned char *hdr;
    const unsigned char *data;
    size_t size;
};

/* The member at *off (advanced past it); 0 at the end, -1 on a bad header. */
static int next_member(const unsigned char *b, size_t len, size_t *off, struct member *m) {
    if (*off + 60 > len) return 0;
    const unsigned char *h = b + *off;
    if (h[58] != '`' || h[59] != '\n') return -1;
    char sz[11];
    memcpy(sz, h + 48, 10);
    sz[10] = 0;
    char *end;
    unsigned long long size = strtoull(sz, &end, 10);
    if (end == sz || *off + 60 + size > len) return -1;
    m->hdr = h;
    m->data = h + 60;
    m->size = (size_t)size;
    *off += 60 + (size_t)size + ((size_t)size & 1);
    return 1;
}

static unsigned char *open_archive(const char *path, size_t *len) {
    unsigned char *b = slurp(path, len);
    if (*len < 8 || memcmp(b, "!<arch>\n", 8) != 0) {
        fprintf(stderr, "elfsyms: %s is not an ar archive\n", path);
        exit(2);
    }
    return b;
}

static int armap(const char *path) {
    size_t len;
    unsigned char *b = open_archive(path, &len);
    size_t off = 8;
    struct member m;
    int r;
    while ((r = next_member(b, len, &off, &m)) == 1) {
        int width = 0;
        if (memcmp(m.hdr, "/               ", 16) == 0) width = 4;
        if (memcmp(m.hdr, "/SYM64/         ", 16) == 0) width = 8;
        if (!width) continue;
        if (m.size < (size_t)width) break;
        uint64_t count = be(m.data, width);
        if (count > (m.size - width) / width) break;
        const char *names = (const char *)m.data + width + count * width;
        const char *end = (const char *)m.data + m.size;
        for (uint64_t i = 0; i < count; i++) {
            const char *z = memchr(names, 0, (size_t)(end - names));
            if (!z) {
                fprintf(stderr, "elfsyms: %s: symbol table names run past the member\n", path);
                return 2;
            }
            puts(names);
            names = z + 1;
        }
        return 0;
    }
    fprintf(stderr, "elfsyms: %s has no readable symbol table member\n", path);
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
        case STT_COMMON: return "COMMON";
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

/* The non-local symbols of one ELF object; returns how many it printed, or -1. */
static long object_symbols(const char *path, const unsigned char *o, size_t n) {
    const Elf64_Ehdr *eh = (const Elf64_Ehdr *)o;
    if (n < sizeof(*eh) || eh->e_ident[EI_CLASS] != ELFCLASS64 || eh->e_ident[EI_DATA] != ELFDATA2LSB) {
        fprintf(stderr, "elfsyms: %s: a member is not 64-bit little-endian ELF\n", path);
        return -1;
    }
    if (eh->e_shentsize != sizeof(Elf64_Shdr) || eh->e_shoff > n ||
        (size_t)eh->e_shnum * sizeof(Elf64_Shdr) > n - eh->e_shoff) {
        fprintf(stderr, "elfsyms: %s: a member's section headers lie outside it\n", path);
        return -1;
    }
    const Elf64_Shdr *sh = (const Elf64_Shdr *)(o + eh->e_shoff);
    long printed = 0;
    for (int i = 0; i < eh->e_shnum; i++) {
        if (sh[i].sh_type != SHT_SYMTAB) continue;
        const Elf64_Shdr *ss = sh[i].sh_link < eh->e_shnum ? &sh[sh[i].sh_link] : NULL;
        if (!ss || sh[i].sh_offset > n || sh[i].sh_size > n - sh[i].sh_offset || ss->sh_offset > n ||
            ss->sh_size > n - ss->sh_offset || ss->sh_size == 0 || o[ss->sh_offset + ss->sh_size - 1] != 0) {
            fprintf(stderr, "elfsyms: %s: a member's symbol table lies outside it\n", path);
            return -1;
        }
        const char *str = (const char *)o + ss->sh_offset;
        const Elf64_Sym *s = (const Elf64_Sym *)(o + sh[i].sh_offset);
        size_t count = sh[i].sh_size / sizeof(Elf64_Sym);
        for (size_t k = 1; k < count; k++) {
            int bind = ELF64_ST_BIND(s[k].st_info);
            if (bind == STB_LOCAL) continue;
            if (s[k].st_name >= ss->sh_size) {
                fprintf(stderr, "elfsyms: %s: a symbol name lies outside its string table\n", path);
                return -1;
            }
            printf("%s %s %s %s %s\n", s[k].st_shndx == SHN_UNDEF ? "UND" : "DEF", bind_name(bind),
                   type_name(ELF64_ST_TYPE(s[k].st_info)), vis_name(ELF64_ST_VISIBILITY(s[k].st_other)),
                   str + s[k].st_name);
            printed++;
        }
    }
    return printed;
}

static int symtab(const char *path) {
    size_t len;
    unsigned char *b = open_archive(path, &len);
    size_t off = 8;
    struct member m;
    int r;
    long objects = 0;
    while ((r = next_member(b, len, &off, &m)) == 1) {
        /* The symbol table ("/", "/SYM64/") and long-name ("//") members. */
        if (m.hdr[0] == '/' && (m.hdr[1] == ' ' || m.hdr[1] == '/' || memcmp(m.hdr, "/SYM64/", 7) == 0)) continue;
        if (m.size < SELFMAG || memcmp(m.data, ELFMAG, SELFMAG) != 0) {
            fprintf(stderr, "elfsyms: %s: a member is not an ELF object\n", path);
            return 2;
        }
        if (object_symbols(path, m.data, m.size) < 0) return 2;
        objects++;
    }
    if (r < 0) {
        fprintf(stderr, "elfsyms: %s: a member header is malformed\n", path);
        return 2;
    }
    if (objects == 0) {
        fprintf(stderr, "elfsyms: %s holds no object\n", path);
        return 2;
    }
    return 0;
}

int main(int argc, char **argv) {
    if (argc == 3 && strcmp(argv[1], "armap") == 0) return armap(argv[2]);
    if (argc == 3 && strcmp(argv[1], "symtab") == 0) return symtab(argv[2]);
    fprintf(stderr, "usage: elfsyms armap <lib.a> | elfsyms symtab <lib.a>\n");
    return 2;
}
