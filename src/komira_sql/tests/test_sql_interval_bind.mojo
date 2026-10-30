# =============================================================================
# sql_bind: DATE +/- INTERVAL folds to a DATE constant (sql_bind_interval)
# =============================================================================
#
# What each test proves, and the defect it would catch:
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
#   4. Refusals by name: a non-constant (column) DATE operand, a TIMESTAMP
#      operand, a bare INTERVAL, INTERVAL - DATE, INTERVAL * n, INTERVAL +
#      INTERVAL, an INTERVAL compared or used as a projection, and a result
#      outside years 1..9999. (catches: a column operand folded as its first
#      row or silently dropped; an out-of-range date wrapped)

from std.testing import TestSuite, assert_equal, assert_true

from komira_arrow.arrow_types import ArrowType
from komira_arrow.schema import Field, SchemaBuilder
from komira_plan_expr.expr import (
    EXPR_BINARY_OP, EXPR_CORRELATED_SUBQUERY, EXPR_UNARY_OP, Expr,
)
from komira_plan_ir.corr_subquery import corr_subq_inner_plan_ref
from komira_plan_ir.logical_plan import LogicalPlan, PLAN_FILTER, PLAN_PROJECT
from komira_sql.sql_bind_parquet import NoParquetFooters
from komira_sql.sql_bind_scope import _date_to_days
from komira_sql.sql_binder import bind_statement
from komira_sql.sql_catalog import SqlCatalog
from komira_sql.sql_parser import parse_sql
from komira_sql.sql_token import tokenize


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


def test_non_constant_date_operand_is_refused() raises:
    _refuses("d + interval '1' day", "needs a constant DATE")
    _refuses("d - interval '1' month", "needs a constant DATE")
    _refuses("interval '1' year + d", "needs a constant DATE")
    _refuses("timestamp '2000-01-01 00:00:00' + interval '1' day", "needs a constant DATE")
    _refuses("'1994-01-01' + interval '1' day", "needs a constant DATE")


def test_interval_anywhere_else_is_refused() raises:
    _refuses("interval '1' day", "only accepted as")
    _refuses("interval '1' day - date '2000-01-01'", "only accepted as")
    _refuses("interval '1' day + interval '1' day", "only accepted as")
    _refuses("date '2000-01-01' + interval '1' day * 2", "only accepted as")
    _refuses("date '2000-01-01' + 2 * interval '1' day", "only accepted as")
    var proj = _got("SELECT interval '1' day AS i FROM t")
    assert_true("only accepted as" in proj, proj)
    var agg = _got("SELECT max(interval '1' day) FROM t")
    assert_true("only accepted as" in agg, agg)
    var corr = _got(
        "SELECT x FROM t WHERE EXISTS (SELECT 1 FROM u WHERE u.k = t.x AND u.d < d + interval '1' day)"
    )
    assert_true(corr.startswith("ERR: "), corr)
    assert_true("needs a constant DATE" in corr, corr)
    var corr_left = _got(
        "SELECT x FROM t WHERE EXISTS (SELECT 1 FROM u WHERE u.k = t.x AND u.d < interval '1' day + d)"
    )
    assert_true("needs a constant DATE" in corr_left, corr_left)
    var corr_alone = _got(
        "SELECT x FROM t WHERE EXISTS (SELECT 1 FROM u WHERE u.k = t.x AND u.d < interval '1' day)"
    )
    assert_true("only accepted as" in corr_alone, corr_alone)


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
