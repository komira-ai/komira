# =============================================================================
# Selection-vector conjunction narrowing
# =============================================================================
#
# `evaluate_conjunction_select` + `evaluate_predicate_selected`: evaluating
# `A AND B AND C AND ...` naively runs every conjunct over all N batch rows,
# even though later conjuncts only need the rows that survived the earlier
# ones. This narrows a SelectionVector conjunct by conjunct, evaluating each
# new predicate only on the surviving rows.
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
from komira_kernels.comparison_kleene import kleene_all_null_predicate
from komira_plan_expr.expr import (
    BIN_AND,
    BIN_OR,
    EXPR_BINARY_OP,
    EXPR_UNARY_OP,
    EXPR_ALIAS,
    EXPR_LITERAL,
    Expr,
    UN_NOT,
)
from komira_scalar_arithmetic.int_overflow import is_int_overflow_error

from .arm_rows import batch_nulled_outside, undecided_rows
from .eval_predicate import _eval_predicate
from .predicate_null_scope import _compute_predicate_input_validity_scoped


# =============================================================================
# Three-valued logic at the filter boundary
# =============================================================================
#
# `flatten_and_conjuncts` splits only AND, so a disjunction is one conjunct:
#
#     WHERE v > 35 AND (tag LIKE 'x%' OR note = 'zzz')
#
# ANDing the validity of every column the conjunct mentions (`{tag, note}`)
# into one mask would drop the rows where `note` is NULL even when `tag`
# matches, yet `TRUE OR NULL` is TRUE. Instead `_predicate_3vl` descends the
# boolean connectives (AND, OR, NOT) and an enclosing alias, and uses each
# leaf's own input validity as that leaf's validity. The connectives are
# combined by `eval_and` / `eval_or` / `eval_not`, which are Kleene-correct,
# and one collapse at the top (`_collapse_nulls_to_false`) turns UNKNOWN into
# FALSE, the Arrow filter boundary.
#
# A site that calls `_eval_predicate` directly is not covered by this;
# `eval_predicate`'s own short-circuit AND / OR carry the same
# `not l.validity` guard for that reason.
#
# What the structure relies on, with the test that fails when it is removed:
#
#   * The BIN_OR descent:
#     `test_filter_disjunction_keeps_TRUE_OR_NULL_rows`
#     (`tests/test_filter_null_collapse_semantics.mojo`).
#   * The UN_NOT and BIN_AND descents:
#     `test_filter_negated_conjunction_keeps_the_FALSE_AND_NULL_rows`, same
#     file. `FALSE AND UNKNOWN` is a known FALSE, so its negation is TRUE.
#   * The alias descent and the NULL literal leaf:
#     `tests/test_filter_null_literal_alias_is_null.mojo`.
#   * Folding a leaf's input validity into the result's validity rather than
#     its data: the negated cells in `test_filter_null_collapse_semantics`.
#     Dropping the merge entirely also breaks the numeric-dictionary filter
#     (`test_numeric_dict_filter_lut_p3`), because a comparison kernel that
#     returns a non-nullable BooleanArray leaves its bits at NULL rows as
#     whatever the compare read from the raw data buffer.
#   * The `not l.validity` guard on the short-circuits:
#     `test_filter_negated_conjunction_with_the_NULL_ARM_FIRST_keeps_its_rows`
#     (AND half) and
#     `test_filter_negated_disjunction_with_the_NULL_ARM_FIRST_drops_only_UNKNOWN`
#     (OR half). The NULL-bearing arm must be on the left. Only the
#     `FALSE AND r` and `FALSE OR r` halves can be reached with unknowns
#     present (their test is `true_count == 0`); the two TRUE halves need
#     `true_count == length`, which an unknown row (data bit 0) rules out.
#
# Every value flowing through `_predicate_3vl` carries data bit 0 at every
# unknown row. `_leaf_3vl` establishes it and the combinators preserve it
# (`eval_and` and `eval_or` data are `l & r` and `l | r`; `eval_not` clears the
# bit itself), so the combinator results are not re-normalised.
# =============================================================================


def _normalize_3vl(var ba: BooleanArray) raises -> BooleanArray:
    """Restore this repo's UNKNOWN encoding on `ba`: data bit 0 at every
    unknown row, with validity saying why.

    `_leaf_3vl` replaces `ba.validity` wholesale, which can leave a data bit
    set on a row the new validity marks unknown, and leaves `null_count` stale.
    The consumer that selects rows (`filter_to_indices`) walks the data bitmap
    and never reads validity, so an unknown row with a set data bit would be
    selected. `_collapse_nulls_to_false` repeats the same masking once at the
    top, and the Kleene combinators ignore a set data bit on an unknown row,
    so this step keeps each value consistent with its own validity rather than
    changing the final row set.
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
    """Fold a leaf predicate's input-column validity into its own validity.

    Unlike `_collapse_nulls_to_false`, which ANDs the input validity into the
    result's data, this ANDs it into the result's validity: the row stays
    UNKNOWN, so an enclosing OR can still apply `TRUE OR UNKNOWN = TRUE` and
    an enclosing NOT can tell UNKNOWN from FALSE.
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
    """Evaluate `expr` over `batch` as a three-valued predicate.

    Returns a BooleanArray in this repo's UNKNOWN encoding: data bit 0 at
    every unknown row, validity saying which rows those are. The caller turns
    it into a filter mask with one `_collapse_nulls_to_false`.

    Only the boolean connectives (AND, OR, NOT) and an enclosing alias are
    descended. A NULL boolean literal is UNKNOWN on every row. Everything
    else is a leaf and goes to `_eval_predicate` whole (a `CASE`, an
    `IN (...)`, a comparison whose left side is arithmetic): a leaf's nullity
    is a property of its own inputs, which `_collect_predicate_col_refs`
    names.

    This is not `_eval_predicate`'s AND/OR path. It reproduces three of that
    path's four short-circuit cases (`FALSE AND r`, `TRUE AND r`, `TRUE OR r`,
    `FALSE OR r`) and not the gather-to-survivors case: top-level ANDs are
    already flattened and narrowed through the SelectionVector, so only an AND
    nested under an OR or a NOT loses that optimisation.

    The short-circuits are algebraic identities (performance only). What
    keeps them correct is the `not l.validity` guard on each: a left mask with
    any UNKNOWN row can be neither all-true nor all-false.

    Args:
        expr: The predicate.
        batch: The batch to evaluate it over.
        fallback_all_columns: What a leaf whose scope the walk cannot derive
            does; see `_compute_predicate_input_validity_scoped`. Production
            callers pass `True`; `False` is the upper bound used by
            `predicate_null_scope_answer_rows_lost`.

    Returns:
        The three-valued mask, `batch.num_rows` bits wide.
    """
    if expr.tag == EXPR_ALIAS:
        return _predicate_3vl(
            expr.alias_child_ref(), batch, fallback_all_columns
        )
    if expr.tag == EXPR_LITERAL and expr.literal_value().is_null():
        return kleene_all_null_predicate(batch.num_rows())
    if expr.tag == EXPR_BINARY_OP:
        var op = expr.binary_op()
        if op == BIN_AND:
            var l = _predicate_3vl(
                expr.binary_left_ref(), batch, fallback_all_columns
            )
            # Short-circuit only when the left mask has no UNKNOWN row; see
            # the block above `_normalize_3vl`.
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
    """The right arm of an AND / OR under `_predicate_3vl`. If the whole-batch
    evaluation raises an integer overflow, it is retried with every row the
    left arm has already decided set to NULL (`arm_rows.undecided_rows`
    names the rows still undecided). The Kleene combine never reads a NULL
    introduced that way."""
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
        # `_predicate_3vl` descends AND/OR/NOT and scopes each leaf's nulls to
        # that leaf's own columns, so the one collapse here only turns
        # UNKNOWN into FALSE.
        var m = _predicate_3vl(expr, batch, True)
        return _collapse_nulls_to_false(m^, None)

    # Materialize the selected-rows sub-batch once; all columns are gathered
    # together, which copies bytes for every column.
    #
    # `capacity=sel_len` avoids re-copying the index vector as `append` grows
    # it: the final size is known here.
    var indices = List[Int](capacity=sel_len)
    for i in range(sel_len):
        indices.append(Int(sel.indices.get_typed[Scalar[DType.int32]](i)))

    var gathered = gather_batch(batch, indices)
    # `gather_batch` materializes validity per element, so the per-row NULL
    # bits align with the result's `sel.length` bits. Per-leaf scoping, as in
    # the full-cover arm above.
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
            # Short-circuit: no rows left.
            return SelectionVector(PrimitiveArray[DType.int32].allocate(0))

        var mask = evaluate_predicate_selected(batch, conjuncts[i], current_sel)
        var pass_count = mask.true_count()

        if pass_count == 0:
            # Every surviving row rejected by this conjunct.
            return SelectionVector(PrimitiveArray[DType.int32].allocate(0))

        if pass_count == surviving_count:
            # Full-pass fast path: no narrowing needed.
            continue

        # Narrow: mask has `surviving_count` bits, one per current survivor.
        # `compose_mask` copies the subset of current_sel.indices where the
        # corresponding mask bit is True.
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

    The batch should carry only the columns the predicate reads. A predicate
    node the null-scope walk has no arm for (see
    `predicate_null_scope_unhandled_tag`) is scoped by ANDing the validity of
    every batch column, so on a wider batch a NULL in an unrelated column can
    drop a row the predicate selects. Callers that cannot narrow the batch
    check `predicate_null_scope_unhandled_tag` first.
    """
    from komira_plan_expr.expr_helpers import flatten_and_conjuncts

    var conjuncts = flatten_and_conjuncts(predicate)
    return evaluate_conjunction_select(batch, conjuncts)
