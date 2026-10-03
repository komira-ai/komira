# =============================================================================
# test_orc_list_decode.mojo — ORC LIST -> Arrow ListArray.
# =============================================================================
#
# Acceptance: `test_orc_list_decode` — LIST -> ListArray,
# offsets correct via cumulative LENGTH accumulation.
#
# Fixture (hand-emitted, NONE codec, single stripe, 4 rows):
#   struct<id:bigint, vals:array<int>>
# vals = [ [1,2], [], [3,4,5], [6] ] -> per-element lengths [2, 0, 3, 1],
# prefix-sum offsets [0, 2, 2, 5, 6], child = [1,2,3,4,5,6].
# Schema node ids: 0=root, 1=id(bigint), 2=vals(list), 3=int(child).
# =============================================================================

from std.testing import assert_equal

from komira_orc import (
    read_orc_bytes,
    ORC_COMPRESSION_NONE,
    ORC_KIND_STRUCT,
    ORC_KIND_LONG,
    ORC_KIND_INT,
    ORC_KIND_LIST,
    ORC_STREAM_DATA,
    ORC_STREAM_LENGTH,
    ORC_ENCODING_DIRECT_V2,
    PB_WIRE_VARINT,
    PB_WIRE_LEN,
)
from komira_core.arrow.arrow_types import ArrowType


def _pb_varint(n: UInt64, mut out: List[UInt8]):
    var v = n
    while True:
        var b = UInt8(v & 0x7F)
        v >>= 7
        if v != 0:
            out.append(b | 0x80)
        else:
            out.append(b)
            break


def _pb_tag(field_number: Int, wire_type: Int, mut out: List[UInt8]):
    _pb_varint(UInt64((field_number << 3) | wire_type), out)


def _pb_varint_field(field_number: Int, value: UInt64, mut out: List[UInt8]):
    _pb_tag(field_number, PB_WIRE_VARINT, out)
    _pb_varint(value, out)


def _pb_string_field(field_number: Int, s: String, mut out: List[UInt8]):
    _pb_tag(field_number, PB_WIRE_LEN, out)
    var b = s.as_bytes()
    _pb_varint(UInt64(len(b)), out)
    for i in range(len(b)):
        out.append(b[i])


def _pb_message_field(field_number: Int, body: List[UInt8], mut out: List[UInt8]):
    _pb_tag(field_number, PB_WIRE_LEN, out)
    _pb_varint(UInt64(len(body)), out)
    for i in range(len(body)):
        out.append(body[i])


def _i64s(*vals: Int) -> List[Int64]:
    var out = List[Int64]()
    for i in range(len(vals)):
        out.append(Int64(vals[i]))
    return out^


def _zigzag_encode(v: Int64) -> UInt64:
    return UInt64((v << 1) ^ (v >> 63))


def _pack_bits_be(values: List[Int64], bits: Int, mut out: List[UInt8]):
    var cur: UInt64 = 0
    var filled: Int = 0
    for vi in range(len(values)):
        var v = UInt64(values[vi]) & ((UInt64(1) << UInt64(bits)) - 1)
        var need = bits
        while need > 0:
            var space = 8 - filled
            var take = need if need < space else space
            var shift = need - take
            var chunk = (v >> UInt64(shift)) & ((UInt64(1) << UInt64(take)) - 1)
            cur = (cur << UInt64(take)) | chunk
            filled += take
            need -= take
            if filled == 8:
                out.append(UInt8(cur & 0xFF))
                cur = 0
                filled = 0
    if filled > 0:
        cur = cur << UInt64(8 - filled)
        out.append(UInt8(cur & 0xFF))


def _rlev2_direct(values: List[Int64], bits: Int, signed: Bool) -> List[UInt8]:
    var packed = List[Int64]()
    for i in range(len(values)):
        if signed:
            packed.append(Int64(_zigzag_encode(values[i])))
        else:
            packed.append(values[i])
    var out = List[UInt8]()
    var enc_w = bits - 1
    var L = len(values) - 1
    var b0 = (1 << 6) | (enc_w << 1) | ((L >> 8) & 1)
    out.append(UInt8(b0))
    out.append(UInt8(L & 0xFF))
    _pack_bits_be(packed, bits, out)
    return out^


def _enc_stream(kind: Int, column: Int, length: Int) -> List[UInt8]:
    var b = List[UInt8]()
    _pb_varint_field(1, UInt64(kind), b)
    _pb_varint_field(2, UInt64(column), b)
    _pb_varint_field(3, UInt64(length), b)
    return b^


def _enc_encoding(kind: Int, dict_size: Int) -> List[UInt8]:
    var b = List[UInt8]()
    _pb_varint_field(1, UInt64(kind), b)
    if dict_size > 0:
        _pb_varint_field(2, UInt64(dict_size), b)
    return b^


def _enc_type_leaf(kind: Int) -> List[UInt8]:
    var b = List[UInt8]()
    _pb_varint_field(1, UInt64(kind), b)
    return b^


def _build_list_file() -> List[UInt8]:
    var id_data = _rlev2_direct(_i64s(100, 200, 300, 400), 12, True)
    # vals LENGTH (unsigned): per-element lengths [2, 0, 3, 1].
    var vals_len = _rlev2_direct(_i64s(2, 0, 3, 1), 4, False)
    # child int values: [1,2,3,4,5,6].
    var child_data = _rlev2_direct(_i64s(1, 2, 3, 4, 5, 6), 4, True)

    # On-disk order: id DATA(1), vals LENGTH(2), child DATA(3).
    var data_region = List[UInt8]()
    for i in range(len(id_data)):
        data_region.append(id_data[i])
    for i in range(len(vals_len)):
        data_region.append(vals_len[i])
    for i in range(len(child_data)):
        data_region.append(child_data[i])

    var sf = List[UInt8]()
    _pb_message_field(1, _enc_stream(ORC_STREAM_DATA, 1, len(id_data)), sf)
    _pb_message_field(1, _enc_stream(ORC_STREAM_LENGTH, 2, len(vals_len)), sf)
    _pb_message_field(1, _enc_stream(ORC_STREAM_DATA, 3, len(child_data)), sf)
    for _i in range(4):
        _pb_message_field(2, _enc_encoding(ORC_ENCODING_DIRECT_V2, 0), sf)

    var root = List[UInt8]()
    _pb_varint_field(1, UInt64(ORC_KIND_STRUCT), root)
    _pb_varint_field(2, 1, root)
    _pb_varint_field(2, 2, root)
    _pb_string_field(3, String("id"), root)
    _pb_string_field(3, String("vals"), root)

    var list_t = List[UInt8]()
    _pb_varint_field(1, UInt64(ORC_KIND_LIST), list_t)
    _pb_varint_field(2, 3, list_t)

    var data_length = len(data_region)
    var sf_length = len(sf)

    var footer2 = List[UInt8]()
    _pb_varint_field(1, 3, footer2)
    _pb_varint_field(2, UInt64(data_length + sf_length), footer2)
    var stripe_entry = List[UInt8]()
    _pb_varint_field(1, 3, stripe_entry)
    _pb_varint_field(2, 0, stripe_entry)
    _pb_varint_field(3, UInt64(data_length), stripe_entry)
    _pb_varint_field(4, UInt64(sf_length), stripe_entry)
    _pb_varint_field(5, 4, stripe_entry)
    _pb_message_field(3, stripe_entry, footer2)
    _pb_message_field(4, root, footer2)
    _pb_message_field(4, _enc_type_leaf(ORC_KIND_LONG), footer2)
    _pb_message_field(4, list_t, footer2)
    _pb_message_field(4, _enc_type_leaf(ORC_KIND_INT), footer2)
    _pb_varint_field(6, 4, footer2)

    var ps = List[UInt8]()
    _pb_varint_field(1, UInt64(len(footer2)), ps)
    _pb_varint_field(2, UInt64(ORC_COMPRESSION_NONE), ps)
    _pb_varint_field(3, 262144, ps)
    _pb_varint_field(5, 0, ps)
    _pb_string_field(8000, String("ORC"), ps)

    var f = List[UInt8]()
    f.append(UInt8(ord("O")))
    f.append(UInt8(ord("R")))
    f.append(UInt8(ord("C")))
    for i in range(len(data_region)):
        f.append(data_region[i])
    for i in range(len(sf)):
        f.append(sf[i])
    for i in range(len(footer2)):
        f.append(footer2[i])
    for i in range(len(ps)):
        f.append(ps[i])
    f.append(UInt8(len(ps)))
    return f^


def test_list_decode() raises:
    var file_bytes = _build_list_file()
    var rb = read_orc_bytes(Span(file_bytes))

    assert_equal(rb.num_rows(), 4, "4 rows")
    assert_equal(rb.num_columns(), 2, "2 cols (id, vals)")

    ref vals_col = rb.column_at(1)
    assert_equal(vals_col.arrow_type, ArrowType.LIST, "vals is LIST")
    var la = vals_col.as_list()
    assert_equal(len(la), 4, "4 list elements")

    # Offsets via cumulative LENGTH accumulation: [0,2,2,5,6].
    assert_equal(la.get_offset(0), 0, "offset[0]")
    assert_equal(la.get_length(0), 2, "len[0]=2")
    assert_equal(la.get_length(1), 0, "len[1]=0 (empty)")
    assert_equal(la.get_length(2), 3, "len[2]=3")
    assert_equal(la.get_length(3), 1, "len[3]=1")
    assert_equal(la.total_values(), 6, "6 child values total")

    # Child int values [1..6].
    var child = la.child.as_primitive[DType.int32]()
    assert_equal(Int(child.get(0)), 1, "child[0]")
    assert_equal(Int(child.get(2)), 3, "child[2] (start of list 2)")
    assert_equal(Int(child.get(5)), 6, "child[5]")


def main() raises:
    test_list_decode()
    print("test_orc_list_decode: ALL PASS")
