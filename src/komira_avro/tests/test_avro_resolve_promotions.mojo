# =============================================================================
# test_avro_resolve_promotions.mojo — type promotion.
# =============================================================================
#
# The 6 numeric promotions (int→long, int→float, int→double, long→float,
# long→double, float→double) + bidirectional string↔bytes. The writer encodes
# the narrower type; the reader expects the wider type. Fixtures hand-emitted.
# =============================================================================

from std.testing import assert_equal, assert_true

from komira_avro import read_avro_bytes_resolved, OCF_SYNC_LEN
from std.memory import bitcast


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


def _enc_float(f: Float32, mut out: List[UInt8]):
    var bits = bitcast[DType.uint32, 1](f)
    for i in range(4):
        out.append(UInt8((bits >> UInt32(8 * i)) & 0xFF))


def _enc_double(f: Float64, mut out: List[UInt8]):
    var bits = bitcast[DType.uint64, 1](f)
    for i in range(8):
        out.append(UInt8((bits >> UInt64(8 * i)) & 0xFF))


def _str_bytes(s: String) -> List[UInt8]:
    var b = s.as_bytes()
    var out = List[UInt8]()
    for i in range(len(b)):
        out.append(b[i])
    return out^


def _enc_str(s: String, mut out: List[UInt8]):
    var b = s.as_bytes()
    _enc_long(Int64(len(b)), out)
    for i in range(len(b)):
        out.append(b[i])


def _enc_bytes(b: List[UInt8], mut out: List[UInt8]):
    _enc_long(Int64(len(b)), out)
    for i in range(len(b)):
        out.append(b[i])


def _sync() -> List[UInt8]:
    var s = List[UInt8]()
    for i in range(OCF_SYNC_LEN):
        s.append(UInt8(0xA0 + i))
    return s^


def _make_header(schema: String, mut out: List[UInt8]):
    out.append(UInt8(ord("O")))
    out.append(UInt8(ord("b")))
    out.append(UInt8(ord("j")))
    out.append(0x01)
    _enc_long(Int64(2), out)
    _enc_str(String("avro.schema"), out)
    _enc_bytes(_str_bytes(schema), out)
    _enc_str(String("avro.codec"), out)
    _enc_bytes(_str_bytes(String("null")), out)
    _enc_long(Int64(0), out)
    var s = _sync()
    for i in range(len(s)):
        out.append(s[i])


def _append_block(mut out: List[UInt8], object_count: Int64, payload: List[UInt8]):
    _enc_long(object_count, out)
    _enc_long(Int64(len(payload)), out)
    for i in range(len(payload)):
        out.append(payload[i])
    var s = _sync()
    for i in range(len(s)):
        out.append(s[i])


def _one_field_schema(name: String, type_name: String) -> String:
    return String(
        '{"type":"record","name":"R","fields":[{"name":"'
    ) + name + String('","type":"') + type_name + String('"}]}')


# -----------------------------------------------------------------------------
# int → long.
# -----------------------------------------------------------------------------
def test_promote_int_to_long() raises:
    var buf = List[UInt8]()
    _make_header(_one_field_schema("v", "int"), buf)
    var p = List[UInt8]()
    _enc_long(Int64(5), p)
    _enc_long(Int64(-3), p)
    _append_block(buf, Int64(2), p)
    var rb = read_avro_bytes_resolved(Span(buf), _one_field_schema("v", "long"))
    var c = rb.column_at(0).as_primitive[DType.int64]()
    assert_equal(Int(c.get(0)), 5, "int->long row0")
    assert_equal(Int(c.get(1)), -3, "int->long row1")


# -----------------------------------------------------------------------------
# int → float.
# -----------------------------------------------------------------------------
def test_promote_int_to_float() raises:
    var buf = List[UInt8]()
    _make_header(_one_field_schema("v", "int"), buf)
    var p = List[UInt8]()
    _enc_long(Int64(7), p)
    _append_block(buf, Int64(1), p)
    var rb = read_avro_bytes_resolved(Span(buf), _one_field_schema("v", "float"))
    var c = rb.column_at(0).as_primitive[DType.float32]()
    assert_true(c.get(0) > 6.99 and c.get(0) < 7.01, "int->float == 7.0")


# -----------------------------------------------------------------------------
# int → double.
# -----------------------------------------------------------------------------
def test_promote_int_to_double() raises:
    var buf = List[UInt8]()
    _make_header(_one_field_schema("v", "int"), buf)
    var p = List[UInt8]()
    _enc_long(Int64(9), p)
    _append_block(buf, Int64(1), p)
    var rb = read_avro_bytes_resolved(Span(buf), _one_field_schema("v", "double"))
    var c = rb.column_at(0).as_primitive[DType.float64]()
    assert_true(c.get(0) > 8.99 and c.get(0) < 9.01, "int->double == 9.0")


# -----------------------------------------------------------------------------
# long → float.
# -----------------------------------------------------------------------------
def test_promote_long_to_float() raises:
    var buf = List[UInt8]()
    _make_header(_one_field_schema("v", "long"), buf)
    var p = List[UInt8]()
    _enc_long(Int64(123), p)
    _append_block(buf, Int64(1), p)
    var rb = read_avro_bytes_resolved(Span(buf), _one_field_schema("v", "float"))
    var c = rb.column_at(0).as_primitive[DType.float32]()
    assert_true(c.get(0) > 122.9 and c.get(0) < 123.1, "long->float == 123.0")


# -----------------------------------------------------------------------------
# long → double.
# -----------------------------------------------------------------------------
def test_promote_long_to_double() raises:
    var buf = List[UInt8]()
    _make_header(_one_field_schema("v", "long"), buf)
    var p = List[UInt8]()
    _enc_long(Int64(456), p)
    _append_block(buf, Int64(1), p)
    var rb = read_avro_bytes_resolved(Span(buf), _one_field_schema("v", "double"))
    var c = rb.column_at(0).as_primitive[DType.float64]()
    assert_true(c.get(0) > 455.9 and c.get(0) < 456.1, "long->double == 456.0")


# -----------------------------------------------------------------------------
# float → double.
# -----------------------------------------------------------------------------
def test_promote_float_to_double() raises:
    var buf = List[UInt8]()
    _make_header(_one_field_schema("v", "float"), buf)
    var p = List[UInt8]()
    _enc_float(Float32(2.5), p)
    _append_block(buf, Int64(1), p)
    var rb = read_avro_bytes_resolved(Span(buf), _one_field_schema("v", "double"))
    var c = rb.column_at(0).as_primitive[DType.float64]()
    assert_true(c.get(0) > 2.49 and c.get(0) < 2.51, "float->double == 2.5")


# -----------------------------------------------------------------------------
# string ↔ bytes — bidirectional.
# -----------------------------------------------------------------------------
def test_resolve_string_bytes_bidirectional() raises:
    # string (writer) → bytes (reader).
    var buf = List[UInt8]()
    _make_header(_one_field_schema("v", "string"), buf)
    var p = List[UInt8]()
    _enc_str(String("hi"), p)
    _append_block(buf, Int64(1), p)
    var rb = read_avro_bytes_resolved(Span(buf), _one_field_schema("v", "bytes"))
    var bcol = rb.column_at(0).as_binary()
    var got = bcol.get(0)
    assert_equal(len(got), 2, "string->bytes len")
    assert_equal(Int(got[0]), ord("h"), "string->bytes[0]")
    assert_equal(Int(got[1]), ord("i"), "string->bytes[1]")

    # bytes (writer) → string (reader).
    var buf2 = List[UInt8]()
    _make_header(_one_field_schema("v", "bytes"), buf2)
    var p2 = List[UInt8]()
    var raw = List[UInt8]()
    raw.append(UInt8(ord("o")))
    raw.append(UInt8(ord("k")))
    _enc_bytes(raw, p2)
    _append_block(buf2, Int64(1), p2)
    var rb2 = read_avro_bytes_resolved(Span(buf2), _one_field_schema("v", "string"))
    var scol = rb2.column_at(0).as_string()
    assert_equal(scol.get(0), String("ok"), "bytes->string")


def main() raises:
    test_promote_int_to_long()
    test_promote_int_to_float()
    test_promote_int_to_double()
    test_promote_long_to_float()
    test_promote_long_to_double()
    test_promote_float_to_double()
    test_resolve_string_bytes_bidirectional()
    print("test_avro_resolve_promotions: ALL PASS")
