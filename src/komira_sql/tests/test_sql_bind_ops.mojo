# =============================================================================
# Direct tests of operator and scalar-expression binding
# (sql_bind_ops, sql_bind_expr)
# =============================================================================
#
# What each test proves, and the defect (mutant) it would catch:
#   1. `/` over two integers casts the left operand to DOUBLE and over a
#      float keeps a plain division; `//` over integers is `BIN_DIV` and over
#      a float or DECIMAL is the zero-guarded CASE; `%` is `BIN_MOD`.
#      (mutant: `_integral_tri(...) == 0` changed to `== 1`, so a float `/`
#      gains a cast)
#   2. `^` is `pow`, `^@` is starts_with over a literal (a column pattern is
#      refused), `||` is refused by name, LIKE / NOT LIKE / ILIKE lower the
#      pattern and the column for ILIKE.
#      (mutant: ILIKE folds only the pattern)
#   3. Unary operators map to their own IR op (`-`, `@`, NOT, IS [NOT] NULL).
#      (mutant: `_map_unop` returns UN_IS_NULL for SXUN_IS_NOT_NULL)
#   4. A NULL comparison operand binds on the right whatever side it was
#      written on; a projected NULL and `NULL = NULL` are refused.
#   5. An integer literal past BIGINT is served only facing a column in a
#      comparison, as a UINT64 literal; past UBIGINT, or projected, refused.
#      (mutant: the UBIGINT overflow check uses `>=` on the high digit)
#   6. `CAST(<signed int col> AS <signed int>) <cmp> <literal that fits>`
#      drops the cast (nested casts too, and a moved `+ c` constant), but not
#      under NOT IN, not for a literal out of the target's range, and an IN
#      list strips one cast level only.
#      (mutant: the range test `lit > hi` changed to `lit >= hi`)
#   7. Literals of every kind, DATE validation (day of month, leap years,
#      malformed text), CASE typing (float promotion, typed NULL arms and
#      defaults), and the scalar-position refusals (aggregate in WHERE,
#      window nested in an expression).
#      (mutant: `_date_to_days` checks `d > 31` only)

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

def test_division_and_modulo() raises:
    _check(
        "SELECT k / 2 AS a, k // 2 AS b, k % 2 AS c, v / 2 AS d, v // 2 AS e, dc // 2 AS f FROM t",
        "Project(exprs=[Alias(BinaryOp(DIV, Cast(ColRef(k), float64), Literal(ScalarValue(int64, 2))), \"a\"), Alias(BinaryOp(DIV, ColRef(k), Literal(ScalarValue(int64, 2))), \"b\"), Alias(BinaryOp(MOD, ColRef(k), Literal(ScalarValue(int64, 2))), \"c\"), Alias(BinaryOp(DIV, ColRef(v), Literal(ScalarValue(int64, 2))), \"d\"), Alias(When(WHEN BinaryOp(EQ, Literal(ScalarValue(int64, 2)), Literal(ScalarValue(int64, 0))) THEN Literal(ScalarValue(null, float64)), ELSE BinaryOp(DIV, ColRef(v), Literal(ScalarValue(int64, 2)))), \"e\"), Alias(When(WHEN BinaryOp(EQ, Literal(ScalarValue(int64, 2)), Literal(ScalarValue(int64, 0))) THEN Literal(ScalarValue(null, float64)), ELSE BinaryOp(DIV, ColRef(dc), Literal(ScalarValue(int64, 2)))), \"f\")])\n"
        "  Scan(path=\"t.parquet\", type=PARQUET, source_kind=COLUMNAR)\n"
    )


def test_power_starts_with_concat_and_like() raises:
    _check(
        "SELECT k ^ 2 AS p, s ^@ 'a' AS sw FROM t",
        "Project(exprs=[Alias(MathFn2(op=1, ColRef(k), Literal(ScalarValue(int64, 2))), \"p\"), Alias(StringOp(STARTS_WITH, ColRef(s), \"a\"), \"sw\")])\n"
        "  Scan(path=\"t.parquet\", type=PARQUET, source_kind=COLUMNAR)\n"
    )
    _check(
        "SELECT s ^@ s FROM t",
        "ERR: SQL not supported: the `^@` (starts-with) operator's right operand must be a string literal — a per-row prefix is a different operation this predicate node cannot express"
    )
    _check(
        "SELECT s || 'x' FROM t",
        "ERR: SQL not supported: the `||` string-concatenation operator. DuckDB's `||` PROPAGATES NULL (`'a' || NULL` is NULL) where this engine's only concatenation, `concat()`, SKIPS a NULL operand (`concat('a', NULL)` is 'a'), and answering one for the other would be wrong on every row with a NULL. The missing primitive is a STRING-typed NULL value in the plan (the CASE that would propagate the NULL has no string NULL to return). `concat(a, b)` is served for the NULL-skipping answer, and is EXACT wherever neither operand can be NULL."
    )
    _check(
        "SELECT s LIKE 'a%' AS l1, s NOT LIKE 'a%' AS l2, s ILIKE 'A%' AS l3 FROM t",
        "Project(exprs=[Alias(StringOp(LIKE, ColRef(s), \"a%\"), \"l1\"), Alias(UnaryOp(NOT, StringOp(LIKE, ColRef(s), \"a%\")), \"l2\"), Alias(StringOp(LIKE, StringFn(op=1, ColRef(s)), \"a%\"), \"l3\")])\n"
        "  Scan(path=\"t.parquet\", type=PARQUET, source_kind=COLUMNAR)\n"
    )
    _check(
        "SELECT k FROM t WHERE k > 1 AND v < 2 OR s = 'x'",
        "Project(exprs=[ColRef(k)])\n"
        "  Filter(predicate=BinaryOp(OR, BinaryOp(AND, BinaryOp(GT, ColRef(k), Literal(ScalarValue(int64, 1))), BinaryOp(LT, ColRef(v), Literal(ScalarValue(int64, 2)))), BinaryOp(EQ, ColRef(s), Literal(ScalarValue(utf8, \"x\")))))\n"
        "    Scan(path=\"t.parquet\", type=PARQUET, source_kind=COLUMNAR)\n"
    )


def test_unary_operators() raises:
    _check(
        "SELECT -k AS n, @k AS a, NOT b AS nb, k IS NULL AS isn, k IS NOT NULL AS inn FROM t",
        "Project(exprs=[Alias(UnaryOp(NEGATE, ColRef(k)), \"n\"), Alias(UnaryOp(ABS, ColRef(k)), \"a\"), Alias(UnaryOp(NOT, ColRef(b)), \"nb\"), Alias(UnaryOp(IS_NULL, ColRef(k)), \"isn\"), Alias(UnaryOp(IS_NOT_NULL, ColRef(k)), \"inn\")])\n"
        "  Scan(path=\"t.parquet\", type=PARQUET, source_kind=COLUMNAR)\n"
    )


def test_null_comparisons() raises:
    _check(
        "SELECT k FROM t WHERE k = NULL",
        "Project(exprs=[ColRef(k)])\n"
        "  Filter(predicate=BinaryOp(EQ, ColRef(k), Literal(ScalarValue(null, int64))))\n"
        "    Scan(path=\"t.parquet\", type=PARQUET, source_kind=COLUMNAR)\n"
    )
    _check(
        "SELECT k FROM t WHERE NULL = k",
        "Project(exprs=[ColRef(k)])\n"
        "  Filter(predicate=BinaryOp(EQ, ColRef(k), Literal(ScalarValue(null, int64))))\n"
        "    Scan(path=\"t.parquet\", type=PARQUET, source_kind=COLUMNAR)\n"
    )
    _check(
        "SELECT k FROM t WHERE k IN (1, NULL)",
        "Project(exprs=[ColRef(k)])\n"
        "  Filter(predicate=BinaryOp(OR, BinaryOp(EQ, ColRef(k), Literal(ScalarValue(int64, 1))), BinaryOp(EQ, ColRef(k), Literal(ScalarValue(null, int64)))))\n"
        "    Scan(path=\"t.parquet\", type=PARQUET, source_kind=COLUMNAR)\n"
    )
    _check(
        "SELECT NULL AS n FROM t",
        "ERR: SQL not supported: a NULL literal is served as a comparison operand (`x = NULL`, `x <> NULL`) and as an IN-list member (`x IN (1, NULL)`, `x NOT IN (1, NULL)`), as a CASE's `ELSE NULL`, as a CASE `THEN NULL` beside INT64 or FLOAT64 arms, and as a COALESCE / IFNULL argument beside a typed one; anywhere else (a projected NULL, `NOT NULL`, `NULL = NULL`, any other function argument, arithmetic, a CASE or COALESCE whose EVERY value is NULL) it needs a typed NULL value this engine's plan does not carry"
    )
    _check(
        "SELECT k FROM t WHERE NULL = NULL",
        "ERR: SQL not supported: a NULL literal is served as a comparison operand (`x = NULL`, `x <> NULL`) and as an IN-list member (`x IN (1, NULL)`, `x NOT IN (1, NULL)`), as a CASE's `ELSE NULL`, as a CASE `THEN NULL` beside INT64 or FLOAT64 arms, and as a COALESCE / IFNULL argument beside a typed one; anywhere else (a projected NULL, `NOT NULL`, `NULL = NULL`, any other function argument, arithmetic, a CASE or COALESCE whose EVERY value is NULL) it needs a typed NULL value this engine's plan does not carry"
    )


def test_integer_literal_past_bigint() raises:
    _check(
        "SELECT k FROM t WHERE u64 = 18446744073709551615",
        "Project(exprs=[ColRef(k)])\n"
        "  Filter(predicate=BinaryOp(EQ, ColRef(u64), Literal(ScalarValue(uint64, -1))))\n"
        "    Scan(path=\"t.parquet\", type=PARQUET, source_kind=COLUMNAR)\n"
    )
    _check(
        "SELECT k FROM t WHERE 18446744073709551615 = u64",
        "Project(exprs=[ColRef(k)])\n"
        "  Filter(predicate=BinaryOp(EQ, Literal(ScalarValue(uint64, -1)), ColRef(u64)))\n"
        "    Scan(path=\"t.parquet\", type=PARQUET, source_kind=COLUMNAR)\n"
    )
    _check(
        "SELECT k FROM t WHERE u64 = 18446744073709551616",
        "ERR: SQL not supported: the integer literal 18446744073709551616 is past BIGINT (9223372036854775807). DuckDB types it HUGEINT, a type this engine has no literal or column for; it is served only as one side of a comparison (= <> < <= > >=) against a plain column, when it fits UBIGINT (<= 18446744073709551615)."
    )
    _check(
        "SELECT 18446744073709551615 AS big FROM t",
        "ERR: SQL not supported: the integer literal 18446744073709551615 is past BIGINT (9223372036854775807). DuckDB types it HUGEINT, a type this engine has no literal or column for; it is served only as one side of a comparison (= <> < <= > >=) against a plain column, when it fits UBIGINT (<= 18446744073709551615)."
    )


def test_integer_cast_comparison_unwrap() raises:
    _check(
        "SELECT k FROM t WHERE CAST(k AS INTEGER) > 0",
        "Project(exprs=[ColRef(k)])\n"
        "  Filter(predicate=BinaryOp(GT, ColRef(k), Literal(ScalarValue(int64, 0))))\n"
        "    Scan(path=\"t.parquet\", type=PARQUET, source_kind=COLUMNAR)\n"
    )
    _check(
        "SELECT k FROM t WHERE 0 < CAST(k AS INTEGER)",
        "Project(exprs=[ColRef(k)])\n"
        "  Filter(predicate=BinaryOp(LT, Literal(ScalarValue(int64, 0)), ColRef(k)))\n"
        "    Scan(path=\"t.parquet\", type=PARQUET, source_kind=COLUMNAR)\n"
    )
    _check(
        "SELECT k FROM t WHERE CAST(k AS INTEGER) > 3000000000",
        "Project(exprs=[ColRef(k)])\n"
        "  Filter(predicate=BinaryOp(GT, Cast(Cast(ColRef(k), float64), int32), Literal(ScalarValue(int64, 3000000000))))\n"
        "    Scan(path=\"t.parquet\", type=PARQUET, source_kind=COLUMNAR)\n"
    )
    _check(
        "SELECT k FROM t WHERE CAST(CAST(k AS INTEGER) AS BIGINT) > 0",
        "Project(exprs=[ColRef(k)])\n"
        "  Filter(predicate=BinaryOp(GT, ColRef(k), Literal(ScalarValue(int64, 0))))\n"
        "    Scan(path=\"t.parquet\", type=PARQUET, source_kind=COLUMNAR)\n"
    )
    _check(
        "SELECT k FROM t WHERE CAST(k AS INTEGER) IN (5, 7)",
        "Project(exprs=[ColRef(k)])\n"
        "  Filter(predicate=BinaryOp(OR, BinaryOp(EQ, ColRef(k), Literal(ScalarValue(int64, 5))), BinaryOp(EQ, ColRef(k), Literal(ScalarValue(int64, 7)))))\n"
        "    Scan(path=\"t.parquet\", type=PARQUET, source_kind=COLUMNAR)\n"
    )
    _check(
        "SELECT k FROM t WHERE CAST(CAST(k AS INTEGER) AS BIGINT) IN (5, 7)",
        "Project(exprs=[ColRef(k)])\n"
        "  Filter(predicate=BinaryOp(OR, BinaryOp(EQ, Cast(Cast(Cast(ColRef(k), float64), int32), int64), Literal(ScalarValue(int64, 5))), BinaryOp(EQ, Cast(Cast(Cast(ColRef(k), float64), int32), int64), Literal(ScalarValue(int64, 7)))))\n"
        "    Scan(path=\"t.parquet\", type=PARQUET, source_kind=COLUMNAR)\n"
    )
    _check(
        "SELECT k FROM t WHERE CAST(k AS INTEGER) NOT IN (5, 7)",
        "Project(exprs=[ColRef(k)])\n"
        "  Filter(predicate=BinaryOp(AND, BinaryOp(NE, Cast(Cast(ColRef(k), float64), int32), Literal(ScalarValue(int64, 5))), BinaryOp(NE, Cast(Cast(ColRef(k), float64), int32), Literal(ScalarValue(int64, 7)))))\n"
        "    Scan(path=\"t.parquet\", type=PARQUET, source_kind=COLUMNAR)\n"
    )
    _check(
        "SELECT k FROM t WHERE CAST(k AS SMALLINT) > 40000",
        "ERR: SQL not supported: CAST to SMALLINT. This engine converts to INTEGER / BIGINT / REAL / DOUBLE — the four targets its cast kernels reach from every numeric source — and refuses every other target BY NAME rather than approximating it with the nearest one: a CAST that answered a number of the wrong type would be a wrong answer with a success code."
    )
    _check(
        "SELECT k FROM t WHERE CAST(k AS TINYINT) > 5",
        "Project(exprs=[ColRef(k)])\n"
        "  Filter(predicate=BinaryOp(GT, ColRef(k), Literal(ScalarValue(int64, 5))))\n"
        "    Scan(path=\"t.parquet\", type=PARQUET, source_kind=COLUMNAR)\n"
    )
    _check(
        "SELECT k FROM t WHERE CAST(v AS INTEGER) > 0",
        "Project(exprs=[ColRef(k)])\n"
        "  Filter(predicate=BinaryOp(GT, Cast(ColRef(v), int32), Literal(ScalarValue(int64, 0))))\n"
        "    Scan(path=\"t.parquet\", type=PARQUET, source_kind=COLUMNAR)\n"
    )


def test_integer_cast_constant_moves() raises:
    _check(
        "SELECT k FROM t WHERE CAST(k AS INTEGER) + 1 > 0",
        "Project(exprs=[ColRef(k)])\n"
        "  Filter(predicate=BinaryOp(GT, ColRef(k), Literal(ScalarValue(int64, -1))))\n"
        "    Scan(path=\"t.parquet\", type=PARQUET, source_kind=COLUMNAR)\n"
    )
    _check(
        "SELECT k FROM t WHERE CAST(k AS INTEGER) - 1 > 0",
        "Project(exprs=[ColRef(k)])\n"
        "  Filter(predicate=BinaryOp(GT, ColRef(k), Literal(ScalarValue(int64, 1))))\n"
        "    Scan(path=\"t.parquet\", type=PARQUET, source_kind=COLUMNAR)\n"
    )
    _check(
        "SELECT k FROM t WHERE 1 + CAST(k AS INTEGER) > 0",
        "Project(exprs=[ColRef(k)])\n"
        "  Filter(predicate=BinaryOp(GT, ColRef(k), Literal(ScalarValue(int64, -1))))\n"
        "    Scan(path=\"t.parquet\", type=PARQUET, source_kind=COLUMNAR)\n"
    )
    _check(
        "SELECT k FROM t WHERE 0 < CAST(k AS INTEGER) + 1",
        "Project(exprs=[ColRef(k)])\n"
        "  Filter(predicate=BinaryOp(LT, Literal(ScalarValue(int64, -1)), ColRef(k)))\n"
        "    Scan(path=\"t.parquet\", type=PARQUET, source_kind=COLUMNAR)\n"
    )
    _check(
        "SELECT k FROM t WHERE CAST(k AS INTEGER) + 1 IN (6, 7)",
        "Project(exprs=[ColRef(k)])\n"
        "  Filter(predicate=BinaryOp(OR, BinaryOp(EQ, BinaryOp(ADD, Cast(Cast(ColRef(k), float64), int32), Literal(ScalarValue(int64, 1))), Literal(ScalarValue(int64, 6))), BinaryOp(EQ, BinaryOp(ADD, Cast(Cast(ColRef(k), float64), int32), Literal(ScalarValue(int64, 1))), Literal(ScalarValue(int64, 7)))))\n"
        "    Scan(path=\"t.parquet\", type=PARQUET, source_kind=COLUMNAR)\n"
    )
    _check(
        "SELECT k FROM t WHERE CAST(k AS INTEGER) + 9223372036854775807 > -10",
        "Project(exprs=[ColRef(k)])\n"
        "  Filter(predicate=BinaryOp(GT, BinaryOp(ADD, Cast(Cast(ColRef(k), float64), int32), Literal(ScalarValue(int64, 9223372036854775807))), Literal(ScalarValue(int64, -10))))\n"
        "    Scan(path=\"t.parquet\", type=PARQUET, source_kind=COLUMNAR)\n"
    )


def test_literals_and_dates() raises:
    _check(
        "SELECT 'abc' AS s1, 1.5 AS f1, true AS t1, false AS f2 FROM t",
        "Project(exprs=[Alias(Literal(ScalarValue(utf8, \"abc\")), \"s1\"), Alias(Literal(ScalarValue(float64, 1.5)), \"f1\"), Alias(Literal(ScalarValue(bool, true)), \"t1\"), Alias(Literal(ScalarValue(bool, false)), \"f2\")])\n"
        "  Scan(path=\"t.parquet\", type=PARQUET, source_kind=COLUMNAR)\n"
    )
    _check(
        "SELECT k FROM t WHERE true",
        "Project(exprs=[ColRef(k)])\n"
        "  Filter(predicate=Literal(ScalarValue(bool, true)))\n"
        "    Scan(path=\"t.parquet\", type=PARQUET, source_kind=COLUMNAR)\n"
    )
    _check(
        "SELECT k FROM t WHERE d = DATE '2021-02-28'",
        "Project(exprs=[ColRef(k)])\n"
        "  Filter(predicate=BinaryOp(EQ, ColRef(d), Literal(ScalarValue(date32, 18686))))\n"
        "    Scan(path=\"t.parquet\", type=PARQUET, source_kind=COLUMNAR)\n"
    )
    _check(
        "SELECT k FROM t WHERE d = DATE '2021-02-30'",
        "ERR: SQL bind error: date out of range '2021-02-30'"
    )
    _check(
        "SELECT k FROM t WHERE d = DATE '2020-02-29'",
        "Project(exprs=[ColRef(k)])\n"
        "  Filter(predicate=BinaryOp(EQ, ColRef(d), Literal(ScalarValue(date32, 18321))))\n"
        "    Scan(path=\"t.parquet\", type=PARQUET, source_kind=COLUMNAR)\n"
    )
    _check(
        "SELECT k FROM t WHERE d = DATE '2021-13-01'",
        "ERR: SQL bind error: date out of range '2021-13-01'"
    )
    _check(
        "SELECT k FROM t WHERE d = DATE '21-01-01'",
        "ERR: SQL bind error: malformed date literal '21-01-01' (want YYYY-MM-DD)"
    )
    _check(
        "SELECT k FROM t WHERE d = DATE '1900-02-29'",
        "ERR: SQL bind error: date out of range '1900-02-29'"
    )
    _check(
        "SELECT k FROM t WHERE d = DATE '2000-02-29'",
        "Project(exprs=[ColRef(k)])\n"
        "  Filter(predicate=BinaryOp(EQ, ColRef(d), Literal(ScalarValue(date32, 11016))))\n"
        "    Scan(path=\"t.parquet\", type=PARQUET, source_kind=COLUMNAR)\n"
    )
    _check(
        "SELECT k FROM t WHERE d = DATE '2021-04-31'",
        "ERR: SQL bind error: date out of range '2021-04-31'"
    )


def test_case_typing() raises:
    _check(
        "SELECT CASE WHEN k > 1 THEN v ELSE 0 END AS c1 FROM t",
        "Project(exprs=[Alias(When(WHEN BinaryOp(GT, ColRef(k), Literal(ScalarValue(int64, 1))) THEN ColRef(v), ELSE Literal(ScalarValue(float64, 0.0))), \"c1\")])\n"
        "  Scan(path=\"t.parquet\", type=PARQUET, source_kind=COLUMNAR)\n"
    )
    _check(
        "SELECT CASE WHEN k > 1 THEN 1 END AS c2 FROM t",
        "Project(exprs=[Alias(When(WHEN BinaryOp(GT, ColRef(k), Literal(ScalarValue(int64, 1))) THEN Literal(ScalarValue(int64, 1)), ELSE Literal(ScalarValue(null, int64))), \"c2\")])\n"
        "  Scan(path=\"t.parquet\", type=PARQUET, source_kind=COLUMNAR)\n"
    )
    _check(
        "SELECT CASE WHEN k > 1 THEN NULL ELSE 2 END AS c3 FROM t",
        "Project(exprs=[Alias(When(WHEN BinaryOp(GT, ColRef(k), Literal(ScalarValue(int64, 1))) THEN Literal(ScalarValue(null, int64)), ELSE Literal(ScalarValue(int64, 2))), \"c3\")])\n"
        "  Scan(path=\"t.parquet\", type=PARQUET, source_kind=COLUMNAR)\n"
    )
    _check(
        "SELECT CASE WHEN k > 1 THEN NULL ELSE 2.5 END AS c4 FROM t",
        "Project(exprs=[Alias(When(WHEN BinaryOp(GT, ColRef(k), Literal(ScalarValue(int64, 1))) THEN Literal(ScalarValue(null, float64)), ELSE Literal(ScalarValue(float64, 2.5))), \"c4\")])\n"
        "  Scan(path=\"t.parquet\", type=PARQUET, source_kind=COLUMNAR)\n"
    )
    _check(
        "SELECT CASE WHEN k > 1 THEN NULL ELSE s END AS c5 FROM t",
        "ERR: SQL not supported: a CASE arm `THEN NULL` beside arms that are neither INT64 nor FLOAT64 (a string, a date, a boolean or a narrower integer). DuckDB types the NULL as its sibling arms; the typed NULL values this engine's plan can carry are INT64 and FLOAT64 only, and every CASE arm must share one type. A NULL beside INT64 or FLOAT64 arms is served; so is an omitted ELSE."
    )
    _check(
        "SELECT CASE WHEN k > 1 THEN NULL ELSE NULL END AS c6 FROM t",
        "ERR: SQL not supported: a NULL literal is served as a comparison operand (`x = NULL`, `x <> NULL`) and as an IN-list member (`x IN (1, NULL)`, `x NOT IN (1, NULL)`), as a CASE's `ELSE NULL`, as a CASE `THEN NULL` beside INT64 or FLOAT64 arms, and as a COALESCE / IFNULL argument beside a typed one; anywhere else (a projected NULL, `NOT NULL`, `NULL = NULL`, any other function argument, arithmetic, a CASE or COALESCE whose EVERY value is NULL) it needs a typed NULL value this engine's plan does not carry"
    )
    _check(
        "SELECT CASE WHEN k > 1 THEN 1 ELSE NULL END AS c7 FROM t",
        "Project(exprs=[Alias(When(WHEN BinaryOp(GT, ColRef(k), Literal(ScalarValue(int64, 1))) THEN Literal(ScalarValue(int64, 1)), ELSE Literal(ScalarValue(null, int64))), \"c7\")])\n"
        "  Scan(path=\"t.parquet\", type=PARQUET, source_kind=COLUMNAR)\n"
    )
    _check(
        "SELECT CASE k WHEN 1 THEN 'a' ELSE 'b' END AS c8 FROM t",
        "Project(exprs=[Alias(When(WHEN BinaryOp(EQ, ColRef(k), Literal(ScalarValue(int64, 1))) THEN Literal(ScalarValue(utf8, \"a\")), ELSE Literal(ScalarValue(utf8, \"b\"))), \"c8\")])\n"
        "  Scan(path=\"t.parquet\", type=PARQUET, source_kind=COLUMNAR)\n"
    )


def test_scalar_position_refusals() raises:
    _check(
        "SELECT rank() OVER (ORDER BY k) + 1 FROM t",
        "ERR: SQL not supported: a window function `f(...) OVER (...)` must be a top-level SELECT item (it cannot be nested inside an expression)"
    )
    _check(
        "SELECT sum(k) FROM t WHERE sum(k) > 1",
        "ERR: SQL bind error: aggregate function not allowed in this position"
    )


def test_case_typing_of_more_arm_shapes() raises:
    _check(
        "SELECT CASE WHEN k > 1 THEN v END AS c FROM t",
        "Project(exprs=[Alias(When(WHEN BinaryOp(GT, ColRef(k), Literal(ScalarValue(int64, 1))) THEN ColRef(v), ELSE Literal(ScalarValue(null, float64))), \"c\")])\n"
        "  Scan(path=\"t.parquet\", type=PARQUET, source_kind=COLUMNAR)\n"
    )
    _check(
        "SELECT CASE WHEN k > 1 THEN NULL WHEN k > 2 THEN 5 ELSE 6 END AS c FROM t",
        "Project(exprs=[Alias(When(WHEN BinaryOp(GT, ColRef(k), Literal(ScalarValue(int64, 1))) THEN Literal(ScalarValue(null, int64)), WHEN BinaryOp(GT, ColRef(k), Literal(ScalarValue(int64, 2))) THEN Literal(ScalarValue(int64, 5)), ELSE Literal(ScalarValue(int64, 6))), \"c\")])\n"
        "  Scan(path=\"t.parquet\", type=PARQUET, source_kind=COLUMNAR)\n"
    )
    _check(
        "SELECT CASE WHEN k > 1 THEN NULL WHEN k > 2 THEN 5.5 ELSE 6 END AS c FROM t",
        "Project(exprs=[Alias(When(WHEN BinaryOp(GT, ColRef(k), Literal(ScalarValue(int64, 1))) THEN Literal(ScalarValue(null, float64)), WHEN BinaryOp(GT, ColRef(k), Literal(ScalarValue(int64, 2))) THEN Literal(ScalarValue(float64, 5.5)), ELSE Literal(ScalarValue(float64, 6.0))), \"c\")])\n"
        "  Scan(path=\"t.parquet\", type=PARQUET, source_kind=COLUMNAR)\n"
    )
    _check(
        "SELECT CASE WHEN k > 1 THEN NULL WHEN k > 2 THEN k + 1 END AS c FROM t",
        "Project(exprs=[Alias(When(WHEN BinaryOp(GT, ColRef(k), Literal(ScalarValue(int64, 1))) THEN Literal(ScalarValue(null, int64)), WHEN BinaryOp(GT, ColRef(k), Literal(ScalarValue(int64, 2))) THEN BinaryOp(ADD, ColRef(k), Literal(ScalarValue(int64, 1))), ELSE Literal(ScalarValue(null, int64))), \"c\")])\n"
        "  Scan(path=\"t.parquet\", type=PARQUET, source_kind=COLUMNAR)\n"
    )
    _check(
        "SELECT CASE WHEN k > 1 THEN k + v ELSE 0 END AS c FROM t",
        "Project(exprs=[Alias(When(WHEN BinaryOp(GT, ColRef(k), Literal(ScalarValue(int64, 1))) THEN BinaryOp(ADD, ColRef(k), ColRef(v)), ELSE Literal(ScalarValue(float64, 0.0))), \"c\")])\n"
        "  Scan(path=\"t.parquet\", type=PARQUET, source_kind=COLUMNAR)\n"
    )
    _check(
        "SELECT CASE WHEN k > 1 THEN CAST(k AS DOUBLE) ELSE 0 END AS c FROM t",
        "Project(exprs=[Alias(When(WHEN BinaryOp(GT, ColRef(k), Literal(ScalarValue(int64, 1))) THEN Cast(ColRef(k), float64), ELSE Literal(ScalarValue(float64, 0.0))), \"c\")])\n"
        "  Scan(path=\"t.parquet\", type=PARQUET, source_kind=COLUMNAR)\n"
    )
    _check(
        "SELECT CASE WHEN k > 1 THEN NULL ELSE i32 END AS c FROM t",
        "ERR: SQL not supported: a CASE arm `THEN NULL` beside arms that are neither INT64 nor FLOAT64 (a string, a date, a boolean or a narrower integer). DuckDB types the NULL as its sibling arms; the typed NULL values this engine's plan can carry are INT64 and FLOAT64 only, and every CASE arm must share one type. A NULL beside INT64 or FLOAT64 arms is served; so is an omitted ELSE."
    )
    _check(
        "SELECT coalesce(k + v, 0) AS c FROM t",
        "Project(exprs=[Alias(When(WHEN UnaryOp(IS_NOT_NULL, BinaryOp(ADD, ColRef(k), ColRef(v))) THEN BinaryOp(ADD, ColRef(k), ColRef(v)), ELSE Literal(ScalarValue(float64, 0.0))), \"c\")])\n"
        "  Scan(path=\"t.parquet\", type=PARQUET, source_kind=COLUMNAR)\n"
    )


def test_integer_cast_unwrap_declines() raises:
    _check(
        "SELECT k FROM t WHERE CAST(k AS INTEGER) > 1.5",
        "Project(exprs=[ColRef(k)])\n"
        "  Filter(predicate=BinaryOp(GT, Cast(Cast(ColRef(k), float64), int32), Literal(ScalarValue(float64, 1.5))))\n"
        "    Scan(path=\"t.parquet\", type=PARQUET, source_kind=COLUMNAR)\n"
    )
    _check(
        "SELECT k FROM t WHERE CAST(k AS DOUBLE) > 1",
        "Project(exprs=[ColRef(k)])\n"
        "  Filter(predicate=BinaryOp(GT, Cast(ColRef(k), float64), Literal(ScalarValue(int64, 1))))\n"
        "    Scan(path=\"t.parquet\", type=PARQUET, source_kind=COLUMNAR)\n"
    )
    _check(
        "SELECT k FROM t WHERE CAST(k + 1 AS INTEGER) > 0",
        "Project(exprs=[ColRef(k)])\n"
        "  Filter(predicate=BinaryOp(GT, Cast(Cast(BinaryOp(ADD, ColRef(k), Literal(ScalarValue(int64, 1))), float64), int32), Literal(ScalarValue(int64, 0))))\n"
        "    Scan(path=\"t.parquet\", type=PARQUET, source_kind=COLUMNAR)\n"
    )
    _check(
        "SELECT k FROM t WHERE CAST(s AS INTEGER) > 0",
        "ERR: SQL not supported: CAST from a STRING to INTEGER. What is refused is the ROUNDING: DuckDB v1.5.3 answers 4 for CAST('3.5' AS BIGINT) and 3 for CAST('2.5' AS BIGINT), rounding half AWAY FROM ZERO — a third model, different again from the half-to-even it uses for CAST(<double> AS BIGINT) — and this engine has no string parse with that rounding, so serving this would raise or answer differently where DuckDB answers a number. Convert in your application, or cast a numeric column instead."
    )
    _check(
        "SELECT k FROM t WHERE CAST(k AS INTEGER) * 2 > 0",
        "Project(exprs=[ColRef(k)])\n"
        "  Filter(predicate=BinaryOp(GT, BinaryOp(MUL, Cast(Cast(ColRef(k), float64), int32), Literal(ScalarValue(int64, 2))), Literal(ScalarValue(int64, 0))))\n"
        "    Scan(path=\"t.parquet\", type=PARQUET, source_kind=COLUMNAR)\n"
    )
    _check(
        "SELECT k FROM t WHERE k + 1 > 0",
        "Project(exprs=[ColRef(k)])\n"
        "  Filter(predicate=BinaryOp(GT, BinaryOp(ADD, ColRef(k), Literal(ScalarValue(int64, 1))), Literal(ScalarValue(int64, 0))))\n"
        "    Scan(path=\"t.parquet\", type=PARQUET, source_kind=COLUMNAR)\n"
    )
    _check(
        "SELECT k FROM t WHERE 5 - CAST(k AS INTEGER) > 0",
        "Project(exprs=[ColRef(k)])\n"
        "  Filter(predicate=BinaryOp(GT, BinaryOp(SUB, Literal(ScalarValue(int64, 5)), Cast(Cast(ColRef(k), float64), int32)), Literal(ScalarValue(int64, 0))))\n"
        "    Scan(path=\"t.parquet\", type=PARQUET, source_kind=COLUMNAR)\n"
    )
    _check(
        "SELECT k FROM t WHERE CAST(k AS INTEGER) + 1 > 18446744073709551615",
        "ERR: SQL not supported: the integer literal 18446744073709551615 is past BIGINT (9223372036854775807). DuckDB types it HUGEINT, a type this engine has no literal or column for; it is served only as one side of a comparison (= <> < <= > >=) against a plain column, when it fits UBIGINT (<= 18446744073709551615)."
    )
    _check(
        "SELECT k FROM t WHERE CAST(k AS INTEGER) + 18446744073709551615 > 0",
        "ERR: SQL not supported: the integer literal 18446744073709551615 is past BIGINT (9223372036854775807). DuckDB types it HUGEINT, a type this engine has no literal or column for; it is served only as one side of a comparison (= <> < <= > >=) against a plain column, when it fits UBIGINT (<= 18446744073709551615)."
    )
    _check(
        "SELECT k FROM t WHERE CAST(k AS INTEGER) + 1 > 3000000000",
        "Project(exprs=[ColRef(k)])\n"
        "  Filter(predicate=BinaryOp(GT, BinaryOp(ADD, Cast(Cast(ColRef(k), float64), int32), Literal(ScalarValue(int64, 1))), Literal(ScalarValue(int64, 3000000000))))\n"
        "    Scan(path=\"t.parquet\", type=PARQUET, source_kind=COLUMNAR)\n"
    )
    _check(
        "SELECT k FROM t WHERE CAST(k AS INTEGER) + 2 > -9223372036854775807",
        "Project(exprs=[ColRef(k)])\n"
        "  Filter(predicate=BinaryOp(GT, BinaryOp(ADD, Cast(Cast(ColRef(k), float64), int32), Literal(ScalarValue(int64, 2))), Literal(ScalarValue(int64, -9223372036854775807))))\n"
        "    Scan(path=\"t.parquet\", type=PARQUET, source_kind=COLUMNAR)\n"
    )
    _check(
        "SELECT k FROM t WHERE CAST(k AS INTEGER) + -2 > 9223372036854775807",
        "Project(exprs=[ColRef(k)])\n"
        "  Filter(predicate=BinaryOp(GT, BinaryOp(ADD, Cast(Cast(ColRef(k), float64), int32), Literal(ScalarValue(int64, -2))), Literal(ScalarValue(int64, 9223372036854775807))))\n"
        "    Scan(path=\"t.parquet\", type=PARQUET, source_kind=COLUMNAR)\n"
    )
    _check(
        "SELECT k FROM t WHERE CAST(k AS INTEGER) - 2 > 9223372036854775807",
        "Project(exprs=[ColRef(k)])\n"
        "  Filter(predicate=BinaryOp(GT, BinaryOp(SUB, Cast(Cast(ColRef(k), float64), int32), Literal(ScalarValue(int64, 2))), Literal(ScalarValue(int64, 9223372036854775807))))\n"
        "    Scan(path=\"t.parquet\", type=PARQUET, source_kind=COLUMNAR)\n"
    )
    _check(
        "SELECT k FROM t WHERE CAST(k AS INTEGER) - -2 > -9223372036854775807",
        "Project(exprs=[ColRef(k)])\n"
        "  Filter(predicate=BinaryOp(GT, BinaryOp(SUB, Cast(Cast(ColRef(k), float64), int32), Literal(ScalarValue(int64, -2))), Literal(ScalarValue(int64, -9223372036854775807))))\n"
        "    Scan(path=\"t.parquet\", type=PARQUET, source_kind=COLUMNAR)\n"
    )
    _check(
        "SELECT k FROM t WHERE CAST(k AS INTEGER) = 1 AND CAST(k AS BIGINT) <> 2 AND CAST(k AS INTEGER) <= 3 AND CAST(k AS INTEGER) >= 0 AND CAST(k AS INTEGER) < 9",
        "Project(exprs=[ColRef(k)])\n"
        "  Filter(predicate=BinaryOp(AND, BinaryOp(AND, BinaryOp(AND, BinaryOp(AND, BinaryOp(EQ, ColRef(k), Literal(ScalarValue(int64, 1))), BinaryOp(NE, ColRef(k), Literal(ScalarValue(int64, 2)))), BinaryOp(LE, ColRef(k), Literal(ScalarValue(int64, 3)))), BinaryOp(GE, ColRef(k), Literal(ScalarValue(int64, 0)))), BinaryOp(LT, ColRef(k), Literal(ScalarValue(int64, 9)))))\n"
        "    Scan(path=\"t.parquet\", type=PARQUET, source_kind=COLUMNAR)\n"
    )
    _check(
        "SELECT k FROM t WHERE k BETWEEN 1 AND 3",
        "Project(exprs=[ColRef(k)])\n"
        "  Filter(predicate=BinaryOp(AND, BinaryOp(GE, ColRef(k), Literal(ScalarValue(int64, 1))), BinaryOp(LE, ColRef(k), Literal(ScalarValue(int64, 3)))))\n"
        "    Scan(path=\"t.parquet\", type=PARQUET, source_kind=COLUMNAR)\n"
    )


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
