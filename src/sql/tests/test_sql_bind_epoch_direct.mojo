# =============================================================================
# Tests of epoch / epoch_ms / epoch_us binding (sql_bind_timestamp
# `_bind_epoch_count`)
# =============================================================================
#
# Each query is parsed and its select items bound with `_bind_scalar` against
# one table's schema; the test compares the bound expression text, or the
# binder's whole message.
#   1. A TIMESTAMP (with or without a zone) or DATE operand lowers to
#      EXPR_EXTRACT with EXTRACT_EPOCH (26), EXTRACT_EPOCH_MS (27) or
#      EXTRACT_EPOCH_US (28).
#   2. `epoch_ms` of an integer is the other DuckDB overload, the same
#      lowering as `make_timestamp_ms` (an INT32 is widened first).
#   3. An integer operand of `epoch` / `epoch_us`, a float, a string, an
#      untyped NULL and a wrong argument count are refused by name.
#   4. `date_part('epoch', x)` and `EXTRACT(epoch FROM x)` bind to the same
#      EXTRACT_EPOCH node as `epoch(x)`.

from std.testing import TestSuite, assert_equal

from arrow.arrow_types import ArrowType
from arrow.schema import Field, Schema, SchemaBuilder
from plan_expr.expr import Expr

from sql.sql_bind_expr import _bind_scalar
from sql.sql_bind_parquet import ParquetFacts
from sql.sql_bind_scope import CteScope, _build_bind_scope
from sql.sql_catalog import SqlCatalog
from sql.sql_parser import parse_sql
from sql.sql_token import tokenize


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
    t.add_field(Field.timestamp(String("tz"), ArrowType.TIMESTAMP_US, String("UTC"), True))
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


def _check(sql: String, want: String) raises:
    assert_equal(_got(sql), want, sql)


comptime _SCAN = "  Scan(path=\"t.parquet\", type=PARQUET, source_kind=COLUMNAR)\n"


def test_a_timestamp_lowers_to_the_epoch_extract_units() raises:
    """epoch -> unit 26, epoch_ms -> 27, epoch_us -> 28, over a column and
    over a TIMESTAMP literal."""
    _check(
        "SELECT epoch(ts) AS a, epoch_ms(ts) AS b, epoch_us(ts) AS c FROM t",
        "Project(exprs=[Alias(Extract(unit=26, ColRef(ts)), \"a\"), Alias(Extract(unit=27, ColRef(ts)), \"b\"), Alias(Extract(unit=28, ColRef(ts)), \"c\")])\n"
        + _SCAN,
    )
    _check(
        "SELECT epoch(TIMESTAMP '2026-09-01 00:00:00.5') FROM t",
        "Project(exprs=[Extract(unit=26, Literal(ScalarValue(timestamp[us], 1788220800500000)))])\n"
        + _SCAN,
    )


def test_a_date_and_a_zoned_timestamp_are_counted_too() raises:
    """DuckDB has DATE and TIMESTAMP WITH TIME ZONE overloads of all three; a
    zoned timestamp holds UTC ticks, so its count is the same lowering."""
    _check(
        "SELECT epoch(d) AS a, epoch_ms(tz) AS b FROM t",
        "Project(exprs=[Alias(Extract(unit=26, ColRef(d)), \"a\"), Alias(Extract(unit=27, ColRef(tz)), \"b\")])\n"
        + _SCAN,
    )


def test_epoch_ms_of_an_integer_is_make_timestamp_ms() raises:
    """epoch_ms(BIGINT) -> TIMESTAMP in DuckDB: the bound expression is the
    one make_timestamp_ms(k) binds to, and an INT32 is widened first."""
    _check(
        "SELECT epoch_ms(k) AS a, make_timestamp_ms(k) AS b, epoch_ms(i32) AS c FROM t",
        "Project(exprs=[Alias(Cast(Cast(ColRef(k), int64, arrow=timestamp[ms]), int64, arrow=timestamp[us]), \"a\"), Alias(Cast(Cast(ColRef(k), int64, arrow=timestamp[ms]), int64, arrow=timestamp[us]), \"b\"), Alias(Cast(Cast(Cast(ColRef(i32), int64), int64, arrow=timestamp[ms]), int64, arrow=timestamp[us]), \"c\")])\n"
        + _SCAN,
    )


def test_an_integer_has_no_epoch_or_epoch_us_overload() raises:
    """DuckDB refuses epoch(42) and epoch_us(42::BIGINT) at bind; so does this."""
    _check(
        "SELECT epoch(k) FROM t",
        "ERR: SQL not supported: `epoch` takes a TIMESTAMP or a DATE, but this argument is of type int64. The TIME and INTERVAL overloads DuckDB also has are not served, and an untyped NULL matches more than one overload: cast it, as in `NULL::TIMESTAMP`.",
    )
    _check(
        "SELECT epoch_us(k) FROM t",
        "ERR: SQL not supported: `epoch_us` takes a TIMESTAMP or a DATE, but this argument is of type int64. The TIME and INTERVAL overloads DuckDB also has are not served, and an untyped NULL matches more than one overload: cast it, as in `NULL::TIMESTAMP`.",
    )


def test_other_operands_are_refused_by_type() raises:
    """A float, a string and an untyped NULL are refused, naming the type."""
    _check(
        "SELECT epoch_ms(v) FROM t",
        "ERR: SQL not supported: `epoch_ms` takes a TIMESTAMP, a DATE, or a BIGINT millisecond count, but this argument is of type float64. The TIME and INTERVAL overloads DuckDB also has are not served, and an untyped NULL matches more than one overload: cast it, as in `NULL::TIMESTAMP`.",
    )
    _check(
        "SELECT epoch(s) FROM t",
        "ERR: SQL not supported: `epoch` takes a TIMESTAMP or a DATE, but this argument is of type string. The TIME and INTERVAL overloads DuckDB also has are not served, and an untyped NULL matches more than one overload: cast it, as in `NULL::TIMESTAMP`.",
    )
    _check(
        "SELECT epoch_us(NULL) FROM t",
        "ERR: SQL not supported: `epoch_us` takes a TIMESTAMP or a DATE, but this argument is of type null. The TIME and INTERVAL overloads DuckDB also has are not served, and an untyped NULL matches more than one overload: cast it, as in `NULL::TIMESTAMP`.",
    )


def test_the_epoch_date_part_is_the_same_unit() raises:
    """date_part('epoch', x) and EXTRACT(epoch FROM x) are DOUBLE seconds in
    DuckDB, as epoch(x) is: the same EXTRACT_EPOCH node."""
    _check(
        "SELECT date_part('epoch', ts) AS a, EXTRACT(epoch FROM d) AS b FROM t",
        "Project(exprs=[Alias(Extract(unit=26, ColRef(ts)), \"a\"), Alias(Extract(unit=26, ColRef(d)), \"b\")])\n"
        + _SCAN,
    )


def test_a_wrong_argument_count_is_refused() raises:
    _check(
        "SELECT epoch(ts, ts) FROM t",
        "ERR: SQL bind error: `epoch` takes exactly ONE argument — a TIMESTAMP or DATE — but got 2.",
    )
    _check(
        "SELECT epoch_ms() FROM t",
        "ERR: SQL bind error: `epoch_ms` takes exactly ONE argument — a TIMESTAMP or DATE — but got 0.",
    )


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
