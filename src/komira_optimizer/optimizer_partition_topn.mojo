# =============================================================================
# Optimizer rule: fuse_partition_topn
# =============================================================================
#
# Detects the pattern:
#
#   [Project(drop rn)] -> Filter(rn <= K) -> PartitionBy(RowNumber|Rank)
#
# and fuses it into a single PartitionTopN node. This eliminates:
#   - The full row_number / rank computation
#   - The filter pass
#   - The projection to strip the rn/rk column
#
# Replaces those 2-3 nodes with a single PartitionTopN that uses a
# per-partition bounded heap (O(N log K) instead of O(N log N + N)).
#
# The gate also recognizes
# PF_RANK. RANK preserves ties, so the fused node carries a small over-fetch
# epsilon (`_PF_RANK_TIE_EPSILON = 16`) that the engine uses as the
# per-partition heap capacity. After the heap is full, the engine ranks
# the surviving rows and discards entries with rank > K. For Float64 sort
# keys with ~10K rows/partition, the tie probability is ~10K * 2^-52 →
# effectively zero, so K + 16 covers all realistic inputs.
#
# **The RANK path is behind the comptime gate `_ENABLE_PF_RANK_FUSE`,
# which is True.** When the gate is OFF, RANK plans flow through the
# unfused PartitionBy + Filter operators; when ON, the engine's
# partition-topN sink dispatches on the fused node's `func`.
#
# Patterns matched (ROW_NUMBER, always on):
#   1. Filter(col(rn) <= K) above PartitionBy([RowNumber]) -> PartitionTopN(K)
#   2. Filter(col(rn) < K)  above PartitionBy([RowNumber]) -> PartitionTopN(K-1)
#   3. Project above the fused PartitionTopN that is now an identity -> absorbed
#
# Patterns matched (RANK, gated on _ENABLE_PF_RANK_FUSE):
#   4. Filter(col(rk) <= K) above PartitionBy([Rank]) -> PartitionTopN(K, RANK)
#   5. Filter(col(rk) < K)  above PartitionBy([Rank]) -> PartitionTopN(K-1, RANK)
#
# The rule does NOT fire when (recognition gates):
#   - PartitionBy has more than one PartitionExpr (multi-window)
#   - The single PartitionExpr is not ROW_NUMBER or RANK (e.g. DenseRank,
#     PercentRank, CumeDist, NTile, Lag, Lead, ...)
#   - PartitionBy has an empty ORDER BY (RANK without an order is
#     meaningless; defensively bail out for ROW_NUMBER too — though the
#     output ordering is already non-deterministic)
#   - The filter predicate does not reference the rn/rk column
#   - The filter op is not <= or <
#   - K < 1 or K > 1_000_000 (negative K is a defensive bail-out, not crash)
# =============================================================================

from komira_plan_ir.logical_plan import (
    LogicalPlan,
    PLAN_SCAN,
    PLAN_FILTER,
    PLAN_PROJECT,
    PLAN_AGGREGATE,
    PLAN_JOIN,
    PLAN_SORT,
    PLAN_LIMIT,
    PLAN_DISTINCT,
    PLAN_TOPN,
    PLAN_PARTITION_BY,
    PLAN_PARTITION_TOPN,
    PLAN_ASOF_JOIN,
)
from komira_plan_expr.expr import (
    Expr,
    EXPR_COL_REF,
    EXPR_LITERAL,
    EXPR_BINARY_OP,
    BIN_LE,
    BIN_LT,
)
from std.collections import Set

from komira_plan_expr.partition_expr import PartitionExpr, PF_ROW_NUMBER, PF_RANK
from komira_plan_ir.plan_helpers import (
    _copy_plan,
    _copy_expr_array,
    _copy_agg_expr_array,
    _take_filter_child,
    _take_project_child,
    _take_aggregate_child,
    _take_join_left,
    _take_join_right,
    _take_sort_child,
    _take_limit_child,
    _take_distinct_child,
    _take_topn_child,
    _take_partition_by_child,
    _take_partition_topn_child,
    _collect_expr_columns,
)


# =============================================================================
# Fusion limit and the RANK gate
# =============================================================================
#
# Maximum K value for PartitionTopN fusion.
comptime _PARTITION_TOPN_MAX_K: Int = 1_000_000

# RANK fusion gate. When True, RANK plans of the form
# `Filter(rk <= K) > PartitionBy(RANK)` fuse into
# `PartitionTopN(func=PF_RANK, over_fetch_k=K+EPSILON)`, which the engine's
# partition-topN sink runs by dispatching on `func`. When False, such plans
# flow through the unfused PartitionBy + Filter operators.
comptime _ENABLE_PF_RANK_FUSE: Bool = True

# Tie-buffer epsilon for the PF_RANK over-fetch. The engine
# maintains a per-partition heap of size `K + EPSILON` then post-filters
# to entries with rank <= K. Rationale:
# Float64 score with ~10K rows/partition → tie probability ~10K * 2^-52
# ≈ 2.2e-12, so EPSILON=16 covers >99.9999% of real inputs.
# Pathological repeated-value inputs (e.g. integer sort key with many
# duplicates) would exceed this and require fallback — that decision
# belongs to the engine.
comptime _PF_RANK_TIE_EPSILON: Int = 16


# =============================================================================
# Public API
# =============================================================================


def fuse_partition_topn(var plan: LogicalPlan) raises -> LogicalPlan:
    """Fuse Filter(rn <= K) + PartitionBy(RowNumber) into PartitionTopN(K).

    Wrapper around `fuse_partition_topn_inplace`.

    Pre-pass: builds the set of window-output column names that are
    referenced ABOVE their immediate Filter consumer (i.e. by ancestor
    operators that would still try to read them after fusion strips
    them from the schema). The recursive fuse uses this set to decide
    whether the fused PartitionTopN must emit the rk/rn column.

    An earlier version skipped fusion when rk was referenced upstream —
    correct, but it missed the fused fast path on the common ranked top-K
    shape `.filter(rk<=K).sort_multi(["x", "rk"])`, because the
    post-filter Sort references rk.

    Instead the rule fuses with
    emission: when the window-output column is in `unsafe_cols`, the
    fused PartitionTopN is constructed with
    `output_rank_col_name = Some(rn_col_name)`, and the engine kernel
    emits an additional Int64 column carrying the rank value so the
    downstream Sort / Project / Filter resolves it normally, and that
    shape takes the fused fast path.
    """
    var unsafe_cols = Set[String]()
    var ancestor_cols = Set[String]()
    _collect_unsafe_window_cols(plan, ancestor_cols, unsafe_cols)
    fuse_partition_topn_inplace(plan, unsafe_cols)
    return plan^


def _collect_unsafe_window_cols(
    plan: LogicalPlan,
    ancestor_cols: Set[String],
    mut unsafe_cols: Set[String],
) raises:
    """Top-down walk: find window-output column names referenced ABOVE
    their consumer Filter.

    Args:
        plan: subplan to examine.
        ancestor_cols: column names referenced by operators STRICTLY
            ABOVE this plan node (Sort keys, Project exprs, Aggregate
            exprs, Join keys, Filter predicates, etc.). Filter
            predicates of THIS node are NOT in ancestor_cols, and a
            Filter does not add its own child PartitionBy's window
            column for that child (the Filter is the legitimate consumer
            of that window column).
        unsafe_cols: out-param. Window-output column names of any
            PartitionBy that is `Filter > PartitionBy(RowNumber|Rank)`
            shaped AND whose window column name appears in
            ancestor_cols.

    Why a Set keyed by NAME (not node-identity): the auto-named window
    column ("rn" / "rk") is unique within a plan instance; if two
    Filters consume two different PartitionBy nodes both producing
    a column named "rk", they cannot coexist in a valid plan. So the
    name-based set is a safe coarsening.
    """
    if plan.tag == PLAN_FILTER:
        # Check: is the Filter's child a fusable PartitionBy?
        if plan._filter.value()[].child[].tag == PLAN_PARTITION_BY:
            ref pb = plan._filter.value()[].child[]._partition_by.value()[]
            if len(pb.partition_exprs) == 1:
                var pf = pb.partition_exprs[0].func
                if (pf == PF_ROW_NUMBER or pf == PF_RANK):
                    var win_col_name = (
                        plan._filter.value()[].child[].output_schema.field_name(
                            plan._filter.value()[].child[].output_schema.num_columns() - 1
                        )
                    )
                    # If any ancestor references the window column, the
                    # fuse is unsafe (the rk column won't exist after
                    # fusion strips it from the PartitionTopN's output
                    # schema).
                    if win_col_name in ancestor_cols:
                        unsafe_cols.add(win_col_name)

        # Recurse: the Filter's predicate is the legitimate consumer of
        # its CHILD PartitionBy's window column, so that one name is not
        # added for the child. Every other column the predicate reads is:
        # a window column produced further down (e.g. under another
        # Filter) is still read here after that lower node fuses.
        var pred_cols = Set[String]()
        _collect_expr_columns(plan._filter.value()[].predicate, pred_cols)
        if plan._filter.value()[].child[].tag == PLAN_PARTITION_BY:
            ref child_schema = plan._filter.value()[].child[].output_schema
            var consumed = child_schema.field_name(
                child_schema.num_columns() - 1
            )
            if consumed in pred_cols:
                pred_cols.remove(consumed)
        var new_ancestor = ancestor_cols.copy()
        for c in pred_cols:
            new_ancestor.add(c)
        _collect_unsafe_window_cols(
            plan._filter.value()[].child[], new_ancestor, unsafe_cols
        )

    elif plan.tag == PLAN_PROJECT:
        var new_ancestor = ancestor_cols.copy()
        for i in range(len(plan._project.value()[].exprs)):
            _collect_expr_columns(plan._project.value()[].exprs[i], new_ancestor)
        _collect_unsafe_window_cols(
            plan._project.value()[].child[], new_ancestor, unsafe_cols
        )

    elif plan.tag == PLAN_AGGREGATE:
        var new_ancestor = ancestor_cols.copy()
        for i in range(len(plan._aggregate.value()[].group_by)):
            _collect_expr_columns(
                plan._aggregate.value()[].group_by[i], new_ancestor
            )
        for i in range(len(plan._aggregate.value()[].agg_exprs)):
            if plan._aggregate.value()[].agg_exprs[i].child:
                _collect_expr_columns(
                    plan._aggregate.value()[].agg_exprs[i].child.value(),
                    new_ancestor,
                )
        _collect_unsafe_window_cols(
            plan._aggregate.value()[].child[], new_ancestor, unsafe_cols
        )

    elif plan.tag == PLAN_JOIN:
        var new_ancestor = ancestor_cols.copy()
        for key in plan._join.value()[].left_on:
            new_ancestor.add(key)
        for key in plan._join.value()[].right_on:
            new_ancestor.add(key)
        # A residual predicate reads columns of either side.
        if plan._join.value()[].residual:
            _collect_expr_columns(
                plan._join.value()[].residual.value()[], new_ancestor
            )
        _collect_unsafe_window_cols(
            plan._join.value()[].left[], new_ancestor, unsafe_cols
        )
        _collect_unsafe_window_cols(
            plan._join.value()[].right[], new_ancestor, unsafe_cols
        )

    elif plan.tag == PLAN_SORT:
        var new_ancestor = ancestor_cols.copy()
        for key in plan._sort.value()[].keys:
            new_ancestor.add(key)
        _collect_unsafe_window_cols(
            plan._sort.value()[].child[], new_ancestor, unsafe_cols
        )

    elif plan.tag == PLAN_LIMIT:
        _collect_unsafe_window_cols(
            plan._limit.value()[].child[], ancestor_cols, unsafe_cols
        )

    elif plan.tag == PLAN_DISTINCT:
        var new_ancestor = ancestor_cols.copy()
        if plan._distinct.value()[].columns:
            for c in plan._distinct.value()[].columns.value():
                new_ancestor.add(c)
        else:
            # A Distinct over all columns reads every column of its child.
            ref child_schema = plan._distinct.value()[].child[].output_schema
            for i in range(child_schema.num_columns()):
                new_ancestor.add(child_schema.field_name(i))
        _collect_unsafe_window_cols(
            plan._distinct.value()[].child[], new_ancestor, unsafe_cols
        )

    elif plan.tag == PLAN_TOPN:
        var new_ancestor = ancestor_cols.copy()
        for key in plan._topn.value()[].keys:
            new_ancestor.add(key)
        _collect_unsafe_window_cols(
            plan._topn.value()[].child[], new_ancestor, unsafe_cols
        )

    elif plan.tag == PLAN_PARTITION_BY:
        # The PartitionBy reads its partition keys, its order keys and
        # each partition expression's argument column from its child; a
        # window column produced below must survive fusion for them.
        var new_ancestor = ancestor_cols.copy()
        ref pbd = plan._partition_by.value()[]
        for key in pbd.partition_keys:
            new_ancestor.add(key)
        for key in pbd.order_keys:
            new_ancestor.add(key)
        for i in range(len(pbd.partition_exprs)):
            if pbd.partition_exprs[i].column.byte_length() > 0:
                new_ancestor.add(pbd.partition_exprs[i].column)
        _collect_unsafe_window_cols(pbd.child[], new_ancestor, unsafe_cols)

    elif plan.tag == PLAN_PARTITION_TOPN:
        # The PartitionTopN reads its partition and sort keys from its
        # child.
        var new_ancestor = ancestor_cols.copy()
        ref ptd = plan._partition_topn.value()[]
        for key in ptd.partition_keys:
            new_ancestor.add(key)
        for key in ptd.sort_keys:
            new_ancestor.add(key)
        _collect_unsafe_window_cols(ptd.child[], new_ancestor, unsafe_cols)

    elif plan.tag == PLAN_ASOF_JOIN:
        # Conservative: ASOF join may reference any column on either
        # side. We don't fuse below an ASOF join anyway in production
        # plan shapes, so this is mostly defensive.
        pass

    # PLAN_SCAN: leaf, nothing to do.


def fuse_partition_topn_inplace(mut plan: LogicalPlan, unsafe_cols: Set[String]) raises:
    """In-place partition-topN fusion.

    Recurses children IN PLACE. The two firing patterns rebuild because
    they collapse two nodes into one (Project-over-PartitionTopN
    identity, Filter-over-PartitionBy fusion). Non-firing walks skip
    the rebuild entirely.

    Args:
        plan: Subplan to optimize in-place.
        unsafe_cols: Set of window-output column names that MUST NOT be
            fused (because their consumer Filter is followed by an
            ancestor that references the column). Computed once by
            `_collect_unsafe_window_cols` at the top-level entry.
    """
    # -- Pattern 1: Project above a (possibly fused) child --
    if plan.tag == PLAN_PROJECT:
        fuse_partition_topn_inplace(plan._project.value()[].child[], unsafe_cols)

        ref ppd = plan._project.value()[]
        if ppd.child[].tag == PLAN_PARTITION_TOPN:
            ref out_schema = ppd.child[].output_schema
            ref proj_exprs = ppd.exprs
            var is_identity = len(proj_exprs) == out_schema.num_columns()
            if is_identity:
                for i in range(len(proj_exprs)):
                    if not proj_exprs[i].is_col_ref():
                        is_identity = False
                        break
                    if proj_exprs[i].col_ref_name() != out_schema.field_name(i):
                        is_identity = False
                        break
            if is_identity:
                # Replace plan with a deep copy of its child (PartitionTopN).
                # _copy_plan is the only safe primitive (partial-move ban on
                # the OwnedPointer field).
                var child_copy = _copy_plan(plan._project.value()[].child[])
                plan = child_copy^
        return

    # -- Pattern 2: Filter above PartitionBy(RowNumber|Rank) --
    if plan.tag == PLAN_FILTER:
        fuse_partition_topn_inplace(plan._filter.value()[].child[], unsafe_cols)

        if plan._filter.value()[].child[].tag == PLAN_PARTITION_BY:
            # MOJO 1.0.0: `pb` and the `fpd.predicate` read below must come
            # off ONE walk of the FilterData.
            ref fpd = plan._filter.value()[]
            ref pb = fpd.child[]._partition_by.value()[]

            # Recognition gate (conservative form):
            #   1. Exactly one PartitionExpr (no multi-window).
            #   2. The PartitionExpr is PF_ROW_NUMBER OR PF_RANK
            #      (NOT PF_DENSE_RANK / PF_PERCENT_RANK / PF_NTILE / ...).
            #   3. A RANK PartitionBy has a non-empty ORDER BY (RANK without
            #      an order is meaningless). ROW_NUMBER without an order has
            #      non-deterministic output but is legal and still fuses.
            #   4. PF_RANK only fires when `_ENABLE_PF_RANK_FUSE` is True
            #      (it is).
            if len(pb.partition_exprs) != 1:
                return
            var pf = pb.partition_exprs[0].func
            var is_row_number = pf == PF_ROW_NUMBER
            var is_rank = pf == PF_RANK
            if not is_row_number and not is_rank:
                return
            # Defensive: RANK without an ORDER BY is meaningless. ROW_NUMBER
            # without ORDER BY has non-deterministic output but is legal at
            # the IR level; ROW_NUMBER still fuses.
            if is_rank and len(pb.order_keys) == 0:
                return
            if is_rank and not _ENABLE_PF_RANK_FUSE:
                # Recognition succeeded but the RANK fast path is gated
                # OFF. Plan flows through unfused PartitionBy + Filter.
                return

            # The rn/rk column is the last column in the PartitionBy output.
            ref rn_schema = fpd.child[].output_schema
            var rn_col_name = rn_schema.field_name(rn_schema.num_columns() - 1)

            # Safety gate: if this rn/rk
            # column is referenced by any ancestor of the Filter, the
            # fused PartitionTopN must emit the column so the ancestor
            # can resolve it.
            #
            # Rather than skip fusion
            # when rk is referenced upstream, fuse with
            # `output_rank_col_name = Some(rn_col_name)`. The kernel
            # then emits an additional Int64 column carrying the rank
            # value per surviving row, and the downstream Sort /
            # Project / Filter resolves it normally.
            var emit_rank_col: Optional[String] = None
            if rn_col_name in unsafe_cols:
                emit_rank_col = String(rn_col_name)

            # Try to extract K from the predicate.
            # MOJO 1.0.0: `rn_schema` / `pb` are projections of the walk above;
            # re-walking `plan._filter` here would invalidate them.
            var k = _try_extract_k(fpd.predicate, rn_col_name)
            if k > 0 and k <= _PARTITION_TOPN_MAX_K:
                # Fuse into PartitionTopN. Rebuild via factory because
                # we are collapsing Filter+PartitionBy -> PartitionTopN
                # (schema and structure both change). Deep-copy the
                # PartitionBy's child (partial-move ban).
                #
                # Thread `func` and `over_fetch_k` into the fused
                # node. For ROW_NUMBER, over_fetch_k = k (no tie buffer).
                # For RANK, over_fetch_k = k + EPSILON tie buffer.
                var pk_copy = pb.partition_keys.copy()
                var ok_copy = pb.order_keys.copy()
                var desc_copy = pb.descending.copy()
                var pb_grandchild = _copy_plan(pb.child[])
                var fused_func: UInt8
                var fused_over_fetch_k: Int
                if is_rank:
                    fused_func = PF_RANK
                    fused_over_fetch_k = k + _PF_RANK_TIE_EPSILON
                else:
                    fused_func = PF_ROW_NUMBER
                    fused_over_fetch_k = k
                plan = LogicalPlan.partition_topn(
                    pk_copy^, ok_copy^, desc_copy^, k, pb_grandchild^,
                    fused_func, fused_over_fetch_k, emit_rank_col^,
                )
        return

    # -- Recurse into all other node types --
    if plan.tag == PLAN_AGGREGATE:
        fuse_partition_topn_inplace(plan._aggregate.value()[].child[], unsafe_cols)

    elif plan.tag == PLAN_JOIN:
        fuse_partition_topn_inplace(plan._join.value()[].left[], unsafe_cols)
        fuse_partition_topn_inplace(plan._join.value()[].right[], unsafe_cols)

    elif plan.tag == PLAN_SORT:
        fuse_partition_topn_inplace(plan._sort.value()[].child[], unsafe_cols)

    elif plan.tag == PLAN_LIMIT:
        fuse_partition_topn_inplace(plan._limit.value()[].child[], unsafe_cols)

    elif plan.tag == PLAN_DISTINCT:
        fuse_partition_topn_inplace(plan._distinct.value()[].child[], unsafe_cols)

    elif plan.tag == PLAN_TOPN:
        fuse_partition_topn_inplace(plan._topn.value()[].child[], unsafe_cols)

    elif plan.tag == PLAN_PARTITION_BY:
        fuse_partition_topn_inplace(plan._partition_by.value()[].child[], unsafe_cols)

    elif plan.tag == PLAN_PARTITION_TOPN:
        fuse_partition_topn_inplace(plan._partition_topn.value()[].child[], unsafe_cols)
    # PLAN_SCAN (leaf) and unknown tags: leave unchanged.


# =============================================================================
# Internal: extract K from a filter predicate
# =============================================================================


def _try_extract_k(pred: Expr, rn_col_name: String) -> Int:
    """Try to extract the limit K from a predicate over the rn column.

    Matches:
      - col(rn_col_name) <= K  ->  K
      - col(rn_col_name) <  K  ->  K - 1

    Returns 0 if the predicate does not match (0 is never a valid K).
    """
    if not pred.is_binary():
        return 0

    var op = pred.binary_op()
    if op != BIN_LE and op != BIN_LT:
        return 0

    # Left side must be a column reference to rn_col_name.
    ref left = pred.binary_left_ref()
    if not left.is_col_ref():
        return 0
    if left.col_ref_name() != rn_col_name:
        return 0

    # Right side must be an integer literal.
    ref right = pred.binary_right_ref()
    if not right.is_literal():
        return 0
    var sv = right.literal_value()
    if sv.dtype != DType.int64 and sv.dtype != DType.int32:
        return 0

    var int_val = Int(sv.int_val)
    if op == BIN_LE:
        if int_val >= 1:
            return int_val
        return 0
    elif op == BIN_LT:
        if int_val >= 2:
            return int_val - 1
        return 0
    return 0
