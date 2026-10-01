# =============================================================================
# Regression: RowBlock incremental reserve_rows + write_fixed must NOT zero
# previously-written rows on a doubling regrow.
# =============================================================================
#
# A silent-correctness hazard: if RowBlock.with_capacity / reserve_rows /
# write_fixed grow `_fixed_storage.capacity` without advancing the underlying
# `OwnedAlignedBuffer._length`, it stays 0. `OwnedAlignedBuffer.reserve`
# preserves only `keep = _length` (= 0) bytes on a regrow (`memcpy` of 0 bytes)
# and `memset`-zeroes the rest. So every amortized-doubling regrow ZEROED all
# previously-written rows. The row hash-agg inserts groups one at a time via
# `reserve_rows(1)`; past the 16,384 -> 32,768 regrow the prior 16,384 rows
# became key-0, the directory re-missed real keys and re-inserted them, and
# the agg over-produced phantom key-0 groups (26,384 vs 10,000 expected).
#
# This is the MINIMAL landmine repro: insert > 16,384 fixed-width rows one
# `reserve_rows(1)`-then-`write_fixed`-at-a-time (forcing >= 1 doubling regrow
# past 16,384), then read every row back and assert NONE was zeroed — row i
# must hold the value written for row i, not 0.
#
# FAIL-BEFORE the fix (rows below the last regrow boundary read back as 0);
# PASS-AFTER the fix (RowBlock keeps `_fixed_storage._length` in sync so the
# regrow `memcpy` preserves ALL written rows).
# =============================================================================

from std.testing import TestSuite, assert_equal

from komira_eval.row_format import RowBlock


def test_row_block_incremental_regrow_preserves_rows() raises:
    """Insert N > 16,384 rows one (reserve_rows(1), write_fixed) at a time;
    every row must read back intact (no zeroing across doubling regrows).
    """
    # 8-byte stride: one i64 cell per row.
    comptime STRIDE = 8
    # Past the 16,384 -> 32,768 doubling boundary; an odd-ish value to make
    # any off-by-one obvious.
    var n = 20_000

    var rb = RowBlock.with_capacity(0, 0, STRIDE)

    for i in range(n):
        var new_row = rb.n_rows
        rb.reserve_rows(1)
        # Encode a value that is uniquely tied to the row index and never 0
        # (so a zeroed cell is unambiguously detectable). +1 keeps row 0 != 0.
        rb.write_fixed[DType.int64](new_row, 0, Int64(i + 1))
        rb.set_n_rows(new_row + 1)

    assert_equal(rb.n_rows, n)

    # Read EVERY row back. A regrow that lost data shows up as a 0 cell.
    var zeroed_count = 0
    var mismatch_count = 0
    for i in range(n):
        var v = rb.read_fixed[DType.int64](i, 0)
        if v == 0:
            zeroed_count += 1
        if v != Int64(i + 1):
            mismatch_count += 1

    assert_equal(zeroed_count, 0)
    assert_equal(mismatch_count, 0)


def test_row_block_incremental_regrow_multi_cell_stride() raises:
    """Same landmine with a wider stride (2 i64 cells per row) + a second
    column at offset 8 — confirms the length-sync covers the full row stride,
    not just the first cell.
    """
    comptime STRIDE = 16
    var n = 18_000

    var rb = RowBlock.with_capacity(0, 0, STRIDE)

    for i in range(n):
        var new_row = rb.n_rows
        rb.reserve_rows(1)
        rb.write_fixed[DType.int64](new_row, 0, Int64(i + 1))
        rb.write_fixed[DType.int64](new_row, 8, Int64((i + 1) * 7))
        rb.set_n_rows(new_row + 1)

    assert_equal(rb.n_rows, n)

    for i in range(n):
        var a = rb.read_fixed[DType.int64](i, 0)
        var b = rb.read_fixed[DType.int64](i, 8)
        assert_equal(a, Int64(i + 1))
        assert_equal(b, Int64((i + 1) * 7))


def main() raises:
    var s = TestSuite()
    s.test[test_row_block_incremental_regrow_preserves_rows]()
    s.test[test_row_block_incremental_regrow_multi_cell_stride]()
    s^.run()
