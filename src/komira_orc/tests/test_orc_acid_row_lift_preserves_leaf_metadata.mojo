# =============================================================================
# test_orc_acid_row_lift_preserves_leaf_metadata.mojo — regression-guard:
# the ACID row.* lift MUST NOT strip per-leaf arrow.orc.* metadata.
# =============================================================================
#
# Acceptance: `test_orc_acid_row_lift_preserves_leaf_metadata`. Readers of
# the lifted columns depend on per-leaf arrow.orc.* metadata surviving the
# row.* structural lift. This guards that the default ACID
# suppress (which reparents row's children to the top level) keeps each lifted
# leaf's arrow.orc.* metadata intact — the lift is a pure reparent keyed on
# the SAME schema node index, never a metadata strip.
#
# Fixture (hand-emitted, NONE codec, single stripe, 2 rows):
#   struct<operation:int, originalTransaction:bigint, bucket:int, rowId:bigint,
#          currentTransaction:bigint,
#          row:struct<sku:varchar(32), qty:int>>
# After default lift the top-level `sku` column MUST carry
# arrow.orc.varchar_max_length = "32".
# Schema node ids: 0=root, 1..5=ACID metadata, 6=row, 7=sku(varchar), 8=qty(int).
# =============================================================================

from std.testing import assert_equal

from komira_orc import (
    read_orc_bytes,
    ORC_COMPRESSION_NONE,
    ORC_KIND_STRUCT,
    ORC_KIND_LONG,
    ORC_KIND_INT,
    ORC_KIND_VARCHAR,
    ORC_STREAM_DATA,
    ORC_STREAM_LENGTH,
    ORC_ENCODING_DIRECT_V2,
    ARROW_ORC_VARCHAR_MAX_LENGTH,
    PB_WIRE_VARINT,
    PB_WIRE_LEN,
)


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


def _enc_varchar(maximum_length: Int) -> List[UInt8]:
    var b = List[UInt8]()
    _pb_varint_field(1, UInt64(ORC_KIND_VARCHAR), b)
    _pb_varint_field(4, UInt64(maximum_length), b)
    return b^


def _app(src: List[UInt8], mut dst: List[UInt8]):
    for i in range(len(src)):
        dst.append(src[i])


def _build_acid_varchar_file() -> List[UInt8]:
    var op_data = _rlev2_direct(_i64s(0, 0), 4, True)
    var otxn_data = _rlev2_direct(_i64s(100, 100), 8, True)
    var bucket_data = _rlev2_direct(_i64s(7, 7), 4, True)
    var rowid_data = _rlev2_direct(_i64s(0, 1), 4, True)
    var ctxn_data = _rlev2_direct(_i64s(5, 5), 4, True)
    var sku_data = List[UInt8]()
    _str_bytes(String("p1p2"), sku_data)
    var sku_len = _rlev2_direct(_i64s(2, 2), 4, False)
    var qty_data = _rlev2_direct(_i64s(9, 8), 4, True)

    # On-disk: 1..5 DATA, sku(7) DATA, sku LENGTH, qty(8) DATA.
    var data_region = List[UInt8]()
    _app(op_data, data_region)
    _app(otxn_data, data_region)
    _app(bucket_data, data_region)
    _app(rowid_data, data_region)
    _app(ctxn_data, data_region)
    _app(sku_data, data_region)
    _app(sku_len, data_region)
    _app(qty_data, data_region)

    var sf = List[UInt8]()
    _pb_message_field(1, _enc_stream(ORC_STREAM_DATA, 1, len(op_data)), sf)
    _pb_message_field(1, _enc_stream(ORC_STREAM_DATA, 2, len(otxn_data)), sf)
    _pb_message_field(1, _enc_stream(ORC_STREAM_DATA, 3, len(bucket_data)), sf)
    _pb_message_field(1, _enc_stream(ORC_STREAM_DATA, 4, len(rowid_data)), sf)
    _pb_message_field(1, _enc_stream(ORC_STREAM_DATA, 5, len(ctxn_data)), sf)
    _pb_message_field(1, _enc_stream(ORC_STREAM_DATA, 7, len(sku_data)), sf)
    _pb_message_field(1, _enc_stream(ORC_STREAM_LENGTH, 7, len(sku_len)), sf)
    _pb_message_field(1, _enc_stream(ORC_STREAM_DATA, 8, len(qty_data)), sf)
    for _i in range(9):
        _pb_message_field(2, _enc_encoding(ORC_ENCODING_DIRECT_V2, 0), sf)

    var root = List[UInt8]()
    _pb_varint_field(1, UInt64(ORC_KIND_STRUCT), root)
    _pb_varint_field(2, 1, root)
    _pb_varint_field(2, 2, root)
    _pb_varint_field(2, 3, root)
    _pb_varint_field(2, 4, root)
    _pb_varint_field(2, 5, root)
    _pb_varint_field(2, 6, root)
    _pb_string_field(3, String("operation"), root)
    _pb_string_field(3, String("originalTransaction"), root)
    _pb_string_field(3, String("bucket"), root)
    _pb_string_field(3, String("rowId"), root)
    _pb_string_field(3, String("currentTransaction"), root)
    _pb_string_field(3, String("row"), root)

    var row_t = List[UInt8]()
    _pb_varint_field(1, UInt64(ORC_KIND_STRUCT), row_t)
    _pb_varint_field(2, 7, row_t)
    _pb_varint_field(2, 8, row_t)
    _pb_string_field(3, String("sku"), row_t)
    _pb_string_field(3, String("qty"), row_t)

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
    _pb_varint_field(5, 2, stripe_entry)
    _pb_message_field(3, stripe_entry, footer2)
    _pb_message_field(4, root, footer2)
    _pb_message_field(4, _enc_type_leaf(ORC_KIND_INT), footer2)
    _pb_message_field(4, _enc_type_leaf(ORC_KIND_LONG), footer2)
    _pb_message_field(4, _enc_type_leaf(ORC_KIND_INT), footer2)
    _pb_message_field(4, _enc_type_leaf(ORC_KIND_LONG), footer2)
    _pb_message_field(4, _enc_type_leaf(ORC_KIND_LONG), footer2)
    _pb_message_field(4, row_t, footer2)
    _pb_message_field(4, _enc_varchar(32), footer2)  # sku VARCHAR(32)
    _pb_message_field(4, _enc_type_leaf(ORC_KIND_INT), footer2)  # qty
    _pb_varint_field(6, 2, footer2)

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
    _app(data_region, f)
    _app(sf, f)
    _app(footer2, f)
    _app(ps, f)
    f.append(UInt8(len(ps)))
    return f^


def _meta_value(
    keys: List[String], values: List[String], key: String
) -> String:
    for i in range(len(keys)):
        if keys[i] == key:
            return values[i]
    return String("<missing>")


def test_acid_row_lift_preserves_leaf_metadata() raises:
    var file_bytes = _build_acid_varchar_file()
    var rb = read_orc_bytes(Span(file_bytes))

    # Default lift -> 2 cols (sku, qty).
    assert_equal(rb.num_columns(), 2, "lifted row.* (sku, qty)")
    assert_equal(rb.schema.field_name(0), String("sku"), "col 0 = sku")
    assert_equal(rb.schema.field_name(1), String("qty"), "col 1 = qty")

    # REGRESSION GUARD: the lifted `sku` leaf MUST still carry its
    # arrow.orc.varchar_max_length metadata (the lift is a node-index reparent,
    # not a metadata strip). Readers of the lifted columns depend on this.
    var k0 = rb.schema.field_metadata_keys(0)
    var v0 = rb.schema.field_metadata_values(0)
    assert_equal(
        _meta_value(k0, v0, ARROW_ORC_VARCHAR_MAX_LENGTH),
        String("32"),
        "lifted sku still carries varchar_max_length=32",
    )

    # Values decode through the lift.
    ref sku_col = rb.column_at(0)
    var sa = sku_col.as_string()
    assert_equal(sa.get(0), String("p1"), "sku[0]")
    assert_equal(sa.get(1), String("p2"), "sku[1]")


def main() raises:
    test_acid_row_lift_preserves_leaf_metadata()
    print("test_orc_acid_row_lift_preserves_leaf_metadata: ALL PASS")
