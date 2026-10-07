# =============================================================================
# test_orc_map_decode.mojo — ORC MAP -> Arrow MapArray.
# =============================================================================
#
# Acceptance: `test_orc_map_decode` — MAP -> MapArray.
#
# Fixture (hand-emitted, NONE codec, single stripe, 3 rows):
#   struct<id:bigint, m:map<string,int>>
# m = [ {"a":1,"b":2}, {}, {"c":3} ] -> per-element lengths [2, 0, 1],
# keys = ["a","b","c"] (DIRECT string), values = [1,2,3] (int).
# Schema node ids: 0=root, 1=id, 2=m(map), 3=string(key), 4=int(value).
# =============================================================================

from std.testing import assert_equal

from komira_orc import (
    read_orc_bytes,
    ORC_COMPRESSION_NONE,
    ORC_KIND_STRUCT,
    ORC_KIND_LONG,
    ORC_KIND_INT,
    ORC_KIND_STRING,
    ORC_KIND_MAP,
    ORC_STREAM_DATA,
    ORC_STREAM_LENGTH,
    ORC_ENCODING_DIRECT_V2,
    PB_WIRE_VARINT,
    PB_WIRE_LEN,
)
from komira_arrow.arrow_types import ArrowType


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


def _str_bytes(s: String, mut out: List[UInt8]):
    var b = s.as_bytes()
    for i in range(len(b)):
        out.append(b[i])


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


def _build_map_file() -> List[UInt8]:
    var id_data = _rlev2_direct(_i64s(7, 8, 9), 8, True)
    # m LENGTH (unsigned): [2, 0, 1].
    var m_len = _rlev2_direct(_i64s(2, 0, 1), 4, False)
    # key DATA (string DIRECT): "abc" with per-entry LENGTH [1,1,1].
    var key_data = List[UInt8]()
    _str_bytes(String("abc"), key_data)
    var key_len = _rlev2_direct(_i64s(1, 1, 1), 4, False)
    # value DATA (int): [1, 2, 3].
    var val_data = _rlev2_direct(_i64s(1, 2, 3), 4, True)

    # On-disk order: id DATA(1), m LENGTH(2), key DATA(3), key LENGTH(3),
    # value DATA(4).
    var data_region = List[UInt8]()
    for i in range(len(id_data)):
        data_region.append(id_data[i])
    for i in range(len(m_len)):
        data_region.append(m_len[i])
    for i in range(len(key_data)):
        data_region.append(key_data[i])
    for i in range(len(key_len)):
        data_region.append(key_len[i])
    for i in range(len(val_data)):
        data_region.append(val_data[i])

    var sf = List[UInt8]()
    _pb_message_field(1, _enc_stream(ORC_STREAM_DATA, 1, len(id_data)), sf)
    _pb_message_field(1, _enc_stream(ORC_STREAM_LENGTH, 2, len(m_len)), sf)
    _pb_message_field(1, _enc_stream(ORC_STREAM_DATA, 3, len(key_data)), sf)
    _pb_message_field(1, _enc_stream(ORC_STREAM_LENGTH, 3, len(key_len)), sf)
    _pb_message_field(1, _enc_stream(ORC_STREAM_DATA, 4, len(val_data)), sf)
    for _i in range(5):
        _pb_message_field(2, _enc_encoding(ORC_ENCODING_DIRECT_V2, 0), sf)

    var root = List[UInt8]()
    _pb_varint_field(1, UInt64(ORC_KIND_STRUCT), root)
    _pb_varint_field(2, 1, root)
    _pb_varint_field(2, 2, root)
    _pb_string_field(3, String("id"), root)
    _pb_string_field(3, String("m"), root)

    var map_t = List[UInt8]()
    _pb_varint_field(1, UInt64(ORC_KIND_MAP), map_t)
    _pb_varint_field(2, 3, map_t)
    _pb_varint_field(2, 4, map_t)

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
    _pb_varint_field(5, 3, stripe_entry)
    _pb_message_field(3, stripe_entry, footer2)
    _pb_message_field(4, root, footer2)
    _pb_message_field(4, _enc_type_leaf(ORC_KIND_LONG), footer2)
    _pb_message_field(4, map_t, footer2)
    _pb_message_field(4, _enc_type_leaf(ORC_KIND_STRING), footer2)
    _pb_message_field(4, _enc_type_leaf(ORC_KIND_INT), footer2)
    _pb_varint_field(6, 3, footer2)

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


def test_map_decode() raises:
    var file_bytes = _build_map_file()
    var rb = read_orc_bytes(Span(file_bytes))

    assert_equal(rb.num_rows(), 3, "3 rows")
    assert_equal(rb.num_columns(), 2, "2 cols (id, m)")

    ref m_col = rb.column_at(1)
    assert_equal(m_col.arrow_type, ArrowType.MAP, "m is MAP")
    var ma = m_col.as_map()
    assert_equal(len(ma), 3, "3 map elements")

    # Offsets via cumulative LENGTH: [0,2,2,3].
    assert_equal(ma.get_length(0), 2, "map[0] has 2 entries")
    assert_equal(ma.get_length(1), 0, "map[1] empty")
    assert_equal(ma.get_length(2), 1, "map[2] has 1 entry")
    assert_equal(ma.total_entries(), 3, "3 entries total")

    # keys = ["a","b","c"], values = [1,2,3].
    var keys = ma.keys.as_string()
    assert_equal(keys.get(0), String("a"), "key[0]")
    assert_equal(keys.get(1), String("b"), "key[1]")
    assert_equal(keys.get(2), String("c"), "key[2]")

    var values = ma.values.as_primitive[DType.int32]()
    assert_equal(Int(values.get(0)), 1, "value[0]")
    assert_equal(Int(values.get(2)), 3, "value[2]")


def main() raises:
    test_map_decode()
    print("test_orc_map_decode: ALL PASS")
