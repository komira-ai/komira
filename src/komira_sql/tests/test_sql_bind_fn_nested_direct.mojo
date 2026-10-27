# =============================================================================
# Tests of the function desugars over nested values and date arithmetic
# (sql_bind_fn_nested)
# =============================================================================
#
# Each query is parsed and its select items and WHERE predicate are bound with
# `_bind_scalar` against one table's schema; the test compares the bound
# expression text, or the binder's message.
#   1. JSON / struct / map extracts.
#   2. date_diff / date_sub (fold vs column arm), even, fdiv / fmod, nullif and
#      days_in_month.

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
        "ERR: SQL not supported: json_extract('$') — the whole-document extract. DuckDB v1.5.3 MINIFIES it (json_extract('  {\"a\" :  1 }  ', '$') = {\"a\":1}), and the engine's JSON extract (`extract_column` in komira_json_index) returns a zero-segment path's payload bytes VERBATIM, whitespace included, so this refuses rather than answering a different string"
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
        "ERR: SQL not supported: only date_sub('day', ...) is supported. date_sub counts COMPLETE periods and date_diff counts boundaries CROSSED — in DuckDB v1.5.3 they differ for every unit above 'day' (1 vs 2 over 2021-01-31 -> 2021-03-01), so the other units are not the neighbouring function's to answer"
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
        "ERR: SQL not supported: nullif() over a STRING operand. Its THEN arm is a typed NULL and this IR has no string-typed NULL literal (`ScalarValue.null` takes a DType, and the engine's scalar broadcast, `broadcast_scalar` in komira_column_kernels, builds an all-NULL column for float64 and int64 only), so there is no value to return for the matching rows. The numeric form is served."
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


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
