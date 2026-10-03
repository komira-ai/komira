# =============================================================================
# test_orc_lineitem_decode_roundtrip.mojo — full end-to-end ORC file decode.
# =============================================================================
#
# Acceptance: read a complete ORC file end to
# end and check equality vs the reference values.
#
# Fixture: a hand-emitted, complete (synthetic) ORC file for a lineitem-shaped
# struct<l_orderkey:bigint, l_partkey:int, l_comment:string>, single stripe,
# 4 rows, NONE codec. Building the whole file by hand exercises BOTH the ORC
# wire-format spec (PostScript / Footer / StripeFooter / stream layout / RLE
# encodings / PRESENT bitmap) AND the full read_orc_bytes decode path. This is
# stronger than a black-box fixture because it round-trips every layer.
#
# l_partkey row 2 is NULL (PRESENT stream exercises the validity bitmap).
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


# -----------------------------------------------------------------------------
# Protobuf encoders (same shape as the footer test).
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


# -----------------------------------------------------------------------------
# RLE / data-stream encoders.
# -----------------------------------------------------------------------------


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


# -----------------------------------------------------------------------------
# StripeFooter encoders.
# -----------------------------------------------------------------------------


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


# -----------------------------------------------------------------------------
# Build the whole file.
# -----------------------------------------------------------------------------


def _build_lineitem_file() -> List[UInt8]:
    # Column streams. 4 rows.
    # col 1 = l_orderkey (bigint): all present, values [1, 2, 3, 4].
    var ok_data = _rlev2_direct(_i64s(1, 2, 3, 4), 8, True)

    # col 2 = l_partkey (int): present [T, T, F, T], values for present rows
    # [100, 200, 400] (row 2 null).
    var pk_present_flags = List[Bool]()
    pk_present_flags.append(True)
    pk_present_flags.append(True)
    pk_present_flags.append(False)
    pk_present_flags.append(True)
    var pk_present = _present_literal(pk_present_flags)
    var pk_data = _rlev2_direct(_i64s(100, 200, 400), 12, True)

    # col 3 = l_comment (string DIRECT): ["foo","","bar","xy"].
    var cm_data = List[UInt8]()
    _str_bytes(String("foobarxy"), cm_data)  # foo + "" + bar + xy
    var cm_len = _rlev2_direct(_i64s(3, 0, 3, 2), 4, False)

    # Lay out streams in on-disk order; record lengths for the StripeFooter.
    # Order: col1 DATA, col2 PRESENT, col2 DATA, col3 DATA, col3 LENGTH.
    var data_region = List[UInt8]()
    for i in range(len(ok_data)):
        data_region.append(ok_data[i])
    for i in range(len(pk_present)):
        data_region.append(pk_present[i])
    for i in range(len(pk_data)):
        data_region.append(pk_data[i])
    for i in range(len(cm_data)):
        data_region.append(cm_data[i])
    for i in range(len(cm_len)):
        data_region.append(cm_len[i])

    # StripeFooter: streams + per-column encodings (column id 0 = root struct).
    var sf = List[UInt8]()
    _pb_message_field(1, _enc_stream(ORC_STREAM_DATA, 1, len(ok_data)), sf)
    _pb_message_field(1, _enc_stream(ORC_STREAM_PRESENT, 2, len(pk_present)), sf)
    _pb_message_field(1, _enc_stream(ORC_STREAM_DATA, 2, len(pk_data)), sf)
    _pb_message_field(1, _enc_stream(ORC_STREAM_DATA, 3, len(cm_data)), sf)
    _pb_message_field(1, _enc_stream(ORC_STREAM_LENGTH, 3, len(cm_len)), sf)
    # columns (field 2): one ColumnEncoding per schema node (0..3).
    _pb_message_field(2, _enc_encoding(ORC_ENCODING_DIRECT_V2, 0), sf)  # root
    _pb_message_field(2, _enc_encoding(ORC_ENCODING_DIRECT_V2, 0), sf)  # ok
    _pb_message_field(2, _enc_encoding(ORC_ENCODING_DIRECT_V2, 0), sf)  # pk
    _pb_message_field(2, _enc_encoding(ORC_ENCODING_DIRECT_V2, 0), sf)  # cm

    # The schema type tree (shared by the footer build below).
    var root = List[UInt8]()
    _pb_varint_field(1, UInt64(ORC_KIND_STRUCT), root)
    _pb_varint_field(2, 1, root)
    _pb_varint_field(2, 2, root)
    _pb_varint_field(2, 3, root)
    _pb_string_field(3, String("l_orderkey"), root)
    _pb_string_field(3, String("l_partkey"), root)
    _pb_string_field(3, String("l_comment"), root)

    # Stripe layout. The leading magic ("ORC") is 3 bytes; the stripe begins
    # immediately after at offset 3.
    var stripe_offset = 3
    var index_length = 0
    var data_length = len(data_region)
    var sf_length = len(sf)

    # Footer with the stripe directory + schema types.
    var footer2 = List[UInt8]()
    _pb_varint_field(1, 3, footer2)
    _pb_varint_field(2, UInt64(data_length + sf_length), footer2)
    var stripe_entry = List[UInt8]()
    _pb_varint_field(1, UInt64(stripe_offset), stripe_entry)
    _pb_varint_field(2, UInt64(index_length), stripe_entry)
    _pb_varint_field(3, UInt64(data_length), stripe_entry)
    _pb_varint_field(4, UInt64(sf_length), stripe_entry)
    _pb_varint_field(5, 4, stripe_entry)  # numberOfRows
    _pb_message_field(3, stripe_entry, footer2)
    # types again.
    _pb_message_field(4, root, footer2)
    _pb_message_field(4, _enc_type_leaf(ORC_KIND_LONG), footer2)
    _pb_message_field(4, _enc_type_leaf(ORC_KIND_INT), footer2)
    _pb_message_field(4, _enc_type_leaf(ORC_KIND_STRING), footer2)
    _pb_varint_field(6, 4, footer2)

    # PostScript.
    var ps = List[UInt8]()
    _pb_varint_field(1, UInt64(len(footer2)), ps)  # footerLength
    _pb_varint_field(2, UInt64(ORC_COMPRESSION_NONE), ps)  # compression
    _pb_varint_field(3, 262144, ps)
    _pb_varint_field(5, 0, ps)  # metadataLength = 0
    _pb_string_field(8000, String("ORC"), ps)

    # Assemble: magic + data_region + sf + (metadata=0) + footer2 + ps + len.
    var f = List[UInt8]()
    f.append(UInt8(ord("O")))
    f.append(UInt8(ord("R")))
    f.append(UInt8(ord("C")))
    for i in range(len(data_region)):
        f.append(data_region[i])
    for i in range(len(sf)):
        f.append(sf[i])
    # metadata length 0 (no bytes).
    for i in range(len(footer2)):
        f.append(footer2[i])
    for i in range(len(ps)):
        f.append(ps[i])
    f.append(UInt8(len(ps)))
    return f^


# -----------------------------------------------------------------------------
# Tests.
# -----------------------------------------------------------------------------


def test_lineitem_roundtrip() raises:
    var file_bytes = _build_lineitem_file()
    var rb = read_orc_bytes(Span(file_bytes))

    assert_equal(rb.num_rows(), 4, "4 rows")
    assert_equal(rb.num_columns(), 3, "3 columns")

    # l_orderkey (bigint), no nulls.
    ref ok = rb.column_at(0)
    var oka = ok.as_primitive[DType.int64]()
    assert_equal(ok.null_count(), 0, "orderkey no nulls")
    assert_equal(Int(oka.get(0)), 1, "orderkey[0]")
    assert_equal(Int(oka.get(1)), 2, "orderkey[1]")
    assert_equal(Int(oka.get(3)), 4, "orderkey[3]")

    # l_partkey (int), row 2 null.
    ref pk = rb.column_at(1)
    var pka = pk.as_primitive[DType.int32]()
    assert_equal(pk.null_count(), 1, "partkey 1 null")
    assert_equal(Int(pka.get(0)), 100, "partkey[0]")
    assert_equal(Int(pka.get(1)), 200, "partkey[1]")
    assert_true(pka.is_null(2), "partkey[2] null")
    assert_equal(Int(pka.get(3)), 400, "partkey[3]")

    # l_comment (string DIRECT).
    ref cm = rb.column_at(2)
    var cma = cm.as_string()
    assert_equal(cma.get(0), String("foo"), "comment[0]")
    assert_equal(cma.get(1), String(""), "comment[1]")
    assert_equal(cma.get(2), String("bar"), "comment[2]")
    assert_equal(cma.get(3), String("xy"), "comment[3]")


def main() raises:
    test_lineitem_roundtrip()
    print("test_orc_lineitem_decode_roundtrip: ALL PASS")
