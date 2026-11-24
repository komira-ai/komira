/* A C host of libkomira that sends the inputs known to end a host process
 * when nothing refuses them, written against komira.h only.
 *
 * Each input is one that reaches a stack exhaustion or an unbounded allocation
 * inside the library unless it is refused first (src/so/README.md, "What an
 * abort does to the host"): statements nested deeper than the parser's limit,
 * and lpad and rpad asked for a value of about 2^63 bytes. repeat, refused by
 * the same ceiling already, is checked beside them. Each must come back as
 * KOMIRA_ERR_ENGINE with the reason as the last error, *out as the driver
 * wrote it, and the context still answering the next query. The statements
 * nested to exactly the limit must still run, except nested scalar
 * subqueries, which the optimizer refuses by name (a status as well).
 *
 * The driver runs everything on the process's main thread, so a crash ends it
 * and the check fails. Exit 0 only if every check holds; each failure prints
 * one line. */
#include <dlfcn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "komira.h"

static int failures = 0;

#define CHECK(cond)                                                          \
    do {                                                                     \
        if (!(cond)) {                                                       \
            fprintf(stderr, "FAIL line %d: %s\n", __LINE__, #cond);          \
            failures++;                                                      \
        }                                                                    \
    } while (0)

#define DECLARE(name) static __typeof__(name) *p_##name

DECLARE(komira_ctx_new);
DECLARE(komira_ctx_free);
DECLARE(komira_last_error);
DECLARE(komira_sql_stream);

static int bind_all(void *lib) {
    int missing = 0;
#define BIND(name)                                                           \
    do {                                                                     \
        void *sym = dlsym(lib, #name);                                       \
        if (sym == NULL) {                                                   \
            fprintf(stderr, "MISSING EXPORT: %s\n", #name);                  \
            missing++;                                                       \
        }                                                                    \
        memcpy(&p_##name, &sym, sizeof sym);                                 \
    } while (0)
    BIND(komira_ctx_new);
    BIND(komira_ctx_free);
    BIND(komira_last_error);
    BIND(komira_sql_stream);
#undef BIND
    return missing;
}

/* The parser's nesting limit (src/sql, MAX_SQL_NESTING): one parenthesised
   expression, function call, IN list, prefix NOT or minus, subquery or derived
   table is one level. */
#define NESTING_LIMIT 100

/* "<head><open x n><middle><close x n>", in a buffer the caller frees. */
static char *nest(const char *head, const char *open, int n, const char *middle, const char *close) {
    size_t lo = strlen(open), lc = strlen(close);
    size_t len = strlen(head) + (size_t)n * (lo + lc) + strlen(middle);
    char *text = malloc(len + 1);
    if (text == NULL) return NULL;
    char *at = text;
    at += sprintf(at, "%s", head);
    for (int i = 0; i < n; i++) {
        memcpy(at, open, lo);
        at += lo;
    }
    at += sprintf(at, "%s", middle);
    for (int i = 0; i < n; i++) {
        memcpy(at, close, lc);
        at += lc;
    }
    *at = 0;
    return text;
}

/* The context's last error as a NUL-terminated string in `text`. */
static const char *last_error_text(komira_handle ctx, char *text, size_t cap) {
    uint64_t n = 0;
    memset(text, 0, cap);
    if (p_komira_last_error(ctx, (uint8_t *)text, cap - 1, &n) != KOMIRA_OK) return "<no last error>";
    return text;
}

/* A good query on `ctx` answers: the context survived what came before. */
static void expect_usable(komira_handle ctx, const char *after) {
    struct ArrowArrayStream out;
    memset(&out, 0, sizeof out);
    int32_t rc = p_komira_sql_stream(ctx, "SELECT 1 AS n", &out);
    if (rc != KOMIRA_OK) fprintf(stderr, "FAIL: SELECT 1 after %s returned %d\n", after, rc);
    CHECK(rc == KOMIRA_OK);
    if (rc == KOMIRA_OK) out.release(&out);
}

/* `sql` runs: KOMIRA_OK and a stream, released here. */
static void expect_runs(komira_handle ctx, const char *what, const char *sql) {
    struct ArrowArrayStream out;
    memset(&out, 0, sizeof out);
    char text[512];
    int32_t rc = sql == NULL ? KOMIRA_ERR_NULL_ARG : p_komira_sql_stream(ctx, sql, &out);
    if (rc != KOMIRA_OK) fprintf(stderr, "FAIL: %s returned %d: %s\n", what, rc, last_error_text(ctx, text, sizeof text));
    CHECK(rc == KOMIRA_OK);
    if (rc == KOMIRA_OK) {
        CHECK(out.release != NULL);
        out.release(&out);
    }
}

/* `sql` is refused with KOMIRA_ERR_ENGINE: *out untouched, the last error is
   exactly `error`, and the next query on the context answers. */
static void expect_refused(komira_handle ctx, const char *what, const char *sql, const char *error) {
    struct ArrowArrayStream out, before;
    memset(&out, 0xAB, sizeof out);
    memcpy(&before, &out, sizeof out);
    char text[512];
    int32_t rc = sql == NULL ? KOMIRA_ERR_NULL_ARG : p_komira_sql_stream(ctx, sql, &out);
    if (rc != KOMIRA_ERR_ENGINE) fprintf(stderr, "FAIL: %s returned %d, want %d\n", what, rc, KOMIRA_ERR_ENGINE);
    CHECK(rc == KOMIRA_ERR_ENGINE);
    CHECK(memcmp(&out, &before, sizeof out) == 0);
    const char *got = last_error_text(ctx, text, sizeof text);
    if (strcmp(got, error) != 0) fprintf(stderr, "FAIL: %s: last error '%s', want '%s'\n", what, got, error);
    CHECK(strcmp(got, error) == 0);
    expect_usable(ctx, what);
}

/* `sql` is refused with KOMIRA_ERR_ENGINE for a reason of its own, one that
   starts with `prefix`: *out untouched, and the next query on the context
   answers. */
static void expect_engine_refusal(komira_handle ctx, const char *what, const char *sql, const char *prefix) {
    struct ArrowArrayStream out, before;
    memset(&out, 0xAB, sizeof out);
    memcpy(&before, &out, sizeof out);
    char text[512];
    int32_t rc = sql == NULL ? KOMIRA_ERR_NULL_ARG : p_komira_sql_stream(ctx, sql, &out);
    if (rc != KOMIRA_ERR_ENGINE) fprintf(stderr, "FAIL: %s returned %d, want %d\n", what, rc, KOMIRA_ERR_ENGINE);
    CHECK(rc == KOMIRA_ERR_ENGINE);
    if (rc == KOMIRA_OK) out.release(&out);
    CHECK(rc == KOMIRA_OK || memcmp(&out, &before, sizeof out) == 0);
    const char *got = last_error_text(ctx, text, sizeof text);
    if (strncmp(got, prefix, strlen(prefix)) != 0) fprintf(stderr, "FAIL: %s: last error '%s', want '%s...'\n", what, got, prefix);
    CHECK(strncmp(got, prefix, strlen(prefix)) == 0);
    expect_usable(ctx, what);
}

/* One nested form: `open` repeated `n` times and `middle` nests `n + extra`
   levels. At the limit it runs (or, when `at_limit_refusal` is not NULL, the
   engine refuses it for that reason, which is not the nesting limit), one
   level more is refused by the parser, and a hundred times the limit is
   refused the same way. */
static void nesting_case(komira_handle ctx, const char *what, const char *head, const char *open, const char *middle,
                         const char *close, int extra, const char *at_limit_refusal) {
    char deep[128];
    snprintf(deep, sizeof deep, "parse: SQL syntax error: the statement nests deeper than %d levels", NESTING_LIMIT);
    int at_limit = NESTING_LIMIT - extra;
    char *sql = nest(head, open, at_limit, middle, close);
    if (at_limit_refusal == NULL) {
        expect_runs(ctx, what, sql);
    } else {
        expect_engine_refusal(ctx, what, sql, at_limit_refusal);
    }
    free(sql);
    sql = nest(head, open, at_limit + 1, middle, close);
    expect_refused(ctx, what, sql, deep);
    free(sql);
    sql = nest(head, open, 100 * NESTING_LIMIT, middle, close);
    expect_refused(ctx, what, sql, deep);
    free(sql);
}

int main(void) {
    void *lib = dlopen("./libkomira.so", RTLD_NOW);
    if (lib == NULL) {
        fprintf(stderr, "dlopen: %s\n", dlerror());
        return 1;
    }
    if (bind_all(lib) != 0) return 1;
    komira_handle ctx = p_komira_ctx_new();
    CHECK(ctx != NULL);
    if (ctx == NULL) return 1;

    /* Nesting: each form recursed once per level on the caller's stack. */
    nesting_case(ctx, "parentheses", "SELECT ", "(", "1", ")", 0, NULL);
    nesting_case(ctx, "NOT", "SELECT ", "NOT ", "true", "", 0, NULL);
    nesting_case(ctx, "unary minus", "SELECT ", "- ", "1", "", 0, NULL);
    nesting_case(ctx, "function calls", "SELECT ", "abs(", "1", ")", 0, NULL);
    /* The optimizer runs no scalar subquery nested in another; it refuses that
       by name, which is a status too. */
    nesting_case(ctx, "scalar subqueries", "SELECT ", "(SELECT ", "1", ")", 0, "optimize: OPTIMIZE_UNRESOLVED_SCALAR: ");
    nesting_case(ctx, "derived tables", "SELECT * FROM ", "(SELECT * FROM ", "(SELECT 1 AS n)", ")", 1, NULL);
    nesting_case(ctx, "derived tables in a UNION", "SELECT * FROM ", "(SELECT 1 AS n UNION ALL SELECT * FROM ",
                 "(SELECT 1 AS n)", ")", 1, NULL);

    /* A value far over the 64 MiB per-row ceiling: refused by its size before
       anything is allocated. */
    expect_refused(ctx, "lpad", "SELECT lpad('a', 9223372036854775807, 'x') AS s",
                   "execute: [Processor] PipelineCompiler: lpad() would produce more than 67108864 bytes for one row, over the per-row ceiling (STRING_FN_N_REPEAT_MAX_BYTES)");
    expect_refused(ctx, "rpad", "SELECT rpad('a', 9223372036854775807, 'x') AS s",
                   "execute: [Processor] PipelineCompiler: rpad() would produce more than 67108864 bytes for one row, over the per-row ceiling (STRING_FN_N_REPEAT_MAX_BYTES)");
    expect_refused(ctx, "repeat", "SELECT repeat('ab', 2147483647) AS s",
                   "execute: [Processor] PipelineCompiler: repeat() would produce 4294967294 bytes for one row, over the 67108864-byte per-row ceiling (STRING_FN_N_REPEAT_MAX_BYTES)");

    p_komira_ctx_free(ctx);
    return failures == 0 ? 0 : 1;
}
