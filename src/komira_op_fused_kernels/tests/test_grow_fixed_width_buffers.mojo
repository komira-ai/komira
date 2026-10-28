# =============================================================================
# The output buffers of the fused and chunked join kernels, grown twice.
#
# The kernels write cells through the buffer's pointer and grow each buffer
# by copying its first `rows_kept` rows into a larger one. A grown buffer's
# length must equal its capacity, as a fresh buffer's does: the next grow
# views `[0, rows_kept)` of it, and the rows written after the first copy lie
# past that copy's length. These tests check the length after each grow and
# read every row back through the length-bounded typed accessor.
# =============================================================================

from std.testing import TestSuite, assert_equal

from komira_buffer.owned_aligned_buffer import OwnedAlignedBuffer
from komira_collections.slab import Slab

from komira_op_fused_kernels.join_fused_gather import (
    _fixed_width_buffers,
    _grow_fixed_width_buffers,
)


def _write_rows(mut bufs: Slab[OwnedAlignedBuffer], start: Int, end: Int):
    """Rows `[start, end)`: column 0 (8 bytes) holds 1000 + row, column 1
    (2 bytes) holds 0 - row."""
    for r in range(start, end):
        bufs[0].set_typed[Int64](r, Int64(1000 + r))
        bufs[1].set_typed[Int16](r, Int16(-r))


def _check_rows(bufs: Slab[OwnedAlignedBuffer], rows: Int) raises:
    for r in range(rows):
        assert_equal(bufs[0].get_typed[Int64](r), Int64(1000 + r))
        assert_equal(bufs[1].get_typed[Int16](r), Int16(-r))


def test_grow_twice_keeps_length_at_capacity() raises:
    """Each grow leaves every buffer's length at `new_rows * element size`.

    Catches a grow that leaves the length at the copied prefix (the length
    `copy_from_view` sets): after the first grow the length would be
    2 rows, not 4."""
    var es: List[Int] = [8, 2]
    var bufs = _fixed_width_buffers(es, 2)
    assert_equal(bufs[0].len(), 16)
    assert_equal(bufs[1].len(), 4)
    _write_rows(bufs, 0, 2)
    _grow_fixed_width_buffers(bufs, es, 2, 4)
    assert_equal(bufs[0].len(), 4 * 8)
    assert_equal(bufs[1].len(), 4 * 2)
    _write_rows(bufs, 2, 4)
    _grow_fixed_width_buffers(bufs, es, 4, 8)
    assert_equal(bufs[0].len(), 8 * 8)
    assert_equal(bufs[1].len(), 8 * 2)


def test_grow_twice_keeps_rows_written_after_first_copy() raises:
    """Rows 2 and 3, written into the buffer the first grow made, survive
    the second grow, as do rows 0 and 1 from before it; rows 4 to 7 are
    written into the second grown buffer.

    Catches a grow that copies fewer than `rows_kept` rows (rows 2 and 3
    would be lost) or copies from the wrong offset."""
    var es: List[Int] = [8, 2]
    var bufs = _fixed_width_buffers(es, 2)
    _write_rows(bufs, 0, 2)
    _grow_fixed_width_buffers(bufs, es, 2, 4)
    _write_rows(bufs, 2, 4)
    _check_rows(bufs, 4)
    _grow_fixed_width_buffers(bufs, es, 4, 8)
    _check_rows(bufs, 4)
    _write_rows(bufs, 4, 8)
    _check_rows(bufs, 8)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
