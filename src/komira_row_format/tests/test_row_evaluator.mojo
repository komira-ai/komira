# =============================================================================
# `komira_row_format.row_evaluator`: `RowExprBoolEvaluator` and
# `selected_row_indices`.
# =============================================================================
#
# WHAT THIS PROVES
# ----------------
# Each of the six comparison ops, evaluated over the cell at a comptime byte
# offset of every row, against a literal. The cells hold LIT - 1, LIT, LIT + 1
# and values far either side, so each op is told apart from its neighbours (a
# `>` that became `>=` changes the LIT row; a `<` that became `<=` too). The
# cell sits at byte 3 of a 7-byte row, little-endian and unaligned, written a
# byte at a time, so the evaluator must read the documented layout at the
# right row stride. `eval_batch` writes only rows below `n_rows`; the mask
# entries past it keep what they held. A float instantiation pins IEEE
# behaviour for NaN (every ordered comparison false, `!=` true).
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_false, assert_true

from komira_row_format.row_block import RowBlock
from komira_row_format.row_evaluator import (
    ROW_PRED_EQ,
    ROW_PRED_GE,
    ROW_PRED_GT,
    ROW_PRED_LE,
    ROW_PRED_LT,
    ROW_PRED_NE,
    RowExprBoolEvaluator,
    selected_row_indices,
)

comptime _STRIDE = 7
comptime _OFF = 3


def _block(vals: List[Int32]) raises -> RowBlock:
    """One i32 cell per row at byte 3 of a 7-byte row, written byte by byte
    least significant first; the other bytes hold 0xA5."""
    var rb = RowBlock.with_capacity(len(vals), 0, _STRIDE)
    rb.set_n_rows(len(vals))
    for r in range(len(vals)):
        for off in range(_STRIDE):
            rb.write_fixed[DType.uint8](r, off, 0xA5)
        var u = vals[r].cast[DType.uint32]()
        for i in range(4):
            rb.write_fixed[DType.uint8](
                r, _OFF + i, UInt8((u >> UInt32(8 * i)) & 0xFF)
            )
    return rb^


def _vals() -> List[Int32]:
    # Rows: 0 far below, 1 LIT-1, 2 LIT, 3 LIT+1, 4 far above, 5 LIT.
    return [-1000000, 99, 100, 101, 0x01020304, 100]


def _run[op: UInt8](rb: RowBlock, n: Int) -> List[Bool]:
    var mask = List[Bool](length=rb.n_rows, fill=False)
    RowExprBoolEvaluator[op, _OFF, DType.int32, Int32(100)].make().eval_batch(
        rb, n, mask
    )
    return mask^


def test_each_op_against_neighbours() raises:
    """Truth table over rows (-1e6, 99, 100, 101, 0x01020304, 100) against
    LIT = 100."""
    var rb = _block(_vals())
    var n = rb.n_rows
    assert_equal(_run[ROW_PRED_GT](rb, n), [False, False, False, True, True, False])
    assert_equal(_run[ROW_PRED_GE](rb, n), [False, False, True, True, True, True])
    assert_equal(_run[ROW_PRED_LT](rb, n), [True, True, False, False, False, False])
    assert_equal(_run[ROW_PRED_LE](rb, n), [True, True, True, False, False, True])
    assert_equal(_run[ROW_PRED_EQ](rb, n), [False, False, True, False, False, True])
    assert_equal(_run[ROW_PRED_NE](rb, n), [True, True, False, True, True, False])


def test_eval_batch_writes_only_first_n_rows() raises:
    """Rows at or past n_rows keep their mask entry: with n = 3 over a mask
    pre-filled True, EQ writes rows 0..2 only (row 5, also 100, stays
    True and row 4, not 100, stays True)."""
    var rb = _block(_vals())
    var mask = List[Bool](length=6, fill=True)
    RowExprBoolEvaluator[ROW_PRED_EQ, _OFF, DType.int32, Int32(100)]().eval_batch(
        rb, 3, mask
    )
    assert_equal(mask, [False, False, True, True, True, True])
    var none = List[Bool](length=6, fill=True)
    RowExprBoolEvaluator[ROW_PRED_GT, _OFF, DType.int32, Int32(100)]().eval_batch(
        rb, 0, none
    )
    assert_equal(none, [True, True, True, True, True, True])


def test_eval_one_float_nan() raises:
    """f64 instantiation: NaN fails every ordered comparison and `==`, passes
    `!=`; -0.0 equals the literal 0.0."""
    var zero = Float64(0)
    var nan = zero / zero
    var gt = RowExprBoolEvaluator[ROW_PRED_GT, 0, DType.float64, 0.0].make()
    var ge = RowExprBoolEvaluator[ROW_PRED_GE, 0, DType.float64, 0.0].make()
    var lt = RowExprBoolEvaluator[ROW_PRED_LT, 0, DType.float64, 0.0].make()
    var le = RowExprBoolEvaluator[ROW_PRED_LE, 0, DType.float64, 0.0].make()
    var eq = RowExprBoolEvaluator[ROW_PRED_EQ, 0, DType.float64, 0.0].make()
    var ne = RowExprBoolEvaluator[ROW_PRED_NE, 0, DType.float64, 0.0].make()
    assert_false(gt.eval_one(nan))
    assert_false(ge.eval_one(nan))
    assert_false(lt.eval_one(nan))
    assert_false(le.eval_one(nan))
    assert_false(eq.eval_one(nan))
    assert_true(ne.eval_one(nan))
    assert_true(eq.eval_one(-0.0))
    assert_false(ne.eval_one(-0.0))
    assert_true(gt.eval_one(5e-324))
    assert_true(lt.eval_one(-5e-324))


def test_selected_row_indices() raises:
    """Indices of the True entries among the first n, ascending; entries at
    or past n are not scanned."""
    var mask: List[Bool] = [True, False, True, True, False, True, True]
    assert_equal(selected_row_indices(mask, 7), [0, 2, 3, 5, 6])
    assert_equal(selected_row_indices(mask, 6), [0, 2, 3, 5])
    assert_equal(selected_row_indices(mask, 1), [0])
    assert_equal(len(selected_row_indices(mask, 0)), 0)
    var none = List[Bool](length=9, fill=False)
    assert_equal(len(selected_row_indices(none, 9)), 0)


def test_filter_then_select() raises:
    """The evaluator's mask feeds selected_row_indices: rows >= 100."""
    var rb = _block(_vals())
    var mask = _run[ROW_PRED_GE](rb, rb.n_rows)
    assert_equal(selected_row_indices(mask, rb.n_rows), [2, 3, 4, 5])


def main() raises:
    var s = TestSuite()
    s.test[test_each_op_against_neighbours]()
    s.test[test_eval_batch_writes_only_first_n_rows]()
    s.test[test_eval_one_float_nan]()
    s.test[test_selected_row_indices]()
    s.test[test_filter_then_select]()
    s^.run()
