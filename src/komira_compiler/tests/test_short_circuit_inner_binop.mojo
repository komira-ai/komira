# =============================================================================
# Tests for inner-BinaryOp short-circuit AND/OR
#
# Verified at the predicate-evaluator
# layer (`compiler_eval_predicate.mojo::_eval_short_circuit_and / _or`). The
# top-level conjunction narrowing is already tested by
# `test_conjunction_narrowing.mojo`; this file targets the inner BinaryOp
# path that the conjunction-flattener can't reach (e.g. OR-of-ANDs).
#
# Each AND test exercises the four cases:
#   1. left_true == 0          -> all-false; right not evaluated (correctness only)
#   2. left_true == num_rows   -> result == right alone
#   3. left_true < num_rows/2  -> selective: gather + eval right + scatter back
#   4. else                     -> non-selective: eval right + bitwise AND
# Each OR test exercises the equivalent three cases (no selective case).
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_true, assert_false

from komira_core.arrow.primitive_array import PrimitiveArray
from komira_core.arrow.boolean_array import BooleanArray
from komira_core.arrow.column import Column
from komira_core.arrow.record_batch import RecordBatch
from komira_core.arrow.schema import Schema, SchemaBuilder, Field, RecordBatchBuilder
from komira_core.arrow.arrow_types import ArrowType

from komira_core.plan.expr import (
    Expr,
    BIN_AND,
    BIN_OR,
    BIN_GT,
    BIN_LT,
    BIN_EQ,
    UN_NOT,
)
from komira_core.plan.scalar_value import ScalarValue
from komira_compiler.compiler_eval_predicate import _eval_predicate


# ---------------------------------------------------------------------------
# helpers
# ---------------------------------------------------------------------------


def _build_int_batch(name: String, vals: List[Int64]) raises -> RecordBatch:
    """Build a single-column non-nullable INT64 RecordBatch.

    Mirror of `_build_int_batch` in `test_conjunction_narrowing.mojo`.
    """
    var prim_vals = List[Scalar[DType.int64]]()
    for i in range(len(vals)):
        prim_vals.append(Scalar[DType.int64](vals[i]))
    var arr = PrimitiveArray[DType.int64].from_list(prim_vals)
    var sb = SchemaBuilder()
    sb.add_field(Field(name, ArrowType.INT64, False))
    return RecordBatch.from_columns_1(sb.build(), arr^)


def _col_gt_lit(name: String, v: Int64) -> Expr:
    return Expr.binary(
        BIN_GT,
        Expr.col_ref(name),
        Expr.literal(ScalarValue.from_int64(v)),
    )


def _col_lt_lit(name: String, v: Int64) -> Expr:
    return Expr.binary(
        BIN_LT,
        Expr.col_ref(name),
        Expr.literal(ScalarValue.from_int64(v)),
    )


def _col_eq_lit(name: String, v: Int64) -> Expr:
    return Expr.binary(
        BIN_EQ,
        Expr.col_ref(name),
        Expr.literal(ScalarValue.from_int64(v)),
    )


def _bool_count(mask: BooleanArray) -> Int:
    return mask.true_count()


# ---------------------------------------------------------------------------
# AND case 1: left_true == 0 -> short-circuit, all-false.
# ---------------------------------------------------------------------------


def test_and_case1_left_all_false() raises:
    """`a > 100 AND a > 5` on values 0..10 -> left is all-false; result is all-false."""
    var vals: List[Int64] = [0, 1, 2, 3, 4, 5, 6, 7, 8, 9]
    var batch = _build_int_batch(String("a"), vals)
    var left = _col_gt_lit(String("a"), 100)
    var right = _col_gt_lit(String("a"), 5)
    var pred = Expr.binary(BIN_AND, left^, right^)
    var mask = _eval_predicate(pred, batch)
    assert_equal(_bool_count(mask), 0)


# ---------------------------------------------------------------------------
# AND case 2: left_true == num_rows -> result == right alone.
# ---------------------------------------------------------------------------


def test_and_case2_left_all_true() raises:
    """`a >= 0 AND a > 5` on values 0..10 -> left is all-true; result == right."""
    var vals: List[Int64] = [0, 1, 2, 3, 4, 5, 6, 7, 8, 9]
    var batch = _build_int_batch(String("a"), vals)
    # `a > -1` is all-true for non-negative vals.
    var left = _col_gt_lit(String("a"), -1)
    var right = _col_gt_lit(String("a"), 5)
    var pred = Expr.binary(BIN_AND, left^, right^)
    var mask = _eval_predicate(pred, batch)
    # a > 5 -> {6,7,8,9} pass = 4 rows
    assert_equal(_bool_count(mask), 4)
    assert_false(mask.data.test(5))
    assert_true(mask.data.test(6))


# ---------------------------------------------------------------------------
# AND case 3: left_true < num_rows/2 -> selective gather + scatter.
# ---------------------------------------------------------------------------


def test_and_case3_selective_left() raises:
    """`a > 7 AND a < 9` on values 0..10 -> left passes 2/10 (<50%);
    selective path filters to {8,9} sub-batch, evals right (a < 9 -> {8}), scatters back.
    Expected: only row index 8 survives.
    """
    var vals: List[Int64] = [0, 1, 2, 3, 4, 5, 6, 7, 8, 9]
    var batch = _build_int_batch(String("a"), vals)
    var left = _col_gt_lit(String("a"), 7)
    var right = _col_lt_lit(String("a"), 9)
    var pred = Expr.binary(BIN_AND, left^, right^)
    var mask = _eval_predicate(pred, batch)
    assert_equal(_bool_count(mask), 1)
    assert_true(mask.data.test(8))
    assert_false(mask.data.test(7))
    assert_false(mask.data.test(9))


def test_and_case3_selective_left_zero_survivors() raises:
    """`a > 7 AND a > 100` on values 0..10 -> left passes 2/10, selective path
    fires; right rejects every survivor. Result must be all-false.
    """
    var vals: List[Int64] = [0, 1, 2, 3, 4, 5, 6, 7, 8, 9]
    var batch = _build_int_batch(String("a"), vals)
    var left = _col_gt_lit(String("a"), 7)
    var right = _col_gt_lit(String("a"), 100)
    var pred = Expr.binary(BIN_AND, left^, right^)
    var mask = _eval_predicate(pred, batch)
    assert_equal(_bool_count(mask), 0)


# ---------------------------------------------------------------------------
# AND case 4: non-selective -> eval right on full batch, bitwise AND.
# ---------------------------------------------------------------------------


def test_and_case4_non_selective() raises:
    """`a > 2 AND a < 8` on values 0..10 -> left passes 7/10 (>50%); non-selective
    path evaluates right on full batch and bitwise-ANDs. Expected: rows 3..7.
    """
    var vals: List[Int64] = [0, 1, 2, 3, 4, 5, 6, 7, 8, 9]
    var batch = _build_int_batch(String("a"), vals)
    var left = _col_gt_lit(String("a"), 2)
    var right = _col_lt_lit(String("a"), 8)
    var pred = Expr.binary(BIN_AND, left^, right^)
    var mask = _eval_predicate(pred, batch)
    # Expected: a in {3,4,5,6,7} = 5 rows
    assert_equal(_bool_count(mask), 5)
    for i in range(3, 8):
        assert_true(mask.data.test(i))
    assert_false(mask.data.test(2))
    assert_false(mask.data.test(8))


# ---------------------------------------------------------------------------
# OR case 1: left_true == num_rows -> short-circuit, all-true.
# ---------------------------------------------------------------------------


def test_or_case1_left_all_true() raises:
    """`a > -1 OR a > 100` -> left is all-true; result is all-true."""
    var vals: List[Int64] = [0, 1, 2, 3, 4, 5, 6, 7, 8, 9]
    var batch = _build_int_batch(String("a"), vals)
    var left = _col_gt_lit(String("a"), -1)
    var right = _col_gt_lit(String("a"), 100)
    var pred = Expr.binary(BIN_OR, left^, right^)
    var mask = _eval_predicate(pred, batch)
    assert_equal(_bool_count(mask), 10)


# ---------------------------------------------------------------------------
# OR case 2: left_true == 0 -> result == right alone.
# ---------------------------------------------------------------------------


def test_or_case2_left_all_false() raises:
    """`a > 100 OR a > 5` -> left is all-false; result == right."""
    var vals: List[Int64] = [0, 1, 2, 3, 4, 5, 6, 7, 8, 9]
    var batch = _build_int_batch(String("a"), vals)
    var left = _col_gt_lit(String("a"), 100)
    var right = _col_gt_lit(String("a"), 5)
    var pred = Expr.binary(BIN_OR, left^, right^)
    var mask = _eval_predicate(pred, batch)
    # a > 5 -> {6,7,8,9} = 4 rows
    assert_equal(_bool_count(mask), 4)
    assert_true(mask.data.test(6))
    assert_false(mask.data.test(5))


# ---------------------------------------------------------------------------
# OR case 3: mixed -> eval both, bitwise OR.
# ---------------------------------------------------------------------------


def test_or_case3_mixed() raises:
    """`a < 3 OR a > 6` -> mixed; result is rows 0,1,2 + 7,8,9 = 6 rows."""
    var vals: List[Int64] = [0, 1, 2, 3, 4, 5, 6, 7, 8, 9]
    var batch = _build_int_batch(String("a"), vals)
    var left = _col_lt_lit(String("a"), 3)
    var right = _col_gt_lit(String("a"), 6)
    var pred = Expr.binary(BIN_OR, left^, right^)
    var mask = _eval_predicate(pred, batch)
    assert_equal(_bool_count(mask), 6)
    for i in range(0, 3):
        assert_true(mask.data.test(i))
    for i in range(7, 10):
        assert_true(mask.data.test(i))
    assert_false(mask.data.test(5))


# ---------------------------------------------------------------------------
# Nested AND-OR — exercises the inner short-circuit path the
# conjunction-flattener can NOT reach.
# Predicate: (a > 2 AND a < 5) OR (a > 7 AND a < 9)
# Expected: a in {3,4,8} = 3 rows
# ---------------------------------------------------------------------------


def test_nested_or_of_ands() raises:
    """OR-of-ANDs where the flattener stops at the OR; each AND sub-tree
    exercises the inner short-circuit (case-3 selective path on both sides)."""
    var vals: List[Int64] = [0, 1, 2, 3, 4, 5, 6, 7, 8, 9]
    var batch = _build_int_batch(String("a"), vals)

    var lhs_and = Expr.binary(
        BIN_AND, _col_gt_lit(String("a"), 2), _col_lt_lit(String("a"), 5)
    )
    var rhs_and = Expr.binary(
        BIN_AND, _col_gt_lit(String("a"), 7), _col_lt_lit(String("a"), 9)
    )
    var pred = Expr.binary(BIN_OR, lhs_and^, rhs_and^)
    var mask = _eval_predicate(pred, batch)

    # Expected: {3,4,8} pass = 3 rows
    assert_equal(_bool_count(mask), 3)
    assert_true(mask.data.test(3))
    assert_true(mask.data.test(4))
    assert_true(mask.data.test(8))
    assert_false(mask.data.test(0))
    assert_false(mask.data.test(5))
    assert_false(mask.data.test(7))
    assert_false(mask.data.test(9))


# ---------------------------------------------------------------------------
# Empty-batch edge case — short-circuit must not crash when num_rows == 0.
# ---------------------------------------------------------------------------


def test_and_empty_batch() raises:
    """AND on an empty batch: left_true == 0 == num_rows; case 1 fires
    (returns left mask of length 0). Must not divide by zero / panic."""
    var vals: List[Int64] = []
    var batch = _build_int_batch(String("a"), vals)
    var left = _col_gt_lit(String("a"), 5)
    var right = _col_gt_lit(String("a"), 6)
    var pred = Expr.binary(BIN_AND, left^, right^)
    var mask = _eval_predicate(pred, batch)
    assert_equal(mask.length, 0)


# ---------------------------------------------------------------------------
# AND case 3 with an UNKNOWN on the RIGHT.
#
# Every case-3 test above has a NON-nullable right side, so none of them can
# see what the scatter does to a right-side UNKNOWN. It used to copy only the
# right's DATA bits into a fresh NON-nullable array, so `TRUE AND UNKNOWN` came
# back as FALSE, and an enclosing NOT then turned it into a SELECTED row. The
# left here is `a > 6` over a NEVER-null `a`: no validity, TRUE on 3 of 10
# rows, so the selective case is the one that runs. `_assert_selective_left`
# proves that on every cell, so a change to the case-3 threshold reds here
# rather than silently moving these cells to the full-batch Kleene combine.
#
# Rows 7, 8, 9 survive the left. The right side is TRUE on 7, UNKNOWN on 8,
# FALSE on 9. Row 8's NULL `b` holds 5 in its data slot, a value that WOULD
# pass `b = 5`, so an arm that reads a null row's data bit answers TRUE there.
# Rows 0..6 are FALSE on the left, and `FALSE AND anything` is FALSE.
# ---------------------------------------------------------------------------


def _selective_3vl_batch() raises -> RecordBatch:
    """a int64 [0..9], never NULL; b int64 = 5 everywhere but row 9 (= 4),
    NULL at row 8; f bool = TRUE everywhere but row 9 (FALSE), NULL at row 8.
    """
    comptime n = 10
    var avals = List[Scalar[DType.int64]]()
    for i in range(n):
        avals.append(Scalar[DType.int64](i))
    var a = PrimitiveArray[DType.int64].from_list(avals^)
    var b = PrimitiveArray[DType.int64].allocate_nullable(n)
    var f = BooleanArray.allocate_nullable(n)
    for i in range(n):
        b.set(i, Scalar[DType.int64](4 if i == 9 else 5))
        f.set(i, i != 9)
    b._set_null(8)
    f._set_null(8)
    var rbb = RecordBatchBuilder.with_capacity(3)
    rbb.add_column(
        Column.from_primitive_with_arrow_type[DType.int64](a^, ArrowType.INT64)
    )
    rbb.add_column(
        Column.from_primitive_with_arrow_type[DType.int64](b^, ArrowType.INT64)
    )
    rbb.add_column(Column.from_boolean(f^))
    var sb = SchemaBuilder()
    sb.add_field(Field(String("a"), ArrowType.INT64, False))
    sb.add_field(Field(String("b"), ArrowType.INT64, True))
    sb.add_field(Field(String("f"), ArrowType.BOOL, True))
    return rbb.build(sb.build())


def _tri(mask: BooleanArray) -> String:
    """One letter per row: T, F, or N for UNKNOWN (validity says null)."""
    var out = String("")
    for i in range(mask.length):
        if mask.validity and not mask.validity.value().test(i):
            out += "N"
        elif mask.data.test(i):
            out += "T"
        else:
            out += "F"
    return out


def _assert_selective_left(left: Expr, batch: RecordBatch) raises:
    """The premise: the left mask carries NO validity and is TRUE on fewer
    than half the rows (and on at least one), which is case 3's entry
    condition. Without this, every cell below could pass by reaching case 4."""
    var lm = _eval_predicate(left, batch)
    assert_false(
        Bool(lm.validity), "premise: left mask must carry no validity"
    )
    assert_true(lm.true_count() > 0, "premise: left must keep a survivor")
    assert_true(
        lm.true_count() < (batch.num_rows() >> 1),
        "premise: left must be TRUE on fewer than half the rows, got "
        + String(lm.true_count()),
    )


def _a_gt_6() -> Expr:
    return _col_gt_lit(String("a"), 6)


def _b_eq_5() -> Expr:
    return _col_eq_lit(String("b"), 5)


def _a_eq_null() -> Expr:
    return Expr.binary(
        BIN_EQ, Expr.col_ref("a"), Expr.literal(ScalarValue.null(DType.int64))
    )


def _check_tri(pred: Expr, batch: RecordBatch, want: String) raises:
    var got = _tri(_eval_predicate(pred, batch))
    assert_equal(got, want, "3VL rows (T/F/N): got " + got + " want " + want)


def test_and_case3_right_unknown_is_unknown_not_false() raises:
    """`a > 6 AND b = 5`: row 8 is TRUE AND UNKNOWN = UNKNOWN."""
    var batch = _selective_3vl_batch()
    _assert_selective_left(_a_gt_6(), batch)
    var pred = Expr.binary(BIN_AND, _a_gt_6(), _b_eq_5())
    _check_tri(pred, batch, String("FFFFFFFTNF"))


def test_and_case3_right_unknown_under_not() raises:
    """`NOT (a > 6 AND b = 5)`: row 8 stays UNKNOWN. Reported as FALSE, the
    NOT made it TRUE -- a row a WHERE would SELECT."""
    var batch = _selective_3vl_batch()
    var pred = Expr.unary(
        UN_NOT, Expr.binary(BIN_AND, _a_gt_6(), _b_eq_5())
    )
    _check_tri(pred, batch, String("TTTTTTTFNT"))


def test_and_case3_bare_bool_right_unknown() raises:
    """`a > 6 AND f` and its NOT: the bare BOOLEAN column as the right side."""
    var batch = _selective_3vl_batch()
    _check_tri(
        Expr.binary(BIN_AND, _a_gt_6(), Expr.col_ref("f")),
        batch,
        String("FFFFFFFTNF"),
    )
    _check_tri(
        Expr.unary(
            UN_NOT, Expr.binary(BIN_AND, _a_gt_6(), Expr.col_ref("f"))
        ),
        batch,
        String("TTTTTTTFNT"),
    )


def test_and_case3_null_literal_right_is_unknown_on_every_survivor() raises:
    """`a > 6 AND a = NULL`: every survivor is UNKNOWN; the NOT keeps them
    UNKNOWN rather than selecting them."""
    var batch = _selective_3vl_batch()
    _check_tri(
        Expr.binary(BIN_AND, _a_gt_6(), _a_eq_null()),
        batch,
        String("FFFFFFFNNN"),
    )
    _check_tri(
        Expr.unary(UN_NOT, Expr.binary(BIN_AND, _a_gt_6(), _a_eq_null())),
        batch,
        String("TTTTTTTNNN"),
    )


def test_and_case3_right_unknown_travels_through_an_enclosing_or() raises:
    """`(a > 6 AND f) OR a < 0`: the OR-of-ANDs shape this inner short-circuit
    exists for. The OR's right is FALSE everywhere, so `UNKNOWN OR FALSE` must
    stay UNKNOWN on row 8 -- it can only if the AND handed the UNKNOWN up."""
    var batch = _selective_3vl_batch()
    var pred = Expr.binary(
        BIN_OR,
        Expr.binary(BIN_AND, _a_gt_6(), Expr.col_ref("f")),
        _col_lt_lit(String("a"), 0),
    )
    _check_tri(pred, batch, String("FFFFFFFTNF"))


def test_and_case3_fully_known_right_attaches_no_validity() raises:
    """CONTROL. A right side with no validity keeps case 3's result
    non-nullable: the fix attaches validity only when the right has UNKNOWNs,
    so an all-valid predicate pays nothing and downstream fast paths that key
    on `validity` being absent still take it."""
    var batch = _selective_3vl_batch()
    var pred = Expr.binary(BIN_AND, _a_gt_6(), _col_lt_lit(String("a"), 9))
    var mask = _eval_predicate(pred, batch)
    assert_equal(_tri(mask), String("FFFFFFFTTF"))
    assert_false(Bool(mask.validity), "a fully-known AND must stay non-nullable")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
