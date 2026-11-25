/* The plan cases of komira_plan_stream, part of the C driver abi_driver.c.
 *
 * abi_driver.c includes this file once, after its own helpers (CHECK, the
 * bound function pointers, struct answer, read_answer, last_error_text,
 * expect_error_step_code and starts_with), and calls plan_stream_cases() from main. It is a header only
 * in name: it holds the definitions, and nothing else includes it.
 *
 * The driver encodes a WirePlanEnvelope by hand (src/plan_proto/plan.proto),
 * a scan of a Parquet file whose schema is the bytes komira_parquet_schema
 * answers, runs it on a context with no table registered, and holds the
 * answer to what komira_sql_stream answers for the same file. Each refusal's
 * step (komira_last_error_step) is held too: KOMIRA_STEP_LOWER for a plan
 * refused at lower, KOMIRA_STEP_NONE for one refused at decode or for its
 * arguments; a plan that answers leaves no step and no code. */
#ifndef KOMIRA_ABI_DRIVER_PLAN_CASES_H
#define KOMIRA_ABI_DRIVER_PLAN_CASES_H

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
                                const char *error, int exact, int32_t step, const struct buf *good,
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
    int32_t got_step = p_komira_last_error_step(ctx);
    if (got_step != step) fprintf(stderr, "FAIL: last error step %d, want %d\n", got_step, step);
    CHECK(got_step == step);
    struct answer a;
    CHECK(p_komira_plan_stream(ctx, good->p, good->n, &out) == KOMIRA_OK);
    CHECK(read_answer(&out, &a) == 0 && same_answer(&a, expect));
    /* A plan that answers clears the error, its step and its code. */
    expect_error_step_code(ctx, KOMIRA_STEP_NONE, "");
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
    expect_plan_refused(ctx, (const uint8_t *)select1, sizeof select1 - 1, KOMIRA_ERR_ENGINE, "decode: ", 0, KOMIRA_STEP_NONE,
                        &plan, &by_sql);
    expect_plan_refused(ctx, garbage, sizeof garbage, KOMIRA_ERR_ENGINE, "decode: ", 0, KOMIRA_STEP_NONE, &plan, &by_sql);
    {
        /* A version this build does not speak. */
        struct buf v3 = {0};
        scan_envelope(&v3, 3, parquet, schema.p, schema.n);
        expect_plan_refused(ctx, v3.p, v3.n, KOMIRA_ERR_ENGINE, "decode: ", 0, KOMIRA_STEP_NONE, &plan, &by_sql);
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
        expect_plan_refused(ctx, gone.p, gone.n, KOMIRA_ERR_ENGINE, "lower: ", 0, KOMIRA_STEP_LOWER, &plan, &by_sql);
        free(gone.p);
    }
    expect_plan_refused(ctx, NULL, plan.n, KOMIRA_ERR_NULL_ARG, "komira_plan_stream: plan or out is NULL", 1, KOMIRA_STEP_NONE,
                        &plan, &by_sql);
    {
        char msg[128];
        snprintf(msg, sizeof msg, "komira_plan_stream: plan_len is above %llu bytes",
                 (unsigned long long)KOMIRA_MAX_INPUT_BYTES);
        /* The pointer is a 3-byte buffer: a length past the bound is refused
           before any byte is read. */
        expect_plan_refused(ctx, garbage, (uint64_t)KOMIRA_MAX_INPUT_BYTES + 1, KOMIRA_ERR_TOO_LARGE, msg, 1, KOMIRA_STEP_NONE, &plan,
                            &by_sql);
        expect_plan_refused(ctx, garbage, UINT64_MAX, KOMIRA_ERR_TOO_LARGE, msg, 1, KOMIRA_STEP_NONE, &plan, &by_sql);
    }
    {
        /* Exactly the bound is read: being garbage, it is the decoder's -3. */
        uint8_t *big = malloc((size_t)KOMIRA_MAX_INPUT_BYTES);
        CHECK(big != NULL);
        if (big != NULL) {
            memset(big, 0xFF, (size_t)KOMIRA_MAX_INPUT_BYTES);
            expect_plan_refused(ctx, big, (uint64_t)KOMIRA_MAX_INPUT_BYTES, KOMIRA_ERR_ENGINE, "decode: ", 0, KOMIRA_STEP_NONE, &plan,
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

#endif /* KOMIRA_ABI_DRIVER_PLAN_CASES_H */
