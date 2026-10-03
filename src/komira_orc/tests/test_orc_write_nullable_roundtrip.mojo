# =============================================================================
# test_orc_write_nullable_roundtrip.mojo — ORC writer PRESENT-stream emit.
# =============================================================================
#
# Acceptance: write columns with nulls -> the writer emits the PRESENT
# (boolean RLE) stream + dense DATA -> read back -> assert null positions +
# non-null values match. Covers int / double / string nullability.
# =============================================================================

from std.testing import assert_equal, assert_true

from komira_core.arrow.arrow_types import ArrowType
from komira_core.arrow.column import Column
from komira_core.arrow.primitive_array import PrimitiveArray
from komira_core.arrow.string_array import StringArray
from komira_core.arrow.bitmap import Bitmap
from komira_core.io.heap_region import HeapRegion
from komira_core.arrow.record_batch import RecordBatch, RecordBatchBuilder
from komira_core.arrow.schema import Schema, SchemaBuilder, Field

from komira_orc import (
    OrcWriterOptions,
    write_orc_bytes,
    read_orc_bytes,
    ORC_COMPRESSION_NONE,
    ORC_COMPRESSION_ZSTD,
)


def _build_nullable() raises -> RecordBatch:
    var n = 5
    var sb = SchemaBuilder()
    sb.add_field(Field("nl", ArrowType.INT64, True))
    sb.add_field(Field("nd", ArrowType.FLOAT64, True))
    sb.add_field(Field("ns", ArrowType.STRING, True))

    # int64 with nulls at rows 1, 3.
    var a = PrimitiveArray[DType.int64].allocate_nullable(n)
    a.set(0, Int64(10)); a._set_null(1); a.set(2, Int64(30)); a._set_null(3); a.set(4, Int64(50))
    a.null_count = 2

    # float64 with null at row 0.
    var d = PrimitiveArray[DType.float64].allocate_nullable(n)
    d._set_null(0); d.set(1, Float64(1.1)); d.set(2, Float64(2.2)); d.set(3, Float64(3.3)); d.set(4, Float64(4.4))
    d.null_count = 1

    # string with null at rows 2, 4.
    var ss = List[String]()
    ss.append(String("aa")); ss.append(String("bb")); ss.append(String("")); ss.append(String("dd")); ss.append(String(""))
    var s = StringArray.from_strings(ss)
    var bm = Bitmap.create_all_valid(n)
    bm.clear(2)
    bm.clear(4)
    s.validity = Optional[Bitmap[HeapRegion]](bm^)
    s.null_count = 2

    var builder = RecordBatchBuilder.with_capacity(3)
    builder.add_column(Column.from_primitive_with_arrow_type[DType.int64](a^, ArrowType.INT64))
    builder.add_column(Column.from_primitive[DType.float64](d^))
    builder.add_column(Column.from_string(s^))
    return builder.build(sb.build())


def _check(codec: Int, label: String) raises:
    var rb = _build_nullable()
    var opts = OrcWriterOptions(codec, 10000, String("UTC"))
    var bytes = write_orc_bytes(rb, opts)
    var back = read_orc_bytes(Span(bytes))
    assert_equal(back.num_rows(), 5, label + ": 5 rows")

    var a = back.column_as_primitive_int64(0)
    assert_true(not a.is_null(0), label + ": a row0 valid")
    assert_true(a.is_null(1), label + ": a row1 null")
    assert_equal(Int(a.get(2)), 30, label + ": a row2 = 30")
    assert_true(a.is_null(3), label + ": a row3 null")
    assert_equal(Int(a.get(4)), 50, label + ": a row4 = 50")

    var d = back.column_as_primitive_float64(1)
    assert_true(d.is_null(0), label + ": d row0 null")
    assert_true(d.get(1) == 1.1, label + ": d row1 = 1.1")
    assert_true(d.get(4) == 4.4, label + ": d row4 = 4.4")

    var s = back.column_as_string(2)
    assert_equal(s.get(0), String("aa"), label + ": s row0 = aa")
    assert_true(not s.is_null(0), label + ": s row0 valid")
    assert_true(s.is_null(2), label + ": s row2 null")
    assert_equal(s.get(3), String("dd"), label + ": s row3 = dd")
    assert_true(s.is_null(4), label + ": s row4 null")


def test_orc_write_nullable_none() raises:
    _check(ORC_COMPRESSION_NONE, "NONE")


def test_orc_write_nullable_zstd() raises:
    _check(ORC_COMPRESSION_ZSTD, "ZSTD")


def main() raises:
    test_orc_write_nullable_none()
    test_orc_write_nullable_zstd()
    print("test_orc_write_nullable_roundtrip: ALL PASS")
