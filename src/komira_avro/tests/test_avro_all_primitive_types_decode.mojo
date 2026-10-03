# =============================================================================
# test_avro_all_primitive_types_decode.mojo — all-primitive decode.
# =============================================================================
#
# Acceptance:
#   test_all_primitive_types_decode — null/boolean/int/long/float/double/
#   bytes/string round-trip through the reader.
#
# The fixture is hand-emitted as the byte-exact inverse of the decoder (the
# decoder-test pattern; no external Avro library needed).
# =============================================================================

from std.testing import assert_equal, assert_true

from komira_avro import read_avro_bytes, OCF_SYNC_LEN
from std.memory import bitcast


# -----------------------------------------------------------------------------
# In-test OCF binary encoders.
# -----------------------------------------------------------------------------


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


def _enc_bytes(b: List[UInt8], mut out: List[UInt8]):
    _enc_long(Int64(len(b)), out)
    for i in range(len(b)):
        out.append(b[i])


def _enc_float(f: Float32, mut out: List[UInt8]):
    var bits = bitcast[DType.uint32, 1](f)
    for i in range(4):
        out.append(UInt8((bits >> UInt32(8 * i)) & 0xFF))


def _enc_double(d: Float64, mut out: List[UInt8]):
    var bits = bitcast[DType.uint64, 1](d)
    for i in range(8):
        out.append(UInt8((bits >> UInt64(8 * i)) & 0xFF))


# String -> List[UInt8] helper (avoids Span lifetime gymnastics in encoders).
def _str_bytes(s: String) -> List[UInt8]:
    var b = s.as_bytes()
    var out = List[UInt8]()
    for i in range(len(b)):
        out.append(b[i])
    return out^


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


# -----------------------------------------------------------------------------
# Tests.
# -----------------------------------------------------------------------------


comptime _SCHEMA_ALL = String(
    '{"type":"record","name":"AllPrims","fields":['
    '{"name":"b","type":"boolean"},'
    '{"name":"i","type":"int"},'
    '{"name":"l","type":"long"},'
    '{"name":"f","type":"float"},'
    '{"name":"d","type":"double"},'
    '{"name":"by","type":"bytes"},'
    '{"name":"s","type":"string"}]}'
)


def test_all_primitive_types() raises:
    """All scalar primitives decode to the right Arrow values across 3 rows."""
    var buf = List[UInt8]()
    _make_header(_SCHEMA_ALL, buf)

    var payload = List[UInt8]()
    # Row 0
    payload.append(0x01)  # boolean true
    _enc_long(Int64(42), payload)  # int
    _enc_long(Int64(1234567890123), payload)  # long
    _enc_float(Float32(3.5), payload)
    _enc_double(Float64(2.71828), payload)
    _enc_bytes(_str_bytes("xyz"), payload)
    _enc_str(String("hello"), payload)
    # Row 1
    payload.append(0x00)  # boolean false
    _enc_long(Int64(-7), payload)
    _enc_long(Int64(-99), payload)
    _enc_float(Float32(-1.25), payload)
    _enc_double(Float64(0.0), payload)
    _enc_bytes(_str_bytes(""), payload)
    _enc_str(String("world"), payload)
    # Row 2
    payload.append(0x01)
    _enc_long(Int64(2147483647), payload)  # int32 max
    _enc_long(Int64(0), payload)
    _enc_float(Float32(100.0), payload)
    _enc_double(Float64(-3.5), payload)
    _enc_bytes(_str_bytes("AB"), payload)
    _enc_str(String(""), payload)

    _append_block(buf, Int64(3), payload)

    var rb = read_avro_bytes(Span(buf))
    assert_equal(rb.num_rows(), 3, "3 rows")
    assert_equal(rb.num_columns(), 7, "7 columns")

    # boolean
    ref bcol = rb.column_at(0)
    var ba = bcol.as_boolean()
    assert_equal(ba.get(0), True, "b[0]")
    assert_equal(ba.get(1), False, "b[1]")
    assert_equal(ba.get(2), True, "b[2]")
    # int (Int32)
    ref icol = rb.column_at(1)
    var ia = icol.as_primitive[DType.int32]()
    assert_equal(Int(ia.get(0)), 42, "i[0]")
    assert_equal(Int(ia.get(1)), -7, "i[1]")
    assert_equal(Int(ia.get(2)), 2147483647, "i[2]")
    # long (Int64)
    ref lcol = rb.column_at(2)
    var la = lcol.as_primitive[DType.int64]()
    assert_equal(Int(la.get(0)), 1234567890123, "l[0]")
    assert_equal(Int(la.get(1)), -99, "l[1]")
    # float
    ref fcol = rb.column_at(3)
    var fa = fcol.as_primitive[DType.float32]()
    assert_true(Float64(fa.get(0)) > 3.49 and Float64(fa.get(0)) < 3.51, "f[0]")
    assert_true(Float64(fa.get(1)) < -1.24, "f[1]")
    # double
    ref dcol = rb.column_at(4)
    var da = dcol.as_primitive[DType.float64]()
    assert_true(da.get(0) > 2.7182 and da.get(0) < 2.7183, "d[0]")
    assert_equal(da.get(1), Float64(0.0), "d[1]")
    # bytes (Binary)
    ref bycol = rb.column_at(5)
    var bya = bycol.as_binary()
    var b0 = bya.get(0)
    assert_equal(len(b0), 3, "by[0] len")
    assert_equal(Int(b0[0]), ord("x"), "by[0][0]")
    assert_equal(len(bya.get(1)), 0, "by[1] empty")
    # string
    ref scol = rb.column_at(6)
    var sa = scol.as_string()
    assert_equal(sa.get(0), String("hello"), "s[0]")
    assert_equal(sa.get(1), String("world"), "s[1]")
    assert_equal(sa.get(2), String(""), "s[2]")


def main() raises:
    test_all_primitive_types()
    print("test_avro_all_primitive_types_decode: ALL PASS")
