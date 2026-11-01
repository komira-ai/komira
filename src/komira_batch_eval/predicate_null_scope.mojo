# =============================================================================
# predicate_null_scope: which input columns can make a predicate UNKNOWN
# =============================================================================
#
# Walks a predicate for the columns whose NULLs reach its result, and computes
# the input validity the filter boundary uses to tell FALSE from UNKNOWN. A
# predicate shape the walker cannot scope is refused by name
# (`predicate_null_scope_refusal`), never guessed.
# =============================================================================

from komira_arrow.bitmap import Bitmap
from komira_arrow.record_batch import RecordBatch
from komira_arrow.schema import Schema
from komira_buffer.heap_region import HeapRegion
from komira_column_kernels.cast_null import bitmap_and
from komira_plan_expr.expr import (
    EXPR_ALIAS,
    EXPR_BINARY_OP,
    EXPR_CAST,
    EXPR_COL_IDX,
    EXPR_COL_REF,
    EXPR_EXTRACT,
    EXPR_IN_LIST,
    EXPR_LITERAL,
    EXPR_REGEXP,
    EXPR_STRING_FN,
    EXPR_STRING_OP,
    EXPR_SUBSTRING,
    EXPR_UDF_CALL,
    EXPR_UNARY_OP,
    Expr,
    UN_IS_NOT_NULL,
    UN_IS_NULL,
    expr_tag_name,
)
from komira_plan_ir.expr_udf_sites import udf_call_column_key

from .conjunction import _collapse_nulls_to_false, _predicate_3vl


# =============================================================================
# NULL-collapse helpers
# =============================================================================
#
# The comparison kernels `_eval_cmp_*` and `eval_col_*` drop validity: they
# return a non-nullable `BooleanArray` whose data bits at NULL rows come from
# the raw bytes in the data buffer. At the filter boundary
# (`evaluate_predicate_selected`) the Expr is therefore walked for the column
# indices it references, those columns' validity bitmaps are ANDed, and the
# result is folded into each leaf's validity (see `conjunction._leaf_3vl`).
# When no referenced column carries a validity bitmap this is a single
# Optional check.
#
# Walker coverage: COL_REF, COL_IDX, LITERAL, BINARY_OP (both sides),
# UNARY_OP (except `IS NULL` / `IS NOT NULL`, see the arm), CAST, ALIAS,
# IN_LIST (child), STRING_OP / REGEXP / EXTRACT / SUBSTRING / STRING_FN (one
# child each), UDF_CALL (its own materialized output column). For every other
# tag (WHEN, AGG_FN, BETWEEN, MATH_FN, STRING_FN_N, WINDOW_FN, ...) the walk
# reports the tag, and `_compute_predicate_input_validity` falls back to ANDing
# every batch column's validity.
#
# That fallback is not a conservative approximation of a filter: it drops rows
# the predicate selects whenever an unrelated column has a NULL. It is a no-op
# when the batch has been narrowed to the predicate's own columns (the scan
# path narrows to the columns the predicate reads), and wrong on a wider batch
# such as the full output of a UDF pre-pass. Callers with a wide batch ask
# `predicate_null_scope_unhandled_tag` first and refuse.
#
# `EXPR_WHEN` has no arm on purpose: a `CASE` result's nullity depends on
# which branch is taken, so ANDing every condition, result and default
# validity would drop a row because an untaken branch was null. It needs
# per-branch three-valued logic, not a descent arm.
# =============================================================================


def _collect_predicate_col_refs(
    expr: Expr, schema: Schema, mut out: List[Int], mut unhandled_tag: Int
) raises:
    """Walk `expr` collecting referenced batch-column indices into `out`.

    `unhandled_tag` arrives `-1` and is set to the `EXPR_*` tag of the first
    node this ladder has no arm for (never overwritten). `>= 0` means the walk
    could not derive the predicate's input scope and `out` is incomplete.

    A caller may not treat `>= 0` as "no validity to AND", which would
    under-drop. The two legitimate readings are the all-columns fallback
    (over-strict on a wide batch) and a refusal.
    """
    if expr.tag == EXPR_COL_REF:
        out.append(schema.column_index(expr.col_ref_name()))
        return
    if expr.tag == EXPR_COL_IDX:
        out.append(expr.col_idx_index())
        return
    if expr.tag == EXPR_LITERAL:
        return
    if expr.tag == EXPR_BINARY_OP:
        _collect_predicate_col_refs(
            expr.binary_left_ref(), schema, out, unhandled_tag
        )
        _collect_predicate_col_refs(
            expr.binary_right_ref(), schema, out, unhandled_tag
        )
        return
    if expr.tag == EXPR_UNARY_OP:
        # `IS NULL` / `IS NOT NULL` do not descend. They are the only readers
        # of validity in the expression language: they turn a three-valued
        # operand into a definite Bool, so the operand's NULLs are the answer
        # and not an UNKNOWN to collapse. Descending would AND the operand's
        # validity into the result, and `IS NULL` is TRUE exactly where that
        # validity is 0, so the filter would return no rows.
        # `tests/test_filter_null_literal_alias_is_null.mojo` pins both.
        #
        # Every other unary (NOT, NEGATE, ...) descends. Per-arm scoping of
        # `x IS NULL OR x > 5` comes from `_predicate_3vl`, whose OR arms are
        # separate leaves with separate masks.
        var _uop = expr.unary_op()
        if _uop == UN_IS_NULL or _uop == UN_IS_NOT_NULL:
            return
        _collect_predicate_col_refs(
            expr.unary_child_ref(), schema, out, unhandled_tag
        )
        return
    if expr.tag == EXPR_CAST:
        _collect_predicate_col_refs(
            expr.cast_child_ref(), schema, out, unhandled_tag
        )
        return
    if expr.tag == EXPR_ALIAS:
        _collect_predicate_col_refs(
            expr.alias_child_ref(), schema, out, unhandled_tag
        )
        return
    if expr.tag == EXPR_IN_LIST:
        _collect_predicate_col_refs(
            expr.in_list_child_ref(), schema, out, unhandled_tag
        )
        return
    if expr.tag == EXPR_UDF_CALL:
        # A UDF call's input is its own output column: `_eval_predicate` reads
        # the column the UDF pre-pass materialized under `udf_call_column_key`
        # (the name `_eval_column_expr`'s UDF arm looks up), so that column's
        # validity is the predicate's input validity, as a `col_ref`'s is.
        # Without this arm the call would fall into the all-columns fallback
        # and a NULL in an unrelated column would drop the row.
        #
        # The argument subtree is not descended: `_run_thunk` refuses by name a
        # UDF whose argument column carries nulls, so the argument's validity is
        # absent or all-ones on every plan that reaches this walk.
        #
        # A missing output column means the pre-pass did not run over this
        # predicate; it is reported as unhandled instead of contributing no
        # validity (which would under-drop).
        #
        # The naming is not observable in a row set today: the output column
        # carries no validity bitmap of its own, and a UDF call on the left of
        # a comparison routes through `_col_cmp_nullable`, which propagates
        # validity itself. The assertion that pins this arm is on this
        # function's return value, in
        # `tests/test_udf_predicate_names_its_own_output_column.mojo`.
        var udf_key = udf_call_column_key(expr)
        for i in range(schema.num_columns()):
            if schema.field_name(i) == udf_key:
                out.append(i)
                return
        if unhandled_tag < 0:
            unhandled_tag = Int(EXPR_UDF_CALL)
        return
    # STRING_OP, REGEXP, EXTRACT, SUBSTRING and STRING_FN each compute one value
    # per row from one child expression and are NULL exactly where that child
    # is NULL (the pattern, unit, offsets and function selector are plan
    # literals, never columns), so the child's columns are this node's input
    # validity, by the same argument as the `col_ref` arm. They descend rather
    # than resolve, so nested calls such as `substring(upper(s), 1, 1)` are
    # fully collected.
    if (
        expr.tag == EXPR_STRING_OP
        or expr.tag == EXPR_REGEXP
        or expr.tag == EXPR_EXTRACT
        or expr.tag == EXPR_SUBSTRING
        or expr.tag == EXPR_STRING_FN
    ):
        if expr.tag == EXPR_STRING_OP:
            _collect_predicate_col_refs(
                expr.string_op_child_ref(), schema, out, unhandled_tag
            )
        elif expr.tag == EXPR_REGEXP:
            _collect_predicate_col_refs(
                expr.regexp_child_ref(), schema, out, unhandled_tag
            )
        elif expr.tag == EXPR_EXTRACT:
            _collect_predicate_col_refs(
                expr.extract_child_ref(), schema, out, unhandled_tag
            )
        elif expr.tag == EXPR_SUBSTRING:
            _collect_predicate_col_refs(
                expr.substring_child_ref(), schema, out, unhandled_tag
            )
        else:
            _collect_predicate_col_refs(
                expr.string_fn_child_ref(), schema, out, unhandled_tag
            )
        return
    # No arm: reported, not guessed. Among the tags without one are `WHEN`
    # (nullity depends on the branch taken), `AGG_FN`, `BETWEEN`,
    # `MATH_FN`/`MATH_FN2`, `STRING_FN_N`, `WINDOW_FN`, `CORRELATED_SUBQUERY`,
    # `STRUCT_FIELD*`, `MAP_GET`, `JSON_EXTRACT` and `SORT_KEY`. A caller reads
    # the report as the docstring of this function describes.
    if unhandled_tag < 0:
        unhandled_tag = Int(expr.tag)


def predicate_null_scope_unhandled_tag(
    imm expr: Expr, imm schema: Schema
) raises -> Int:
    """`-1` iff the NULL-collapse walk can derive `expr`'s entire input scope
    against `schema`; otherwise the `EXPR_*` tag of the first node it cannot.

    It answers by running `_collect_predicate_col_refs`, so the predicates it
    admits are exactly the ones that ladder can scope; a tag with no arm is
    what it reports, and no second list of admitted tags exists to drift.

    It must be called with the schema the filter will actually see: the
    `EXPR_UDF_CALL` arm resolves the pre-pass's materialized output column by
    name, so running this against the pre-pass's input schema would report
    every UDF predicate as unscopable.

    It is not a substitute for `_inmem_filter_predicate_supported`, which
    answers whether `_eval_predicate` can serve the shape; this answers
    whether the walk can say whose validity to AND.

    Args:
        expr: The predicate about to be evaluated.
        schema: The schema of the batch it will be evaluated against.

    Returns:
        `-1` when every node is armed; else the first unarmed node's tag.
    """
    var refs = List[Int]()
    var unhandled_tag = -1
    _collect_predicate_col_refs(expr, schema, refs, unhandled_tag)
    return unhandled_tag


def predicate_null_scope_answer_rows_lost(
    imm expr: Expr, imm batch: RecordBatch
) raises -> Int:
    """How many rows the all-columns fallback removes from the answer over
    THIS batch. `0` means the filter's row set is exactly the one a fully
    derived scope would return, so the caller can serve the query.

    Write `iv_correct` for the mask a fully armed walk would build and
    `iv_cons` for the all-columns fallback. The correct scope is a subset of
    the batch's columns, so `iv_correct` has at least the valid bits
    `iv_cons` has, and masking with more valid bits drops no more rows:

        answer(no mask)  ⊇  answer(iv_correct)  ⊇  answer(iv_cons)

    (the inclusions survive an enclosing `NOT`: a leaf going from UNKNOWN to
    KNOWN can only turn a collapsed FALSE into TRUE or FALSE, never the
    reverse, and UNKNOWN is never TRUE at any depth). This function computes
    the two outer terms and counts the difference; `0` squeezes the middle
    term onto both. Clearing a bit on a row the predicate already rejects
    costs nothing, which is why the count is of rows and not of cleared bits.

    Both terms come from `_predicate_3vl`, the function the filter itself
    runs, so the number cannot disagree with the mask that gets applied.

    It is only meaningful when the scope is underivable: with a derived scope
    the two terms differ by the predicate's own Arrow-3VL drop. Callers gate
    on `predicate_null_scope_unhandled_tag(...) >= 0` first. The result
    depends on the batch, so the same query can answer over data whose nulls
    do not reach the answer and refuse once one does.

    Cost: two full evaluations of the predicate over the batch.

    Args:
        expr: The predicate whose scope the walk could not derive.
        batch: The batch the filter is about to run over.

    Returns:
        The number of rows the all-columns fallback removes from the answer.
    """
    var strict = _collapse_nulls_to_false(
        _predicate_3vl(expr, batch, True), None
    )
    var loose = _collapse_nulls_to_false(
        _predicate_3vl(expr, batch, False), None
    )
    return loose.data.and_not(strict.data).popcount()


def predicate_null_scope_refusal(imm tag: Int) raises -> String:
    """The reason half of an unscopable-predicate refusal, for tag `tag`.

    Kept next to the walker so the diagnostic and the ladder that produced it
    cannot drift; the caller owns the sentence that names itself, this owns
    the sentence that names the shape.
    """
    if tag == Int(EXPR_UDF_CALL):
        return (
            "the UDF pre-pass materialized no output column for a"
            " `EXPR_UDF_CALL` node in this predicate, so the filter cannot"
            " read what the call produces. The producer's walk missed a node"
            " the evaluator reaches"
        )
    return (
        "`"
        + expr_tag_name(UInt8(tag))
        + "` has no arm in the NULL-collapse walk"
        " (`predicate_null_scope._collect_predicate_col_refs`), so the columns"
        " whose validity this predicate depends on cannot be derived"
    )


def _compute_predicate_input_validity(
    expr: Expr, batch: RecordBatch
) raises -> Optional[Bitmap[HeapRegion]]:
    """Compute the byte-AND of validity bitmaps for columns referenced
    by `expr`. Returns `None` when no referenced column carries a
    validity bitmap (the all-valid fast path).

    On a tag the walker cannot scope it ANDs the validities of ALL batch
    columns rather than miss an input. On a batch wider than the predicate
    that drops rows the predicate selects; on a batch already narrowed to the
    predicate's own columns it is a no-op. A caller that hands this walk a
    full batch checks `predicate_null_scope_unhandled_tag` first and refuses.
    """
    return _compute_predicate_input_validity_scoped(expr, batch, True)


def _compute_predicate_input_validity_scoped(
    expr: Expr, batch: RecordBatch, fallback_all_columns: Bool
) raises -> Optional[Bitmap[HeapRegion]]:
    """`_compute_predicate_input_validity` with the unscopable-tag fallback
    chosen by the caller instead of fixed.

    `fallback_all_columns=False` contributes no input validity for a node the
    walk has no arm for, i.e. it under-drops. It exists only as the upper
    bound in `predicate_null_scope_answer_rows_lost`, which compares the two
    results; its mask must not be used to answer a query.
    """
    var refs = List[Int]()
    var unhandled_tag = -1
    _collect_predicate_col_refs(expr, batch.schema, refs, unhandled_tag)

    if unhandled_tag >= 0:
        if not fallback_all_columns:
            return None
        # Walk every column in the batch.
        for i in range(batch.num_columns()):
            refs.append(i)

    var combined: Optional[Bitmap[HeapRegion]] = None
    for k in range(len(refs)):
        var col_idx = refs[k]
        ref col = batch.column_at(col_idx)
        if not col._validity:
            continue
        # Honor column offset/length (sliced columns); the produced bitmap
        # is `col._length` bits long, indexed [0, col._length).
        var per_col = Bitmap.copy_slice_from(
            col._validity.value(), col._offset, col._length
        )
        if not combined:
            combined = per_col^
        else:
            combined = bitmap_and(combined.value(), per_col)
    return combined^
