# =============================================================================
# test_avro_logical_types_decode.mojo — logical-type decode.
# =============================================================================
#
# Acceptance:
#   test_logical_types_decode — date / decimal / timestamp-millis /
#   timestamp-micros / uuid (+ time-millis / time-micros).
#
# Logical types ride on a physical primitive: date/time-millis on `int`;
# time-micros/timestamp-* on `long`; decimal on `bytes`/`fixed`; uuid on
# `string` (the type lattice maps uuid → BINARY). The reader stamps the Arrow logical
# ArrowType over the physical storage via from_primitive_with_arrow_type.
# Fixture hand-emitted (fastavro unavailable).
# =============================================================================

from std.testing import assert_equal, assert_true

from komira_avro import read_avro_bytes, OCF_SYNC_LEN
from komira_arrow.arrow_types import ArrowType


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


# -----------------------------------------------------------------------------
# Tests.
# -----------------------------------------------------------------------------


comptime _SCHEMA_LOGICAL = String(
    '{"type":"record","name":"Logicals","fields":['
    '{"name":"d","type":{"type":"int","logicalType":"date"}},'
    '{"name":"tm","type":{"type":"int","logicalType":"time-millis"}},'
    '{"name":"tu","type":{"type":"long","logicalType":"time-micros"}},'
    '{"name":"tsm","type":{"type":"long","logicalType":"timestamp-millis"}},'
    '{"name":"tsu","type":{"type":"long","logicalType":"timestamp-micros"}},'
    '{"name":"dec","type":{"type":"bytes","logicalType":"decimal",'
    '"precision":9,"scale":2}},'
    '{"name":"u","type":{"type":"string","logicalType":"uuid"}}]}'
)


def test_logical_types() raises:
    """Logical types decode to the right Arrow types + values."""
    var buf = List[UInt8]()
    _make_header(_SCHEMA_LOGICAL, buf)

    var p = List[UInt8]()
    # Row 0
    _enc_long(Int64(19000), p)  # date (days since epoch)
    _enc_long(Int64(3600000), p)  # time-millis
    _enc_long(Int64(3600000000), p)  # time-micros
    _enc_long(Int64(1700000000000), p)  # timestamp-millis
    _enc_long(Int64(1700000000000000), p)  # timestamp-micros
    # decimal 123.45 -> unscaled 12345 -> BE 2 bytes [0x30,0x39]
    var dec0 = List[UInt8]()
    dec0.append(0x30)
    dec0.append(0x39)
    _enc_bytes(dec0, p)
    _enc_str(String("550e8400-e29b-41d4-a716-446655440000"), p)
    # Row 1
    _enc_long(Int64(0), p)
    _enc_long(Int64(0), p)
    _enc_long(Int64(0), p)
    _enc_long(Int64(-1), p)
    _enc_long(Int64(-1), p)
    # decimal -1.00 -> unscaled -100 -> BE two's complement of 100 = [0xFF,0x9C]
    var dec1 = List[UInt8]()
    dec1.append(0xFF)
    dec1.append(0x9C)
    _enc_bytes(dec1, p)
    _enc_str(String("00000000-0000-0000-0000-000000000000"), p)

    _append_block(buf, Int64(2), p)

    var rb = read_avro_bytes(Span(buf))
    assert_equal(rb.num_rows(), 2, "2 rows")
    assert_equal(rb.num_columns(), 7, "7 cols")

    # date -> DATE32 (Int32 storage)
    ref dcol = rb.column_at(0)
    assert_equal(dcol.arrow_type.type_id, ArrowType.DATE32.type_id, "date type")
    var da = dcol.as_primitive[DType.int32]()
    assert_equal(Int(da.get(0)), 19000, "date[0]")

    # time-millis -> TIME32_MS (Int32)
    ref tmcol = rb.column_at(1)
    assert_equal(tmcol.arrow_type.type_id, ArrowType.TIME32_MS.type_id, "time-millis type")
    var tma = tmcol.as_primitive[DType.int32]()
    assert_equal(Int(tma.get(0)), 3600000, "time-millis[0]")

    # time-micros -> TIME64_US (Int64)
    ref tucol = rb.column_at(2)
    assert_equal(tucol.arrow_type.type_id, ArrowType.TIME64_US.type_id, "time-micros type")
    var tua = tucol.as_primitive[DType.int64]()
    assert_equal(Int(tua.get(0)), 3600000000, "time-micros[0]")

    # timestamp-millis -> TIMESTAMP_MS (Int64)
    ref tsmcol = rb.column_at(3)
    assert_equal(tsmcol.arrow_type.type_id, ArrowType.TIMESTAMP_MS.type_id, "ts-millis type")
    var tsma = tsmcol.as_primitive[DType.int64]()
    assert_equal(Int(tsma.get(0)), 1700000000000, "ts-millis[0]")

    # timestamp-micros -> TIMESTAMP_US (Int64)
    ref tsucol = rb.column_at(4)
    assert_equal(tsucol.arrow_type.type_id, ArrowType.TIMESTAMP_US.type_id, "ts-micros type")
    var tsua = tsucol.as_primitive[DType.int64]()
    assert_equal(Int(tsua.get(0)), 1700000000000000, "ts-micros[0]")

    # decimal(9,2) over bytes -> DECIMAL128
    ref deccol = rb.column_at(5)
    assert_equal(deccol.arrow_type.type_id, ArrowType.DECIMAL128.type_id, "decimal type")
    var deca = deccol.as_decimal128()
    # 12345 -> low=12345, high=0
    assert_equal(Int(deca.get_low(0)), 12345, "dec[0] low")
    assert_equal(Int(deca.get_high(0)), 0, "dec[0] high")
    # -100 -> sign-extended: low = -100 (as Int64), high = -1
    assert_equal(Int(deca.get_low(1)), -100, "dec[1] low (neg)")
    assert_equal(Int(deca.get_high(1)), -1, "dec[1] high (sign-ext)")

    # uuid (string logical) -> BINARY (the type lattice maps uuid → BINARY)
    ref ucol = rb.column_at(6)
    var ua = ucol.as_string()
    assert_equal(ua.get(0), String("550e8400-e29b-41d4-a716-446655440000"), "uuid[0]")


def main() raises:
    test_logical_types()
    print("test_avro_logical_types_decode: ALL PASS")
