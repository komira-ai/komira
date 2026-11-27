/* The cases of komira_add_sql_binding, part of the C driver abi_driver.c.
 *
 * abi_driver.c includes this file once, after plan_cases.h, and calls
 * binding_cases() from main. It uses what the driver and plan_cases.h define
 * (CHECK, the bound function pointers, struct answer, query, last_error_text,
 * expect_error_step_code, write_file and the struct buf writers put_bytes and
 * buf_put); nothing else includes it.
 *
 * The driver encodes a WireBoundSource (src/plan_proto/bound_source.proto) by
 * hand, WireBoundSource{1 files}, WireFileSource{1 location}, with the path of
 * a local Parquet file: two_columns.parquet, staged beside the driver (no row),
 * and a three-row file it writes with COPY. It binds a table through
 * komira_add_sql_binding and reads it through komira_sql_stream; binding a
 * name again replaces the table, so the second source answers. Each refusal is
 * held to its status, its last error word for word, its step and its code, and
 * to leaving the earlier table as it was. */
#ifndef KOMIRA_ABI_DRIVER_BINDING_CASES_H
#define KOMIRA_ABI_DRIVER_BINDING_CASES_H

/* The bytes of WireBoundSource{files{location = path}}, in `out`. */
static void files_source(struct buf *out, const char *path) {
    struct buf file = {0};
    put_bytes(&file, 1, path, strlen(path));
    put_bytes(out, 1, file.p, file.n);
    free(file.p);
}

/* count(*) of `table` on `ctx` is `want`. */
static void expect_count(komira_handle ctx, const char *table, int64_t want) {
    char sql[256];
    struct answer a;
    snprintf(sql, sizeof sql, "SELECT count(*) AS n FROM %s", table);
    if (query(ctx, sql, &a) == 0) {
        CHECK(a.n_fields == 1 && strcmp(a.names[0], "n") == 0 && strcmp(a.formats[0], "l") == 0);
        CHECK(a.rows == 1 && a.n_values == 1 && a.values[0] == want);
    }
}

/* `komira_add_sql_binding(ctx, name, src, n, scope)` is refused with the
   engine's -3: the last error is `error` word for word, with step bind and
   code `code`. */
static void expect_bind_refused(komira_handle ctx, const char *name, const uint8_t *src, uint64_t n, int32_t scope,
                                const char *error, const char *code) {
    char text[512];
    int32_t rc = p_komira_add_sql_binding(ctx, name, src, n, scope);
    if (rc != KOMIRA_ERR_ENGINE) fprintf(stderr, "FAIL: komira_add_sql_binding returned %d, want %d\n", rc, KOMIRA_ERR_ENGINE);
    CHECK(rc == KOMIRA_ERR_ENGINE);
    const char *got = last_error_text(ctx, text, sizeof text);
    if (strcmp(got, error) != 0) fprintf(stderr, "FAIL: last error '%s', want '%s'\n", got, error);
    CHECK(strcmp(got, error) == 0);
    expect_error_step_code(ctx, KOMIRA_STEP_BIND, code);
}

static void binding_cases(void) {
    const char *tmp = getenv("TEST_TMPDIR");
    CHECK(tmp != NULL && tmp[0] != 0);
    if (tmp == NULL) return;
    komira_handle ctx = p_komira_ctx_new();
    CHECK(ctx != NULL);
    if (ctx == NULL) return;
    struct ArrowArrayStream out;
    struct answer a;
    char text[512], sql[1024], csv[512], three[512];

    /* The two sources: the fixture of no row, and a file of three rows. */
    snprintf(csv, sizeof csv, "%s/bound_three.csv", tmp);
    snprintf(three, sizeof three, "%s/bound_three.parquet", tmp);
    if (write_file(tmp, "bound_three.csv", "k\n1\n2\n3\n", csv, sizeof csv) != 0) return;
    snprintf(sql, sizeof sql, "COPY (SELECT k FROM read_csv('%s')) TO '%s'", csv, three);
    CHECK(p_komira_sql_stream(ctx, sql, &out) == KOMIRA_OK);
    CHECK(read_answer(&out, &a) == 0 && a.rows == 1 && a.n_values == 1 && a.values[0] == 3);
    struct buf fixture = {0}, rows = {0};
    files_source(&fixture, "two_columns.parquet");
    files_source(&rows, three);

    /* A local file source binds, and SQL reads it by name (found without
       regard to case) as it reads a registered file. */
    CHECK(p_komira_add_sql_binding(ctx, "bound", fixture.p, fixture.n, KOMIRA_BIND_SESSION) == KOMIRA_OK);
    uint64_t len = 99;
    CHECK(p_komira_last_error(ctx, NULL, 0, &len) == KOMIRA_OK && len == 0);
    expect_count(ctx, "bound", 0);
    expect_count(ctx, "BOUND", 0);
    CHECK(p_komira_sql_stream(ctx, "SELECT i64, s FROM bound", &out) == KOMIRA_OK);
    CHECK(read_answer(&out, &a) == 0);
    CHECK(a.n_fields == 2 && strcmp(a.names[0], "i64") == 0 && strcmp(a.names[1], "s") == 0 && a.rows == 0);

    /* Binding the name again replaces the table: the second source answers. */
    CHECK(p_komira_add_sql_binding(ctx, "bound", rows.p, rows.n, KOMIRA_BIND_SESSION) == KOMIRA_OK);
    CHECK(p_komira_last_error(ctx, NULL, 0, &len) == KOMIRA_OK && len == 0);
    expect_count(ctx, "bound", 3);
    if (query(ctx, "SELECT k FROM bound WHERE k >= 2 ORDER BY k", &a) == 0) {
        CHECK(a.n_fields == 1 && strcmp(a.names[0], "k") == 0);
        CHECK(a.rows == 2 && a.n_values == 2 && a.values[0] == 2 && a.values[1] == 3);
    }
    /* ... and back to the first. */
    CHECK(p_komira_add_sql_binding(ctx, "bound", fixture.p, fixture.n, KOMIRA_BIND_SESSION) == KOMIRA_OK);
    expect_count(ctx, "bound", 0);
    CHECK(p_komira_add_sql_binding(ctx, "bound", rows.p, rows.n, KOMIRA_BIND_SESSION) == KOMIRA_OK);

    /* A NULL context is -1; a NULL name or source is -2 with its named last
       error and neither step nor code. */
    CHECK(p_komira_add_sql_binding(NULL, "bound", rows.p, rows.n, KOMIRA_BIND_SESSION) == KOMIRA_ERR_NULL_CTX);
    CHECK(p_komira_add_sql_binding(NULL, NULL, NULL, 0, 0) == KOMIRA_ERR_NULL_CTX);
    CHECK(p_komira_add_sql_binding(ctx, NULL, rows.p, rows.n, KOMIRA_BIND_SESSION) == KOMIRA_ERR_NULL_ARG);
    CHECK(strcmp(last_error_text(ctx, text, sizeof text), "komira_add_sql_binding: name or source is NULL") == 0);
    expect_error_step_code(ctx, KOMIRA_STEP_NONE, "");
    CHECK(p_komira_add_sql_binding(ctx, "bound", NULL, rows.n, KOMIRA_BIND_SESSION) == KOMIRA_ERR_NULL_ARG);
    CHECK(strcmp(last_error_text(ctx, text, sizeof text), "komira_add_sql_binding: name or source is NULL") == 0);
    CHECK(p_komira_add_sql_binding(ctx, "bound", NULL, 0, KOMIRA_BIND_SESSION) == KOMIRA_ERR_NULL_ARG);

    /* A length above the bound is -5, before any read of the source. */
    CHECK(p_komira_add_sql_binding(ctx, "bound", rows.p, (uint64_t)KOMIRA_MAX_INPUT_BYTES + 1, KOMIRA_BIND_SESSION) ==
          KOMIRA_ERR_TOO_LARGE);
    CHECK(strcmp(last_error_text(ctx, text, sizeof text), "komira_add_sql_binding: source_len is above 67108864 bytes") == 0);
    CHECK(p_komira_add_sql_binding(ctx, "bound", rows.p, UINT64_MAX, KOMIRA_BIND_SESSION) == KOMIRA_ERR_TOO_LARGE);

    /* The engine's refusals, each leaving the table `bound` as it was. */
    static const uint8_t tag_only[1] = {0x0A};
    static const uint8_t none[1] = {0};
    expect_bind_refused(ctx, "bound", fixture.p, fixture.n, 2,
                        "BIND_SCOPE_UNSUPPORTED: add_sql_binding scope=2: only KOMIRA_BIND_SESSION (1) binds a source",
                        "BIND_SCOPE_UNSUPPORTED");
    expect_bind_refused(ctx, "", fixture.p, fixture.n, KOMIRA_BIND_SESSION, "TABLE_NAME_EMPTY: a table name must not be empty",
                        "TABLE_NAME_EMPTY");
    expect_bind_refused(ctx, "bound", tag_only, sizeof tag_only, KOMIRA_BIND_SESSION,
                        "BIND_SOURCE_MALFORMED: add_sql_binding name=bound: the source is not a komira.plan.v1.WireBoundSource",
                        "BIND_SOURCE_MALFORMED");
    expect_bind_refused(ctx, "bound", none, 0, KOMIRA_BIND_SESSION,
                        "BIND_SOURCE_MALFORMED: add_sql_binding name=bound: the source names no kind", "BIND_SOURCE_MALFORMED");
    {
        struct buf gone = {0};
        char missing[512];
        snprintf(missing, sizeof missing, "%s/no_such_file.parquet", tmp);
        files_source(&gone, missing);
        CHECK(p_komira_add_sql_binding(ctx, "bound", gone.p, gone.n, KOMIRA_BIND_SESSION) == KOMIRA_ERR_ENGINE);
        CHECK(last_error_text(ctx, text, sizeof text)[0] != 0);
        CHECK(p_komira_last_error_step(ctx) == KOMIRA_STEP_BIND);
        free(gone.p);
    }
    expect_count(ctx, "bound", 3);

    /* A name that is not UTF-8 is refused before the source is read. */
    CHECK(p_komira_add_sql_binding(ctx, "b\xff", rows.p, rows.n, KOMIRA_BIND_SESSION) == KOMIRA_ERR_ENGINE);
    CHECK(strcmp(last_error_text(ctx, text, sizeof text), "a string argument is not valid UTF-8") == 0);

    /* A good call after a refusal leaves no error. */
    CHECK(p_komira_add_sql_binding(ctx, "bound", rows.p, rows.n, KOMIRA_BIND_SESSION) == KOMIRA_OK);
    CHECK(p_komira_last_error(ctx, NULL, 0, &len) == KOMIRA_OK && len == 0);
    expect_error_step_code(ctx, KOMIRA_STEP_NONE, "");

    free(fixture.p);
    free(rows.p);
    p_komira_ctx_free(ctx);
}

#endif
