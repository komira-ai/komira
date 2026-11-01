# =============================================================================
# RecordBatchScanSource / StreamingMorsel behaviour
# =============================================================================
#
# What each test proves, and the defect it would catch:
#   * the source splits a batch into morsels of at most `morsel_size` rows,
#     yields them in order with the batch's values, and then yields nothing:
#     a wrong split, a repeated or skipped morsel, or a source that never
#     exhausts is red;
#   * a BOOL column is copied as bits from the column's bit offset (25 rows in
#     morsels of 10, so morsels 1 and 2 start mid-byte): a byte-wise copy, or a
#     copy that ignores the offset, yields wrong bits;
#   * a validity bitmap is copied per morsel from the column's offset, and the
#     per-morsel null count is recomputed: a copy from bit 0 or a stale null
#     count is red;
#   * a zero-row batch yields no rows and does not raise;
#   * a column with no fixed byte width (STRING) makes `next_morsel` raise
#     naming the type, rather than copying a slab of the wrong width;
#   * `StreamingMorsel` selection set / take / clear keep `num_active`
#     consistent, taking from a morsel with no selection raises, and a taken
#     selection can be set back.
# =============================================================================

from std.sys import size_of
from std.testing import TestSuite, assert_equal, assert_true, assert_false

from komira_arrow.arrow_types import ArrowType
from komira_arrow.bitmap import Bitmap
from komira_arrow.boolean_array import BooleanArray
from komira_arrow.column import Column
from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.schema import (
    Field,
    RecordBatch,
    RecordBatchBuilder,
    SchemaBuilder,
)
from komira_arrow.selection_vector import SelectionVector
from komira_arrow.string_array import StringArray
from komira_buffer.heap_region import HeapRegion
from komira_buffer.owned_aligned_buffer import OwnedAlignedBuffer
from komira_engine_runtime.scan_source import RecordBatchScanSource
from komira_engine_runtime.streaming_morsel import StreamingMorsel


def _i64_column(n: Int, null_every: Int = 0) raises -> Column[HeapRegion]:
    """Int64 values 0..n-1; when `null_every > 0`, rows i with
    i % null_every == 3 are null."""
    comptime w = size_of[Scalar[DType.int64]]()
    var buf = OwnedAlignedBuffer(max(n * w, 1))
    var p = buf.view_typed_mut[DType.int64]()
    for i in range(n):
        (p + i).unsafe_write(Scalar[DType.int64](i))
    buf.set_length(Int64(n * w))
    var validity = Optional[Bitmap[HeapRegion]](None)
    var nulls = 0
    if null_every > 0:
        var bm = Bitmap.create(n)
        for i in range(n):
            if i % null_every == 3:
                bm.clear(i)
                nulls += 1
            else:
                bm.set(i)
        validity = bm^
    var arr = PrimitiveArray[DType.int64](buf^, n, validity^, nulls, 0)
    return Column.from_primitive[DType.int64](arr)


def _batch_i64(n: Int, null_every: Int = 0) raises -> RecordBatch:
    var sb = SchemaBuilder()
    sb.add_field(Field("a", ArrowType.INT64, null_every > 0))
    var builder = RecordBatchBuilder()
    builder.add_column(_i64_column(n, null_every))
    return builder.build(sb.build())


def _batch_bool(n: Int) raises -> RecordBatch:
    """BOOL column where row i is true iff i % 3 == 0."""
    var bm = Bitmap.create(n)
    for i in range(n):
        if i % 3 == 0:
            bm.set(i)
    var sb = SchemaBuilder()
    sb.add_field(Field("f", ArrowType.BOOL, False))
    var builder = RecordBatchBuilder()
    builder.add_column(Column.from_boolean(BooleanArray.from_bitmap(bm^)))
    return builder.build(sb.build())


def test_scan_source_splits_in_order_and_exhausts() raises:
    var src = RecordBatchScanSource(_batch_i64(25), 10)
    assert_equal(src.num_morsels(), 3)
    assert_equal(src.total_rows(), 25)
    var next_value = 0
    var sizes = List[Int]()
    while True:
        var m = src.next_morsel()
        if not m:
            break
        var mm = m.take()
        sizes.append(mm.num_rows())
        var arr = mm.batch.column_at(0).as_primitive[DType.int64]()
        for r in range(mm.num_rows()):
            assert_equal(Int(arr.get(r)), next_value)
            next_value += 1
    assert_equal(len(sizes), 3)
    assert_equal(sizes[0], 10)
    assert_equal(sizes[1], 10)
    assert_equal(sizes[2], 5)
    assert_equal(next_value, 25)
    assert_false(Bool(src.next_morsel()))


def test_bool_column_copies_bits_from_the_column_offset() raises:
    var src = RecordBatchScanSource(_batch_bool(25), 10)
    var row = 0
    while True:
        var m = src.next_morsel()
        if not m:
            break
        var mm = m.take()
        var arr = mm.batch.column_at(0).as_boolean()
        for r in range(mm.num_rows()):
            assert_equal(arr.get(r), row % 3 == 0, "row " + String(row))
            row += 1
    assert_equal(row, 25)


def test_validity_is_copied_from_the_column_offset() raises:
    # Nulls at rows 3, 13, 23 of 25: one per morsel, at different positions.
    var src = RecordBatchScanSource(_batch_i64(25, 10), 10)
    var row = 0
    while True:
        var m = src.next_morsel()
        if not m:
            break
        var mm = m.take()
        ref col = mm.batch.column_at(0)
        assert_equal(col.null_count(), 1)
        for r in range(mm.num_rows()):
            assert_equal(col.is_null_at(r), row % 10 == 3, "row " + String(row))
            if row % 10 != 3:
                assert_equal(Int(col.as_primitive[DType.int64]().get(r)), row)
            row += 1
    assert_equal(row, 25)


def test_zero_row_batch_yields_no_rows() raises:
    var src = RecordBatchScanSource(_batch_i64(0), 10)
    assert_equal(src.total_rows(), 0)
    var rows = 0
    while True:
        var m = src.next_morsel()
        if not m:
            break
        rows += m.take().num_rows()
    assert_equal(rows, 0)


def test_non_fixed_width_column_raises_naming_the_type() raises:
    var values = List[String]()
    for i in range(4):
        values.append(String("s") + String(i))
    var sb = SchemaBuilder()
    sb.add_field(Field("s", ArrowType.STRING, False))
    var builder = RecordBatchBuilder()
    builder.add_column(
        Column.from_string(StringArray.from_strings(values))
    )
    var src = RecordBatchScanSource(builder.build(sb.build()), 10)
    var msg = String()
    try:
        _ = src.next_morsel()
    except e:
        msg = String(e)
    assert_true(String(ArrowType.STRING) in msg, msg)


def test_streaming_morsel_selection_lifecycle() raises:
    var sm = StreamingMorsel(_batch_i64(8))
    assert_true(sm.all_active())
    assert_equal(sm.num_active, 8)
    sm.set_selection(SelectionVector.all(3))
    assert_false(sm.all_active())
    assert_equal(sm.num_active, 3)
    var sv = sm.take_selection()
    assert_equal(sv.length(), 3)
    assert_equal(sm.num_active, 0)
    assert_true(sm.all_active())
    sm.set_selection(sv^)
    assert_equal(sm.num_active, 3)
    sm.clear_selection()
    assert_true(sm.all_active())
    assert_equal(sm.num_active, 8)
    var with_sv = StreamingMorsel(_batch_i64(8), SelectionVector.all(5))
    assert_equal(with_sv.num_active, 5)
    assert_false(with_sv.all_active())


def test_take_selection_without_a_selection_raises() raises:
    var sm = StreamingMorsel(_batch_i64(4))
    var msg = String()
    try:
        _ = sm.take_selection()
    except e:
        msg = String(e)
    assert_true("no selection" in msg, msg)
    assert_equal(sm.num_active, 4)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
