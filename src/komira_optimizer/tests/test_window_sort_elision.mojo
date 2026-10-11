# =============================================================================
# Tests for Pattern C of `optimize_window_rewrite` -- redundant post-window
# Sort elision.
# =============================================================================
#
# Pattern C drops a `Sort(keys=K, desc=A)` directly above a
# `PartitionBy(pkeys=P, okeys=O, desc=D)` when K is a PREFIX of (P ++ O)
# and A matches the implied direction list (P keys are always ASC inside
# the engine sink; O keys use D directly).
#
# A running or rolling window query ending with `.sort_multi(["user_id",
# "ts"], [False, False])` after `.over(["user_id"], ["ts"])` sorts rows that
# are already in that order. This rule removes that redundant sort.
#
# Negative cases:
#   - Sort key NOT a prefix of (P ++ O): preserved.
#   - Direction mismatch: preserved.
#   - NULL placement other than the sink's derived one: preserved.
#   - Sort longer than (P ++ O): preserved.
#   - Sort directly above PartitionBy with empty pkeys/okeys: preserved
#     (the engine skips its internal sort in that case, so output order
#     is not guaranteed).
#
# Run: a welded test of komira_optimizer (BUCK test_srcs).
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_true, assert_false

from komira_arrow.schema import Schema, SchemaBuilder, Field
from komira_arrow.arrow_types import ArrowType

from komira_plan_ir.logical_plan import (
    LogicalPlan,
    PLAN_SORT,
    PLAN_PARTITION_BY,
)
from komira_plan_expr.partition_expr import (
    PartitionExpr,
)

from komira_optimizer.optimizer_window_rewrite import optimize_window_rewrite


# =============================================================================
# Helpers
# =============================================================================

def _scan_plan(var schema: Schema) raises -> LogicalPlan:
    """Construct an in-memory scan LogicalPlan for plan-shape tests."""
    return LogicalPlan.scan(
        String("__test"),
        UInt8(3),  # SOURCE_IN_MEMORY
        schema^,
    )


def _three_col_schema() -> Schema:
    """user_id Int64, ts Int64, value Float64 — a running-window shape."""
    var sb = SchemaBuilder()
    sb.add_field(Field("user_id", ArrowType.INT64, False))
    sb.add_field(Field("ts", ArrowType.INT64, False))
    sb.add_field(Field("value", ArrowType.FLOAT64, False))
    return sb.build()


def _build_running_total_pb(var child: LogicalPlan) raises -> LogicalPlan:
    """PartitionBy(pkeys=[user_id], okeys=[ts], desc=[False],
    pexprs=[sum(value) AS running_total])."""
    var pkeys: List[String] = ["user_id"]
    var okeys: List[String] = ["ts"]
    var desc: List[Bool] = [False]
    var pexprs = List[PartitionExpr]()
    pexprs.append(
        PartitionExpr.running_sum(String("value")).with_alias(String("running_total"))
    )
    return LogicalPlan.partition_by(
        pkeys^, okeys^, desc^, pexprs^, child^,
    )


def _count_sort(plan: LogicalPlan) -> Int:
    """Recursively count Sort nodes in the plan tree."""
    var count: Int = 0
    if plan.tag == PLAN_SORT:
        count = 1 + _count_sort(plan.sort_data_ref().child[])
    elif plan.tag == PLAN_PARTITION_BY:
        count = _count_sort(plan.partition_by_data_ref().child[])
    return count


def _count_partition_by(plan: LogicalPlan) -> Int:
    """Recursively count PartitionBy nodes in the plan tree."""
    var count: Int = 0
    if plan.tag == PLAN_PARTITION_BY:
        count = 1 + _count_partition_by(plan.partition_by_data_ref().child[])
    elif plan.tag == PLAN_SORT:
        count = _count_partition_by(plan.sort_data_ref().child[])
    return count


# =============================================================================
# Section 1 -- Positive cases (Sort elided)
# =============================================================================

def test_exact_prefix_match_elides_sort() raises:
    """Sort by exactly (user_id, ts) ASC over PartitionBy(pkeys=[user_id],
    okeys=[ts]) — keys+directions match; Sort dropped.

    This is the running / rolling window shape after the
    DataFrame-level `.with_column(window).sort_multi(...)` lowering.
    """
    var schema = _three_col_schema()
    var child = _scan_plan(schema^)
    var pb = _build_running_total_pb(child^)

    var sort_keys: List[String] = ["user_id", "ts"]
    var sort_desc: List[Bool] = [False, False]
    var plan = LogicalPlan.sort(sort_keys^, sort_desc^, pb^)

    # Pre: 1 Sort + 1 PartitionBy.
    assert_equal(_count_sort(plan), 1)
    assert_equal(_count_partition_by(plan), 1)

    var rewritten = optimize_window_rewrite(plan^)

    # Post: 0 Sort, 1 PartitionBy. Top should be PartitionBy now.
    assert_equal(_count_sort(rewritten), 0)
    assert_equal(_count_partition_by(rewritten), 1)
    assert_equal(Int(rewritten.tag), Int(PLAN_PARTITION_BY))


def test_strict_prefix_match_elides_sort() raises:
    """Sort by (user_id) ASC over PartitionBy(pkeys=[user_id], okeys=[ts]).
    K=[user_id] is a strict prefix of (P++O)=[user_id, ts]; the
    PartitionBy's internal sort is strictly more specific (ties broken by
    ts ASC), so dropping the user-level Sort is safe."""
    var schema = _three_col_schema()
    var child = _scan_plan(schema^)
    var pb = _build_running_total_pb(child^)

    var sort_keys: List[String] = ["user_id"]
    var sort_desc: List[Bool] = [False]
    var plan = LogicalPlan.sort(sort_keys^, sort_desc^, pb^)

    var rewritten = optimize_window_rewrite(plan^)
    assert_equal(_count_sort(rewritten), 0)
    assert_equal(Int(rewritten.tag), Int(PLAN_PARTITION_BY))


def test_descending_okey_matches_sort_desc_elides() raises:
    """PartitionBy with okeys=[ts] DESC + Sort by (user_id ASC, ts DESC).
    Implied directions [False, True] match Sort directions [False, True];
    Sort dropped."""
    var schema = _three_col_schema()
    var child = _scan_plan(schema^)
    var pkeys: List[String] = ["user_id"]
    var okeys: List[String] = ["ts"]
    var pb_desc: List[Bool] = [True]  # ORDER BY ts DESC
    var pexprs = List[PartitionExpr]()
    pexprs.append(
        PartitionExpr.running_sum(String("value")).with_alias(String("rt"))
    )
    var pb = LogicalPlan.partition_by(
        pkeys^, okeys^, pb_desc^, pexprs^, child^,
    )

    var sort_keys: List[String] = ["user_id", "ts"]
    var sort_desc: List[Bool] = [False, True]
    var plan = LogicalPlan.sort(sort_keys^, sort_desc^, pb^)

    var rewritten = optimize_window_rewrite(plan^)
    assert_equal(_count_sort(rewritten), 0)
    assert_equal(Int(rewritten.tag), Int(PLAN_PARTITION_BY))


# =============================================================================
# Section 2 -- Negative cases (Sort preserved)
# =============================================================================

def test_sort_key_not_in_partition_by_order_preserved() raises:
    """Sort by a column that's NOT in (P ++ O) — Sort preserved."""
    var schema = _three_col_schema()
    var child = _scan_plan(schema^)
    var pb = _build_running_total_pb(child^)

    # Sort by `value` — not in (P++O) = (user_id, ts).
    var sort_keys: List[String] = ["value"]
    var sort_desc: List[Bool] = [False]
    var plan = LogicalPlan.sort(sort_keys^, sort_desc^, pb^)

    var rewritten = optimize_window_rewrite(plan^)
    # Sort retained.
    assert_equal(_count_sort(rewritten), 1)
    assert_equal(Int(rewritten.tag), Int(PLAN_SORT))


def test_sort_direction_mismatch_preserved() raises:
    """Sort by (user_id DESC, ts ASC) over PartitionBy(pkeys=[user_id],
    okeys=[ts] ASC). The first key's direction (DESC) doesn't match the
    PartitionBy's implied direction for partition keys (always ASC) — the
    Sort is genuinely needed; preserved."""
    var schema = _three_col_schema()
    var child = _scan_plan(schema^)
    var pb = _build_running_total_pb(child^)

    var sort_keys: List[String] = ["user_id", "ts"]
    var sort_desc: List[Bool] = [True, False]  # user_id DESC mismatches!
    var plan = LogicalPlan.sort(sort_keys^, sort_desc^, pb^)

    var rewritten = optimize_window_rewrite(plan^)
    assert_equal(_count_sort(rewritten), 1)
    assert_equal(Int(rewritten.tag), Int(PLAN_SORT))


def test_sort_key_order_swapped_preserved() raises:
    """Sort by (ts, user_id) — keys are present in (P++O) but in the
    wrong order. NOT a prefix; preserved."""
    var schema = _three_col_schema()
    var child = _scan_plan(schema^)
    var pb = _build_running_total_pb(child^)

    var sort_keys: List[String] = ["ts", "user_id"]  # swapped order
    var sort_desc: List[Bool] = [False, False]
    var plan = LogicalPlan.sort(sort_keys^, sort_desc^, pb^)

    var rewritten = optimize_window_rewrite(plan^)
    assert_equal(_count_sort(rewritten), 1)
    assert_equal(Int(rewritten.tag), Int(PLAN_SORT))


def test_sort_longer_than_partition_by_keys_preserved() raises:
    """Sort by (user_id, ts, value) — first 2 keys are a prefix of
    (P++O) but the third key extends beyond what PartitionBy guarantees.
    Conservative gate: preserved."""
    var schema = _three_col_schema()
    var child = _scan_plan(schema^)
    var pb = _build_running_total_pb(child^)

    var sort_keys: List[String] = ["user_id", "ts", "value"]
    var sort_desc: List[Bool] = [False, False, False]
    var plan = LogicalPlan.sort(sort_keys^, sort_desc^, pb^)

    var rewritten = optimize_window_rewrite(plan^)
    assert_equal(_count_sort(rewritten), 1)
    assert_equal(Int(rewritten.tag), Int(PLAN_SORT))


def test_sort_over_partition_by_with_empty_keys_preserved() raises:
    """PartitionBy with empty pkeys AND empty okeys -- the engine sink
    skips its internal sort in this case (`if len(sort_keys) == 0:
    sorted_batch = batch^`), so output row order is NOT guaranteed.
    Sort is genuinely needed; preserved."""
    var schema = _three_col_schema()
    var child = _scan_plan(schema^)

    var pkeys: List[String] = []
    var okeys: List[String] = []
    var pb_desc: List[Bool] = []
    var pexprs = List[PartitionExpr]()
    pexprs.append(
        PartitionExpr.row_number().with_alias(String("rn"))
    )
    var pb = LogicalPlan.partition_by(
        pkeys^, okeys^, pb_desc^, pexprs^, child^,
    )

    var sort_keys: List[String] = ["user_id"]
    var sort_desc: List[Bool] = [False]
    var plan = LogicalPlan.sort(sort_keys^, sort_desc^, pb^)

    var rewritten = optimize_window_rewrite(plan^)
    assert_equal(_count_sort(rewritten), 1)
    assert_equal(Int(rewritten.tag), Int(PLAN_SORT))


def test_sort_nulls_first_on_partition_key_preserved() raises:
    """Sort by (user_id ASC NULLS FIRST, ts ASC NULLS FIRST) over
    PartitionBy(pkeys=[user_id], okeys=[ts]). Keys and directions are a
    prefix of (P ++ O), but the sink places NULLs where
    `derived_nulls_first` says (NULLS LAST), so the Sort is not redundant
    and must survive with its explicit placement."""
    var schema = _three_col_schema()
    var child = _scan_plan(schema^)
    var pb = _build_running_total_pb(child^)

    var sort_keys: List[String] = ["user_id", "ts"]
    var sort_desc: List[Bool] = [False, False]
    var nf: List[Bool] = [True, True]
    var plan = LogicalPlan.sort(sort_keys^, sort_desc^, pb^, Optional(nf^))

    var rewritten = optimize_window_rewrite(plan^)
    assert_equal(_count_sort(rewritten), 1)
    assert_equal(Int(rewritten.tag), Int(PLAN_SORT))
    ref sd = rewritten.sort_data_ref()
    assert_equal(len(sd.nulls_first), 2)
    assert_true(sd.nulls_first[0])
    assert_true(sd.nulls_first[1])


def test_sort_nulls_first_on_order_key_only_preserved() raises:
    """Sort by (user_id ASC NULLS LAST, ts ASC NULLS FIRST) over
    PartitionBy(pkeys=[user_id], okeys=[ts]). Only the order key's NULL
    placement differs from the sink's; that one mismatch keeps the Sort."""
    var schema = _three_col_schema()
    var child = _scan_plan(schema^)
    var pb = _build_running_total_pb(child^)

    var sort_keys: List[String] = ["user_id", "ts"]
    var sort_desc: List[Bool] = [False, False]
    var nf: List[Bool] = [False, True]
    var plan = LogicalPlan.sort(sort_keys^, sort_desc^, pb^, Optional(nf^))

    var rewritten = optimize_window_rewrite(plan^)
    assert_equal(_count_sort(rewritten), 1)
    assert_equal(Int(rewritten.tag), Int(PLAN_SORT))


def test_sort_explicit_nulls_last_matching_sink_elides() raises:
    """Sort by (user_id, ts) ASC with explicit NULLS LAST, which is the
    sink's own placement: the Sort is redundant and is dropped."""
    var schema = _three_col_schema()
    var child = _scan_plan(schema^)
    var pb = _build_running_total_pb(child^)

    var sort_keys: List[String] = ["user_id", "ts"]
    var sort_desc: List[Bool] = [False, False]
    var nf: List[Bool] = [False, False]
    var plan = LogicalPlan.sort(sort_keys^, sort_desc^, pb^, Optional(nf^))

    var rewritten = optimize_window_rewrite(plan^)
    assert_equal(_count_sort(rewritten), 0)
    assert_equal(Int(rewritten.tag), Int(PLAN_PARTITION_BY))


# =============================================================================
# Section 3 -- Compositional cases
# =============================================================================

def test_sort_above_non_partition_by_unchanged() raises:
    """A bare Sort over a non-PartitionBy plan (e.g. a Scan) is untouched
    by the rule -- Pattern C only fires for the Sort/PartitionBy
    adjacency."""
    var schema = _three_col_schema()
    var child = _scan_plan(schema^)

    var sort_keys: List[String] = ["user_id"]
    var sort_desc: List[Bool] = [False]
    var plan = LogicalPlan.sort(sort_keys^, sort_desc^, child^)

    var rewritten = optimize_window_rewrite(plan^)
    # Sort retained -- not a Pattern C trigger.
    assert_equal(_count_sort(rewritten), 1)
    assert_equal(_count_partition_by(rewritten), 0)


def test_sort_above_pb_above_pb_pattern_b_then_c() raises:
    """Sort -> PartitionBy(triple T) -> PartitionBy(triple T) -> Scan.
    Pattern B fuses the two adjacent PBs; Pattern C then sees
    Sort -> single fused PartitionBy and elides the Sort.

    Demonstrates rule composability: Pattern C runs at every level via
    the recursive `optimize_window_rewrite` walker, including over
    plans that Pattern B has just fused.
    """
    var schema = _three_col_schema()
    var child = _scan_plan(schema^)

    # Inner PartitionBy.
    var inner_pkeys: List[String] = ["user_id"]
    var inner_okeys: List[String] = ["ts"]
    var inner_desc: List[Bool] = [False]
    var inner_pexprs = List[PartitionExpr]()
    inner_pexprs.append(
        PartitionExpr.rank().with_alias(String("rk"))
    )
    var inner_pb = LogicalPlan.partition_by(
        inner_pkeys^, inner_okeys^, inner_desc^, inner_pexprs^, child^,
    )

    # Outer PartitionBy with the SAME triple — Pattern B fuses these.
    var outer_pkeys: List[String] = ["user_id"]
    var outer_okeys: List[String] = ["ts"]
    var outer_desc: List[Bool] = [False]
    var outer_pexprs = List[PartitionExpr]()
    outer_pexprs.append(
        PartitionExpr.row_number().with_alias(String("rn"))
    )
    var pb = LogicalPlan.partition_by(
        outer_pkeys^, outer_okeys^, outer_desc^, outer_pexprs^, inner_pb^,
    )

    # Sort matching the (merged) PartitionBy's implied order.
    var sort_keys: List[String] = ["user_id", "ts"]
    var sort_desc: List[Bool] = [False, False]
    var plan = LogicalPlan.sort(sort_keys^, sort_desc^, pb^)

    # Pre: Sort + 2 PartitionBy.
    assert_equal(_count_sort(plan), 1)
    assert_equal(_count_partition_by(plan), 2)

    var rewritten = optimize_window_rewrite(plan^)

    # Post: Sort gone, single fused PartitionBy.
    assert_equal(_count_sort(rewritten), 0)
    assert_equal(_count_partition_by(rewritten), 1)
    assert_equal(Int(rewritten.tag), Int(PLAN_PARTITION_BY))


def test_sort_below_partition_by_unchanged() raises:
    """A Sort BELOW a PartitionBy (PB(child=Sort(scan))) is never a
    Pattern C trigger -- only the Sort/PB adjacency in the OUTER
    direction matters."""
    var schema = _three_col_schema()
    var child = _scan_plan(schema^)

    # Build Sort below PB.
    var sort_keys: List[String] = ["user_id"]
    var sort_desc: List[Bool] = [False]
    var inner_sort = LogicalPlan.sort(sort_keys^, sort_desc^, child^)
    var pb = _build_running_total_pb(inner_sort^)

    var rewritten = optimize_window_rewrite(pb^)
    # Sort still present; PartitionBy still present.
    assert_equal(_count_sort(rewritten), 1)
    assert_equal(_count_partition_by(rewritten), 1)
    assert_equal(Int(rewritten.tag), Int(PLAN_PARTITION_BY))


# =============================================================================
# Test driver
# =============================================================================

def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
