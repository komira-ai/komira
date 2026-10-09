# =============================================================================
# test_avro_cov_comptime.mojo -- the comptime shape-kind reader on the arms
# its other tests leave: a compressed file on both the hot path and the
# fallback, the boolean / float / bytes columns of the hot path, the timing
# report, and every classifier answer that is UNKNOWN.
# =============================================================================
#
# The oracle is the values written into the payload; `read_avro_bytes` (the
# runtime interpreter) is checked against the same values.
#
# What each case proves, and the mutant planted in the product code to see
# it fail (each alone, then restored; the red message is quoted):
#   T1  a non-null scalar record (boolean, float, bytes, long, string) on
#       the hot path decodes the written values from a null-codec file and
#       from a deflate file (with the timing report on). Mutants: the hot
#       boolean arm pushes `not read_boolean()`: red, "hot null b0"; the hot
#       path decodes `raw` instead of the decompressed block: red,
#       "MALFORMED: negative bytes length".
#   T2  a mixed-nullability record from a deflate file falls back to the
#       interpreter and decodes the written values. Mutant: the fallback
#       decodes `raw` for a compressed codec: red, -10 vs 10.
#   T3  classify_avro_shape answers UNKNOWN for a non-record root, a record
#       with no field, a fixed field, a union of three branches, a no-null
#       union of two, and a record mixing nullable and non-nullable fields.
#       Mutants: the non-record root answers N_PRIMS: red in T3; the mixed
#       case answers NULLABLE_PRIMS: red already in T2 ("TRUNCATED: long
#       varint overrun", the hot nullable arm reads a union tag the writer
#       never wrote).
# =============================================================================

from std.memory import bitcast
from std.testing import assert_equal, assert_true

from komira_avro import (
    AvroSchema,
    classify_avro_shape,
    decode_avro_bytes_comptime,
    read_avro_bytes,
    compress_block,
    SHAPE_KIND_UNKNOWN,
    SHAPE_KIND_STRUCT_OF_N_PRIMS,
    AVRO_CODEC_NULL,
    AVRO_CODEC_DEFLATE,
    OCF_SYNC_LEN,
)
from komira_arrow.record_batch import RecordBatch


def _enc_long(n: Int64, mut out: List[UInt8]):
    var zz = UInt64((n << 1) ^ (n >> 63))
    while True:
        var b = UInt8(zz & 0x7F)
        zz >>= 7
        if zz != 0:
            out.append(b | 0x80)
        else:
            out.append(b)
            break


def _enc_str(s: String, mut out: List[UInt8]):
    var b = s.as_bytes()
    _enc_long(Int64(len(b)), out)
    for i in range(len(b)):
        out.append(b[i])


def _enc_float(v: Float32, mut out: List[UInt8]):
    var bits = bitcast[DType.uint32, 1](SIMD[DType.float32, 1](v))
    for i in range(4):
        out.append(UInt8((bits >> UInt32(8 * i)) & 0xFF))


def _file(
    schema: String, codec: String, count: Int, block: List[UInt8]
) -> List[UInt8]:
    var out: List[UInt8] = [0x4F, 0x62, 0x6A, 0x01]
    _enc_long(2, out)
    _enc_str("avro.schema", out)
    _enc_str(schema, out)
    _enc_str("avro.codec", out)
    _enc_str(codec, out)
    _enc_long(0, out)
    for i in range(OCF_SYNC_LEN):
        out.append(UInt8(0x11 * (i % 15) + 1))
    _enc_long(Int64(count), out)
    _enc_long(Int64(len(block)), out)
    out.extend(Span(block))
    for i in range(OCF_SYNC_LEN):
        out.append(UInt8(0x11 * (i % 15) + 1))
    return out^


comptime _HOT = String(
    '{"type":"record","name":"R","fields":['
    '{"name":"b","type":"boolean"},'
    '{"name":"f","type":"float"},'
    '{"name":"y","type":"bytes"},'
    '{"name":"l","type":"long"},'
    '{"name":"s","type":"string"}]}'
)


def _hot_payload() -> List[UInt8]:
    var p = List[UInt8]()
    p.append(1)
    _enc_float(Float32(1.25), p)
    _enc_long(2, p)
    p.append(0xAB)
    p.append(0xCD)
    _enc_long(-3, p)
    _enc_str("one", p)
    p.append(0)
    _enc_float(Float32(-8.0), p)
    _enc_long(0, p)
    _enc_long(1 << 40, p)
    _enc_str("", p)
    return p^


def _check_hot(rb: RecordBatch, label: String) raises:
    assert_equal(rb.num_rows(), 2, label)
    var b = rb.column_as_boolean(0)
    assert_true(b.get(0), label + " b0")
    assert_true(not b.get(1), label + " b1")
    var f = rb.column_as_primitive_float32(1)
    assert_true(f.get(0) == Float32(1.25), label + " f0")
    assert_true(f.get(1) == Float32(-8.0), label + " f1")
    var y = rb.column_at(2).as_binary()
    assert_equal(len(y.get(0)), 2, label + " y0 len")
    assert_equal(Int(y.get(0)[1]), 0xCD, label + " y0[1]")
    assert_equal(len(y.get(1)), 0, label + " y1 len")
    var l = rb.column_as_primitive_int64(3)
    assert_equal(Int(l.get(0)), -3, label + " l0")
    assert_equal(Int(l.get(1)), 1 << 40, label + " l1")
    var s = rb.column_as_string(4)
    assert_equal(s.get(0), "one", label + " s0")
    assert_equal(s.get(1), "", label + " s1")


def test_hot_path_null_and_deflate() raises:
    """T1."""
    var schema = AvroSchema.parse(_HOT)
    assert_equal(classify_avro_shape(schema), SHAPE_KIND_STRUCT_OF_N_PRIMS)
    var payload = _hot_payload()
    var plain = _file(_HOT, "null", 2, payload)
    _check_hot(decode_avro_bytes_comptime(Span(plain)), "hot null")
    var packed = compress_block(AVRO_CODEC_DEFLATE, Span(payload))
    assert_true(len(packed) != len(payload), "deflate changed the bytes")
    var deflated = _file(_HOT, "deflate", 2, packed)
    _check_hot(
        decode_avro_bytes_comptime(Span(deflated), print_timing=True),
        "hot deflate",
    )
    _check_hot(read_avro_bytes(Span(deflated)), "interp deflate")


def test_fallback_deflate() raises:
    """T2."""
    var mixed = String(
        '{"type":"record","name":"R","fields":['
        '{"name":"a","type":"long"},'
        '{"name":"n","type":["null","int"]}]}'
    )
    var p = List[UInt8]()
    _enc_long(10, p)
    _enc_long(0, p)  # n null
    _enc_long(-20, p)
    _enc_long(1, p)
    _enc_long(33, p)
    var packed = compress_block(AVRO_CODEC_DEFLATE, Span(p))
    var rb = decode_avro_bytes_comptime(Span(_file(mixed, "deflate", 2, packed)))
    assert_equal(rb.num_rows(), 2)
    var a = rb.column_as_primitive_int64(0)
    assert_equal(Int(a.get(0)), 10)
    assert_equal(Int(a.get(1)), -20)
    var n = rb.column_as_primitive_int32(1)
    assert_true(n.is_null(0), "n0 null")
    assert_equal(Int(n.get(1)), 33)


def _shape(json: String) raises -> Int:
    return classify_avro_shape(AvroSchema.parse(json))


def test_classifier_unknowns() raises:
    """T3."""
    assert_equal(_shape('"long"'), SHAPE_KIND_UNKNOWN, "non-record root")
    assert_equal(
        _shape('{"type":"record","name":"R","fields":[]}'),
        SHAPE_KIND_UNKNOWN,
        "no field",
    )
    assert_equal(
        _shape(
            '{"type":"record","name":"R","fields":['
            '{"name":"x","type":{"type":"fixed","name":"F","size":2}}]}'
        ),
        SHAPE_KIND_UNKNOWN,
        "fixed",
    )
    assert_equal(
        _shape(
            '{"type":"record","name":"R","fields":['
            '{"name":"u","type":["null","int","long"]}]}'
        ),
        SHAPE_KIND_UNKNOWN,
        "three-branch union",
    )
    assert_equal(
        _shape(
            '{"type":"record","name":"R","fields":['
            '{"name":"u","type":["int","string"]}]}'
        ),
        SHAPE_KIND_UNKNOWN,
        "no-null union",
    )
    assert_equal(
        _shape(
            '{"type":"record","name":"R","fields":['
            '{"name":"a","type":"long"},'
            '{"name":"n","type":["null","int"]}]}'
        ),
        SHAPE_KIND_UNKNOWN,
        "mixed nullability",
    )


def main() raises:
    test_hot_path_null_and_deflate()
    test_fallback_deflate()
    test_classifier_unknowns()
    print("test_avro_cov_comptime: ALL PASS")
