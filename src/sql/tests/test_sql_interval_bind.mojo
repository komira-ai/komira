# =============================================================================
# sql_bind: DATE +/- INTERVAL folds to a DATE constant (sql_bind_interval)
# =============================================================================
#
# What each test proves:
#   1. Every TPC-H interval use, and a table of calendar cases, bind to the
#      expected `date32` literal: the month-end clamp (31 Jan + 1 month = 28
#      or 29 Feb; 29 Feb +/- 1 year = 28 Feb; 31 Mar - 1 month = 29 Feb in a
#      leap year), leap years (29 Feb + 4 years stays), years before 1970,
#      negative counts, weeks, a chain of intervals, and `INTERVAL + DATE`.
#      The expected day number comes from `_date_to_days` on the expected
#      ISO date. (catches: no clamp so the day overflows into the next month;
#      a month added as 30 days; year arithmetic that skips the clamp;
#      subtraction applied with the wrong sign; floor vs truncating division
#      before 1970)
#   2. The folds hold in every expression binder: a WHERE predicate, a
#      correlated subquery's inner predicate, and a post-aggregate
#      expression. (catches: the fold wired into one binder only)
#   3. The TPC-H Q1 and Q6 queries bind, their WHERE clauses carrying the
#      folded date. (catches: the corpus queries still refused)
#   4. A DATE column (or any DATE-typed expression) `+/- INTERVAL` and
#      `INTERVAL + DATE` bind to a TIMESTAMP cast over a `DateAdd` carrying
#      the interval's months and days, in the WHERE, select-list,
#      post-aggregate and correlated-subquery binders; a chain nests one
#      `DateAdd` per interval under one cast. (catches: an interval wired
#      into one binder only; the sign of `-` lost; a unit mapped to the wrong
#      months or days)
#   5. Refusals by name: a TIMESTAMP, string or number operand, a bare
#      INTERVAL, INTERVAL - DATE, INTERVAL * n, INTERVAL + INTERVAL, an
#      INTERVAL compared or used as a projection, an interval whose months or
#      days do not fit 32 bits, and a result outside years 1..9999 on a
#      constant DATE. (catches: a non-DATE operand shifted as if it were a
#      DATE; an out-of-range date wrapped)

from std.testing import TestSuite, assert_equal, assert_true

from arrow.arrow_types import ArrowType
from arrow.schema import Field, SchemaBuilder
from plan_expr.expr import (
    EXPR_BINARY_OP, EXPR_CORRELATED_SUBQUERY, EXPR_UNARY_OP, Expr,
)
from plan_ir.corr_subquery import corr_subq_inner_plan_ref
from plan_ir.logical_plan import LogicalPlan, PLAN_FILTER, PLAN_PROJECT
from sql.sql_ast import (
    SXIVL_DAY, SXIVL_MONTH, SXIVL_WEEK, SXIVL_YEAR, SqlExpr,
)
from sql.sql_bind_interval import interval_const
from sql.sql_bind_parquet import NoParquetFooters
from sql.sql_bind_scope import _date_to_days
from sql.sql_binder import bind_statement
from sql.sql_catalog import SqlCatalog
from sql.sql_parser import parse_sql
from sql.sql_token import tokenize


def _catalog() raises -> SqlCatalog:
    """t(d DATE, ts TIMESTAMP, x INT64), u(k INT64, d DATE) and the TPC-H
    lineitem columns Q1 and Q6 read. Parquet tables with given schemas; no
    file is opened."""
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
    var li = SchemaBuilder()
    li.add_field(Field(String("l_returnflag"), ArrowType.STRING, True))
    li.add_field(Field(String("l_linestatus"), ArrowType.STRING, True))
    li.add_field(Field(String("l_quantity"), ArrowType.FLOAT64, True))
    li.add_field(Field(String("l_extendedprice"), ArrowType.FLOAT64, True))
    li.add_field(Field(String("l_discount"), ArrowType.FLOAT64, True))
    li.add_field(Field(String("l_tax"), ArrowType.FLOAT64, True))
    li.add_field(Field(String("l_shipdate"), ArrowType.DATE32, True))
    cat.add_parquet(String("lineitem"), String("lineitem.parquet"), li.build())
    return cat^


def _got(sql: String) raises -> String:
    """The bound plan's text, or `ERR: ` and the binder's message."""
    try:
        var cat = _catalog()
        var bound = bind_statement(parse_sql(tokenize(sql)), cat, NoParquetFooters())
        return String(bound.take_plan())
    except e:
        return String("ERR: ") + String(e)


def _lit(iso: String) raises -> String:
    return "Literal(ScalarValue(date32, " + String(Int(_date_to_days(iso))) + "))"


def _folds(expr: String, iso: String) raises:
    var plan = _got("SELECT d FROM t WHERE d < " + expr)
    var want = "  Filter(predicate=BinaryOp(LT, ColRef(d), " + _lit(iso) + "))\n"
    assert_true(want in plan, "`" + expr + "` bound to: " + plan + " want " + want)


def _refuses(expr: String, needle: String) raises:
    var plan = _got("SELECT d FROM t WHERE d < " + expr)
    assert_true(plan.startswith("ERR: "), "`" + expr + "` bound: " + plan)
    assert_true(needle in plan, "`" + expr + "` raised: " + plan)


def test_epoch_anchors() raises:
    # Absolute pins independent of `_date_to_days`.
    var p = _got("SELECT d FROM t WHERE d < date '1970-01-01' - interval '1' day")
    assert_true("Literal(ScalarValue(date32, -1))" in p, p)
    var q = _got("SELECT d FROM t WHERE d < date '1998-12-01' - interval '90' day")
    assert_true("Literal(ScalarValue(date32, 10471))" in q, q)
    var r = _got("SELECT d FROM t WHERE d < date '1970-01-31' + interval '1' month")
    assert_true("Literal(ScalarValue(date32, 58))" in r, r)


def test_interval_folds_to_the_expected_date() raises:
    _folds("date '1998-12-01' - interval '90' day", "1998-09-02")
    _folds("date '1993-07-01' + interval '3' month", "1993-10-01")
    _folds("date '1994-01-01' + interval '1' year", "1995-01-01")
    _folds("date '1993-10-01' + interval '3' month", "1994-01-01")
    _folds("date '1995-09-01' + interval '1' month", "1995-10-01")
    _folds("date '1996-01-01' + interval '3' month", "1996-04-01")
    _folds("date '2023-01-31' + interval '1' month", "2023-02-28")
    _folds("date '2024-01-31' + interval '1' month", "2024-02-29")
    _folds("date '2023-12-31' + interval '2' month", "2024-02-29")
    _folds("date '2023-03-31' - interval '1' month", "2023-02-28")
    _folds("date '2024-03-31' - interval '1' month", "2024-02-29")
    _folds("date '2024-05-31' - interval '1' month", "2024-04-30")
    _folds("date '2032-02-29' + interval '1' year", "2033-02-28")
    _folds("date '2024-02-29' - interval '1' year", "2023-02-28")
    _folds("date '2020-02-29' + interval '4' year", "2024-02-29")
    _folds("date '2032-02-29' + interval '12' month", "2033-02-28")
    _folds("date '1900-02-28' + interval '1' day", "1900-03-01")
    _folds("date '2000-02-28' + interval '1' day", "2000-02-29")
    _folds("date '2032-12-31' + interval '1' day", "2033-01-01")
    _folds("date '2024-01-01' - interval '1' day", "2023-12-31")
    _folds("date '1994-01-01' + interval '2' week", "1994-01-15")
    _folds("date '1970-01-01' - interval '1' day", "1969-12-31")
    _folds("date '1970-01-31' - interval '1' year", "1969-01-31")
    _folds("date '1970-03-31' - interval '13' month", "1969-02-28")
    _folds("date '1970-01-01' - interval '25' month", "1967-12-01")
    _folds("date '1994-01-01' + interval '-1' month", "1993-12-01")
    _folds("date '1994-01-01' - interval '-1' year", "1995-01-01")
    _folds("date '1994-01-01' + interval '0' day", "1994-01-01")
    _folds("interval '1' year + date '1994-01-01'", "1995-01-01")
    _folds("date '1994-01-01' + interval '1' year + interval '1' day", "1995-01-02")
    _folds("date '1994-01-01' + interval '1' year - interval '1' day", "1994-12-31")
    _folds("date '2024-01-31' + interval '1' month + interval '1' month", "2024-03-29")
    _folds("date '0001-01-01' + interval '9998' year", "9999-01-01")
    _folds("date '9999-12-31' - interval '9998' year", "0001-12-31")


def test_fold_in_every_expression_binder() raises:
    var dt = _lit("1995-01-01")
    # Correlated subquery inner predicate (TPC-H Q20's shape).
    var corr = _got(
        "SELECT x FROM t WHERE EXISTS (SELECT 1 FROM u WHERE u.k = t.x"
        " AND u.d >= date '1994-01-01' AND u.d < date '1994-01-01' + interval '1' year)"
    )
    assert_true(not corr.startswith("ERR: "), corr)
    # Post-aggregate expression.
    var agg = _got("SELECT max(d) < date '1994-01-01' + interval '1' year AS b FROM t")
    assert_true(not agg.startswith("ERR: "), agg)
    assert_true(dt in agg, agg)
    var having = _got(
        "SELECT x, max(d) AS m FROM t GROUP BY x"
        " HAVING max(d) < date '1994-01-01' + interval '1' year"
    )
    assert_true(not having.startswith("ERR: "), having)
    assert_true(dt in having, having)
    # A select-list item.
    var sel = _got("SELECT date '1994-01-01' + interval '1' year AS nd FROM t")
    assert_true(not sel.startswith("ERR: "), sel)
    assert_true(dt in sel, sel)


comptime _Q1 = """select
  l_returnflag,
  l_linestatus,
  sum(l_quantity) as sum_qty,
  sum(l_extendedprice) as sum_base_price,
  sum(l_extendedprice * (1 - l_discount)) as sum_disc_price,
  sum(l_extendedprice * (1 - l_discount) * (1 + l_tax)) as sum_charge,
  avg(l_quantity) as avg_qty,
  avg(l_extendedprice) as avg_price,
  avg(l_discount) as avg_disc,
  count(*) as count_order
from
  lineitem
where
  l_shipdate <= date '1998-12-01' - interval '90' day
group by
  l_returnflag,
  l_linestatus
order by
  l_returnflag,
  l_linestatus"""

comptime _Q6 = """select
  sum(l_extendedprice * l_discount) as revenue
from
  lineitem
where
  l_shipdate >= date '1994-01-01'
  and l_shipdate < date '1994-01-01' + interval '1' year
  and l_discount between 0.06 - 0.01 and 0.06 + 0.01
  and l_quantity < 24"""


def test_tpch_q1_binds_with_the_folded_date() raises:
    var plan = _got(_Q1)
    assert_true(not plan.startswith("ERR: "), plan)
    assert_true(
        "BinaryOp(LE, ColRef(l_shipdate), " + _lit("1998-09-02") + ")" in plan, plan
    )


def test_tpch_q6_binds_with_the_folded_dates() raises:
    var plan = _got(_Q6)
    assert_true(not plan.startswith("ERR: "), plan)
    assert_true("BinaryOp(GE, ColRef(l_shipdate), " + _lit("1994-01-01") + ")" in plan, plan)
    assert_true("BinaryOp(LT, ColRef(l_shipdate), " + _lit("1995-01-01") + ")" in plan, plan)


def _shifted(months: Int, days: Int, col: String) -> String:
    """The text of the TIMESTAMP-cast shift of column `col`."""
    return (
        "Cast(DateAdd(months=" + String(months) + ", days=" + String(days)
        + ", ColRef(" + col + ")), "
    )


def _binds_shift(expr: String, months: Int, days: Int) raises:
    var plan = _got("SELECT d FROM t WHERE d < " + expr)
    var want = "BinaryOp(LT, ColRef(d), " + _shifted(months, days, "d")
    assert_true(want in plan, "`" + expr + "` bound to: " + plan + " want " + want)


def test_date_column_plus_interval_binds_a_timestamp_shift() raises:
    _binds_shift("d + interval '1' day", 0, 1)
    _binds_shift("d + interval '3' month", 3, 0)
    _binds_shift("d + interval '2' year", 24, 0)
    _binds_shift("d + interval '2' week", 0, 14)
    _binds_shift("d - interval '1' month", -1, 0)
    _binds_shift("d - interval '1' year", -12, 0)
    _binds_shift("d - interval '10' day", 0, -10)
    _binds_shift("d - interval '1' week", 0, -7)
    _binds_shift("d + interval '-4' day", 0, -4)
    _binds_shift("d - interval '-4' day", 0, 4)
    _binds_shift("interval '1' year + d", 12, 0)
    _binds_shift("interval '5' day + d", 0, 5)
    _binds_shift("interval '1000000000' month + d", 1000000000, 0)
    _binds_shift("d - interval '1000000000' day", 0, -1000000000)


def test_interval_chain_nests_one_shift_per_interval_under_one_cast() raises:
    var plan = _got(
        "SELECT d FROM t WHERE d < d + interval '1' month + interval '2' day"
    )
    var want = (
        "Cast(DateAdd(months=0, days=2, DateAdd(months=1, days=0, ColRef(d))), "
    )
    assert_true(want in plan, plan)
    assert_true("Cast(DateAdd(months=0, days=2, Cast(" not in plan, plan)
    var minus = _got("SELECT d FROM t WHERE d < d + interval '1' year - interval '1' day")
    assert_true(
        "Cast(DateAdd(months=0, days=-1, DateAdd(months=12, days=0, ColRef(d))), "
        in minus,
        minus,
    )
    var left = _got("SELECT d FROM t WHERE d < interval '1' day + (d + interval '1' month)")
    assert_true(
        "Cast(DateAdd(months=0, days=1, DateAdd(months=1, days=0, ColRef(d))), "
        in left,
        left,
    )


def test_interval_shift_follows_a_date_integer_shift() raises:
    var plan = _got("SELECT d FROM t WHERE d < d + 3 + interval '1' month")
    assert_true(
        "Cast(DateAdd(months=1, days=0, DateAdd(months=0, days=3, ColRef(d))), "
        in plan,
        plan,
    )


def test_date_column_interval_in_the_select_list_and_post_aggregate_binders() raises:
    var sel = _got("SELECT d + interval '1' day AS nd FROM t")
    assert_true(_shifted(0, 1, "d") in sel, sel)
    var agg = _got("SELECT max(d) + interval '1' month AS nd FROM t")
    assert_true(not agg.startswith("ERR: "), agg)
    assert_true("Cast(DateAdd(months=1, days=0, ColRef(" in agg, agg)
    var left = _got("SELECT interval '1' month + max(d) AS nd FROM t")
    assert_true("Cast(DateAdd(months=1, days=0, ColRef(" in left, left)
    var having = _got(
        "SELECT x, max(d) AS m FROM t GROUP BY x HAVING max(d) < min(d) + interval '7' day"
    )
    assert_true(not having.startswith("ERR: "), having)
    assert_true("Cast(DateAdd(months=0, days=7, ColRef(" in having, having)
    var grouped = _got("SELECT d + interval '1' day AS nd, count(*) FROM t GROUP BY d")
    assert_true(not grouped.startswith("ERR: "), grouped)
    assert_true("DateAdd(months=0, days=1, ColRef(d))" in grouped, grouped)


def test_date_column_interval_in_a_correlated_subquery_predicate() raises:
    var right_form = _corr_inner_of(
        "SELECT x FROM t WHERE EXISTS (SELECT 1 FROM u WHERE u.k = t.x"
        " AND u.d < d + interval '1' day)"
    )
    assert_true(_shifted(0, 1, "d") in right_form, right_form)
    var left_form = _corr_inner_of(
        "SELECT x FROM t WHERE EXISTS (SELECT 1 FROM u WHERE u.k = t.x"
        " AND u.d < interval '2' month + d)"
    )
    assert_true(_shifted(2, 0, "d") in left_form, left_form)
    var minus = _corr_inner_of(
        "SELECT x FROM t WHERE EXISTS (SELECT 1 FROM u WHERE u.k = t.x"
        " AND u.d > d - interval '1' year)"
    )
    assert_true(_shifted(-12, 0, "d") in minus, minus)


def test_non_date_operand_of_an_interval_is_refused() raises:
    _refuses("timestamp '2000-01-01 00:00:00' + interval '1' day", "needs a DATE operand")
    _refuses("'1994-01-01' + interval '1' day", "needs a DATE operand")
    _refuses("ts + interval '1' day", "needs a DATE operand")
    _refuses("interval '1' day + ts", "needs a DATE operand")
    _refuses("x + interval '1' day", "needs a DATE operand")
    _refuses("(x * 2) + interval '1' day", "needs a DATE operand")


def test_interval_beyond_a_date_shift_is_refused() raises:
    _refuses("d + interval '1000000000' year", "beyond the range of a DATE shift")
    _refuses("d - interval '1000000000' year", "beyond the range of a DATE shift")
    _refuses("d + interval '1000000000' week", "beyond the range of a DATE shift")
    _refuses("d - interval '-1000000000' week", "beyond the range of a DATE shift")
    _refuses("d + interval '-1000000000' year", "beyond the range of a DATE shift")


def test_interval_const_reads_months_and_days() raises:
    var y = interval_const(SqlExpr.interval_lit(2, SXIVL_YEAR), False)
    assert_equal(y.months, 24)
    assert_equal(y.days, 0)
    var m = interval_const(SqlExpr.interval_lit(3, SXIVL_MONTH), False)
    assert_equal(m.months, 3)
    assert_equal(m.days, 0)
    var w = interval_const(SqlExpr.interval_lit(2, SXIVL_WEEK), False)
    assert_equal(w.months, 0)
    assert_equal(w.days, 14)
    var d = interval_const(SqlExpr.interval_lit(5, SXIVL_DAY), False)
    assert_equal(d.months, 0)
    assert_equal(d.days, 5)
    var neg = interval_const(SqlExpr.interval_lit(5, SXIVL_DAY), True)
    assert_equal(neg.days, -5)
    var neg_year = interval_const(SqlExpr.interval_lit(-1, SXIVL_YEAR), True)
    assert_equal(neg_year.months, 12)


def test_interval_anywhere_else_is_refused() raises:
    _refuses("interval '1' day", "only accepted as")
    _refuses("interval '1' day - date '2000-01-01'", "only accepted as")
    _refuses("interval '1' day - d", "only accepted as")
    _refuses("interval '1' day + interval '1' day", "only accepted as")
    _refuses("date '2000-01-01' + interval '1' day * 2", "only accepted as")
    _refuses("date '2000-01-01' + 2 * interval '1' day", "only accepted as")
    _refuses("d + interval '1' day * 2", "only accepted as")
    var proj = _got("SELECT interval '1' day AS i FROM t")
    assert_true("only accepted as" in proj, proj)
    var agg = _got("SELECT max(interval '1' day) FROM t")
    assert_true("only accepted as" in agg, agg)
    var corr_alone = _got(
        "SELECT x FROM t WHERE EXISTS (SELECT 1 FROM u WHERE u.k = t.x AND u.d < interval '1' day)"
    )
    assert_true("only accepted as" in corr_alone, corr_alone)
    var post_alone = _got("SELECT interval '1' day - max(d) FROM t")
    assert_true("only accepted as" in post_alone, post_alone)


def test_column_valued_interval_is_refused_by_name() raises:
    for q in List[String](
        "interval (x) day", "interval x day", "interval t.x day",
        "d + interval (x) day", "d + interval x month",
    ):
        var plan = _got("SELECT d FROM t WHERE d < " + q)
        assert_true(plan.startswith("ERR: "), q + " bound: " + plan)
        assert_true("non-constant count" in plan, q + " raised: " + plan)


def test_out_of_range_results_are_refused() raises:
    _refuses("date '9999-12-31' + interval '1' day", "out of range")
    _refuses("date '9999-12-31' + interval '1' year", "out of range")
    _refuses("date '0001-01-01' - interval '1' day", "out of range")
    _refuses("date '0001-01-01' - interval '1' month", "out of range")
    _refuses("date '1994-01-01' + interval '1000000000' year", "out of range")
    _refuses("date '1994-01-01' - interval '1000000000' day", "out of range")


def _first_corr_inner(e: Expr) raises -> String:
    """The rendered inner plan of the first correlated subquery under `e`'s
    AND / OR / comparison and unary nodes, or ""."""
    if e.tag == EXPR_CORRELATED_SUBQUERY:
        return String(corr_subq_inner_plan_ref(e))
    if e.tag == EXPR_BINARY_OP:
        var l = _first_corr_inner(e.binary_left_ref())
        if l != "":
            return l^
        return _first_corr_inner(e.binary_right_ref())
    if e.tag == EXPR_UNARY_OP:
        return _first_corr_inner(e.unary_child_ref())
    return String("")


def _plan_corr_inner(p: LogicalPlan) raises -> String:
    if p.tag == PLAN_FILTER:
        return _first_corr_inner(p.filter_data_ref().predicate)
    if p.tag == PLAN_PROJECT:
        return _plan_corr_inner(p.project_data_ref().child[])
    return String("")


def _corr_inner_of(sql: String) raises -> String:
    var cat = _catalog()
    var bound = bind_statement(parse_sql(tokenize(sql)), cat, NoParquetFooters())
    return _plan_corr_inner(bound.take_plan())


def test_q20_shaped_correlated_subquery_holds_the_folded_dates() raises:
    var lo = "BinaryOp(GE, ColRef(d), " + _lit("1994-01-01") + ")"
    var hi = "BinaryOp(LT, ColRef(d), " + _lit("1995-01-01") + ")"
    var right_form = _corr_inner_of(
        "SELECT x FROM t WHERE EXISTS (SELECT 1 FROM u WHERE u.k = t.x"
        " AND u.d >= date '1994-01-01' AND u.d < date '1994-01-01' + interval '1' year)"
    )
    assert_true(lo in right_form, right_form)
    assert_true(hi in right_form, right_form)
    var left_form = _corr_inner_of(
        "SELECT x FROM t WHERE EXISTS (SELECT 1 FROM u WHERE u.k = t.x"
        " AND u.d >= date '1994-01-01' AND u.d < interval '1' year + date '1994-01-01')"
    )
    assert_true(lo in left_form, left_form)
    assert_true(hi in left_form, left_form)
    var minus = _corr_inner_of(
        "SELECT x FROM t WHERE EXISTS (SELECT 1 FROM u WHERE u.k = t.x"
        " AND u.d > date '1995-01-01' - interval '1' year)"
    )
    assert_true("BinaryOp(GT, ColRef(d), " + _lit("1994-01-01") + ")" in minus, minus)


def test_left_operand_fold_in_every_expression_binder() raises:
    var dt = _lit("1995-01-01")
    var having = _got(
        "SELECT x, max(d) AS m FROM t GROUP BY x"
        " HAVING max(d) < interval '1' year + date '1994-01-01'"
    )
    assert_true(not having.startswith("ERR: "), having)
    assert_true(dt in having, having)
    var agg = _got("SELECT max(d) < interval '1' year + date '1994-01-01' AS b FROM t")
    assert_true(not agg.startswith("ERR: "), agg)
    assert_true(dt in agg, agg)
    var sel = _got("SELECT interval '1' year + date '1994-01-01' AS nd FROM t")
    assert_true(dt in sel, sel)


def test_order_by_a_folded_date_binds_and_a_bare_date_literal_does_not() raises:
    var ok = _got("SELECT d FROM t ORDER BY date '1994-01-01' + interval '1' year")
    assert_true(not ok.startswith("ERR: "), ok)
    var bare = _got("SELECT d FROM t ORDER BY date '1994-01-01'")
    assert_true("has no effect" in bare, bare)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
