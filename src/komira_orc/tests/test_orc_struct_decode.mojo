# =============================================================================
# test_orc_struct_decode.mojo — ORC nested STRUCT -> Arrow StructArray.
# =============================================================================
#
# Acceptance: `test_orc_struct_decode`.
#
# Fixture (hand-emitted, NONE codec, single stripe, 3 rows):
#   struct<id:bigint, info:struct<a:int, b:string>>
# The `info` column is a NESTED struct with two children. Exercises the
# recursive descent: top-level struct -> `info` struct -> primitive leaves.
# Row 1's `info` is NULL (struct-level PRESENT bitmap), but ORC struct children
# still carry all 3 rows' values (the child columns are NOT shortened).
# =============================================================================

from std.testing import assert_equal, assert_true

from komira_orc import (
    read_orc_bytes,
    ORC_COMPRESSION_NONE,
    ORC_KIND_STRUCT,
    ORC_KIND_LONG,
    ORC_KIND_INT,
    ORC_KIND_STRING,
    ORC_STREAM_PRESENT,
    ORC_STREAM_DATA,
    ORC_STREAM_LENGTH,
    ORC_ENCODING_DIRECT_V2,
    PB_WIRE_VARINT,
    PB_WIRE_LEN,
)
from komira_core.arrow.arrow_types import ArrowType


# -----------------------------------------------------------------------------
# Protobuf + RLE encoders (same shape as the other fixture tests).
# -----------------------------------------------------------------------------


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


def _present_literal(flags: List[Bool]) -> List[UInt8]:
    var n_bytes = (len(flags) + 7) // 8
    var out = List[UInt8]()
    out.append(UInt8(256 - n_bytes))
    for bi in range(n_bytes):
        var byte: Int = 0
        for k in range(8):
            var idx = bi * 8 + k
            var present = idx < len(flags) and flags[idx]
            byte = (byte << 1) | (1 if present else 0)
        out.append(UInt8(byte))
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


def _bl(*vals: Bool) -> List[Bool]:
    var out = List[Bool]()
    for i in range(len(vals)):
        out.append(vals[i])
    return out^


# -----------------------------------------------------------------------------
# Build a struct<id:bigint, info:struct<a:int, b:string>> file, 3 rows.
#
# Schema node ids (pre-order flat list):
#   0 = root struct (id, info)
#   1 = id (bigint)
#   2 = info (struct<a, b>)
#   3 = a (int)
#   4 = b (string)
#
# Rows: id = [10, 20, 30]; info present = [T, F, T] (row 1 NULL).
# info.a = [1, 2, 3] (children carry all 3 rows even though info[1] is null).
# info.b = ["x", "y", "z"].
# -----------------------------------------------------------------------------


def _build_struct_file() -> List[UInt8]:
    var id_data = _rlev2_direct(_i64s(10, 20, 30), 8, True)

    var info_present = _present_literal(_bl(True, False, True))

    var a_data = _rlev2_direct(_i64s(1, 2, 3), 4, True)

    var b_data = List[UInt8]()
    _str_bytes(String("xyz"), b_data)
    var b_len = _rlev2_direct(_i64s(1, 1, 1), 4, False)

    # On-disk stream order: id DATA, info PRESENT, a DATA, b DATA, b LENGTH.
    var data_region = List[UInt8]()
    for i in range(len(id_data)):
        data_region.append(id_data[i])
    for i in range(len(info_present)):
        data_region.append(info_present[i])
    for i in range(len(a_data)):
        data_region.append(a_data[i])
    for i in range(len(b_data)):
        data_region.append(b_data[i])
    for i in range(len(b_len)):
        data_region.append(b_len[i])

    var sf = List[UInt8]()
    _pb_message_field(1, _enc_stream(ORC_STREAM_DATA, 1, len(id_data)), sf)
    _pb_message_field(1, _enc_stream(ORC_STREAM_PRESENT, 2, len(info_present)), sf)
    _pb_message_field(1, _enc_stream(ORC_STREAM_DATA, 3, len(a_data)), sf)
    _pb_message_field(1, _enc_stream(ORC_STREAM_DATA, 4, len(b_data)), sf)
    _pb_message_field(1, _enc_stream(ORC_STREAM_LENGTH, 4, len(b_len)), sf)
    # One ColumnEncoding per node 0..4.
    for _i in range(5):
        _pb_message_field(2, _enc_encoding(ORC_ENCODING_DIRECT_V2, 0), sf)

    # Schema type tree.
    var root = List[UInt8]()
    _pb_varint_field(1, UInt64(ORC_KIND_STRUCT), root)
    _pb_varint_field(2, 1, root)
    _pb_varint_field(2, 2, root)
    _pb_string_field(3, String("id"), root)
    _pb_string_field(3, String("info"), root)

    var info_t = List[UInt8]()
    _pb_varint_field(1, UInt64(ORC_KIND_STRUCT), info_t)
    _pb_varint_field(2, 3, info_t)
    _pb_varint_field(2, 4, info_t)
    _pb_string_field(3, String("a"), info_t)
    _pb_string_field(3, String("b"), info_t)

    var stripe_offset = 3
    var index_length = 0
    var data_length = len(data_region)
    var sf_length = len(sf)

    var footer2 = List[UInt8]()
    _pb_varint_field(1, 3, footer2)
    _pb_varint_field(2, UInt64(data_length + sf_length), footer2)
    var stripe_entry = List[UInt8]()
    _pb_varint_field(1, UInt64(stripe_offset), stripe_entry)
    _pb_varint_field(2, UInt64(index_length), stripe_entry)
    _pb_varint_field(3, UInt64(data_length), stripe_entry)
    _pb_varint_field(4, UInt64(sf_length), stripe_entry)
    _pb_varint_field(5, 3, stripe_entry)
    _pb_message_field(3, stripe_entry, footer2)
    _pb_message_field(4, root, footer2)
    _pb_message_field(4, _enc_type_leaf(ORC_KIND_LONG), footer2)
    _pb_message_field(4, info_t, footer2)
    _pb_message_field(4, _enc_type_leaf(ORC_KIND_INT), footer2)
    _pb_message_field(4, _enc_type_leaf(ORC_KIND_STRING), footer2)
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


def test_struct_decode() raises:
    var file_bytes = _build_struct_file()
    var rb = read_orc_bytes(Span(file_bytes))

    assert_equal(rb.num_rows(), 3, "3 rows")
    assert_equal(rb.num_columns(), 2, "2 top-level cols (id, info)")

    # id (bigint).
    ref id_col = rb.column_at(0)
    var ida = id_col.as_primitive[DType.int64]()
    assert_equal(Int(ida.get(0)), 10, "id[0]")
    assert_equal(Int(ida.get(2)), 30, "id[2]")

    # info (struct<a:int, b:string>), row 1 null.
    ref info_col = rb.column_at(1)
    assert_equal(info_col.arrow_type, ArrowType.STRUCT, "info is STRUCT")
    var sa = info_col.as_struct()
    assert_equal(len(sa), 3, "struct has 3 rows")
    assert_equal(sa.num_fields(), 2, "struct has 2 fields")
    assert_equal(sa.field_name(0), String("a"), "field 0 = a")
    assert_equal(sa.field_name(1), String("b"), "field 1 = b")
    assert_true(sa.is_null(1), "info[1] is null")
    assert_true(not sa.is_null(0), "info[0] not null")
    assert_true(not sa.is_null(2), "info[2] not null")

    # Child a (int) — carries all 3 rows.
    ref a_col = sa.child_at(0)
    var aa = a_col.as_primitive[DType.int32]()
    assert_equal(Int(aa.get(0)), 1, "info.a[0]")
    assert_equal(Int(aa.get(2)), 3, "info.a[2]")

    # Child b (string).
    ref b_col = sa.child_at(1)
    var ba = b_col.as_string()
    assert_equal(ba.get(0), String("x"), "info.b[0]")
    assert_equal(ba.get(2), String("z"), "info.b[2]")


def main() raises:
    test_struct_decode()
    print("test_orc_struct_decode: ALL PASS")
