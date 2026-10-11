# =============================================================================
# order_advisory: when advise_join_order fires, what it reports, and the
# walk through the nodes above a join chain
# =============================================================================
#
# Join estimates here are `estimate_cardinality`'s: an inner equi-join
# outputs max(|L|, |R|) rows. The three-relation chain
# (A(1000) JOIN B(10) ON a = b) JOIN C(100) ON b = c sums 1000 + 1000 = 2000
# intermediate rows; the reorderer (greedy, below the DPccp minimum) writes
# (B JOIN C) JOIN A, which sums 100 + 1000 = 1100.
#
# Each test names the defect it catches.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_true, assert_false

from komira_arrow.schema import Schema, SchemaBuilder, Field
from komira_arrow.arrow_types import ArrowType
from komira_plan_expr.expr import Expr, BIN_GT
from komira_plan_expr.agg_expr import AggExpr, AGG_COUNT
from komira_plan_expr.partition_expr import PartitionExpr
from komira_plan_expr.scalar_value import ScalarValue
from komira_plan_ir.logical_plan import (
    LogicalPlan,
    ExprArray,
    AggExprArray,
    SOURCE_PARQUET,
    PLAN_AGGREGATE,
    PLAN_DISTINCT,
    PLAN_FILTER,
    PLAN_JOIN,
    PLAN_LIMIT,
    PLAN_PARTITION_BY,
    PLAN_PARTITION_TOPN,
    PLAN_PROJECT,
    PLAN_SORT,
    JOIN_INNER,
)
from komira_async.runtime.sched_trace import (
    order_advisory_fire_count,
    order_advisory_fire_reset,
)
from komira_optimizer.order_advisory import OrderAdvisory, advise_join_order


# =============================================================================
# Helpers
# =============================================================================


def _schema(name: String) -> Schema:
    var b = SchemaBuilder()
    b.add_field(Field(name, ArrowType.INT64, False))
    return b.build()


def _one(a: String) -> List[String]:
    var l = List[String]()
    l.append(a)
    return l^


def _scan(name: String, rows: Int) -> LogicalPlan:
    var proj: Optional[List[String]] = None
    var filt: Optional[Expr] = None
    var rc: Optional[Int] = rows
    return LogicalPlan.scan(name + ".parquet", SOURCE_PARQUET, _schema(name), proj^, filt^, rc^)


def _inner(var l: LogicalPlan, var r: LogicalPlan, lk: String, rk: String) -> LogicalPlan:
    return LogicalPlan.join(l^, r^, _one(lk), _one(rk), JOIN_INNER)


def _chain3() -> LogicalPlan:
    """(A(1000) JOIN B(10) ON a = b) JOIN C(100) ON b = c."""
    return _inner(_inner(_scan("a", 1000), _scan("b", 10), "a", "b"), _scan("c", 100), "b", "c")


def _wrap(kind: Int, var child: LogicalPlan) raises -> LogicalPlan:
    """Kind 0..7: Filter, Project, Limit, Aggregate, Sort, Distinct,
    PartitionBy, PartitionTopN over `child`, each naming column `a`."""
    if kind == 0:
        var pred = Expr.binary(BIN_GT, Expr.col_ref("a"), Expr.literal(ScalarValue.from_int(5)))
        return LogicalPlan.filter(pred^, child^)
    if kind == 1:
        var e = ExprArray()
        e.append(Expr.col_ref("a"))
        e.append(Expr.col_ref("b"))
        e.append(Expr.col_ref("c"))
        return LogicalPlan.project(e^, child^)
    if kind == 2:
        return LogicalPlan.limit(1_000_000, child^)
    if kind == 3:
        var keys = ExprArray()
        keys.append(Expr.col_ref("a"))
        var aggs = AggExprArray()
        var none_child: Optional[Expr] = None
        aggs.append(AggExpr(AGG_COUNT, none_child^, Optional[String](String("n"))))
        return LogicalPlan.aggregate(keys^, aggs^, child^)
    var desc = List[Bool]()
    desc.append(False)
    if kind == 4:
        return LogicalPlan.sort(_one("a"), desc^, child^)
    if kind == 5:
        var none_cols: Optional[List[String]] = None
        return LogicalPlan.distinct(none_cols^, child^)
    if kind == 6:
        return LogicalPlan.partition_by(
            List[String](), _one("a"), desc^, List[PartitionExpr](), child^
        )
    return LogicalPlan.partition_topn(_one("b"), _one("a"), desc^, 5, child^)


# =============================================================================
# Firing
# =============================================================================


def test_a_costlier_written_order_fires() raises:
    """The chain: fired, author 2000 rows against 1100, blowup 1, both
    signatures, the counter moved once, and the warning line. Catches:
    the fire condition inverted, the costs or orders swapped, the counter
    bump dropped, and the warning text changed."""
    order_advisory_fire_reset()
    var adv = advise_join_order(_chain3())
    assert_true(adv.fired)
    assert_equal(adv.author_cost, 2000)
    assert_equal(adv.optimal_cost, 1100)
    assert_equal(adv.blowup, 1)
    assert_equal(adv.author_order, "(([a] [b]) [c])")
    assert_equal(adv.optimal_order, "(([b] [c]) [a])")
    assert_equal(order_advisory_fire_count(), UInt64(1))
    assert_equal(
        adv.warning(),
        "order advisory: author join order estimated 1x worse than optimal"
        + " (author intermediate rows ~2000, optimal ~1100); reorder"
        + " available. author=(([a] [b]) [c]) optimal=(([b] [c]) [a])",
    )


def test_blowup_is_the_cost_quotient() raises:
    """A(1,000,000) joined first to B, C and D (10 rows each) along the path
    a = b = c = d: the written order carries a million rows through three
    joins (3,000,000); the reorderer joins A last. The blowup is the
    integer quotient of the two costs, at least 2 here. Catches: a blowup
    not computed from the costs (a constant 1)."""
    order_advisory_fire_reset()
    var plan = _inner(
        _inner(
            _inner(_scan("a", 1_000_000), _scan("b", 10), "a", "b"),
            _scan("c", 10), "b", "c",
        ),
        _scan("d", 10), "c", "d",
    )
    var adv = advise_join_order(plan)
    assert_true(adv.fired)
    assert_equal(adv.author_cost, 3_000_000)
    assert_true(adv.optimal_cost < 1_500_001)
    assert_equal(adv.blowup, adv.author_cost // adv.optimal_cost)
    assert_true(adv.blowup >= 2)


def test_an_optimal_written_order_is_silent() raises:
    """(B JOIN C) JOIN A, the reorderer's own order: not fired, both costs
    1100, equal orders, the counter unmoved. Catches: a fire on an equal
    cost (the strict comparison relaxed)."""
    order_advisory_fire_reset()
    var plan = _inner(_inner(_scan("b", 10), _scan("c", 100), "b", "c"), _scan("a", 1000), "c", "a")
    var adv = advise_join_order(plan)
    assert_false(adv.fired)
    assert_equal(adv.blowup, 1)
    assert_equal(adv.author_cost, 1100)
    assert_equal(adv.optimal_cost, 1100)
    assert_equal(adv.author_order, adv.optimal_order)
    assert_equal(order_advisory_fire_count(), UInt64(0))


def test_an_equal_cost_reorder_is_silent() raises:
    """A(1000) JOIN B(1) ON a = b, then C(1000) ON b = c: the reorderer
    writes (B JOIN C) JOIN A, a different order, and both sum 2000 rows:
    not fired, the two orders reported as they differ, the counter
    unmoved. Catches: a fire on a changed order alone (the reorderer
    returns an equal-cost permutation of an already-optimal chain)."""
    order_advisory_fire_reset()
    var plan = _inner(_inner(_scan("a", 1000), _scan("b", 1), "a", "b"), _scan("c", 1000), "b", "c")
    var adv = advise_join_order(plan)
    assert_false(adv.fired)
    assert_equal(adv.author_cost, 2000)
    assert_equal(adv.optimal_cost, 2000)
    assert_equal(adv.author_order, "(([a] [b]) [c])")
    assert_equal(adv.optimal_order, "(([b] [c]) [a])")
    assert_equal(order_advisory_fire_count(), UInt64(0))


def test_a_plan_without_a_join_is_not_reordered() raises:
    """A scan, a Filter over it, and a node of each of the nine kinds the
    walk descends (Join, Filter, Project, Limit, Aggregate, Sort,
    Distinct, PartitionBy, PartitionTopN) without its payload: silent,
    zero costs, empty orders. Catches: the no-join early return removed
    (the orders would read "[a]"), and any one of the nine presence checks
    dropped (the walk would read an empty payload)."""
    order_advisory_fire_reset()
    var pred = Expr.binary(BIN_GT, Expr.col_ref("a"), Expr.literal(ScalarValue.from_int(5)))
    var plans = List[LogicalPlan]()
    plans.append(_scan("a", 10))
    plans.append(LogicalPlan.filter(pred^, _scan("a", 10)))
    plans.append(LogicalPlan(PLAN_JOIN, _schema("a")))
    plans.append(LogicalPlan(PLAN_FILTER, _schema("a")))
    plans.append(LogicalPlan(PLAN_PROJECT, _schema("a")))
    plans.append(LogicalPlan(PLAN_LIMIT, _schema("a")))
    plans.append(LogicalPlan(PLAN_AGGREGATE, _schema("a")))
    plans.append(LogicalPlan(PLAN_SORT, _schema("a")))
    plans.append(LogicalPlan(PLAN_DISTINCT, _schema("a")))
    plans.append(LogicalPlan(PLAN_PARTITION_BY, _schema("a")))
    plans.append(LogicalPlan(PLAN_PARTITION_TOPN, _schema("a")))
    for i in range(len(plans)):
        var adv = advise_join_order(plans[i])
        assert_false(adv.fired)
        assert_equal(adv.blowup, 1)
        assert_equal(adv.author_cost, 0)
        assert_equal(adv.optimal_cost, 0)
        assert_equal(adv.author_order, "")
        assert_equal(adv.optimal_order, "")
    assert_equal(order_advisory_fire_count(), UInt64(0))


# =============================================================================
# The walk
# =============================================================================


def test_the_walk_descends_every_node_above_a_chain() raises:
    """The chain under each of Filter, Project, Limit, Aggregate, Sort,
    Distinct, PartitionBy and PartitionTopN: the written order and cost
    are the chain's. Catches: any of the eight descents removed (that
    node would read as a leaf: no join, empty order)."""
    for k in range(8):
        var adv = advise_join_order(_wrap(k, _chain3()))
        assert_equal(adv.author_order, "(([a] [b]) [c])")
        assert_equal(adv.author_cost, 2000)


def test_a_leaf_label_lists_every_column() raises:
    """A leaf with columns x and y reads "[x,y]". Catches: the separator
    dropped or only the first column named."""
    var b = SchemaBuilder()
    b.add_field(Field("x", ArrowType.INT64, False))
    b.add_field(Field("y", ArrowType.INT64, False))
    var proj: Optional[List[String]] = None
    var filt: Optional[Expr] = None
    var rc: Optional[Int] = 5
    var xy = LogicalPlan.scan("xy.parquet", SOURCE_PARQUET, b.build(), proj^, filt^, rc^)
    var adv = advise_join_order(_inner(xy^, _scan("z", 5), "x", "z"))
    assert_equal(adv.author_order, "([x,y] [z])")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
