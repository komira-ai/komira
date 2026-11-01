# =============================================================================
# ColumnDecodeContext band slots and codes capacity; RowSelection intersect
# and IntervalCursor at their ends.
#
# What each test proves:
#   * the codes buffer reports no usable bytes before it is allocated, and
#     its capacity once it is;
#   * band slots refuse fewer value sizes than columns, and refuse a later
#     call naming a different column count, each naming both numbers; a
#     refused call leaves the slots as they were;
#   * intersecting two empty selections selects nothing;
#   * a cursor whose last select run is spent reports the end of the
#     intervals, consumes nothing and is exhausted, instead of re-entering a
#     phase, and a cursor over no intervals starts exhausted.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_false, assert_raises, assert_true

from komira_parquet.column_decode_context import ColumnDecodeContext
from komira_parquet.row_selection import IntervalCursor, RowInterval, RowSelection


def test_codes_capacity_is_zero_before_allocation() raises:
    var ctx = ColumnDecodeContext()
    assert_equal(ctx.codes_capacity(), 0)
    ctx.ensure_codes(300)
    assert_true(ctx.codes_capacity() >= 300)


def test_band_slots_refuse_too_few_value_sizes() raises:
    var ctx = ColumnDecodeContext()
    var sizes: List[Int] = [64, 64]
    with assert_raises(contains="2 value sizes for 3 band columns"):
        ctx.ensure_band_slots(3, sizes)
    assert_equal(ctx.band_n_cols(), 0)


def test_band_slots_refuse_a_different_column_count_later() raises:
    var ctx = ColumnDecodeContext()
    var sizes: List[Int] = [64, 64, 64]
    ctx.ensure_band_slots(2, sizes)
    assert_equal(ctx.band_n_cols(), 2)
    with assert_raises(contains="band slots hold 2 columns, asked for 3"):
        ctx.ensure_band_slots(3, sizes)
    assert_equal(ctx.band_n_cols(), 2)
    # The same count is accepted and keeps the slots.
    ctx.ensure_band_slots(2, sizes)
    assert_equal(ctx.band_n_cols(), 2)


def test_intersecting_empty_selections_selects_nothing() raises:
    var a = RowSelection.none()
    var b = RowSelection.none()
    var both = a.intersect(b)
    assert_equal(len(both.intervals), 0)
    assert_equal(both.total_rows(), UInt64(0))
    assert_equal(both.num_selected(), UInt64(0))
    var some = RowSelection.all(UInt64(10))
    var with_none = some.intersect(b)
    assert_equal(with_none.num_selected(), UInt64(0))


def test_a_cursor_past_its_last_select_run_is_exhausted() raises:
    var intervals: List[RowInterval] = [RowInterval(UInt64(2), UInt64(3))]
    var cur = IntervalCursor(Span(intervals))
    var consumed: UInt64 = 0
    var selecting = False
    cur.consume_phase(UInt64(10), consumed, selecting)
    assert_equal(consumed, UInt64(2))
    assert_false(selecting)
    cur.consume_phase(UInt64(10), consumed, selecting)
    assert_equal(consumed, UInt64(3))
    assert_true(selecting)
    assert_false(cur.exhausted())
    # The select run is spent: the next call steps past the last interval.
    cur.consume_phase(UInt64(10), consumed, selecting)
    assert_equal(consumed, UInt64(0))
    assert_false(selecting)
    assert_true(cur.exhausted())
    assert_false(cur.is_selecting())
    # An exhausted cursor stays exhausted and consumes nothing.
    consumed = 7
    selecting = True
    cur.consume_phase(UInt64(10), consumed, selecting)
    assert_equal(consumed, UInt64(0))
    assert_false(selecting)


def test_a_cursor_over_no_intervals_is_exhausted() raises:
    var none = List[RowInterval]()
    var cur = IntervalCursor(Span(none))
    assert_true(cur.exhausted())
    var consumed: UInt64 = 5
    var selecting = True
    cur.consume_phase(UInt64(3), consumed, selecting)
    assert_equal(consumed, UInt64(0))
    assert_false(selecting)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
