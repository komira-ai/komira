# =============================================================================
# sql_bind: `date_add(date, INTERVAL ...)` and DATE +/- an integer number of days
# =============================================================================
#
# What each test proves:
#   1. `date_add(d, INTERVAL '<n>' <unit>)` binds to the same TIMESTAMP-cast
#      `DateAdd` as `d + INTERVAL '<n>' <unit>`, for every unit and sign, and
#      a nested `date_add` chains under one cast. A constant DATE first
#      argument folds to a DATE literal. (catches: the interval argument
#      bound as a value and refused; a unit mapped to the wrong months or
#      days)
#   2. `date_add` refusals by name: a second argument that is not an INTERVAL
#      literal, a wrong argument count, a non-DATE first argument, and `ago`
#      staying refused. (catches: an integer day count silently read as an
#      interval)
#   3. `d + n`, `n + d`, `d - n` over an integer constant bind to
#      `DateAdd(0, +/-n, d)` with no cast (the result stays a DATE), negative
#      and double-negative literals included, in the WHERE, select-list and
#      post-aggregate binders and under a scalar subquery; a DATE literal
#      with an integer folds to a DATE literal. (catches: the sign of `-`
#      lost; `n + d` typed as an integer)
#   4. DATE +/- number refusals by name: a non-constant integer, `n - d`, a
#      float or string or timestamp operand, a day count beyond 32 bits, and a
#      constant DATE shifted out of the 32-bit range; `d - d` keeps plain
#      subtraction. (catches: a date column plus an integer column accepted
#      as a constant shift)

from std.testing import TestSuite, assert_equal, assert_true

from arrow.arrow_types import ArrowType
from arrow.schema import Field, SchemaBuilder
from sql.sql_bind_parquet import NoParquetFooters
from sql.sql_bind_scope import _date_to_days
from sql.sql_binder import bind_statement
from sql.sql_catalog import SqlCatalog
from sql.sql_parser import parse_sql
from sql.sql_token import tokenize


def _catalog() raises -> SqlCatalog:
    """t(d DATE, ts TIMESTAMP, x INT64) and u(k INT64, d DATE); Parquet tables
    with given schemas, no file is opened."""
    var cat = SqlCatalog()
    var t = SchemaBuilder()
    t.add_field(Field(String("d"), ArrowType.DATE32, True))
    t.add_field(Field.timestamp(String("ts"), ArrowType.TIMESTAMP_US, String(""), True))
    t.add_field(Field(String("x"), ArrowType.INT64, True))
    cat.add_parquet(String("t"), String("t.parquet"), t.build())
    var u = SchemaBuilder()
    u.add_field(Field(String("k"), ArrowType.INT64, True))
    u.add_field(Field(String("d"), ArrowType.DATE32, True))
    cat.add_parquet(String("u"), String("u.parquet"), u.build())
    return cat^


def _got(sql: String) raises -> String:
    """The bound plan's text, or `ERR: ` and the binder's message."""
    try:
        var cat = _catalog()
        var bound = bind_statement(parse_sql(tokenize(sql)), cat, NoParquetFooters())
        return String(bound.take_plan())
    except e:
        return String("ERR: ") + String(e)


def _where(expr: String) raises -> String:
    return _got("SELECT d FROM t WHERE d < " + expr)


def _lit(iso: String) raises -> String:
    return "Literal(ScalarValue(date32, " + String(Int(_date_to_days(iso))) + "))"


def _refuses(expr: String, needle: String) raises:
    var plan = _where(expr)
    assert_true(plan.startswith("ERR: "), "`" + expr + "` bound: " + plan)
    assert_true(needle in plan, "`" + expr + "` raised: " + plan)


def _casts(months: Int, days: Int) -> String:
    return "BinaryOp(LT, ColRef(d), Cast(DateAdd(months=" + String(months) + ", days=" + String(days) + ", ColRef(d)), "


def _plain(days: Int) -> String:
    return "BinaryOp(LT, ColRef(d), DateAdd(months=0, days=" + String(days) + ", ColRef(d)))"


def _binds_cast(expr: String, months: Int, days: Int) raises:
    var plan = _where(expr)
    assert_true(_casts(months, days) in plan, "`" + expr + "` bound to: " + plan)


def _binds_plain(expr: String, days: Int) raises:
    var plan = _where(expr)
    assert_true(_plain(days) in plan, "`" + expr + "` bound to: " + plan)


def test_date_add_interval_binds_the_timestamp_shift() raises:
    _binds_cast("date_add(d, interval '1' day)", 0, 1)
    _binds_cast("date_add(d, interval '2' week)", 0, 14)
    _binds_cast("date_add(d, interval '3' month)", 3, 0)
    _binds_cast("date_add(d, interval '1' year)", 12, 0)
    _binds_cast("date_add(d, interval '-2' month)", -2, 0)
    _binds_cast("DATE_ADD(d, INTERVAL 5 DAY)", 0, 5)


def test_date_add_chains_under_one_cast() raises:
    var plan = _where("date_add(date_add(d, interval '1' month), interval '1' day)")
    assert_true(
        "Cast(DateAdd(months=0, days=1, DateAdd(months=1, days=0, ColRef(d))), "
        in plan,
        plan,
    )
    var mixed = _where("date_add(d, interval '1' month) + interval '2' day")
    assert_true(
        "Cast(DateAdd(months=0, days=2, DateAdd(months=1, days=0, ColRef(d))), "
        in mixed,
        mixed,
    )


def test_date_add_over_a_date_literal_folds_to_a_date() raises:
    var plan = _where("date_add(date '2024-01-31', interval '1' month)")
    assert_true(_lit("2024-02-29") in plan, plan)
    var back = _where("date_add(date '2023-03-31', interval '-1' month)")
    assert_true(_lit("2023-02-28") in back, back)


def test_date_add_in_the_select_list_and_post_aggregate_binders() raises:
    var sel = _got("SELECT date_add(d, interval '1' day) AS nd FROM t")
    assert_true("Cast(DateAdd(months=0, days=1, ColRef(d)), " in sel, sel)
    var agg = _got("SELECT date_add(max(d), interval '1' day) AS nd FROM t")
    assert_true(agg.startswith("ERR: "), agg)


def test_date_add_refusals_are_named() raises:
    _refuses("date_add(d, 3)", "needs its second argument to be an INTERVAL literal")
    _refuses("date_add(d, x)", "needs its second argument to be an INTERVAL literal")
    _refuses("date_add(d, -interval '1' day)", "needs its second argument to be an INTERVAL literal")
    _refuses("date_add(d)", "expects 2 arguments")
    _refuses("date_add(d, interval '1' day, 3)", "expects 2 arguments")
    _refuses("date_add(ts, interval '1' day)", "needs a DATE operand")
    _refuses("date_add(x, interval '1' day)", "needs a DATE operand")
    _refuses("date_add(d, interval '1000000000' year)", "beyond the range of a DATE shift")
    var ago = _got("SELECT ago(x) FROM t")
    assert_true(ago.startswith("ERR: "), ago)
    assert_true("INTERVAL" in ago, ago)


def test_date_plus_and_minus_an_integer_binds_a_date_shift() raises:
    _binds_plain("d + 7", 7)
    _binds_plain("d - 7", -7)
    _binds_plain("7 + d", 7)
    _binds_plain("d + -3", -3)
    _binds_plain("d - -3", 3)
    _binds_plain("d + 0", 0)
    _binds_plain("2147483647 + d", 2147483647)
    _binds_plain("d - 2147483647", -2147483647)
    var chain = _where("d + 3 + 1")
    assert_true(
        "BinaryOp(LT, ColRef(d), DateAdd(months=0, days=1, DateAdd(months=0, days=3, ColRef(d))))"
        in chain,
        chain,
    )
    var cast_free = _where("d + 7")
    assert_true("Cast(" not in cast_free, cast_free)


def test_date_integer_shift_in_select_list_post_aggregate_and_subquery() raises:
    var sel = _got("SELECT d + 7 AS nd FROM t")
    assert_true("DateAdd(months=0, days=7, ColRef(d))" in sel, sel)
    var agg = _got("SELECT max(d) + 7 AS nd FROM t")
    assert_true(not agg.startswith("ERR: "), agg)
    assert_true("DateAdd(months=0, days=7, ColRef(" in agg, agg)
    var left = _got("SELECT 7 + max(d) AS nd FROM t")
    assert_true("DateAdd(months=0, days=7, ColRef(" in left, left)
    var sub = _got("SELECT d FROM t WHERE d < (SELECT max(d) FROM u) + 3")
    assert_true(not sub.startswith("ERR: "), sub)
    assert_true("DateAdd(months=0, days=3, " in sub, sub)
    var corr = _got(
        "SELECT x FROM t WHERE EXISTS (SELECT 1 FROM u WHERE u.k = t.x AND u.d < d + 1)"
    )
    assert_true(not corr.startswith("ERR: "), corr)


def test_date_literal_plus_an_integer_folds_to_a_date() raises:
    var plan = _where("date '2024-01-31' + 3")
    assert_true(_lit("2024-02-03") in plan, plan)
    var left = _where("3 + date '2024-01-31'")
    assert_true(_lit("2024-02-03") in left, left)
    var minus = _where("date '2024-03-01' - 1")
    assert_true(_lit("2024-02-29") in minus, minus)
    var chain = _where("date '2024-01-31' + 3 + 1")
    assert_true(_lit("2024-02-04") in chain, chain)
    var epoch = _where("date '1970-01-01' - 1")
    assert_true("Literal(ScalarValue(date32, -1))" in epoch, epoch)


def test_date_integer_refusals_are_named() raises:
    _refuses("d + x", "add a constant number of days")
    _refuses("x + d", "add a constant number of days")
    _refuses("d - x", "add a constant number of days")
    _refuses("d + (x * 2)", "add a constant number of days")
    _refuses("7 - d", "`<number> - DATE`")
    _refuses("d + 1.5", "a DATE +/- an operand of type")
    _refuses("d + 'a'", "a DATE +/- an operand of type")
    _refuses("d + ts", "a DATE +/- an operand of type")
    _refuses("ts - d", "a DATE +/- an operand of type")
    _refuses("d + 2147483648", "beyond the range of a DATE shift")
    _refuses("d - 2147483649", "beyond the range of a DATE shift")
    _refuses("d - -2147483648", "beyond the range of a DATE shift")
    _refuses("date '2024-01-01' + 2147483647", "out of range")
    _refuses("date '2024-01-01' - 2147483647 - 2147483647", "out of range")


def test_date_minus_date_keeps_plain_subtraction() raises:
    var plan = _got("SELECT d - d AS n FROM t")
    assert_true(not plan.startswith("ERR: "), plan)
    assert_true("BinaryOp(SUB, ColRef(d), ColRef(d))" in plan, plan)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
