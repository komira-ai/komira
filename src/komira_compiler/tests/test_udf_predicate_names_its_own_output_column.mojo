# =============================================================================
# test_udf_predicate_names_its_own_output_column — the `EXPR_UDF_CALL` arm of
# `conjunction._collect_predicate_col_refs`, PINNED AT ITS ARGUED MECHANISM.
# =============================================================================
#
# ⛔⛔ WHY THIS FILE EXISTS: THE ARM'S REASONING IS PINNED BY NOTHING ELSE.
#
# The `EXPR_UDF_CALL` arm of `_collect_predicate_col_refs` closes a defect:
# `SELECT ... WHERE <udf>(v) > lit` dropped every row carrying a NULL in ANY
# column of the batch, because a UDF call fell into the "unrecognized variant"
# fallback and the caller then ANDed the validity of EVERY batch column into
# the predicate's result bits.
#
# The arm does not merely skip the UDF call. It NAMES the column
# `_eval_predicate` actually reads at that position — the pre-pass's output,
# looked up by `udf_call_column_key`. Replacing the entire arm body with a bare
# `return` (i.e. "skip the UDF call, contribute no columns") gives
# BYTE-IDENTICAL results across the UDF end-to-end suite, so nothing else can
# tell the shipped arm from the one it argues against.
#
# ── ⭐ WHY A SYNTHETIC BATCH ──────────────────────────────────────────────────
#
#     udf_expr_execution._run_thunk:
#         var out_arr = PrimitiveArray[out_dt].allocate_uninitialized(n)
#
# The UDF's output column is allocated with NO validity bitmap and none is ever
# attached, and `_run_thunk` REFUSES BY NAME a null-bearing ARGUMENT column
# ("the argument column carries N nulls; the handle path binds validity=NULL").
# So on every live route the `__udf:` column's `null_count` is 0, and
# `_compute_predicate_input_validity` skips a column with no validity
# (`if not col._validity: continue`) — which makes NAMING the column and
# SKIPPING it produce identical bits, by construction, for every query a
# customer can write today.
#
# ⇒ The naming becomes observable the day `UdfData.null_mode` lands and the
# `__udf:` output carries validity of its own. THAT COLUMN CAN BE BUILT TODAY,
# synthetically, and this file builds it. A synthetic batch is the ONLY thing
# that can see this arm.
#
# ── ⭐ THE THREE-WAY DISCRIMINATION, AND WHERE IT LIVES ──────────────────────
#
#     rows                 0  1  2  3  4  5  6  7
#     __udf:<key> NULL        ●              ●         <- the predicate's input
#     unrelated   NULL              ●     ●            <- read by nothing
#
# The three candidate implementations return three DIFFERENT values from
# `_compute_predicate_input_validity`, which is therefore where the pin is:
#
#     SHIPPED  (name the output column)   Some(...), cleared at 1, 6
#     "skip it" (bare `return`)           None
#     no arm    (conservative fallback)   Some(...), cleared at 1, 2, 4, 6
#
# ⭐ MEASURED, farm, `--nocache_test_results`, — the neuter runs
# this file exists to fail, both actually executed against this file:
#
#   arm body -> a bare `return`   5 passed / 2 FAILED
#       test_the_walk_names_the_UDFs_OWN_OUTPUT_COLUMN_and_no_other
#       test_the_conservative_branch_IS_correct_when_it_is_reached_directly
#     ⇒ BOTH end-to-end cells stayed GREEN. That is the measurement behind
#       the paragraph below, not a reading of the kernels.
#
#   arm DELETED (conservative)    4 passed / 3 FAILED
#       the walk cell (bit 2 cleared), and BOTH end-to-end cells
#       (`[0, 3, 5, 7]` — the original defect's row set, exactly)
#
# ⚠⚠ AND THE END-TO-END ROW SET SEPARATES ONLY **TWO** OF THE THREE, WHICH IS
# STATED HERE RATHER THAN DISCOVERED BY THE NEXT READER. A computed LHS routes
# through `_eval_col_vs_col_promoted` -> `_col_cmp_nullable`, which propagates
# the LHS column's validity into the BooleanArray's OWN validity, and
# `_collapse_nulls_to_false` ANDs that in FIRST — before `input_validity` is
# consulted at all. So rows 1 and 6 drop whether or not the arm named anything,
# and "skip it" is INDISTINGUISHABLE FROM SHIPPED at the filter boundary. Only
# the conservative fallback (rows 2 and 4 also gone) shows up in an answer.
#
# ⇒ THE NAMING IS NOT MERELY UNTESTED END-TO-END; AT THIS PREDICATE SHAPE IT IS
# UNREACHABLE BY CONSTRUCTION. That is why the load-bearing assertion is on the
# walk's own return value and the end-to-end cells are labelled for what they
# actually cover. The tests below carry both.
#
# Every raw value in the `__udf:` buffer passes the comparison, INCLUDING at the
# NULL positions — the deterministic-failure shape `test_filter_null_collapse_
# semantics.mojo` established for this same boundary. So a row's fate here is
# decided by validity handling alone and by nothing else.
# =============================================================================

from std.sys import size_of
from std.testing import TestSuite, assert_equal, assert_true, assert_raises

from komira_core.arrow.primitive_array import PrimitiveArray
from komira_core.arrow.bitmap import Bitmap
from komira_core.io.heap_region import HeapRegion
from komira_core.arrow.record_batch import RecordBatch
from komira_core.arrow.schema import Schema, SchemaBuilder, Field
from komira_core.arrow.arrow_types import ArrowType
from komira_core.arrow.owned_aligned_buffer import OwnedAlignedBuffer
from komira_eval.selection_vector import SelectionVector

from komira_core.plan.expr import Expr, BIN_ADD, BIN_GT
from komira_core.plan.expr_udf_sites import udf_call_column_key
from komira_core.plan.scalar_value import ScalarValue
from komira_compiler.conjunction import (
    evaluate_filter_narrowed,
    _compute_predicate_input_validity,
)


# ---------------------------------------------------------------------------
# THE FIXTURE. Eight rows; every value in every column PASSES the comparison,
# so validity is the only thing that can change the answer.
# ---------------------------------------------------------------------------
comptime _N = 8
comptime _THRESHOLD: Int64 = 100
# The UDF's own name/handle/types. ⚠ NONE of these is asserted anywhere — the
# column name is DERIVED from the expression by `udf_call_column_key`, the same
# function the producer and the evaluator both call. Spelling a `__udf:...`
# literal here would be the two-names bug this repo has now paid for twice.
comptime _UDF_NAME = "affine_nd"
comptime _UDF_HANDLE = 7


def _nullable_i64(
    raw_values: List[Int64], null_indices: List[Int]
) raises -> PrimitiveArray[DType.int64]:
    """A nullable Int64 column whose DATA BUFFER holds a passing value at every
    NULL row — so a build that ignores validity lets the NULL rows through and
    is caught, rather than being right by accident."""
    var length = len(raw_values)
    comptime elem_size = size_of[Scalar[DType.int64]]()
    var buf = OwnedAlignedBuffer(max(length, 1) * elem_size)
    for i in range(length):
        buf.set_typed[Scalar[DType.int64]](
            i, Scalar[DType.int64](raw_values[i])
        )
    buf.set_length(Int64(length * elem_size))
    var validity = Bitmap.create_all_valid(length)
    for k in range(len(null_indices)):
        validity.clear(null_indices[k])
    return PrimitiveArray[DType.int64](
        buf^,
        length,
        Optional[Bitmap[HeapRegion]](validity^),
        len(null_indices),
        0,
    )


def _udf_call() -> Expr:
    """`affine_nd(col("v"))` — the customer's call, as the binder lowers it."""
    return Expr.udf_call(
        String(_UDF_NAME),
        Optional[Int](_UDF_HANDLE),
        ArrowType.INT64,
        ArrowType.INT64,
        Expr.col_ref("v"),
    )


def _predicate() -> Expr:
    """`affine_nd(v) > 100` — the shape the defect was measured on."""
    return Expr.binary(
        BIN_GT,
        _udf_call(),
        Expr.literal(ScalarValue.from_int64(_THRESHOLD)),
    )


def _predicate_wrapped() -> Expr:
    """`affine_nd(v) + 1 > 100` — the SAME call, one arithmetic node deeper.

    ⚠ NOT REDUNDANT WITH `_predicate`, and which of the two (if either) can see
    the naming end-to-end is a question about the KERNELS, answered by
    execution below rather than by reading them.
    """
    return Expr.binary(
        BIN_GT,
        Expr.binary(
            BIN_ADD,
            _udf_call(),
            Expr.literal(ScalarValue.from_int64(1)),
        ),
        Expr.literal(ScalarValue.from_int64(_THRESHOLD)),
    )


def _batch(with_udf_column: Bool) raises -> RecordBatch:
    """v / <the UDF's output column> / unrelated.

    * `v`   the ARGUMENT — NULL-FREE, because `_run_thunk` refuses a
            null-bearing argument by name and a fixture with nulls there would
            be asking for that refusal instead of this arm.
    * the UDF OUTPUT column — nulls at rows 1 and 6. ⭐ THE SYNTHETIC HALF: no
            live route produces one (see the header).
    * `unrelated` — nulls at rows 2 and 4, DISJOINT from the output column's,
            and read by nothing in the predicate.

    `with_udf_column = False` builds the same batch with the output column
    RENAMED, i.e. the pre-pass did not run — the arm's other branch.
    """
    var key = udf_call_column_key(_udf_call())
    var out_name = key if with_udf_column else String("__udf:NOT_THE_KEY")

    var vs = List[Int64]()
    var ys = List[Int64]()
    var us = List[Int64]()
    for i in range(_N):
        vs.append(Int64(i))
        # Every raw value clears the threshold, at the NULL rows too.
        ys.append(Int64(500 + i))
        us.append(Int64(900 + i))

    var sb = SchemaBuilder()
    sb.add_field(Field("v", ArrowType.INT64, False))
    sb.add_field(Field(out_name, ArrowType.INT64, True))
    sb.add_field(Field("unrelated", ArrowType.INT64, True))
    return RecordBatch.from_columns_3(
        sb.build(),
        _nullable_i64(vs, List[Int]()),
        _nullable_i64(ys, [1, 6]),
        _nullable_i64(us, [2, 4]),
    )


def _surviving(sv: SelectionVector) raises -> List[Int]:
    var out = List[Int]()
    var ptr = sv.indices._typed_ptr_ro()
    for i in range(sv.length()):
        out.append(Int(ptr[unsafe_offset=i]))
    return out^


def _fmt(xs: List[Int]) -> String:
    var s = String("[")
    for i in range(len(xs)):
        if i > 0:
            s += ", "
        s += String(xs[i])
    return s + "]"


# ---------------------------------------------------------------------------
# ⭐ THE TEST THE COMMIT DID NOT HAVE.
# ---------------------------------------------------------------------------
def test_the_walk_names_the_UDFs_OWN_OUTPUT_COLUMN_and_no_other() raises:
    """★★ THE PIN. `_compute_predicate_input_validity` is asked directly, so
    the answer cannot be confounded by what a comparison kernel does with
    validity on the way past.

    Three implementations, three DIFFERENT return values:

      SHIPPED (name the output column)  Some(bitmap), cleared at 1 and 6 ONLY
      bare `return` ("skip it")         None — no referenced column carries a
                                        validity bitmap, because none was named
      no arm (conservative fallback)    Some(bitmap), cleared at 1, 2, 4 and 6

    ⛔ THE THIRD IS THE DEFECT THE ARM FIXES. THE SECOND IS THE READING IT
    ARGUES AGAINST AND NOTHING ELSE CAN SEE — replacing the arm body with a
    bare `return` gives byte-identical results across the UDF end-to-end suite.
    """
    var batch = _batch(True)
    var pred = _predicate()
    var iv = _compute_predicate_input_validity(pred, batch)

    assert_true(
        iv.__bool__(),
        "the walk contributed NO column with a validity bitmap, so the"
        " predicate's input validity is None. ⛔ That is the `skip the UDF"
        " call` reading: the UDF output's OWN nulls would then be honoured by"
        " nothing at this layer. The shipped arm NAMES the output column, so"
        " its validity must come back here.",
    )

    ref bits = iv.value()
    for i in range(_N):
        var want_valid = i != 1 and i != 6
        var got_valid = bits.test(i)
        var why = String("input-validity bit ")
        why += String(i)
        why += " is "
        why += String(got_valid)
        why += ", want "
        why += String(want_valid)
        why += (
            ". Rows 1 and 6 are NULL in the UDF's OWN OUTPUT column and must"
            " be cleared; rows 2 and 4 are NULL in `unrelated`, which this"
            " predicate never reads, and must stay SET. A cleared bit at 2 or"
            " 4 is the conservative fallback — the arm is gone, and this is"
            " the over-dropping defect exactly."
        )
        assert_equal(got_valid, want_valid, why)

    _ = batch^
    _ = pred^


def test_the_walk_is_not_merely_returning_the_whole_batchs_validity() raises:
    """⚠ THE NEGATIVE CONTROL FOR THE PIN ABOVE, and it is not decoration.

    `Some(bitmap)` with bits cleared at 1 and 6 is ALSO what a walk that named
    the WRONG column would return if that column happened to share the null
    pattern. So: ask the same function about a predicate over `unrelated`
    ALONE, and require the ANSWER TO MOVE — bits 2 and 4 cleared, 1 and 6 set.
    One function, two predicates, two different answers ⇒ it is reading the
    predicate, not the batch.
    """
    var batch = _batch(True)
    var other = Expr.binary(
        BIN_GT,
        Expr.col_ref("unrelated"),
        Expr.literal(ScalarValue.from_int64(0)),
    )
    var iv = _compute_predicate_input_validity(other, batch)
    assert_true(iv.__bool__(), "`unrelated > 0` names a nullable column")
    ref bits = iv.value()
    for i in range(_N):
        var want_valid = i != 2 and i != 4
        assert_equal(
            bits.test(i),
            want_valid,
            "control predicate `unrelated > 0`: bit "
            + String(i)
            + " should follow `unrelated`'s nulls (2, 4), not the UDF output's"
            " (1, 6). If this matches the UDF pattern the walk is returning a"
            " property of the BATCH and the pin above is vacuous.",
        )
    _ = batch^
    _ = other^


def test_the_fixture_can_tell_the_three_implementations_apart() raises:
    """⚠ THE FIXTURE-DISCRIMINATION GATE. A fixture that cannot fail is a
    common failure; this asserts the property that makes a RED
    above mean something, on every run.

    The two null sets must be NON-EMPTY and DISJOINT — if the UDF output's
    nulls were a subset of `unrelated`'s, "name the output column" and "AND
    every column" would agree and the pin would be vacuous.
    """
    var udf_nulls: List[Int] = [1, 6]
    var other_nulls: List[Int] = [2, 4]
    assert_true(len(udf_nulls) > 0, "the UDF output column carries no nulls")
    assert_true(len(other_nulls) > 0, "the unrelated column carries no nulls")
    for i in range(len(udf_nulls)):
        for j in range(len(other_nulls)):
            assert_true(
                udf_nulls[i] != other_nulls[j],
                "the two null sets overlap at row "
                + String(udf_nulls[i])
                + ", so naming the output column and ANDing every column would"
                " return the SAME rows and the pin would be vacuous",
            )
    assert_true(
        len(udf_nulls) + len(other_nulls) < _N,
        "the nulls cover the whole batch, so every candidate returns the empty"
        " set",
    )
    # ⛔ AND THE ARGUMENT COLUMN MUST BE NULL-FREE, or this fixture asks for
    # `_run_thunk`'s already-correct argument refusal instead of this arm.
    var batch = _batch(True)
    assert_equal(
        batch.column_at(0).null_count(),
        0,
        "`v` (the UDF ARGUMENT) carries nulls; a null-bearing argument is"
        " REFUSED BY NAME on every live route, so a fixture with one measures"
        " that refusal and not this walk",
    )
    _ = batch^


# ---------------------------------------------------------------------------
# ⚠ AND WHETHER IT REACHES AN ANSWER — a SEPARATE question, measured.
# ---------------------------------------------------------------------------
def test_end_to_end_the_null_bearing_udf_output_drops_only_its_own_rows(
) raises:
    """The same batch through the production filter boundary.

    ⚠ THIS CELL DOES **NOT** SEE THE NAMING AND IS NOT CLAIMED TO. A computed
    LHS routes through `_eval_col_vs_col_promoted` -> `_col_cmp_nullable`,
    which propagates the LHS column's validity into the BooleanArray's OWN
    validity, and `_collapse_nulls_to_false`'s FIRST step (`data &= validity`)
    already clears rows 1 and 6 before `input_validity` is consulted. So a
    build with the arm replaced by a bare `return` returns THIS SAME ROW SET.

    What it does pin is the half that IS reachable: rows 2 and 4 — NULL in a
    column the predicate never reads — must SURVIVE. That is the conservative
    fallback, i.e. the shipped defect, and this cell goes red on it.
    """
    var batch = _batch(True)
    var sv = evaluate_filter_narrowed(batch, _predicate())
    var got = _surviving(sv)
    var want: List[Int] = [0, 2, 3, 4, 5, 7]

    var why = String("`affine_nd(v) > 100` kept ")
    why += _fmt(got)
    why += " of 8 rows, want "
    why += _fmt(want)
    why += (
        ". ⛔ [0, 3, 5, 7] means the `EXPR_UDF_CALL` arm is gone and the"
        " conservative fallback ANDed `unrelated`'s validity into a predicate"
        " that never read it — MEASURED as this exact row set"
        " with the arm deleted. ALL EIGHT means the UDF output's own nulls"
        " reached the answer as data."
    )
    assert_equal(len(got), len(want), why)
    for i in range(len(want)):
        assert_equal(got[i], want[i], why)
    _ = batch^


def test_end_to_end_an_ARITHMETIC_WRAPPED_udf_call_keeps_the_same_rows(
) raises:
    """`affine_nd(v) + 1 > 100` — the same call one node deeper, so the
    comparison kernel no longer sees the UDF column directly.

    ⭐ WHY THE SHAPE IS HERE AT ALL: it is the candidate for an end-to-end cell
    that CAN see the naming, if the arithmetic kernel does not carry validity
    through. Whether it does is a fact about the kernels, and this cell
    measures it rather than asserting a story about it. Either way the ROW SET
    is the same one — rows 2 and 4 survive, rows 1 and 6 do not — so this is a
    correctness assertion in its own right, not only a probe.
    """
    var batch = _batch(True)
    var sv = evaluate_filter_narrowed(batch, _predicate_wrapped())
    var got = _surviving(sv)
    var want: List[Int] = [0, 2, 3, 4, 5, 7]
    var why = String("`affine_nd(v) + 1 > 100` kept ")
    why += _fmt(got)
    why += ", want "
    why += _fmt(want)
    why += (
        ". Same rows as the unwrapped shape: an arithmetic node between the"
        " UDF call and the comparison changes which layer honours the NULLs,"
        " never which rows the predicate selects."
    )
    assert_equal(len(got), len(want), why)
    for i in range(len(want)):
        assert_equal(got[i], want[i], why)
    _ = batch^


def test_an_UNRESOLVABLE_UDF_KEY_never_reaches_the_conservative_branch(
) raises:
    """⛔⛔ THE ARM'S OTHER CLAIM IS UNREACHABLE BY CONSTRUCTION, AND THIS
    RECORDS IT RATHER THAN LETTING IT READ AS A TESTED SAFETY PROPERTY.

    The shipped arm ends:

        conservative = True
        return

    under a comment arguing that a key resolving to no column must stay
    CONSERVATIVE because "the pre-pass did not run and `_eval_predicate` is
    about to raise for that reason". The second half of that sentence is what
    makes the first half DEAD CODE: `evaluate_predicate_selected` calls
    `_eval_predicate` BEFORE `_compute_predicate_input_validity`, and
    `_eval_column_expr`'s UDF arm raises `the UDF ... was not materialized onto
    this batch` at the missing lookup. The validity walk never runs.

    ⇒ Through THIS caller there is no difference between "conservative" and
    "contributes nothing". This test asserts the REFUSAL — what actually
    happens on this path — and it keeps asserting it.

    ⭐ `conjunction.predicate_null_scope_unhandled_tag` computes validity
    coverage WITHOUT evaluating first, so the branch is LIVE for the UDF
    filter door, where it produces a named refusal
    (`UDF_FILTER_PREDICATE_NULL_SCOPE_UNDERIVABLE`). This cell stays GREEN
    because it drives `evaluate_filter_narrowed` directly — the
    evaluate-first path — which is exactly the path it was written to pin. The
    branch's own behaviour is asserted by the sibling below.
    """
    var batch = _batch(False)
    with assert_raises(contains="was not materialized onto this batch"):
        _ = evaluate_filter_narrowed(batch, _predicate())
    _ = batch^


def test_the_conservative_branch_IS_correct_when_it_is_reached_directly(
) raises:
    """...and it is reachable HERE, one layer below the raise, so the branch is
    at least asserted to do what it says rather than merely commented.

    Asking `_compute_predicate_input_validity` directly (no `_eval_predicate`
    in front of it) over a batch missing the `__udf:` column must AND EVERY
    column — bits cleared at 1, 2, 4 AND 6 — which is the fail-CLOSED direction
    the comment argues for. A `None` here would be the fail-OPEN one.
    """
    var batch = _batch(False)
    var pred = _predicate()
    var iv = _compute_predicate_input_validity(pred, batch)
    assert_true(
        iv.__bool__(),
        "an unresolvable UDF key returned None (fail-OPEN) instead of going"
        " conservative over a batch this walk cannot read",
    )
    ref bits = iv.value()
    for i in range(_N):
        var want_valid = i != 1 and i != 2 and i != 4 and i != 6
        assert_equal(
            bits.test(i),
            want_valid,
            "conservative fallback: bit "
            + String(i)
            + " must follow the AND of EVERY column's validity",
        )
    _ = batch^
    _ = pred^


def main() raises:
    var ts = TestSuite()
    ts.test[test_the_walk_names_the_UDFs_OWN_OUTPUT_COLUMN_and_no_other]()
    ts.test[test_the_walk_is_not_merely_returning_the_whole_batchs_validity]()
    ts.test[test_the_fixture_can_tell_the_three_implementations_apart]()
    ts.test[
        test_end_to_end_the_null_bearing_udf_output_drops_only_its_own_rows
    ]()
    ts.test[
        test_end_to_end_an_ARITHMETIC_WRAPPED_udf_call_keeps_the_same_rows
    ]()
    ts.test[test_an_UNRESOLVABLE_UDF_KEY_never_reaches_the_conservative_branch]()
    ts.test[test_the_conservative_branch_IS_correct_when_it_is_reached_directly]()
    ts^.run()
