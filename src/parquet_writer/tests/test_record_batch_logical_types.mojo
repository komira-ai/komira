# Timestamps and narrow and unsigned integers: the annotations a written file
# carries and the values parquet's reader decodes from it.
#
# Each test writes a batch with `write_record_batch_to_parquet_bytes`, parses
# the footer with `parse_full_metadata` and decodes the row group with
# `decode_row_group_from_bytes` (the reader shares no code with the writer).
# The annotations expected are the ones DuckDB writes for the same columns
# (`record_batch_schema` lists them).
#
#   * test_each_timestamp_unit_is_the_footers_unit: the legacy TIMESTAMP tag,
#     TIMESTAMP_US, TIMESTAMP_MS, TIMESTAMP_NS, TIMESTAMP_S and a TIMESTAMP_US
#     field with the time zone "UTC" are INT64 leaves whose LogicalType unit
#     is MICROS, MICROS, MILLIS, NANOS, MICROS and MICROS, isAdjustedToUTC
#     only for the zoned one, ConvertedType TIMESTAMP_MICROS (10) or
#     TIMESTAMP_MILLIS (9) and none for nanoseconds; each decodes as the
#     timestamp type of its unit with the values written (seconds times a
#     million), NULLs, the epoch, a time before 1970 and INT64's extremes
#     included. Catches a unit off by 1000 (the decoded values change), a
#     missing UTC flag, and seconds written unscaled.
#   * test_narrow_and_unsigned_integers_keep_their_types: INT8, INT16, UINT8,
#     UINT16 and UINT32 are INT32 leaves and UINT64 an INT64 leaf with the
#     ConvertedType INT_8, INT_16, UINT_8, UINT_16, UINT_32 and UINT_64; each
#     decodes as its own type with each type's minimum and maximum, a NULL
#     in the nullable columns and none in the REQUIRED ones.
#   * test_unsigned_chunks_carry_no_min_or_max: a UINT32 and a UINT64 chunk
#     holding values past the signed maximum keep their null count and carry
#     no min or max in either spelling, while INT8 and UINT16 chunks carry
#     their true min and max. Catches a UINT32 chunk whose signed min says
#     4294967295 < 0 and so lets a reader skip rows it should read.
#   * test_a_timestamp_s_past_the_microsecond_range_is_refused: a seconds
#     value one past INT64's microsecond range, either side, is refused by
#     exact message, and the largest value inside it is written.

from std.testing import TestSuite, assert_equal, assert_false, assert_raises, assert_true

from arrow.arrow_types import ArrowType
from arrow.column import Column
from arrow.primitive_array import PrimitiveArray
from arrow.record_batch import RecordBatch, RecordBatchBuilder
from arrow.schema import Field, SchemaBuilder
from byte_buffer.byte_view import ByteView
from parquet.bytes_decode import (
    decode_row_group_from_bytes,
    row_group_byte_range,
)
from parquet.metadata_parser import parse_full_metadata
from parquet.morsel_reader import ColumnProjection
from parquet_api.metadata import FileMetaData
from parquet_api.types import ParquetType
from parquet_writer import write_record_batch_to_parquet_bytes


def _view[
    mut: Bool, //, o: Origin[mut=mut]
](data: Span[UInt8, o]) -> ByteView[o]:
    return ByteView[o](data.unsafe_ptr(), len(data))


def _footer(file: List[UInt8]) raises -> FileMetaData:
    var n = len(file)
    var flen = 0
    for k in range(4):
        flen |= Int(file[n - 8 + k]) << (8 * k)
    return parse_full_metadata(_view(Span(file)[n - 8 - flen : n - 8]))


def _decode(file: List[UInt8]) raises -> RecordBatch:
    var md = _footer(file)
    ref rg = md.row_groups[0]
    var br = row_group_byte_range(rg)
    return decode_row_group_from_bytes(
        _view(Span(file)[br.start : br.end]),
        br,
        rg,
        md.schema,
        ColumnProjection.all(),
    )


# A NULL (row 0), the epoch, one tick before it, a value of 2015, and INT64's
# largest and its negation (DuckDB's infinity and -infinity).
comptime _ROWS = 6


def _ticks(row: Int, scale: Int64) -> Int64:
    if row == 1:
        return 0
    if row == 2:
        return -1
    if row == 3:
        return 1441369845 * scale + scale // 8
    if row == 4:
        return Int64.MAX
    return -Int64.MAX


def _timestamp_column(
    mut sb: SchemaBuilder,
    mut rb: RecordBatchBuilder,
    name: String,
    at: ArrowType,
    scale: Int64,
    tz: String,
) raises:
    var arr = PrimitiveArray[DType.int64].allocate_nullable(_ROWS)
    arr._set_null(0)
    for r in range(1, _ROWS):
        arr.set(r, _ticks(r, scale))
    sb.add_field(Field.timestamp(name, at, tz, True))
    rb.add_column(Column.from_primitive_with_arrow_type[DType.int64](arr^, at))


def _timestamps() raises -> RecordBatch:
    var sb = SchemaBuilder()
    var rb = RecordBatchBuilder()
    _timestamp_column(sb, rb, "legacy", ArrowType.TIMESTAMP, 1_000_000, "")
    _timestamp_column(sb, rb, "us", ArrowType.TIMESTAMP_US, 1_000_000, "")
    _timestamp_column(sb, rb, "ms", ArrowType.TIMESTAMP_MS, 1_000, "")
    _timestamp_column(sb, rb, "ns", ArrowType.TIMESTAMP_NS, 1_000_000_000, "")
    # Seconds: INT64's extremes are past the microsecond range, so rows 4
    # and 5 hold the largest seconds that scale.
    var s = PrimitiveArray[DType.int64].allocate_nullable(_ROWS)
    s._set_null(0)
    for r in range(1, 4):
        s.set(r, _ticks(r, 1))
    s.set(4, Int64.MAX // 1_000_000)
    s.set(5, -(Int64.MAX // 1_000_000))
    sb.add_field(Field.timestamp("s", ArrowType.TIMESTAMP_S, "", True))
    rb.add_column(
        Column.from_primitive_with_arrow_type[DType.int64](s^, ArrowType.TIMESTAMP_S)
    )
    _timestamp_column(sb, rb, "utc", ArrowType.TIMESTAMP_US, 1_000_000, "UTC")
    return rb.build(sb.build())


def test_each_timestamp_unit_is_the_footers_unit() raises:
    var file = write_record_batch_to_parquet_bytes(_timestamps())
    var md = _footer(file)
    var units: List[Int] = [2, 2, 1, 3, 2, 2]
    var utc: List[Bool] = [False, False, False, False, False, True]
    var converted: List[Int] = [10, 10, 9, -1, 10, 10]
    for c in range(6):
        ref leaf = md.schema[c + 1]
        var w = leaf.name
        assert_true(leaf.type.value() == ParquetType.INT64, w)
        assert_equal(leaf.logical_timestamp_unit.value(), units[c], w)
        assert_equal(leaf.logical_timestamp_is_utc.value(), utc[c], w)
        if converted[c] < 0:
            assert_false(Bool(leaf.converted_type), w)
        else:
            assert_equal(leaf.converted_type.value(), converted[c], w)

    var b = _decode(file)
    var types: List[ArrowType] = [
        ArrowType.TIMESTAMP_US, ArrowType.TIMESTAMP_US, ArrowType.TIMESTAMP_MS,
        ArrowType.TIMESTAMP_NS, ArrowType.TIMESTAMP_US, ArrowType.TIMESTAMP_US,
    ]
    var scales: List[Int64] = [1_000_000, 1_000_000, 1_000, 1_000_000_000, 1, 1_000_000]
    for c in range(6):
        var w = b.schema.field_name(c)
        assert_true(b.schema.field_arrow_type(c) == types[c], w)
        assert_equal(b.schema.field_tz(c), String("UTC") if utc[c] else String(""), w)
        var arr = b.column_at(c).as_primitive[DType.int64]()
        assert_true(arr.is_null(0), w)
        for r in range(1, _ROWS):
            var want = _ticks(r, scales[c])
            if c == 4:
                # Seconds come back as microseconds.
                want = (
                    Int64.MAX // 1_000_000 if r == 4
                    else -(Int64.MAX // 1_000_000) if r == 5
                    else want
                ) * 1_000_000
            assert_equal(arr.get(r), want, w + " row " + String(r))


def _ints() raises -> RecordBatch:
    """Rows: each type's minimum, its maximum, a NULL (nullable columns) or
    a 7 (REQUIRED ones)."""
    var sb = SchemaBuilder()
    var rb = RecordBatchBuilder()
    var i8 = PrimitiveArray[DType.int8].allocate_nullable(3)
    i8.set(0, Int8.MIN)
    i8.set(1, Int8.MAX)
    i8._set_null(2)
    sb.add_field(Field("i8", ArrowType.INT8, True))
    rb.add_column(Column.from_primitive[DType.int8](i8^))
    var i16 = PrimitiveArray[DType.int16].from_list([Int16.MIN, Int16.MAX, Int16(7)])
    sb.add_field(Field("i16", ArrowType.INT16, False))
    rb.add_column(Column.from_primitive[DType.int16](i16^))
    var u8 = PrimitiveArray[DType.uint8].from_list([UInt8(0), UInt8.MAX, UInt8(7)])
    sb.add_field(Field("u8", ArrowType.UINT8, False))
    rb.add_column(Column.from_primitive[DType.uint8](u8^))
    var u16 = PrimitiveArray[DType.uint16].allocate_nullable(3)
    u16.set(0, 0)
    u16.set(1, UInt16.MAX)
    u16._set_null(2)
    sb.add_field(Field("u16", ArrowType.UINT16, True))
    rb.add_column(Column.from_primitive[DType.uint16](u16^))
    var u32 = PrimitiveArray[DType.uint32].allocate_nullable(3)
    u32.set(0, 0)
    u32.set(1, UInt32.MAX)
    u32._set_null(2)
    sb.add_field(Field("u32", ArrowType.UINT32, True))
    rb.add_column(Column.from_primitive[DType.uint32](u32^))
    var u64 = PrimitiveArray[DType.uint64].from_list([UInt64(0), UInt64.MAX, UInt64(7)])
    sb.add_field(Field("u64", ArrowType.UINT64, False))
    rb.add_column(Column.from_primitive[DType.uint64](u64^))
    return rb.build(sb.build())


def test_narrow_and_unsigned_integers_keep_their_types() raises:
    var file = write_record_batch_to_parquet_bytes(_ints())
    var md = _footer(file)
    var converted: List[Int] = [15, 16, 11, 12, 13, 14]
    for c in range(6):
        ref leaf = md.schema[c + 1]
        var physical = ParquetType.INT64 if c == 5 else ParquetType.INT32
        assert_true(leaf.type.value() == physical, leaf.name)
        assert_equal(leaf.converted_type.value(), converted[c], leaf.name)
        assert_false(Bool(leaf.logical_timestamp_unit), leaf.name)

    var b = _decode(file)
    var types: List[ArrowType] = [
        ArrowType.INT8, ArrowType.INT16, ArrowType.UINT8, ArrowType.UINT16,
        ArrowType.UINT32, ArrowType.UINT64,
    ]
    for c in range(6):
        assert_true(b.schema.field_arrow_type(c) == types[c], b.schema.field_name(c))
    var i8 = b.column_at(0).as_primitive[DType.int8]()
    assert_equal(i8.get(0), Int8.MIN)
    assert_equal(i8.get(1), Int8.MAX)
    assert_true(i8.is_null(2))
    var i16 = b.column_at(1).as_primitive[DType.int16]()
    assert_equal(i16.get(0), Int16.MIN)
    assert_equal(i16.get(1), Int16.MAX)
    assert_equal(i16.get(2), 7)
    var u8 = b.column_at(2).as_primitive[DType.uint8]()
    assert_equal(u8.get(0), 0)
    assert_equal(u8.get(1), UInt8.MAX)
    assert_equal(u8.get(2), 7)
    var u16 = b.column_at(3).as_primitive[DType.uint16]()
    assert_equal(u16.get(1), UInt16.MAX)
    assert_true(u16.is_null(2))
    var u32 = b.column_at(4).as_primitive[DType.uint32]()
    assert_equal(u32.get(0), 0)
    assert_equal(u32.get(1), UInt32.MAX)
    assert_true(u32.is_null(2))
    var u64 = b.column_at(5).as_primitive[DType.uint64]()
    assert_equal(u64.get(0), 0)
    assert_equal(u64.get(1), UInt64.MAX)
    assert_equal(u64.get(2), 7)


def _le_i32(v: Int) -> List[UInt8]:
    var out = List[UInt8]()
    for k in range(4):
        out.append(UInt8((v >> (8 * k)) & 0xFF))
    return out^


def test_unsigned_chunks_carry_no_min_or_max() raises:
    var md = _footer(write_record_batch_to_parquet_bytes(_ints()))
    ref cols = md.row_groups[0].columns
    for c in [4, 5]:
        ref st = cols[c].meta_data.statistics.value()
        var w = String("column ") + String(c)
        assert_false(Bool(st.min_value), w)
        assert_false(Bool(st.max_value), w)
        assert_false(Bool(st.min), w)
        assert_false(Bool(st.max), w)
    assert_equal(cols[4].meta_data.statistics.value().null_count.value(), 1)
    assert_equal(cols[5].meta_data.statistics.value().null_count.value(), 0)
    ref s8 = cols[0].meta_data.statistics.value()
    assert_equal(s8.min_value.value(), _le_i32(-128))
    assert_equal(s8.max_value.value(), _le_i32(127))
    ref s16 = cols[3].meta_data.statistics.value()
    assert_equal(s16.min_value.value(), _le_i32(0))
    assert_equal(s16.max_value.value(), _le_i32(65535))


def _seconds(v: Int64) raises -> RecordBatch:
    var arr = PrimitiveArray[DType.int64].from_list([Int64(0), v])
    var sb = SchemaBuilder()
    sb.add_field(Field("at", ArrowType.TIMESTAMP_S, False))
    var rb = RecordBatchBuilder()
    rb.add_column(
        Column.from_primitive_with_arrow_type[DType.int64](arr^, ArrowType.TIMESTAMP_S)
    )
    return rb.build(sb.build())


def test_a_timestamp_s_past_the_microsecond_range_is_refused() raises:
    var limit = Int64.MAX // 1_000_000
    for v in [limit + 1, -limit - 1]:
        with assert_raises(
            contains=String("parquet writer: column 'at' row 1 holds the")
            + " TIMESTAMP_S value " + String(v) + ", whose microseconds do not"
            " fit in an INT64 (a Parquet timestamp has no seconds unit, so"
            " seconds are written as microseconds)"
        ):
            _ = write_record_batch_to_parquet_bytes(_seconds(v))
    var b = _decode(write_record_batch_to_parquet_bytes(_seconds(limit)))
    assert_equal(b.column_at(0).as_primitive[DType.int64]().get(1), limit * 1_000_000)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
