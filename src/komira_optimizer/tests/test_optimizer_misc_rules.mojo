# =============================================================================
# test_optimizer_misc_rules.mojo -- Rule 6 (limit pushdown), Rule 14
# (sort + limit -> TopN) and Rule 22 (row-count estimate), arm by arm.
# =============================================================================
#
# Each rule is a recursive walk with one rewrite site. The rewrite tests pin
# the site (and the two guards: a RANGE with an offset is never pushed or
# fused); the walk tests put the rewrite site under every parent kind the walk
# names, so a parent arm that stops recursing leaves the site unrewritten and
# goes red. The estimate tests pin each heuristic the docstring states.
# =============================================================================

from std.memory import OwnedPointer
from std.testing import TestSuite, assert_equal, assert_true, assert_false

from komira_arrow.arrow_types import ArrowType
from komira_arrow.schema import Field, Schema, SchemaBuilder
from komira_plan_expr.agg_expr import AggExpr, AGG_COUNT
from komira_plan_expr.expr import Expr, BIN_GT
from komira_plan_expr.scalar_value import ScalarValue
from komira_plan_ir.logical_plan import (
    LogicalPlan,
    ExprArray,
    AggExprArray,
    PLAN_SCAN,
    PLAN_FILTER,
    PLAN_PROJECT,
    PLAN_AGGREGATE,
    PLAN_JOIN,
    PLAN_SORT,
    PLAN_LIMIT,
    PLAN_DISTINCT,
    PLAN_TOPN,
    JOIN_INNER,
    JOIN_SEMI,
    JOIN_ANTI,
    JOIN_CROSS,
    SOURCE_PARQUET,
)
from komira_optimizer.optimizer_misc import (
    push_limit_down,
    fuse_sort_limit,
    propagate_statistics,
    estimate_row_count,
)


# -----------------------------------------------------------------------------
# fixtures
# -----------------------------------------------------------------------------


def _schema(prefix: String) -> Schema:
    var sb = SchemaBuilder()
    sb.add_field(Field(prefix + "a", ArrowType.INT64, True))
    sb.add_field(Field(prefix + "b", ArrowType.INT64, True))
    return sb.build()


def _scan(prefix: String = "") -> LogicalPlan:
    return LogicalPlan.scan(prefix + "t.parquet", SOURCE_PARQUET, _schema(prefix))


def _strs(a: String) -> List[String]:
    var l = List[String]()
    l.append(a)
    return l^


def _bools(a: Bool) -> List[Bool]:
    var l = List[Bool]()
    l.append(a)
    return l^


def _project(var child: LogicalPlan, col: String = "a") -> LogicalPlan:
    var e = ExprArray()
    e.append(Expr.col_ref(col))
    return LogicalPlan.project(e^, child^)


def _filter(var child: LogicalPlan) -> LogicalPlan:
    return LogicalPlan.filter(
        Expr.binary(
            BIN_GT, Expr.col_ref("a"), Expr.literal(ScalarValue.from_int64(Int64(1)))
        ),
        child^,
    )


def _aggregate(var child: LogicalPlan) -> LogicalPlan:
    var gb = ExprArray()
    gb.append(Expr.col_ref("a"))
    var aggs = AggExprArray()
    var none: Optional[Expr] = None
    aggs.append(AggExpr(AGG_COUNT, none^, Optional(String("n"))))
    return LogicalPlan.aggregate(gb^, aggs^, child^)


def _sort(var child: LogicalPlan) -> LogicalPlan:
    return LogicalPlan.sort(_strs("a"), _bools(False), child^)


def _distinct(var child: LogicalPlan) -> LogicalPlan:
    var none: Optional[List[String]] = None
    return LogicalPlan.distinct(none^, child^)


def _topn(var child: LogicalPlan) -> LogicalPlan:
    return LogicalPlan.topn(_strs("a"), _bools(False), 9, child^)


def _join(var l: LogicalPlan, var r: LogicalPlan, jt: UInt8) -> LogicalPlan:
    var lk = List[String]()
    var rk = List[String]()
    if jt != JOIN_CROSS:
        lk.append("a")
        rk.append("ra")
    return LogicalPlan.join(l^, r^, lk^, rk^, jt)


# -----------------------------------------------------------------------------
# Rule 6: push_limit_down
# -----------------------------------------------------------------------------


def _limit_over_project() -> LogicalPlan:
    return LogicalPlan.limit(5, _project(_scan()))


def _limit_pushed(p: LogicalPlan) -> Bool:
    """`Project(Limit(5, Scan))`: the rewrite fired at this node."""
    if p.tag != PLAN_PROJECT:
        return False
    ref c = p._project.value()[].child[]
    return c.tag == PLAN_LIMIT and c._limit.value()[].n == 5


def test_limit_over_project_is_pushed_below_it() raises:
    # Defect: the rewrite does not fire, or the Limit loses its count.
    var out = push_limit_down(_limit_over_project())
    assert_true(_limit_pushed(out))
    ref inner = out._project.value()[].child[]
    assert_equal(Int(inner._limit.value()[].child[].tag), Int(PLAN_SCAN))
    assert_equal(out.output_schema.num_columns(), 1, "output schema unchanged")


def test_a_range_with_an_offset_is_not_pushed() raises:
    # A RANGE (offset > 0) is absorbed at the plan root; pushing it under the
    # Project would move it off the root. Defect: the offset guard removed.
    var out = push_limit_down(LogicalPlan.limit(5, _project(_scan()), 2))
    assert_equal(Int(out.tag), Int(PLAN_LIMIT))
    assert_equal(out._limit.value()[].offset, 2)


def test_limit_over_non_project_recurses_but_stays() raises:
    # Limit(Filter(Limit(Project))): the outer Limit stays (child is a
    # Filter); the inner site is rewritten through the Limit and Filter arms.
    # Defect: the Limit arm skips its child, or the Filter arm stops.
    var out = push_limit_down(LogicalPlan.limit(7, _filter(_limit_over_project())))
    assert_equal(Int(out.tag), Int(PLAN_LIMIT))
    ref f = out._limit.value()[].child[]
    assert_equal(Int(f.tag), Int(PLAN_FILTER))
    assert_true(_limit_pushed(f._filter.value()[].child[]))


def test_limit_pushdown_walks_every_parent_kind() raises:
    # Defect: one parent arm of the walk does not recurse into its child.
    var p = push_limit_down(_project(_limit_over_project()))
    assert_true(_limit_pushed(p._project.value()[].child[]), "Project arm")
    var a = push_limit_down(_aggregate(_limit_over_project()))
    assert_true(_limit_pushed(a._aggregate.value()[].child[]), "Aggregate arm")
    var s = push_limit_down(_sort(_limit_over_project()))
    assert_true(_limit_pushed(s._sort.value()[].child[]), "Sort arm")
    var d = push_limit_down(_distinct(_limit_over_project()))
    assert_true(_limit_pushed(d._distinct.value()[].child[]), "Distinct arm")
    var t = push_limit_down(_topn(_limit_over_project()))
    assert_true(_limit_pushed(t._topn.value()[].child[]), "TopN arm")
    var right = LogicalPlan.limit(5, _project(_scan("r"), "ra"))
    var j = push_limit_down(_join(_limit_over_project(), right^, JOIN_INNER))
    assert_true(_limit_pushed(j._join.value()[].left[]), "Join left")
    assert_true(_limit_pushed(j._join.value()[].right[]), "Join right")
    var sc = push_limit_down(_scan())
    assert_equal(Int(sc.tag), Int(PLAN_SCAN), "a leaf is left as is")


# -----------------------------------------------------------------------------
# Rule 14: fuse_sort_limit
# -----------------------------------------------------------------------------


def _limit_over_sort(prefix: String = "") -> LogicalPlan:
    var nf = List[Bool]()
    nf.append(True)  # an EXPLICIT NULLS FIRST, not the derived default
    var sort = LogicalPlan.sort(
        _strs(prefix + "a"), _bools(True), _scan(prefix), Optional(nf^)
    )
    return LogicalPlan.limit(4, sort^)


def _fused(p: LogicalPlan) -> Bool:
    return p.tag == PLAN_TOPN and p._topn.value()[].n == 4


def test_limit_over_sort_fuses_into_topn_keeping_placement() raises:
    # Defect: no fusion; keys / direction / count lost; or the explicit NULLS
    # FIRST dropped (a TOP-N then returns a different SET of rows).
    var out = fuse_sort_limit(_limit_over_sort())
    assert_true(_fused(out))
    ref td = out._topn.value()[]
    assert_equal(len(td.keys), 1)
    assert_equal(td.keys[0], "a")
    assert_true(td.descending[0])
    assert_equal(len(td.nulls_first), 1)
    assert_true(td.nulls_first[0], "explicit NULLS FIRST must survive")
    assert_equal(Int(td.child[].tag), Int(PLAN_SCAN))


def test_a_range_over_sort_is_not_fused() raises:
    # TopN carries no offset. Defect: the offset guard removed (the window
    # silently drops its offset).
    var sort = LogicalPlan.sort(_strs("a"), _bools(True), _scan())
    var out = fuse_sort_limit(LogicalPlan.limit(4, sort^, 3))
    assert_equal(Int(out.tag), Int(PLAN_LIMIT))
    assert_equal(Int(out._limit.value()[].child[].tag), Int(PLAN_SORT))


def test_limit_over_non_sort_recurses_but_stays() raises:
    # Defect: the Limit arm does not recurse into a non-Sort child.
    var out = fuse_sort_limit(LogicalPlan.limit(8, _filter(_limit_over_sort())))
    assert_equal(Int(out.tag), Int(PLAN_LIMIT))
    ref f = out._limit.value()[].child[]
    assert_true(_fused(f._filter.value()[].child[]))


def test_sort_limit_fusion_walks_every_parent_kind() raises:
    # Defect: one parent arm of the walk does not recurse into its child.
    var p = fuse_sort_limit(_project(_limit_over_sort()))
    assert_true(_fused(p._project.value()[].child[]), "Project arm")
    var a = fuse_sort_limit(_aggregate(_limit_over_sort()))
    assert_true(_fused(a._aggregate.value()[].child[]), "Aggregate arm")
    var s = fuse_sort_limit(_sort(_limit_over_sort()))
    assert_true(_fused(s._sort.value()[].child[]), "Sort arm")
    var d = fuse_sort_limit(_distinct(_limit_over_sort()))
    assert_true(_fused(d._distinct.value()[].child[]), "Distinct arm")
    var t = fuse_sort_limit(_topn(_limit_over_sort()))
    assert_true(_fused(t._topn.value()[].child[]), "TopN arm")
    var j = fuse_sort_limit(_join(_scan(), _limit_over_sort("r"), JOIN_INNER))
    assert_true(_fused(j._join.value()[].right[]), "Join right")
    var j2 = fuse_sort_limit(_join(_limit_over_sort(), _scan("r"), JOIN_INNER))
    assert_true(_fused(j2._join.value()[].left[]), "Join left")
    var sc = fuse_sort_limit(_scan())
    assert_equal(Int(sc.tag), Int(PLAN_SCAN))


# -----------------------------------------------------------------------------
# Rule 22: estimate_row_count / propagate_statistics
# -----------------------------------------------------------------------------


def test_estimate_scan_filter_project_aggregate_sort_distinct() raises:
    # The stated heuristics. Defect: a factor changed, or an arm that does not
    # recurse (it would answer the 1,000,000 default instead).
    assert_equal(estimate_row_count(_scan()), 1_000_000)
    assert_equal(estimate_row_count(_filter(_scan())), 500_000)
    assert_equal(estimate_row_count(_project(_filter(_scan()))), 500_000)
    assert_equal(estimate_row_count(_aggregate(_scan())), 100_000)
    assert_equal(estimate_row_count(_sort(_filter(_scan()))), 500_000)
    assert_equal(estimate_row_count(_distinct(_scan())), 500_000)


def test_estimate_floors_at_one_row() raises:
    # Filter / Aggregate / Distinct over one row must not estimate 0. Defect:
    # the `max(.., 1)` floor removed.
    var one = LogicalPlan.limit(1, _scan())
    assert_equal(estimate_row_count(_filter(one^)), 1)
    var one2 = LogicalPlan.limit(1, _scan())
    assert_equal(estimate_row_count(_aggregate(one2^)), 1)
    var one3 = LogicalPlan.limit(1, _scan())
    assert_equal(estimate_row_count(_distinct(one3^)), 1)


def test_estimate_joins_by_type() raises:
    # INNER: product capped at 1e9, times 0.3; CROSS: the full product;
    # SEMI / ANTI: half the left. Defect: a join type routed to the wrong arm,
    # or the cap removed.
    assert_equal(
        estimate_row_count(_join(_scan(), _scan("r"), JOIN_INNER)), 300_000_000
    )
    assert_equal(
        estimate_row_count(_join(_scan(), _scan("r"), JOIN_CROSS)),
        1_000_000_000_000,
    )
    assert_equal(estimate_row_count(_join(_scan(), _scan("r"), JOIN_SEMI)), 500_000)
    assert_equal(estimate_row_count(_join(_scan(), _scan("r"), JOIN_ANTI)), 500_000)
    # Under the cap: 100 x 30 = 3,000 -> 900.
    var l = LogicalPlan.limit(100, _scan())
    var r = LogicalPlan.limit(30, _scan("r"))
    assert_equal(estimate_row_count(_join(l^, r^, JOIN_INNER)), 900)


def test_estimate_limit_respects_offset_and_count() raises:
    # rows [offset, offset + n): Defect: offset ignored, or a negative count.
    assert_equal(estimate_row_count(LogicalPlan.limit(10, _scan())), 10)
    var inner = LogicalPlan.limit(50, _scan())
    assert_equal(estimate_row_count(LogicalPlan.limit(100, inner^, 20)), 30)
    var inner2 = LogicalPlan.limit(5, _scan())
    assert_equal(estimate_row_count(LogicalPlan.limit(100, inner2^, 20)), 0)


def test_estimate_topn_is_min_of_n_and_child() raises:
    # Defect: TopN answers n regardless of a smaller child, or the child.
    assert_equal(estimate_row_count(_topn(_scan())), 9)
    var small = LogicalPlan.limit(3, _scan())
    assert_equal(estimate_row_count(_topn(small^)), 3)


def test_estimate_unlisted_node_is_the_default() raises:
    # A node the estimator does not list (a UNION) answers the default.
    # Defect: the fall-through returns 0 or raises.
    var kids = List[OwnedPointer[LogicalPlan]]()
    kids.append(OwnedPointer(_scan()))
    kids.append(OwnedPointer(_scan()))
    var u = LogicalPlan.union(kids^, _schema(""))
    assert_equal(estimate_row_count(u), 1_000_000)


def test_propagate_statistics_leaves_the_plan_unchanged() raises:
    # An annotation pass. Defect: it rebuilds or drops nodes.
    var out = propagate_statistics(_project(_filter(_scan())))
    assert_equal(Int(out.tag), Int(PLAN_PROJECT))
    assert_equal(Int(out._project.value()[].child[].tag), Int(PLAN_FILTER))


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
