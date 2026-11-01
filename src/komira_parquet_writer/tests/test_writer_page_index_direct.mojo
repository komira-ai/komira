# The page index writer (`writer_page_index`): BoundaryOrder in the column's
# type-defined order, and the ColumnIndex / OffsetIndex bytes.
#
# What each test proves, and the defect it catches:
#   * test_int32_order_is_numeric_not_bytewise: pages with min 1 then 256 are
#     ASCENDING. Their PLAIN bytes are `01 00 00 00` and `00 01 00 00`, so a
#     bytewise compare (the predecessor's) calls them DESCENDING, and a
#     reader binary-searching a DESCENDING index skips the pages that hold
#     the matches. Red before the type-aware compare.
#   * test_int64_negative_values: -5 < 3 as signed; as unsigned bytes -5
#     (`fb ff .. ff`) sorts last.
#   * test_double_order: -1.5 < 0.25 < 2.0 as numbers; the IEEE bit patterns
#     of a negative double sort after every positive one.
#   * test_max_values_must_also_be_ordered: mins ascending but maxes not is
#     UNORDERED (the spec's ASCENDING covers both lists).
#   * test_byte_array_is_unsigned_lexicographic, null pages skipped, a
#     single page, BOOLEAN claims nothing.
#   * the serialized ColumnIndex and OffsetIndex bytes, against expected
#     bytes written out here field by field.
from std.testing import TestSuite, assert_equal

from komira_parquet_api.types import BoundaryOrder, ParquetType
from komira_parquet_writer.writer_page_index import (
    ColumnPageTracker,
    serialize_column_index,
    serialize_offset_index,
)


def _le(v: UInt64, width: Int) -> List[UInt8]:
    var out = List[UInt8]()
    for i in range(width):
        out.append(UInt8((v >> UInt64(8 * i)) & 0xFF))
    return out^


def _i32(v: Int) -> List[UInt8]:
    return _le(UInt64(UInt32(Int32(v))), 4)


def _i64(v: Int) -> List[UInt8]:
    return _le(UInt64(Int64(v)), 8)


def _f64(v: Float64) -> List[UInt8]:
    return _le(UInt64(v.to_bits()), 8)


def _str(s: String) -> List[UInt8]:
    var out = List[UInt8]()
    var b = s.as_bytes()
    for i in range(len(b)):
        out.append(b[i])
    return out^


def _extend(mut out: List[UInt8], more: List[UInt8]):
    for i in range(len(more)):
        out.append(more[i])


def _byte(v: UInt8) -> List[UInt8]:
    var out = List[UInt8]()
    out.append(v)
    return out^


def _order(tracker: ColumnPageTracker) raises -> Int:
    """The boundary_order field (4, i32) of the serialized ColumnIndex: the
    byte after the field-4 header, zigzag-decoded."""
    var b = serialize_column_index(tracker)
    # The order is the last field before the null_counts list (field 5) and
    # the STOP byte: header 0x15 (delta 1, i32), then a 1-byte zigzag varint.
    var at = -1
    for i in range(len(b) - 1):
        if b[i] == 0x15:
            at = i
    assert_equal(at >= 0, True, "no boundary_order field")
    return Int(b[at + 1]) >> 1


def test_int32_order_is_numeric_not_bytewise() raises:
    var t = ColumnPageTracker(ParquetType.INT32)
    t.add_page(4, 10, 0, _i32(1), _i32(2))
    t.add_page(14, 10, 100, _i32(256), _i32(300))
    t.add_page(24, 10, 200, _i32(70000), _i32(70001))
    assert_equal(_order(t), Int(BoundaryOrder.ASCENDING.value))


def test_int64_negative_values() raises:
    var t = ColumnPageTracker(ParquetType.INT64)
    t.add_page(4, 10, 0, _i64(-5), _i64(-1))
    t.add_page(14, 10, 100, _i64(3), _i64(9))
    assert_equal(_order(t), Int(BoundaryOrder.ASCENDING.value))
    var d = ColumnPageTracker(ParquetType.INT64)
    d.add_page(4, 10, 0, _i64(3), _i64(9))
    d.add_page(14, 10, 100, _i64(-5), _i64(-1))
    assert_equal(_order(d), Int(BoundaryOrder.DESCENDING.value))


def test_double_order() raises:
    var t = ColumnPageTracker(ParquetType.DOUBLE)
    t.add_page(4, 10, 0, _f64(-1.5), _f64(-1.0))
    t.add_page(14, 10, 100, _f64(0.25), _f64(1.0))
    t.add_page(24, 10, 200, _f64(2.0), _f64(4.0))
    assert_equal(_order(t), Int(BoundaryOrder.ASCENDING.value))


def test_max_values_must_also_be_ordered() raises:
    var t = ColumnPageTracker(ParquetType.INT32)
    t.add_page(4, 10, 0, _i32(1), _i32(50))
    t.add_page(14, 10, 100, _i32(2), _i32(10))
    assert_equal(_order(t), Int(BoundaryOrder.UNORDERED.value))


def test_byte_array_is_unsigned_lexicographic() raises:
    var t = ColumnPageTracker(ParquetType.BYTE_ARRAY)
    t.add_page(4, 10, 0, _str("a"), _str("az"))
    t.add_page(14, 10, 100, _str("b"), _str("é"))
    assert_equal(_order(t), Int(BoundaryOrder.ASCENDING.value))


def test_null_pages_skipped_and_single_page() raises:
    var t = ColumnPageTracker(ParquetType.INT32)
    t.add_page(4, 10, 0, _i32(5), _i32(6))
    t.add_page(14, 10, 100, List[UInt8](), List[UInt8](), 100, True)
    t.add_page(24, 10, 200, _i32(1), _i32(2))
    assert_equal(_order(t), Int(BoundaryOrder.DESCENDING.value))
    var one = ColumnPageTracker(ParquetType.INT32)
    one.add_page(4, 10, 0, _i32(9), _i32(1))
    assert_equal(_order(one), Int(BoundaryOrder.ASCENDING.value))


def test_boolean_claims_nothing() raises:
    var t = ColumnPageTracker(ParquetType.BOOLEAN)
    t.add_page(4, 10, 0, _byte(0), _byte(0))
    t.add_page(14, 10, 100, _byte(1), _byte(1))
    assert_equal(_order(t), Int(BoundaryOrder.UNORDERED.value))


def test_column_index_bytes() raises:
    var t = ColumnPageTracker(ParquetType.INT32)
    t.add_page(4, 10, 0, _i32(1), _i32(2), 3)
    var got = serialize_column_index(t)
    var want = List[UInt8]()
    # 1: list<bool> null_pages, 1 element: 0x19 (delta 1, list), 0x11, then
    # the element: 2 is false in the compact protocol (1 is true; 0 is not a
    # boolean and a strict reader rejects it).
    want.append(0x19)
    want.append(0x11)
    want.append(0x02)
    # 2: list<binary> min_values: 0x19, 0x18, len 4, 01 00 00 00
    want.append(0x19)
    want.append(0x18)
    want.append(0x04)
    _extend(want, _i32(1))
    # 3: list<binary> max_values
    want.append(0x19)
    want.append(0x18)
    want.append(0x04)
    _extend(want, _i32(2))
    # 4: i32 boundary_order = ASCENDING (1), zigzag 2
    want.append(0x15)
    want.append(0x02)
    # 5: list<i64> null_counts = [3], zigzag 6
    want.append(0x19)
    want.append(0x16)
    want.append(0x06)
    want.append(0x00)
    assert_equal(len(got), len(want))
    for i in range(len(want)):
        assert_equal(Int(got[i]), Int(want[i]), "byte " + String(i))


def test_offset_index_bytes() raises:
    var t = ColumnPageTracker(ParquetType.INT32)
    t.add_page(4, 10, 0, _i32(1), _i32(2))
    t.add_page(14, 20, 100, _i32(3), _i32(4))
    var got = serialize_offset_index(t)
    var want: List[UInt8] = [
        0x19, 0x2C,  # 1: list<struct> page_locations, 2 elements
        0x16, 0x08, 0x15, 0x14, 0x16, 0x00, 0x00,  # {offset 4, size 10, row 0}
        0x16, 0x1C, 0x15, 0x28, 0x16, 0xC8, 0x01, 0x00,  # {14, 20, 100}
        0x00,  # STOP
    ]
    assert_equal(len(got), len(want))
    for i in range(len(want)):
        assert_equal(Int(got[i]), Int(want[i]), "byte " + String(i))


def test_empty_tracker_serializes_nothing() raises:
    var t = ColumnPageTracker(ParquetType.INT64)
    assert_equal(len(serialize_column_index(t)), 0)
    assert_equal(len(serialize_offset_index(t)), 0)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
