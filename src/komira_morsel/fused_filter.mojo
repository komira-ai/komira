# =============================================================================
# Fused multi-conjunct filter -- parquet late-mat helper
# =============================================================================
#
# Bridges `komira_column_kernels.fused_predicate` (the SIMD kernel) with the
# parquet morsel source filter loop in `parquet_morsel_source.mojo`.
#
# Detection contract:
#   Input: List[Expr] -- the resolved decode-filter stages (each stage is
#          one binary-op tree; multi-AND chains are nested inside one
#          stage as a BIN_AND tree, since `_and_combine_filters` flattens
#          per-OP_FILTER predicates into a single combined Expr).
#   We walk every stage, flattening BIN_AND into leaf comparisons. For
#   each leaf:
#     * tag must be EXPR_BINARY_OP
#     * op must be one of {EQ, NE, LT, LE, GT, GE}
#     * left must be EXPR_COL_REF (or alias to one)
#     * right must be EXPR_LITERAL with int64 OR float64 value
#     * resolved column type must be INT64 OR FLOAT64
#   Each leaf is bucketed into either the int_conjuncts list (INT64 col)
#   or the float_conjuncts list (FLOAT64 col). If every leaf qualifies
#   AND the total count <= FUSED_MAX_CONJUNCTS, we emit both lists and
#   dispatch to `fused_eval_and_mixed`. Else, return None and the caller
#   takes the per-stage `_eval_predicate` loop.
#
#   Mixed-kernel rationale: TPC-H Q6's chain is 2 INT64 conjuncts on
#   l_shipdate + 3 FLOAT64 conjuncts on l_discount/l_quantity; an INT64-
#   only or FLOAT64-only fused path can't fire on it. The mixed kernel
#   handles K + M conjuncts in one byte-walking pass.
#
# Called only from `ParquetMorselSource._decode_with_late_mat` filter
# loop. Kept in this module (not the source file) because the source
# file is already 1615 lines (over the 1000-line guidance).
# =============================================================================

from komira_arrow.schema import RecordBatch
from komira_arrow.boolean_array import BooleanArray
from komira_arrow.arrow_types import ArrowType
from komira_arrow.primitive_array import PrimitiveArray

from komira_plan_expr.expr import (
    Expr,
    EXPR_BINARY_OP,
    EXPR_COL_REF,
    EXPR_COL_IDX,
    EXPR_LITERAL,
    EXPR_ALIAS,
    BIN_AND,
)
from komira_column_kernels.fused_predicate import (
    ConjunctDescI64,
    ConjunctDescF64,
    FUSED_MAX_CONJUNCTS,
    fused_eval_and_int64,
    fused_eval_and_float64,
    fused_eval_and_mixed,
    fused_op_from_bin_op,
)
from komira_column_kernels.compiler_helpers import resolve_col_index

from komira_plan_expr.expr_id import ExprId
from komira_plan_expr.expr_pool import ExprPool


# =============================================================================
# Internal: walk a single stage's Expr tree, AND-flatten leaves into the
# matching int / float bucket.
#
# Returns False if the stage contains anything outside the supported shape
# (e.g. OR, NOT, string compare, computed RHS, INT32). Both bucket lists
# are then in an indeterminate state; the caller MUST discard them and
# fall back.
# =============================================================================


def _try_collect_conjuncts_from_expr(
    expr: Expr,
    batch: RecordBatch,
    mut int_conjuncts: List[ConjunctDescI64],
    mut float_conjuncts: List[ConjunctDescF64],
) raises -> Bool:
    """Recursively flatten BIN_AND nodes into individual conjuncts,
    bucketing each leaf into int_conjuncts (INT64 col) or float_conjuncts
    (FLOAT64 col).

    Returns True iff the entire subtree is a flat AND-chain of supported
    INT64/FLOAT64 col-vs-literal comparisons. On False, both bucket lists
    are in an indeterminate state and the caller must discard.
    """
    # AND -- recurse into both children.
    if expr.tag == EXPR_BINARY_OP and expr.binary_op() == BIN_AND:
        if not _try_collect_conjuncts_from_expr(
            expr.binary_left_ref(), batch, int_conjuncts, float_conjuncts
        ):
            return False
        if not _try_collect_conjuncts_from_expr(
            expr.binary_right_ref(), batch, int_conjuncts, float_conjuncts
        ):
            return False
        return True

    # Leaf -- must be a comparison op.
    if expr.tag != EXPR_BINARY_OP:
        return False

    var op = expr.binary_op()
    var fused_op_int = fused_op_from_bin_op(op)
    if fused_op_int < 0:
        return False

    # Left must be a column reference (allow alias wrapper).
    var left_expr_tag = expr.binary_left_ref().tag
    if (
        left_expr_tag != EXPR_COL_REF
        and left_expr_tag != EXPR_COL_IDX
        and left_expr_tag != EXPR_ALIAS
    ):
        return False

    # Right must be a literal.
    if expr.binary_right_ref().tag != EXPR_LITERAL:
        return False

    # Resolve the column.
    var col_idx = resolve_col_index(expr.binary_left_ref(), batch.schema)
    ref col = batch.column_at(col_idx)

    # ⛔⛔ A NULLABLE COLUMN REFUSES THE FUSED PATH (2026-09-11), AND THIS IS A
    # WRONG-ROW-SET FIX, NOT A TUNING CHOICE.
    #
    # `fused_predicate.mojo` is 622 lines and the words "validity" and "null"
    # do not appear in any of them: the kernel walks the DATA plane at byte
    # granularity and never sees a validity bitmap. Over a NON-nullable column
    # that is exactly right and is the whole point. Over a NULLABLE one it
    # compares WHATEVER BYTES THE DECODER LEFT IN THE NULL LANE against the
    # threshold, and a null lane that reads as 0.0 satisfies `v > -inf AND
    # v < inf` — so the row SURVIVES a filter that under SQL 3VL must reject
    # it (UNKNOWN is not TRUE).
    #
    # ⚠ MEASURED THROUGH THE SHIPPED `.so`, and the way it surfaced is worth
    # keeping because it is how this stayed hidden:
    # an internal Bazel target, cell
    # `filter_isfinite` — `SELECT k FROM F WHERE isfinite(v)` returned
    # survivors [0, 4, 5, 6] where DuckDB v1.5.3 gives [0, 4, 5]; row 6 is the
    # NULL. Its two SIBLINGS in the same fixture were both CORRECT:
    # `isinf(v)` desugars to an OR and `isnan(v)` to a NOT, neither of which
    # this collector accepts, so both fell back to the validity-honouring
    # `_eval_predicate` loop. ⇒ ONLY the pure AND-of-comparisons shape reaches
    # this kernel, and only `isfinite` answers TRUE on a 0.0 payload — one of
    # three arms wrong, which reads like a bug in one function and is not.
    #
    # ⛔ IT IS NOT AN `isfinite` BUG AND THE SCOPE IS MUCH WIDER: ANY
    # `WHERE a > x AND a < y` over a NULLABLE INT64/FLOAT64 column on the
    # late-mat path has the same silent wrong row set. TPC-H q6/q11/q15 — the
    # benches this lever was built for — declare their columns NOT NULL, which
    # is precisely why the kernel could ship validity-blind and stay green.
    #
    # ⚠ REFUSING HERE COSTS THOSE BENCHES NOTHING, and that is the reason the
    # guard is a REFUSAL rather than a validity-aware kernel: a non-nullable
    # column has no bitmap, `has_validity_buffer()` is False, and the fused
    # path is taken exactly as before. Teaching the kernel 3VL would be a
    # SECOND implementation of the null policy that `kleene_cmp_finalize`
    # already owns, in a hand-staged byte loop, for a case the hot path does
    # not have.
    if col.has_validity_buffer():
        return False

    # Bucket on column type. INT64 and FLOAT64 are supported.
    var lit = expr.binary_right_ref().literal_value()
    var total = len(int_conjuncts) + len(float_conjuncts)
    if total >= FUSED_MAX_CONJUNCTS:
        return False

    if col.arrow_type == ArrowType.INT64:
        # Literal must be coercible to int64. The planner emits
        # int_val for INT64 literals; reject FLOAT64 literals against
        # an INT64 column to avoid silent truncation.
        if not lit.is_int():
            return False
        int_conjuncts.append(
            ConjunctDescI64(col_idx, UInt8(fused_op_int), lit.int_val)
        )
        return True

    if col.arrow_type == ArrowType.FLOAT64:
        # Allow either int_val or float_val literal; widen int->float.
        # Q6 has `l_quantity < 24` where 24 is an int literal but the
        # column is FLOAT64; the planner may emit it either way.
        var thresh: Float64
        if lit.is_float():
            thresh = lit.float_val
        elif lit.is_int():
            thresh = Float64(lit.int_val)
        else:
            return False
        float_conjuncts.append(
            ConjunctDescF64(col_idx, UInt8(fused_op_int), thresh)
        )
        return True

    return False


# =============================================================================
# Public API: try the fused mixed INT64+FLOAT64 path.
#
# Returns Some(BooleanArray) iff the full stage list is a flat AND-chain
# of INT64/FLOAT64 col-vs-literal comparisons. Else returns None and the
# caller takes the legacy per-stage `_eval_predicate` loop.
#
# A successful call replaces:
#   * len(stages) BooleanArray allocations (one per `_eval_predicate`)
#   * (len(stages) - 1) eval_and BooleanArray allocations
#   * (len(stages) - 1) bitmap-AND passes
#   * (len(stages) - 1) true_count zero-mask short-circuit checks
# with one BooleanArray allocation + one fused SIMD pass.
#
# Naming: the function name keeps the historic `_int64` suffix so call
# sites stay unchanged. It now dispatches to the mixed kernel underneath
# (which itself short-circuits to the pure-int or pure-float specialization
# when one bucket is empty), so the fused fast path covers both Q6
# (mixed) and q11/q15/q17 (pure INT64) without touching parquet_morsel_source.
# =============================================================================


# Fused-kind tags returned by `try_fused_eval`. Used by the caller to
# bump per-kind counters (latemat_fused_int64_fired vs
# latemat_fused_float64_fired). The "mixed" case (int + float) bumps the
# float counter — the win is gating on the FLOAT64 extension.
comptime FUSED_KIND_NONE: UInt8 = 0
comptime FUSED_KIND_INT64: UInt8 = 1
comptime FUSED_KIND_FLOAT64: UInt8 = 2
comptime FUSED_KIND_MIXED: UInt8 = 3


struct FusedEvalResult(Movable):
    """Return value of `try_fused_eval`.

    `kind` reports which conjunct shape fired so the caller can bump the
    matching counter. `mask` is wrapped in Optional so the caller can
    extract it with `take_mask()` without violating the partial-move-out-
    of-struct-field rule (a field is never moved out of the middle of a struct).
    """
    var kind: UInt8
    var mask: Optional[BooleanArray]

    @always_inline
    def __init__(out self, kind: UInt8, var mask: BooleanArray):
        self.kind = kind
        self.mask = Optional[BooleanArray](mask^)

    @always_inline
    def take_mask(mut self) -> BooleanArray:
        """Extract the BooleanArray, leaving the struct in a destructor-
        safe (None) state. Safe to drop the struct afterward.
        """
        return self.mask.take()


def try_fused_eval(
    pool: ExprPool,
    stages: List[ExprId],
    batch: RecordBatch,
) raises -> Optional[FusedEvalResult]:
    """Try the fused multi-conjunct kernel (INT64 + FLOAT64 + mixed).

    Args:
        pool:   ExprPool to resolve `stages` against.
        stages: List of decode-filter stage ExprIds.
        batch:  The just-decoded filter columns RecordBatch. Every stage's
                column references must resolve into this batch (which is
                the contract of the late-mat filter loop -- the caller
                only decoded `filter_cols` covering exactly the stages'
                referenced columns).

    Returns:
        Some(FusedEvalResult) on fused-path success, with `kind` set to
        FUSED_KIND_INT64 / FUSED_KIND_FLOAT64 / FUSED_KIND_MIXED.
        None if any stage falls outside the supported shape.
    """
    if len(stages) == 0:
        return None

    var int_conjuncts = List[ConjunctDescI64]()
    var float_conjuncts = List[ConjunctDescF64]()
    for i in range(len(stages)):
        ref stg = pool.resolve(stages[i])
        if not _try_collect_conjuncts_from_expr(
            stg, batch, int_conjuncts, float_conjuncts
        ):
            return None

    var n_int = len(int_conjuncts)
    var n_flt = len(float_conjuncts)
    var total = n_int + n_flt
    if total == 0 or total > FUSED_MAX_CONJUNCTS:
        return None

    # Single-conjunct case: the fused kernel has no advantage over the
    # comptime-specialized `_eval_cmp_*` kernels (it would just add a
    # dynamic op-dispatch branch in the inner loop). Bench validation
    # showed a small regression on q11 (~+0.27 ms / +4.7%)
    # when N=1 took the fused path. Reserve this path for the
    # multi-conjunct case where its win materializes.
    if total == 1:
        return None

    var n_rows = batch.num_rows()
    var ba = fused_eval_and_mixed(
        batch, int_conjuncts, float_conjuncts, n_rows
    )

    var kind: UInt8
    if n_int > 0 and n_flt > 0:
        kind = FUSED_KIND_MIXED
    elif n_flt > 0:
        kind = FUSED_KIND_FLOAT64
    else:
        kind = FUSED_KIND_INT64
    return Optional[FusedEvalResult](FusedEvalResult(kind, ba^))


# Legacy alias kept for any external consumer that used the v0.4-pre name.
# Identical semantics to `try_fused_eval` minus the kind tag (caller treats
# as INT64-only). The parquet morsel source migrates to `try_fused_eval`
# directly so it can disambiguate the int / float / mixed paths.
def try_fused_eval_int64(
    pool: ExprPool,
    stages: List[ExprId],
    batch: RecordBatch,
) raises -> Optional[BooleanArray]:
    """Legacy entry point. New callers should use `try_fused_eval`."""
    var res_opt = try_fused_eval(pool, stages, batch)
    if not res_opt:
        return None
    var res = res_opt.take()
    return Optional[BooleanArray](res.take_mask())
