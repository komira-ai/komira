# =============================================================================
# Direct tests of scalar-function binding: the function-table dispatch and
# the desugars (sql_bind_call, sql_bind_fn_args, sql_bind_fn_nested)
# =============================================================================
#
# What each test proves, and the defect (mutant) it would catch:
#   1. Each direct lowering kind builds its node: string / math functions,
#      the type-keeping unary numerics, the operator names (`add(x)` is x,
#      `subtract(x)` is -x, `divide` is `//`), date fields, two-argument
#      math, string predicates over a literal pattern (a column pattern is
#      refused), and the constant macros (arguments unbound, arity kept).
#      (mutant: the `n == 1` arm of FNK_BINARY_OP returns `-x` for `add`)
#   2. The family arity messages, the refused rows, and the unknown-function
#      message.
#      (mutant: the arity check in `_bind_scalar_call` deleted, so
#      `upper(s, s)` binds)
#   3. The n-ary string family and the regexp family: argument shapes,
#      options, group index bounds, literal-only patterns.
#      (mutant: `regexp_extract`'s group bound `> 9` changed to `> 10`)
#   4. The desugars: greatest / least, coalesce / ifnull (a NULL argument
#      dropped, all-NULL refused), date_part / date_trunc and their unit
#      refusals, left / right / substring, the year-derived parts,
#      nanosecond, the float classes, string_split, JSON / struct / map
#      extracts, date_diff / date_sub (fold vs column arm), even, fdiv /
#      fmod, nullif, days_in_month.
#      (mutants: `coalesce` keeps a NULL argument; `left(s, -n)` uses
#      `lr_n` instead of `lr_n - 1`; `struct_extract_at` keeps the 1-based
#      index)

from std.testing import TestSuite, assert_equal, assert_false, assert_true

from komira_arrow.arrow_types import ArrowType
from komira_arrow.record_batch import RecordBatch
from komira_arrow.schema import Field, Schema, SchemaBuilder

from komira_sql.sql_token import tokenize
from komira_sql.sql_parser import parse_sql
from komira_sql.sql_catalog import SqlCatalog
from komira_sql.sql_bind_parquet import NoParquetFooters, SqlParquetFooters
from komira_sql.sql_binder import bind_statement


def _two(
    mut cat: SqlCatalog,
    name: String,
    c0: String,
    t0: ArrowType,
    c1: String,
    t1: ArrowType,
):
    """Register parquet table `name`(c0 NOT NULL, c1 NULL)."""
    var sb = SchemaBuilder()
    sb.add_field(Field(c0, t0, False))
    sb.add_field(Field(c1, t1, True))
    cat.add_parquet(name, name + ".parquet", sb.build())


def _catalog() raises -> SqlCatalog:
    """t(k, v, s, g, d, ts, i32, dc, b, f32, u64, j), u(k, w, s), kk(k, a),
    mm(k, b), up(K, B), kk2(k, k_right): parquet tables with given schemas
    (no file is opened); mem(k, v): an empty in-memory table."""
    var cat = SqlCatalog()
    var t = SchemaBuilder()
    t.add_field(Field(String("k"), ArrowType.INT64, False))
    t.add_field(Field(String("v"), ArrowType.FLOAT64, True))
    t.add_field(Field(String("s"), ArrowType.STRING, True))
    t.add_field(Field(String("g"), ArrowType.INT64, True))
    t.add_field(Field(String("d"), ArrowType.DATE32, True))
    t.add_field(Field.timestamp(String("ts"), ArrowType.TIMESTAMP_US, String(""), True))
    t.add_field(Field(String("i32"), ArrowType.INT32, True))
    t.add_field(Field.decimal128(String("dc"), 12, 2, True))
    t.add_field(Field(String("b"), ArrowType.BOOL, True))
    t.add_field(Field(String("f32"), ArrowType.FLOAT32, True))
    t.add_field(Field(String("u64"), ArrowType.UINT64, True))
    t.add_field(Field(String("j"), ArrowType.STRING, True))
    cat.add_parquet(String("t"), String("t.parquet"), t.build())
    var u = SchemaBuilder()
    u.add_field(Field(String("k"), ArrowType.INT64, False))
    u.add_field(Field(String("w"), ArrowType.INT64, True))
    u.add_field(Field(String("s"), ArrowType.STRING, True))
    cat.add_parquet(String("u"), String("u.parquet"), u.build())
    _two(cat, "kk", "k", ArrowType.INT64, "a", ArrowType.INT64)
    _two(cat, "mm", "k", ArrowType.INT64, "b", ArrowType.INT64)
    _two(cat, "up", "K", ArrowType.INT64, "B", ArrowType.INT64)
    _two(cat, "kk2", "k", ArrowType.INT64, "k_right", ArrowType.INT64)
    cat.add_in_memory(String("mem"), RecordBatch.empty_from_schema(_kv()))
    return cat^


def _kv() -> Schema:
    var sb = SchemaBuilder()
    sb.add_field(Field(String("k"), ArrowType.INT64, False))
    sb.add_field(Field(String("v"), ArrowType.FLOAT64, True))
    return sb.build()


@fieldwise_init
struct _Footers(SqlParquetFooters):
    """A footer reader with fixed answers: every path but `missing.parquet`
    has schema (k INT64, v FLOAT64); `k` holds no NULL and `v` holds 3; a
    path named `bad.parquet` raises for null counts."""

    def footer_schema(self, path: String) raises -> Schema:
        if path == "missing.parquet":
            raise Error("no such file: " + path)
        return _kv()

    def column_null_count(self, path: String, column: String) raises -> Optional[Int]:
        if path == "bad.parquet":
            raise Error("unreadable statistics")
        if column == "k":
            return 0
        if column == "v":
            return 3
        return None


def _got(sql: String) raises -> String:
    """The bound plan's text, or `ERR: ` and the binder's message."""
    var cat = _catalog()
    try:
        var bound = bind_statement(parse_sql(tokenize(sql)), cat, NoParquetFooters())
        return String(bound.take_plan())
    except e:
        return String("ERR: ") + String(e)


def _gotp(sql: String) raises -> String:
    """`_got` with the `_Footers` reader."""
    var cat = _catalog()
    try:
        var bound = bind_statement(parse_sql(tokenize(sql)), cat, _Footers())
        return String(bound.take_plan())
    except e:
        return String("ERR: ") + String(e)


def _check(sql: String, want: String) raises:
    assert_equal(_got(sql), want, sql)


def _checkp(sql: String, want: String) raises:
    assert_equal(_gotp(sql), want, sql)

def test_direct_lowerings() raises:
    _check(
        "SELECT upper(s) AS a, sqrt(v) AS b, abs(k) AS c, add(k) AS d, subtract(k) AS e, add(k, 1) AS f, divide(k, 2) AS g, divide(v, 2) AS h, year(d) AS i, pow(v, 2) AS j FROM t",
        "Project(exprs=[Alias(StringFn(op=0, ColRef(s)), \"a\"), Alias(MathFn(op=2, ColRef(v)), \"b\"), Alias(UnaryOp(ABS, ColRef(k)), \"c\"), Alias(ColRef(k), \"d\"), Alias(UnaryOp(NEGATE, ColRef(k)), \"e\"), Alias(BinaryOp(ADD, ColRef(k), Literal(ScalarValue(int64, 1))), \"f\"), Alias(BinaryOp(DIV, ColRef(k), Literal(ScalarValue(int64, 2))), \"g\"), Alias(When(WHEN BinaryOp(EQ, Literal(ScalarValue(int64, 2)), Literal(ScalarValue(int64, 0))) THEN Literal(ScalarValue(null, float64)), ELSE BinaryOp(DIV, ColRef(v), Literal(ScalarValue(int64, 2)))), \"h\"), Alias(Extract(unit=0, ColRef(d)), \"i\"), Alias(MathFn2(op=1, ColRef(v), Literal(ScalarValue(int64, 2))), \"j\")])\n"
        "  Scan(path=\"t.parquet\", type=PARQUET, source_kind=COLUMNAR)\n"
    )
    _check(
        "SELECT multiply(k) FROM t",
        "ERR: SQL bind error: multiply() is the function spelling of an arithmetic operator and takes 2 arguments (add() and subtract() also take 1) — got 1"
    )
    _check(
        "SELECT contains(s, 'a') AS c1, starts_with(s, 'a') AS c2 FROM t",
        "Project(exprs=[Alias(StringOp(CONTAINS, ColRef(s), \"a\"), \"c1\"), Alias(StringOp(STARTS_WITH, ColRef(s), \"a\"), \"c2\")])\n"
        "  Scan(path=\"t.parquet\", type=PARQUET, source_kind=COLUMNAR)\n"
    )
    _check(
        "SELECT contains(s, s) FROM t",
        "ERR: SQL not supported: contains() pattern must be a string literal"
    )
    _check(
        "SELECT pg_table_is_visible(zzz) AS a, pg_is_other_temp_schema(1) AS b, current_user() AS c, pg_my_temp_schema() AS d FROM t",
        "Project(exprs=[Alias(Literal(ScalarValue(bool, true)), \"a\"), Alias(Literal(ScalarValue(bool, false)), \"b\"), Alias(Literal(ScalarValue(utf8, \"duckdb\")), \"c\"), Alias(Literal(ScalarValue(int32, 0)), \"d\")])\n"
        "  Scan(path=\"t.parquet\", type=PARQUET, source_kind=COLUMNAR)\n"
    )
    _check(
        "SELECT pg_table_is_visible(1, 2) FROM t",
        "ERR: SQL bind error: pg_table_is_visible() is a PostgreSQL compatibility constant — its DuckDB v1.5.3 body is a fixed value that IGNORES the arguments, but the declared argument COUNT is still enforced (DuckDB refuses a miscounted call by name, and so does this engine) — got 2. See the row in `sql_fn_table.mojo` for the count this name declares."
    )
    _check(
        "SELECT pi() AS p FROM t",
        "Project(exprs=[Alias(Literal(ScalarValue(float64, 3.141592653589793)), \"p\")])\n"
        "  Scan(path=\"t.parquet\", type=PARQUET, source_kind=COLUMNAR)\n"
    )
    _check(
        "SELECT pi(k) FROM t",
        "ERR: SQL bind error: pi() takes no arguments — got 1"
    )


def test_arity_refused_and_unknown_functions() raises:
    _check(
        "SELECT upper(s, s) FROM t",
        "ERR: SQL bind error: upper() expects exactly 1 argument — got 2"
    )
    _check(
        "SELECT nosuchfn(k) FROM t",
        "ERR: SQL not supported: scalar function 'nosuchfn'. No UDFs are declared on this catalog either — declare one with `catalog.declare_udf(f)`"
    )
    _check(
        "SELECT nextafter(v, 1.0) FROM t",
        "ERR: SQL not supported: `nextafter` is a real DuckDB v1.5.3 SCALAR function — TWO overloads, `DOUBLE(DOUBLE, DOUBLE)` and `FLOAT(FLOAT, FLOAT)` — and THE MISSING PRIMITIVE IS A `MATH2_` OP. `EXPR_MATH_FN2` carries exactly TWO members on this engine's wire, `MATH2_ATAN2` (engine 0) and `MATH2_POW` (engine 1), pinned by `MATH_FN2_WIRE_MEMBERS = 2` in `plan_wire_vocabulary.mojo`, and neither computes a next-representable step. ⚠ THE COST IS WHY THIS IS A REFUSAL AND NOT A ONE-LINE ROW: a new `MATH2_` member reaches `scalar_math.eval_math_binary`, the wire vocabulary's member COUNT and its engine/wire MIN and MAX as well as its to_wire/from_wire pair, `plan.proto` + `plan_vocabulary.proto`, `expr.mojo`, `lower_untyped_expr`, `xl_scalar_numeric` and this table — a strictly wider surface than a `STRFN_` tag, and the wire codec REFUSES an op it does not carry rather than silently dropping it. ⚠ `compiler_eval_column` is NOT on that list: it reaches a `MATH2_` op ONLY through `eval_math_binary` and therefore needs no per-member edit at all. ⛔ AND NO EXISTING OP IS NEAR ENOUGH TO BORROW, WHICH IS THE PART A NEAREST-MATCH FIX WOULD GET WRONG. MEASURED v1.5.3 through `printf('%.17g')` (a bare `duckdb -csv` does not round-trip a double): `nextafter(1.0, 2.0)` = 1.0000000000000002 but `nextafter(1.0, 0.0)` = 0.99999999999999989 — the two steps have DIFFERENT magnitudes because the binade changes below 1.0; `nextafter(0.0, 1.0)` = 4.9406564584124654e-324, the smallest SUBNORMAL and not an epsilon; and `nextafter(1.0, 1.0)` = 1.0, so equal operands are the IDENTITY and not a step. Every one of those is a property of the IEEE-754 bit pattern rather than of arithmetic over the operands, so any approximation would be wrong at exactly the call sites that ask for this function. ⭐ YOU CAN SUPPLY THIS FUNCTION YOURSELF: this name lowers to nothing here, so it is DECLARABLE as a UDF — declare one named `nextafter` with `catalog.declare_udf(f)`, and this binder will resolve your function in place of this refusal."
    )
    _check(
        "SELECT round(v, 2) FROM t",
        "ERR: SQL bind error: round() takes exactly 1 argument here — got 2. DuckDB also has a 2-argument round(x, digits) / trunc(x, digits); this engine lowers the 1-argument form onto a UNARY node that has no slot for a digit count, so the 2-argument form is REFUSED rather than rounded to zero digits."
    )
    _check(
        "SELECT trim(s, 'x') FROM t",
        "ERR: SQL bind error: trim() expects exactly 1 argument — got 2"
    )
    _check(
        "SELECT median(v) FROM t WHERE upper(median(v)) = 'x'",
        "ERR: SQL bind error: aggregate function 'median' is not allowed in this position"
    )


def test_string_fn_n_family() raises:
    _check(
        "SELECT concat(s, 'x', s) AS c1, lpad(s, 5, '*') AS c2, replace(s, 'a', 'b') AS c3 FROM t",
        "Project(exprs=[Alias(StringFnN(op=0, n=3, ColRef(s), Literal(ScalarValue(utf8, \"x\")), ColRef(s)), \"c1\"), Alias(StringFnN(op=3, n=3, ColRef(s), Literal(ScalarValue(int64, 5)), Literal(ScalarValue(utf8, \"*\"))), \"c2\"), Alias(StringFnN(op=2, n=3, ColRef(s), Literal(ScalarValue(utf8, \"a\")), Literal(ScalarValue(utf8, \"b\"))), \"c3\")])\n"
        "  Scan(path=\"t.parquet\", type=PARQUET, source_kind=COLUMNAR)\n"
    )
    _check(
        "SELECT lpad(s) FROM t",
        "ERR: SQL bind error: lpad() expects exactly 3 arguments — got 1"
    )
    _check(
        "SELECT concat() FROM t",
        "ERR: SQL bind error: concat() expects at least 1 arguments — got 0"
    )


def test_regexp_family() raises:
    _check(
        "SELECT regexp_matches(s, 'a.c') AS r1, regexp_full_match(s, 'abc') AS r2, regexp_replace(s, 'b', 'X') AS r3, regexp_extract(s, '(a)(b)', 1) AS r4, regexp_extract_all(s, 'a') AS r5, regexp_split_to_array(s, ',') AS r6 FROM t",
        "Project(exprs=[Alias(Regexp(op=0, ColRef(s), pattern=\"a.c\"), \"r1\"), Alias(Regexp(op=9, ColRef(s), pattern=\"abc\"), \"r2\"), Alias(Regexp(op=2, ColRef(s), pattern=\"b\", replacement=\"X\"), \"r3\"), Alias(Regexp(op=3, ColRef(s), pattern=\"(a)(b)\", group=1), \"r4\"), Alias(Regexp(op=5, ColRef(s), pattern=\"a\", group=0), \"r5\"), Alias(Regexp(op=4, ColRef(s), pattern=\",\"), \"r6\")])\n"
        "  Scan(path=\"t.parquet\", type=PARQUET, source_kind=COLUMNAR)\n"
    )
    _check(
        "SELECT regexp_matches(s, 'a', 'i') AS r1, regexp_replace(s, 'b', 'X', 'g') AS r2, regexp_extract(s, 'a', 0, 'i') AS r3 FROM t",
        "Project(exprs=[Alias(Regexp(op=0, ColRef(s), pattern=\"a\", flags=\"i\"), \"r1\"), Alias(Regexp(op=2, ColRef(s), pattern=\"b\", flags=\"g\", replacement=\"X\"), \"r2\"), Alias(Regexp(op=3, ColRef(s), pattern=\"a\", flags=\"i\", group=0), \"r3\")])\n"
        "  Scan(path=\"t.parquet\", type=PARQUET, source_kind=COLUMNAR)\n"
    )
    _check(
        "SELECT regexp_matches(s) FROM t",
        "ERR: SQL bind error: regexp_matches() expects (string, regex[, options]) — got 1 arguments"
    )
    _check(
        "SELECT regexp_replace(s) FROM t",
        "ERR: SQL bind error: regexp_replace() expects (string, regex, replacement[, options]) — got 1 arguments"
    )
    _check(
        "SELECT regexp_extract(s, '(a)(b)', -1) FROM t",
        "ERR: SQL bind error: regexp_extract() group must be non-negative — got -1"
    )
    _check(
        "SELECT regexp_extract(s, '(a)', 10) FROM t",
        "Project(exprs=[Regexp(op=3, ColRef(s), pattern=\"(a)\", group=10)])\n"
        "  Scan(path=\"t.parquet\", type=PARQUET, source_kind=COLUMNAR)\n"
    )
    _check(
        "SELECT regexp_matches(s, s) FROM t",
        "ERR: SQL not supported: regexp_matches() pattern must be a string literal"
    )
    _check(
        "SELECT regexp_matches(s, 'a', 'zz') FROM t",
        "Project(exprs=[Regexp(op=0, ColRef(s), pattern=\"a\", flags=\"zz\")])\n"
        "  Scan(path=\"t.parquet\", type=PARQUET, source_kind=COLUMNAR)\n"
    )
    _check(
        "SELECT regexp_matches(s, 'a', s) FROM t",
        "ERR: SQL not supported: regexp_matches() options must be a string literal"
    )
    _check(
        "SELECT regexp_replace(s, 'a', s) FROM t",
        "ERR: SQL not supported: regexp_replace() replacement must be a string literal"
    )
    _check(
        "SELECT regexp_extract(s, 'a', s) FROM t",
        "ERR: SQL not supported: regexp_extract() group must be an integer literal (the name-list overload, which returns a STRUCT, is not served)"
    )
    _check(
        "SELECT regexp_extract(s, 'a', 1, 2, 3) FROM t",
        "ERR: SQL bind error: regexp_extract() expects (string, regex[, group][, options]) — got 5 arguments"
    )
    _check(
        "SELECT regexp_extract_all(s, 'a', 1) FROM t",
        "Project(exprs=[Regexp(op=5, ColRef(s), pattern=\"a\", group=1)])\n"
        "  Scan(path=\"t.parquet\", type=PARQUET, source_kind=COLUMNAR)\n"
    )


def test_greatest_least_coalesce() raises:
    _check(
        "SELECT greatest(k, v) AS g1, least(k, 2) AS l1 FROM t",
        "Project(exprs=[Alias(When(WHEN UnaryOp(IS_NULL, ColRef(k)) THEN ColRef(v), WHEN UnaryOp(IS_NULL, ColRef(v)) THEN ColRef(k), WHEN BinaryOp(GT, ColRef(k), ColRef(v)) THEN ColRef(k), ELSE ColRef(v)), \"g1\"), Alias(When(WHEN UnaryOp(IS_NULL, ColRef(k)) THEN Literal(ScalarValue(int64, 2)), WHEN UnaryOp(IS_NULL, Literal(ScalarValue(int64, 2))) THEN ColRef(k), WHEN BinaryOp(LT, ColRef(k), Literal(ScalarValue(int64, 2))) THEN ColRef(k), ELSE Literal(ScalarValue(int64, 2))), \"l1\")])\n"
        "  Scan(path=\"t.parquet\", type=PARQUET, source_kind=COLUMNAR)\n"
    )
    _check(
        "SELECT greatest(k, g, 3) FROM t",
        "ERR: SQL not supported: greatest() takes exactly 2 arguments here — got 3. It desugars to a CASE that mentions each operand four times, so folding a third argument would square the plan"
    )
    _check(
        "SELECT coalesce(v, 0) AS c1, coalesce(NULL, k) AS c2, ifnull(k, 0) AS c3, coalesce(k, g, 0) AS c4 FROM t",
        "Project(exprs=[Alias(When(WHEN UnaryOp(IS_NOT_NULL, ColRef(v)) THEN ColRef(v), ELSE Literal(ScalarValue(float64, 0.0))), \"c1\"), Alias(ColRef(k), \"c2\"), Alias(When(WHEN UnaryOp(IS_NOT_NULL, ColRef(k)) THEN ColRef(k), ELSE Literal(ScalarValue(int64, 0))), \"c3\"), Alias(When(WHEN UnaryOp(IS_NOT_NULL, ColRef(k)) THEN ColRef(k), WHEN UnaryOp(IS_NOT_NULL, ColRef(g)) THEN ColRef(g), ELSE Literal(ScalarValue(int64, 0))), \"c4\")])\n"
        "  Scan(path=\"t.parquet\", type=PARQUET, source_kind=COLUMNAR)\n"
    )
    _check(
        "SELECT coalesce(v) AS c FROM t",
        "Project(exprs=[Alias(ColRef(v), \"c\")])\n"
        "  Scan(path=\"t.parquet\", type=PARQUET, source_kind=COLUMNAR)\n"
    )
    _check(
        "SELECT ifnull(k) FROM t",
        "ERR: SQL bind error: ifnull() expects exactly 2 arguments — got 1"
    )
    _check(
        "SELECT coalesce() FROM t",
        "ERR: SQL bind error: coalesce() expects at least 1 argument"
    )
    _check(
        "SELECT coalesce(NULL, NULL) FROM t",
        "ERR: SQL not supported: a NULL literal is served as a comparison operand (`x = NULL`, `x <> NULL`) and as an IN-list member (`x IN (1, NULL)`, `x NOT IN (1, NULL)`), as a CASE's `ELSE NULL`, as a CASE `THEN NULL` beside INT64 or FLOAT64 arms, and as a COALESCE / IFNULL argument beside a typed one; anywhere else (a projected NULL, `NOT NULL`, `NULL = NULL`, any other function argument, arithmetic, a CASE or COALESCE whose EVERY value is NULL) it needs a typed NULL value this engine's plan does not carry"
    )


def test_date_part_and_date_trunc() raises:
    _check(
        "SELECT date_part('year', d) AS p1, date_part('dow', d) AS p2, date_part('century', d) AS p3, extract(month FROM ts) AS p4 FROM t",
        "Project(exprs=[Alias(Extract(unit=0, ColRef(d)), \"p1\"), Alias(Extract(unit=7, ColRef(d)), \"p2\"), Alias(When(WHEN BinaryOp(GT, Extract(unit=0, ColRef(d)), Literal(ScalarValue(int64, 0))) THEN BinaryOp(ADD, BinaryOp(DIV, BinaryOp(SUB, Extract(unit=0, ColRef(d)), Literal(ScalarValue(int64, 1))), Literal(ScalarValue(int64, 100))), Literal(ScalarValue(int64, 1))), WHEN BinaryOp(LE, Extract(unit=0, ColRef(d)), Literal(ScalarValue(int64, 0))) THEN BinaryOp(SUB, BinaryOp(DIV, Extract(unit=0, ColRef(d)), Literal(ScalarValue(int64, 100))), Literal(ScalarValue(int64, 1))), ELSE Literal(ScalarValue(null, int64))), \"p3\"), Alias(Extract(unit=2, ColRef(ts)), \"p4\")])\n"
        "  Scan(path=\"t.parquet\", type=PARQUET, source_kind=COLUMNAR)\n"
    )
    _check(
        "SELECT date_part('fortnight', d) FROM t",
        "ERR: SQL not supported: date part 'fortnight' — this engine serves year, years, yr, yrs, y, quarter, quarters, month, months, mon, mons, day, days, d, dayofmonth, hour, hours, h, hr, hrs, minute, minutes, min, mins, m, second, seconds, s, sec, secs, dayofweek, dow, weekday, isodow, dayofyear, doy, week, weeks, weekofyear, w, isoyear, yearweek, millisecond, milliseconds, msec, msecs, ms, msecond, mseconds, microsecond, microseconds, usec, usecs, us, usecond, useconds, century, centuries, cent, decade, decades, dec, decs, millennium, millennia, mil, mils, era. It does NOT serve epoch, julian, timezone, timezone_hour, timezone_minute, each of which IS a real v1.5.3 specifier with a measured blocker (epoch / julian read a RAW value no unit on this wire carries; the timezone reads answer 0 for every naive timestamp and are refused rather than served as a plausible zero). This list is DERIVED from the specifier tables, not written beside them"
    )
    _check(
        "SELECT date_part(s, d) FROM t",
        "ERR: SQL not supported: date_part() requires a constant string unit as its first argument (a column or expression there is not supported — the unit selects the IR node at bind time)"
    )
    _check(
        "SELECT date_part('year') FROM t",
        "ERR: SQL bind error: date_part() expects (unit, temporal) — got 1 arguments"
    )
    _check(
        "SELECT date_trunc('month', d) AS t1, date_trunc('dow', ts) AS t2 FROM t",
        "Project(exprs=[Alias(Extract(unit=18, ColRef(d)), \"t1\"), Alias(Extract(unit=20, ColRef(ts)), \"t2\")])\n"
        "  Scan(path=\"t.parquet\", type=PARQUET, source_kind=COLUMNAR)\n"
    )
    _check(
        "SELECT date_trunc('decade', d) FROM t",
        "ERR: SQL not supported: date_trunc unit 'decade' — the supported periods are year, quarter, month, week, day, hour, minute, second, millisecond and microsecond, each with its DuckDB aliases (including the field-named periods dayofweek / dow / weekday / isodow / dayofyear / doy / julian, which truncate to the DAY; weekofyear / yearweek, which truncate to the WEEK; and epoch, which truncates to the SECOND). (decade / century / millennium / isoyear are real DuckDB periods with no unit on this engine's wire; they are refused rather than rounded to the nearest period that exists; isoyear especially, since 2021-01-01 falls in isoyear 2020)"
    )
    _check(
        "SELECT date_trunc('month') FROM t",
        "ERR: SQL bind error: date_trunc() expects (unit, temporal) — got 1 arguments"
    )


def test_left_right_substring() raises:
    _check(
        "SELECT left(s, 2) AS l1, left(s, -2) AS l2, right(s, 2) AS r1, right(s, -2) AS r2, left(s, 0) AS l0, right(s, 0) AS r0 FROM t",
        "Project(exprs=[Alias(Substring(ColRef(s), start=1, length=2), \"l1\"), Alias(Substring(ColRef(s), start=1, length=-3), \"l2\"), Alias(Substring(ColRef(s), start=-2, length=-1), \"r1\"), Alias(Substring(ColRef(s), start=3, length=-1), \"r2\"), Alias(Substring(ColRef(s), start=1, length=0), \"l0\"), Alias(Substring(ColRef(s), start=1, length=0), \"r0\")])\n"
        "  Scan(path=\"t.parquet\", type=PARQUET, source_kind=COLUMNAR)\n"
    )
    _check(
        "SELECT left(s) FROM t",
        "ERR: SQL bind error: left() expects exactly 2 arguments (string, count) — got 1"
    )
    _check(
        "SELECT left(s, k) FROM t",
        "ERR: SQL not supported: left() count must be an integer literal"
    )
    _check(
        "SELECT substring(s, 2) AS s1, substring(s, 2, 3) AS s2, substr(s, 1, 1) AS s3 FROM t",
        "Project(exprs=[Alias(Substring(ColRef(s), start=2, length=-1), \"s1\"), Alias(Substring(ColRef(s), start=2, length=3), \"s2\"), Alias(Substring(ColRef(s), start=1, length=1), \"s3\")])\n"
        "  Scan(path=\"t.parquet\", type=PARQUET, source_kind=COLUMNAR)\n"
    )
    _check(
        "SELECT substring(s) FROM t",
        "ERR: SQL bind error: substring() expects (string, start[, length]) — got 1 arguments"
    )
    _check(
        "SELECT substring(s, k) FROM t",
        "ERR: SQL not supported: substring() start position must be an integer literal"
    )
    _check(
        "SELECT substring(s, 1, k) FROM t",
        "ERR: SQL not supported: substring() length must be an integer literal"
    )
    _check(
        "SELECT substring(s, 1, -1) FROM t",
        "ERR: SQL bind error: substring() length must be non-negative"
    )


def test_year_parts_nanosecond_float_classes_split() raises:
    _check(
        "SELECT century(d) AS c, decade(d) AS de, millennium(d) AS m, era(d) AS e FROM t",
        "Project(exprs=[Alias(When(WHEN BinaryOp(GT, Extract(unit=0, ColRef(d)), Literal(ScalarValue(int64, 0))) THEN BinaryOp(ADD, BinaryOp(DIV, BinaryOp(SUB, Extract(unit=0, ColRef(d)), Literal(ScalarValue(int64, 1))), Literal(ScalarValue(int64, 100))), Literal(ScalarValue(int64, 1))), WHEN BinaryOp(LE, Extract(unit=0, ColRef(d)), Literal(ScalarValue(int64, 0))) THEN BinaryOp(SUB, BinaryOp(DIV, Extract(unit=0, ColRef(d)), Literal(ScalarValue(int64, 100))), Literal(ScalarValue(int64, 1))), ELSE Literal(ScalarValue(null, int64))), \"c\"), Alias(BinaryOp(DIV, Extract(unit=0, ColRef(d)), Literal(ScalarValue(int64, 10))), \"de\"), Alias(When(WHEN BinaryOp(GT, Extract(unit=0, ColRef(d)), Literal(ScalarValue(int64, 0))) THEN BinaryOp(ADD, BinaryOp(DIV, BinaryOp(SUB, Extract(unit=0, ColRef(d)), Literal(ScalarValue(int64, 1))), Literal(ScalarValue(int64, 1000))), Literal(ScalarValue(int64, 1))), WHEN BinaryOp(LE, Extract(unit=0, ColRef(d)), Literal(ScalarValue(int64, 0))) THEN BinaryOp(SUB, BinaryOp(DIV, Extract(unit=0, ColRef(d)), Literal(ScalarValue(int64, 1000))), Literal(ScalarValue(int64, 1))), ELSE Literal(ScalarValue(null, int64))), \"m\"), Alias(When(WHEN BinaryOp(GT, Extract(unit=0, ColRef(d)), Literal(ScalarValue(int64, 0))) THEN Literal(ScalarValue(int64, 1)), WHEN BinaryOp(LE, Extract(unit=0, ColRef(d)), Literal(ScalarValue(int64, 0))) THEN Literal(ScalarValue(int64, 0)), ELSE Literal(ScalarValue(null, int64))), \"e\")])\n"
        "  Scan(path=\"t.parquet\", type=PARQUET, source_kind=COLUMNAR)\n"
    )
    _check(
        "SELECT century(d, d) FROM t",
        "ERR: SQL bind error: century() expects exactly 1 argument (a DATE or TIMESTAMP expression) — got 2"
    )
    _check(
        "SELECT nanosecond(ts) AS n FROM t",
        "Project(exprs=[Alias(BinaryOp(MUL, Extract(unit=14, ColRef(ts)), Literal(ScalarValue(int64, 1000))), \"n\")])\n"
        "  Scan(path=\"t.parquet\", type=PARQUET, source_kind=COLUMNAR)\n"
    )
    _check(
        "SELECT nanosecond(ts, ts) FROM t",
        "ERR: SQL bind error: nanosecond() expects exactly 1 argument (a DATE or TIMESTAMP expression) — got 2"
    )
    _check(
        "SELECT isfinite(v) AS a, isinf(v) AS b, isnan(v) AS c FROM t",
        "Project(exprs=[Alias(BinaryOp(AND, BinaryOp(GT, ColRef(v), Literal(ScalarValue(float64, -inf))), BinaryOp(LT, ColRef(v), Literal(ScalarValue(float64, inf)))), \"a\"), Alias(BinaryOp(OR, BinaryOp(EQ, ColRef(v), Literal(ScalarValue(float64, inf))), BinaryOp(EQ, ColRef(v), Literal(ScalarValue(float64, -inf)))), \"b\"), Alias(BinaryOp(AND, UnaryOp(NOT, BinaryOp(AND, BinaryOp(GT, ColRef(v), Literal(ScalarValue(float64, -inf))), BinaryOp(LT, ColRef(v), Literal(ScalarValue(float64, inf))))), UnaryOp(NOT, BinaryOp(OR, BinaryOp(EQ, ColRef(v), Literal(ScalarValue(float64, inf))), BinaryOp(EQ, ColRef(v), Literal(ScalarValue(float64, -inf)))))), \"c\")])\n"
        "  Scan(path=\"t.parquet\", type=PARQUET, source_kind=COLUMNAR)\n"
    )
    _check(
        "SELECT isnan(v, v) FROM t",
        "ERR: SQL bind error: isnan() expects exactly 1 argument (a numeric expression) — got 2"
    )
    _check(
        "SELECT string_split(s, '.') AS p1, split(s, ',') AS p2 FROM t",
        "Project(exprs=[Alias(Regexp(op=4, ColRef(s), pattern=\"\\\\.\"), \"p1\"), Alias(Regexp(op=4, ColRef(s), pattern=\"\\\\,\"), \"p2\")])\n"
        "  Scan(path=\"t.parquet\", type=PARQUET, source_kind=COLUMNAR)\n"
    )
    _check(
        "SELECT string_split(s) FROM t",
        "ERR: SQL bind error: string_split() expects exactly 2 arguments (string, separator) — got 1"
    )
    _check(
        "SELECT string_split(s, s) FROM t",
        "ERR: SQL not supported: string_split() separator must be a string literal"
    )


def test_json_struct_map() raises:
    _check(
        "SELECT json_extract(j, '$.a.b') AS a, json_extract_string(j, 'a.b') AS b, json_extract(j, '$.\"a.b\"') AS c FROM t",
        "Project(exprs=[Alias(JsonExtract(ColRef(j), path=\"$.a.b\", mode=->), \"a\"), Alias(JsonExtract(ColRef(j), path=\"$.a\\.b\", mode=->>), \"b\"), Alias(JsonExtract(ColRef(j), path=\"$.a\\.b\", mode=->), \"c\")])\n"
        "  Scan(path=\"t.parquet\", type=PARQUET, source_kind=COLUMNAR)\n"
    )
    _check(
        "SELECT json_extract(j) FROM t",
        "ERR: SQL bind error: json_extract() expects exactly 2 arguments (json_text, path) — got 1"
    )
    _check(
        "SELECT json_extract(j, s) FROM t",
        "ERR: SQL not supported: json_extract() path must be a string literal — `EXPR_JSON_EXTRACT` parses the path into `JsonExtractData.path_segments` ONCE at plan time, so a column-valued path (and DuckDB's LIST-of-paths and integer-index overloads) is an operation the tag cannot express"
    )
    _check(
        "SELECT json_extract(j, '') FROM t",
        "ERR: SQL not supported: json_extract() path must not be empty"
    )
    _check(
        "SELECT json_extract(j, '$') FROM t",
        "ERR: SQL not supported: json_extract('$') — the whole-document extract. DuckDB v1.5.3 MINIFIES it (json_extract('  {\"a\" :  1 }  ', '$') = {\"a\":1}), and this engine's JSON extract returns a zero-segment path's payload bytes VERBATIM, whitespace included; with no JSON canonicaliser to re-emit a parsed document, this refuses rather than answering a different string"
    )
    _check(
        "SELECT json_extract(j, '$.e[0]') FROM t",
        "ERR: parse_json_path: bracket notation not supported (path '$.e[0]')"
    )
    _check(
        "SELECT struct_extract(s, 'a') AS a, struct_extract_at(s, 1) AS b, map_extract_value(s, 'k') AS c FROM t",
        "Project(exprs=[Alias(StructField(ColRef(s), \"a\"), \"a\"), Alias(StructFieldIdx(ColRef(s), #0), \"b\"), Alias(MapGet(ColRef(s), Literal(ScalarValue(utf8, \"k\"))), \"c\")])\n"
        "  Scan(path=\"t.parquet\", type=PARQUET, source_kind=COLUMNAR)\n"
    )
    _check(
        "SELECT struct_extract(s) FROM t",
        "ERR: SQL bind error: struct_extract() expects exactly 2 arguments (struct, field_name) — got 1"
    )
    _check(
        "SELECT struct_extract(s, k) FROM t",
        "ERR: SQL not supported: struct_extract() second argument must be a literal — the tag stores the selector as a plain String/Int in `StructFieldData` / `StructFieldIdxData`, not as an `Expr`, so a column-valued selector is an operation it cannot express"
    )
    _check(
        "SELECT struct_extract_at(s, 'a') FROM t",
        "ERR: SQL bind error: struct_extract_at() index must be an INTEGER literal"
    )
    _check(
        "SELECT struct_extract_at(s, 0) FROM t",
        "ERR: SQL bind error: struct_extract_at() index is 1-BASED on DuckDB v1.5.3 (struct_extract_at({'a':1,'b':2}, 0) is a Binder Error there) — got 0"
    )
    _check(
        "SELECT struct_extract(s, 1) FROM t",
        "ERR: SQL bind error: struct_extract() field name must be a STRING literal"
    )
    _check(
        "SELECT map_extract_value(s) FROM t",
        "ERR: SQL bind error: map_extract_value() expects exactly 2 arguments (map, key) — got 1"
    )


def test_date_diff_and_date_sub() raises:
    _check(
        "SELECT date_diff('day', DATE '2021-01-01', DATE '2021-01-31') AS a, date_diff('day', d, d) AS b, date_sub('day', DATE '2021-01-01', DATE '2021-01-31') AS c, date_sub('day', d, d) AS e FROM t",
        "Project(exprs=[Alias(Literal(ScalarValue(int64, 30)), \"a\"), Alias(BinaryOp(SUB, Cast(ColRef(d), int64), Cast(ColRef(d), int64)), \"b\"), Alias(Literal(ScalarValue(int64, 30)), \"c\"), Alias(BinaryOp(SUB, Cast(ColRef(d), int64), Cast(ColRef(d), int64)), \"e\")])\n"
        "  Scan(path=\"t.parquet\", type=PARQUET, source_kind=COLUMNAR)\n"
    )
    _check(
        "SELECT date_diff('month', d, d) FROM t",
        "ERR: SQL not supported: only date_diff('day', ...) is supported (got unit that is not the constant 'day'). THE MISSING PRIMITIVE IS CIVIL-CALENDAR BOUNDARY ARITHMETIC OVER A COLUMN: this function counts BOUNDARIES CROSSED, which for month/year is not expressible as the int32 day subtraction that serves 'day'"
    )
    _check(
        "SELECT date_diff('day', d) FROM t",
        "ERR: SQL bind error: date_diff expects 3 arguments (unit, start, end)"
    )
    _check(
        "SELECT date_sub('month', d, d) FROM t",
        "ERR: SQL not supported: only date_sub('day', ...) is supported. ⚠ date_sub counts COMPLETE periods and date_diff counts boundaries CROSSED — in DuckDB v1.5.3 they differ for every unit above 'day' (1 vs 2 over 2021-01-31 -> 2021-03-01), so the"
    )
    _check(
        "SELECT date_sub('day', d) FROM t",
        "ERR: SQL bind error: date_sub expects 3 arguments (unit, start, end)"
    )
    _check(
        "SELECT date_diff('day', k, d) FROM t",
        "ERR: SQL not supported: date_diff('day', a, b) requires DATE operands — argument 2 is not a DATE literal and not a DATE32 column. THE MISSING PRIMITIVE IS A UNIT-AWARE, PER-FUNCTION TEMPORAL DELTA. The lowering here subtracts DAY NUMBERS, and it is refused over anything else for two separate reasons: a TIMESTAMP is int64 MICROSECONDS, so the subtraction answers a number ~8.64e10 times too large, and date_diff and date_sub DISAGREE on 'day' itself once the operands carry a time-of-day (DuckDB v1.5.3: 247 vs 246 over one pair) — so one shared lowering would answer one function's rule under the other's name. A bare integer column is refused for a third: it has no days in it, and the subtraction would answer a plausible day count anyway rather than raising"
    )
    _check(
        "SELECT date_diff('day', d, ts) FROM t",
        "ERR: SQL not supported: date_diff('day', a, b) requires DATE operands — argument 3 is not a DATE literal and not a DATE32 column. THE MISSING PRIMITIVE IS A UNIT-AWARE, PER-FUNCTION TEMPORAL DELTA. The lowering here subtracts DAY NUMBERS, and it is refused over anything else for two separate reasons: a TIMESTAMP is int64 MICROSECONDS, so the subtraction answers a number ~8.64e10 times too large, and date_diff and date_sub DISAGREE on 'day' itself once the operands carry a time-of-day (DuckDB v1.5.3: 247 vs 246 over one pair) — so one shared lowering would answer one function's rule under the other's name. A bare integer column is refused for a third: it has no days in it, and the subtraction would answer a plausible day count anyway rather than raising"
    )
    _check(
        "SELECT date_sub('day', DATE '2021-01-01', d) FROM t",
        "Project(exprs=[BinaryOp(SUB, Cast(ColRef(d), int64), Cast(Literal(ScalarValue(date32, 18628)), int64))])\n"
        "  Scan(path=\"t.parquet\", type=PARQUET, source_kind=COLUMNAR)\n"
    )


def test_even_fdiv_nullif_days_in_month() raises:
    _check(
        "SELECT even(v) AS e1 FROM t",
        "Project(exprs=[Alias(When(WHEN BinaryOp(GE, Cast(ColRef(v), float64), Literal(ScalarValue(float64, 0.0))) THEN BinaryOp(MUL, MathFn(op=5, BinaryOp(DIV, Cast(ColRef(v), float64), Literal(ScalarValue(float64, 2.0)))), Literal(ScalarValue(float64, 2.0))), ELSE BinaryOp(MUL, MathFn(op=6, BinaryOp(DIV, Cast(ColRef(v), float64), Literal(ScalarValue(float64, 2.0)))), Literal(ScalarValue(float64, 2.0)))), \"e1\")])\n"
        "  Scan(path=\"t.parquet\", type=PARQUET, source_kind=COLUMNAR)\n"
    )
    _check(
        "SELECT even(v, k) FROM t",
        "ERR: SQL bind error: even() expects exactly 1 argument — got 2"
    )
    _check(
        "SELECT fdiv(k, 2) AS a, fmod(k, 2) AS b FROM t",
        "Project(exprs=[Alias(MathFn(op=6, BinaryOp(DIV, Cast(ColRef(k), float64), Cast(Literal(ScalarValue(int64, 2)), float64))), \"a\"), Alias(BinaryOp(SUB, Cast(ColRef(k), float64), BinaryOp(MUL, Cast(Literal(ScalarValue(int64, 2)), float64), MathFn(op=6, BinaryOp(DIV, Cast(ColRef(k), float64), Cast(Literal(ScalarValue(int64, 2)), float64))))), \"b\")])\n"
        "  Scan(path=\"t.parquet\", type=PARQUET, source_kind=COLUMNAR)\n"
    )
    _check(
        "SELECT fdiv(k) FROM t",
        "ERR: SQL bind error: fdiv() expects exactly 2 arguments (x, y) — got 1"
    )
    _check(
        "SELECT nullif(k, 2) AS a, nullif(v, 1) AS b, nullif(k, 1.5) AS c FROM t",
        "Project(exprs=[Alias(When(WHEN BinaryOp(EQ, ColRef(k), Literal(ScalarValue(int64, 2))) THEN Literal(ScalarValue(null, int64)), ELSE ColRef(k)), \"a\"), Alias(When(WHEN BinaryOp(EQ, ColRef(v), Literal(ScalarValue(float64, 1.0))) THEN Literal(ScalarValue(null, float64)), ELSE ColRef(v)), \"b\"), Alias(When(WHEN BinaryOp(EQ, ColRef(k), Literal(ScalarValue(float64, 1.5))) THEN Literal(ScalarValue(null, float64)), ELSE ColRef(k)), \"c\")])\n"
        "  Scan(path=\"t.parquet\", type=PARQUET, source_kind=COLUMNAR)\n"
    )
    _check(
        "SELECT nullif(s, 'a') FROM t",
        "ERR: SQL not supported: nullif() over a STRING operand. Its THEN arm is a typed NULL and this IR has no string-typed NULL literal (the plan's typed NULL literals are float64 and int64 only), so there is no value to return for the matching rows. The numeric form is served."
    )
    _check(
        "SELECT nullif(k) FROM t",
        "ERR: SQL bind error: nullif() expects exactly 2 arguments — got 1"
    )
    _check(
        "SELECT days_in_month(d) AS x FROM t",
        "Project(exprs=[Alias(When(WHEN BinaryOp(EQ, Extract(unit=2, ColRef(d)), Literal(ScalarValue(int64, 1))) THEN Literal(ScalarValue(int64, 31)), WHEN BinaryOp(EQ, Extract(unit=2, ColRef(d)), Literal(ScalarValue(int64, 2))) THEN When(WHEN BinaryOp(EQ, BinaryOp(SUB, Extract(unit=0, ColRef(d)), BinaryOp(MUL, BinaryOp(DIV, Extract(unit=0, ColRef(d)), Literal(ScalarValue(int64, 400))), Literal(ScalarValue(int64, 400)))), Literal(ScalarValue(int64, 0))) THEN Literal(ScalarValue(int64, 29)), WHEN BinaryOp(EQ, BinaryOp(SUB, Extract(unit=0, ColRef(d)), BinaryOp(MUL, BinaryOp(DIV, Extract(unit=0, ColRef(d)), Literal(ScalarValue(int64, 100))), Literal(ScalarValue(int64, 100)))), Literal(ScalarValue(int64, 0))) THEN Literal(ScalarValue(int64, 28)), WHEN BinaryOp(EQ, BinaryOp(SUB, Extract(unit=0, ColRef(d)), BinaryOp(MUL, BinaryOp(DIV, Extract(unit=0, ColRef(d)), Literal(ScalarValue(int64, 4))), Literal(ScalarValue(int64, 4)))), Literal(ScalarValue(int64, 0))) THEN Literal(ScalarValue(int64, 29)), ELSE Literal(ScalarValue(int64, 28))), WHEN BinaryOp(EQ, Extract(unit=2, ColRef(d)), Literal(ScalarValue(int64, 3))) THEN Literal(ScalarValue(int64, 31)), WHEN BinaryOp(EQ, Extract(unit=2, ColRef(d)), Literal(ScalarValue(int64, 4))) THEN Literal(ScalarValue(int64, 30)), WHEN BinaryOp(EQ, Extract(unit=2, ColRef(d)), Literal(ScalarValue(int64, 5))) THEN Literal(ScalarValue(int64, 31)), WHEN BinaryOp(EQ, Extract(unit=2, ColRef(d)), Literal(ScalarValue(int64, 6))) THEN Literal(ScalarValue(int64, 30)), WHEN BinaryOp(EQ, Extract(unit=2, ColRef(d)), Literal(ScalarValue(int64, 7))) THEN Literal(ScalarValue(int64, 31)), WHEN BinaryOp(EQ, Extract(unit=2, ColRef(d)), Literal(ScalarValue(int64, 8))) THEN Literal(ScalarValue(int64, 31)), WHEN BinaryOp(EQ, Extract(unit=2, ColRef(d)), Literal(ScalarValue(int64, 9))) THEN Literal(ScalarValue(int64, 30)), WHEN BinaryOp(EQ, Extract(unit=2, ColRef(d)), Literal(ScalarValue(int64, 10))) THEN Literal(ScalarValue(int64, 31)), WHEN BinaryOp(EQ, Extract(unit=2, ColRef(d)), Literal(ScalarValue(int64, 11))) THEN Literal(ScalarValue(int64, 30)), WHEN BinaryOp(EQ, Extract(unit=2, ColRef(d)), Literal(ScalarValue(int64, 12))) THEN Literal(ScalarValue(int64, 31)), ELSE Literal(ScalarValue(null, int64))), \"x\")])\n"
        "  Scan(path=\"t.parquet\", type=PARQUET, source_kind=COLUMNAR)\n"
    )
    _check(
        "SELECT days_in_month(d, k) FROM t",
        "ERR: SQL bind error: days_in_month() expects exactly 1 argument (a DATE or TIMESTAMP expression) — got 2"
    )


def test_family_arity_messages() raises:
    _check(
        "SELECT contains(s) FROM t",
        "ERR: SQL bind error: contains() expects exactly 2 arguments (string, pattern) — got 1"
    )
    _check(
        "SELECT year(d, d) FROM t",
        "ERR: SQL bind error: year() expects exactly 1 argument (a DATE or TIMESTAMP expression) — got 2"
    )
    _check(
        "SELECT pow(v) FROM t",
        "ERR: SQL bind error: pow() expects exactly 2 arguments (base, exponent)"
    )
    _check(
        "SELECT add(k, 1, 2) FROM t",
        "ERR: SQL bind error: add() is the function spelling of an arithmetic operator and takes 2 arguments (add() and subtract() also take 1) — got 3"
    )


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
