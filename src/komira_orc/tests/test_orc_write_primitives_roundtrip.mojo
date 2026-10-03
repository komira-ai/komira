# =============================================================================
# test_orc_write_primitives_roundtrip.mojo — ORC writer all-primitive-types.
# =============================================================================
#
# Acceptance: write a RecordBatch covering every supported primitive
# ORC type (TINYINT/SMALLINT/INT/BIGINT/DATE/FLOAT/DOUBLE/BOOL/STRING) and read
# it back via the reader. NONE + ZSTD codecs (codec matrix is covered
# in test_orc_write_roundtrip).
# =============================================================================

from std.testing import assert_equal, assert_true

from komira_core.arrow.arrow_types import ArrowType
from komira_core.arrow.column import Column
from komira_core.arrow.primitive_array import PrimitiveArray
from komira_core.arrow.string_array import StringArray
from komira_core.arrow.boolean_array import BooleanArray
from komira_core.arrow.record_batch import RecordBatch, RecordBatchBuilder
from komira_core.arrow.schema import Schema, SchemaBuilder, Field

from komira_orc import (
    OrcWriterOptions,
    write_orc_bytes,
    read_orc_bytes,
    ORC_COMPRESSION_NONE,
    ORC_COMPRESSION_ZSTD,
)


def _build_all_primitives() raises -> RecordBatch:
    var n = 4
    var sb = SchemaBuilder()
    sb.add_field(Field("t8", ArrowType.INT8, True))
    sb.add_field(Field("s16", ArrowType.INT16, True))
    sb.add_field(Field("i32", ArrowType.INT32, True))
    sb.add_field(Field("l64", ArrowType.INT64, True))
    sb.add_field(Field("dt", ArrowType.DATE32, True))
    sb.add_field(Field("f32", ArrowType.FLOAT32, True))
    sb.add_field(Field("f64", ArrowType.FLOAT64, True))
    sb.add_field(Field("bl", ArrowType.BOOL, True))
    sb.add_field(Field("st", ArrowType.STRING, True))

    var a8 = PrimitiveArray[DType.int8].allocate(n)
    a8.set(0, Int8(-128)); a8.set(1, Int8(0)); a8.set(2, Int8(7)); a8.set(3, Int8(127))
    var a16 = PrimitiveArray[DType.int16].allocate(n)
    a16.set(0, Int16(-30000)); a16.set(1, Int16(0)); a16.set(2, Int16(123)); a16.set(3, Int16(30000))
    var a32 = PrimitiveArray[DType.int32].allocate(n)
    a32.set(0, Int32(-1)); a32.set(1, Int32(0)); a32.set(2, Int32(65536)); a32.set(3, Int32(2000000000))
    var a64 = PrimitiveArray[DType.int64].allocate(n)
    a64.set(0, Int64(-9000000000)); a64.set(1, Int64(0)); a64.set(2, Int64(42)); a64.set(3, Int64(9000000000))
    var adt = PrimitiveArray[DType.int32].allocate(n)
    adt.set(0, Int32(0)); adt.set(1, Int32(19000)); adt.set(2, Int32(19000)); adt.set(3, Int32(-100))
    var af32 = PrimitiveArray[DType.float32].allocate(n)
    af32.set(0, Float32(1.25)); af32.set(1, Float32(-2.5)); af32.set(2, Float32(0.0)); af32.set(3, Float32(123.5))
    var af64 = PrimitiveArray[DType.float64].allocate(n)
    af64.set(0, Float64(3.14159)); af64.set(1, Float64(-1.0)); af64.set(2, Float64(0.0)); af64.set(3, Float64(1e10))
    var abl = BooleanArray.allocate(n)
    abl.set(0, True); abl.set(1, True); abl.set(2, False); abl.set(3, True)
    var ss = List[String]()
    ss.append(String("x")); ss.append(String("yy")); ss.append(String("")); ss.append(String("zzz"))
    var ast = StringArray.from_strings(ss)

    var builder = RecordBatchBuilder.with_capacity(9)
    builder.add_column(Column.from_primitive_with_arrow_type[DType.int8](a8^, ArrowType.INT8))
    builder.add_column(Column.from_primitive_with_arrow_type[DType.int16](a16^, ArrowType.INT16))
    builder.add_column(Column.from_primitive_with_arrow_type[DType.int32](a32^, ArrowType.INT32))
    builder.add_column(Column.from_primitive_with_arrow_type[DType.int64](a64^, ArrowType.INT64))
    builder.add_column(Column.from_primitive_with_arrow_type[DType.int32](adt^, ArrowType.DATE32))
    builder.add_column(Column.from_primitive[DType.float32](af32^))
    builder.add_column(Column.from_primitive[DType.float64](af64^))
    builder.add_column(Column.from_boolean(abl^))
    builder.add_column(Column.from_string(ast^))
    return builder.build(sb.build())


def _check(codec: Int, label: String) raises:
    var rb = _build_all_primitives()
    var opts = OrcWriterOptions(codec, 10000, String("UTC"))
    var bytes = write_orc_bytes(rb, opts)
    var back = read_orc_bytes(Span(bytes))
    assert_equal(back.num_columns(), 9, label + ": 9 cols")
    assert_equal(back.num_rows(), 4, label + ": 4 rows")

    # INT8 / INT16 columns: the reader keeps them as int8 / int16 typed arrays
    # (ACC_I8 / ACC_I16). Access via the matching comptime-typed accessor.
    var c8 = back.column_at(0).as_primitive[DType.int8]()
    assert_equal(Int(c8.get(0)), -128, label + ": t8 row0")
    assert_equal(Int(c8.get(3)), 127, label + ": t8 row3")
    var c16 = back.column_at(1).as_primitive[DType.int16]()
    assert_equal(Int(c16.get(0)), -30000, label + ": s16 row0")
    assert_equal(Int(c16.get(3)), 30000, label + ": s16 row3")

    var l = back.column_as_primitive_int64(3)
    assert_equal(Int(l.get(0)), -9000000000, label + ": l64 row0")
    assert_equal(Int(l.get(3)), 9000000000, label + ": l64 row3")

    var i = back.column_as_primitive_int32(2)
    assert_equal(Int(i.get(2)), 65536, label + ": i32 row2")
    assert_equal(Int(i.get(3)), 2000000000, label + ": i32 row3")

    var dt = back.column_as_primitive_int32(4)
    assert_equal(Int(dt.get(1)), 19000, label + ": date row1")
    assert_equal(Int(dt.get(3)), -100, label + ": date row3")

    var f = back.column_as_primitive_float64(6)
    assert_true(f.get(3) == 1e10, label + ": f64 row3")

    var bl = back.column_as_boolean(7)
    assert_true(bl.get(0), label + ": bool row0")
    assert_true(not bl.get(2), label + ": bool row2")

    var st = back.column_as_string(8)
    assert_equal(st.get(2), String(""), label + ": str row2 empty")
    assert_equal(st.get(3), String("zzz"), label + ": str row3")


def test_orc_write_primitives_none() raises:
    _check(ORC_COMPRESSION_NONE, "NONE")


def test_orc_write_primitives_zstd() raises:
    _check(ORC_COMPRESSION_ZSTD, "ZSTD")


def main() raises:
    test_orc_write_primitives_none()
    test_orc_write_primitives_zstd()
    print("test_orc_write_primitives_roundtrip: ALL PASS")
