# =============================================================================
# Tests of make_date, last_day and the six-argument make_timestamp at bind
# (sql_bind_civil)
# =============================================================================
#
# Each query is parsed and its select items are bound with `_bind_scalar`
# against one table's schema. The expected day and microsecond counts are
# DuckDB v1.5.6's (`make_date(...) - DATE '1970-01-01'`,
# `epoch_us(make_timestamp(...))`), and every refusal of constant arguments is
# DuckDB's message for the same call, word for word.
#   1. All-constant calls fold to a DATE or TIMESTAMP literal: leap and
#      non-leap Februaries, year 0 and BC years, both ends of DATE's range,
#      fractional, 60 and 60.5 seconds, 24:00, the last microsecond of the
#      timestamp range.
#   2. Invalid constant calls are refused with DuckDB's message, in DuckDB's
#      order (the argument cast to INTEGER last-first, the date before the
#      time, the time before the timestamp range).
#   3. Column arguments build a DATE / TIMESTAMP expression; every integer
#      width, a NULL literal and every number type for the seconds are taken,
#      and every other type, a wrong count and a zoned timestamp are refused.
#   4. A column call's tree grows linearly with its arguments.
#   5. The value functions behind the fold: NaN, infinities and values past
#      INTEGER for the seconds, and the two roundings.

from std.math import inf, nan
from std.testing import TestSuite, assert_equal, assert_false, assert_true

from arrow.arrow_types import ArrowType
from arrow.schema import Field, Schema, SchemaBuilder
from plan_expr.expr import Expr
from plan_expr.expr_walk import PlanColRefFields, walk_expr_field

from sql.sql_bind_civil import (
    date_is_valid, days_from_civil, fold_make_date, fold_make_timestamp,
)
from sql.sql_bind_expr import _bind_scalar
from sql.sql_bind_parquet import ParquetFacts
from sql.sql_bind_scope import CteScope, _build_bind_scope
from sql.sql_catalog import SqlCatalog
from sql.sql_parser import parse_sql
from sql.sql_token import tokenize


def _catalog() raises -> SqlCatalog:
    """t: one column of each argument type the three functions see."""
    var cat = SqlCatalog()
    var t = SchemaBuilder()
    t.add_field(Field(String("k"), ArrowType.INT64, False))
    t.add_field(Field(String("i32"), ArrowType.INT32, True))
    t.add_field(Field(String("i16"), ArrowType.INT16, True))
    t.add_field(Field(String("u8"), ArrowType.UINT8, True))
    t.add_field(Field(String("u32"), ArrowType.UINT32, True))
    t.add_field(Field(String("u64"), ArrowType.UINT64, True))
    t.add_field(Field(String("v"), ArrowType.FLOAT64, True))
    t.add_field(Field(String("f32"), ArrowType.FLOAT32, True))
    t.add_field(Field.decimal128(String("dc"), 12, 2, True))
    t.add_field(Field(String("s"), ArrowType.STRING, True))
    t.add_field(Field(String("b"), ArrowType.BOOL, True))
    t.add_field(Field(String("d"), ArrowType.DATE32, True))
    t.add_field(Field.timestamp(String("ts"), ArrowType.TIMESTAMP_US, String(""), True))
    t.add_field(Field.timestamp(String("tns"), ArrowType.TIMESTAMP_NS, String(""), True))
    t.add_field(Field.timestamp(String("tz"), ArrowType.TIMESTAMP_US, String("UTC"), True))
    cat.add_parquet(String("t"), String("t.parquet"), t.build())
    return cat^


def _bound(sql: String) raises -> List[Expr]:
    """Bind every select item of `sql` (one SELECT over t)."""
    var cat = _catalog()
    var st = parse_sql(tokenize(sql))
    var scope = _build_bind_scope(
        st.query.from_tables, st.query.joins, cat, CteScope(ParquetFacts())
    )
    var prebound = List[Expr]()
    var out = List[Expr]()
    for i in range(len(st.query.select_items)):
        out.append(
            _bind_scalar(
                st.query.select_items[i].expr, scope.out_schema, scope, cat,
                CteScope(ParquetFacts()), prebound,
            )
        )
    return out^


def _text(sql: String) raises -> String:
    """The bound select items as text, `; `-separated, or `ERR: ` and the
    binder's message."""
    try:
        var items = _bound(sql)
        var out = String("")
        for i in range(len(items)):
            if i > 0:
                out += "; "
            out += String(items[i])
        return out
    except e:
        return String("ERR: ") + String(e)


def _check(sql: String, want: String) raises:
    assert_equal(_text(sql), want, sql)


def _types(sql: String) raises -> String:
    """The Arrow type of each bound select item, `; `-separated."""
    var cat = _catalog()
    var st = parse_sql(tokenize(sql))
    var scope = _build_bind_scope(
        st.query.from_tables, st.query.joins, cat, CteScope(ParquetFacts())
    )
    var items = _bound(sql)
    var out = String("")
    for i in range(len(items)):
        var missing = String("")
        if i > 0:
            out += "; "
        out += String(
            walk_expr_field[PlanColRefFields](items[i], scope.out_schema, missing).arrow_type
        )
    return out


def _date(n: Int) -> String:
    return "Literal(ScalarValue(date32, " + String(n) + "))"


def _ts(n: Int64) -> String:
    return "Literal(ScalarValue(timestamp[us], " + String(n) + "))"


# ---- 1. constants fold -------------------------------------------------------


def test_make_date_constants_fold_to_duckdb_day_numbers() raises:
    _check(
        "SELECT make_date(2024, 2, 29), make_date(2100, 2, 28), make_date(2000, 2, 29), make_date(1969, 12, 31) FROM t",
        _date(19782) + "; " + _date(47540) + "; " + _date(11016) + "; " + _date(-1),
    )
    _check(
        "SELECT make_date(0, 1, 1), make_date(-1, 3, 1), make_date(-4, 2, 29), make_date(-5877641, 6, 25), make_date(5881580, 7, 10) FROM t",
        _date(-719528) + "; " + _date(-719834) + "; " + _date(-720930) + "; "
        + _date(-2147483646) + "; " + _date(2147483646),
    )


def test_make_timestamp_constants_fold_to_duckdb_microseconds() raises:
    _check(
        "SELECT make_timestamp(2024, 2, 29, 1, 2, 3.5), make_timestamp(2024, 2, 29, 23, 59, 60), make_timestamp(2015, 12, 31, 24, 0, 0), make_timestamp(2000, 2, 29, 12, 0, 59.9999995), make_timestamp(2028, 2, 29, 0, 0, 0.0000005) FROM t",
        _ts(1709168523500000) + "; " + _ts(1709251200000000) + "; "
        + _ts(1451606400000000) + "; " + _ts(951825660000000) + "; "
        + _ts(1835395200000001),
    )
    # 60.5 rounds half to even to 60 whole seconds; -0.0000004 rounds to 0
    # microseconds; the last valid microsecond and the first valid day.
    _check(
        "SELECT make_timestamp(2024, 1, 1, 0, 0, 60.5), make_timestamp(2024, 1, 1, 0, 0, -0.0000004), make_timestamp(294247, 1, 10, 4, 0, 54.775806), make_timestamp(-290308, 12, 22, 0, 0, 0), make_timestamp(-1, 3, 1, 12, 0, 0) FROM t",
        _ts(1704067260500000) + "; " + _ts(1704067200000000) + "; "
        + _ts(9223372036854775806) + "; " + _ts(-9223372022400000000) + "; "
        + _ts(-62193614400000000),
    )


# ---- 2. invalid constants are refused with DuckDB's message ------------------


def test_make_date_invalid_constants_are_refused_as_duckdb() raises:
    _check("SELECT make_date(2023, 2, 29) FROM t", "ERR: Conversion Error: Date out of range: 2023-2-29")
    _check("SELECT make_date(2100, 2, 29) FROM t", "ERR: Conversion Error: Date out of range: 2100-2-29")
    _check("SELECT make_date(2024, 13, 1) FROM t", "ERR: Conversion Error: Date out of range: 2024-13-1")
    _check("SELECT make_date(2024, 0, 1) FROM t", "ERR: Conversion Error: Date out of range: 2024-0-1")
    _check("SELECT make_date(2024, 4, 31) FROM t", "ERR: Conversion Error: Date out of range: 2024-4-31")
    _check("SELECT make_date(2024, 1, 0) FROM t", "ERR: Conversion Error: Date out of range: 2024-1-0")
    _check("SELECT make_date(2024, -1, 1) FROM t", "ERR: Conversion Error: Date out of range: 2024--1-1")
    _check("SELECT make_date(5881580, 7, 11) FROM t", "ERR: Conversion Error: Date out of range: 5881580-7-11")
    _check("SELECT make_date(5881580, 8, 1) FROM t", "ERR: Conversion Error: Date out of range: 5881580-8-1")
    _check("SELECT make_date(5881581, 1, 1) FROM t", "ERR: Conversion Error: Date out of range: 5881581-1-1")
    _check("SELECT make_date(-5877641, 6, 24) FROM t", "ERR: Conversion Error: Date out of range: -5877641-6-24")
    _check("SELECT make_date(-5877641, 5, 30) FROM t", "ERR: Conversion Error: Date out of range: -5877641-5-30")
    _check("SELECT make_date(-5877642, 12, 31) FROM t", "ERR: Conversion Error: Date out of range: -5877642-12-31")
    # Of the arguments past INTEGER, DuckDB names the last.
    _check(
        "SELECT make_date(9223372036854775807, 1, 1) FROM t",
        "ERR: Invalid Input Error: Type INT64 with value 9223372036854775807 can't be cast because the value is out of range for the destination type INT32",
    )
    _check(
        "SELECT make_date(1, 9223372036854775806, 9223372036854775805) FROM t",
        "ERR: Invalid Input Error: Type INT64 with value 9223372036854775805 can't be cast because the value is out of range for the destination type INT32",
    )
    _check(
        "SELECT make_date(-2147483649, 4294967296, 1) FROM t",
        "ERR: Invalid Input Error: Type INT64 with value 4294967296 can't be cast because the value is out of range for the destination type INT32",
    )


def test_make_timestamp_invalid_constants_are_refused_as_duckdb() raises:
    _check("SELECT make_timestamp(2024, 2, 29, 25, 0, 0) FROM t", "ERR: Conversion Error: Time out of range: 25:0:0.0")
    _check("SELECT make_timestamp(2024, 2, 29, 24, 1, 0) FROM t", "ERR: Conversion Error: Time out of range: 24:1:0.0")
    _check("SELECT make_timestamp(2024, 2, 29, 24, 0, 0.0000005) FROM t", "ERR: Conversion Error: Time out of range: 24:0:0.1")
    _check("SELECT make_timestamp(2024, 2, 29, -3, 1, 1) FROM t", "ERR: Conversion Error: Time out of range: -3:1:1.0")
    _check("SELECT make_timestamp(2024, 2, 29, 1, 60, 0) FROM t", "ERR: Conversion Error: Time out of range: 1:60:0.0")
    _check("SELECT make_timestamp(2024, 2, 29, 0, -1, 1) FROM t", "ERR: Conversion Error: Time out of range: 0:-1:1.0")
    _check("SELECT make_timestamp(2024, 1, 1, 0, 0, 61.5) FROM t", "ERR: Conversion Error: Time out of range: 0:0:62.-500000")
    _check("SELECT make_timestamp(2024, 1, 1, 0, 0, 62.5) FROM t", "ERR: Conversion Error: Time out of range: 0:0:62.500000")
    _check("SELECT make_timestamp(2024, 1, 1, 0, 0, 75.25) FROM t", "ERR: Conversion Error: Time out of range: 0:0:75.250000")
    _check("SELECT make_timestamp(2024, 1, 1, 0, 0, -0.5) FROM t", "ERR: Conversion Error: Time out of range: 0:0:0.-500000")
    _check("SELECT make_timestamp(2024, 1, 1, 0, 0, -7.75) FROM t", "ERR: Conversion Error: Time out of range: 0:0:-8.250000")
    _check(
        "SELECT make_timestamp(2024, 1, 1, 0, 0, 10000000000.0) FROM t",
        "ERR: Invalid Input Error: Type DOUBLE with value 10000000000.0 can't be cast because the value is out of range for the destination type INT32",
    )
    _check(
        "SELECT make_timestamp(2024, 1, 1, 0, 0, -2147483648.4) FROM t",
        "ERR: Invalid Input Error: Type DOUBLE with value -2147483648.4 can't be cast because the value is out of range for the destination type INT32",
    )
    _check(
        "SELECT make_timestamp(2024, 1, 1, 0, 0, 2147483647.6) FROM t",
        "ERR: Conversion Error: Time out of range: 0:0:-2147483648.-2147483648",
    )
    # The date is checked first, then the hour, then the minute.
    _check("SELECT make_timestamp(2024, 13, 1, 25, 1, 0) FROM t", "ERR: Conversion Error: Date out of range: 2024-13-1")
    _check(
        "SELECT make_timestamp(2024, 1, 1, 9223372036854775807, 1, 0) FROM t",
        "ERR: Invalid Input Error: Type INT64 with value 9223372036854775807 can't be cast because the value is out of range for the destination type INT32",
    )
    _check(
        "SELECT make_timestamp(2024, 1, 1, 1, 9223372036854775806, 0) FROM t",
        "ERR: Invalid Input Error: Type INT64 with value 9223372036854775806 can't be cast because the value is out of range for the destination type INT32",
    )
    # Past the timestamp range: a day too late, a microsecond too late, a day
    # too early (a whole day of time does not bring it back).
    _check("SELECT make_timestamp(294247, 1, 11, 0, 0, 0) FROM t", "ERR: Conversion Error: Date and time not in timestamp range")
    _check("SELECT make_timestamp(294247, 1, 10, 4, 0, 54.775807) FROM t", "ERR: Conversion Error: Date and time not in timestamp range")
    _check("SELECT make_timestamp(-290308, 12, 21, 23, 59, 59) FROM t", "ERR: Conversion Error: Date and time not in timestamp range")


# ---- 3. columns build an expression; types and counts ------------------------


def test_column_arguments_build_date_and_timestamp_expressions() raises:
    assert_equal(
        _types(
            "SELECT make_date(k, 2, 29), make_date(i32, i16, u8), make_date(u32, -k, NULL), make_date(NULL, 1, 1), last_day(d), last_day(ts), last_day(tns), last_day(make_date(k, 1, 1)) FROM t"
        ),
        "date32; date32; date32; date32; date32; date32; date32; date32",
    )
    assert_equal(
        _types(
            "SELECT make_timestamp(k, 1, 1, 0, 0, v), make_timestamp(2024, 1, 1, 0, 0, k), make_timestamp(2024, 1, 1, 0, 0, f32), make_timestamp(2024, 1, 1, 0, 0, dc), make_timestamp(2024, 1, 1, 0, 0, u64), make_timestamp(2024, 1, 1, i32, 0, NULL), make_timestamp(2024, 1, 1, 0, 0, -v) FROM t"
        ),
        "timestamp[us]; timestamp[us]; timestamp[us]; timestamp[us]; timestamp[us]; timestamp[us]; timestamp[us]",
    )


def test_a_column_call_raises_through_a_named_guard() raises:
    # The invalid-row guard is a strict cast of a CASE of string literals.
    var t = _text("SELECT make_date(k, 2, 29), last_day(d), make_timestamp(k, 1, 1, 0, 0, 0) FROM t")
    assert_true('"make_date: Date out of range"' in t, t)
    assert_true('"last_day: Date out of range"' in t, t)
    assert_true('"make_timestamp: Date out of range"' in t, t)
    assert_true('"make_timestamp: Time out of range"' in t, t)
    assert_true('"make_timestamp: Date and time not in timestamp range"' in t, t)
    assert_false("ERR:" in t, t)


def test_a_column_call_copies_each_argument_a_bounded_number_of_times() raises:
    # Each argument is clamped on its own and the date's validity enters only
    # the guard, so the tree is linear in its arguments: a column argument
    # replaced by a wider expression grows the printed tree by a bounded
    # multiple of the extra text, not by a product of the nesting.
    var narrow = _text("SELECT make_timestamp(k, k, k, k, k, v) FROM t").byte_length()
    var wide = _text(
        "SELECT make_timestamp(k + k, k + k, k + k, k + k, k + k, v + v) FROM t"
    ).byte_length()
    assert_true(narrow < 40000, "make_timestamp prints " + String(narrow) + " bytes")
    assert_true(
        wide - narrow < 40000,
        "make_timestamp grows by " + String(wide - narrow) + " bytes",
    )
    var dates = _text("SELECT make_date(k, k, k), last_day(d) FROM t").byte_length()
    assert_true(dates < 20000, "make_date and last_day print " + String(dates) + " bytes")


def test_argument_types_and_counts_are_refused_by_name() raises:
    _check(
        "SELECT make_date(v, 1, 1) FROM t",
        "ERR: SQL not supported: `make_date` takes integer arguments (DuckDB's BIGINT overload), but argument 1 is of type float64. DuckDB refuses a DOUBLE or DECIMAL argument too; cast the argument to BIGINT.",
    )
    _check(
        "SELECT make_date(2024, dc, 1) FROM t",
        "ERR: SQL not supported: `make_date` takes integer arguments (DuckDB's BIGINT overload), but argument 2 is of type decimal128. DuckDB refuses a DOUBLE or DECIMAL argument too; cast the argument to BIGINT.",
    )
    _check(
        "SELECT make_date(2024, 1, u64) FROM t",
        "ERR: SQL not supported: `make_date` takes integer arguments (DuckDB's BIGINT overload), but argument 3 is of type uint64. DuckDB refuses a DOUBLE or DECIMAL argument too; cast the argument to BIGINT.",
    )
    _check(
        "SELECT make_timestamp(2024, 1, 1, s, 0, 0) FROM t",
        "ERR: SQL not supported: `make_timestamp` takes integer arguments (DuckDB's BIGINT overload), but argument 4 is of type string. DuckDB refuses a DOUBLE or DECIMAL argument too; cast the argument to BIGINT.",
    )
    _check(
        "SELECT make_timestamp(2024, 1, 1, 0, 0, s) FROM t",
        "ERR: SQL not supported: `make_timestamp` takes its seconds as a DOUBLE, but argument 6 is of type string; cast it to DOUBLE.",
    )
    _check(
        "SELECT make_timestamp(2024, 1, 1, 0, 0, b) FROM t",
        "ERR: SQL not supported: `make_timestamp` takes its seconds as a DOUBLE, but argument 6 is of type bool; cast it to DOUBLE.",
    )
    _check(
        "SELECT make_date(k) FROM t",
        "ERR: SQL not supported: `make_date` is served as make_date(year, month, day), three integer arguments; got 1. DuckDB's one-argument overloads (an INTEGER day count, a STRUCT of the three parts) are not served.",
    )
    _check(
        "SELECT make_date(k, k, k, k) FROM t",
        "ERR: SQL not supported: `make_date` is served as make_date(year, month, day), three integer arguments; got 4. DuckDB's one-argument overloads (an INTEGER day count, a STRUCT of the three parts) are not served.",
    )
    _check(
        "SELECT last_day(d, d) FROM t",
        "ERR: SQL bind error: last_day() expects exactly 1 argument (a DATE or TIMESTAMP expression) — got 2",
    )
    _check(
        "SELECT last_day(k) FROM t",
        "ERR: SQL not supported: `last_day` takes a DATE or a TIMESTAMP without a time zone, but its argument is of type int64.",
    )
    _check(
        "SELECT last_day(tz) FROM t",
        "ERR: SQL not supported: `last_day` takes a DATE or a TIMESTAMP without a time zone, but its argument is of type timestamp[us] with time zone UTC.",
    )
    _check(
        "SELECT make_timestamp(k, k) FROM t",
        "ERR: SQL bind error: `make_timestamp` takes exactly ONE argument — an INTEGER tick count since 1970-01-01 (or six: make_timestamp(year, month, day, hour, minute, seconds)) — but got 2.",
    )
    _check(
        "SELECT make_timestamp_ns(k, k, k, k, k, k) FROM t",
        "ERR: SQL bind error: `make_timestamp_ns` takes exactly ONE argument — an INTEGER tick count since 1970-01-01 — but got 6.",
    )


# ---- 4. the value functions --------------------------------------------------


def test_fold_functions_match_duckdb_on_values_sql_cannot_spell() raises:
    assert_equal(fold_make_date(2024, 2, 29), 19782)
    assert_true(date_is_valid(2000, 2, 29))
    assert_false(date_is_valid(1900, 2, 29))
    assert_equal(days_from_civil(1970, 1, 1), 0)
    # NaN seconds: DuckDB's lossy casts answer INTEGER's minimum for both.
    try:
        _ = fold_make_timestamp(2024, 1, 1, 0, 0, nan[DType.float64]())
        assert_true(False, "NaN seconds folded")
    except e:
        assert_equal(String(e), "Conversion Error: Time out of range: 0:0:-2147483648.-2147483648")
    try:
        _ = fold_make_timestamp(2024, 1, 1, 0, 0, inf[DType.float64]())
        assert_true(False, "inf seconds folded")
    except e:
        assert_equal(
            String(e),
            "Invalid Input Error: Type DOUBLE with value inf can't be cast because the value is out of range for the destination type INT32",
        )
    try:
        _ = fold_make_timestamp(2024, 1, 1, 0, 0, -inf[DType.float64]())
        assert_true(False, "-inf seconds folded")
    except e:
        assert_equal(
            String(e),
            "Invalid Input Error: Type DOUBLE with value -inf can't be cast because the value is out of range for the destination type INT32",
        )
    try:
        _ = fold_make_timestamp(2024, 1, 1, 0, 0, 1e300)
        assert_true(False, "1e300 seconds folded")
    except e:
        assert_equal(
            String(e),
            "Invalid Input Error: Type DOUBLE with value 1e+300 can't be cast because the value is out of range for the destination type INT32",
        )
    # Half to even at 60.5 (-> 60) and 61.5 (-> 62); half away from zero for
    # the microseconds (0.0000015 -> 2, 0.0000025 -> 3).
    assert_equal(fold_make_timestamp(1970, 1, 1, 0, 0, 0.0000015), 2)
    assert_equal(fold_make_timestamp(1970, 1, 1, 0, 0, 0.0000025), 3)
    assert_equal(fold_make_timestamp(1970, 1, 1, 0, 0, 60.5), 60500000)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
