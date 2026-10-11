# =============================================================================
# Selection-vector conjunction narrowing
# =============================================================================
#
# The `evaluate_conjunction_select` + `evaluate_predicate_selected` pair.
#
# Intent: evaluating `A AND B AND C AND ...` naively runs every conjunct over
# all N batch rows, even though later conjuncts only need to look at the rows
# that survived the earlier ones. This narrows a SelectionVector conjunct by
# conjunct, evaluating each new predicate only on the surviving rows — a
# 1.5-2x speedup on wide-table filters.
#
# Depends on eval_predicate and compiler_helpers.
# =============================================================================

from komira_arrow.bitmap import Bitmap
from komira_arrow.boolean_array import BooleanArray
from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.record_batch import RecordBatch
from komira_arrow.selection_vector import SelectionVector
from komira_buffer.heap_region import HeapRegion
from komira_collections.slab import Slab
from komira_column_kernels.arithmetic import eval_and, eval_not, eval_or
from komira_column_kernels.cast_null import bitmap_and
from komira_column_kernels.compiler_helpers import gather_batch
from komira_plan_expr.expr import (
    BIN_AND,
    BIN_OR,
    EXPR_BINARY_OP,
    EXPR_UNARY_OP,
    Expr,
    UN_NOT,
)
from komira_scalar_arithmetic.int_overflow import is_int_overflow_error

from .arm_rows import batch_nulled_outside, undecided_rows
from .eval_predicate import _eval_predicate
from .predicate_null_scope import _compute_predicate_input_validity_scoped


# =============================================================================
# ⛔⛔ ONE MASK PER CONJUNCT CANNOT EXPRESS THREE-VALUED LOGIC
# =============================================================================
#
#     WHERE v > 35 AND (tag LIKE 'x%' OR note = 'zzz')
#
# `flatten_and_conjuncts` splits only AND, so a disjunction is ONE conjunct.
# AND-ing the validity of every column the conjunct mentions (`{tag, note}`)
# into one mask would mask BOTH OR arms by BOTH columns' validity, and the rows
# where `note` IS NULL would fall out of an arm about `tag` — yet `TRUE OR NULL`
# is TRUE in SQL, so they belong in the answer. The scope derivation
# (`predicate_null_scope_unhandled_tag`) is complete here; the defect would be
# the conjunct-level mask itself, which is why the fix lives in this function
# and every caller of it (`evaluate_filter_narrowed`,
# `evaluate_predicate_selected`) inherits it.
#
# ── ★ THE MECHANISM: NO CONJUNCT-LEVEL MASK ──────────────────────────────────
#
# `_predicate_3vl` descends the BOOLEAN CONNECTIVES — AND, OR, NOT — and
# applies each LEAF's own input validity as that leaf's VALIDITY rather than
# AND-ing it into a whole-conjunct result. The connectives are then combined by
# `eval_and` / `eval_or` / `eval_not`, which are Kleene-correct
# (`komira_column_kernels/arithmetic.mojo`); ONE collapse at the very top turns
# UNKNOWN into FALSE, which is the Arrow filter boundary this file exists to
# enforce.
#
# ⚠ SCOPE: this covers `_predicate_3vl`, reached through exactly two entry
# points in THIS file: `evaluate_filter_narrowed` and
# `evaluate_predicate_selected`. A site that calls `_eval_predicate` itself is
# not covered by it; `eval_predicate`'s own short-circuit AND / OR
# carry the same `not l.validity` guard for that reason.
#
# ⛔ WHAT MAY NOT BE "SIMPLIFIED" AWAY — each named with the test that goes RED
# when it is deleted:
#
#   * THE `BIN_OR` DESCENT ->
#     `test_filter_disjunction_keeps_TRUE_OR_NULL_rows`
#     (`tests/test_filter_null_collapse_semantics.mojo`).
#   * THE `UN_NOT` AND `BIN_AND` DESCENTS ->
#     `test_filter_negated_conjunction_keeps_the_FALSE_AND_NULL_rows`, same
#     file. `FALSE AND UNKNOWN` is a KNOWN false, so its negation is TRUE; hand
#     either node to `_eval_predicate` whole and that row is masked out by a
#     validity the AND had already consumed.
#   * THE LEAF MASK ITSELF — i.e. that `_leaf_3vl` folds `input_validity` into
#     the result's VALIDITY and NOT into its DATA. Folding it into DATA turns
#     the negated cells red (`test_filter_negated_conjunction_keeps_the_FALSE_
#     AND_NULL_rows` and the `_with_the_NULL_ARM_FIRST_*` pair), while
#     `test_filter_disjunction_keeps_TRUE_OR_NULL_rows` STAYS GREEN: the OR case
#     is fixed by the DESCENT, and VALIDITY-vs-DATA is only observable where
#     UNKNOWN and FALSE differ, which at a filter boundary is EXACTLY under a
#     `NOT`. ⇒ The descent and the folding are TWO mechanisms; do not cite one
#     cell for both.
#     Deleting `_leaf_3vl`'s `input_validity` merge ENTIRELY also breaks the
#     numeric-dictionary LUT filter (`test_numeric_dict_filter_lut_p3`): a
#     comparison kernel that returns a NON-nullable BooleanArray leaves its bits
#     at NULL rows as whatever the SIMD compare read out of the raw data buffer.
#     ⚠ The `test_filter_null_collapsed_*` cells stay GREEN without the merge,
#     because `_eval_predicate`'s int/float arms finalize through
#     `kleene_cmp_finalize_scalar` and carry their own validity. Do NOT delete
#     the merge on the evidence that those tests still pass.
#   * THE `not l.validity` GUARD ON THE SHORT-CIRCUITS ->
#     `test_filter_negated_conjunction_with_the_NULL_ARM_FIRST_keeps_its_rows`
#     (the AND half) and
#     `test_filter_negated_disjunction_with_the_NULL_ARM_FIRST_drops_only_UNKNOWN`
#     (the OR half). The NULL-bearing arm must be on the LEFT: the
#     short-circuits key on `l.true_count`, and a leaf that is FALSE-where-known
#     and UNKNOWN elsewhere has `true_count == 0`, so a null-free LEADING arm
#     never reaches the guarded code. The two halves fail in OPPOSITE
#     DIRECTIONS: the AND half LOSES a row, the OR half GAINS one.
#     ⚠ ONLY TWO OF THE FOUR ARMS ARE REACHABLE WITH UNKNOWNS PRESENT: an
#     UNKNOWN row carries DATA BIT 0, so a mask with one unknown row cannot have
#     `true_count == l.length`. The `TRUE AND r` / `TRUE OR r` halves only ever
#     run on a fully-known left mask, where the guard is a no-op.
#
# ── ⚠ THE INVARIANT, AND WHY THE CONNECTIVES DO **NOT** RE-NORMALISE ─────────
#
# Every value flowing through `_predicate_3vl` carries DATA BIT 0 at every
# UNKNOWN row. `_leaf_3vl` establishes it; the three combinators PRESERVE it,
# which is checked here rather than re-imposed with a defensive call that would
# be dead code:
#
#     eval_and   data = l & r      UNKNOWN needs one side unknown -> data 0
#     eval_or    data = l | r      UNKNOWN needs BOTH unknown     -> data 0
#     eval_not   `~v` sets the bit AND `eval_not` re-clears it itself, in the
#                loop its own docstring documents ("data bit 0 is how UNKNOWN
#                reaches a consumer that reads data only").
#
# ⛔ SO DO NOT ADD A `_normalize_3vl` CALL ON THE COMBINATOR RESULTS "TO BE
# SAFE". It would be dead code by the table above. If a future kernel breaks
# the invariant, the fix belongs in that kernel, where a test can see it.
# =============================================================================


def _normalize_3vl(var ba: BooleanArray) raises -> BooleanArray:
    """Restore this repo's UNKNOWN encoding on `ba`: DATA BIT 0, validity says
    why.

    ★ THE ENCODING IS THE REPO'S, NOT THIS FILE'S. It is stated as the
    representation invariant of the whole null-convergence programme
    (*"a row whose value is UNKNOWN carries data bit 0"*) and `eval_not`'s docstring gives the
    reason — the consumer that actually selects rows (`filter_to_indices`)
    walks the DATA bitmap and never reads validity, so an unknown row carrying
    a set data bit is a SELECTED row.

    ⚠ ONE CALL SITE, AND IT IS `_leaf_3vl`. Folding an input-validity bitmap
    into a mask's VALIDITY is the only step in this file that can leave a data
    bit set on an unknown row, and `null_count` is stale the instant that
    happens.

    ⛔⛔ AND ITS DATA HALF IS **REDUNDANT AT THE ANSWER LEVEL TODAY** — said
    here rather than left for a reader to discover, because this tree has
    shipped four fixes running whose argued mechanism no assertion could see.
    `_collapse_nulls_to_false` performs the same `data &= validity` once at the
    top, and the three Kleene combinators are ALGEBRAICALLY INSENSITIVE to a
    set data bit on an unknown row (their validity formulas AND every use of a
    data bit with that side's validity). So deleting this masking changes NO
    row set, and no test in this repo goes red for it. It is kept as an
    INVARIANT-RESTORING step — `_leaf_3vl` replaces `ba.validity` wholesale and
    a struct left inconsistent with its own new validity is a hazard the type
    system cannot see — NOT as a defect-preventing mechanism. Do not describe
    it as one, and do not add a second copy on the combinators.
    """
    if ba.validity:
        var v = ba.validity.take()
        var nc = v.null_count()
        ba.data = bitmap_and(ba.data, v)
        ba.validity = v^
        ba.null_count = nc
    return ba^


def _leaf_3vl(
    var ba: BooleanArray, var input_validity: Optional[Bitmap[HeapRegion]]
) raises -> BooleanArray:
    """Fold a leaf predicate's INPUT-column validity into its OWN validity.

    ⭐ THE ONE-LINE DIFFERENCE FROM `_collapse_nulls_to_false`, AND IT IS THE
    WHOLE FIX. The old funnel ANDed `input_validity` into the result's DATA,
    destroying the distinction between "this row is FALSE" and "this row is
    UNKNOWN" before any enclosing OR could read it. This ANDs it into the
    result's VALIDITY, so the row stays UNKNOWN and `eval_or` can apply
    `TRUE OR UNKNOWN = TRUE`.
    """
    if input_validity:
        var iv = input_validity.take()
        if ba.validity:
            var ov = ba.validity.take()
            ba.validity = bitmap_and(ov, iv)
        else:
            ba.validity = iv^
    return _normalize_3vl(ba^)


def _predicate_3vl(
    expr: Expr, batch: RecordBatch, fallback_all_columns: Bool
) raises -> BooleanArray:
    """Evaluate `expr` over `batch` as a THREE-VALUED predicate.

    Returns a BooleanArray in this repo's UNKNOWN encoding — data bit 0 at
    every unknown row, validity saying which rows those are. The caller turns
    it into a filter mask with ONE `_collapse_nulls_to_false`.

    ⚠ IT DESCENDS ONLY THE BOOLEAN CONNECTIVES. Everything else is a LEAF and
    goes to `_eval_predicate` whole — including a `CASE`, an `IN (...)`, a
    comparison whose LHS is arbitrary arithmetic. That is deliberate: a leaf's
    nullity is a property of the leaf's own inputs, and `_collect_predicate_
    col_refs` is exactly the walk that names them. AND / OR / NOT are the only
    nodes where the ARMS have different null scopes, which is the entire
    defect.

    ⚠ IT IS NOT `_eval_predicate`'s AND/OR PATH AND DOES NOT REPLACE IT.
    `_eval_predicate` keeps its own `_eval_short_circuit_{and,or}` arms for its
    other callers; this reproduces THREE of that pair's four cases —
    `FALSE AND r`, `TRUE AND r`, `TRUE OR r`, `FALSE OR r` — and deliberately
    NOT the fourth, `_eval_short_circuit_and`'s gather-to-survivors case. (That
    scatter copied only DATA bits until so a right-side UNKNOWN
    came back FALSE there; it carries the right's validity now.) At THIS
    funnel the top-level ANDs have already been flattened by
    `flatten_and_conjuncts` and narrowed through the SelectionVector, which is
    the same optimisation one layer up, so what is given up is the case of an
    AND NESTED under an OR or a NOT.

    ⚠ THE FOUR SHORT-CIRCUITS ARE ALGEBRAIC IDENTITIES, i.e. PERF ONLY. Delete
    them and every answer is unchanged — do not expect a test to catch that,
    and do not describe them as correctness machinery. What IS correctness is
    the `not l.validity` guard on each: without it they are wrong, and the
    block above says exactly how.

    Args:
        expr: The predicate.
        batch: The batch to evaluate it over.
        fallback_all_columns: What a leaf whose scope the walk cannot derive
            does — see `_compute_predicate_input_validity_scoped`. Production
            callers pass `True`; `False` is the measurement bound only.

    Returns:
        The three-valued mask, `batch.num_rows` bits wide.
    """
    if expr.tag == EXPR_BINARY_OP:
        var op = expr.binary_op()
        if op == BIN_AND:
            var l = _predicate_3vl(
                expr.binary_left_ref(), batch, fallback_all_columns
            )
            # ⚠ BOTH ARMS ARE FULLY-KNOWN-ONLY, and the guard is the point —
            # see the block above `_normalize_3vl`.
            if not l.validity:
                if l.true_count() == 0:
                    return l^          # FALSE AND r = FALSE
                if l.true_count() == l.length:
                    return _predicate_3vl(
                        expr.binary_right_ref(), batch, fallback_all_columns
                    )                  # TRUE AND r = r
            var r = _predicate_3vl_right(
                expr.binary_right_ref(), batch, fallback_all_columns, l, False
            )
            return eval_and(l, r)
        if op == BIN_OR:
            var l = _predicate_3vl(
                expr.binary_left_ref(), batch, fallback_all_columns
            )
            if not l.validity:
                if l.true_count() == l.length:
                    return l^          # TRUE OR r = TRUE
                if l.true_count() == 0:
                    return _predicate_3vl(
                        expr.binary_right_ref(), batch, fallback_all_columns
                    )                  # FALSE OR r = r
            var r = _predicate_3vl_right(
                expr.binary_right_ref(), batch, fallback_all_columns, l, True
            )
            return eval_or(l, r)
    if expr.tag == EXPR_UNARY_OP and expr.unary_op() == UN_NOT:
        return eval_not(
            _predicate_3vl(expr.unary_child_ref(), batch, fallback_all_columns)
        )

    var raw = _eval_predicate(expr, batch)
    var iv = _compute_predicate_input_validity_scoped(
        expr, batch, fallback_all_columns
    )
    return _leaf_3vl(raw^, iv^)


def _predicate_3vl_right(
    right: Expr,
    batch: RecordBatch,
    fallback_all_columns: Bool,
    imm left: BooleanArray,
    is_or: Bool,
) raises -> BooleanArray:
    """The right arm of an AND / OR under `_predicate_3vl`, asked — only if the
    whole-batch evaluation raises an integer OVERFLOW — of the rows the left arm
    has NOT decided, every other row NULL (; the argument is
    `arm_rows.mojo`'s). The Kleene combine never reads a NULL it introduced."""
    try:
        return _predicate_3vl(right, batch, fallback_all_columns)
    except err:
        if not is_int_overflow_error(String(err)):
            raise err^
    return _predicate_3vl(
        right,
        batch_nulled_outside(batch, undecided_rows(left, is_or)),
        fallback_all_columns,
    )


def _collapse_nulls_to_false(
    var ba: BooleanArray, var input_validity: Optional[Bitmap[HeapRegion]]
) raises -> BooleanArray:
    """Mask `ba.data` so that any NULL position becomes FALSE per Arrow-
    standard filter semantics.

    Steps:
      1. If `ba.validity` is Some → `ba.data &= ba.validity`; drop
         `ba.validity` (treated as non-nullable downstream).
      2. If `input_validity` is Some → `ba.data &= input_validity`.

    The result is a non-nullable BooleanArray whose data bits are FALSE
    at every position where the predicate either returned NULL itself
    or its inputs were NULL.
    """
    if ba.validity:
        # AND data with own validity, drop validity bitmap.
        # Bitmap is non-Copyable; take it out of the Optional rather than
        # implicit-copy via .value. The Optional is left in None state,
        # which matches the explicit reset on the next line.
        var ov = ba.validity.take()
        ba.data = bitmap_and(ba.data, ov^)
        ba.validity = Optional[Bitmap[HeapRegion]](None)
        ba.null_count = 0
    if input_validity:
        ba.data = bitmap_and(ba.data, input_validity.value())
    return ba^


# =============================================================================
# evaluate_predicate_selected — evaluate a predicate only on selected rows
# =============================================================================


def evaluate_predicate_selected(
    batch: RecordBatch,
    expr: Expr,
    sel: SelectionVector,
) raises -> BooleanArray:
    """Evaluate `expr` as a predicate on the rows indicated by `sel`.

    Returns a BooleanArray with `sel.length` bits — one per currently
    surviving row (NOT `batch.num_rows`). Bit `i` is true iff the
    predicate held for the row at `sel.indices[i]`.

    Fast path: when `sel` already covers every row, skip the gather and
    evaluate on the original batch directly.

    Slow path (narrowed): gather input columns at the selected indices into
    a dense mini-batch, then call `_eval_predicate` on the mini-batch. The
    result has `sel.length` rows; row `i` corresponds to `sel.indices[i]`.
    """
    var num_rows = batch.num_rows()
    var sel_len = sel.length()

    if sel_len == num_rows:
        # Full-cover selection: no gather needed.
        # NULL-collapse, per BOOLEAN LEAF: `_predicate_3vl` descends AND/OR/NOT and
        # scopes each leaf's nulls to that leaf's own columns, so the ONE
        # collapse here only has UNKNOWN -> FALSE left to do. Handing this
        # function a whole-conjunct `input_validity` is what lost the
        # `TRUE OR NULL` rows; see the block above `_normalize_3vl`.
        var m = _predicate_3vl(expr, batch, True)
        return _collapse_nulls_to_false(m^, None)

    # Materialize the selected-rows sub-batch once; all columns are gathered
    # together. `_gather_batch`
    # copies bytes for every column — an unavoidable cost of narrowing.
    # Z.4-continue: migrated `sel.indices._unsafe_data_ptr` onto
    # `sel.indices.get_typed[Scalar[DType.int32]]`.
    #
    # `capacity=sel_len` is not a nicety: the exact final size is known here,
    # and without it this `append` loop walks List's doubling schedule and
    # re-copies the whole index vector log2(sel_len) times. Measured on a
    # compound-AND filter, that growth costs
    # 8.4 Mcyc/rep -- 4.32% of `evaluate_filter_narrowed`'s own samples plus
    # 0.57% of the process sitting in `List::_realloc`. The sibling narrowing
    # site (`komira_engine_runtime/column_filter_predicate.mojo`, the agg-arm
    # wrapper around this same evaluator) already passes it.
    var indices = List[Int](capacity=sel_len)
    for i in range(sel_len):
        indices.append(Int(sel.indices.get_typed[Scalar[DType.int32]](i)))

    var gathered = gather_batch(batch, indices)
    # NULL-collapse on the GATHERED sub-batch —
    # `gather_batch` materializes validity per element (see
    # `compiler_helpers.gather_batch`), so the per-row NULL bits align with
    # the comparison result's `sel.length` bits. Per-leaf; see the full-cover
    # arm above.
    var m = _predicate_3vl(expr, gathered, True)
    return _collapse_nulls_to_false(m^, None)


# =============================================================================
# evaluate_conjunction_select — narrow a selection through an AND-chain
# =============================================================================


def evaluate_conjunction_select(
    batch: RecordBatch,
    conjuncts: Slab[Expr],
) raises -> SelectionVector:
    """Evaluate `A AND B AND C AND ...` by sequential SelectionVector narrowing.

    For each conjunct:
      1. Evaluate only on surviving rows (via evaluate_predicate_selected).
      2. If pass_count == surviving_count: skip narrowing (full-pass fast path).
      3. If pass_count == 0: short-circuit, return empty selection.
      4. Else narrow current selection via `compose_mask(sub_mask)`.

    Args:
        batch: The input RecordBatch.
        conjuncts: Flat conjunct list from `flatten_and_conjuncts`.

    Returns:
        A SelectionVector of the surviving row indices. When every conjunct
        passes every row, the result is the full `[0..batch.num_rows)`
        (the caller can detect this via `sv.is_all(batch.num_rows)` and
        skip materializing a selection).

    No `Optional` result: `None` would encode "no narrowing occurred — use the
    full batch". Mojo does
    not have references into Option ergonomically here, and the common
    downstream API (`filter_to_indices` / `_gather_batch`) already works
    with a concrete SelectionVector. We return the materialized "all rows"
    vector when no narrowing occurred; callers that want the fast path
    check `is_all(num_rows)`. Cost: one extra O(N) allocation when zero
    narrowing happens — negligible against the row-evaluation savings.
    """
    var num_rows = batch.num_rows()
    var num_conjuncts = len(conjuncts)

    # Degenerate: no conjuncts at all (caller normally guards, but be safe).
    if num_conjuncts == 0:
        return SelectionVector.all(num_rows)

    # Initial state: every row is a survivor.
    var current_sel = SelectionVector.all(num_rows)
    var surviving_count = num_rows

    for i in range(num_conjuncts):
        if surviving_count == 0:
            # Short-circuit: no rows left. Matches eval.rs:1063-1065.
            return SelectionVector(PrimitiveArray[DType.int32].allocate(0))

        var mask = evaluate_predicate_selected(batch, conjuncts[i], current_sel)
        var pass_count = mask.true_count()

        if pass_count == 0:
            # Every surviving row rejected by this conjunct. eval.rs:1071-1073.
            return SelectionVector(PrimitiveArray[DType.int32].allocate(0))

        if pass_count == surviving_count:
            # Full-pass fast path: no narrowing needed. eval.rs:1075-1078.
            continue

        # Narrow: mask has `surviving_count` bits, one per current survivor.
        # `compose_mask` copies the subset of current_sel.indices where the
        # corresponding mask bit is True. eval.rs:1081-1091.
        current_sel = current_sel.compose_mask(mask)
        surviving_count = pass_count

    return current_sel^


# =============================================================================
# Convenience: flatten + narrow in one call
# =============================================================================


def evaluate_filter_narrowed(
    batch: RecordBatch,
    predicate: Expr,
) raises -> SelectionVector:
    """End-to-end filter entry: flatten the predicate, then narrow.

    This is the one-call API the morsel executor uses for OP_FILTER.
    Handles the non-AND predicate case transparently: `flatten_and_conjuncts`
    returns a single-element list, and `evaluate_conjunction_select` with
    one conjunct is the single-predicate path.
    """
    from komira_plan_expr.expr_helpers import flatten_and_conjuncts

    var conjuncts = flatten_and_conjuncts(predicate)
    return evaluate_conjunction_select(batch, conjuncts)
