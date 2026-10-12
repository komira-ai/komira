# =============================================================================
# test_optimizer_reorder_output_order -- a join reorder below a node whose
# output is its child's columns keeps that node's column order
# =============================================================================
#
# Filter, Sort, Limit, Distinct and TopN emit their child's columns in the
# child's order, and their cached `output_schema` is not recomputed when a
# reorder walker replaces their child. The driver's guard around the reorder
# (`restore_join_reorder_output_columns`) reads only the plan root's cached
# schema, so a permutation below such a node went unrestored: the node still
# reported the query's order while its child emitted the reordered one.
#
# Each test computes the columns a plan really emits by walking it (a
# Project's expressions, a join's left then right side, a scan's schema) and
# compares them with the query's order and with the root's cached schema.
#
# Fixture: (a(100000) JOIN b(10) ON ak = bk) JOIN d(1000) ON bk = dk. Three
# relations, so the reorder is greedy: b seeds, d joins, then a, and the
# reordered join emits bk, bv, dk, dv, ak, av.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_true

from komira_arrow.arrow_types import ArrowType
from komira_arrow.schema import Field, Schema, SchemaBuilder
from komira_plan_expr.agg_expr import AggExpr, AGG_COUNT
from komira_plan_expr.expr import Expr, BIN_GT, EXPR_ALIAS
from komira_plan_expr.scalar_value import ScalarValue
from komira_plan_ir.logical_plan import (
    LogicalPlan,
    ExprArray,
    AggExprArray,
    SOURCE_PARQUET,
    PLAN_FILTER,
    PLAN_PROJECT,
    PLAN_AGGREGATE,
    PLAN_JOIN,
    PLAN_SORT,
    PLAN_LIMIT,
    PLAN_DISTINCT,
    PLAN_TOPN,
    JOIN_INNER,
    JOIN_LEFT,
)
from komira_optimizer.optimizer_config import OptimizerConfig
from komira_optimizer.optimizer_scalar_deps import ScalarDepTable
from komira_optimizer.optimizer_driver import optimize
from komira_optimizer.optimizer_dpccp import reorder_joins_with_dp
from komira_optimizer.optimizer_reorder import reorder_joins


# -----------------------------------------------------------------------------
# Fixtures
# -----------------------------------------------------------------------------


def _scan(path: String, k: String, v: String, rows: Int) -> LogicalPlan:
    var sb = SchemaBuilder()
    sb.add_field(Field(k, ArrowType.INT64, False))
    sb.add_field(Field(v, ArrowType.INT64, False))
    return LogicalPlan.scan(path, SOURCE_PARQUET, sb.build(), None, None, rows)


def _l1(a: String) -> List[String]:
    var o = List[String]()
    o.append(a)
    return o^


def _abd() -> LogicalPlan:
    """(a(100000) JOIN b(10) ON ak = bk) JOIN d(1000) ON bk = dk."""
    var ab = LogicalPlan.join(
        _scan("a", "ak", "av", 100000), _scan("b", "bk", "bv", 10),
        _l1("ak"), _l1("bk"), JOIN_INNER,
    )
    return LogicalPlan.join(
        ab^, _scan("d", "dk", "dv", 1000), _l1("bk"), _l1("dk"), JOIN_INNER
    )


def _query_order() -> List[String]:
    return ["ak", "av", "bk", "bv", "dk", "dv"]


def _wrap(kind: Int, var child: LogicalPlan) raises -> LogicalPlan:
    """0 Filter, 1 Sort, 2 Limit, 3 Distinct, 4 TopN: the nodes that emit
    their child's columns in the child's order."""
    var asc = List[Bool]()
    asc.append(False)
    if kind == 0:
        var pred = Expr.binary(
            BIN_GT, Expr.col_ref("ak"), Expr.literal(ScalarValue.from_int(1))
        )
        return LogicalPlan.filter(pred^, child^)
    if kind == 1:
        return LogicalPlan.sort(_l1("ak"), asc^, child^)
    if kind == 2:
        return LogicalPlan.limit(5, child^)
    if kind == 3:
        var all_cols: Optional[List[String]] = None
        return LogicalPlan.distinct(all_cols^, child^)
    return LogicalPlan.topn(_l1("ak"), asc^, 5, child^)


def _wrap_tags() -> List[UInt8]:
    return [PLAN_FILTER, PLAN_SORT, PLAN_LIMIT, PLAN_DISTINCT, PLAN_TOPN]


# -----------------------------------------------------------------------------
# The columns a plan really emits
# -----------------------------------------------------------------------------


def _emit(plan: LogicalPlan, mut out: List[String]) raises:
    """Append the columns `plan` emits, derived from its nodes rather than
    read from any cached schema above a leaf. Join sides here never share a
    name, so a join emits its left columns then its right ones."""
    if plan.tag == PLAN_JOIN:
        _emit(plan.join_data_ref().left[], out)
        _emit(plan.join_data_ref().right[], out)
    elif plan.tag == PLAN_PROJECT:
        ref exprs = plan.project_data_ref().exprs
        for i in range(len(exprs)):
            if exprs[i].tag == EXPR_ALIAS:
                out.append(exprs[i].alias_name())
            else:
                out.append(exprs[i].col_ref_name())
    elif plan.tag == PLAN_FILTER:
        _emit(plan.filter_data_ref().child[], out)
    elif plan.tag == PLAN_SORT:
        _emit(plan.sort_data_ref().child[], out)
    elif plan.tag == PLAN_LIMIT:
        _emit(plan.limit_data_ref().child[], out)
    elif plan.tag == PLAN_DISTINCT:
        _emit(plan.distinct_data_ref().child[], out)
    elif plan.tag == PLAN_TOPN:
        _emit(plan.topn_data_ref().child[], out)
    else:
        for i in range(plan.output_schema.num_columns()):
            out.append(plan.output_schema.field_name(i))


def _emitted(plan: LogicalPlan) raises -> String:
    var cols = List[String]()
    _emit(plan, cols)
    return _join(cols)


def _cached(plan: LogicalPlan) -> String:
    var cols = List[String]()
    for i in range(plan.output_schema.num_columns()):
        cols.append(plan.output_schema.field_name(i))
    return _join(cols)


def _join(cols: List[String]) -> String:
    var s = String("")
    for i in range(len(cols)):
        if i > 0:
            s += ","
        s += cols[i]
    return s^


def _want() -> String:
    return _join(_query_order())


# -----------------------------------------------------------------------------
# The driver (the case komira-ai/komira#1439 records)
# -----------------------------------------------------------------------------


def test_driver_keeps_the_query_order_below_a_limit() raises:
    """`Limit 5` over the three-way join: the plan `optimize` returns emits
    ak, av, bk, bv, dk, dv, and its root's cached schema says the same.

    Defect caught: the reorder below the Limit restored by nobody. The Limit
    keeps its stale cached schema, the root guard compares it with itself,
    and the plan emits bk, bv, dk, dv, ak, av."""
    var deps = ScalarDepTable()
    var out = optimize(LogicalPlan.limit(5, _abd()), OptimizerConfig(), deps)
    assert_equal(_emitted(out), _want())
    assert_equal(_cached(out), _want())


# -----------------------------------------------------------------------------
# reorder_joins_with_dp (the driver's walker)
# -----------------------------------------------------------------------------


def test_dp_walker_keeps_the_order_below_each_pass_through_node() raises:
    """Filter, Sort, Limit, Distinct and TopN over the join: each keeps its
    tag, its child is reordered (b is the first leaf) and the node emits the
    query's order.

    Defect caught: any of the five arms recursing without restoring its
    child's order (that node emits bk, bv, dk, dv, ak, av)."""
    var tags = _wrap_tags()
    for k in range(5):
        var out = reorder_joins_with_dp(_wrap(k, _abd()))
        assert_equal(out.tag, tags[k])
        assert_equal(_emitted(out), _want())
        assert_equal(_cached(out), _want())
        assert_true(_first_leaf(out) == "b")


def test_dp_walker_keeps_the_order_below_an_outer_join_barrier() raises:
    """Limit over LEFT(join, e(1)) ON ak = ek: the chain under the barrier is
    reordered, the barrier's rebuild takes the reordered column order, and
    the Limit still emits the query's order.

    Defect caught: the Limit arm comparing against the barrier's rebuilt
    (already permuted) schema instead of the one it held before the walk."""
    var lj = LogicalPlan.join(
        _abd(), _scan("e", "ek", "ev", 1), _l1("ak"), _l1("ek"), JOIN_LEFT
    )
    var out = reorder_joins_with_dp(LogicalPlan.limit(5, lj^))
    assert_equal(out.tag, PLAN_LIMIT)
    assert_equal(_emitted(out), "ak,av,bk,bv,dk,dv,ek,ev")
    assert_equal(_cached(out), "ak,av,bk,bv,dk,dv,ek,ev")
    assert_true(_first_leaf(out) == "b")


def test_dp_walker_adds_nothing_under_a_by_name_parent() raises:
    """A Project and an Aggregate read their child by name, so the reordered
    join sits directly under each.

    Defect caught: the restore applied to every arm (a Project between a
    Project or Aggregate and the join, on the common path)."""
    var pe = ExprArray()
    pe.append(Expr.col_ref("dv"))
    var proj = reorder_joins_with_dp(LogicalPlan.project(pe^, _abd()))
    assert_equal(proj.project_data_ref().child[].tag, PLAN_JOIN)
    assert_true(_first_leaf(proj) == "b")
    var keys = ExprArray()
    keys.append(Expr.col_ref("ak"))
    var aggs = AggExprArray()
    var none_arg: Optional[Expr] = None
    aggs.append(AggExpr(AGG_COUNT, none_arg^, Optional[String](String("n"))))
    var agg = reorder_joins_with_dp(LogicalPlan.aggregate(keys^, aggs^, _abd()))
    assert_equal(agg.aggregate_data_ref().child[].tag, PLAN_JOIN)
    assert_true(_first_leaf(agg) == "b")


# -----------------------------------------------------------------------------
# reorder_joins (the greedy-only walker)
# -----------------------------------------------------------------------------


def test_greedy_walker_keeps_the_order_below_each_pass_through_node() raises:
    """The same five nodes over the same join, through `reorder_joins`.

    Defect caught: any of its five arms recursing without restoring its
    child's order."""
    var tags = _wrap_tags()
    for k in range(5):
        var out = reorder_joins(_wrap(k, _abd()))
        assert_equal(out.tag, tags[k])
        assert_equal(_emitted(out), _want())
        assert_equal(_cached(out), _want())
        assert_true(_first_leaf(out) == "b")


def _first_leaf(plan: LogicalPlan) -> String:
    """The path of the leftmost scan, walking every single-child node."""
    if plan.tag == PLAN_JOIN:
        return _first_leaf(plan.join_data_ref().left[])
    if plan.tag == PLAN_PROJECT:
        return _first_leaf(plan.project_data_ref().child[])
    if plan.tag == PLAN_AGGREGATE:
        return _first_leaf(plan.aggregate_data_ref().child[])
    if plan.tag == PLAN_FILTER:
        return _first_leaf(plan.filter_data_ref().child[])
    if plan.tag == PLAN_SORT:
        return _first_leaf(plan.sort_data_ref().child[])
    if plan.tag == PLAN_LIMIT:
        return _first_leaf(plan.limit_data_ref().child[])
    if plan.tag == PLAN_DISTINCT:
        return _first_leaf(plan.distinct_data_ref().child[])
    if plan.tag == PLAN_TOPN:
        return _first_leaf(plan.topn_data_ref().child[])
    return plan.scan_data_ref().source_path


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
