# =============================================================================
# test_avro_cov_writer_types.mojo -- the writer's per-type encode arms (int8,
# int16, uint8, uint32, large_string, nullable and non-nullable columns with
# nulls), the Arrow -> Avro schema emitter's degrade and refusal arms, and a
# read back through the independent reader as the oracle.
# =============================================================================
#
# What each case proves, and the mutant planted in the product code to see
# it fail (each alone, then restored; the red message is quoted):
#   W1  a 12-column batch (int8, int16, uint8, uint32, uint16, float64,
#       float32, string, bool, large_string, int64, string; a null in every
#       nullable column, two non-nullable ones) written with the arrow.*
#       annotations OFF reads back value for value and null for null, in two
#       blocks, through null and deflate. Mutant: the int8 arm encodes
#       `arr.get(row) + 1`: red, -127 vs -128.
#   W2  the emitted schema JSON is pinned: int8/int16/uint8/uint16 -> "int",
#       uint32 -> "long", large_string -> "string", nullable -> ["null",T],
#       non-nullable -> bare T. Mutant: `_standard_avro_type_for_lossy`'s
#       long arm returns "int": red already in W1 ("column is int32 but
#       requested int64").
#   W3  with the annotations ON, the read-back types are INT8, INT16, UINT8,
#       UINT32, UINT16 (the arrow.* round-trip of the arms W1 added).
#   W4  from_arrow_schema_json: BINARY / LARGE_BINARY -> "bytes"; an Arrow
#       type with no Avro mapping, an empty schema, and a non-lossy type
#       handed to the lossy emitters are refused by name; a fixed-backed
#       lossy type with the annotations off degrades to "bytes" (the
#       function's documented contract). Mutant: the BINARY arm writes
#       "string": red on the pinned JSON.
# =============================================================================

from std.testing import assert_equal, assert_true

from komira_arrow.arrow_types import ArrowType
from komira_arrow.column import Column
from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.string_array import StringArray
from komira_arrow.large_string_array import LargeStringArray
from komira_arrow.boolean_array import BooleanArray
from komira_arrow.record_batch import RecordBatch, RecordBatchBuilder
from komira_arrow.schema import Schema, SchemaBuilder, Field

from komira_avro import (
    AvroWriterOptions,
    write_avro_bytes,
    read_avro_bytes,
    decode_ocf_header,
    scan_ocf_blocks,
    from_arrow_schema_json,
    from_arrow_avro_type_json,
    AVRO_CODEC_NULL,
    AVRO_CODEC_DEFLATE,
)
from komira_avro.avro_logical_arrow import _standard_avro_type_for_lossy


comptime _N = 4


def _batch() raises -> RecordBatch:
    var sb = SchemaBuilder()
    sb.add_field(Field("i8", ArrowType.INT8, True))
    sb.add_field(Field("i16", ArrowType.INT16, True))
    sb.add_field(Field("u8", ArrowType.UINT8, True))
    sb.add_field(Field("u32", ArrowType.UINT32, True))
    sb.add_field(Field("u16", ArrowType.UINT16, True))
    sb.add_field(Field("f64", ArrowType.FLOAT64, True))
    sb.add_field(Field("f32", ArrowType.FLOAT32, True))
    sb.add_field(Field("s", ArrowType.STRING, True))
    sb.add_field(Field("b", ArrowType.BOOL, True))
    sb.add_field(Field("ls", ArrowType.LARGE_STRING, True))
    sb.add_field(Field("i64", ArrowType.INT64, False))
    sb.add_field(Field("s2", ArrowType.STRING, False))

    var i8 = PrimitiveArray[DType.int8].allocate_nullable(_N)
    i8.set(0, Int8(-128))
    i8.set(1, Int8(0))
    i8._set_null(2)
    i8.set(3, Int8(127))
    var i16 = PrimitiveArray[DType.int16].allocate_nullable(_N)
    i16.set(0, Int16(-32768))
    i16._set_null(1)
    i16.set(2, Int16(2))
    i16.set(3, Int16(32767))
    var u8 = PrimitiveArray[DType.uint8].allocate_nullable(_N)
    u8.set(0, UInt8(0))
    u8.set(1, UInt8(255))
    u8._set_null(2)
    u8.set(3, UInt8(7))
    var u32 = PrimitiveArray[DType.uint32].allocate_nullable(_N)
    u32.set(0, UInt32(0))
    u32.set(1, UInt32(4294967295))
    u32.set(2, UInt32(5))
    u32._set_null(3)
    var u16 = PrimitiveArray[DType.uint16].allocate_nullable(_N)
    u16._set_null(0)
    u16.set(1, UInt16(65535))
    u16.set(2, UInt16(1))
    u16.set(3, UInt16(2))
    var f64 = PrimitiveArray[DType.float64].allocate_nullable(_N)
    f64.set(0, 1.5)
    f64._set_null(1)
    f64.set(2, -2.0)
    f64.set(3, 0.25)
    var f32 = PrimitiveArray[DType.float32].allocate_nullable(_N)
    f32._set_null(0)
    f32.set(1, Float32(2.5))
    f32.set(2, Float32(-0.5))
    f32.set(3, Float32(8.0))
    var sv: List[String] = ["a", "", "", "dd"]
    var sok: List[Bool] = [True, False, True, True]
    var s = StringArray.from_strings_with_validity(sv, sok)
    var b = BooleanArray.allocate(_N)
    b.set(0, True)
    b.set(1, False)
    b.set(2, False)
    b.set(3, True)
    b._set_null(1)
    var lv: List[String] = ["x", "", "yz", ""]
    var lok: List[Bool] = [True, False, True, True]
    var ls = LargeStringArray.from_strings_with_validity(lv, lok)
    var i64 = PrimitiveArray[DType.int64].allocate(_N)
    i64.set(0, Int64.MIN)
    i64.set(1, Int64(-1))
    i64.set(2, Int64(300))
    i64.set(3, Int64.MAX)
    var s2v: List[String] = ["p", "q", "r", "s"]
    var s2 = StringArray.from_strings(s2v)

    var bb = RecordBatchBuilder.with_capacity(12)
    bb.add_column(
        Column.from_primitive_with_arrow_type[DType.int8](i8^, ArrowType.INT8)
    )
    bb.add_column(
        Column.from_primitive_with_arrow_type[DType.int16](
            i16^, ArrowType.INT16
        )
    )
    bb.add_column(
        Column.from_primitive_with_arrow_type[DType.uint8](
            u8^, ArrowType.UINT8
        )
    )
    bb.add_column(
        Column.from_primitive_with_arrow_type[DType.uint32](
            u32^, ArrowType.UINT32
        )
    )
    bb.add_column(
        Column.from_primitive_with_arrow_type[DType.uint16](
            u16^, ArrowType.UINT16
        )
    )
    bb.add_column(Column.from_primitive[DType.float64](f64^))
    bb.add_column(Column.from_primitive[DType.float32](f32^))
    bb.add_column(Column.from_string(s^))
    bb.add_column(Column.from_boolean(b^))
    bb.add_column(Column.from_large_string(ls^))
    bb.add_column(Column.from_primitive[DType.int64](i64^))
    bb.add_column(Column.from_string(s2^))
    return bb.build(sb.build())


def _opts(codec: Int, logicals: Bool) -> AvroWriterOptions:
    # Two rows per block, so every column's accumulator is reserved twice
    # on the read side (the second reserve copies a validity bitmap).
    return AvroWriterOptions(
        codec, 1 << 20, 2, logicals, String("R"), True, False
    )


def _check_values(rb: RecordBatch, label: String) raises:
    assert_equal(rb.num_rows(), _N, label)
    assert_equal(rb.num_columns(), 12, label)
    var i8 = rb.column_as_primitive_int32(0)
    assert_equal(Int(i8.get(0)), -128, label + " i8[0]")
    assert_equal(Int(i8.get(1)), 0, label + " i8[1]")
    assert_true(i8.is_null(2), label + " i8[2] null")
    assert_equal(Int(i8.get(3)), 127, label + " i8[3]")
    var i16 = rb.column_as_primitive_int32(1)
    assert_equal(Int(i16.get(0)), -32768, label + " i16[0]")
    assert_true(i16.is_null(1), label + " i16[1] null")
    assert_equal(Int(i16.get(2)), 2, label + " i16[2]")
    assert_equal(Int(i16.get(3)), 32767, label + " i16[3]")
    assert_true(not rb.schema.field_nullable(10), label + " i64 not nullable")
    var u8 = rb.column_as_primitive_int32(2)
    assert_equal(Int(u8.get(1)), 255, label + " u8[1]")
    assert_true(u8.is_null(2), label + " u8[2] null")
    assert_equal(Int(u8.get(3)), 7, label + " u8[3]")
    var u32 = rb.column_as_primitive_int64(3)
    assert_equal(Int(u32.get(1)), 4294967295, label + " u32[1]")
    assert_equal(Int(u32.get(2)), 5, label + " u32[2]")
    assert_true(u32.is_null(3), label + " u32[3] null")
    assert_true(not u32.is_null(0), label + " u32[0] valid")
    var u16 = rb.column_as_primitive_int32(4)
    assert_true(u16.is_null(0), label + " u16[0] null")
    assert_equal(Int(u16.get(1)), 65535, label + " u16[1]")
    var f64 = rb.column_as_primitive_float64(5)
    assert_true(f64.get(0) == 1.5, label + " f64[0]")
    assert_true(f64.is_null(1), label + " f64[1] null")
    assert_true(f64.get(2) == -2.0, label + " f64[2]")
    assert_true(f64.get(3) == 0.25, label + " f64[3]")
    var f32 = rb.column_as_primitive_float32(6)
    assert_true(f32.is_null(0), label + " f32[0] null")
    assert_true(f32.get(1) == Float32(2.5), label + " f32[1]")
    assert_true(f32.get(3) == Float32(8.0), label + " f32[3]")
    var s = rb.column_as_string(7)
    assert_equal(s.get(0), "a", label + " s[0]")
    assert_true(s.is_null(1), label + " s[1] null")
    assert_true(not s.is_null(2), label + " s[2] valid")
    assert_equal(s.get(2), "", label + " s[2]")
    assert_equal(s.get(3), "dd", label + " s[3]")
    var b = rb.column_as_boolean(8)
    assert_true(b.get(0), label + " b[0]")
    assert_true(b.is_null(1), label + " b[1] null")
    assert_true(not b.get(2), label + " b[2]")
    assert_true(not b.is_null(2), label + " b[2] valid")
    assert_true(b.get(3), label + " b[3]")
    var ls = rb.column_as_string(9)
    assert_equal(ls.get(0), "x", label + " ls[0]")
    assert_true(ls.is_null(1), label + " ls[1] null")
    assert_equal(ls.get(2), "yz", label + " ls[2]")
    assert_equal(ls.get(3), "", label + " ls[3]")
    var i64 = rb.column_as_primitive_int64(10)
    assert_equal(i64.get(0), Int64.MIN, label + " i64[0]")
    assert_equal(Int(i64.get(2)), 300, label + " i64[2]")
    assert_equal(i64.get(3), Int64.MAX, label + " i64[3]")
    var s2 = rb.column_as_string(11)
    assert_equal(s2.get(0), "p", label + " s2[0]")
    assert_equal(s2.get(3), "s", label + " s2[3]")


def test_round_trip_every_arm() raises:
    """W1."""
    var rb = _batch()
    var codecs: List[Int] = [AVRO_CODEC_NULL, AVRO_CODEC_DEFLATE]
    for c in codecs:
        var bytes = write_avro_bytes(rb, _opts(c, False))
        assert_equal(len(scan_ocf_blocks(Span(bytes))), 2, "two blocks")
        _check_values(read_avro_bytes(Span(bytes)), "codec " + String(c))


def test_schema_json_without_logicals() raises:
    """W2."""
    var rb = _batch()
    var bytes = write_avro_bytes(rb, _opts(AVRO_CODEC_NULL, False))
    var h = decode_ocf_header(Span(bytes))
    assert_equal(
        h.schema_json,
        String('{"type":"record","name":"R","fields":[')
        + '{"name":"i8","type":["null","int"]},'
        + '{"name":"i16","type":["null","int"]},'
        + '{"name":"u8","type":["null","int"]},'
        + '{"name":"u32","type":["null","long"]},'
        + '{"name":"u16","type":["null","int"]},'
        + '{"name":"f64","type":["null","double"]},'
        + '{"name":"f32","type":["null","float"]},'
        + '{"name":"s","type":["null","string"]},'
        + '{"name":"b","type":["null","boolean"]},'
        + '{"name":"ls","type":["null","string"]},'
        + '{"name":"i64","type":"long"},'
        + '{"name":"s2","type":"string"}]}',
    )


def test_logicals_restore_types() raises:
    """W3."""
    var rb = _batch()
    var bytes = write_avro_bytes(rb, _opts(AVRO_CODEC_NULL, True))
    var back = read_avro_bytes(Span(bytes))
    assert_true(back.schema.field_arrow_type(0) == ArrowType.INT8, "i8")
    assert_true(back.schema.field_arrow_type(1) == ArrowType.INT16, "i16")
    assert_true(back.schema.field_arrow_type(2) == ArrowType.UINT8, "u8")
    assert_true(back.schema.field_arrow_type(3) == ArrowType.UINT32, "u32")
    assert_true(back.schema.field_arrow_type(4) == ArrowType.UINT16, "u16")
    assert_equal(back.num_rows(), _N)


def _one_field(t: ArrowType, nullable: Bool) -> Schema:
    var sb = SchemaBuilder()
    sb.add_field(Field("c", t, nullable))
    return sb.build()


def _schema_err(s: Schema) -> String:
    try:
        return from_arrow_schema_json(s, String("R"), True)
    except e:
        return String(e)


def test_schema_emitter_edges() raises:
    """W4."""
    assert_equal(
        _schema_err(_one_field(ArrowType.BINARY, False)),
        '{"type":"record","name":"R","fields":[{"name":"c","type":"bytes"}]}',
    )
    assert_equal(
        _schema_err(_one_field(ArrowType.LARGE_BINARY, True)),
        '{"type":"record","name":"R","fields":[{"name":"c","type":'
        '["null","bytes"]}]}',
    )
    var bad = _schema_err(_one_field(ArrowType.DECIMAL128, False))
    assert_true(
        bad.startswith(
            "AvroSchemaError.UNSUPPORTED_ARROW_TYPE: Arrow type "
        ),
        bad,
    )
    assert_true(bad.find("has no Avro writer mapping") > 0, bad)
    var no_fields = SchemaBuilder()
    assert_equal(
        _schema_err(no_fields.build()),
        "AvroSchemaError.EMPTY_SCHEMA: Arrow schema has no columns",
    )
    # A fixed-backed lossy type with the annotations off: "bytes".
    assert_equal(
        from_arrow_schema_json(
            _one_field(ArrowType.FLOAT16, False), String("R"), False
        ),
        '{"type":"record","name":"R","fields":[{"name":"c","type":"bytes"}]}',
    )
    var got = String("(accepted)")
    try:
        _ = from_arrow_avro_type_json(ArrowType.INT32, String("f"))
    except e:
        got = String(e)
    assert_equal(
        got,
        "AvroSchemaError.NOT_A_LOSSY_ARROW_TYPE: arrow.* round-trip"
        " annotation requested for a non-lossy Arrow type",
    )
    got = String("(accepted)")
    try:
        _ = _standard_avro_type_for_lossy(ArrowType.INT32)
    except e:
        got = String(e)
    assert_equal(got, "AvroSchemaError.NOT_A_LOSSY_ARROW_TYPE")


def main() raises:
    test_round_trip_every_arm()
    test_schema_json_without_logicals()
    test_logicals_restore_types()
    test_schema_emitter_edges()
    print("test_avro_cov_writer_types: ALL PASS")
