"""`_extract_build_key_array`: which arm serves the build key, and that both
arms return the same values.

The share and the copy are value-identical by design, so a value assertion
alone cannot tell which arm ran. Each case therefore reads the two counters of
`hbs_key_share_counter` as well: a column with no validity bitmap must take the
SHARE arm (and carry a sliced column's offset through), a column with a bitmap
must take the copy and count a SHAPE decline. The marker line is printed with
`marker_on=True` on both arms; its text goes to stdout, which the test does not
read, so those cases prove only that the print arm runs without raising.
"""

from std.testing import assert_equal

from komira_arrow.arrow_types import ArrowType
from komira_arrow.bitmap import Bitmap
from komira_arrow.column import Column
from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.record_batch import RecordBatch, RecordBatchBuilder
from komira_arrow.schema import Field, SchemaBuilder
from komira_buffer.heap_region import HeapRegion
from komira_buffer.owned_aligned_buffer import OwnedAlignedBuffer

from komira_dispatch_join_kernels.hbs_key_extract import (
    _extract_build_key_array,
)
from komira_dispatch_join_kernels.hbs_key_share_counter import (
    hbs_key_decline_shape_count,
    hbs_key_share_count,
)


comptime I64 = DType.int64


def _key(i: Int) -> Int64:
    """Never equal to the row index, so an extraction that returned row
    numbers goes red."""
    return Int64(5_000_000_011) - Int64(i) * Int64(3)


def _plain_key_col(rows: Int) raises -> Column[HeapRegion]:
    var arr = PrimitiveArray[I64].allocate(rows)
    for i in range(rows):
        arr.set(i, _key(i))
    return Column.from_primitive[I64](arr^)


def _bitmap_key_col(rows: Int, null_row: Int) raises -> Column[HeapRegion]:
    """The same values, carrying a validity bitmap with one NULL slot."""
    var buf = OwnedAlignedBuffer(max(rows * 8, 1))
    buf.set_length(Int64(rows * 8))
    for i in range(rows):
        buf.set_typed[Scalar[I64]](i, _key(i))
    var bm = Bitmap.create_all_valid(rows)
    bm.clear(null_row)
    return Column[HeapRegion](
        arrow_type=ArrowType.INT64,
        data=buf^,
        offsets=Optional[OwnedAlignedBuffer](None),
        validity=Optional[Bitmap[HeapRegion]](bm^),
        length=rows,
        null_count=1,
        offset=0,
    )


def _batch(
    payload_first: Bool, var key: Column[HeapRegion]
) raises -> RecordBatch:
    """A two-column batch whose key sits at index 1 when `payload_first`, so a
    body that ignored `key_idx` reads the wrong column."""
    var rows = key.length()
    var sb = SchemaBuilder()
    var b = RecordBatchBuilder.with_capacity(2)
    if payload_first:
        var other = PrimitiveArray[I64].allocate(rows)
        for i in range(rows):
            other.set(i, Int64(-1))
        sb.add_field(Field("payload", ArrowType.INT64, False))
        b.add_column(Column.from_primitive[I64](other^))
    sb.add_field(Field("key", ArrowType.INT64, True))
    b.add_column(key^)
    return b.build(sb.build())


def test_a_column_without_a_bitmap_takes_the_share() raises:
    """MUTANT: `if take_share:` inverted: the SHARE count stays put and the
    SHAPE count moves."""
    var rows = 40
    var batch = _batch(True, _plain_key_col(rows))
    var share0 = hbs_key_share_count()
    var shape0 = hbs_key_decline_shape_count()
    var arr = _extract_build_key_array(batch, 1, False)
    assert_equal(hbs_key_share_count() - share0, 1)
    assert_equal(hbs_key_decline_shape_count() - shape0, 0)
    assert_equal(arr.length, rows)
    for i in range(rows):
        assert_equal(arr.get(i), _key(i))


def test_the_share_carries_a_sliced_columns_offset() raises:
    """A column sliced at row 7 shares the parent buffer, so the array must
    report offset 7 and still read row `i` of the slice as parent row 7 + i.
    MUTANT: a share that dropped the offset reads parent row `i`."""
    var parent = _plain_key_col(50)
    var sliced = parent.slice(7, 30)
    var batch = _batch(False, sliced^)
    var share0 = hbs_key_share_count()
    var arr = _extract_build_key_array(batch, 0, True)
    assert_equal(hbs_key_share_count() - share0, 1)
    assert_equal(arr.length, 30)
    assert_equal(arr.offset, 7)
    for i in range(30):
        assert_equal(arr.get(i), _key(7 + i))
    _ = parent^


def test_a_column_with_a_bitmap_is_copied_and_counted() raises:
    """The share refuses a column carrying a validity bitmap, so the copy runs
    and a SHAPE decline is counted; the NULL slot stays NULL in the copy.
    MUTANT: `hbs_key_decline_shape_incr()` dropped from the copy arm: the
    SHAPE count stays put."""
    var rows = 24
    var batch = _batch(True, _bitmap_key_col(rows, 5))
    var share0 = hbs_key_share_count()
    var shape0 = hbs_key_decline_shape_count()
    var arr = _extract_build_key_array(batch, 1, True)
    assert_equal(hbs_key_share_count() - share0, 0)
    assert_equal(hbs_key_decline_shape_count() - shape0, 1)
    assert_equal(arr.length, rows)
    assert_equal(arr.is_null(5), True)
    for i in range(rows):
        if i != 5:
            assert_equal(arr.get(i), _key(i))


def test_the_copy_arm_without_the_marker() raises:
    """The copy arm with the marker off: the same counts, no print."""
    var batch = _batch(False, _bitmap_key_col(9, 0))
    var shape0 = hbs_key_decline_shape_count()
    var arr = _extract_build_key_array(batch, 0, False)
    assert_equal(hbs_key_decline_shape_count() - shape0, 1)
    assert_equal(arr.get(8), _key(8))


def main() raises:
    test_a_column_without_a_bitmap_takes_the_share()
    test_the_share_carries_a_sliced_columns_offset()
    test_a_column_with_a_bitmap_is_copied_and_counted()
    test_the_copy_arm_without_the_marker()
    print("All 4 build-key extraction tests passed.")
