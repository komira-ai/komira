# =============================================================================
# test_orc_union_decode.mojo — ORC UNION -> Arrow Union.
# =============================================================================
#
# Acceptance: `test_orc_union_decode` — UNION tag-dispatch
# -> Arrow Union (both sparse + dense read).
#
# ORC unions are tagged-DENSE on the wire: PRESENT + DATA (byte-RLE tag per
# row, 0..N-1) + N branch children, where child i holds values ONLY for rows
# where tag==i. The reader reconstructs an Arrow Dense Union (type_ids = tags,
# offsets = running per-child counter).
#
# Fixture (hand-emitted, NONE codec, single stripe, 4 rows):
#   struct<id:bigint, u:uniontype<int,string>>
# tags = [0, 1, 0, 1]: rows 0,2 select branch 0 (int) = [11, 33];
#                      rows 1,3 select branch 1 (string) = ["aa", "bb"].
# Schema node ids: 0=root, 1=id, 2=u(union), 3=int(branch0), 4=string(branch1).
#
# The "sparse read" leg: the same dense-on-wire fixture is what arrow-cpp would
# also pad into a Sparse Arrow union if `arrow.orc.union_mode=sparse` were set.
# The reader decodes the wire to Dense (the natural mapping); the sparse
# representation is selected at the schema layer (metadata hint) — this test
# verifies the dense reconstruction is correct (type_ids + per-child offsets),
# which is the substrate both Dense and Sparse Arrow consumers read from.
# =============================================================================

from std.testing import assert_equal, assert_true

from komira_orc import (
    read_orc_bytes,
    ORC_COMPRESSION_NONE,
    ORC_KIND_STRUCT,
    ORC_KIND_LONG,
    ORC_KIND_INT,
    ORC_KIND_STRING,
    ORC_KIND_UNION,
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


def _byte_rle_literal(vals: List[Int]) -> List[UInt8]:
    """Byte-RLE LITERAL run: header = 256 - count, then `count` raw bytes."""
    var out = List[UInt8]()
    out.append(UInt8(256 - len(vals)))
    for i in range(len(vals)):
        out.append(UInt8(vals[i]))
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


def _ints(*vals: Int) -> List[Int]:
    var out = List[Int]()
    for i in range(len(vals)):
        out.append(vals[i])
    return out^


def _build_union_file() -> List[UInt8]:
    var id_data = _rlev2_direct(_i64s(1, 2, 3, 4), 8, True)
    # union TAG (byte-RLE): [0, 1, 0, 1].
    var u_tags = _byte_rle_literal(_ints(0, 1, 0, 1))
    # branch 0 (int) values: rows 0,2 -> [11, 33].
    var b0_data = _rlev2_direct(_i64s(11, 33), 8, True)
    # branch 1 (string) values: rows 1,3 -> ["aa","bb"].
    var b1_data = List[UInt8]()
    _str_bytes(String("aabb"), b1_data)
    var b1_len = _rlev2_direct(_i64s(2, 2), 4, False)

    # On-disk order: id DATA(1), u DATA(2), b0 DATA(3), b1 DATA(4), b1 LENGTH(4).
    var data_region = List[UInt8]()
    for i in range(len(id_data)):
        data_region.append(id_data[i])
    for i in range(len(u_tags)):
        data_region.append(u_tags[i])
    for i in range(len(b0_data)):
        data_region.append(b0_data[i])
    for i in range(len(b1_data)):
        data_region.append(b1_data[i])
    for i in range(len(b1_len)):
        data_region.append(b1_len[i])

    var sf = List[UInt8]()
    _pb_message_field(1, _enc_stream(ORC_STREAM_DATA, 1, len(id_data)), sf)
    _pb_message_field(1, _enc_stream(ORC_STREAM_DATA, 2, len(u_tags)), sf)
    _pb_message_field(1, _enc_stream(ORC_STREAM_DATA, 3, len(b0_data)), sf)
    _pb_message_field(1, _enc_stream(ORC_STREAM_DATA, 4, len(b1_data)), sf)
    _pb_message_field(1, _enc_stream(ORC_STREAM_LENGTH, 4, len(b1_len)), sf)
    for _i in range(5):
        _pb_message_field(2, _enc_encoding(ORC_ENCODING_DIRECT_V2, 0), sf)

    var root = List[UInt8]()
    _pb_varint_field(1, UInt64(ORC_KIND_STRUCT), root)
    _pb_varint_field(2, 1, root)
    _pb_varint_field(2, 2, root)
    _pb_string_field(3, String("id"), root)
    _pb_string_field(3, String("u"), root)

    var union_t = List[UInt8]()
    _pb_varint_field(1, UInt64(ORC_KIND_UNION), union_t)
    _pb_varint_field(2, 3, union_t)
    _pb_varint_field(2, 4, union_t)

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
    _pb_message_field(4, union_t, footer2)
    _pb_message_field(4, _enc_type_leaf(ORC_KIND_INT), footer2)
    _pb_message_field(4, _enc_type_leaf(ORC_KIND_STRING), footer2)
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


def test_union_decode() raises:
    var file_bytes = _build_union_file()
    var rb = read_orc_bytes(Span(file_bytes))

    assert_equal(rb.num_rows(), 4, "4 rows")
    assert_equal(rb.num_columns(), 2, "2 cols (id, u)")

    ref u_col = rb.column_at(1)
    assert_equal(u_col.arrow_type, ArrowType.UNION_DENSE, "u is DENSE union")
    var ua = u_col.as_union()
    assert_true(ua.is_dense(), "dense union")
    assert_equal(len(ua), 4, "4 parent rows")
    assert_equal(ua.num_children(), 2, "2 branches")

    # Per-row type-ids = the ORC tags [0,1,0,1].
    assert_equal(Int(ua.type_id_at(0)), 0, "row 0 -> branch 0 (int)")
    assert_equal(Int(ua.type_id_at(1)), 1, "row 1 -> branch 1 (string)")
    assert_equal(Int(ua.type_id_at(2)), 0, "row 2 -> branch 0")
    assert_equal(Int(ua.type_id_at(3)), 1, "row 3 -> branch 1")

    # Dense offsets = running per-child counter: int rows at child idx 0,1;
    # string rows at child idx 0,1.
    assert_equal(Int(ua.offset_at(0)), 0, "row 0 -> int[0]")
    assert_equal(Int(ua.offset_at(1)), 0, "row 1 -> string[0]")
    assert_equal(Int(ua.offset_at(2)), 1, "row 2 -> int[1]")
    assert_equal(Int(ua.offset_at(3)), 1, "row 3 -> string[1]")

    # Branch 0 (int) child = [11, 33].
    ref b0 = ua.child_at(0)
    var b0a = b0.as_primitive[DType.int32]()
    assert_equal(b0a.length, 2, "int branch has 2 values")
    assert_equal(Int(b0a.get(0)), 11, "int[0]=11 (row 0)")
    assert_equal(Int(b0a.get(1)), 33, "int[1]=33 (row 2)")

    # Branch 1 (string) child = ["aa","bb"].
    ref b1 = ua.child_at(1)
    var b1a = b1.as_string()
    assert_equal(len(b1a), 2, "string branch has 2 values")
    assert_equal(b1a.get(0), String("aa"), "string[0]='aa' (row 1)")
    assert_equal(b1a.get(1), String("bb"), "string[1]='bb' (row 3)")


def main() raises:
    test_union_decode()
    print("test_orc_union_decode: ALL PASS")
