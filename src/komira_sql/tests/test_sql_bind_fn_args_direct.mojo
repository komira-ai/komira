# =============================================================================
# Tests of the function desugars over argument shapes (sql_bind_fn_args)
# =============================================================================
#
# Each query is parsed and its select items and WHERE predicate are bound with
# `_bind_scalar` against one table's schema; the test compares the bound
# expression text, or the binder's message.
#   1. greatest / least, coalesce / ifnull (a NULL argument dropped, all-NULL
#      refused).
#   2. date_part / date_trunc and their unit refusals; left / right /
#      substring; the year-derived parts, nanosecond, the float classes and
#      string_split.

from std.testing import TestSuite, assert_equal, assert_false, assert_true

from komira_arrow.arrow_types import ArrowType
from komira_arrow.schema import Field, Schema, SchemaBuilder
from komira_plan_expr.expr import Expr

from komira_sql.sql_bind_expr import _bind_scalar
from komira_sql.sql_bind_parquet import ParquetFacts
from komira_sql.sql_bind_scope import CteScope, _build_bind_scope
from komira_sql.sql_catalog import SqlCatalog
from komira_sql.sql_parser import parse_sql
from komira_sql.sql_token import tokenize


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
    (no file is opened)."""
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
    return cat^


def _got(sql: String) raises -> String:
    """Parse `sql` (one SELECT over one table), bind every select item and
    the WHERE predicate with `_bind_scalar` against the table's schema, and
    return the Project / Filter / Scan text of the result, or `ERR: ` and the
    binder's message."""
    var cat = _catalog()
    try:
        var st = parse_sql(tokenize(sql))
        var scope = _build_bind_scope(
            st.query.from_tables, st.query.joins, cat, CteScope(ParquetFacts())
        )
        var prebound = List[Expr]()
        var items = String("")
        for i in range(len(st.query.select_items)):
            ref item = st.query.select_items[i]
            var e = _bind_scalar(
                item.expr, scope.out_schema, scope, cat, CteScope(ParquetFacts()), prebound
            )
            if item.out_alias:
                e = Expr.alias(e^, item.out_alias.value())
            if i > 0:
                items += ", "
            items += String(e)
        var out = "Project(exprs=[" + items + "])\n"
        var pad = String("  ")
        if st.query.where_pred:
            var p = _bind_scalar(
                st.query.where_pred.value(), scope.out_schema, scope, cat,
                CteScope(ParquetFacts()), prebound,
            )
            out += pad + "Filter(predicate=" + String(p) + ")\n"
            pad += "  "
        return out + pad + "Scan(path=\"t.parquet\", type=PARQUET, source_kind=COLUMNAR)\n"
    except e:
        return String("ERR: ") + String(e)


def _check(sql: String, want: String) raises:
    assert_equal(_got(sql), want, sql)


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
        "SELECT left(s, -2147483649) FROM t",
        "ERR: SQL not supported: left() count below -2147483648"
    )
    _check(
        "SELECT right(s, -2147483649) FROM t",
        "ERR: SQL not supported: right() count below -2147483648"
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


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
