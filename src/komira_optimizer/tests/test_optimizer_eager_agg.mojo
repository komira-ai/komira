# =============================================================================
# Tests for cross-side eager aggregation pushdown (optimizer_eager_agg)
# =============================================================================
#
# SLICE 1 (INNER) and SLICE 2 (LEFT join, push onto the right side). Covers:
#   1. The cross-side rewrite FIRES on the star-schema shape (group by the
#      dimension attribute, aggregate the fact measure) and produces
#      Aggregate(Join(Aggregate(fact), dim)) with the partial agg pushed
#      onto the fact side.
#   2. Push-to-right symmetry.
#   3. Decline paths: LEFT join with the agg input on the preserved (left)
#      side, agg input spanning both sides, non-whitelisted aggregate
#      (MEAN), and the cost gate (small fact side).
#   4. SLICE 2: the q13-shape LEFT-join COUNT pushed right, the preserved-
#      side decline, a peeled narrowing Project, and a large fact side that
#      passes the cost gate.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_true, assert_false

from komira_arrow.arrow_types import ArrowType
from komira_arrow.schema import Field, Schema, SchemaBuilder
from komira_plan_expr.agg_expr import (
    AggExpr,
    sum as agg_sum,
    count as agg_count,
    min as agg_min,
    max as agg_max,
    mean as agg_mean,
)
from komira_plan_expr.col_expr import col
from komira_plan_expr.expr import Expr
from komira_plan_ir.logical_plan import (
    AggExprArray,
    ExprArray,
    LogicalPlan,
    SOURCE_PARQUET,
    PLAN_SCAN,
    PLAN_AGGREGATE,
    PLAN_JOIN,
    JOIN_INNER,
    JOIN_LEFT,
)
from komira_optimizer.optimizer_eager_agg import (
    eager_aggregate_pushdown,
    _classify_eager_push,
    _EAGER_NONE,
    _EAGER_LEFT,
    _EAGER_RIGHT,
)


# =============================================================================
# Schema builders — a star-schema fact/dim pair
# =============================================================================


def _fact_schema() raises -> Schema:
    """fact: fk_id, measure (the many side)."""
    var sb = SchemaBuilder()
    sb.add_field(Field("fk_id", ArrowType.INT64, False))
    sb.add_field(Field("measure", ArrowType.INT64, False))
    return sb.build()


def _dim_schema() raises -> Schema:
    """dim: dim_id (PK), dim_attr (the group-by attribute)."""
    var sb = SchemaBuilder()
    sb.add_field(Field("dim_id", ArrowType.INT64, False))
    sb.add_field(Field("dim_attr", ArrowType.INT64, False))
    return sb.build()


def _str1(a: String) -> List[String]:
    var out = List[String]()
    out.append(a)
    return out^


def _scan_fact(row_count: Optional[Int] = None) raises -> LogicalPlan:
    return LogicalPlan.scan(
        String("fact.parquet"), SOURCE_PARQUET, _fact_schema(),
        row_count=row_count,
    )


def _scan_dim(row_count: Optional[Int] = None) raises -> LogicalPlan:
    return LogicalPlan.scan(
        String("dim.parquet"), SOURCE_PARQUET, _dim_schema(),
        row_count=row_count,
    )


# Aggregate(group_by=[dim_attr], SUM(measure))  over  Join(fact, dim, INNER).
# Agg input `measure` is on the fact side; group key `dim_attr` on the dim
# side — the cross-side shape the same-side pass CANNOT handle.
def _star_join_fact_left(
    fact_rows: Optional[Int] = None, dim_rows: Optional[Int] = None
) raises -> LogicalPlan:
    var join = LogicalPlan.join(
        _scan_fact(fact_rows),
        _scan_dim(dim_rows),
        _str1("fk_id"),
        _str1("dim_id"),
        JOIN_INNER,
    )
    var gb = ExprArray()
    gb.append(col("dim_attr").copy_expr())
    var aggs = AggExprArray()
    aggs.append(agg_sum(col("measure")).alias("total"))
    return LogicalPlan.aggregate(gb^, aggs^, join^)


# =============================================================================
# 1. Cross-side fire + shape
# =============================================================================


def test_cross_side_inner_fires_push_left() raises:
    """Fact on LEFT, agg input on fact => push a partial aggregate onto the
    left (fact) child. Result: Aggregate(Join(Aggregate(fact), dim))."""
    var plan = _star_join_fact_left()
    var rewritten = eager_aggregate_pushdown(plan^)

    assert_equal(Int(rewritten.tag), Int(PLAN_AGGREGATE), "top must stay Aggregate")
    ref join_node = rewritten._aggregate.value()[].child[]
    assert_equal(Int(join_node.tag), Int(PLAN_JOIN), "child must be Join")
    var left_tag = join_node._join.value()[].left[].tag
    var right_tag = join_node._join.value()[].right[].tag
    assert_equal(
        Int(left_tag), Int(PLAN_AGGREGATE),
        "partial Aggregate must be pushed onto the LEFT (fact) side",
    )
    assert_equal(
        Int(right_tag), Int(PLAN_SCAN),
        "dim side must remain a Scan (no partial agg)",
    )
    # The partial aggregate groups by the fact join key fk_id.
    ref partial = join_node._join.value()[].left[]
    assert_equal(
        len(partial._aggregate.value()[].group_by), 1,
        "partial group-by = [fk_id]",
    )
    print("test_cross_side_inner_fires_push_left OK")


def test_cross_side_inner_fires_push_right() raises:
    """Fact on RIGHT => push the partial aggregate onto the right child."""
    var join = LogicalPlan.join(
        _scan_dim(),
        _scan_fact(),
        _str1("dim_id"),
        _str1("fk_id"),
        JOIN_INNER,
    )
    var gb = ExprArray()
    gb.append(col("dim_attr").copy_expr())
    var aggs = AggExprArray()
    aggs.append(agg_sum(col("measure")).alias("total"))
    var plan = LogicalPlan.aggregate(gb^, aggs^, join^)

    var rewritten = eager_aggregate_pushdown(plan^)
    assert_equal(Int(rewritten.tag), Int(PLAN_AGGREGATE), "top Aggregate")
    ref join_node = rewritten._aggregate.value()[].child[]
    assert_equal(Int(join_node.tag), Int(PLAN_JOIN), "child Join")
    var right_tag = join_node._join.value()[].right[].tag
    var left_tag = join_node._join.value()[].left[].tag
    assert_equal(
        Int(right_tag), Int(PLAN_AGGREGATE),
        "partial Aggregate must be pushed onto the RIGHT (fact) side",
    )
    assert_equal(Int(left_tag), Int(PLAN_SCAN), "dim side stays Scan")
    print("test_cross_side_inner_fires_push_right OK")


# =============================================================================
# 2. Decline paths
# =============================================================================


def test_left_join_declines_slice1() raises:
    """A LEFT join whose agg input is on the LEFT (preserved) side declines:
    on a LEFT join the pass pushes onto the right (null-producing) side only."""
    var join = LogicalPlan.join(
        _scan_fact(),
        _scan_dim(),
        _str1("fk_id"),
        _str1("dim_id"),
        JOIN_LEFT,
    )
    var gb = ExprArray()
    gb.append(col("dim_attr").copy_expr())
    var aggs = AggExprArray()
    aggs.append(agg_sum(col("measure")).alias("total"))
    var plan = LogicalPlan.aggregate(gb^, aggs^, join^)
    ref join_ref = plan._aggregate.value()[].child[]
    var d = _classify_eager_push(plan, join_ref)
    assert_equal(Int(d.kind), Int(_EAGER_NONE), "LEFT join must decline in slice 1")
    print("test_left_join_declines_slice1 OK")


def test_agg_input_spans_both_declines() raises:
    """An aggregate whose inputs span both sides cannot be pushed."""
    var join = LogicalPlan.join(
        _scan_fact(),
        _scan_dim(),
        _str1("fk_id"),
        _str1("dim_id"),
        JOIN_INNER,
    )
    var gb = ExprArray()
    gb.append(col("dim_attr").copy_expr())
    var aggs = AggExprArray()
    aggs.append(agg_sum(col("measure")).alias("total"))  # fact side
    aggs.append(agg_min(col("dim_attr")).alias("mn"))    # dim side
    var plan = LogicalPlan.aggregate(gb^, aggs^, join^)
    ref join_ref = plan._aggregate.value()[].child[]
    var d = _classify_eager_push(plan, join_ref)
    assert_equal(Int(d.kind), Int(_EAGER_NONE), "spanning agg inputs must decline")
    print("test_agg_input_spans_both_declines OK")


def test_mean_not_whitelisted_declines() raises:
    """MEAN is excluded (two-phase merge not implemented in this pass)."""
    var join = LogicalPlan.join(
        _scan_fact(),
        _scan_dim(),
        _str1("fk_id"),
        _str1("dim_id"),
        JOIN_INNER,
    )
    var gb = ExprArray()
    gb.append(col("dim_attr").copy_expr())
    var aggs = AggExprArray()
    aggs.append(agg_mean(col("measure")).alias("avg_measure"))
    var plan = LogicalPlan.aggregate(gb^, aggs^, join^)
    ref join_ref = plan._aggregate.value()[].child[]
    var d = _classify_eager_push(plan, join_ref)
    assert_equal(Int(d.kind), Int(_EAGER_NONE), "MEAN must decline")
    print("test_mean_not_whitelisted_declines OK")


def test_small_fact_declines_cost_gate() raises:
    """Cost gate: a fact side below EAGER_MIN_S_ROWS is not worth an agg
    pass — the pre-agg overhead dominates."""
    var plan = _star_join_fact_left(fact_rows=Optional[Int](1000))
    ref join_ref = plan._aggregate.value()[].child[]
    var d = _classify_eager_push(plan, join_ref)
    assert_equal(
        Int(d.kind), Int(_EAGER_NONE),
        "small fact side must decline the cost gate",
    )
    print("test_small_fact_declines_cost_gate OK")


# =============================================================================
# 3. SLICE 2 — LEFT-join count (q13 shape) + project peeling
# =============================================================================


def test_left_join_count_fires_push_right() raises:
    """q13 shape: dim LEFT JOIN fact, group by the dim (preserved) join key,
    count(fact col). Agg input is on the RIGHT (null-producing) side -> push
    a partial COUNT onto the right; the merge coalesces unmatched NULL -> 0."""
    var join = LogicalPlan.join(
        _scan_dim(Optional[Int](150_000)),   # preserved (left)
        _scan_fact(Optional[Int](1_500_000)),  # aggregated (right)
        _str1("dim_id"),
        _str1("fk_id"),
        JOIN_LEFT,
    )
    var gb = ExprArray()
    gb.append(col("dim_id").copy_expr())     # group by the left/preserved key
    var aggs = AggExprArray()
    aggs.append(agg_count(col("measure")).alias("cnt"))  # measure on the right
    var plan = LogicalPlan.aggregate(gb^, aggs^, join^)

    var rewritten = eager_aggregate_pushdown(plan^)
    assert_equal(Int(rewritten.tag), Int(PLAN_AGGREGATE), "top Aggregate")
    ref join_node = rewritten._aggregate.value()[].child[]
    assert_equal(Int(join_node.tag), Int(PLAN_JOIN), "child Join")
    assert_equal(
        Int(join_node._join.value()[].right[].tag), Int(PLAN_AGGREGATE),
        "partial COUNT pushed onto the right (fact) side",
    )
    print("test_left_join_count_fires_push_right OK")


def test_left_join_push_left_declines() raises:
    """LEFT join with agg input on the LEFT (preserved) side is out of scope
    (preserved-side push has subtler merge semantics)."""
    var plan = _star_join_fact_left(
        fact_rows=Optional[Int](1_500_000),
        dim_rows=Optional[Int](150_000),
    )
    # rebuild as LEFT (fact is left, agg input measure on fact/left).
    var join = LogicalPlan.join(
        _scan_fact(Optional[Int](1_500_000)),
        _scan_dim(Optional[Int](150_000)),
        _str1("fk_id"),
        _str1("dim_id"),
        JOIN_LEFT,
    )
    var gb = ExprArray()
    gb.append(col("dim_attr").copy_expr())
    var aggs = AggExprArray()
    aggs.append(agg_sum(col("measure")).alias("total"))
    var p2 = LogicalPlan.aggregate(gb^, aggs^, join^)
    ref join_ref = p2._aggregate.value()[].child[]
    var d = _classify_eager_push(p2, join_ref)
    assert_equal(
        Int(d.kind), Int(_EAGER_NONE),
        "LEFT join push-to-left (preserved side) must decline",
    )
    _ = plan^
    print("test_left_join_push_left_declines OK")


def test_project_peel_inner_fires() raises:
    """A pure column-narrowing Project between the Aggregate and the Join is
    peeled so the transform still fires (a column-pruning pass, not in this
    tree, is designed to insert this Project below the aggregate)."""
    var join = LogicalPlan.join(
        _scan_fact(Optional[Int](1_500_000)),
        _scan_dim(Optional[Int](150_000)),
        _str1("fk_id"),
        _str1("dim_id"),
        JOIN_INNER,
    )
    # Narrowing project: keep only fk_id, measure, dim_attr (plain col-refs).
    var pexprs = ExprArray()
    pexprs.append(col("fk_id").copy_expr())
    pexprs.append(col("measure").copy_expr())
    pexprs.append(col("dim_attr").copy_expr())
    var proj = LogicalPlan.project(pexprs^, join^)
    var gb = ExprArray()
    gb.append(col("dim_attr").copy_expr())
    var aggs = AggExprArray()
    aggs.append(agg_sum(col("measure")).alias("total"))
    var plan = LogicalPlan.aggregate(gb^, aggs^, proj^)

    var rewritten = eager_aggregate_pushdown(plan^)
    assert_equal(Int(rewritten.tag), Int(PLAN_AGGREGATE), "top Aggregate")
    ref child = rewritten._aggregate.value()[].child[]
    # After peeling, the merge aggregate sits directly over the rewritten
    # Join (the narrowing Project is dropped).
    assert_equal(
        Int(child.tag), Int(PLAN_JOIN),
        "peeled: merge Aggregate is directly over the Join",
    )
    assert_equal(
        Int(child._join.value()[].left[].tag), Int(PLAN_AGGREGATE),
        "partial Aggregate pushed onto the fact (left) side",
    )
    print("test_project_peel_inner_fires OK")


def test_large_fact_fires_cost_gate() raises:
    """Cost gate: a large fact side with an unfiltered (full-cover) dim
    side fires."""
    var plan = _star_join_fact_left(
        fact_rows=Optional[Int](1_500_000),
        dim_rows=Optional[Int](150_000),
    )
    ref join_ref = plan._aggregate.value()[].child[]
    var d = _classify_eager_push(plan, join_ref)
    assert_equal(
        Int(d.kind), Int(_EAGER_LEFT),
        "large fact + full-cover dim must fire (push left)",
    )
    print("test_large_fact_fires_cost_gate OK")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
