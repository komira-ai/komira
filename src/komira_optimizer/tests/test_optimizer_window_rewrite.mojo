# =============================================================================
# Tests for the window rewrite optimizer rule (`optimize_window_rewrite`)
# =============================================================================
#
# Multi-window co-location. This file covers two of the rule's
# triggers (Pattern C is in test_window_sort_elision.mojo):
#
#   Pattern A -- Project containing EXPR_WINDOW_FN exprs.
#   Pattern B -- Adjacent PartitionBy nodes with matching triple.
#
# This test file validates plan-shape behavior for both patterns; it
# executes no plan.
#
# Run: a welded test of komira_optimizer (BUCK test_srcs).
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_true, assert_false

from komira_arrow.schema import Schema, Field
from komira_arrow.arrow_types import ArrowType

from komira_plan_expr.col_expr import col
from komira_plan_expr.expr import (
    Expr, EXPR_COL_REF, EXPR_WINDOW_FN, EXPR_ALIAS,
)
from komira_plan_ir.logical_plan import (
    LogicalPlan, ExprArray,
    PLAN_PROJECT, PLAN_PARTITION_BY, PLAN_SCAN,
)
from komira_plan_expr.partition_expr import (
    PartitionExpr, PartitionFrame,
    PF_RANK, PF_ROW_NUMBER, PF_LAG, PF_SUM, PF_AVG,
)
from komira_plan_expr.scalar_value import ScalarValue

# This file's pure-plan rewrite pins
# (Sections 1-9, 11) exercise the LIVE optimizer pass `optimize_window_rewrite`
# (both Pattern A `_rewrite_project_with_windows` and Pattern B
# `_fuse_adjacent_partition_bys` remain in src, actively served — the typed-ROW
# window driver was re-homed) on HAND-BUILT LogicalPlans, so they never
# needed struct `DataFrame[O]`. Section 10 (the DataFrame[O]-only
# `.with_column(window)` -> PLAN_PARTITION_BY fast-path + e2e materialize) is
# TRIMMED — see its section note; the adjacent-PB FUSION it exercised is covered
# by Section 6 (`test_adjacent_partition_bys_same_triple_fuse`, hand-built
# adjacent PartitionBys); window materialize correctness is not tested
# here (this file executes no plan).
from komira_optimizer.optimizer_window_rewrite import optimize_window_rewrite


# =============================================================================
# Helpers
# =============================================================================

def _depth(plan: LogicalPlan) -> Int:
    """Plan tree depth (count of nested nodes from root to leaf scan)."""
    if plan.tag == PLAN_PARTITION_BY:
        return 1 + _depth(plan.partition_by_data_ref().child[])
    if plan.tag == PLAN_PROJECT:
        return 1 + _depth(plan.project_data_ref().child[])
    return 1


def _count_partition_by(plan: LogicalPlan) -> Int:
    """Number of PartitionBy nodes in the plan tree (recursive)."""
    var count: Int = 0
    if plan.tag == PLAN_PARTITION_BY:
        count = 1 + _count_partition_by(plan.partition_by_data_ref().child[])
    elif plan.tag == PLAN_PROJECT:
        count = _count_partition_by(plan.project_data_ref().child[])
    return count


# Build a pure-source LogicalPlan around a Slab[RecordBatch] without an
# InMemoryRegistry. The rule itself is pure-plan, so we only need a
# LogicalPlan to observe rewrite behavior; we never .materialize(ctx).
def _scan_plan(var schema: Schema) raises -> LogicalPlan:
    """Construct an in-memory scan LogicalPlan for plan-shape tests."""
    return LogicalPlan.scan(
        String("__test"),
        UInt8(3),  # SOURCE_IN_MEMORY
        schema^,
    )


# =============================================================================
# Section 1 -- Pattern A: Project with single EXPR_WINDOW_FN
# =============================================================================
#
# A single window: the rule fires and produces the same plan as the
# `with_column` fast-path. We construct a
# Project containing a window-fn expression manually (since the SDK's
# `with_column` fast-path bypasses Project) and verify the rule lowers
# it to PartitionBy + Project(col_ref).

def test_single_window_in_project_lowers_to_partition_by() raises:
    """A Project containing one EXPR_WINDOW_FN expr is rewritten to
    PartitionBy(child) + Project([col_ref(output_name)])."""
    var schema = Schema.from_fields_2(
        Field("g", ArrowType.INT64, False),
        Field("v", ArrowType.INT64, False),
    )
    var child = _scan_plan(schema^)

    # Build a Project with one window expr: rank().over("g").alias("rk").
    var exprs = ExprArray()
    exprs.append(Expr.col_ref("g"))
    exprs.append(Expr.col_ref("v"))
    exprs.append(col("v").rank().over("g").alias("rk"))
    var plan = LogicalPlan.project(exprs^, child^)

    var rewritten = optimize_window_rewrite(plan^)

    # Top should be a Project; immediately under should be a single
    # PartitionBy.
    assert_equal(Int(rewritten.tag), Int(PLAN_PROJECT))
    ref pd = rewritten.project_data_ref()
    assert_equal(Int(pd.child[].tag), Int(PLAN_PARTITION_BY))

    # Project's third expr should be col_ref("rk") (replacing the window).
    assert_equal(len(pd.exprs), 3)
    assert_equal(Int(pd.exprs[2].tag), Int(EXPR_COL_REF))
    assert_equal(pd.exprs[2].col_ref_name(), String("rk"))

    # Inner PartitionBy should have one PartitionExpr with PF_RANK and
    # alias_name="rk".
    ref pb = pd.child[].partition_by_data_ref()
    assert_equal(len(pb.partition_exprs), 1)
    assert_equal(Int(pb.partition_exprs[0].func), Int(PF_RANK))
    assert_equal(pb.partition_exprs[0].alias_name, String("rk"))


# =============================================================================
# Section 2 -- Pattern A: Two windows with same triple co-locate
# =============================================================================
#
# This is the load-bearing assertion of Pattern A: two window
# expressions sharing the SAME (partition_by, order_by, descending)
# triple should land in ONE PartitionBy node.

def test_two_windows_same_triple_colocate_into_one_partition_by() raises:
    """Two window exprs with identical .over("g") triple co-locate
    into a single PartitionBy node with two PartitionExprs."""
    var schema = Schema.from_fields_2(
        Field("g", ArrowType.INT64, False),
        Field("v", ArrowType.INT64, False),
    )
    var child = _scan_plan(schema^)

    # Project([g, v, rank().over("g") as rk, row_number().over("g") as rn])
    var exprs = ExprArray()
    exprs.append(Expr.col_ref("g"))
    exprs.append(Expr.col_ref("v"))
    exprs.append(col("v").rank().over("g").alias("rk"))
    exprs.append(col("v").row_number().over("g").alias("rn"))
    var plan = LogicalPlan.project(exprs^, child^)

    var rewritten = optimize_window_rewrite(plan^)

    # Top should be Project; under it ONE PartitionBy with TWO
    # PartitionExprs.
    assert_equal(Int(rewritten.tag), Int(PLAN_PROJECT))
    ref pd = rewritten.project_data_ref()
    assert_equal(Int(pd.child[].tag), Int(PLAN_PARTITION_BY))
    ref pb = pd.child[].partition_by_data_ref()
    assert_equal(len(pb.partition_exprs), 2)
    assert_equal(Int(pb.partition_exprs[0].func), Int(PF_RANK))
    assert_equal(pb.partition_exprs[0].alias_name, String("rk"))
    assert_equal(Int(pb.partition_exprs[1].func), Int(PF_ROW_NUMBER))
    assert_equal(pb.partition_exprs[1].alias_name, String("rn"))

    # And the child of the PartitionBy should be the original scan
    # (not nested PartitionBy).
    assert_equal(_count_partition_by(rewritten), 1)


# =============================================================================
# Section 3 -- Pattern A: Two windows with different partition_by
# =============================================================================
#
# Different triples must be split into separate PartitionBy nodes.

def test_two_windows_different_partition_by_split_into_two_pbys() raises:
    """Two window exprs with different .over(...) partition keys
    produce TWO PartitionBy nodes (stacked)."""
    var schema = Schema.from_fields_3(
        Field("g1", ArrowType.INT64, False),
        Field("g2", ArrowType.INT64, False),
        Field("v", ArrowType.INT64, False),
    )
    var child = _scan_plan(schema^)

    # Project([g1, g2, v, rank().over("g1") as rk1, rank().over("g2") as rk2])
    var exprs = ExprArray()
    exprs.append(Expr.col_ref("g1"))
    exprs.append(Expr.col_ref("g2"))
    exprs.append(Expr.col_ref("v"))
    exprs.append(col("v").rank().over("g1").alias("rk1"))
    exprs.append(col("v").rank().over("g2").alias("rk2"))
    var plan = LogicalPlan.project(exprs^, child^)

    var rewritten = optimize_window_rewrite(plan^)

    # Top: Project. Under: TWO PartitionBy nodes stacked.
    assert_equal(Int(rewritten.tag), Int(PLAN_PROJECT))
    assert_equal(_count_partition_by(rewritten), 2)


# =============================================================================
# Section 4 -- Pattern A: 3 windows, 2 share triple, 1 different
# =============================================================================

def test_three_windows_two_share_triple_one_different() raises:
    """3 window exprs: 2 share triple (over "g1") + 1 different
    (over "g2") => 2 PartitionBy nodes total. The shared bucket has
    two PartitionExprs; the singleton bucket has one."""
    var schema = Schema.from_fields_3(
        Field("g1", ArrowType.INT64, False),
        Field("g2", ArrowType.INT64, False),
        Field("v", ArrowType.INT64, False),
    )
    var child = _scan_plan(schema^)

    var exprs = ExprArray()
    exprs.append(Expr.col_ref("g1"))
    exprs.append(Expr.col_ref("g2"))
    exprs.append(Expr.col_ref("v"))
    exprs.append(col("v").rank().over("g1").alias("rk_a"))
    exprs.append(col("v").row_number().over("g1").alias("rn_a"))
    exprs.append(col("v").rank().over("g2").alias("rk_b"))
    var plan = LogicalPlan.project(exprs^, child^)

    var rewritten = optimize_window_rewrite(plan^)

    assert_equal(Int(rewritten.tag), Int(PLAN_PROJECT))
    assert_equal(_count_partition_by(rewritten), 2)

    # Walk down: top Project, then OUTERMOST PartitionBy (group 1, "g2"
    # singleton with 1 pexpr), then INNER PartitionBy (group 0, "g1"
    # bucket with 2 pexprs). The order matches the append order in
    # _rewrite_project_with_windows: groups[0]=g1 lands innermost,
    # groups[1]=g2 lands outermost.
    ref pd = rewritten.project_data_ref()
    assert_equal(Int(pd.child[].tag), Int(PLAN_PARTITION_BY))
    ref outer_pb = pd.child[].partition_by_data_ref()
    # Outer = singleton (group 1, "g2", rk_b)
    assert_equal(len(outer_pb.partition_keys), 1)
    assert_equal(outer_pb.partition_keys[0], String("g2"))
    assert_equal(len(outer_pb.partition_exprs), 1)
    assert_equal(outer_pb.partition_exprs[0].alias_name, String("rk_b"))

    # Inner = shared bucket (group 0, "g1", [rk_a, rn_a])
    assert_equal(Int(outer_pb.child[].tag), Int(PLAN_PARTITION_BY))
    ref inner_pb = outer_pb.child[].partition_by_data_ref()
    assert_equal(len(inner_pb.partition_keys), 1)
    assert_equal(inner_pb.partition_keys[0], String("g1"))
    assert_equal(len(inner_pb.partition_exprs), 2)
    assert_equal(inner_pb.partition_exprs[0].alias_name, String("rk_a"))
    assert_equal(inner_pb.partition_exprs[1].alias_name, String("rn_a"))


# =============================================================================
# Section 5 -- Pattern A: same partition_by but different order_by => split
# =============================================================================

def test_two_windows_same_pkey_different_order_by_split() raises:
    """Two window exprs with same partition_by but different order_by
    are NOT co-located (different sort directions/keys)."""
    var schema = Schema.from_fields_3(
        Field("g", ArrowType.INT64, False),
        Field("v1", ArrowType.INT64, False),
        Field("v2", ArrowType.INT64, False),
    )
    var child = _scan_plan(schema^)

    var pkeys_a: List[String] = ["g"]
    var okeys_a: List[String] = ["v1"]
    var pkeys_b: List[String] = ["g"]
    var okeys_b: List[String] = ["v2"]

    var exprs = ExprArray()
    exprs.append(Expr.col_ref("g"))
    exprs.append(Expr.col_ref("v1"))
    exprs.append(Expr.col_ref("v2"))
    exprs.append(col("v1").rank().over(pkeys_a^, okeys_a^).alias("rk_v1"))
    exprs.append(col("v2").rank().over(pkeys_b^, okeys_b^).alias("rk_v2"))
    var plan = LogicalPlan.project(exprs^, child^)

    var rewritten = optimize_window_rewrite(plan^)
    # Different order_by => 2 separate PartitionBy nodes.
    assert_equal(_count_partition_by(rewritten), 2)


# =============================================================================
# Section 6 -- Pattern B: adjacent PartitionBy with matching triple fuse
# =============================================================================
#
# This is the empirically-load-bearing pattern: chained
# `.with_column(window).with_column(window)` calls each fire the
# `with_column` fast-path independently, producing PartitionBy(PartitionBy()).
# Pattern B fuses them into one node.

def test_adjacent_partition_bys_same_triple_fuse() raises:
    """Two adjacent PartitionBy nodes with matching (pkeys, okeys,
    desc) triple fuse into one PartitionBy with concatenated pexprs."""
    var schema = Schema.from_fields_2(
        Field("g", ArrowType.INT64, False),
        Field("v", ArrowType.INT64, False),
    )
    var child = _scan_plan(schema^)

    # Build inner PartitionBy(pkeys=g, okeys=v, [rank as rk]).
    var inner_pkeys: List[String] = ["g"]
    var inner_okeys: List[String] = ["v"]
    var inner_desc: List[Bool] = [False]
    var inner_pexprs = List[PartitionExpr]()
    inner_pexprs.append(
        PartitionExpr.rank().with_alias(String("rk"))
    )
    var inner_plan = LogicalPlan.partition_by(
        inner_pkeys^, inner_okeys^, inner_desc^, inner_pexprs^, child^,
    )

    # Build outer PartitionBy(pkeys=g, okeys=v, [row_number as rn]).
    var outer_pkeys: List[String] = ["g"]
    var outer_okeys: List[String] = ["v"]
    var outer_desc: List[Bool] = [False]
    var outer_pexprs = List[PartitionExpr]()
    outer_pexprs.append(
        PartitionExpr.row_number().with_alias(String("rn"))
    )
    var plan = LogicalPlan.partition_by(
        outer_pkeys^, outer_okeys^, outer_desc^, outer_pexprs^, inner_plan^,
    )

    # Verify pre-condition: 2 stacked PartitionBy nodes.
    assert_equal(_count_partition_by(plan), 2)

    var rewritten = optimize_window_rewrite(plan^)

    # Post: ONE PartitionBy with 2 pexprs.
    assert_equal(Int(rewritten.tag), Int(PLAN_PARTITION_BY))
    assert_equal(_count_partition_by(rewritten), 1)
    ref pb = rewritten.partition_by_data_ref()
    assert_equal(len(pb.partition_exprs), 2)
    # Inner pexprs come first (preserves execution order semantics).
    assert_equal(pb.partition_exprs[0].alias_name, String("rk"))
    assert_equal(pb.partition_exprs[1].alias_name, String("rn"))


def test_three_adjacent_partition_bys_same_triple_fuse_to_one() raises:
    """⭐ THE SQL BINDER'S SHAPE FOR THREE WINDOWS.

    A SQL binder builds ONE PartitionBy per window SELECT item,
    so `SELECT k, row_number() OVER w, rank() OVER w, dense_rank() OVER w`
    arrives as PB3(PB2(PB1(scan))). The fuse fused the top PAIR and then
    rewrote only the GRANDCHILD, never the fused node against it — leaving
    PB32(PB1(scan)), a window whose child is a window, which the window
    executor refuses as an out-of-envelope shape: every three-window
    SQL query over one OVER clause was REFUSED at the SQL door while two
    windows answered. Three stacked nodes with one triple must fuse to ONE,
    execution order preserved (innermost first)."""
    var schema = Schema.from_fields_2(
        Field("g", ArrowType.INT64, False),
        Field("v", ArrowType.INT64, False),
    )
    var plan = _scan_plan(schema^)
    var aliases: List[String] = ["rn", "rk", "dr"]
    for i in range(3):
        var pk: List[String] = ["g"]
        var ok: List[String] = ["v"]
        var dsc: List[Bool] = [False]
        var px = List[PartitionExpr]()
        if i == 0:
            px.append(PartitionExpr.row_number().with_alias(aliases[i]))
        elif i == 1:
            px.append(PartitionExpr.rank().with_alias(aliases[i]))
        else:
            px.append(PartitionExpr.dense_rank().with_alias(aliases[i]))
        plan = LogicalPlan.partition_by(pk^, ok^, dsc^, px^, plan^)
    assert_equal(_count_partition_by(plan), 3)

    var rewritten = optimize_window_rewrite(plan^)

    assert_equal(Int(rewritten.tag), Int(PLAN_PARTITION_BY))
    assert_equal(
        _count_partition_by(rewritten), 1,
        "three stacked PartitionBys with ONE triple must fuse to ONE node",
    )
    ref pb = rewritten.partition_by_data_ref()
    assert_equal(len(pb.partition_exprs), 3)
    assert_equal(pb.partition_exprs[0].alias_name, String("rn"))
    assert_equal(pb.partition_exprs[1].alias_name, String("rk"))
    assert_equal(pb.partition_exprs[2].alias_name, String("dr"))
    assert_equal(
        Int(pb.child[].tag), Int(PLAN_SCAN),
        "the fused window must sit directly on the scan",
    )


def test_four_adjacent_partition_bys_under_a_project_fuse_to_one() raises:
    """The same, four deep and under the SELECT's Project — `win_running_v`'s
    SQL shape (sum / count / min / max over one OVER clause)."""
    var schema = Schema.from_fields_2(
        Field("g", ArrowType.INT64, False),
        Field("v", ArrowType.INT64, False),
    )
    var plan = _scan_plan(schema^)
    var aliases: List[String] = ["a", "b", "c", "d"]
    for i in range(4):
        var pk: List[String] = ["g"]
        var ok: List[String] = ["v"]
        var dsc: List[Bool] = [False]
        var px = List[PartitionExpr]()
        px.append(PartitionExpr.row_number().with_alias(aliases[i]))
        plan = LogicalPlan.partition_by(pk^, ok^, dsc^, px^, plan^)
    var names: List[String] = ["g", "v", "a", "b", "c", "d"]
    var exprs = ExprArray()
    for i in range(len(names)):
        exprs.append(Expr.col_ref(names[i]))
    var proj = LogicalPlan.project(exprs^, plan^)
    assert_equal(_count_partition_by(proj), 4)

    var rewritten = optimize_window_rewrite(proj^)

    assert_equal(Int(rewritten.tag), Int(PLAN_PROJECT))
    assert_equal(_count_partition_by(rewritten), 1)
    ref pb = rewritten.project_data_ref().child[].partition_by_data_ref()
    assert_equal(len(pb.partition_exprs), 4)
    for i in range(4):
        assert_equal(pb.partition_exprs[i].alias_name, aliases[i])


# =============================================================================
# Section 7 -- Pattern B: adjacent PartitionBy with different triple stay
# =============================================================================

def test_adjacent_partition_bys_different_triple_do_not_fuse() raises:
    """Two adjacent PartitionBy nodes with different triples remain
    as two stacked nodes (no fusion)."""
    var schema = Schema.from_fields_3(
        Field("g1", ArrowType.INT64, False),
        Field("g2", ArrowType.INT64, False),
        Field("v", ArrowType.INT64, False),
    )
    var child = _scan_plan(schema^)

    # Inner partition_by g1
    var ip: List[String] = ["g1"]
    var io: List[String] = []
    var id_: List[Bool] = []
    var ipx = List[PartitionExpr]()
    ipx.append(PartitionExpr.rank().with_alias(String("rk1")))
    var inner_plan = LogicalPlan.partition_by(
        ip^, io^, id_^, ipx^, child^,
    )

    # Outer partition_by g2 (different)
    var op_: List[String] = ["g2"]
    var oo: List[String] = []
    var od: List[Bool] = []
    var opx = List[PartitionExpr]()
    opx.append(PartitionExpr.rank().with_alias(String("rk2")))
    var plan = LogicalPlan.partition_by(
        op_^, oo^, od^, opx^, inner_plan^,
    )

    var rewritten = optimize_window_rewrite(plan^)
    # Still 2 PartitionBy nodes.
    assert_equal(_count_partition_by(rewritten), 2)


# =============================================================================
# Section 8 -- Pattern A: bare (un-aliased) window-fn uses generated name
# =============================================================================

def test_bare_window_fn_uses_generated_name() raises:
    """A bare EXPR_WINDOW_FN (no Alias wrapper) gets a generated
    `_w<idx>_<func>` output name, and the Project's replacement
    col_ref points at that name."""
    var schema = Schema.from_fields_2(
        Field("g", ArrowType.INT64, False),
        Field("v", ArrowType.INT64, False),
    )
    var child = _scan_plan(schema^)

    var exprs = ExprArray()
    exprs.append(Expr.col_ref("g"))
    # No .alias() chain -- the PartitionExpr will get alias_name=""
    # and partition_expr_output_field will assign "_w0_rank".
    exprs.append(col("v").rank().over("g"))
    var plan = LogicalPlan.project(exprs^, child^)

    var rewritten = optimize_window_rewrite(plan^)

    assert_equal(Int(rewritten.tag), Int(PLAN_PROJECT))
    ref pd = rewritten.project_data_ref()
    # Project's second expr should be col_ref("_w0_rank").
    assert_equal(Int(pd.exprs[1].tag), Int(EXPR_COL_REF))
    assert_equal(pd.exprs[1].col_ref_name(), String("_w0_rank"))


# =============================================================================
# Section 9 -- No-window plan: rule passes through
# =============================================================================

def test_plan_with_no_window_fn_passes_through() raises:
    """A plan with no window-fn exprs and no adjacent PartitionBy is
    returned unchanged (modulo deep-copy)."""
    var schema = Schema.from_fields_2(
        Field("g", ArrowType.INT64, False),
        Field("v", ArrowType.INT64, False),
    )
    var child = _scan_plan(schema^)
    var exprs = ExprArray()
    exprs.append(Expr.col_ref("g"))
    exprs.append(Expr.col_ref("v"))
    var plan = LogicalPlan.project(exprs^, child^)

    var rewritten = optimize_window_rewrite(plan^)
    assert_equal(Int(rewritten.tag), Int(PLAN_PROJECT))
    assert_equal(_count_partition_by(rewritten), 0)


# =============================================================================
# Section 10 (End-to-end chained `.with_column(window)` co-location) TRIMMED
# =============================================================================
#
# This section built a `DataFrame[COLUMN].from_record_batch(batch)
# .with_column(window).with_column(window)` and pinned
# `df.plan_tag() == PLAN_PARTITION_BY` — i.e. the DataFrame[O]-only
# `.with_column(window)` fast-path that WRAPS each window in a PartitionBy at
# construction time. That fast-path was retired with struct `DataFrame[O]`
# and the survivor construction route (ScanFrame `.with_column`)
# builds a PLAN_PROJECT with no construction-time window detection, so the
# `plan_tag() == PLAN_PARTITION_BY` pre-condition has no replacement surface —
# it guarded a deliberately-removed construction behavior, not the optimizer.
#
# The coverage this section provided is NOT lost:
#   * The adjacent-PartitionBy FUSION (Pattern B) it fed is covered by
#     Section 6 (`test_adjacent_partition_bys_same_triple_fuse`), which builds the
#     adjacent PartitionBy nodes by hand and asserts they fuse into one.
#   * End-to-end window materialize CORRECTNESS is not tested in this file,
#     which executes no plan.


# =============================================================================
# Section 11 -- Composability: window expr with non-window peers in Project
# =============================================================================
#
# The "window expr among other exprs
# (composability)" case. Verifies the rule is robust to non-window
# expressions interleaved with window-fns in the same Project.

def test_window_expr_alongside_non_window_exprs_in_project() raises:
    """Project mixing literal, col_ref, binary_op, and window_fn
    exprs should still rewrite cleanly: only the window_fn becomes a
    col_ref into a new PartitionBy; other exprs pass through verbatim."""
    var schema = Schema.from_fields_2(
        Field("g", ArrowType.INT64, False),
        Field("v", ArrowType.INT64, False),
    )
    var child = _scan_plan(schema^)

    var exprs = ExprArray()
    # 1: bare col_ref
    exprs.append(Expr.col_ref("g"))
    # 2: literal (passes through)
    var lit_val: ScalarValue = ScalarValue.from_int64(Int64(42))
    exprs.append(Expr.literal(lit_val^))
    # 3: window expr
    exprs.append(col("v").rank().over("g").alias("rk"))
    # 4: another col_ref
    exprs.append(Expr.col_ref("v"))
    var plan = LogicalPlan.project(exprs^, child^)

    var rewritten = optimize_window_rewrite(plan^)
    assert_equal(Int(rewritten.tag), Int(PLAN_PROJECT))
    ref pd = rewritten.project_data_ref()
    # Same number of output exprs.
    assert_equal(len(pd.exprs), 4)
    # Window slot replaced with col_ref("rk").
    assert_equal(Int(pd.exprs[2].tag), Int(EXPR_COL_REF))
    assert_equal(pd.exprs[2].col_ref_name(), String("rk"))
    # Non-window exprs preserved in original positions.
    assert_equal(Int(pd.exprs[0].tag), Int(EXPR_COL_REF))
    assert_equal(pd.exprs[0].col_ref_name(), String("g"))
    # One PartitionBy under the Project.
    assert_equal(_count_partition_by(rewritten), 1)


# =============================================================================
# Section 12 -- Pattern A: a window ALIASED TO A NAME THE CHILD ALREADY HAS
# =============================================================================
#
# ⛔ `with_columns(col("v").max().over("g").alias("v"))` (polars' "replace v
# with its group max") answered the ORIGINAL `v`, silently: the PartitionBy
# APPENDED a second `v` and the Project's `col_ref("v")` resolved to the
# child's. MEASURED through the Mojo API: v = [7, NULL, 10, 0, ..]
# where polars 1.44.2 and DuckDB 1.5.3 answer [7, 7, 10, 10, ..].

def test_a_window_aliased_to_a_child_column_gets_an_internal_name() raises:
    """The window is computed under an INTERNAL name and aliased back, so the
    Project's `v` reads the WINDOW, not the child's `v`."""
    var schema = Schema.from_fields_2(
        Field("g", ArrowType.INT64, False),
        Field("v", ArrowType.INT64, False),
    )
    var child = _scan_plan(schema^)
    var exprs = ExprArray()
    exprs.append(Expr.col_ref("g"))
    exprs.append(col("v").max().over("g").alias("v"))
    var plan = LogicalPlan.project(exprs^, child^)

    var rewritten = optimize_window_rewrite(plan^)
    assert_equal(Int(rewritten.tag), Int(PLAN_PROJECT))
    ref pd = rewritten.project_data_ref()
    assert_equal(Int(pd.child[].tag), Int(PLAN_PARTITION_BY))
    ref pb = pd.child[].partition_by_data_ref()
    assert_equal(len(pb.partition_exprs), 1)
    var internal = pb.partition_exprs[0].alias_name.copy()
    assert_true(internal != String("v"), "no SECOND `v` under the Project")
    assert_equal(Int(pd.exprs[1].tag), Int(EXPR_ALIAS), "aliased back")
    assert_equal(pd.exprs[1].alias_name(), String("v"))
    assert_equal(pd.exprs[1].alias_child_ref().col_ref_name(), internal)
    assert_equal(rewritten.output_schema.num_columns(), 2)
    assert_equal(rewritten.output_schema.field_name(1), String("v"))


def test_a_window_with_a_fresh_name_keeps_the_bare_col_ref() raises:
    """CONTROL: no collision -> exactly the pre-fix shape."""
    var schema = Schema.from_fields_2(
        Field("g", ArrowType.INT64, False),
        Field("v", ArrowType.INT64, False),
    )
    var child = _scan_plan(schema^)
    var exprs = ExprArray()
    exprs.append(Expr.col_ref("g"))
    exprs.append(col("v").max().over("g").alias("mx"))
    var plan = LogicalPlan.project(exprs^, child^)
    var rewritten = optimize_window_rewrite(plan^)
    ref pd = rewritten.project_data_ref()
    assert_equal(Int(pd.exprs[1].tag), Int(EXPR_COL_REF))
    assert_equal(pd.exprs[1].col_ref_name(), String("mx"))
    ref pb = pd.child[].partition_by_data_ref()
    assert_equal(pb.partition_exprs[0].alias_name, String("mx"))


# =============================================================================
# Test driver
# =============================================================================

def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
