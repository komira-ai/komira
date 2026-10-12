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
        # `eval_predicate` already emits exactly that
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
        # `komira_batch_eval/tests/test_udf_predicate_names_its_own_output_
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
