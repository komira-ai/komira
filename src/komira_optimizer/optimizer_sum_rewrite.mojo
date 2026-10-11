# =============================================================================
# optimizer_sum_rewrite.mojo -- SUM(x + C)  ->  SUM(x) + C * COUNT(x)
# =============================================================================
#
# DuckDB's `SumRewriterOptimizer` (`src/optimizer/sum_rewriter.cpp`), ported.
#
# ⛔⛔ THIS PASS IS HALF OF A PAIR AND IS A PESSIMISATION ON ITS OWN.
# ==================================================================
# It emits ONE `SUM(x)` PER MATCHED AGGREGATE plus ONE `COUNT(x)` per non-zero
# offset, i.e. UP TO 2N AGGREGATES WHERE THERE WERE N. What makes that a win is
# `dedup_common_aggregates` (`optimizer_agg_cse.mojo`), designed to run
# immediately after and collapse the structurally-identical ones: for ClickBench
# cbq29 (`SELECT sum(rw), sum(rw+1), ... sum(rw+89)`) this pass produces **179**
# aggregates and the dedup collapses them to **2**. komira_optimizer has no
# driver that orders its passes; the order this pass is designed for is this
# pass, then the dedup. Without the dedup the plan carries up to 2N aggregates
# where it had N; do not fund, move or gate one without the other.
#
# WHY IT IS WORTH ANYTHING AT ALL
# ===============================
# `sum(rw + 1)` is a SUM over a COMPUTED input, so `materialize_agg_input`
# (a pass designed to run after this one, not in this tree) mints a `__agg_in_<k>` column for
# it and splices a Project below the aggregate to materialise it. At 90
# aggregates that is 90 derived columns, and it also pushes the aggregate's
# child from a bare SCAN to a PROJECT.
#
# After the rewrite, every aggregate input is the RAW column: nothing is
# materialised and the aggregate's child stays the SCAN.
#
# SCOPE -- ALL FOUR GATES ARE LOAD-BEARING
# ========================================
#  1. **0-KEY ONLY** (`len(group_by) == 0`). A GROUPED `sum(x+C)` is still
#     algebraically rewritable, but the post-aggregate arithmetic then runs
#     per GROUP rather than over one row, so the win stops being free and the
#     `COUNT` it adds is a real per-group accumulator. DuckDB's own rewriter is
#     likewise restricted. ⚠ The 1-row output is exactly what makes the Project
#     this pass splices ABOVE the aggregate cost nothing.
#  2. **INTEGRAL ONLY** -- the aggregand column's dtype must be a signed
#     int8/16/32/64 or an unsigned int8/16/32, AND the offset must be an
#     INTEGER literal. ⛔ NOT FLOATS: `sum(x + 1.0)` and `sum(x) + 1.0*count(x)`
#     differ in IEEE-754 rounding, so the rewrite would change the answer.
#     ⛔ NOT uint64: a `uint64` sum + a signed offset is a mixed-sign promotion
#     question this pass declines to answer.
#  3. **PLAIN COLUMN AGGREGAND** -- `sum(f(x) + C)` is declined. The offset has
#     to be added to a NAMED column, because the `COUNT` half has to count the
#     non-NULL rows OF THAT SAME INPUT and the only way to say so without
#     materialising anything is a col_ref.
#  4. **AT LEAST ONE NON-ZERO OFFSET.** A bare `sum(x)` is admitted as an
#     offset-0 match so it shares the deduped `SUM(x)` helper -- but if NOTHING
#     in the node carries an offset the pass DECLINES OUTRIGHT rather than
#     convert `sum(x)` into `sum(x)` + a pointless Project.
#
# NULL SEMANTICS -- WHY `COUNT(x)` AND NOT `COUNT(*)`
# ===================================================
# `sum(x + C)` skips rows where `x` IS NULL. `COUNT(x)` counts non-NULL `x`
# (standard SQL), so
# `sum(x) + C*count(x)` skips exactly the same rows. `COUNT(*)` would count the
# NULL rows too and answer `C` too high per NULL. Over an all-NULL or empty
# input `sum(x)` is NULL and `NULL + C*0` is NULL -- which is what `sum(x + C)`
# answers. `test_optimizer_sum_rewrite_gates.mojo` pins that the replacement
# is `COUNT(x)`, not `COUNT(*)`.
#
# ⚠ RESIDUAL, STATED RATHER THAN GUARDED: the rewrite is exact in Int64 whenever
# `sum(x)` itself is representable. A pathological input whose `x` values
# overflow Int64 while `x + C` does not (huge positive `x`, huge negative `C`)
# would diverge. `|C|` is bounded to Int32 range here, which removes the half of
# that hazard this pass creates; the other half is `sum(x)` overflow, which
# DuckDB's rewriter carries identically.
# =============================================================================

from std.collections import List, Optional

from komira_plan_expr.scalar_value import ScalarValue
from komira_plan_expr.expr import (
    Expr,
    EXPR_ALIAS,
    EXPR_BINARY_OP,
    EXPR_COL_REF,
    EXPR_LITERAL,
    BIN_ADD,
    BIN_SUB,
    BIN_MUL,
)
from komira_plan_expr.agg_expr import AggExpr, AGG_SUM, AGG_COUNT
from komira_plan_ir.logical_plan import (
    LogicalPlan,
    ExprArray,
    AggExprArray,
    PLAN_AGGREGATE,
    PLAN_FILTER,
    PLAN_PROJECT,
    PLAN_JOIN,
    PLAN_SORT,
    PLAN_LIMIT,
    PLAN_DISTINCT,
    PLAN_TOPN,
)
from komira_plan_ir.plan_helpers import _copy_plan


comptime _SR_OFFSET_ABS_MAX: Int64 = 2147483647
"""Largest |C| this pass will fold. See the RESIDUAL note in the header."""


# =============================================================================
# Helpers
# =============================================================================


def _stripped_col_name(imm e: Expr) -> Optional[String]:
    """The column name `e` names, after stripping EXPR_ALIAS wrappers.

    ⛔ EXPR_COL_IDX is DELIBERATELY not accepted: this pass has to write the
    name into a NEW `col_ref` (in the `COUNT(x)` it mints) and has to look the
    dtype up by name in the child schema. A positional reference gives neither.
    """
    if e.tag == EXPR_COL_REF:
        return Optional[String](String(e.col_ref_name()))
    if e.tag == EXPR_ALIAS:
        return _stripped_col_name(e.alias_child_ref())
    return Optional[String](None)


def _int_literal(imm e: Expr) -> Optional[Int64]:
    """The Int64 value of an integer literal, or None."""
    if e.tag != EXPR_LITERAL:
        return Optional[Int64](None)
    var sv = e.literal_value()
    if not sv.is_int():
        return Optional[Int64](None)
    return Optional[Int64](sv.int_val)


def _is_foldable_integral(dt: DType) -> Bool:
    """Gate 2 of the header: the dtypes whose SUM this pass will re-associate."""
    return (
        dt == DType.int8
        or dt == DType.int16
        or dt == DType.int32
        or dt == DType.int64
        or dt == DType.uint8
        or dt == DType.uint16
        or dt == DType.uint32
    )


def _column_is_foldable(imm plan: LogicalPlan, imm name: String) -> Bool:
    """True iff `name` is a column of `plan`'s output schema with a dtype this
    pass will re-associate. An unknown name answers False (decline)."""
    ref schema = plan.output_schema
    for i in range(schema.num_columns()):
        if schema.field_name(i) == name:
            return _is_foldable_integral(schema.field_dtype(i))
    return False


def _match_sum_offset(
    imm ae: AggExpr,
    imm child: LogicalPlan,
    mut out_col: String,
    mut out_offset: Int64,
) -> Bool:
    """Does `ae` match `SUM(<col>)`, `SUM(<col> + C)`, `SUM(C + <col>)` or
    `SUM(<col> - C)` over a foldable integral column?

    On True, `out_col` is the column name and `out_offset` is C (0 for the bare
    form, negative for the subtract form).
    """
    if ae.func != AGG_SUM:
        return False
    if not ae.child:
        return False
    if Bool(ae.child1) or Bool(ae.child2) or Bool(ae.child3):
        return False

    ref e = ae.child.value()

    # --- the bare `SUM(col)` form: offset 0, admitted so it SHARES the deduped
    # `SUM(col)` helper rather than standing as a 91st aggregate. ---
    var bare = _stripped_col_name(e)
    if bare:
        if not _column_is_foldable(child, bare.value()):
            return False
        out_col = bare.value()
        out_offset = 0
        return True

    if e.tag != EXPR_BINARY_OP:
        return False
    var op = e.binary_op()
    if op != BIN_ADD and op != BIN_SUB:
        return False

    ref lhs = e.binary_left_ref()
    ref rhs = e.binary_right_ref()

    var col_name = _stripped_col_name(lhs)
    var offset = _int_literal(rhs)
    if col_name and offset:
        # `col + C` / `col - C`
        var c = offset.value()
        if op == BIN_SUB:
            c = -c
        if c > _SR_OFFSET_ABS_MAX or c < -_SR_OFFSET_ABS_MAX:
            return False
        if not _column_is_foldable(child, col_name.value()):
            return False
        out_col = col_name.value()
        out_offset = c
        return True

    if op != BIN_ADD:
        # ⛔ `C - col` is NOT handled. It IS algebraically foldable
        # (`C*count(col) - sum(col)`), but it inverts the SIGN of the sum term
        # rather than of the offset term, which this pass's uniform
        # `sum + C*count` shape cannot express. Declining is a no-op; getting
        # the sign wrong is a wrong answer.
        return False

    var col_name_r = _stripped_col_name(rhs)
    var offset_l = _int_literal(lhs)
    if col_name_r and offset_l:
        var c2 = offset_l.value()
        if c2 > _SR_OFFSET_ABS_MAX or c2 < -_SR_OFFSET_ABS_MAX:
            return False
        if not _column_is_foldable(child, col_name_r.value()):
            return False
        out_col = col_name_r.value()
        out_offset = c2
        return True

    return False


# =============================================================================
# Rule: rewrite_sum_of_offset
# =============================================================================


def rewrite_sum_of_offset(var plan: LogicalPlan) raises -> LogicalPlan:
    """Wrapper around `rewrite_sum_of_offset_inplace`."""
    rewrite_sum_of_offset_inplace(plan)
    return plan^


def rewrite_sum_of_offset_inplace(mut plan: LogicalPlan) raises:
    """Walk the plan, rewriting every eligible 0-key `SUM(x + C)` aggregate.

    Children are rewritten FIRST so a nested aggregate is settled before its
    parent is inspected. The node kinds walked mirror
    `materialize_agg_input_inplace` (not in this tree); a kind not walked
    simply does not fold.
    """
    if plan.tag == PLAN_AGGREGATE:
        rewrite_sum_of_offset_inplace(plan._aggregate.value()[].child[])
        _maybe_rewrite_sum_offsets(plan)
    elif plan.tag == PLAN_FILTER:
        rewrite_sum_of_offset_inplace(plan._filter.value()[].child[])
    elif plan.tag == PLAN_PROJECT:
        rewrite_sum_of_offset_inplace(plan._project.value()[].child[])
    elif plan.tag == PLAN_JOIN:
        rewrite_sum_of_offset_inplace(plan._join.value()[].left[])
        rewrite_sum_of_offset_inplace(plan._join.value()[].right[])
    elif plan.tag == PLAN_SORT:
        rewrite_sum_of_offset_inplace(plan._sort.value()[].child[])
    elif plan.tag == PLAN_LIMIT:
        rewrite_sum_of_offset_inplace(plan._limit.value()[].child[])
    elif plan.tag == PLAN_DISTINCT:
        rewrite_sum_of_offset_inplace(plan._distinct.value()[].child[])
    elif plan.tag == PLAN_TOPN:
        rewrite_sum_of_offset_inplace(plan._topn.value()[].child[])


def _analyze(
    imm plan: LogicalPlan,
    mut matched: List[Bool],
    mut cols: List[String],
    mut offsets: List[Int64],
) -> Int:
    """Fill the per-aggregate match tables. Returns the number of matches whose
    offset is NON-ZERO -- 0 means DECLINE (gate 4 of the header).

    ⚠ ONE interior reference into `plan._aggregate`, held for the whole scan.
    Re-forming it mid-walk invalidates the first (the standing plan-rewrite
    trap); every result this leaves behind is an OWNED value.
    """
    ref agg_data = plan._aggregate.value()[]
    if agg_data.has_udf():
        return 0
    if len(agg_data.group_by) != 0:
        return 0
    if agg_data.group_topk:
        return 0
    var n = len(agg_data.agg_exprs)
    if n < 1:
        return 0

    var n_offset = 0
    for i in range(n):
        var col = String("")
        var off = Int64(0)
        var ok = _match_sum_offset(
            agg_data.agg_exprs[i], agg_data.child[], col, off
        )
        matched.append(ok)
        cols.append(col^)
        offsets.append(off)
        if ok and off != 0:
            n_offset += 1
    return n_offset


def _build_rewrite(
    imm plan: LogicalPlan,
    imm matched: List[Bool],
    imm cols: List[String],
    imm offsets: List[Int64],
    mut new_aggs: AggExprArray,
    mut proj_exprs: ExprArray,
) raises -> LogicalPlan:
    """Build the replacement aggregate list + the post-aggregate projection,
    and return a deep copy of the aggregate's child.

    The projection's output names are read off `plan.output_schema`, NOT
    re-derived -- `LogicalPlan.aggregate` disambiguates duplicate auto-generated
    agg names (`sum`, `sum_1`, ...) and the whole point of this rewrite is that
    the node's OUTPUT SCHEMA does not move.
    """
    # Output names FIRST, while nothing is borrowed through `_aggregate`.
    var out_names = List[String]()
    for i in range(plan.output_schema.num_columns()):
        out_names.append(plan.output_schema.field_name(i))

    ref agg_data = plan._aggregate.value()[]
    var n = len(agg_data.agg_exprs)
    var seq = 0
    for i in range(n):
        if matched[i]:
            var sname = String("__sr_s") + String(seq)
            new_aggs.append(
                AggExpr(
                    AGG_SUM,
                    Optional[Expr](Expr.col_ref(cols[i])),
                    Optional[String](sname),
                )
            )
            if offsets[i] == 0:
                proj_exprs.append(
                    Expr.alias(Expr.col_ref(sname), out_names[i])
                )
            else:
                var cname = String("__sr_c") + String(seq)
                new_aggs.append(
                    AggExpr(
                        AGG_COUNT,
                        Optional[Expr](Expr.col_ref(cols[i])),
                        Optional[String](cname),
                    )
                )
                var term = Expr.binary(
                    BIN_MUL,
                    Expr.literal(ScalarValue.from_int64(offsets[i])),
                    Expr.col_ref(cname),
                )
                proj_exprs.append(
                    Expr.alias(
                        Expr.binary(BIN_ADD, Expr.col_ref(sname), term^),
                        out_names[i],
                    )
                )
            seq += 1
        else:
            # An aggregate this pass does not touch still has to keep its place
            # AND its output name. It is re-aliased to a private name and the
            # projection renames it back, so the node's output schema is
            # byte-identical to what it was.
            var kname = String("__sr_k") + String(i)
            var kept = agg_data.agg_exprs[i].copy()
            kept.alias_name = Optional[String](kname)
            new_aggs.append(kept^)
            proj_exprs.append(Expr.alias(Expr.col_ref(kname), out_names[i]))

    return _copy_plan(agg_data.child[])


def _maybe_rewrite_sum_offsets(mut plan: LogicalPlan) raises:
    """`plan` is a PLAN_AGGREGATE. Rewrite it if it qualifies."""
    var matched = List[Bool]()
    var cols = List[String]()
    var offsets = List[Int64]()
    if _analyze(plan, matched, cols, offsets) == 0:
        return

    var new_aggs = AggExprArray()
    var proj_exprs = ExprArray()
    var child_copy = _build_rewrite(
        plan, matched, cols, offsets, new_aggs, proj_exprs
    )

    var new_agg_plan = LogicalPlan.aggregate(
        ExprArray(), new_aggs^, child_copy^
    )
    plan = LogicalPlan.project(proj_exprs^, new_agg_plan^)
