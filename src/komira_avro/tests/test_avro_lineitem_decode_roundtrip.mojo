# =============================================================================
# test_avro_lineitem_decode_roundtrip.mojo — lineitem-shaped read.
# =============================================================================
#
# Acceptance:
#   test_lineitem_sf1_decode_roundtrip — full read of an Avro lineitem-shaped
#   fixture → equality vs the reference values we encoded. fastavro is
#   unavailable, so the fixture is hand-emitted as the byte-exact inverse of
#   the decoder (the decoder-test pattern), spanning MULTIPLE OCF
#   blocks to exercise cross-block column accumulation.
#
# Schema is a TPC-H lineitem subset (mixed primitive + decimal + date +
# nullable string), enough to exercise the column-direct dispatch over a
# representative wide-row shape.
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


# TPC-H lineitem subset:
#   l_orderkey      long
#   l_partkey       int
#   l_quantity      decimal(15,2) over bytes
#   l_extendedprice double
#   l_shipdate      int + date logical
#   l_comment       union[null, string]  (nullable)
comptime _SCHEMA_LINEITEM = String(
    '{"type":"record","name":"LineItem","fields":['
    '{"name":"l_orderkey","type":"long"},'
    '{"name":"l_partkey","type":"int"},'
    '{"name":"l_quantity","type":{"type":"bytes","logicalType":"decimal",'
    '"precision":15,"scale":2}},'
    '{"name":"l_extendedprice","type":"double"},'
    '{"name":"l_shipdate","type":{"type":"int","logicalType":"date"}},'
    '{"name":"l_comment","type":["null","string"]}]}'
)


def _enc_dec_2byte(unscaled: Int, mut out: List[UInt8]):
    """Encode a small non-negative unscaled decimal as a 2-byte BE field."""
    var be = List[UInt8]()
    be.append(UInt8((unscaled >> 8) & 0xFF))
    be.append(UInt8(unscaled & 0xFF))
    _enc_bytes(be, out)


def _enc_row(
    mut p: List[UInt8],
    orderkey: Int64,
    partkey: Int32,
    qty_unscaled: Int,
    price: Float64,
    shipdate: Int32,
    comment: String,
    comment_null: Bool,
):
    from std.memory import bitcast

    _enc_long(orderkey, p)
    _enc_long(Int64(partkey), p)
    _enc_dec_2byte(qty_unscaled, p)
    var bits = bitcast[DType.uint64, 1](price)
    for i in range(8):
        p.append(UInt8((bits >> UInt64(8 * i)) & 0xFF))
    _enc_long(Int64(shipdate), p)
    if comment_null:
        _enc_long(Int64(0), p)  # union[null,string]: tag 0 == null
    else:
        _enc_long(Int64(1), p)  # tag 1 == string branch
        _enc_str(comment, p)


def test_lineitem_roundtrip_multiblock() raises:
    """A 5-row lineitem fixture across 2 blocks decodes to the encoded values."""
    var buf = List[UInt8]()
    _make_header(_SCHEMA_LINEITEM, buf)

    # Block 1: rows 0-2
    var b1 = List[UInt8]()
    _enc_row(b1, Int64(1), Int32(155), 1700, Float64(21168.23), Int32(9000), String("late delivery"), False)
    _enc_row(b1, Int64(2), Int32(67310), 3600, Float64(45983.16), Int32(9100), String(""), True)
    _enc_row(b1, Int64(3), Int32(63700), 800, Float64(13309.60), Int32(9200), String("urgent"), False)
    _append_block(buf, Int64(3), b1)

    # Block 2: rows 3-4
    var b2 = List[UInt8]()
    _enc_row(b2, Int64(4), Int32(2132), 2800, Float64(28955.64), Int32(9300), String("packed"), False)
    _enc_row(b2, Int64(5), Int32(24027), 2400, Float64(22824.48), Int32(9400), String(""), True)
    _append_block(buf, Int64(2), b2)

    var rb = read_avro_bytes(Span(buf))
    assert_equal(rb.num_rows(), 5, "5 rows across 2 blocks")
    assert_equal(rb.num_columns(), 6, "6 columns")

    # l_orderkey (long)
    ref ok = rb.column_at(0)
    var oka = ok.as_primitive[DType.int64]()
    assert_equal(Int(oka.get(0)), 1, "orderkey[0]")
    assert_equal(Int(oka.get(4)), 5, "orderkey[4] (block 2)")

    # l_partkey (int)
    ref pk = rb.column_at(1)
    var pka = pk.as_primitive[DType.int32]()
    assert_equal(Int(pka.get(1)), 67310, "partkey[1]")
    assert_equal(Int(pka.get(3)), 2132, "partkey[3] (block 2)")

    # l_quantity (decimal128(15,2))
    ref q = rb.column_at(2)
    assert_equal(q.arrow_type.type_id, ArrowType.DECIMAL128.type_id, "quantity decimal")
    var qa = q.as_decimal128()
    assert_equal(Int(qa.get_low(0)), 1700, "quantity[0] unscaled")
    assert_equal(Int(qa.get_low(4)), 2400, "quantity[4] (block 2)")

    # l_extendedprice (double)
    ref ep = rb.column_at(3)
    var epa = ep.as_primitive[DType.float64]()
    assert_true(epa.get(0) > 21168.2 and epa.get(0) < 21168.3, "price[0]")
    assert_true(epa.get(4) > 22824.4 and epa.get(4) < 22824.5, "price[4] (block 2)")

    # l_shipdate (date32)
    ref sd = rb.column_at(4)
    assert_equal(sd.arrow_type.type_id, ArrowType.DATE32.type_id, "shipdate date32")
    var sda = sd.as_primitive[DType.int32]()
    assert_equal(Int(sda.get(0)), 9000, "shipdate[0]")
    assert_equal(Int(sda.get(4)), 9400, "shipdate[4] (block 2)")

    # l_comment (nullable string)
    ref cm = rb.column_at(5)
    var cma = cm.as_string()
    assert_equal(cma.get(0), String("late delivery"), "comment[0]")
    assert_true(cma.is_null(1), "comment[1] null")
    assert_equal(cma.get(2), String("urgent"), "comment[2]")
    assert_equal(cma.get(3), String("packed"), "comment[3] (block 2)")
    assert_true(cma.is_null(4), "comment[4] null (block 2)")
    assert_equal(cm.null_count(), 2, "comment null_count == 2")


def main() raises:
    test_lineitem_roundtrip_multiblock()
    print("test_avro_lineitem_decode_roundtrip: ALL PASS")
