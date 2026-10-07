/* callsites: the external_call names of Mojo sources, read by tokenizing them
 * (README.md, "One shared library").
 *
 *   callsites <file.mojo>...   every name N of a call `external_call["N", ...]`,
 *                              one per line, in order of appearance
 *
 * This is the second reader of the call sites, written to share nothing with
 * native_exports.sh's (a line-oriented awk scan): it lexes Mojo the way the
 * compiler sees it, into identifiers, string literals and punctuation, with
 * `#` comments and triple-quoted strings (docstrings) dropped, and prints the
 * string after each `external_call` `[` token pair, wherever the line breaks
 * fall. native_callsite_check.sh holds the library's exports to it.
 *
 * An unterminated string or docstring, or a file it cannot read, is an error
 * (exit 2): a reader that silently skips what it cannot read cannot pass a check.
 */
#include <ctype.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

enum kind { IDENT, STRING, PUNCT };

/* The last three tokens: an `external_call` `[` STRING run is a call site. */
struct tok {
    enum kind kind;
    char text[256];
    int too_long;
};

static struct tok window[3];
static int seen;

static void push(enum kind kind, const char *s, size_t n) {
    window[0] = window[1];
    window[1] = window[2];
    window[2].kind = kind;
    window[2].too_long = n >= sizeof(window[2].text);
    if (window[2].too_long) n = sizeof(window[2].text) - 1;
    memcpy(window[2].text, s, n);
    window[2].text[n] = 0;
    if (seen < 3) seen++;
    if (seen == 3 && window[0].kind == IDENT && strcmp(window[0].text, "external_call") == 0 &&
        window[1].kind == PUNCT && window[1].text[0] == '[' && window[2].kind == STRING && !window[2].too_long) {
        const char *t = window[2].text;
        int ok = (isalpha((unsigned char)t[0]) || t[0] == '_');
        for (const char *p = t; ok && *p; p++) ok = isalnum((unsigned char)*p) || *p == '_';
        if (ok) puts(t);
    }
}

static int scan(const char *path) {
    FILE *f = fopen(path, "rb");
    if (!f) {
        perror(path);
        return 2;
    }
    size_t cap = 1 << 16, n = 0;
    char *b = malloc(cap);
    size_t r;
    while (b && (r = fread(b + n, 1, cap - n, f)) > 0) {
        n += r;
        if (n == cap) b = realloc(b, cap *= 2);
    }
    fclose(f);
    if (!b) {
        fprintf(stderr, "callsites: out of memory reading %s\n", path);
        return 2;
    }
    seen = 0;
    size_t i = 0;
    while (i < n) {
        char c = b[i];
        if (c == '#') {
            while (i < n && b[i] != '\n') i++;
        } else if ((c == '"' || c == '\'') && i + 2 < n && b[i + 1] == c && b[i + 2] == c) {
            /* A triple-quoted string (a docstring): not code, dropped. */
            size_t j = i + 3;
            while (j + 2 < n && !(b[j] == c && b[j + 1] == c && b[j + 2] == c)) j += (b[j] == '\\') ? 2 : 1;
            if (j + 2 >= n) {
                fprintf(stderr, "callsites: %s: an unterminated triple-quoted string\n", path);
                free(b);
                return 2;
            }
            i = j + 3;
        } else if (c == '"' || c == '\'') {
            size_t j = i + 1;
            while (j < n && b[j] != c && b[j] != '\n') j += (b[j] == '\\') ? 2 : 1;
            if (j >= n || b[j] != c) {
                fprintf(stderr, "callsites: %s: an unterminated string\n", path);
                free(b);
                return 2;
            }
            push(STRING, b + i + 1, j - i - 1);
            i = j + 1;
        } else if (isalpha((unsigned char)c) || c == '_') {
            size_t j = i;
            while (j < n && (isalnum((unsigned char)b[j]) || b[j] == '_')) j++;
            push(IDENT, b + i, j - i);
            i = j;
        } else if (isspace((unsigned char)c)) {
            i++;
        } else {
            push(PUNCT, b + i, 1);
            i++;
        }
    }
    free(b);
    return 0;
}

int main(int argc, char **argv) {
    if (argc < 2) {
        fprintf(stderr, "usage: callsites <file.mojo>...\n");
        return 2;
    }
    for (int k = 1; k < argc; k++) {
        int rc = scan(argv[k]);
        if (rc) return rc;
    }
    return 0;
}
