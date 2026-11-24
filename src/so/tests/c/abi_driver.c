/* A C host of libkomira, written against komira.h only.
 *
 * It opens ./libkomira.so with RTLD_NOW and binds every function the header
 * declares to the symbol of that name. Each pointer is declared with the type
 * of the header's prototype (`__typeof__`), so the calls below are compiled
 * against the header and run against the binary. A header whose version, status
 * codes or argument types differ from the library's fails here.
 *
 * It also runs SQL through komira_sql_stream and reads each answer through the
 * struct ArrowArrayStream the header defines, as an Arrow consumer would: the
 * schema, every chunk until the end of the stream, the stream released before
 * its chunks are read, and each release checked to null its own slot. The
 * inputs are two_columns.parquet, staged beside the driver (an int64 column
 * `i64` and a string column `s`, no row), and files it writes under
 * $TEST_TMPDIR.
 *
 * Then it creates contexts with komira_ctx_new_with_options: a memory budget
 * of one byte refuses a query at step `execute` with the sink's named denial,
 * the same query answers under the host's own budget, and a negative option
 * is a NULL context.
 * It also registers CSV and newline-delimited JSON files it writes under
 * $TEST_TMPDIR with komira_register_csv and komira_register_json and queries
 * each table by name through komira_sql_stream; every answer is checked
 * against the rows the driver wrote.
 *
 * And it runs plans through komira_plan_stream: a WirePlanEnvelope it encodes
 * by hand (a scan of a Parquet file, its schema the bytes komira_parquet_schema
 * answers), run on a context with no table registered, answers what
 * komira_sql_stream answers for the same file.
 *
 * Exit 0 only if every check holds; each failure prints one line. */
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

DECLARE(komira_abi_version);
DECLARE(komira_ctx_new);
DECLARE(komira_ctx_new_with_options);
DECLARE(komira_ctx_free);
DECLARE(komira_last_error);
DECLARE(komira_register_parquet);
DECLARE(komira_parquet_schema);
DECLARE(komira_csv_binding);
DECLARE(komira_json_binding);
DECLARE(komira_plan_render);
DECLARE(komira_credential_add);
DECLARE(komira_credential_set);
DECLARE(komira_credential_seal);
DECLARE(komira_sql_stream);
DECLARE(komira_register_csv);
DECLARE(komira_register_json);
DECLARE(komira_plan_stream);

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
    BIND(komira_abi_version);
    BIND(komira_ctx_new);
    BIND(komira_ctx_new_with_options);
    BIND(komira_ctx_free);
    BIND(komira_last_error);
    BIND(komira_register_parquet);
    BIND(komira_parquet_schema);
    BIND(komira_csv_binding);
    BIND(komira_json_binding);
    BIND(komira_plan_render);
    BIND(komira_credential_add);
    BIND(komira_credential_set);
    BIND(komira_credential_seal);
    BIND(komira_sql_stream);
    BIND(komira_register_csv);
    BIND(komira_register_json);
    BIND(komira_plan_stream);
#undef BIND
    return missing;
}

/* The status codes are part of the header; the binary must agree on each. */
_Static_assert(KOMIRA_OK == 0, "KOMIRA_OK");
_Static_assert(KOMIRA_ERR_NULL_CTX == -1, "KOMIRA_ERR_NULL_CTX");
_Static_assert(KOMIRA_ERR_NULL_ARG == -2, "KOMIRA_ERR_NULL_ARG");
_Static_assert(KOMIRA_ERR_ENGINE == -3, "KOMIRA_ERR_ENGINE");
_Static_assert(KOMIRA_ERR_BUFFER_TOO_SMALL == -4, "KOMIRA_ERR_BUFFER_TOO_SMALL");
_Static_assert(KOMIRA_ERR_TOO_LARGE == -5, "KOMIRA_ERR_TOO_LARGE");
_Static_assert(KOMIRA_MAX_INPUT_BYTES == 64 * 1024 * 1024, "KOMIRA_MAX_INPUT_BYTES");
_Static_assert(KOMIRA_BIND_SESSION == 1, "KOMIRA_BIND_SESSION");
_Static_assert(KOMIRA_CRED_AWS_KEYS == 1, "KOMIRA_CRED_AWS_KEYS");
_Static_assert(KOMIRA_CRED_OAUTH2_CLIENT == 8, "KOMIRA_CRED_OAUTH2_CLIENT");
_Static_assert(KOMIRA_FIELD_KEY_ID == 1, "KOMIRA_FIELD_KEY_ID");
_Static_assert(KOMIRA_FIELD_SECRET == 2, "KOMIRA_FIELD_SECRET");
_Static_assert(KOMIRA_FIELD_TOKEN_URL == 13, "KOMIRA_FIELD_TOKEN_URL");
/* The header's Arrow structs have the layout of the Arrow specification. */
_Static_assert(sizeof(struct ArrowArrayStream) == 5 * sizeof(void *), "ArrowArrayStream");
_Static_assert(sizeof(struct ArrowSchema) == 9 * 8, "ArrowSchema");
_Static_assert(sizeof(struct ArrowArray) == 10 * 8, "ArrowArray");

/* What a stream carried: its fields, and the rows and integer values of every
   chunk. */
#define MAX_FIELDS 4
#define MAX_CHUNKS 8
#define MAX_VALUES 8
struct answer {
    int64_t n_fields;
    char names[MAX_FIELDS][32];
    char formats[MAX_FIELDS][16];
    int64_t flags[MAX_FIELDS];
    int64_t n_chunks;
    int64_t rows;
    /* The values of the first column, when it is int64 (`l`) or int32 (`i`)
       and has no NULL. */
    int64_t n_values;
    int64_t values[MAX_VALUES];
};

/* Read the stream `s` whole into `a` and release everything: get_schema, then
   get_next until the end, then the stream, then each chunk (after its values
   are read), then the schema. Returns 0, or -1 after printing why. */
static int read_answer(struct ArrowArrayStream *s, struct answer *a) {
    memset(a, 0, sizeof *a);
    struct ArrowSchema schema;
    struct ArrowArray chunks[MAX_CHUNKS];
    int failed = 0;
    if (s->release == NULL || s->get_schema(s, &schema) != 0) {
        fprintf(stderr, "FAIL: get_schema on a stream komira_sql_stream returned\n");
        return -1;
    }
    if (strcmp(schema.format, "+s") != 0 || schema.n_children < 1 || schema.n_children > MAX_FIELDS) {
        fprintf(stderr, "FAIL: the schema is not a struct of 1 to %d fields\n", MAX_FIELDS);
        failed = 1;
    } else {
        a->n_fields = schema.n_children;
        for (int64_t i = 0; i < schema.n_children; i++) {
            const struct ArrowSchema *f = schema.children[i];
            snprintf(a->names[i], sizeof a->names[i], "%s", f->name ? f->name : "");
            snprintf(a->formats[i], sizeof a->formats[i], "%s", f->format);
            a->flags[i] = f->flags;
        }
    }
    for (;;) {
        struct ArrowArray c;
        if (s->get_next(s, &c) != 0) {
            fprintf(stderr, "FAIL: get_next: %s\n", s->get_last_error(s));
            failed = 1;
            break;
        }
        if (c.release == NULL) break; /* the end of the stream */
        if (a->n_chunks == MAX_CHUNKS) {
            fprintf(stderr, "FAIL: more than %d chunks\n", MAX_CHUNKS);
            c.release(&c);
            failed = 1;
            break;
        }
        chunks[a->n_chunks++] = c;
    }
    /* The stream goes first: the chunks it handed out stay readable. */
    s->release(s);
    CHECK(s->release == NULL);
    for (int64_t k = 0; k < a->n_chunks; k++) {
        struct ArrowArray *c = &chunks[k];
        CHECK(c->n_children == a->n_fields);
        a->rows += c->length;
        if (a->n_fields > 0 && c->n_children > 0) {
            const struct ArrowArray *col = c->children[0];
            int is64 = strcmp(a->formats[0], "l") == 0;
            int is32 = strcmp(a->formats[0], "i") == 0;
            if ((is64 || is32) && col->null_count == 0) {
                for (int64_t i = 0; i < col->length && a->n_values < MAX_VALUES; i++) {
                    int64_t at = col->offset + i;
                    a->values[a->n_values++] = is64 ? ((const int64_t *)col->buffers[1])[at]
                                                    : ((const int32_t *)col->buffers[1])[at];
                }
            }
        }
        c->release(c);
        CHECK(c->release == NULL);
    }
    schema.release(&schema);
    CHECK(schema.release == NULL);
    return failed ? -1 : 0;
}

/* The context's last error as a NUL-terminated string in `text`. */
static const char *last_error_text(komira_handle ctx, char *text, size_t cap) {
    uint64_t n = 0;
    memset(text, 0, cap);
    if (p_komira_last_error(ctx, (uint8_t *)text, cap - 1, &n) != KOMIRA_OK) return "<no last error>";
    return text;
}

static int starts_with(const char *text, const char *prefix) {
    return strncmp(text, prefix, strlen(prefix)) == 0;
}

/* `komira_sql_stream(ctx, sql, ...)` refused with `want`: *out is left as the
   driver wrote it, and the last error is `error` when `exact`, or starts with
   it. Then a good query on the same context still answers. */
static void expect_refused(komira_handle ctx, const char *sql, int32_t want, const char *error, int exact) {
    struct ArrowArrayStream out, before;
    memset(&out, 0xAB, sizeof out);
    memcpy(&before, &out, sizeof out);
    char text[512];
    int32_t rc = p_komira_sql_stream(ctx, sql, &out);
    if (rc != want) fprintf(stderr, "FAIL: komira_sql_stream returned %d, want %d\n", rc, want);
    CHECK(rc == want);
    CHECK(memcmp(&out, &before, sizeof out) == 0);
    const char *got = last_error_text(ctx, text, sizeof text);
    int ok = exact ? strcmp(got, error) == 0 : starts_with(got, error);
    if (!ok) fprintf(stderr, "FAIL: last error '%s', want '%s'%s\n", got, error, exact ? "" : "...");
    CHECK(ok);
    struct answer a;
    CHECK(p_komira_sql_stream(ctx, "SELECT 1 AS n", &out) == KOMIRA_OK);
    CHECK(read_answer(&out, &a) == 0 && a.rows == 1 && a.n_values == 1 && a.values[0] == 1);
}

/* The SQL cases of komira_sql_stream. */
static void sql_stream_cases(void) {
    const char *tmp = getenv("TEST_TMPDIR");
    CHECK(tmp != NULL && tmp[0] != 0);
    if (tmp == NULL) return;
    komira_handle ctx = p_komira_ctx_new();
    CHECK(ctx != NULL);
    if (ctx == NULL) return;
    struct ArrowArrayStream out;
    struct answer a;
    char sql[1024];
    char text[512];

    /* A query over the Parquet fixture: count(*) of a file of no row is one
       row holding 0, a BIGINT that is never NULL. */
    CHECK(p_komira_register_parquet(ctx, "two", "two_columns.parquet") == KOMIRA_OK);
    memset(&out, 0, sizeof out);
    CHECK(p_komira_sql_stream(ctx, "SELECT count(*) AS n FROM two", &out) == KOMIRA_OK);
    CHECK(out.release != NULL);
    uint64_t len = 99;
    CHECK(p_komira_last_error(ctx, NULL, 0, &len) == KOMIRA_OK && len == 0);
    CHECK(read_answer(&out, &a) == 0);
    CHECK(a.n_fields == 1 && strcmp(a.names[0], "n") == 0 && strcmp(a.formats[0], "l") == 0);
    CHECK((a.flags[0] & ARROW_FLAG_NULLABLE) == 0);
    CHECK(a.rows == 1 && a.n_values == 1 && a.values[0] == 0);

    /* Its columns, with no row: the schema crosses, the chunks hold nothing. */
    CHECK(p_komira_sql_stream(ctx, "SELECT i64, s FROM two", &out) == KOMIRA_OK);
    CHECK(read_answer(&out, &a) == 0);
    CHECK(a.n_fields == 2);
    CHECK(strcmp(a.names[0], "i64") == 0 && strcmp(a.formats[0], "l") == 0);
    CHECK(strcmp(a.names[1], "s") == 0 && strcmp(a.formats[1], "u") == 0);
    CHECK((a.flags[1] & ARROW_FLAG_NULLABLE) != 0);
    CHECK(a.rows == 0);

    /* A Parquet file of three rows: written by COPY from a CSV file, whose
       answer is the BIGINT Count of rows written, then registered and
       queried. */
    char csv[512], parquet[512];
    snprintf(csv, sizeof csv, "%s/three.csv", tmp);
    snprintf(parquet, sizeof parquet, "%s/three.parquet", tmp);
    FILE *f = fopen(csv, "w");
    CHECK(f != NULL);
    if (f != NULL) {
        fputs("k\n1\n2\n3\n", f);
        fclose(f);
    }
    snprintf(sql, sizeof sql, "COPY (SELECT k FROM read_csv('%s')) TO '%s'", csv, parquet);
    CHECK(p_komira_sql_stream(ctx, sql, &out) == KOMIRA_OK);
    CHECK(read_answer(&out, &a) == 0);
    CHECK(a.n_fields == 1 && strcmp(a.names[0], "Count") == 0 && strcmp(a.formats[0], "l") == 0);
    CHECK(a.rows == 1 && a.n_values == 1 && a.values[0] == 3);
    CHECK(p_komira_register_parquet(ctx, "three", parquet) == KOMIRA_OK);
    CHECK(p_komira_sql_stream(ctx, "SELECT k FROM three WHERE k >= 2 ORDER BY k", &out) == KOMIRA_OK);
    CHECK(read_answer(&out, &a) == 0);
    CHECK(a.n_fields == 1 && strcmp(a.names[0], "k") == 0 && strcmp(a.formats[0], "l") == 0);
    CHECK(a.rows == 2 && a.n_values == 2 && a.values[0] == 2 && a.values[1] == 3);

    /* Refusals: *out untouched, the reason in the last error, and the context
       answers the next query. */
    expect_refused(ctx, NULL, KOMIRA_ERR_NULL_ARG, "komira_sql_stream: sql or out is NULL", 1);
    expect_refused(ctx, "SELEC 1", KOMIRA_ERR_ENGINE, "parse: ", 0);
    CHECK(p_komira_sql_stream(ctx, "SELECT * FROM nosuch", &out) == KOMIRA_ERR_ENGINE);
    CHECK(strstr(last_error_text(ctx, text, sizeof text), "nosuch") != NULL);
    expect_refused(ctx, "SELECT * FROM nosuch", KOMIRA_ERR_ENGINE, "bind: ", 0);
    expect_refused(ctx, "SELECT '\xff' AS s", KOMIRA_ERR_ENGINE, "komira_sql_stream: the SQL text is not valid UTF-8", 1);
    struct ArrowArrayStream untouched;
    memset(&untouched, 0xAB, sizeof untouched);
    CHECK(p_komira_sql_stream(NULL, "SELECT 1 AS n", &untouched) == KOMIRA_ERR_NULL_CTX);
    CHECK(p_komira_sql_stream(ctx, "SELECT 1 AS n", NULL) == KOMIRA_ERR_NULL_ARG);
    CHECK(strcmp(last_error_text(ctx, text, sizeof text), "komira_sql_stream: sql or out is NULL") == 0);
    {
        uint8_t sentinel[sizeof untouched];
        memset(sentinel, 0xAB, sizeof sentinel);
        CHECK(memcmp(&untouched, sentinel, sizeof sentinel) == 0);
    }

    /* The text bound: exactly KOMIRA_MAX_INPUT_BYTES bytes before the NUL is
       run; one byte more is refused before the engine sees it. */
    size_t bound = (size_t)KOMIRA_MAX_INPUT_BYTES;
    char *big = malloc(bound + 2);
    CHECK(big != NULL);
    if (big != NULL) {
        static const char select1[] = "SELECT 1 AS n";
        memset(big, ' ', bound + 1);
        memcpy(big, select1, sizeof select1 - 1);
        big[bound] = 0;
        CHECK(p_komira_sql_stream(ctx, big, &out) == KOMIRA_OK);
        CHECK(read_answer(&out, &a) == 0 && a.rows == 1 && a.n_values == 1 && a.values[0] == 1);
        big[bound] = ' ';
        big[bound + 1] = 0;
        char msg[128];
        snprintf(msg, sizeof msg, "komira_sql_stream: sql is above %llu bytes", (unsigned long long)KOMIRA_MAX_INPUT_BYTES);
        expect_refused(ctx, big, KOMIRA_ERR_TOO_LARGE, msg, 1);
        free(big);
    }

    /* A stream outlives its context: the context is freed before the stream
       is read, and the stream and its chunks are released after. */
    CHECK(p_komira_sql_stream(ctx, "SELECT k FROM three ORDER BY k", &out) == KOMIRA_OK);
    p_komira_ctx_free(ctx);
    CHECK(read_answer(&out, &a) == 0);
    CHECK(a.rows == 3 && a.n_values == 3 && a.values[0] == 1 && a.values[1] == 2 && a.values[2] == 3);
}

/* Write `text` to `<tmp>/<name>` and leave the path in `path`. */
static int write_file(const char *tmp, const char *name, const char *text, char *path, size_t cap) {
    snprintf(path, cap, "%s/%s", tmp, name);
    FILE *f = fopen(path, "w");
    if (f == NULL) {
        fprintf(stderr, "FAIL: cannot write %s\n", path);
        failures++;
        return -1;
    }
    fputs(text, f);
    fclose(f);
    return 0;
}

/* Run `sql` on `ctx` and read its answer into `a`; 0, or -1 after printing why.
   Every -1 is counted as a failure here, so a caller that skips its value
   checks on -1 still makes the driver exit non-zero. */
static int query(komira_handle ctx, const char *sql, struct answer *a) {
    struct ArrowArrayStream out;
    memset(&out, 0, sizeof out);
    int32_t rc = p_komira_sql_stream(ctx, sql, &out);
    if (rc != KOMIRA_OK) {
        char text[512];
        fprintf(stderr, "FAIL: %s returned %d: %s\n", sql, rc, last_error_text(ctx, text, sizeof text));
        failures++;
        return -1;
    }
    if (read_answer(&out, a) != 0) {
        fprintf(stderr, "FAIL: the answer of %s could not be read\n", sql);
        failures++;
        return -1;
    }
    return 0;
}

/* The CSV and JSON tables of komira_register_csv and komira_register_json:
   registered by name, queried by that name, and the answers are the rows of
   the files. */
static void text_source_cases(void) {
    const char *tmp = getenv("TEST_TMPDIR");
    CHECK(tmp != NULL && tmp[0] != 0);
    if (tmp == NULL) return;
    komira_handle ctx = p_komira_ctx_new();
    CHECK(ctx != NULL);
    if (ctx == NULL) return;
    struct answer a;
    char text[512];
    char people[512], piped[512], bare[512], events[512], missing[512];
    if (write_file(tmp, "people.csv", "id,name,score\n1,ann,10\n2,bob,20\n3,cy,30\n", people, sizeof people) != 0) return;
    if (write_file(tmp, "piped.csv", "id|name\n4|dee\n5|eve\n", piped, sizeof piped) != 0) return;
    if (write_file(tmp, "bare.csv", "7,8\n9,10\n", bare, sizeof bare) != 0) return;
    if (write_file(tmp, "events.jsonl", "{\"id\":1,\"v\":\"x\"}\n{\"id\":2,\"v\":\"y\"}\n{\"id\":3,\"v\":\"y\"}\n", events, sizeof events) != 0) return;
    snprintf(missing, sizeof missing, "%s/no_such_file.csv", tmp);

    /* A CSV file with a header: a filter, a sort and a string comparison. */
    CHECK(p_komira_register_csv(ctx, "people", people, ',', 1, 0) == KOMIRA_OK);
    uint64_t len = 99;
    CHECK(p_komira_last_error(ctx, NULL, 0, &len) == KOMIRA_OK && len == 0);
    if (query(ctx, "SELECT id FROM people WHERE score >= 20 ORDER BY id", &a) == 0) {
        CHECK(a.n_fields == 1 && strcmp(a.names[0], "id") == 0 && strcmp(a.formats[0], "l") == 0);
        CHECK(a.rows == 2 && a.n_values == 2 && a.values[0] == 2 && a.values[1] == 3);
    }
    if (query(ctx, "SELECT id FROM PEOPLE WHERE name = 'cy'", &a) == 0) {
        CHECK(a.rows == 1 && a.n_values == 1 && a.values[0] == 3);
    }
    if (query(ctx, "SELECT max(score) AS m FROM people", &a) == 0) {
        CHECK(a.rows == 1 && a.n_values == 1 && a.values[0] == 30);
    }

    /* Another delimiter, no header, and every column a string. */
    CHECK(p_komira_register_csv(ctx, "piped", piped, '|', 1, 0) == KOMIRA_OK);
    if (query(ctx, "SELECT id, name FROM piped ORDER BY id", &a) == 0) {
        CHECK(a.n_fields == 2 && strcmp(a.names[1], "name") == 0 && strcmp(a.formats[1], "u") == 0);
        CHECK(a.rows == 2 && a.n_values == 2 && a.values[0] == 4 && a.values[1] == 5);
    }
    /* No header: the table registers, and a query on it is refused by name
       at lower (as read_csv(..., header=false) is), *out left as written. */
    CHECK(p_komira_register_csv(ctx, "bare", bare, ',', 0, 0) == KOMIRA_OK);
    {
        struct ArrowArrayStream untouched;
        memset(&untouched, 0, sizeof untouched);
        CHECK(p_komira_sql_stream(ctx, "SELECT count(*) AS n FROM bare", &untouched) == KOMIRA_ERR_ENGINE);
        CHECK(untouched.release == NULL);
        const char *why = last_error_text(ctx, text, sizeof text);
        CHECK(starts_with(why, "lower: ") && strstr(why, "header=false") != NULL);
    }
    CHECK(p_komira_register_csv(ctx, "people_text", people, ',', 1, 1) == KOMIRA_OK);
    if (query(ctx, "SELECT id, score FROM people_text", &a) == 0) {
        CHECK(a.n_fields == 2 && strcmp(a.formats[0], "u") == 0 && strcmp(a.formats[1], "u") == 0);
        CHECK(a.rows == 3);
    }

    /* A newline-delimited JSON file. */
    CHECK(p_komira_register_json(ctx, "events", events) == KOMIRA_OK);
    if (query(ctx, "SELECT id FROM events WHERE v = 'y' ORDER BY id", &a) == 0) {
        CHECK(a.n_fields == 1 && strcmp(a.names[0], "id") == 0 && strcmp(a.formats[0], "l") == 0);
        CHECK(a.rows == 2 && a.n_values == 2 && a.values[0] == 2 && a.values[1] == 3);
    }

    /* Refusals, each with its named last error; the first table under a
       taken name keeps answering with its own rows. */
    CHECK(p_komira_register_csv(ctx, "Events", people, ',', 1, 0) == KOMIRA_ERR_ENGINE);
    CHECK(strcmp(last_error_text(ctx, text, sizeof text),
                 "TABLE_ALREADY_REGISTERED: the session already has a table named 'Events'") == 0);
    CHECK(p_komira_register_json(ctx, "people", events) == KOMIRA_ERR_ENGINE);
    CHECK(strcmp(last_error_text(ctx, text, sizeof text),
                 "TABLE_ALREADY_REGISTERED: the session already has a table named 'people'") == 0);
    CHECK(p_komira_register_csv(ctx, "", people, ',', 1, 0) == KOMIRA_ERR_ENGINE);
    CHECK(strcmp(last_error_text(ctx, text, sizeof text), "TABLE_NAME_EMPTY: a table name must not be empty") == 0);
    CHECK(p_komira_register_json(ctx, "", events) == KOMIRA_ERR_ENGINE);
    CHECK(strcmp(last_error_text(ctx, text, sizeof text), "TABLE_NAME_EMPTY: a table name must not be empty") == 0);
    CHECK(p_komira_register_csv(ctx, "gone", missing, ',', 1, 0) == KOMIRA_ERR_ENGINE);
    CHECK(last_error_text(ctx, text, sizeof text)[0] != 0);
    CHECK(p_komira_register_json(ctx, "gone", missing) == KOMIRA_ERR_ENGINE);
    CHECK(last_error_text(ctx, text, sizeof text)[0] != 0);
    CHECK(p_komira_register_csv(NULL, "t", people, ',', 1, 0) == KOMIRA_ERR_NULL_CTX);
    CHECK(p_komira_register_json(NULL, "t", events) == KOMIRA_ERR_NULL_CTX);
    CHECK(p_komira_register_csv(ctx, NULL, people, ',', 1, 0) == KOMIRA_ERR_NULL_ARG);
    CHECK(strcmp(last_error_text(ctx, text, sizeof text), "komira_register_csv: name or path is NULL") == 0);
    CHECK(p_komira_register_json(ctx, "t", NULL) == KOMIRA_ERR_NULL_ARG);
    CHECK(strcmp(last_error_text(ctx, text, sizeof text), "komira_register_json: name or path is NULL") == 0);
    if (query(ctx, "SELECT count(*) AS n FROM events", &a) == 0) {
        CHECK(a.rows == 1 && a.n_values == 1 && a.values[0] == 3);
    }
    if (query(ctx, "SELECT count(*) AS n FROM people", &a) == 0) {
        CHECK(a.rows == 1 && a.n_values == 1 && a.values[0] == 3);
    }
    /* A refused name stays free. */
    CHECK(p_komira_register_csv(ctx, "gone", people, ',', 1, 0) == KOMIRA_OK);
    p_komira_ctx_free(ctx);
}

/* The session options of komira_ctx_new_with_options, over three.parquet
   (k = 1, 2, 3), which sql_stream_cases wrote under $TEST_TMPDIR. */
static void options_cases(void) {
    const char *tmp = getenv("TEST_TMPDIR");
    if (tmp == NULL) return; /* sql_stream_cases has already failed on it */
    char parquet[512];
    snprintf(parquet, sizeof parquet, "%s/three.parquet", tmp);
    static const char sum[] = "SELECT sum(k) AS s FROM three";
    struct ArrowArrayStream out;
    struct answer a;
    char text[512];

    /* 0 and 0 are the host's own worker count and budget: a context that
       answers, with no error. */
    komira_handle host = p_komira_ctx_new_with_options(0, 0);
    CHECK(host != NULL);
    if (host != NULL) {
        uint64_t len = 99;
        CHECK(p_komira_last_error(host, NULL, 0, &len) == KOMIRA_OK && len == 0);
        CHECK(p_komira_register_parquet(host, "three", parquet) == KOMIRA_OK);
        CHECK(p_komira_sql_stream(host, sum, &out) == KOMIRA_OK);
        CHECK(read_answer(&out, &a) == 0 && a.rows == 1 && a.n_fields == 1 && strcmp(a.names[0], "s") == 0);
        p_komira_ctx_free(host);
    }

    /* One worker and the host's budget: the same query answers. */
    komira_handle one = p_komira_ctx_new_with_options(1, 0);
    CHECK(one != NULL);
    if (one != NULL) {
        CHECK(p_komira_register_parquet(one, "three", parquet) == KOMIRA_OK);
        CHECK(p_komira_sql_stream(one, sum, &out) == KOMIRA_OK);
        CHECK(read_answer(&out, &a) == 0 && a.rows == 1);
        p_komira_ctx_free(one);
    }

    /* A budget of one byte, with one worker and with the host's count: the
       aggregation sink is denied its state, a refusal at step `execute` that
       names the budget; *out is untouched and the context answers a query
       that reserves nothing. */
    static const int64_t workers[2] = {1, 0};
    for (int i = 0; i < 2; i++) {
        komira_handle tiny = p_komira_ctx_new_with_options(workers[i], 1);
        CHECK(tiny != NULL);
        if (tiny == NULL) continue;
        CHECK(p_komira_register_parquet(tiny, "three", parquet) == KOMIRA_OK);
        expect_refused(tiny, sum, KOMIRA_ERR_ENGINE, "execute: [Processor] pipeline_exec: the ", 0);
        CHECK(p_komira_sql_stream(tiny, sum, &out) == KOMIRA_ERR_ENGINE);
        const char *got = last_error_text(tiny, text, sizeof text);
        int named = strstr(got, " sink of segment ") != NULL && strstr(got, " was denied ") != NULL &&
                    strstr(got, " bytes of the segment's memory pool") != NULL && strstr(got, "(budget 1, granted ") != NULL;
        if (!named) fprintf(stderr, "FAIL: last error '%s' does not name the sink's denial under a budget of 1\n", got);
        CHECK(named);
        p_komira_ctx_free(tiny);
    }

    /* A negative worker count or budget is refused: NULL, nothing to free. */
    CHECK(p_komira_ctx_new_with_options(-1, 0) == NULL);
    CHECK(p_komira_ctx_new_with_options(0, -1) == NULL);
    CHECK(p_komira_ctx_new_with_options(INT64_MIN, 0) == NULL);
    CHECK(p_komira_ctx_new_with_options(0, INT64_MIN) == NULL);
}

/* A growable byte string, for the protobuf bytes of a plan. */
struct buf {
    uint8_t *p;
    size_t n, cap;
};

static void buf_put(struct buf *b, const void *src, size_t n) {
    if (b->n + n > b->cap) {
        b->cap = (b->n + n) * 2 + 64;
        b->p = realloc(b->p, b->cap);
        if (b->p == NULL) abort();
    }
    if (n) memcpy(b->p + b->n, src, n);
    b->n += n;
}

static void put_varint(struct buf *b, uint64_t v) {
    uint8_t c;
    do {
        c = v & 0x7f;
        v >>= 7;
        if (v) c |= 0x80;
        buf_put(b, &c, 1);
    } while (v);
}

/* A field of wire type 0 (varint). */
static void put_uint(struct buf *b, unsigned field, uint64_t v) {
    put_varint(b, (uint64_t)field << 3);
    put_varint(b, v);
}

/* A field of wire type 2 (length-delimited). */
static void put_bytes(struct buf *b, unsigned field, const void *src, size_t n) {
    put_varint(b, ((uint64_t)field << 3) | 2);
    put_varint(b, n);
    buf_put(b, src, n);
}

/* The WirePlanEnvelope (src/plan_proto/plan.proto) of a scan of the Parquet
   file `path` whose WireSchema bytes are `schema`, declaring `version`:
   WirePlanEnvelope{1 format_version, 2 plan}, WirePlan{2 output_schema,
   4 scan}, WireScanNode{1 source, 2 has_schema, 3 schema, 10 source_kind
   (1, columnar)}, WireScanSource{1 parquet}, WireParquetSource{1 paths,
   2 schema, 10 fs_is_local}. The scan's output is its file's schema. */
static void scan_envelope(struct buf *out, uint64_t version, const char *path,
                          const uint8_t *schema, size_t schema_len) {
    struct buf pq = {0}, src = {0}, scan = {0}, plan = {0};
    put_bytes(&pq, 1, path, strlen(path));
    put_bytes(&pq, 2, schema, schema_len);
    put_uint(&pq, 10, 1);
    put_bytes(&src, 1, pq.p, pq.n);
    put_bytes(&scan, 1, src.p, src.n);
    put_uint(&scan, 2, 1);
    put_bytes(&scan, 3, schema, schema_len);
    put_uint(&scan, 10, 1);
    put_bytes(&plan, 2, schema, schema_len);
    put_bytes(&plan, 4, scan.p, scan.n);
    put_uint(out, 1, version);
    put_bytes(out, 2, plan.p, plan.n);
    free(pq.p);
    free(src.p);
    free(scan.p);
    free(plan.p);
}

/* The WireSchema bytes of the Parquet file `path` (komira_parquet_schema, by
   the two-call protocol), in `b`; 0, or -1 after printing why. */
static int schema_bytes(komira_handle ctx, const char *path, struct buf *b) {
    uint64_t len = 0, again = 0;
    if (p_komira_parquet_schema(ctx, path, NULL, 0, &len) != KOMIRA_ERR_BUFFER_TOO_SMALL || len == 0) {
        fprintf(stderr, "FAIL: komira_parquet_schema of %s gave no length\n", path);
        return -1;
    }
    b->n = 0;
    if (b->cap < len) {
        b->cap = len;
        b->p = realloc(b->p, len);
        if (b->p == NULL) abort();
    }
    if (p_komira_parquet_schema(ctx, path, b->p, len, &again) != KOMIRA_OK || again != len) {
        fprintf(stderr, "FAIL: komira_parquet_schema of %s\n", path);
        return -1;
    }
    b->n = len;
    return 0;
}

/* Two answers are the same: fields (name, format, flags), rows and the values
   of the first column. */
static int same_answer(const struct answer *a, const struct answer *b) {
    if (a->n_fields != b->n_fields || a->rows != b->rows || a->n_values != b->n_values) return 0;
    for (int64_t i = 0; i < a->n_fields; i++) {
        if (strcmp(a->names[i], b->names[i]) != 0 || strcmp(a->formats[i], b->formats[i]) != 0 ||
            a->flags[i] != b->flags[i])
            return 0;
    }
    for (int64_t i = 0; i < a->n_values; i++) {
        if (a->values[i] != b->values[i]) return 0;
    }
    return 1;
}

/* `komira_plan_stream(ctx, plan, len, ...)` refused with `want`: *out is left
   as the driver wrote it, and the last error is `error` when `exact`, or
   starts with it. Then the good plan `good` on the same context answers
   `expect`. */
static void expect_plan_refused(komira_handle ctx, const uint8_t *plan, uint64_t len, int32_t want,
                                const char *error, int exact, const struct buf *good,
                                const struct answer *expect) {
    struct ArrowArrayStream out, before;
    memset(&out, 0xAB, sizeof out);
    memcpy(&before, &out, sizeof out);
    char text[512];
    int32_t rc = p_komira_plan_stream(ctx, plan, len, &out);
    if (rc != want) fprintf(stderr, "FAIL: komira_plan_stream returned %d, want %d\n", rc, want);
    CHECK(rc == want);
    CHECK(memcmp(&out, &before, sizeof out) == 0);
    const char *got = last_error_text(ctx, text, sizeof text);
    int ok = exact ? strcmp(got, error) == 0 : starts_with(got, error);
    if (!ok) fprintf(stderr, "FAIL: last error '%s', want '%s'%s\n", got, error, exact ? "" : "...");
    CHECK(ok);
    struct answer a;
    CHECK(p_komira_plan_stream(ctx, good->p, good->n, &out) == KOMIRA_OK);
    CHECK(read_answer(&out, &a) == 0 && same_answer(&a, expect));
}

/* The plan cases of komira_plan_stream. */
static void plan_stream_cases(void) {
    const char *tmp = getenv("TEST_TMPDIR");
    CHECK(tmp != NULL && tmp[0] != 0);
    if (tmp == NULL) return;
    komira_handle sql = p_komira_ctx_new();
    komira_handle ctx = p_komira_ctx_new();
    CHECK(sql != NULL && ctx != NULL);
    if (sql == NULL || ctx == NULL) return;
    struct ArrowArrayStream out;
    struct answer by_plan, by_sql;
    char text[512];
    struct buf schema = {0}, plan = {0};

    /* A Parquet file of three rows, written by COPY on the SQL context. */
    char csv[512], parquet[512], query[1200];
    snprintf(csv, sizeof csv, "%s/plan_three.csv", tmp);
    snprintf(parquet, sizeof parquet, "%s/plan_three.parquet", tmp);
    FILE *f = fopen(csv, "w");
    CHECK(f != NULL);
    if (f != NULL) {
        fputs("k\n1\n2\n3\n", f);
        fclose(f);
    }
    snprintf(query, sizeof query, "COPY (SELECT k FROM read_csv('%s')) TO '%s'", csv, parquet);
    CHECK(p_komira_sql_stream(sql, query, &out) == KOMIRA_OK);
    CHECK(read_answer(&out, &by_sql) == 0 && by_sql.n_values == 1 && by_sql.values[0] == 3);

    /* A scan of it, run on a context with no table, answers what SQL answers
       for the file: the column k, BIGINT, the rows 1, 2 and 3. */
    CHECK(schema_bytes(ctx, parquet, &schema) == 0);
    scan_envelope(&plan, 4, parquet, schema.p, schema.n);
    memset(&out, 0, sizeof out);
    CHECK(p_komira_plan_stream(ctx, plan.p, plan.n, &out) == KOMIRA_OK);
    CHECK(out.release != NULL);
    uint64_t len = 99;
    CHECK(p_komira_last_error(ctx, NULL, 0, &len) == KOMIRA_OK && len == 0);
    CHECK(read_answer(&out, &by_plan) == 0);
    CHECK(p_komira_register_parquet(sql, "three", parquet) == KOMIRA_OK);
    CHECK(p_komira_sql_stream(sql, "SELECT k FROM three", &out) == KOMIRA_OK);
    CHECK(read_answer(&out, &by_sql) == 0);
    CHECK(same_answer(&by_plan, &by_sql));
    CHECK(by_plan.n_fields == 1 && strcmp(by_plan.names[0], "k") == 0 && strcmp(by_plan.formats[0], "l") == 0);
    CHECK(by_plan.rows == 3 && by_plan.n_values == 3 && by_plan.values[0] == 1 && by_plan.values[1] == 2 &&
          by_plan.values[2] == 3);

    /* The no-row fixture: its two columns cross with no row, as by SQL. */
    {
        struct buf two_schema = {0}, two = {0};
        struct answer two_plan, two_sql;
        CHECK(schema_bytes(ctx, "two_columns.parquet", &two_schema) == 0);
        scan_envelope(&two, 4, "two_columns.parquet", two_schema.p, two_schema.n);
        CHECK(p_komira_plan_stream(ctx, two.p, two.n, &out) == KOMIRA_OK);
        CHECK(read_answer(&out, &two_plan) == 0);
        CHECK(p_komira_register_parquet(sql, "two", "two_columns.parquet") == KOMIRA_OK);
        CHECK(p_komira_sql_stream(sql, "SELECT i64, s FROM two", &out) == KOMIRA_OK);
        CHECK(read_answer(&out, &two_sql) == 0);
        CHECK(same_answer(&two_plan, &two_sql));
        CHECK(two_plan.n_fields == 2 && two_plan.rows == 0);
        free(two_schema.p);
        free(two.p);
    }

    /* Refusals: *out untouched, the reason in the last error, and the context
       runs the plan again. Bytes that are SQL text are not a plan. */
    static const char select1[] = "SELECT 1 AS n";
    static const uint8_t garbage[3] = {0xFF, 0x00, 0x01};
    expect_plan_refused(ctx, (const uint8_t *)select1, sizeof select1 - 1, KOMIRA_ERR_ENGINE, "decode: ", 0,
                        &plan, &by_sql);
    expect_plan_refused(ctx, garbage, sizeof garbage, KOMIRA_ERR_ENGINE, "decode: ", 0, &plan, &by_sql);
    {
        /* A version this build does not speak. */
        struct buf v3 = {0};
        scan_envelope(&v3, 3, parquet, schema.p, schema.n);
        expect_plan_refused(ctx, v3.p, v3.n, KOMIRA_ERR_ENGINE, "decode: ", 0, &plan, &by_sql);
        free(v3.p);
    }
    {
        /* A scan of a file that is not there is refused when it is lowered. */
        char missing[512];
        struct buf gone = {0};
        snprintf(missing, sizeof missing, "%s/plan_missing.parquet", tmp);
        scan_envelope(&gone, 4, missing, schema.p, schema.n);
        CHECK(p_komira_plan_stream(ctx, gone.p, gone.n, &out) == KOMIRA_ERR_ENGINE);
        CHECK(strstr(last_error_text(ctx, text, sizeof text), "plan_missing.parquet") != NULL);
        expect_plan_refused(ctx, gone.p, gone.n, KOMIRA_ERR_ENGINE, "lower: ", 0, &plan, &by_sql);
        free(gone.p);
    }
    expect_plan_refused(ctx, NULL, plan.n, KOMIRA_ERR_NULL_ARG, "komira_plan_stream: plan or out is NULL", 1,
                        &plan, &by_sql);
    {
        char msg[128];
        snprintf(msg, sizeof msg, "komira_plan_stream: plan_len is above %llu bytes",
                 (unsigned long long)KOMIRA_MAX_INPUT_BYTES);
        /* The pointer is a 3-byte buffer: a length past the bound is refused
           before any byte is read. */
        expect_plan_refused(ctx, garbage, (uint64_t)KOMIRA_MAX_INPUT_BYTES + 1, KOMIRA_ERR_TOO_LARGE, msg, 1, &plan,
                            &by_sql);
        expect_plan_refused(ctx, garbage, UINT64_MAX, KOMIRA_ERR_TOO_LARGE, msg, 1, &plan, &by_sql);
    }
    {
        /* Exactly the bound is read: being garbage, it is the decoder's -3. */
        uint8_t *big = malloc((size_t)KOMIRA_MAX_INPUT_BYTES);
        CHECK(big != NULL);
        if (big != NULL) {
            memset(big, 0xFF, (size_t)KOMIRA_MAX_INPUT_BYTES);
            expect_plan_refused(ctx, big, (uint64_t)KOMIRA_MAX_INPUT_BYTES, KOMIRA_ERR_ENGINE, "decode: ", 0, &plan,
                                &by_sql);
            free(big);
        }
    }
    struct ArrowArrayStream untouched;
    memset(&untouched, 0xAB, sizeof untouched);
    CHECK(p_komira_plan_stream(NULL, plan.p, plan.n, &untouched) == KOMIRA_ERR_NULL_CTX);
    CHECK(p_komira_plan_stream(ctx, plan.p, plan.n, NULL) == KOMIRA_ERR_NULL_ARG);
    CHECK(strcmp(last_error_text(ctx, text, sizeof text), "komira_plan_stream: plan or out is NULL") == 0);
    {
        uint8_t sentinel[sizeof untouched];
        memset(sentinel, 0xAB, sizeof sentinel);
        CHECK(memcmp(&untouched, sentinel, sizeof sentinel) == 0);
    }

    /* A stream outlives its context. */
    CHECK(p_komira_plan_stream(ctx, plan.p, plan.n, &out) == KOMIRA_OK);
    p_komira_ctx_free(ctx);
    CHECK(read_answer(&out, &by_plan) == 0 && same_answer(&by_plan, &by_sql));
    p_komira_ctx_free(sql);
    free(schema.p);
    free(plan.p);
}

int main(void) {
    void *lib = dlopen("./libkomira.so", RTLD_NOW);
    if (lib == NULL) {
        fprintf(stderr, "dlopen: %s\n", dlerror());
        return 1;
    }
    if (bind_all(lib) != 0) return 1;

    /* The version in the header is the version of the binary. */
    CHECK(p_komira_abi_version() == KOMIRA_ABI_VERSION_MAJOR * 1000 + KOMIRA_ABI_VERSION_MINOR);

    /* A context is a handle; two are two sessions. */
    komira_handle ctx = p_komira_ctx_new();
    komira_handle other = p_komira_ctx_new();
    CHECK(ctx != NULL && other != NULL && ctx != other);

    /* A fresh session has no error: the length is 0 and no buffer is needed. */
    uint64_t len = 99;
    CHECK(p_komira_last_error(ctx, NULL, 0, &len) == KOMIRA_OK);
    CHECK(len == 0);

    /* The statuses the header names are the ones the binary returns. */
    CHECK(p_komira_last_error(NULL, NULL, 0, &len) == KOMIRA_ERR_NULL_CTX);
    CHECK(p_komira_last_error(ctx, NULL, 0, NULL) == KOMIRA_ERR_NULL_ARG);
    CHECK(p_komira_register_parquet(NULL, "t", "x.parquet") == KOMIRA_ERR_NULL_CTX);
    CHECK(p_komira_register_parquet(ctx, NULL, "x.parquet") == KOMIRA_ERR_NULL_ARG);

    /* An engine refusal stores its text in the context: the two-call round trip. */
    CHECK(p_komira_register_parquet(ctx, "t", "no_such_file.parquet") == KOMIRA_ERR_ENGINE);
    len = 0;
    CHECK(p_komira_last_error(ctx, NULL, 0, &len) == KOMIRA_ERR_BUFFER_TOO_SMALL);
    CHECK(len > 0 && len < 4096);
    uint8_t text[4096];
    uint64_t again = 0;
    memset(text, 0, sizeof text);
    CHECK(p_komira_last_error(ctx, text, len - 1, &again) == KOMIRA_ERR_BUFFER_TOO_SMALL);
    CHECK(again == len && text[0] == 0); /* a short buffer is not written */
    CHECK(p_komira_last_error(ctx, text, len, &again) == KOMIRA_OK);
    CHECK(again == len && text[0] != 0 && text[len] == 0);
    /* The other session saw none of it. */
    CHECK(p_komira_last_error(other, NULL, 0, &len) == KOMIRA_OK && len == 0);

    /* A path that is not a file is the engine's refusal for each source call. */
    uint8_t out[16];
    uint64_t out_len = 0;
    CHECK(p_komira_parquet_schema(ctx, "no_such_file.parquet", out, sizeof out, &out_len) == KOMIRA_ERR_ENGINE);
    CHECK(p_komira_csv_binding(ctx, "no_such_file.csv", ',', 1, 0, out, sizeof out, &out_len) == KOMIRA_ERR_ENGINE);
    CHECK(p_komira_json_binding(ctx, "no_such_file.json", out, sizeof out, &out_len) == KOMIRA_ERR_ENGINE);

    /* The input bound is the header's: one byte over is refused before any read. */
    static const uint8_t plan[1] = {0};
    CHECK(p_komira_plan_render(ctx, plan, (uint64_t)KOMIRA_MAX_INPUT_BYTES + 1, out, sizeof out, &out_len) == KOMIRA_ERR_TOO_LARGE);
    CHECK(p_komira_plan_render(ctx, plan, UINT64_MAX, out, sizeof out, &out_len) == KOMIRA_ERR_TOO_LARGE);
    CHECK(p_komira_plan_render(ctx, NULL, 0, NULL, 0, NULL) == KOMIRA_ERR_NULL_ARG);

    /* A credential through the header's constants: defined, then one sealed
       without its secret is the engine's refusal, named in the last error. */
    int32_t id = -7;
    static const char key_id[] = "AKIDDRIVER";
    static const char secret[] = "driver-secret";
    CHECK(p_komira_credential_add(ctx, KOMIRA_CRED_AWS_KEYS, "raw-etl", &id) == KOMIRA_OK && id > 0);
    CHECK(p_komira_credential_set(ctx, id, KOMIRA_FIELD_KEY_ID, (const uint8_t *)key_id, sizeof key_id - 1) == KOMIRA_OK);
    CHECK(p_komira_credential_set(ctx, id, KOMIRA_FIELD_SECRET, (const uint8_t *)secret, sizeof secret - 1) == KOMIRA_OK);
    CHECK(p_komira_credential_seal(ctx, id, KOMIRA_BIND_SESSION) == KOMIRA_OK);
    CHECK(p_komira_credential_add(ctx, KOMIRA_CRED_AWS_KEYS, "raw-etl", &id) == KOMIRA_OK);
    CHECK(p_komira_credential_set(ctx, id, KOMIRA_FIELD_KEY_ID, (const uint8_t *)key_id, sizeof key_id - 1) == KOMIRA_OK);
    CHECK(p_komira_credential_seal(ctx, id, KOMIRA_BIND_SESSION) == KOMIRA_ERR_ENGINE);
    static const char named[] = "CREDENTIALS_INVALID: seal credential=raw-etl: AwsKeys needs secret=";
    memset(text, 0, sizeof text);
    CHECK(p_komira_last_error(ctx, text, sizeof text, &again) == KOMIRA_OK);
    CHECK(again == sizeof named - 1 && memcmp(text, named, sizeof named - 1) == 0);
    /* NULL context, NULL out_id, NULL value with a length, a length past the bound. */
    int32_t untouched = -7;
    CHECK(p_komira_credential_add(NULL, KOMIRA_CRED_AWS_KEYS, "raw-etl", &untouched) == KOMIRA_ERR_NULL_CTX);
    CHECK(p_komira_credential_add(ctx, KOMIRA_CRED_AWS_KEYS, "raw-etl", NULL) == KOMIRA_ERR_NULL_ARG);
    CHECK(untouched == -7);
    CHECK(p_komira_credential_set(ctx, 1, KOMIRA_FIELD_SECRET, NULL, 4) == KOMIRA_ERR_NULL_ARG);
    CHECK(p_komira_credential_set(ctx, 1, KOMIRA_FIELD_SECRET, plan, (uint64_t)KOMIRA_MAX_INPUT_BYTES + 1) == KOMIRA_ERR_TOO_LARGE);
    CHECK(p_komira_credential_seal(NULL, 1, KOMIRA_BIND_SESSION) == KOMIRA_ERR_NULL_CTX);

    p_komira_ctx_free(ctx);
    p_komira_ctx_free(other);
    p_komira_ctx_free(NULL);

    sql_stream_cases();
    text_source_cases();
    options_cases();
    plan_stream_cases();
    return failures == 0 ? 0 : 1;
}
