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
 * And it runs SQL through komira_sql_stream_run under a run handle: a handle
 * cancelled before the call refuses the run with KOMIRA_ERR_CANCELLED and the
 * QUERY_CANCELLED last error; a second thread reads the progress of a run in
 * flight, and another cancels one in flight. No check depends on how long
 * anything takes: a reading taken while a run is in flight is held only to
 * what every reading must satisfy, and a cancel racing a run may land before
 * or after its last check, so either outcome is accepted and each is checked
 * whole.
 * Last, it is a producer of struct ArrowArrayStream, written in C as a host's
 * Arrow library would be, and hands its streams to
 * komira_register_arrow_stream: the registered table answers queries (a
 * join with a registered CSV file among them) after the producer's buffers
 * are overwritten and freed, and the producer counts every release the
 * library makes of the stream, its schema and its chunks.
 *
 * And it runs plans through komira_plan_stream: a WirePlanEnvelope it encodes
 * by hand (a scan of a Parquet file, its schema the bytes komira_parquet_schema
 * answers), run on a context with no table registered, answers what
 * komira_sql_stream answers for the same file.
 *
 * Exit 0 only if every check holds; each failure prints one line. */
#include <dlfcn.h>
#include <pthread.h>
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
DECLARE(komira_last_error_code);
DECLARE(komira_last_error_step);
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
DECLARE(komira_run_new);
DECLARE(komira_run_free);
DECLARE(komira_run_cancel);
DECLARE(komira_run_progress);
DECLARE(komira_sql_stream_run);
DECLARE(komira_plan_stream);
DECLARE(komira_register_arrow_stream);

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
    BIND(komira_last_error_code);
    BIND(komira_last_error_step);
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
    BIND(komira_run_new);
    BIND(komira_run_free);
    BIND(komira_run_cancel);
    BIND(komira_run_progress);
    BIND(komira_sql_stream_run);
    BIND(komira_plan_stream);
    BIND(komira_register_arrow_stream);
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
_Static_assert(KOMIRA_ERR_CANCELLED == -6, "KOMIRA_ERR_CANCELLED");
_Static_assert(KOMIRA_STEP_NONE == 0, "KOMIRA_STEP_NONE");
_Static_assert(KOMIRA_STEP_PARSE == 1, "KOMIRA_STEP_PARSE");
_Static_assert(KOMIRA_STEP_BIND == 2, "KOMIRA_STEP_BIND");
_Static_assert(KOMIRA_STEP_OPTIMIZE == 3, "KOMIRA_STEP_OPTIMIZE");
_Static_assert(KOMIRA_STEP_LOWER == 4, "KOMIRA_STEP_LOWER");
_Static_assert(KOMIRA_STEP_EXECUTE == 5, "KOMIRA_STEP_EXECUTE");
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

/* The last error's step is `step` and its code is exactly `code` (empty for
   none), the code read by the two-call protocol: a probe with capacity 0, a
   buffer one byte short (-4, not written), and an exact buffer. Neither call
   clears the error: the text read before and after is the same. */
static void expect_error_step_code(komira_handle ctx, int32_t step, const char *code) {
    char before[512], after[512];
    last_error_text(ctx, before, sizeof before);
    CHECK(p_komira_last_error_step(ctx) == step);
    size_t want = strlen(code);
    uint64_t n = 99;
    if (want == 0) {
        CHECK(p_komira_last_error_code(ctx, NULL, 0, &n) == KOMIRA_OK && n == 0);
    } else {
        uint8_t buf[128];
        CHECK(want < sizeof buf);
        CHECK(p_komira_last_error_code(ctx, NULL, 0, &n) == KOMIRA_ERR_BUFFER_TOO_SMALL);
        CHECK(n == want);
        memset(buf, 0xAB, sizeof buf);
        n = 0;
        CHECK(p_komira_last_error_code(ctx, buf, want - 1, &n) == KOMIRA_ERR_BUFFER_TOO_SMALL);
        CHECK(n == want && buf[0] == 0xAB);
        n = 0;
        CHECK(p_komira_last_error_code(ctx, buf, want, &n) == KOMIRA_OK);
        CHECK(n == want && memcmp(buf, code, want) == 0 && buf[want] == 0xAB);
    }
    last_error_text(ctx, after, sizeof after);
    CHECK(strcmp(before, after) == 0);
    CHECK(p_komira_last_error_step(ctx) == step);
}

static int starts_with(const char *text, const char *prefix) {
    return strncmp(text, prefix, strlen(prefix)) == 0;
}

/* `komira_sql_stream(ctx, sql, ...)` refused with `want`: *out is left as the
   driver wrote it, and the last error is `error` when `exact`, or starts with
   it, with step `step` and code `code`. Then a good query on the same context still answers. */
static void expect_refused(komira_handle ctx, const char *sql, int32_t want, const char *error, int exact, int32_t step, const char *code) {
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
    expect_error_step_code(ctx, step, code);
    struct answer a;
    CHECK(p_komira_sql_stream(ctx, "SELECT 1 AS n", &out) == KOMIRA_OK);
    CHECK(read_answer(&out, &a) == 0 && a.rows == 1 && a.n_values == 1 && a.values[0] == 1);
}

/* The last error of a run its handle cancelled before the call. */
static const char cancelled_text[] =
    "QUERY_CANCELLED: execute: pipeline_exec: the query was cancelled: the caller cancelled the run";

/* The progress of `run`, which the call must answer. */
static void progress_of(komira_handle run, uint64_t *done, uint64_t *total) {
    *done = 99;
    *total = 0;
    CHECK(p_komira_run_progress(run, done, total) == KOMIRA_OK);
    CHECK(*done <= *total);
}

/* One komira_sql_stream_run on a thread of its own. */
struct run_job {
    komira_handle ctx;
    komira_handle run;
    const char *sql;
    struct ArrowArrayStream out;
    int32_t rc;
    int finished;
};

static void *run_job_main(void *arg) {
    struct run_job *j = arg;
    j->rc = p_komira_sql_stream_run(j->ctx, j->sql, j->run, &j->out);
    __atomic_store_n(&j->finished, 1, __ATOMIC_RELEASE);
    return NULL;
}

static int start_job(struct run_job *j, pthread_t *thread, komira_handle ctx, komira_handle run, const char *sql) {
    memset(j, 0, sizeof *j);
    memset(&j->out, 0xAB, sizeof j->out);
    j->ctx = ctx;
    j->run = run;
    j->sql = sql;
    int started = pthread_create(thread, NULL, run_job_main, j) == 0;
    CHECK(started);
    return started;
}

/* The run handle: cancel and progress. `ctx` has the table `three` (k = 1, 2,
   3) registered. */
static void run_cases(komira_handle ctx) {
    struct ArrowArrayStream out, before;
    struct answer a;
    char text[512];
    uint64_t done = 0, total = 0;

    /* NULL handles and slots are refused and nothing is written. */
    komira_handle run = p_komira_run_new();
    CHECK(run != NULL);
    if (run == NULL) return;
    CHECK(p_komira_run_cancel(NULL) == KOMIRA_ERR_NULL_ARG);
    done = 7;
    total = 7;
    CHECK(p_komira_run_progress(NULL, &done, &total) == KOMIRA_ERR_NULL_ARG);
    CHECK(p_komira_run_progress(run, NULL, &total) == KOMIRA_ERR_NULL_ARG);
    CHECK(p_komira_run_progress(run, &done, NULL) == KOMIRA_ERR_NULL_ARG);
    CHECK(done == 7 && total == 7);
    memset(&out, 0xAB, sizeof out);
    memcpy(&before, &out, sizeof out);
    CHECK(p_komira_sql_stream_run(NULL, "SELECT 1 AS n", run, &out) == KOMIRA_ERR_NULL_CTX);
    CHECK(p_komira_sql_stream_run(ctx, "SELECT 1 AS n", NULL, &out) == KOMIRA_ERR_NULL_ARG);
    CHECK(strcmp(last_error_text(ctx, text, sizeof text), "komira_sql_stream_run: sql, run or out is NULL") == 0);
    CHECK(p_komira_sql_stream_run(ctx, NULL, run, &out) == KOMIRA_ERR_NULL_ARG);
    CHECK(p_komira_sql_stream_run(ctx, "SELECT 1 AS n", run, NULL) == KOMIRA_ERR_NULL_ARG);
    CHECK(memcmp(&out, &before, sizeof out) == 0);

    /* A fresh handle reads 0 of 0; a run nobody cancels answers, and leaves
       every segment it counted done. */
    progress_of(run, &done, &total);
    CHECK(done == 0 && total == 0);
    CHECK(p_komira_sql_stream_run(ctx, "SELECT k FROM three ORDER BY k", run, &out) == KOMIRA_OK);
    CHECK(read_answer(&out, &a) == 0);
    CHECK(a.rows == 3 && a.n_values == 3 && a.values[0] == 1 && a.values[2] == 3);
    uint64_t len = 99;
    CHECK(p_komira_last_error(ctx, NULL, 0, &len) == KOMIRA_OK && len == 0);
    uint64_t first = 0;
    progress_of(run, &done, &first);
    CHECK(first > 0 && done == first);
    /* A second run given the same handle adds to its counts. */
    CHECK(p_komira_sql_stream_run(ctx, "SELECT k FROM three ORDER BY k", run, &out) == KOMIRA_OK);
    CHECK(read_answer(&out, &a) == 0 && a.rows == 3);
    progress_of(run, &done, &total);
    CHECK(total == 2 * first && done == total);

    /* Cancelled before the call: the run is refused with -6, *out untouched,
       the named error word for word; it counted its segments and finished
       none. A second cancel is accepted and changes nothing. */
    CHECK(p_komira_run_cancel(run) == KOMIRA_OK);
    CHECK(p_komira_run_cancel(run) == KOMIRA_OK);
    uint64_t done_before = done, total_before = total;
    memset(&out, 0xAB, sizeof out);
    memcpy(&before, &out, sizeof out);
    int32_t rc = p_komira_sql_stream_run(ctx, "SELECT k FROM three ORDER BY k", run, &out);
    if (rc != KOMIRA_ERR_CANCELLED) fprintf(stderr, "FAIL: a cancelled run returned %d\n", rc);
    CHECK(rc == KOMIRA_ERR_CANCELLED);
    CHECK(memcmp(&out, &before, sizeof out) == 0);
    const char *got = last_error_text(ctx, text, sizeof text);
    if (strcmp(got, cancelled_text) != 0) fprintf(stderr, "FAIL: last error '%s'\n", got);
    CHECK(strcmp(got, cancelled_text) == 0);
    progress_of(run, &done, &total);
    CHECK(done == done_before && total > total_before);
    /* A statement refused before its plan runs keeps its own refusal. */
    CHECK(p_komira_sql_stream_run(ctx, "SELECT * FROM nosuch", run, &out) == KOMIRA_ERR_ENGINE);
    CHECK(starts_with(last_error_text(ctx, text, sizeof text), "bind: "));
    /* The context answers the next query, with or without a handle. */
    CHECK(p_komira_sql_stream(ctx, "SELECT 1 AS n", &out) == KOMIRA_OK);
    CHECK(read_answer(&out, &a) == 0 && a.rows == 1 && a.values[0] == 1);
    komira_handle fresh = p_komira_run_new();
    CHECK(fresh != NULL && fresh != run);
    CHECK(p_komira_sql_stream_run(ctx, "SELECT 1 AS n", fresh, &out) == KOMIRA_OK);
    CHECK(read_answer(&out, &a) == 0 && a.rows == 1 && a.values[0] == 1);
    p_komira_run_free(fresh);
    p_komira_run_free(run);
    p_komira_run_free(NULL);

    /* Progress read from this thread while the run is in flight on another:
       every reading has done at most total, and none is below the one before. */
    struct run_job job;
    pthread_t thread;
    run = p_komira_run_new();
    CHECK(run != NULL);
    if (run == NULL) return;
    if (start_job(&job, &thread, ctx, run, "SELECT k FROM three WHERE k >= 2 ORDER BY k")) {
        uint64_t last_done = 0, last_total = 0;
        long readings = 0;
        int finished = 0;
        do {
            finished = __atomic_load_n(&job.finished, __ATOMIC_ACQUIRE);
            progress_of(run, &done, &total);
            CHECK(done >= last_done && total >= last_total);
            last_done = done;
            last_total = total;
            readings++;
        } while (!finished);
        pthread_join(thread, NULL);
        CHECK(readings > 0);
        CHECK(job.rc == KOMIRA_OK);
        if (job.rc == KOMIRA_OK) {
            CHECK(read_answer(&job.out, &a) == 0);
            CHECK(a.rows == 2 && a.n_values == 2 && a.values[0] == 2 && a.values[1] == 3);
        }
        /* The reading after the run's end is its last: every segment done. */
        CHECK(done == total && total > 0);
    }
    p_komira_run_free(run);

    /* A cancel from this thread while the run is in flight on another: it
       lands before the run's last check (-6, *out untouched, the named error)
       or after it (the answer). The context answers the next query either
       way. */
    run = p_komira_run_new();
    CHECK(run != NULL);
    if (run == NULL) return;
    if (start_job(&job, &thread, ctx, run, "SELECT k FROM three ORDER BY k")) {
        CHECK(p_komira_run_cancel(run) == KOMIRA_OK);
        pthread_join(thread, NULL);
        CHECK(job.rc == KOMIRA_OK || job.rc == KOMIRA_ERR_CANCELLED);
        if (job.rc == KOMIRA_OK) {
            CHECK(read_answer(&job.out, &a) == 0 && a.rows == 3);
        } else {
            uint8_t sentinel[sizeof job.out];
            memset(sentinel, 0xAB, sizeof sentinel);
            CHECK(memcmp(&job.out, sentinel, sizeof sentinel) == 0);
            CHECK(starts_with(last_error_text(ctx, text, sizeof text), "QUERY_CANCELLED: execute: "));
        }
    }
    p_komira_run_free(run);
    CHECK(p_komira_sql_stream(ctx, "SELECT k FROM three ORDER BY k", &out) == KOMIRA_OK);
    CHECK(read_answer(&out, &a) == 0 && a.rows == 3);
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
    expect_refused(ctx, NULL, KOMIRA_ERR_NULL_ARG, "komira_sql_stream: sql or out is NULL", 1, KOMIRA_STEP_NONE, "");
    expect_refused(ctx, "SELEC 1", KOMIRA_ERR_ENGINE, "parse: SQL syntax error: ", 0, KOMIRA_STEP_PARSE, "SQL_SYNTAX_ERROR");
    CHECK(p_komira_sql_stream(ctx, "SELECT * FROM nosuch", &out) == KOMIRA_ERR_ENGINE);
    CHECK(strstr(last_error_text(ctx, text, sizeof text), "nosuch") != NULL);
    expect_refused(ctx, "SELECT * FROM nosuch", KOMIRA_ERR_ENGINE, "bind: SQL bind error: unknown table 'nosuch'", 1, KOMIRA_STEP_BIND, "SQL_BIND_ERROR");
    expect_refused(ctx, "SELECT '\xff' AS s", KOMIRA_ERR_ENGINE, "komira_sql_stream: the SQL text is not valid UTF-8", 1, KOMIRA_STEP_NONE, "");
    expect_refused(ctx, "SELECT k FROM three INTERSECT ALL SELECT k FROM three", KOMIRA_ERR_ENGINE, "parse: SQL not supported: INTERSECT ALL. ", 0, KOMIRA_STEP_PARSE, "SQL_NOT_SUPPORTED");
    /* A success clears the previous error: step NONE, no code. */
    CHECK(p_komira_sql_stream(ctx, "SELEC 1", &out) == KOMIRA_ERR_ENGINE);
    CHECK(p_komira_sql_stream(ctx, "SELECT 1 AS n", &out) == KOMIRA_OK);
    expect_error_step_code(ctx, KOMIRA_STEP_NONE, "");
    CHECK(read_answer(&out, &a) == 0);
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
        expect_refused(ctx, big, KOMIRA_ERR_TOO_LARGE, msg, 1, KOMIRA_STEP_NONE, "");
        free(big);
    }

    run_cases(ctx);

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

/* A producer of struct ArrowArrayStream, as a host's Arrow library is one:
   up to two chunks of three rows, `id` int64 (1..6) and `s` utf8 of two
   characters ("an", "bo", "cy", "de", "ev", "fi"), from one heap block the
   producer owns. Its callbacks count what the library does with them. */
struct producer {
    int n_chunks;        /* chunks get_next hands out before the end */
    int next;            /* chunks handed out so far */
    int fail_schema;     /* get_schema fails */
    int fail_at;         /* get_next fails at this chunk, -1 never */
    int null_column;     /* the schema's second column is of the Null type */
    int schema_calls, stream_releases, schema_releases, chunk_releases;
    char error[64];
    struct data {
        int64_t ids[6];
        int32_t offsets[4];
        char chars[12];
    } *data;
};

static void producer_init(struct producer *p, int n_chunks) {
    memset(p, 0, sizeof *p);
    p->n_chunks = n_chunks;
    p->fail_at = -1;
    p->data = calloc(1, sizeof *p->data);
    for (int i = 0; i < 6; i++) p->data->ids[i] = i + 1;
    for (int i = 0; i < 4; i++) p->data->offsets[i] = 2 * i;
    memcpy(p->data->chars, "anbocydeevfi", 12);
}

/* Overwrite and free the producer's rows: a table that still answers after
   this holds its own copy. */
static void producer_drop_data(struct producer *p) {
    memset(p->data, 0xFF, sizeof *p->data);
    free(p->data);
    p->data = NULL;
}

struct schema_owner {
    struct producer *p;
    struct ArrowSchema *children[2];
};

static void release_leaf_schema(struct ArrowSchema *s) { s->release = NULL; }

static void release_root_schema(struct ArrowSchema *s) {
    struct schema_owner *o = s->private_data;
    o->p->schema_releases++;
    for (int i = 0; i < 2; i++) {
        if (o->children[i]->release != NULL) o->children[i]->release(o->children[i]);
        free(o->children[i]);
    }
    free(o);
    s->release = NULL;
}

static struct ArrowSchema *leaf_schema(const char *name, const char *format) {
    struct ArrowSchema *f = calloc(1, sizeof *f);
    f->format = format;
    f->name = name;
    f->flags = ARROW_FLAG_NULLABLE;
    f->release = release_leaf_schema;
    return f;
}

static int producer_get_schema(struct ArrowArrayStream *s, struct ArrowSchema *out) {
    struct producer *p = s->private_data;
    p->schema_calls++;
    if (p->fail_schema) {
        snprintf(p->error, sizeof p->error, "producer: schema refused");
        return 5;
    }
    struct schema_owner *o = calloc(1, sizeof *o);
    o->p = p;
    o->children[0] = leaf_schema("id", "l");
    o->children[1] = leaf_schema(p->null_column ? "nothing" : "s", p->null_column ? "n" : "u");
    memset(out, 0, sizeof *out);
    out->format = "+s";
    out->name = "";
    out->n_children = 2;
    out->children = o->children;
    out->private_data = o;
    out->release = release_root_schema;
    return 0;
}

struct chunk_owner {
    struct producer *p;
    struct ArrowArray *children[2];
    const void *root_buffers[1], *id_buffers[2], *s_buffers[3];
};

static void release_leaf_array(struct ArrowArray *a) { a->release = NULL; }

static void release_chunk(struct ArrowArray *a) {
    struct chunk_owner *o = a->private_data;
    o->p->chunk_releases++;
    for (int i = 0; i < 2; i++) {
        if (o->children[i]->release != NULL) o->children[i]->release(o->children[i]);
        free(o->children[i]);
    }
    free(o);
    a->release = NULL;
}

static int producer_get_next(struct ArrowArrayStream *s, struct ArrowArray *out) {
    struct producer *p = s->private_data;
    if (p->next == p->fail_at) {
        snprintf(p->error, sizeof p->error, "producer: chunk %d refused", p->next);
        return 5;
    }
    memset(out, 0, sizeof *out);
    if (p->next == p->n_chunks) return 0; /* the end: release stays NULL */
    int k = p->next++;
    struct chunk_owner *o = calloc(1, sizeof *o);
    o->p = p;
    o->id_buffers[1] = p->data->ids + 3 * k;
    o->s_buffers[1] = p->data->offsets;
    o->s_buffers[2] = p->data->chars + 6 * k;
    const void **buffers[2] = {o->id_buffers, o->s_buffers};
    for (int i = 0; i < 2; i++) {
        struct ArrowArray *c = calloc(1, sizeof *c);
        c->length = 3;
        c->n_buffers = i == 0 ? 2 : 3;
        c->buffers = buffers[i];
        c->release = release_leaf_array;
        o->children[i] = c;
    }
    out->length = 3;
    out->n_buffers = 1;
    out->buffers = o->root_buffers;
    out->n_children = 2;
    out->children = o->children;
    out->private_data = o;
    out->release = release_chunk;
    return 0;
}

static const char *producer_last_error(struct ArrowArrayStream *s) {
    return ((struct producer *)s->private_data)->error;
}

static void producer_release(struct ArrowArrayStream *s) {
    ((struct producer *)s->private_data)->stream_releases++;
    s->release = NULL;
}

static void producer_stream(struct ArrowArrayStream *s, struct producer *p) {
    s->get_schema = producer_get_schema;
    s->get_next = producer_get_next;
    s->get_last_error = producer_last_error;
    s->release = producer_release;
    s->private_data = p;
}

/* Hand a fresh producer's stream of `n_chunks` to the library under `name`,
   with the producer's failure switches set as given, then check the stream is
   released and drop the producer's rows. Returns the call's status. */
static int32_t register_stream(komira_handle ctx, const char *name, struct producer *p, int n_chunks,
                               int fail_schema, int fail_at, int null_column) {
    struct ArrowArrayStream s;
    producer_init(p, n_chunks);
    p->fail_schema = fail_schema;
    p->fail_at = fail_at;
    p->null_column = null_column;
    producer_stream(&s, p);
    int32_t rc = p_komira_register_arrow_stream(ctx, name, &s);
    CHECK(s.release == NULL);
    producer_drop_data(p);
    return rc;
}

/* komira_register_arrow_stream: streams of this file's producer, drained into
   tables of the session, each release counted. */
static void arrow_stream_cases(void) {
    const char *tmp = getenv("TEST_TMPDIR");
    if (tmp == NULL) return; /* text_source_cases has already failed on it */
    komira_handle ctx = p_komira_ctx_new();
    CHECK(ctx != NULL);
    if (ctx == NULL) return;
    struct producer p;
    struct answer a;
    char text[512], people[512];
    if (write_file(tmp, "people.csv", "id,name,score\n1,ann,10\n2,bob,20\n3,cy,30\n", people, sizeof people) != 0) return;

    /* Two chunks: the stream, its schema and each chunk released once, and
       the rows answer after the producer's buffers are overwritten and freed. */
    CHECK(register_stream(ctx, "rows", &p, 2, 0, -1, 0) == KOMIRA_OK);
    CHECK(p.schema_calls == 1 && p.stream_releases == 1 && p.schema_releases == 1 && p.chunk_releases == 2);
    uint64_t len = 99;
    CHECK(p_komira_last_error(ctx, NULL, 0, &len) == KOMIRA_OK && len == 0);
    if (query(ctx, "SELECT id, s FROM ROWS ORDER BY id", &a) == 0) {
        CHECK(a.n_fields == 2 && strcmp(a.names[1], "s") == 0 && strcmp(a.formats[0], "l") == 0 && strcmp(a.formats[1], "u") == 0);
        CHECK(a.rows == 6 && a.n_values == 6 && a.values[0] == 1 && a.values[5] == 6);
    }
    if (query(ctx, "SELECT id FROM rows WHERE s = 'ev'", &a) == 0) {
        CHECK(a.rows == 1 && a.n_values == 1 && a.values[0] == 5);
    }
    if (query(ctx, "SELECT max(id) AS m FROM rows WHERE id < 4", &a) == 0) {
        CHECK(a.rows == 1 && a.n_values == 1 && a.values[0] == 3);
    }
    /* A join with a registered CSV file: ids 1..3 are both tables'. */
    CHECK(p_komira_register_csv(ctx, "people", people, ',', 1, 0) == KOMIRA_OK);
    if (query(ctx, "SELECT r.id FROM rows r JOIN people p ON r.id = p.id WHERE p.score >= 20 ORDER BY r.id", &a) == 0) {
        CHECK(a.rows == 2 && a.n_values == 2 && a.values[0] == 2 && a.values[1] == 3);
    }

    /* A stream of no chunk: a table of no row with the stream's schema. */
    CHECK(register_stream(ctx, "none_yet", &p, 0, 0, -1, 0) == KOMIRA_OK);
    CHECK(p.stream_releases == 1 && p.schema_releases == 1 && p.chunk_releases == 0);
    if (query(ctx, "SELECT id, s FROM none_yet", &a) == 0) {
        CHECK(a.n_fields == 2 && strcmp(a.formats[1], "u") == 0 && a.rows == 0);
    }
    if (query(ctx, "SELECT count(*) AS n FROM none_yet", &a) == 0) {
        CHECK(a.rows == 1 && a.n_values == 1 && a.values[0] == 0);
    }

    /* A second registration of a name replaces its table, a CSV one too. */
    CHECK(register_stream(ctx, "Rows", &p, 1, 0, -1, 0) == KOMIRA_OK);
    if (query(ctx, "SELECT count(*) AS n FROM rows", &a) == 0) {
        CHECK(a.rows == 1 && a.n_values == 1 && a.values[0] == 3);
    }
    CHECK(register_stream(ctx, "people", &p, 2, 0, -1, 0) == KOMIRA_OK);
    if (query(ctx, "SELECT count(*) AS n FROM people", &a) == 0) {
        CHECK(a.rows == 1 && a.n_values == 1 && a.values[0] == 6);
    }
    CHECK(p_komira_register_csv(ctx, "rows", people, ',', 1, 0) == KOMIRA_ERR_ENGINE);
    CHECK(strcmp(last_error_text(ctx, text, sizeof text),
                 "TABLE_ALREADY_REGISTERED: the session already has a table named 'rows'") == 0);

    /* Refusals: each releases the stream once, names its reason word for word
       and replaces nothing; `rows` keeps its three rows. */
    CHECK(register_stream(ctx, "rows", &p, 2, 1, -1, 0) == KOMIRA_ERR_ENGINE);
    CHECK(strcmp(last_error_text(ctx, text, sizeof text),
                 "from_arrow_c_stream: get_schema failed (rc=5): producer: schema refused") == 0);
    CHECK(p.stream_releases == 1 && p.schema_releases == 0 && p.chunk_releases == 0);
    CHECK(register_stream(ctx, "rows", &p, 2, 0, 1, 0) == KOMIRA_ERR_ENGINE);
    CHECK(strcmp(last_error_text(ctx, text, sizeof text),
                 "from_arrow_c_stream: get_next failed (rc=5): producer: chunk 1 refused") == 0);
    CHECK(p.stream_releases == 1 && p.schema_releases == 1 && p.chunk_releases == 1);
    CHECK(register_stream(ctx, "rows", &p, 2, 0, -1, 1) == KOMIRA_ERR_ENGINE);
    CHECK(strcmp(last_error_text(ctx, text, sizeof text),
                 "UnsupportedArrowCABIType: the Null type ('n') is not in the supported drain subset") == 0);
    CHECK(p.stream_releases == 1 && p.schema_releases == 1 && p.chunk_releases == 0);
    if (query(ctx, "SELECT count(*) AS n FROM rows", &a) == 0) {
        CHECK(a.rows == 1 && a.n_values == 1 && a.values[0] == 3);
    }
    /* Refused before the stream is read: released once, get_schema never
       called. */
    CHECK(register_stream(ctx, "", &p, 2, 0, -1, 0) == KOMIRA_ERR_ENGINE);
    CHECK(strcmp(last_error_text(ctx, text, sizeof text), "TABLE_NAME_EMPTY: a table name must not be empty") == 0);
    CHECK(p_komira_last_error_step(ctx) == KOMIRA_STEP_BIND); /* a registration's refusal, as komira_register_csv's */
    CHECK(p.schema_calls == 0 && p.stream_releases == 1);
    CHECK(register_stream(ctx, NULL, &p, 2, 0, -1, 0) == KOMIRA_ERR_NULL_ARG);
    CHECK(strcmp(last_error_text(ctx, text, sizeof text), "komira_register_arrow_stream: name or stream is NULL") == 0);
    CHECK(p.schema_calls == 0 && p.stream_releases == 1);
    CHECK(register_stream(NULL, "t", &p, 2, 0, -1, 0) == KOMIRA_ERR_NULL_CTX);
    CHECK(p.schema_calls == 0 && p.stream_releases == 1);
    CHECK(p_komira_register_arrow_stream(ctx, "t", NULL) == KOMIRA_ERR_NULL_ARG);
    {
        struct ArrowArrayStream released;
        memset(&released, 0, sizeof released);
        CHECK(p_komira_register_arrow_stream(ctx, "t", &released) == KOMIRA_ERR_ENGINE);
        CHECK(strcmp(last_error_text(ctx, text, sizeof text), "from_arrow_c_stream: stream is already released") == 0);
    }
    /* A refused name stays free. */
    CHECK(register_stream(ctx, "t", &p, 1, 0, -1, 0) == KOMIRA_OK);
    CHECK(p_komira_last_error(ctx, NULL, 0, &len) == KOMIRA_OK && len == 0);
    if (query(ctx, "SELECT count(*) AS n FROM t", &a) == 0) {
        CHECK(a.rows == 1 && a.n_values == 1 && a.values[0] == 3);
    }
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
        expect_refused(tiny, sum, KOMIRA_ERR_ENGINE, "execute: [Processor] MEMORY_BUDGET_EXCEEDED: pipeline_exec: the ", 0, KOMIRA_STEP_EXECUTE,
                       "MEMORY_BUDGET_EXCEEDED");
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

/* The plan cases of komira_plan_stream, in a file of their own so that each
   file stays under 1000 lines. */
#include "plan_cases.h"

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

    /* A fresh session: step NONE, no code. A NULL context is -1 for the code
       and step NONE; a NULL out_len is -2. */
    expect_error_step_code(ctx, KOMIRA_STEP_NONE, "");
    CHECK(p_komira_last_error_step(NULL) == KOMIRA_STEP_NONE);
    CHECK(p_komira_last_error_code(NULL, NULL, 0, &len) == KOMIRA_ERR_NULL_CTX);

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
    expect_error_step_code(other, KOMIRA_STEP_NONE, "");
    /* A failed registration is a bind failure with no code. */
    expect_error_step_code(ctx, KOMIRA_STEP_BIND, "");
    /* A NULL out_len of the code call is -2, stores its own refusal and, like
       komira_last_error's, replaces the held error; a NULL out_buf with bytes
       to write is -2 too. */
    CHECK(p_komira_last_error_code(ctx, NULL, 0, NULL) == KOMIRA_ERR_NULL_ARG);
    {
        char refused[512];
        CHECK(strcmp(last_error_text(ctx, refused, sizeof refused), "komira_last_error_code: out_len is NULL") == 0);
    }
    expect_error_step_code(ctx, KOMIRA_STEP_NONE, "");

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
    expect_error_step_code(ctx, KOMIRA_STEP_BIND, "CREDENTIALS_INVALID");
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
    /* A refusal of a NULL argument has no step and no code. */
    CHECK(p_komira_credential_add(ctx, KOMIRA_CRED_AWS_KEYS, "raw-etl", NULL) == KOMIRA_ERR_NULL_ARG);
    expect_error_step_code(ctx, KOMIRA_STEP_NONE, "");
    /* A NULL out_buf with a code to write is -2. */
    CHECK(p_komira_register_parquet(ctx, "t", "no_such_file.parquet") == KOMIRA_ERR_ENGINE);
    CHECK(p_komira_credential_seal(ctx, 99, KOMIRA_BIND_SESSION) == KOMIRA_ERR_ENGINE);
    CHECK(p_komira_last_error_code(ctx, NULL, 19, &again) == KOMIRA_ERR_NULL_ARG);
    CHECK(again == 19);

    p_komira_ctx_free(ctx);
    p_komira_ctx_free(other);
    p_komira_ctx_free(NULL);

    sql_stream_cases();
    text_source_cases();
    options_cases();
    plan_stream_cases();
    arrow_stream_cases();
    return failures == 0 ? 0 : 1;
}
