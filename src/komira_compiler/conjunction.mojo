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
# Depends on compiler_eval_predicate and compiler_helpers.
# =============================================================================

from komira_core.arrow.record_batch import RecordBatch
from komira_core.arrow.boolean_array import BooleanArray
from komira_core.arrow.bitmap import Bitmap
from komira_core.arrow.primitive_array import PrimitiveArray
from komira_core.io.heap_region import HeapRegion
from komira_core.arrow.schema import Schema
from komira_core.eval.selection_vector import SelectionVector
from komira_core.collections.slab import Slab

from komira_core.plan.expr import (
    Expr,
    EXPR_COL_REF,
    EXPR_COL_IDX,
    EXPR_LITERAL,
    EXPR_BINARY_OP,
    EXPR_UNARY_OP,
    EXPR_CAST,
    EXPR_ALIAS,
    EXPR_IN_LIST,
    EXPR_STRING_OP,
    EXPR_REGEXP,
    EXPR_EXTRACT,
    EXPR_SUBSTRING,
    EXPR_STRING_FN,
    EXPR_UDF_CALL,
    BIN_AND,
    BIN_OR,
    UN_NOT,
    UN_IS_NULL,
    UN_IS_NOT_NULL,
    expr_tag_name,
)
from komira_core.plan.expr_udf_sites import udf_call_column_key
from .compiler_eval_predicate import _eval_predicate
from .arm_rows import batch_nulled_outside, undecided_rows
from komira_core.eval.int_overflow import is_int_overflow_error
from komira_core.helpers.compiler_helpers import gather_batch, resolve_col_index
from komira_core.eval.cast_null import bitmap_and
from komira_core.eval.arithmetic import eval_and, eval_not, eval_or


# =============================================================================
# NULL-collapse helpers
# =============================================================================
#
# The legacy production filter path
# enforces Arrow-standard semantics at the filter boundary — `NULL` in
# any operand of a predicate collapses to `FALSE`, so the row is dropped
# from the output selection.
#
# The fast-path comparison kernels at `comparison.mojo:_eval_cmp_*` and
# `eval_col_*` DROP validity entirely (they return a non-nullable
# `BooleanArray` whose `data` bits at NULL row positions are whatever
# the SIMD compare produced from the raw bytes in the data buffer).
# Without this collapse step, NULL row inclusion depended on whatever
# bytes the allocator left at the NULL slot — undefined behavior at the
# semantic layer.
#
# Strategy: at the filter boundary (the single funnel
# `evaluate_predicate_selected`), walk the Expr to collect referenced
# column indices, byte-AND their validity bitmaps, and mask the
# predicate result's `data` bits with the resulting input-validity mask.
# The result is then logically treated as non-nullable (validity dropped).
#
# For the all-valid fast path (no referenced column carries a validity
# bitmap), this helper is a single Optional check — zero added cost.
# For nullable inputs, the cost is O(N/8) bytewise AND per AND-ed column
# — negligible against the comparison wall.
#
# Walker coverage: COL_REF, COL_IDX, LITERAL, BINARY_OP (both sides),
# UNARY_OP (EXCEPT `IS NULL` / `IS NOT NULL`, which are validity READERS and
# whose operand's NULLs are the answer — see the arm), CAST, ALIAS,
# IN_LIST (child), STRING_OP / REGEXP / EXTRACT / SUBSTRING / STRING_FN (each
# one child, — see the arms), UDF_CALL (its OWN materialized
# output column — see the arm). For every remaining tag (WHEN, AGG_FN, BETWEEN,
# MATH_FN, STRING_FN_N, WINDOW_FN, …) we conservatively AND all batch columns'
# validity bitmaps.
#
# ⛔⛔ "OVER-STRICT BUT CORRECT" IS FALSE AND THIS COMMENT USED TO SAY IT.
# It read: *"over-strict for predicates that only touch a subset, but correct
# (drops at most more rows than Arrow standard requires; never under-drops)"*.
# Dropping MORE rows than the predicate selects is not a conservative
# approximation of a filter — it is a SILENTLY WRONG ANSWER with a success
# code, and it is what measured: `WHERE <udf>(v) > lit` lost
# every row with a NULL in an UNRELATED column. `never under-drops` names the
# only direction that would be safe; over-dropping is the direction that ships
# missing rows.
#
# ── ⛔ AND THE SAME FALLBACK MEASURED AGAIN ───
#
# `WHERE <udf>(v) > 100 AND tag LIKE 'x%'` returned **ZERO** rows over a
# fixture whose `tag` is NULL-FREE, through the UDF FILTER DOOR
# (`udf_scratch_scope.filter_batch_over_udf_predicate`). SIX tags collapse to
# `[]` through that door:
#
#     STRING_OP · REGEXP · EXTRACT · WHEN · SUBSTRING · STRING_FN
#
# — the last two being the "sixth tag nobody listed", which is exactly why the
# door now carries a DERIVED envelope (`predicate_null_scope_unhandled_tag`,
# below) instead of a hand-written list of admitted tags.
#
# ⭐ WHY THE PARQUET DOOR DID NOT SHOW IT, AND WHY THAT IS NOT A DEFENCE. The
# ordinary route narrows the batch to the predicate's own columns first (the
# late-mat decode set comes from `walk_expr_column_refs`), so "AND every batch
# column" is ANDing exactly the predicate's columns — a no-op. The UDF door
# hands this walk the child's FULL materialized output, so the same fallback is
# lethal there. A door-shaped explanation is a property of the BATCH, not of the
# walker: any caller whose batch is wider than the predicate is exposed.
#
# ⭐ THE ARMS ARE THE FIX FOR A KNOWN TAG; THE ENVELOPE IS THE FIX FOR THE
# CLASS. Five arms landed here (STRING_OP, REGEXP, EXTRACT, SUBSTRING,
# STRING_FN), each on the same argument — the tag is elementwise and
# null-propagating over ONE child expression, so that child's columns ARE the
# predicate's input validity, exactly as a `col_ref`'s are.
#
# ⛔ `EXPR_WHEN` IS DELIBERATELY LEFT UNARMED AND IT IS NOT AN OVERSIGHT. A
# `CASE` result's nullity depends on WHICH BRANCH IS TAKEN, so ANDing the
# validity of every condition, result and default would drop a row because the
# UNTAKEN branch was null — the same over-strict wrongness this block is about,
# just narrower. `CASE` needs per-branch 3VL, not a descent arm; until then the
# envelope REFUSES it BY NAME, which is a correct answer where zero rows is not.
# =============================================================================


def _collect_predicate_col_refs(
    expr: Expr, schema: Schema, mut out: List[Int], mut unhandled_tag: Int
) raises:
    """Walk `expr` collecting referenced batch-column indices into `out`.

    `unhandled_tag` is the walk's OWN report of its coverage: it arrives `-1`
    and is set to the `EXPR_*` tag of the FIRST node this ladder has no arm for
    (never overwritten, so the tag reported is the first one encountered, not
    the last). `>= 0` means the walk could not derive the predicate's input
    scope and `out` is INCOMPLETE.

    ⭐ IT REPLACED A BARE `conservative: Bool`.
    Two consumers now read it and they need different things — the legacy
    caller wants "is it complete", the UDF filter door's envelope wants "WHICH
    tag" so its refusal can name the shape instead of saying `False` — and one
    field that answers both cannot disagree with itself the way a Bool plus a
    tag would.

    ⛔ THE CALLER MAY NOT TREAT `>= 0` AS "NO VALIDITY TO AND". That is the
    fail-OPEN direction (under-drop). The two legitimate readings are the
    legacy over-strict fallback (AND every batch column — measured WRONG on a
    wide batch, see the block above) and a REFUSAL. There is no third.
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
        # =====================================================================
        # ★ `IS NULL` / `IS NOT NULL` DO NOT DESCEND.
        # =====================================================================
        #
        # THE DEFECT THIS CLOSES: `WHERE col IS NULL` RETURNED ZERO ROWS, FOR
        # ANY COLUMN, ON ANY BATCH, on the WHERE path. Measured by
        # `test_is_null_finds_exactly_the_missing_values` (S024) — a fixture
        # with two NULLs whose own anti-vacuity gate proves they survive the
        # parquet round trip, and the filter found none of them. An empty
        # result is a legitimate-LOOKING answer, so this was the silently-
        # wrong class rather than the crashing one.
        #
        # THE MECHANISM. The caller (`evaluate_predicate_selected`) ANDs the
        # validity of every column this walk returns into the predicate's
        # result bits (`_compute_predicate_input_validity` ->
        # `_collapse_nulls_to_false`). Descending into `IS NULL`'s child put
        # the operand's OWN validity into that mask — and `IS NULL` is TRUE at
        # exactly the rows where that validity is 0, so the AND cancelled the
        # answer to empty every time. `IS NOT NULL` survived only by
        # coincidence: its TRUE rows ARE the valid ones, so the mask is a
        # no-op there. It is enumerated with `IS NULL` rather than left to
        # luck.
        #
        # WHY NOT-DESCENDING IS CORRECT AND NOT MERELY CONVENIENT: these two
        # ops are the only readers of validity in the expression language.
        # They consume a 3-valued input and produce a DEFINITE Bool — the
        # operand's NULLs are the ANSWER, not an UNKNOWN to be collapsed.
        # `compiler_eval_predicate` already emits exactly that
        # (`data = ~validity`, validity all-ones), so the arm was right and
        # only this caller was wrong.
        #
        # ⚠ NARROW ON PURPOSE. Every OTHER unary (NOT, NEGATE, ...) keeps
        # descending, so the collapse layer keeps compensating for the
        # comparison kernels that drop validity — which is why the WHERE route
        # is correct where the others are not.
        # Removing the layer, or widening this exception, re-opens that.
        #
        # ⭐ PER-ARM 3VL: `x IS NULL OR x > 5` needs it, because the OR's
        # other arm would contribute x's validity to the SAME whole-predicate
        # mask. `_predicate_3vl` is that per-arm 3VL: the OR's arms are separate
        # leaves with separate masks, so `note IS NULL OR note = 'a'` returns the
        # union rather than the left arm minus the right arm's nulls.
        # named refusal — not a sentence.
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
        # =====================================================================
        # ★ A UDF CALL'S INPUT IS ITS OWN OUTPUT COLUMN.
        # =====================================================================
        #
        # THE DEFECT THIS CLOSES: `SELECT ... WHERE <udf>(v) > lit` DROPPED
        # EVERY ROW CARRYING A NULL IN **ANY** COLUMN OF THE BATCH — a column
        # the predicate never read, a column the query never projected. rc=0,
        # a plausible row set, fewer rows than the predicate selects, and no
        # signal to the customer.
        #
        # THE MECHANISM. `EXPR_UDF_CALL` had no arm here, so it fell into the
        # conservative fallback below and the caller ANDed the validity of
        # EVERY batch column into the predicate's result bits. `note IS NULL`
        # on some row then cancelled that row out of a predicate about `v`.
        #
        # ⛔ THE ANSWER IS NOT "SKIP IT" AND NOT "DESCEND INTO THE ARGUMENT".
        # What `_eval_predicate` actually reads at this position is the column
        # the UDF pre-pass materialized under `udf_call_column_key` — the same
        # name `_eval_column_expr`'s UDF arm looks up, derived by THIS
        # function rather than spelled — so that column's validity is the
        # predicate's input validity, exactly as a `col_ref`'s is. Naming the
        # column keeps this arm correct on the day the output starts carrying
        # nulls of its own (`UdfData.null_mode`), where "skip it" would then
        # UNDER-drop.
        #
        # ⚠ AND NOT THE ARGUMENT SUBTREE. `_run_thunk` REFUSES BY NAME a UDF
        # whose argument column carries nulls (the per-batch ABI binds
        # `validity = NULL`, i.e. every row valid), so the argument's validity
        # is either absent or all-ones on every plan that reaches this walk.
        # Descending would be a no-op today and WRONG under `null_mode`, where
        # the propagated nulls belong to the output column and are already
        # counted once, here.
        #
        # ⛔ A MISSING COLUMN STAYS CONSERVATIVE rather than contributing
        # nothing. It means the pre-pass did not run over this predicate, and
        # answering "no validity to AND" would be the fail-OPEN direction on a
        # batch this walk cannot read.
        #
        # ⚠⚠ THE SENTENCE THAT USED TO FOLLOW WAS FALSE, AND IT MADE THE
        # BRANCH READ AS A TESTED SAFETY PROPERTY. It said `_eval_predicate`
        # "is ABOUT TO raise for that reason" — but
        # `evaluate_predicate_selected` calls `_eval_predicate` BEFORE
        # `_compute_predicate_input_validity`, and `_eval_column_expr`'s UDF
        # arm raises `the UDF ... was not materialized onto this batch` at the
        # missing lookup, so through THAT caller the walk never runs and this
        # line was dead code. Pinned by
        # `komira_compiler/tests/test_udf_predicate_names_its_own_output_
        # column.mojo` (`test_an_UNRESOLVABLE_UDF_KEY_never_reaches_the_
        # conservative_branch` asserts the raise that pre-empts it;
        # `test_the_conservative_branch_IS_correct_when_it_is_reached_directly`
        # asserts the branch itself one layer below).
        #
        # ⭐ AND THAT DAY ARRIVED. Those tests
        # said the branch becomes live "the day some caller computes validity
        # without evaluating first". `predicate_null_scope_unhandled_tag` — the
        # UDF filter door's envelope — is exactly that caller: it runs THIS
        # walk BEFORE any evaluation, so an unresolvable key now produces the
        # door's named refusal instead of being unreachable. Kept, reachable,
        # and no longer described as something it is not.
        #
        # ⛔⛔ THE NAMING ABOVE IS STILL NOT OBSERVABLE IN AN ANSWER TODAY,
        # WHICH IS WHY IT NEEDED A TEST AT ALL. Replacing this whole arm body
        # with a bare `return` — the "skip it" reading argued against above —
        # gives byte-identical results across the UDF end-to-end suite:
        #
        #     shipped                 all pass
        #     arm body -> `return`    all pass, IDENTICAL
        #
        #
        # Two independent reasons, and BOTH have to go before a customer can
        # see the difference:
        #   1. `udf_expr_execution._run_thunk` allocates the output with
        #      `allocate_uninitialized` and NEVER attaches a validity bitmap,
        #      and refuses a null-bearing ARGUMENT by name — so on every live
        #      route `null_count == 0` and
        #      `_compute_predicate_input_validity` skips the column anyway.
        #      (`UdfData.null_mode` is what changes this.)
        #   2. Even with a synthetic null-bearing output column, a UDF call is
        #      a COMPUTED LHS, which routes through `_eval_col_vs_col_promoted`
        #      -> `_col_cmp_nullable`; that propagates the LHS's validity into
        #      the BooleanArray's OWN validity, and `_collapse_nulls_to_false`
        #      ANDs that in FIRST. So the rows drop whether or not this arm
        #      named anything.
        # ⇒ The load-bearing assertion is on THIS FUNCTION'S RETURN VALUE, not
        # on a row set. Do not "simplify" this arm to a bare `return` on the
        # evidence that no end-to-end test changes — that has been measured,
        # and the test that does change is the one named above.
        var udf_key = udf_call_column_key(expr)
        for i in range(schema.num_columns()):
            if schema.field_name(i) == udf_key:
                out.append(i)
                return
        if unhandled_tag < 0:
            unhandled_tag = Int(EXPR_UDF_CALL)
        return
    # ★ THE FIVE ELEMENTWISE ARMS. Each of these
    # tags computes ONE value per row from ONE child expression and is NULL at
    # exactly the rows where that child is NULL (the pattern / unit / offsets /
    # function selector are plan-literals, never columns) — so the child's
    # columns ARE this node's input validity, by the same argument the
    # `col_ref` arm rests on. Unarmed, each of them collapses a UDF-door
    # filter to zero rows.
    #
    # ⚠ THEY DESCEND RATHER THAN RESOLVE. `substring(upper(s), 1, 1)` nests,
    # and an arm written against the `col_ref` case a first test happens to use
    # would under-collect the moment two of these compose.
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
    # ⛔ NO ARM — REPORTED, NOT GUESSED. `WHEN` (branch-dependent nullity),
    # `AGG_FN`, `BETWEEN`, `MATH_FN`/`MATH_FN2`, `STRING_FN_N`, `WINDOW_FN`,
    # `CORRELATED_SUBQUERY`, `STRUCT_FIELD*`, `MAP_GET`, `JSON_EXTRACT`,
    # `SORT_KEY`. The two readings a caller may take are stated on the
    # docstring; adding an arm here is what makes the envelope refuse less.
    if unhandled_tag < 0:
        unhandled_tag = Int(expr.tag)


def predicate_null_scope_unhandled_tag(
    imm expr: Expr, imm schema: Schema
) raises -> Int:
    """`-1` iff the NULL-collapse walk can derive `expr`'s ENTIRE input scope
    against `schema`; otherwise the `EXPR_*` tag of the first node it cannot.

    ★ THE ENVELOPE FOR THE UDF FILTER DOOR, AND IT IS **DERIVED, NOT DECLARED**.
    It answers the question by RUNNING
    `_collect_predicate_col_refs` — the very ladder whose missing arm is the
    hazard — so the set of predicates it admits is, by construction, exactly
    the set that ladder can scope.
    ⛔ DO NOT REPLACE IT WITH A LIST OF ADMITTED TAGS. A list is a SECOND
    statement of the same fact, and the whole defect is what happens when the
    two disagree: the previous fix enumerated five unarmed tags in its open
    items and the census found SEVEN, because `EXPR_SUBSTRING` and
    `EXPR_STRING_FN` landed after the list was written. A list goes stale on
    the day a tag is added; this cannot, because a tag with no arm IS what it
    reports.

    ⚠ IT MUST BE CALLED WITH THE SCHEMA THE FILTER WILL ACTUALLY SEE. The
    `EXPR_UDF_CALL` arm resolves the pre-pass's materialized output column BY
    NAME, so running this against the pre-pass's INPUT schema would report
    every UDF predicate as unscopable. At the door that means: AFTER
    `materialize_udf_columns_for_expr`, never before.

    ⚠ AND IT IS NOT A SUBSTITUTE FOR `_inmem_filter_predicate_supported`. That
    envelope answers "can `_eval_predicate` serve this shape without raising";
    this one answers "can the NULL-collapse walk say whose validity to AND".
    They are different questions with different answers — `STRING_OP` is inside
    the first and was outside the second, which is precisely the gap that
    returned zero rows.

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
    """How many rows the CONSERVATIVE fallback REMOVES FROM THE ANSWER over
    THIS batch. `0` means the filter's row set is exactly the one a fully-
    derived scope would return, so the door can serve the query.

    ⛔⛔ IT REPLACED A COUNT OF THE WRONG QUANTITY, AND THAT COUNT CAUSED A
    REFUSAL REGRESSION. The predecessor,
    `predicate_null_scope_conservative_masked_rows`, returned
    `input_validity.null_count` — how many BITS the fallback CLEARS. Clearing
    a bit on a row the predicate already rejects costs NOTHING, so on a fixture
    whose nulls sit only on rejected rows the door had ANSWERED `k=[3,5,7]`
    correctly and began raising `UDF_FILTER_PREDICATE_NULL_SCOPE_UNDERIVABLE`
    instead. ⛔ That is `udf_only_refused` — *a query this engine ANSWERS
    without a UDF became a REFUSAL with one* — the class
    exists to prevent, reintroduced by the guard written to prevent its mirror
    image.

    ⭐ WHY THE COMPARISON IS A PROOF AND NOT A HEURISTIC. Write `iv_correct`
    for the mask a fully-armed walk would build and `iv_cons` for the
    all-columns fallback. The correct scope is a SUBSET of the batch's columns,
    so `iv_correct` has at least the valid bits `iv_cons` has, and masking with
    more valid bits drops no more rows:

        answer(no mask)  ⊇  answer(iv_correct)  ⊇  answer(iv_cons)

    (the inclusions survive an enclosing `NOT`: a leaf going from UNKNOWN to
    KNOWN can only turn a collapsed FALSE into TRUE or FALSE, never the
    reverse, and UNKNOWN is never TRUE at any depth). This function computes
    the two OUTER terms and counts the difference. `0` squeezes the middle term
    onto both — the answer IS the correct one — with no appeal to which columns
    the missing arm would have named.

    ⭐ AND IT STILL MEASURES RATHER THAN PREDICTS. Both terms come from
    `_predicate_3vl`, the function the filter itself runs, so the number cannot
    disagree with the mask that actually gets applied.

    ⚠ IT IS ONLY MEANINGFUL WHEN THE SCOPE IS UNDERIVABLE — with a derived
    scope the two terms differ by the predicate's OWN legitimate Arrow-3VL
    drop, and refusing on that would be wrong. Callers gate on
    `predicate_null_scope_unhandled_tag(...) >= 0` first.

    ⚠ AND IT IS A PROPERTY OF THIS BATCH, so the refusal it drives is
    DATA-DEPENDENT BY CONSTRUCTION: the same query answers over data whose
    nulls do not reach the answer and refuses once one does. That is the honest
    report — the engine serves the shape exactly when the shape's answer does
    not depend on a scope it cannot derive.

    ⚠ COST, STATED: TWO full evaluations of the predicate over the batch, where
    the predecessor did one validity WALK and no evaluation. It is paid only on
    the path that was about to REFUSE — i.e. only for a predicate carrying a
    node the walk has no arm for — and buying the answer back is worth more
    than the walk. If a cheaper bound is ever wanted, it must still be an
    ANSWER, not a mask: a proxy for the mask is exactly what went wrong.

    Args:
        expr: The predicate whose scope the walk could not derive.
        batch: The batch the filter is about to run over.

    Returns:
        The number of rows the conservative fallback removes from the answer.
    """
    var strict = _collapse_nulls_to_false(
        _predicate_3vl(expr, batch, True), None
    )
    var loose = _collapse_nulls_to_false(
        _predicate_3vl(expr, batch, False), None
    )
    return loose.data.and_not(strict.data).popcount()


def predicate_null_scope_refusal(imm tag: Int) raises -> String:
    """The WHY half of an unscopable-predicate refusal, for tag `tag`.

    Kept next to the walker rather than at the door so the diagnostic and the
    ladder that produced it cannot drift; the DOOR owns the sentence that names
    itself, this owns the sentence that names the shape.
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
        " (`conjunction._collect_predicate_col_refs`), so the columns whose"
        " validity this predicate depends on cannot be derived"
    )


def _compute_predicate_input_validity(
    expr: Expr, batch: RecordBatch
) raises -> Optional[Bitmap[HeapRegion]]:
    """Compute the byte-AND of validity bitmaps for columns referenced
    by `expr`. Returns `None` when no referenced column carries a
    validity bitmap (the all-valid fast path).

    ⛔ CONSERVATIVE ON A TAG THE WALKER CANNOT SCOPE — ANDs validities across
    ALL batch columns rather than miss an input. THAT IS OVER-STRICT AND IT IS
    A WRONG ANSWER ON A WIDE BATCH (see
    module's other callers the batch has already been narrowed to the
    predicate's own columns, where it is a provable no-op — and because
    turning it into a raise would refuse queries those callers answer
    correctly today. The caller that hands this walk a FULL batch (the UDF
    filter door) refuses UP FRONT instead, via
    `predicate_null_scope_unhandled_tag`.
    """
    return _compute_predicate_input_validity_scoped(expr, batch, True)


def _compute_predicate_input_validity_scoped(
    expr: Expr, batch: RecordBatch, fallback_all_columns: Bool
) raises -> Optional[Bitmap[HeapRegion]]:
    """`_compute_predicate_input_validity` with the UNSCOPABLE-TAG fallback
    chosen by the caller instead of fixed.

    ⛔ `fallback_all_columns=False` IS THE FAIL-OPEN DIRECTION AND IT MAY NEVER
    REACH AN ANSWER. It contributes NO input validity for a node the walk has
    no arm for, i.e. it under-drops — the reading
    `_collect_predicate_col_refs`'s docstring forbids a caller from taking.
    It exists for exactly ONE purpose: as the UPPER BOUND in
    `predicate_null_scope_answer_rows_lost`, which compares the two so a
    refusal can be keyed on whether the fallback moves a ROW rather than on
    whether it clears a BIT. The bound is what makes that comparison a proof
    (see that function); a caller that returned this mask's answer to a
    customer would be shipping rows the predicate does not select.
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
# (`komira_core/eval/arithmetic.mojo`); ONE collapse at the very top turns
# UNKNOWN into FALSE, which is the Arrow filter boundary this file exists to
# enforce.
#
# ⚠ SCOPE: this covers `_predicate_3vl`, reached through exactly two entry
# points in THIS file: `evaluate_filter_narrowed` and
# `evaluate_predicate_selected`. A site that calls `_eval_predicate` itself is
# not covered by it; `compiler_eval_predicate`'s own short-circuit AND / OR
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
    from komira_core.plan.expr_helpers import flatten_and_conjuncts

    var conjuncts = flatten_and_conjuncts(predicate)
    return evaluate_conjunction_select(batch, conjuncts)
