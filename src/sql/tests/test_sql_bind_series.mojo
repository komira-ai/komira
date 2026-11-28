# =============================================================================
# sql_bind: `generate_series(...)` / `range(...)` in FROM (sql_series_bind)
# =============================================================================
#
# Each test binds SQL text; a series scan's spec is read back from the scan
# node's `komira.generate_series` binding and its rows computed by
# `series_values`.
#
# What each test proves, and the defect it would catch:
#   1. Integer series: `generate_series` includes the stop and `range`
#      excludes it; the one-argument forms count from 0; a step and a negative
#      step walk as written; a negative literal bound works. The schema is one
#      BIGINT column. (catches: an off-by-one at the bound; the 1-argument
#      form starting at 1)
#   2. A step pointing away from the bound is no rows, for both functions and
#      both directions; it is not an error. (catches: an endless or reversed
#      series; a refusal DuckDB does not make)
#   3. Dates by day, month and year: the column is TIMESTAMP (microseconds), a
#      DATE is its midnight; month steps clamp at the end of the month and
#      accumulate (31 Jan, 29 Feb, 29 Mar, 29 Apr 2024). (catches: a DATE
#      series typed DATE; a clamped day that comes back)
#   4. Timestamps by hour, minute, second and week, DATE and TIMESTAMP bounds
#      mixed, and a negative interval walking down. (catches: a sub-day unit
#      read as days; the time of day dropped)
#   5. A NULL argument is no rows, typed by the overload the other arguments
#      choose (BIGINT for all-NULL), even with a zero step. (catches: a NULL
#      read as 0; a zero step refused ahead of the NULL)
#   6. Naming: the column is the function name, or the first name of the alias
#      list (more names are ignored); the qualifier is the alias, else the
#      function name; an alias hides the function name; `*` expands to the
#      column. (catches: `AS t(d)` dropped; `t.d` unresolved)
#   7. A series joins with a catalog table and with another series. (catches:
#      the series relation sent down the catalog path)
#   8. The scan carries its row count for a fixed step, and none for a month
#      step or a count past the largest Int (0..Int64.MAX is 2^63 rows). (catches: a stale or invented estimate)
#   9. Refusals, each by its message: a zero integer step, a zero interval
#      step, a column-valued argument (qualified or bare), a non-literal
#      expression, two DATE bounds, an integer step with dates, an interval
#      step with integers, a string, a decimal, no argument, four arguments,
#      TIMESTAMPTZ, an interval beyond 64 bits of microseconds. (catches: a
#      shape DuckDB has no overload for answered with rows)

from std.testing import TestSuite, assert_equal, assert_true

from arrow.arrow_types import ArrowType
from arrow.schema import Field, SchemaBuilder
from plan_ir.logical_plan import LogicalPlan
from scan_source.series_scan import SeriesSpec, US_PER_DAY, series_spec_of, series_values
from sql.sql_bind_parquet import NoParquetFooters, collect_parquet_facts
from sql.sql_bind_scope import (
    CteScope, _date_to_days, _relation_scan, _relation_schema,
)
from sql.sql_binder import bind_statement
from sql.sql_catalog import SqlCatalog
from sql.sql_parser import parse_sql
from sql.sql_token import tokenize


def _catalog() raises -> SqlCatalog:
    """u(k INT64, x INT64): a catalog table to join with and to reference."""
    var cat = SqlCatalog()
    var u = SchemaBuilder()
    u.add_field(Field(String("k"), ArrowType.INT64, True))
    u.add_field(Field(String("x"), ArrowType.INT64, True))
    cat.add_parquet(String("u"), String("u.parquet"), u.build())
    return cat^


def _scan(sql: String) raises -> LogicalPlan:
    """The scan of the first FROM relation of `sql`."""
    var st = parse_sql(tokenize(sql))
    var cat = _catalog()
    var cte = CteScope(collect_parquet_facts(st, cat, NoParquetFooters()))
    return _relation_scan(st.query.from_tables[0], cat, cte)


def _spec(sql: String) raises -> SeriesSpec:
    var scan = _scan(sql)
    return series_spec_of(scan.scan_data_ref().source.binding_ref())


def _rows(sql: String) raises -> List[Int64]:
    return series_values(_spec(sql), 0, 1000)


def _from(call: String) -> String:
    return "SELECT * FROM " + call


def _err(sql: String) raises -> String:
    try:
        var cat = _catalog()
        _ = bind_statement(parse_sql(tokenize(sql)), cat, NoParquetFooters())
    except e:
        return String(e)
    raise Error("bound, expected a refusal: " + sql)


def _binds(sql: String) raises:
    var cat = _catalog()
    _ = bind_statement(parse_sql(tokenize(sql)), cat, NoParquetFooters())


def _us(iso: String) raises -> Int64:
    """Microseconds of a date's midnight."""
    return Int64(Int(_date_to_days(iso))) * US_PER_DAY


def _expect(got: List[Int64], want: List[Int64], what: String) raises:
    assert_equal(len(got), len(want), what + ": row count")
    for i in range(len(want)):
        assert_equal(Int(got[i]), Int(want[i]), what + ": row " + String(i))


def test_integer_series_include_or_exclude_the_stop() raises:
    _expect(_rows(_from("generate_series(1, 5)")), [1, 2, 3, 4, 5], "gs(1,5)")
    _expect(_rows(_from("range(1, 5)")), [1, 2, 3, 4], "range(1,5)")
    _expect(_rows(_from("generate_series(3)")), [0, 1, 2, 3], "gs(3)")
    _expect(_rows(_from("range(3)")), [0, 1, 2], "range(3)")
    _expect(_rows(_from("generate_series(1, 10, 3)")), [1, 4, 7, 10], "gs step 3")
    _expect(_rows(_from("range(1, 10, 3)")), [1, 4, 7], "range step 3")
    _expect(_rows(_from("generate_series(10, 1, -4)")), [10, 6, 2], "gs down")
    _expect(_rows(_from("generate_series(-3, -1)")), [-3, -2, -1], "negative")
    _expect(_rows(_from("generate_series(2, 2)")), [2], "one row")
    _expect(_rows(_from("range(2, 2)")), List[Int64](), "range empty")
    var s = _spec(_from("generate_series(1, 5)"))
    assert_true(s.inclusive)
    assert_true(not s.timestamp)
    assert_true(not _spec(_from("range(1, 5)")).inclusive)


def test_integer_schema_is_one_bigint_column() raises:
    var cat = _catalog()
    var st = parse_sql(tokenize(_from("generate_series(1, 3)")))
    var cte = CteScope(collect_parquet_facts(st, cat, NoParquetFooters()))
    var sch = _relation_schema(st.query.from_tables[0], cat, cte)
    assert_equal(sch.num_columns(), 1)
    assert_equal(sch.field_name(0), "generate_series")
    assert_true(sch.field_arrow_type(0) == ArrowType.INT64)
    assert_true(not sch.field_nullable(0))
    var scan = _scan(_from("range(3)"))
    assert_equal(scan.output_schema.field_name(0), "range")
    assert_true(scan.output_schema.field_arrow_type(0) == ArrowType.INT64)


def test_a_step_away_from_the_stop_is_no_rows() raises:
    _expect(_rows(_from("generate_series(5, 1)")), List[Int64](), "gs(5,1)")
    _expect(_rows(_from("range(3, 1)")), List[Int64](), "range(3,1)")
    _expect(_rows(_from("generate_series(1, 5, -1)")), List[Int64](), "negative upward")
    _expect(_rows(_from("range(5, 1, 1)")), List[Int64](), "range upward step down")
    _expect(_rows(_from("generate_series(-3)")), List[Int64](), "gs(-3)")
    _expect(_rows(_from("range(0)")), List[Int64](), "range(0)")


def test_date_series_are_timestamps_by_day_month_and_year() raises:
    var days = _rows(_from(
        "generate_series(DATE '2024-01-01', DATE '2024-01-07', INTERVAL '1' DAY)"
    ))
    assert_equal(len(days), 7)
    assert_equal(Int(days[0]), Int(_us("2024-01-01")))
    assert_equal(Int(days[6]), Int(_us("2024-01-07")))
    var ex = _rows(_from(
        "range(DATE '2024-01-01', DATE '2024-01-07', INTERVAL '1' DAY)"
    ))
    assert_equal(len(ex), 6)
    var s = _spec(_from(
        "generate_series(DATE '2024-01-01', DATE '2024-01-07', INTERVAL '2' DAY)"
    ))
    assert_true(s.timestamp)
    assert_equal(Int(s.step), Int(2 * US_PER_DAY))
    assert_true(s.schema().field_arrow_type(0) == ArrowType.TIMESTAMP_US)
    _expect(
        _rows(_from(
            "generate_series(DATE '2024-01-31', DATE '2024-04-30', INTERVAL '1' MONTH)"
        )),
        [_us("2024-01-31"), _us("2024-02-29"), _us("2024-03-29"), _us("2024-04-29")],
        "month clamp",
    )
    var m = _spec(_from(
        "generate_series(DATE '2024-01-31', DATE '2024-04-30', INTERVAL '1' MONTH)"
    ))
    assert_equal(Int(m.step_months), 1)
    assert_equal(Int(m.step), 0)
    _expect(
        _rows(_from(
            "generate_series(DATE '2020-02-29', DATE '2024-03-01', INTERVAL '2' YEAR)"
        )),
        [_us("2020-02-29"), _us("2022-02-28"), _us("2024-02-28")],
        "year step",
    )
    assert_equal(
        Int(_spec(_from(
            "range(DATE '2024-01-01', DATE '2026-01-01', INTERVAL '1' YEAR)"
        )).step_months),
        12,
    )


def test_timestamp_series_by_sub_day_and_week_steps() raises:
    var h = _rows(_from(
        "generate_series(TIMESTAMP '2024-01-01 00:00:00',"
        " TIMESTAMP '2024-01-01 03:00:00', INTERVAL '1' HOUR)"
    ))
    assert_equal(len(h), 4)
    assert_equal(Int(h[1] - h[0]), 3_600_000_000)
    assert_equal(Int(h[0]), Int(_us("2024-01-01")))
    var min = _spec(_from(
        "generate_series(TIMESTAMP '2024-01-01 00:00:00',"
        " TIMESTAMP '2024-01-01 00:10:00', INTERVAL '5' MINUTE)"
    ))
    assert_equal(Int(min.step), 300_000_000)
    assert_equal(len(series_values(min, 0, 100)), 3)
    var sec = _spec(_from(
        "range(TIMESTAMP '2024-01-01 00:00:00',"
        " TIMESTAMP '2024-01-01 00:00:03', INTERVAL '1' SECOND)"
    ))
    assert_equal(Int(sec.step), 1_000_000)
    assert_equal(len(series_values(sec, 0, 100)), 3)
    var wk = _spec(_from(
        "generate_series(DATE '2024-01-01', DATE '2024-02-01', INTERVAL '1' WEEK)"
    ))
    assert_equal(Int(wk.step), Int(7 * US_PER_DAY))
    var mixed = _rows(_from(
        "generate_series(DATE '2024-01-01', TIMESTAMP '2024-01-01 12:00:00',"
        " INTERVAL '6' HOUR)"
    ))
    assert_equal(len(mixed), 3)
    assert_equal(Int(mixed[2]), Int(_us("2024-01-01")) + 12 * 3_600_000_000)
    var down = _rows(_from(
        "generate_series(TIMESTAMP '2024-01-01 10:30:00',"
        " TIMESTAMP '2024-01-01 08:30:00', INTERVAL '-1' HOUR)"
    ))
    assert_equal(len(down), 3)
    assert_equal(Int(down[0] - down[1]), 3_600_000_000)
    var wrong = _rows(_from(
        "generate_series(DATE '2024-01-07', DATE '2024-01-01', INTERVAL '1' DAY)"
    ))
    assert_equal(len(wrong), 0)
    var tod = _rows(_from(
        "generate_series(TIMESTAMP '2024-01-31 13:45:00',"
        " TIMESTAMP '2024-03-31 13:45:00', INTERVAL '1' MONTH)"
    ))
    assert_equal(len(tod), 3)
    assert_equal(Int(tod[1]), Int(_us("2024-02-29")) + (13 * 60 + 45) * 60 * 1_000_000)


def test_a_null_argument_is_no_rows_typed_by_the_others() raises:
    var a = _spec(_from("generate_series(NULL, 5)"))
    assert_equal(len(series_values(a, 0, 10)), 0)
    assert_true(not a.timestamp)
    assert_true(len(series_values(_spec(_from("range(5, NULL)")), 0, 10)) == 0)
    assert_true(len(series_values(_spec(_from("generate_series(NULL)")), 0, 10)) == 0)
    var z = _spec(_from("generate_series(1, 5, NULL)"))
    assert_true(not z.timestamp)
    var zero = _spec(_from("generate_series(NULL, 5, 0)"))
    assert_equal(len(series_values(zero, 0, 10)), 0)
    var all = _spec(_from("generate_series(NULL, NULL, NULL)"))
    assert_true(not all.timestamp)
    var t1 = _spec(_from(
        "generate_series(DATE '2024-01-01', NULL, INTERVAL '1' DAY)"
    ))
    assert_true(t1.timestamp)
    assert_equal(len(series_values(t1, 0, 10)), 0)
    var t2 = _spec(_from("generate_series(NULL, NULL, INTERVAL '1' DAY)"))
    assert_true(t2.timestamp)
    var t3 = _spec(_from(
        "generate_series(DATE '2024-01-01', DATE '2024-01-02', NULL)"
    ))
    assert_true(t3.timestamp)
    assert_equal(len(series_values(t3, 0, 10)), 0)
    var t4 = _spec(_from(
        "generate_series(TIMESTAMP '2024-01-01 00:00:00', NULL, NULL)"
    ))
    assert_true(t4.timestamp)
    var zero_iv = _spec(_from(
        "generate_series(DATE '2024-01-01', NULL, INTERVAL '0' DAY)"
    ))
    assert_equal(len(series_values(zero_iv, 0, 10)), 0)


def test_names_of_the_column_and_the_qualifier() raises:
    assert_equal(_spec(_from("generate_series(1, 3)")).column, "generate_series")
    assert_equal(_spec(_from("range(3)")).column, "range")
    assert_equal(_spec(_from("range(3) AS t")).column, "range")
    assert_equal(_spec(_from("generate_series(1, 3) AS t(d)")).column, "d")
    assert_equal(_spec(_from("range(3) t(d, e, f)")).column, "d")
    var cat = _catalog()
    var st = parse_sql(tokenize(_from("generate_series(1, 3) AS t(d)")))
    var cte = CteScope(collect_parquet_facts(st, cat, NoParquetFooters()))
    var sch = _relation_schema(st.query.from_tables[0], cat, cte)
    assert_equal(sch.field_name(0), "d")
    _binds("SELECT d FROM generate_series(1, 3) AS t(d)")
    _binds("SELECT t.d FROM generate_series(1, 3) AS t(d)")
    _binds("SELECT * FROM generate_series(1, 3) AS t(d)")
    _binds("SELECT generate_series FROM generate_series(1, 3)")
    _binds("SELECT generate_series.generate_series FROM generate_series(1, 3)")
    _binds("SELECT range.range FROM range(3)")
    _binds("SELECT t.range FROM range(3) AS t")
    _binds("SELECT t.generate_series FROM generate_series(1, 3) t")
    _binds("SELECT d + 1 AS y FROM generate_series(1, 3) AS t(d) WHERE d > 1")
    var hidden = _err("SELECT generate_series.generate_series FROM generate_series(1, 3) AS t")
    assert_true(hidden.byte_length() > 0)
    var renamed = _err("SELECT generate_series FROM generate_series(1, 3) AS t(d)")
    assert_true(renamed.byte_length() > 0)


def test_a_series_joins_with_a_table_and_another_series() raises:
    _binds("SELECT t.d, u.k FROM generate_series(1, 3) AS t(d), u WHERE t.d = u.k")
    _binds("SELECT t.d, u.x FROM u JOIN generate_series(1, 3) AS t(d) ON u.k = t.d")
    _binds(
        "SELECT a.x, b.y FROM generate_series(1, 2) AS a(x),"
        " range(3) AS b(y) WHERE a.x < b.y"
    )
    _binds(
        "SELECT * FROM generate_series(DATE '2024-01-01', DATE '2024-01-03',"
        " INTERVAL '1' DAY) AS t(d), u"
    )
    _binds("SELECT u.k FROM u WHERE u.k IN (SELECT s FROM range(3) AS t(s))")
    _binds("SELECT k FROM u WHERE EXISTS (SELECT 1 FROM generate_series(1, 3) AS t(d))")


def test_the_scan_carries_its_row_count_for_a_fixed_step() raises:
    var fixed = _scan(_from("generate_series(1, 10, 3)"))
    assert_true(Bool(fixed.scan_data_ref().row_count))
    assert_equal(fixed.scan_data_ref().row_count.value(), 4)
    var ex = _scan(_from("range(10)"))
    assert_equal(ex.scan_data_ref().row_count.value(), 10)
    var month = _scan(_from(
        "generate_series(DATE '2024-01-01', DATE '2024-06-01', INTERVAL '1' MONTH)"
    ))
    assert_true(not month.scan_data_ref().row_count)
    var huge = _scan(_from("generate_series(0, 9223372036854775807)"))
    assert_true(not huge.scan_data_ref().row_count)


def test_zero_steps_are_refused_by_name() raises:
    assert_true("interval cannot be 0" in _err(_from("generate_series(1, 5, 0)")))
    assert_true("interval cannot be 0" in _err(_from("range(1, 5, 0)")))
    assert_true("interval cannot be 0" in _err(_from(
        "generate_series(DATE '2024-01-01', DATE '2024-01-05', INTERVAL '0' DAY)"
    )))
    assert_true("interval cannot be 0" in _err(_from(
        "range(DATE '2024-01-01', DATE '2024-01-05', INTERVAL '0' MONTH)"
    )))


def test_column_valued_and_non_literal_arguments_are_refused() raises:
    var q = _err("SELECT * FROM u, generate_series(1, u.x)")
    assert_true("column-valued" in q and "`x`" in q, q)
    var b = _err("SELECT * FROM u, generate_series(x, 3)")
    assert_true("column-valued" in b and "argument 1" in b, b)
    var r = _err("SELECT * FROM u, range(1, 5, k)")
    assert_true("column-valued" in r and "argument 3" in r, r)
    var e = _err(_from("generate_series(1 + 1, 5)"))
    assert_true("not a literal" in e, e)
    var big = _err(_from("generate_series(1, 9223372036854775808)"))
    assert_true("not a literal" in big, big)


def test_shapes_without_a_duckdb_overload_are_refused_by_name() raises:
    var two = _err(_from(
        "generate_series(DATE '2024-01-01', DATE '2024-01-07')"
    ))
    assert_true("no function matches generate_series(DATE, DATE)" in two, two)
    var null_date = _err(_from("generate_series(NULL, DATE '2024-01-07')"))
    assert_true("no function matches" in null_date, null_date)
    var int_step = _err(_from(
        "generate_series(DATE '2024-01-01', DATE '2024-01-07', 1)"
    ))
    assert_true("no function matches" in int_step, int_step)
    var iv_ints = _err(_from("generate_series(1, 5, INTERVAL '1' DAY)"))
    assert_true("INTEGER, INTEGER, INTERVAL" in iv_ints, iv_ints)
    var iv_null = _err(_from("generate_series(1, NULL, INTERVAL '1' DAY)"))
    assert_true("no function matches" in iv_null, iv_null)
    var iv_first = _err(_from(
        "generate_series(INTERVAL '1' DAY, DATE '2024-01-07', INTERVAL '1' DAY)"
    ))
    assert_true("no function matches" in iv_first, iv_first)
    var date_step = _err(_from(
        "generate_series(DATE '2024-01-01', DATE '2024-01-07', DATE '2024-01-02')"
    ))
    assert_true("no function matches" in date_step, date_step)
    var str_arg = _err(_from("generate_series('a', 'c')"))
    assert_true("string as argument 1" in str_arg, str_arg)
    var dec = _err(_from("generate_series(1, 2.5)"))
    assert_true("decimal as argument 2" in dec, dec)
    var none = _err(_from("generate_series()"))
    assert_true("with 0 arguments" in none, none)
    var four = _err(_from("range(1, 2, 3, 4)"))
    assert_true("with 4 arguments" in four, four)
    var tz = _err(_from(
        "generate_series(TIMESTAMPTZ '2024-01-01 00:00:00+00',"
        " TIMESTAMPTZ '2024-01-02 00:00:00+00', INTERVAL '1' DAY)"
    ))
    assert_true("TIMESTAMPTZ" in tz, tz)
    var over = _err(_from(
        "generate_series(DATE '2024-01-01', DATE '2024-02-01', INTERVAL '1000000000' DAY)"
    ))
    assert_true("beyond 64 bits" in over, over)
    var over_week = _err(_from(
        "generate_series(DATE '2024-01-01', DATE '2024-02-01', INTERVAL '-1000000000' WEEK)"
    ))
    assert_true("beyond 64 bits" in over_week, over_week)
    var bad_date = _err(_from(
        "generate_series(DATE '2024-13-01', DATE '2024-02-01', INTERVAL '1' DAY)"
    ))
    assert_true("date" in bad_date.lower(), bad_date)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
