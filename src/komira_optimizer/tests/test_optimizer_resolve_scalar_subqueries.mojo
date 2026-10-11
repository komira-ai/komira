# =============================================================================
# test_optimizer_resolve_scalar_subqueries -- request, bind, inline
# =============================================================================
#
# `resolve_scalar_subqueries_rewrite` runs in three phases: collect the
# uncorrelated SCALAR subquery sites, look each one up in the dependency table
# (a miss records a request), and, only when every site is bound, rewrite each
# site to a literal in the same pre-order it was collected in. These tests pin
# each phase and every plan and expression shape the two walkers visit, and
# the counting helper `find_uncorrelated_scalar_subqueries` that mirrors them.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_true, assert_false

from komira_arrow.arrow_types import ArrowType
from komira_arrow.schema import Field, SchemaBuilder
from komira_plan_expr.expr import (
    Expr,
    WhenCaseData,
    EXPR_LITERAL,
    EXPR_COL_REF,
    EXPR_CORRELATED_SUBQUERY,
    EXPR_WHEN,
    BIN_GT,
    BIN_LT,
    BIN_EQ,
    BIN_AND,
    UN_NEGATE,
    STR_LIKE,
)
from komira_plan_expr.scalar_value import ScalarValue
from komira_plan_expr.agg_expr import AggExpr, AGG_SUM, AGG_MAX
from komira_plan_ir.logical_plan import (
    LogicalPlan,
    ExprArray,
    AggExprArray,
    SOURCE_PARQUET,
    CORR_KIND_SCALAR,
    PLAN_FILTER,
    PLAN_PROJECT,
    PLAN_SORT,
    PLAN_LIMIT,
    PLAN_DISTINCT,
    PLAN_TOPN,
    PLAN_AGGREGATE,
)

from komira_optimizer.optimizer_scalar_deps import (
    ScalarDepTable,
    DEP_SCALAR_SUBQUERY,
)
from komira_optimizer.optimizer_resolve_scalar_subqueries import (
    resolve_scalar_subqueries_rewrite,
)
from komira_optimizer.resolve_scalar_subqueries import (
    find_uncorrelated_scalar_subqueries,
    resolve_scalar_subqueries,
    SCALAR_SUBQUERY_MULTIPLE_ROWS,
    _is_uncorrelated_scalar_subquery,
)


# =============================================================================
# Fixtures
# =============================================================================


def _lineitem() -> LogicalPlan:
    var b = SchemaBuilder()
    b.add_field(Field(String("l_orderkey"), ArrowType.INT64, False))
    b.add_field(Field(String("l_quantity"), ArrowType.INT64, False))
    return LogicalPlan.scan(String("lineitem.parquet"), SOURCE_PARQUET, b.build())


def _orders() -> LogicalPlan:
    var b = SchemaBuilder()
    b.add_field(Field(String("o_custkey"), ArrowType.INT64, False))
    return LogicalPlan.scan(String("orders.parquet"), SOURCE_PARQUET, b.build())


def _inner(func: UInt8) -> LogicalPlan:
    """`SELECT <func>(o_custkey) FROM orders`; the func picks the hash."""
    var aggs = AggExprArray()
    aggs.append(AggExpr(
        func,
        Optional(Expr.col_ref(String("o_custkey"))),
        Optional(String("v")),
    ))
    return LogicalPlan.aggregate(ExprArray(), aggs^, _orders())


def _subq(func: UInt8 = AGG_SUM) -> Expr:
    """An uncorrelated scalar subquery over `_inner(func)`."""
    return Expr.correlated_subquery(_inner(func), List[String](), CORR_KIND_SCALAR)


def _correlated() -> Expr:
    """A CORRELATED scalar subquery: not this pass's business."""
    var refs = List[String]()
    refs.append(String("l_orderkey"))
    return Expr.correlated_subquery(_inner(AGG_SUM), refs^, CORR_KIND_SCALAR)


def _q() -> Expr:
    return Expr.col_ref(String("l_quantity"))


def _lit(v: Int) -> Expr:
    return Expr.literal(ScalarValue.from_int(v))


def _gt(var l: Expr, var r: Expr) -> Expr:
    return Expr.binary(BIN_GT, l^, r^)


def _and(var l: Expr, var r: Expr) -> Expr:
    return Expr.binary(BIN_AND, l^, r^)


def _bound(func: UInt8, v: Int) -> ScalarDepTable:
    var deps = ScalarDepTable()
    deps.bind_scalar(_inner(func).structural_hash(), ScalarValue.from_int(v))
    return deps^


# =============================================================================
# Phase 1 / 2: no site, a miss, de-duplication, a partial bind
# =============================================================================


def test_a_plan_without_a_subquery_passes_through() raises:
    # Catches: a pass that rebuilds or requests when there is nothing to do.
    var plan = LogicalPlan.filter(_gt(_q(), _lit(5)), _lineitem())
    var before = plan.structural_hash()
    var deps = ScalarDepTable()
    var out = resolve_scalar_subqueries_rewrite(plan^, deps)
    assert_equal(out.structural_hash(), before)
    assert_equal(deps.num_requests(), 0)


def test_a_miss_requests_the_inner_plan_and_leaves_the_site() raises:
    # Catches: a miss that rewrites anyway, or a request keyed on anything but
    # the inner plan's structural hash (bindings are keyed by it).
    var plan = LogicalPlan.filter(_gt(_q(), _subq()), _lineitem())
    var before = plan.structural_hash()
    var deps = ScalarDepTable()
    var out = resolve_scalar_subqueries_rewrite(plan^, deps)
    assert_equal(out.structural_hash(), before)
    assert_equal(deps.num_requests(), 1)
    assert_equal(Int(deps.request_kind(0)), Int(DEP_SCALAR_SUBQUERY))
    var h = _inner(AGG_SUM).structural_hash()
    assert_equal(deps.request_key(0), h)
    assert_equal(deps.request_plan(0).structural_hash(), h)


def test_one_subquery_used_twice_is_one_request() raises:
    # Catches: one request per occurrence (N executions of one subquery).
    var pred = _and(_gt(_q(), _subq()), _gt(_subq(), _q()))
    var plan = LogicalPlan.filter(pred^, _lineitem())
    var deps = ScalarDepTable()
    _ = resolve_scalar_subqueries_rewrite(plan^, deps)
    assert_equal(deps.num_requests(), 1)


def test_a_partial_bind_rewrites_nothing_and_requests_the_rest() raises:
    # Catches: rewriting the bound site while another is unbound, which breaks
    # the lockstep between the collected sites and the rewrite counter.
    var pred = _and(_gt(_q(), _subq(AGG_SUM)), _gt(_q(), _subq(AGG_MAX)))
    var plan = LogicalPlan.filter(pred^, _lineitem())
    var before = plan.structural_hash()
    var deps = _bound(AGG_SUM, 100)
    var out = resolve_scalar_subqueries_rewrite(plan^, deps)
    assert_equal(out.structural_hash(), before)
    assert_equal(deps.num_requests(), 1)
    assert_equal(deps.request_key(0), _inner(AGG_MAX).structural_hash())


# =============================================================================
# Phase 3: the rewrite
# =============================================================================


def test_a_bound_site_becomes_its_literal() raises:
    # Catches: a rewrite that drops the comparison, substitutes the wrong
    # value, or still records a request when every site is bound.
    var plan = LogicalPlan.filter(_gt(_q(), _subq()), _lineitem())
    assert_equal(find_uncorrelated_scalar_subqueries(plan), 1)
    var deps = _bound(AGG_SUM, 100)
    var out = resolve_scalar_subqueries_rewrite(plan^, deps)
    assert_equal(deps.num_requests(), 0)
    assert_equal(out.tag, PLAN_FILTER)
    ref pred = out.filter_data_ref().predicate
    assert_equal(Int(pred.binary_op()), Int(BIN_GT))
    assert_equal(pred.binary_left_ref().tag, EXPR_COL_REF)
    assert_equal(pred.binary_right_ref().tag, EXPR_LITERAL)
    assert_equal(Int(pred.binary_right_ref().literal_value().int_val), 100)
    assert_equal(find_uncorrelated_scalar_subqueries(out), 0)


def test_two_bound_sites_take_their_values_in_collection_order() raises:
    # Catches: a rewrite counter that does not advance, or one that walks the
    # right operand before the left (each site would get the other's value).
    var pred = _and(_gt(_q(), _subq(AGG_SUM)), _gt(_q(), _subq(AGG_MAX)))
    var plan = LogicalPlan.filter(pred^, _lineitem())
    var deps = _bound(AGG_SUM, 1)
    deps.bind_scalar(_inner(AGG_MAX).structural_hash(), ScalarValue.from_int(2))
    var out = resolve_scalar_subqueries_rewrite(plan^, deps)
    ref p = out.filter_data_ref().predicate
    assert_equal(Int(p.binary_left_ref().binary_right_ref().literal_value().int_val), 1)
    assert_equal(Int(p.binary_right_ref().binary_right_ref().literal_value().int_val), 2)


def _every_container() -> Expr:
    """One AND chain holding the subquery inside every container both walkers
    descend (binary, unary, cast, alias, string op, IN list, agg fn), plus
    three things they must leave alone: a correlated subquery, a column, and a
    subquery under CASE (not on the walk set)."""
    var vals = List[ScalarValue]()
    vals.append(ScalarValue.from_int(1))
    var cases = List[WhenCaseData]()
    cases.append(WhenCaseData(_gt(_q(), _lit(0)), _subq()))
    var e = _gt(_q(), _subq())
    e = _and(e^, Expr.binary(BIN_EQ, Expr.unary(UN_NEGATE, _subq()), _lit(1)))
    e = _and(e^, Expr.binary(BIN_EQ, Expr.cast(_subq(), DType.float64), _lit(1)))
    e = _and(e^, Expr.binary(BIN_EQ, Expr.alias(_subq(), String("a")), _lit(1)))
    e = _and(e^, Expr.string_op(STR_LIKE, _subq(), String("1%")))
    e = _and(e^, Expr.in_list_node(_subq(), vals^))
    e = _and(e^, Expr.binary(BIN_EQ, Expr.agg_fn(AGG_MAX, _subq()), _lit(1)))
    e = _and(e^, Expr.binary(BIN_LT, _q(), _correlated()))
    e = _and(e^, Expr.binary(BIN_EQ, Expr.when(cases^, _lit(0)), _lit(1)))
    return e^


def test_every_container_is_counted_and_rewritten() raises:
    # Catches: a container arm dropped from the count, the collector or the
    # rewriter (a dropped collector arm leaves a site unbound and a dropped
    # rewriter arm trips the lockstep check); a correlated subquery or a CASE
    # body being rewritten.
    var plan = LogicalPlan.filter(_every_container(), _lineitem())
    assert_equal(find_uncorrelated_scalar_subqueries(plan), 7)
    var deps = _bound(AGG_SUM, 3)
    var out = resolve_scalar_subqueries_rewrite(plan^, deps)
    assert_equal(deps.num_requests(), 0)
    assert_equal(find_uncorrelated_scalar_subqueries(out), 0)
    # Walk the left-deep AND chain from the right: the CASE, the correlated
    # subquery, then the rewritten containers.
    ref top = out.filter_data_ref().predicate
    ref when_cmp = top.binary_right_ref()
    assert_equal(when_cmp.binary_left_ref().tag, EXPR_WHEN)
    assert_equal(
        when_cmp.binary_left_ref().when_case_result_ref(0).tag,
        EXPR_CORRELATED_SUBQUERY,
    )
    ref rest = top.binary_left_ref()
    assert_equal(
        rest.binary_right_ref().binary_right_ref().tag, EXPR_CORRELATED_SUBQUERY
    )
    ref agg_cmp = rest.binary_left_ref().binary_right_ref()
    assert_equal(agg_cmp.binary_left_ref().agg_fn_child_ref().tag, EXPR_LITERAL)
    ref r2 = rest.binary_left_ref().binary_left_ref()
    assert_equal(r2.binary_right_ref().in_list_child_ref().tag, EXPR_LITERAL)
    assert_equal(r2.binary_right_ref().in_list_len(), 1)
    ref r3 = r2.binary_left_ref()
    assert_equal(r3.binary_right_ref().string_op_child_ref().tag, EXPR_LITERAL)
    assert_equal(r3.binary_right_ref().string_op_pattern(), String("1%"))
    ref r4 = r3.binary_left_ref()
    assert_equal(
        r4.binary_right_ref().binary_left_ref().alias_child_ref().tag, EXPR_LITERAL
    )
    assert_equal(r4.binary_right_ref().binary_left_ref().alias_name(), String("a"))
    ref r5 = r4.binary_left_ref()
    assert_equal(
        r5.binary_right_ref().binary_left_ref().cast_child_ref().tag, EXPR_LITERAL
    )
    assert_true(r5.binary_right_ref().binary_left_ref().cast_target() == DType.float64)
    ref r6 = r5.binary_left_ref()
    assert_equal(
        r6.binary_right_ref().binary_left_ref().unary_child_ref().tag, EXPR_LITERAL
    )
    assert_equal(
        Int(r6.binary_right_ref().binary_left_ref().unary_op()), Int(UN_NEGATE)
    )
    assert_equal(r6.binary_left_ref().binary_right_ref().tag, EXPR_LITERAL)


def test_every_plan_shape_on_the_walk_is_rewritten() raises:
    # Plan: TopN(Distinct(Limit(Sort(Project([sq AS v, l_quantity],
    #       Filter(l_quantity > sq, lineitem)))))).
    # Catches: a plan arm dropped from the count, collector or rewriter; a
    # rebuild that loses the LIMIT offset, the DISTINCT columns, the TopN n or
    # an explicit NULLS FIRST.
    var pexprs = ExprArray()
    pexprs.append(Expr.alias(_subq(), String("v")))
    pexprs.append(_q())
    var filt = LogicalPlan.filter(_gt(_q(), _subq()), _lineitem())
    var proj = LogicalPlan.project(pexprs^, filt^)
    var keys = List[String]()
    keys.append(String("v"))
    var desc = List[Bool]()
    desc.append(False)
    var nf = List[Bool]()
    nf.append(True)
    var sort = LogicalPlan.sort(keys.copy(), desc.copy(), proj^, Optional(nf.copy()))
    var limit = LogicalPlan.limit(10, sort^, offset=3)
    var dcols = List[String]()
    dcols.append(String("v"))
    var dist = LogicalPlan.distinct(Optional(dcols^), limit^)
    var plan = LogicalPlan.topn(keys^, desc^, 4, dist^, Optional(nf^))
    assert_equal(find_uncorrelated_scalar_subqueries(plan), 2)

    var deps = _bound(AGG_SUM, 7)
    var out = resolve_scalar_subqueries_rewrite(plan^, deps)
    assert_equal(find_uncorrelated_scalar_subqueries(out), 0)
    assert_equal(out.tag, PLAN_TOPN)
    assert_equal(out.topn_data_ref().n, 4)
    assert_true(out.topn_data_ref().nulls_first[0])
    ref d = out.topn_data_ref().child[]
    assert_equal(d.tag, PLAN_DISTINCT)
    assert_equal(d.distinct_data_ref().columns.value()[0], String("v"))
    ref l = d.distinct_data_ref().child[]
    assert_equal(l.tag, PLAN_LIMIT)
    assert_equal(l.limit_data_ref().n, 10)
    assert_equal(l.limit_data_ref().offset, 3)
    ref s = l.limit_data_ref().child[]
    assert_equal(s.tag, PLAN_SORT)
    assert_true(s.sort_data_ref().nulls_first[0])
    ref p = s.sort_data_ref().child[]
    assert_equal(p.tag, PLAN_PROJECT)
    ref v = p.project_data_ref().exprs[0]
    assert_equal(v.alias_child_ref().tag, EXPR_LITERAL)
    assert_equal(Int(v.alias_child_ref().literal_value().int_val), 7)
    ref f = p.project_data_ref().child[]
    assert_equal(f.tag, PLAN_FILTER)
    assert_equal(f.filter_data_ref().predicate.binary_right_ref().tag, EXPR_LITERAL)


def test_a_distinct_without_columns_keeps_none() raises:
    # Catches: a DISTINCT rebuild that invents a column list.
    var filt = LogicalPlan.filter(_gt(_q(), _subq()), _lineitem())
    var plan = LogicalPlan.distinct(None, filt^)
    var deps = _bound(AGG_SUM, 7)
    var out = resolve_scalar_subqueries_rewrite(plan^, deps)
    assert_equal(out.tag, PLAN_DISTINCT)
    assert_false(Bool(out.distinct_data_ref().columns))
    assert_equal(find_uncorrelated_scalar_subqueries(out), 0)


def test_a_subquery_below_an_aggregate_is_out_of_reach() raises:
    # The walk stops at an Aggregate (a stated limit, not a bug). Catches: a
    # counter that descends further than the collector, which would make the
    # count promise a rewrite the pass never does.
    var filt = LogicalPlan.filter(_gt(_q(), _subq()), _lineitem())
    var aggs = AggExprArray()
    aggs.append(AggExpr(AGG_SUM, Optional(_q()), Optional(String("s"))))
    var plan = LogicalPlan.aggregate(ExprArray(), aggs^, filt^)
    assert_equal(find_uncorrelated_scalar_subqueries(plan), 0)
    var before = plan.structural_hash()
    var deps = ScalarDepTable()
    var out = resolve_scalar_subqueries_rewrite(plan^, deps)
    assert_equal(out.tag, PLAN_AGGREGATE)
    assert_equal(out.structural_hash(), before)
    assert_equal(deps.num_requests(), 0)


def test_the_multiple_rows_prefix_is_stable() raises:
    # The executing caller this is designed for (not in this tree) raises with
    # this prefix and tests match on it; catches a rename.
    assert_equal(SCALAR_SUBQUERY_MULTIPLE_ROWS, String("ScalarSubqueryMultipleRows"))


def test_the_site_predicate() raises:
    # The walkers ask only about subquery nodes; called directly the
    # predicate must also refuse a non-subquery. Catches: a predicate that
    # reads the subquery payload of any node, or one that ignores outer refs.
    assert_false(_is_uncorrelated_scalar_subquery(_q()))
    assert_false(_is_uncorrelated_scalar_subquery(_correlated()))
    assert_true(_is_uncorrelated_scalar_subquery(_subq()))


# =============================================================================
# The no-execution form
# =============================================================================


def test_the_no_execution_form_keeps_an_uncorrelated_subquery() raises:
    # `resolve_scalar_subqueries` has no dependency table, so it must return
    # the plan unchanged even when it holds an uncorrelated SCALAR subquery.
    # The welded `test_pass_returns_plan_unchanged` feeds a plan with no
    # subquery at all. Catches: a no-execution form that rewrites the site to
    # a literal, or drops it (or its Filter); either changes the hash and the
    # count.
    var plan = LogicalPlan.filter(_gt(_q(), _subq()), _lineitem())
    assert_equal(find_uncorrelated_scalar_subqueries(plan), 1)
    var before = plan.structural_hash()
    var out = resolve_scalar_subqueries(plan^)
    assert_equal(out.structural_hash(), before)
    assert_equal(find_uncorrelated_scalar_subqueries(out), 1)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
