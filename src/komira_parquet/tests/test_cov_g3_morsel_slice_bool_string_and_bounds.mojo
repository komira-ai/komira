# =============================================================================
# slice_column_rows: boolean windows, string windows with nulls, bounds and
# malformed string columns.
#
# What each test proves:
#   * a BOOL window starting off a byte boundary holds exactly the source
#     rows, from bit 0, and counts only the window's own nulls;
#   * an empty window of any layout is a column of no rows;
#   * a STRING window with nulls reads back the source strings, with offsets
#     rebased to 0, for a window longer than one SIMD step;
#   * a window outside the column, in either direction, is refused naming
#     the rows asked for and the rows held;
#   * a string column without an offsets buffer, and one whose offsets run
#     backwards across the window, are refused instead of copied;
#   * a column with a non-zero offset is windowed relative to that offset.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_false, assert_raises, assert_true

from komira_arrow.arrow_types import ArrowType
from komira_arrow.boolean_array import BooleanArray
from komira_arrow.column import Column
from komira_arrow.string_array import StringArray
from komira_buffer.heap_region import HeapRegion
from komira_buffer.owned_aligned_buffer import OwnedAlignedBuffer
from komira_parquet.morsel_slice import slice_column_rows


def _bool_source(n: Int) raises -> Column[HeapRegion]:
    # Row i is true when i % 3 == 0; rows 5, 12 and 30 are null.
    var arr = BooleanArray.allocate_nullable(n)
    for i in range(n):
        arr.set(i, i % 3 == 0)
    arr._set_null(5)
    arr._set_null(12)
    arr._set_null(30)
    return Column.from_boolean(arr^)


def test_a_bool_window_off_a_byte_boundary_is_rebased_to_bit_zero() raises:
    var src = _bool_source(40)
    var win = slice_column_rows(src, 3, 17)
    assert_true(win.arrow_type == ArrowType.BOOL)
    assert_equal(win.length(), 17)
    assert_equal(win._offset, 0)
    # Rows 5 and 12 of the source are null; row 30 is outside the window.
    assert_equal(win.null_count(), 2)
    var got = win.as_boolean()
    for i in range(17):
        var row = 3 + i
        if row == 5 or row == 12:
            assert_true(got.is_null(i))
        else:
            assert_false(got.is_null(i))
            assert_equal(got.get(i), row % 3 == 0)


def test_a_bool_window_without_nulls_has_none() raises:
    var arr = BooleanArray.allocate(20)
    for i in range(20):
        arr.set(i, i % 2 == 0)
    var src = Column.from_boolean(arr^)
    var win = slice_column_rows(src, 1, 10)
    assert_equal(win.null_count(), 0)
    var got = win.as_boolean()
    for i in range(10):
        assert_equal(got.get(i), (i + 1) % 2 == 0)


def test_an_empty_window_is_a_column_of_no_rows() raises:
    var src = _bool_source(40)
    var win = slice_column_rows(src, 7, 0)
    assert_equal(win.length(), 0)
    assert_equal(win.null_count(), 0)
    var at_end = slice_column_rows(src, 40, 0)
    assert_equal(at_end.length(), 0)


def test_a_string_window_with_nulls_reads_back_the_source_rows() raises:
    var values = List[String]()
    var valid = List[Bool]()
    for i in range(60):
        values.append("s" + String(i) + ("x" * (i % 5)))
        valid.append(i % 4 != 0)
    var src = Column.from_string(StringArray.from_strings_with_validity(values, valid))
    var win = slice_column_rows(src, 7, 41)
    assert_equal(win.length(), 41)
    assert_equal(win._offset, 0)
    var expected_nulls = 0
    for i in range(41):
        if (7 + i) % 4 == 0:
            expected_nulls += 1
    assert_equal(win.null_count(), expected_nulls)
    var got = win.as_string()
    for i in range(41):
        var row = 7 + i
        if row % 4 == 0:
            assert_true(got.is_null(i))
        else:
            assert_false(got.is_null(i))
            assert_equal(got.get(i), values[row])


def test_a_window_outside_the_column_is_refused() raises:
    var src = _bool_source(40)
    with assert_raises(contains="rows [39, 41) are outside a column of 40 rows"):
        _ = slice_column_rows(src, 39, 2)
    with assert_raises(contains="outside a column of 40 rows"):
        _ = slice_column_rows(src, -1, 2)
    with assert_raises(contains="outside a column of 40 rows"):
        _ = slice_column_rows(src, 2, -1)


def test_a_string_column_without_offsets_is_refused() raises:
    var data = OwnedAlignedBuffer(8)
    data.set_length(8)
    var col = Column[HeapRegion](
        arrow_type=ArrowType.STRING,
        data=data^,
        offsets=None,
        validity=None,
        length=2,
        null_count=0,
        offset=0,
    )
    with assert_raises(contains="a string column without offsets"):
        _ = slice_column_rows(col, 0, 1)


def test_string_offsets_running_backwards_are_refused() raises:
    var data = OwnedAlignedBuffer(8)
    data.set_length(8)
    var offsets = OwnedAlignedBuffer(12)
    offsets.set_length(12)
    offsets.set_typed[Int32](0, 0)
    offsets.set_typed[Int32](1, 5)
    offsets.set_typed[Int32](2, 3)
    var col = Column[HeapRegion](
        arrow_type=ArrowType.STRING,
        data=data^,
        offsets=offsets^,
        validity=None,
        length=2,
        null_count=0,
        offset=0,
    )
    with assert_raises(contains="string offsets run backwards"):
        _ = slice_column_rows(col, 1, 1)


def test_a_window_is_relative_to_the_columns_own_offset() raises:
    var data = OwnedAlignedBuffer(24)
    data.set_length(24)
    for i in range(6):
        data.set_typed[Int32](i, Int32(100 + i))
    var col = Column[HeapRegion](
        arrow_type=ArrowType.INT32,
        data=data^,
        offsets=None,
        validity=None,
        length=4,
        null_count=0,
        offset=2,
    )
    # Rows 1 and 2 of the column are underlying rows 3 and 4.
    var win = slice_column_rows(col, 1, 2)
    assert_equal(win.length(), 2)
    var view = win._data.view_ro()
    assert_equal(view.get_typed[Int32](0), 103)
    assert_equal(view.get_typed[Int32](1), 104)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
