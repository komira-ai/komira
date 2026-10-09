# =============================================================================
# test_optimizer_agg_cse.mojo -- the q15 float-determinism fold, tested at the
# mechanism level.
#
# THE PROBLEM
# ===========
# TPC-H q15's `WHERE total_revenue = (SELECT max(total_revenue) FROM
# revenue_view)` decorrelates (scalar_subquery_decorrelate) into a CROSS join
# whose BOTH sides read the SAME `Aggregate(sum(l_disc_price) GROUP BY
# l_suppkey)` subtree. A PLAN_CSE_REF is a DAG edge a plan walked as a tree
# cannot follow, so a tree-walked plan computes the aggregate TWICE,
# independently. Two parallel work-stealing float-sum reductions are
# non-deterministic, so the two per-group sums can differ by ~1 ULP and the
# exact `=` can miss (q15 then returns 0 rows; DuckDB, materializing the CTE
# once, always returns the top supplier).
#
# THE FIX (`komira_optimizer.optimizer_agg_cse`)
# finds a duplicated AGGREGATE subtree and replaces every occurrence with an
# `InMemorySource` scan leaf sharing one materialized source, so both
# consumers read bit-identical values. This test exercises the three pure
# fold helpers directly (deterministic; no data files, nothing executed):
#   * collect_agg_subtree_hashes finds the duplicated aggregate (count == 2),
#   * find_agg_subtree_by_hash returns the shared aggregate,
#   * replace_agg_subtree_with_source folds BOTH occurrences to scan leaves
#     (post-fold the aggregate hash appears ZERO times).
# Catches a missing fold: without it the two aggregate subtrees survive
# (count stays 2).
# =============================================================================

from std.collections import Dict, Optional
from std.testing import TestSuite, assert_equal, assert_true, assert_false

from komira_arrow.arrow_types import ArrowType
from komira_arrow.column import Column
from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.schema import (
    Field,
    RecordBatch,
    RecordBatchBuilder,
    Schema,
    SchemaBuilder,
)
from komira_plan_expr.agg_expr import AggExpr, AGG_SUM, AGG_MAX
from komira_plan_expr.expr import Expr
from komira_plan_ir.logical_plan import (
    LogicalPlan,
    ExprArray,
    AggExprArray,
    JOIN_CROSS,
    PLAN_AGGREGATE,
    PLAN_JOIN,
    PLAN_SCAN,
    SOURCE_PARQUET,
)
from komira_scan_source.in_memory_source import InMemorySource

from komira_optimizer.optimizer_agg_cse import (
    collect_agg_subtree_hashes,
    find_agg_subtree_by_hash,
    replace_agg_subtree_with_source,
)


# -----------------------------------------------------------------------------
# fixtures
# -----------------------------------------------------------------------------


def _rv_agg_over_scan() -> LogicalPlan:
    """`Aggregate(sum(value) GROUP BY key, Scan(parquet))` -- the q15
    `revenue_view` shape (FLOAT64 aggregand, the class that is non-deterministic
    under parallel reduction)."""
    var sb = SchemaBuilder()
    sb.add_field(Field("key", ArrowType.INT64, False))
    sb.add_field(Field("value", ArrowType.FLOAT64, False))
    var scan = LogicalPlan.scan("lineitem.parquet", SOURCE_PARQUET, sb.build())
    var gb = ExprArray()
    gb.append(Expr.col_ref("key"))
    var child_expr: Optional[Expr] = Optional(Expr.col_ref("value"))
    var aggs = AggExprArray()
    aggs.append(AggExpr(AGG_SUM, child_expr^, Optional(String("total"))))
    return LogicalPlan.aggregate(gb^, aggs^, scan^)


def _cross_of_two_rv() -> LogicalPlan:
    """`CROSS(RV, RV)` -- two structurally-identical aggregate subtrees, a
    reduced form of the q15 CROSS from `scalar_subquery_decorrelate` (there
    the right side is `max` over RV)."""
    var a = _rv_agg_over_scan()
    var b = _rv_agg_over_scan()
    var lk = List[String]()
    var rk = List[String]()
    return LogicalPlan.join(a^, b^, lk^, rk^, JOIN_CROSS)


def _ungrouped_max_over_scan() -> LogicalPlan:
    """`Aggregate([], [max(value)], Scan)` -- an UNGROUPED aggregate (a 1-row
    global reduction; the deterministic scalar-subquery / cross-broadcast shape
    that must NOT be folded -- see the module SCOPE note and its nested-cross
    shape)."""
    var sb = SchemaBuilder()
    sb.add_field(Field("key", ArrowType.INT64, False))
    sb.add_field(Field("value", ArrowType.FLOAT64, False))
    var scan = LogicalPlan.scan("lineitem.parquet", SOURCE_PARQUET, sb.build())
    var gb = ExprArray()  # EMPTY group-by -> ungrouped
    var child_expr: Optional[Expr] = Optional(Expr.col_ref("value"))
    var aggs = AggExprArray()
    aggs.append(AggExpr(AGG_MAX, child_expr^, Optional(String("m"))))
    return LogicalPlan.aggregate(gb^, aggs^, scan^)


def _dummy_materialized_source() raises -> InMemorySource:
    """A stand-in for the ONE-time materialization of `revenue_view` -- a
    single (key, total) row with the aggregate's output schema."""
    var kb = PrimitiveArray[DType.int64].allocate(1)
    var tb = PrimitiveArray[DType.float64].allocate(1)
    kb._typed_ptr_mut()[0] = Scalar[DType.int64](2)
    tb._typed_ptr_mut()[0] = Scalar[DType.float64](50.0)
    var sb = SchemaBuilder()
    sb.add_field(Field("key", ArrowType.INT64, False))
    sb.add_field(Field("total", ArrowType.FLOAT64, False))
    var bb = RecordBatchBuilder()
    bb.add_column(Column.from_primitive[DType.int64](kb^))
    bb.add_column(Column.from_primitive[DType.float64](tb^))
    var batch = bb.build(sb.build())
    return InMemorySource.from_record_batch(
        batch^, Optional[String](String("__test_agg_cse"))
    )


# -----------------------------------------------------------------------------
# tests
# -----------------------------------------------------------------------------


def test_collect_finds_duplicate_aggregate() raises:
    """The two identical RV aggregate subtrees hash equal and are counted twice
    -- a count of 2 is what makes a subtree a duplicate. Catches a collector
    that misses one occurrence."""
    var a = _rv_agg_over_scan()
    var b = _rv_agg_over_scan()
    var h = a.structural_hash()
    # Same shape over the same source -> same structural hash.
    assert_equal(h, b.structural_hash())
    _ = a^
    _ = b^

    var plan = _cross_of_two_rv()
    var counts = Dict[UInt64, Int]()
    collect_agg_subtree_hashes(plan, counts)
    assert_true(h in counts)
    assert_equal(counts[h], 2)


def test_find_returns_the_shared_aggregate() raises:
    """find_agg_subtree_by_hash returns a copy of the duplicated aggregate
    subtree (an Aggregate with the target hash)."""
    var probe = _rv_agg_over_scan()
    var h = probe.structural_hash()
    _ = probe^

    var plan = _cross_of_two_rv()
    var found = find_agg_subtree_by_hash(plan, h)
    assert_true(Bool(found))
    assert_equal(Int(found.value().tag), Int(PLAN_AGGREGATE))
    assert_equal(found.value().structural_hash(), h)


def test_replace_folds_both_occurrences_to_scan() raises:
    """After the fold, the duplicated aggregate hash appears ZERO times and both
    CROSS children are scan leaves. Leaves over one source are what make the
    two compared values bit-identical. Catches a replace that leaves the
    aggregate on either side."""
    var probe = _rv_agg_over_scan()
    var h = probe.structural_hash()
    _ = probe^

    var src = _dummy_materialized_source()
    var plan = _cross_of_two_rv()
    var folded = replace_agg_subtree_with_source(plan^, h, src)

    var counts = Dict[UInt64, Int]()
    collect_agg_subtree_hashes(folded, counts)
    var remaining = 0
    if h in counts:
        remaining = counts[h]
    assert_equal(remaining, 0)

    assert_equal(Int(folded.tag), Int(PLAN_JOIN))
    assert_equal(Int(folded._join.value()[].left[].tag), Int(PLAN_SCAN))
    assert_equal(Int(folded._join.value()[].right[].tag), Int(PLAN_SCAN))


def test_ungrouped_aggregate_is_not_folded() raises:
    """An UNGROUPED aggregate (empty GROUP BY) is NOT a fold candidate even when
    duplicated -- it is a deterministic global reduction / cross-broadcast side,
    and folding it changes which side of the CROSS is the leaf side (the
    nested-cross shape). The collector must report ZERO grouped-aggregate duplicates."""
    var a = _ungrouped_max_over_scan()
    var b = _ungrouped_max_over_scan()
    var h = a.structural_hash()
    assert_equal(h, b.structural_hash())
    var lk = List[String]()
    var rk = List[String]()
    var plan = LogicalPlan.join(a^, b^, lk^, rk^, JOIN_CROSS)

    var counts = Dict[UInt64, Int]()
    collect_agg_subtree_hashes(plan, counts)
    # The ungrouped-max hash must NOT be collected (grouped-only fold target).
    var seen = 0
    if h in counts:
        seen = counts[h]
    assert_equal(seen, 0)
    # And find returns None for it (nothing to fold).
    var found = find_agg_subtree_by_hash(plan, h)
    assert_false(Bool(found))


def test_no_duplicate_is_a_noop() raises:
    """A single aggregate (no duplication) is NOT a fold candidate: the
    collector reports count 1, below the duplicate threshold of 2."""
    var a = _rv_agg_over_scan()
    var h = a.structural_hash()
    var counts = Dict[UInt64, Int]()
    collect_agg_subtree_hashes(a, counts)
    assert_true(h in counts)
    assert_equal(counts[h], 1)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
