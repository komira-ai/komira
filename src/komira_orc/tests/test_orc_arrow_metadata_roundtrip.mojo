# =============================================================================
# test_orc_arrow_metadata_roundtrip.mojo — arrow.orc.* extension metadata
# preserved to Arrow Field metadata.
# =============================================================================
#
# Acceptance: `test_orc_arrow_metadata_roundtrip` —
# arrow.orc.* keys preserved to Arrow field metadata.
#
# Fixture (hand-emitted, NONE codec, single stripe, 2 rows):
#   struct<name:varchar(40), code:char(10), tags:map<string,int>>
# Asserts the output Arrow Schema carries:
#   name -> arrow.orc.varchar_max_length = "40"
#   code -> arrow.orc.char_length        = "10"
#   tags -> arrow.orc.map_keys_sorted    = "false"
#
# (UNION's arrow.orc.union_mode=dense default is covered by the union decode
# test's substrate; here we focus on the VARCHAR/CHAR/MAP keys, which have no
# first-class Arrow type and so survive only as field metadata.)
# =============================================================================

from std.testing import assert_equal, assert_true

from komira_orc import (
    read_orc_bytes,
    ORC_COMPRESSION_NONE,
    ORC_KIND_STRUCT,
    ORC_KIND_INT,
    ORC_KIND_STRING,
    ORC_KIND_VARCHAR,
    ORC_KIND_CHAR,
    ORC_KIND_MAP,
    ORC_STREAM_DATA,
    ORC_STREAM_LENGTH,
    ORC_ENCODING_DIRECT_V2,
    ARROW_ORC_VARCHAR_MAX_LENGTH,
    ARROW_ORC_CHAR_LENGTH,
    ARROW_ORC_MAP_KEYS_SORTED,
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


def _enc_varchar_char(kind: Int, maximum_length: Int) -> List[UInt8]:
    """A VARCHAR/CHAR Type node carries field 4 = maximumLength."""
    var b = List[UInt8]()
    _pb_varint_field(1, UInt64(kind), b)
    _pb_varint_field(4, UInt64(maximum_length), b)
    return b^


# -----------------------------------------------------------------------------
# Build struct<name:varchar(40), code:char(10), tags:map<string,int>>, 2 rows.
#
# Schema node ids: 0=root, 1=name(varchar), 2=code(char), 3=tags(map),
#                  4=string(key), 5=int(value).
# name = ["al","bo"]; code = ["x","y"]; tags = [ {"k":1}, {} ].
# -----------------------------------------------------------------------------


def _build_metadata_file() -> List[UInt8]:
    var name_data = List[UInt8]()
    _str_bytes(String("albo"), name_data)
    var name_len = _rlev2_direct(_i64s(2, 2), 4, False)

    var code_data = List[UInt8]()
    _str_bytes(String("xy"), code_data)
    var code_len = _rlev2_direct(_i64s(1, 1), 4, False)

    var tags_len = _rlev2_direct(_i64s(1, 0), 4, False)
    var key_data = List[UInt8]()
    _str_bytes(String("k"), key_data)
    var key_len = _rlev2_direct(_i64s(1), 4, False)
    var val_data = _rlev2_direct(_i64s(1), 4, True)

    # On-disk: name DATA(1), name LEN(1), code DATA(2), code LEN(2),
    # tags LEN(3), key DATA(4), key LEN(4), val DATA(5).
    var data_region = List[UInt8]()

    def _app(src: List[UInt8], mut dst: List[UInt8]):
        for i in range(len(src)):
            dst.append(src[i])

    _app(name_data, data_region)
    _app(name_len, data_region)
    _app(code_data, data_region)
    _app(code_len, data_region)
    _app(tags_len, data_region)
    _app(key_data, data_region)
    _app(key_len, data_region)
    _app(val_data, data_region)

    var sf = List[UInt8]()
    _pb_message_field(1, _enc_stream(ORC_STREAM_DATA, 1, len(name_data)), sf)
    _pb_message_field(1, _enc_stream(ORC_STREAM_LENGTH, 1, len(name_len)), sf)
    _pb_message_field(1, _enc_stream(ORC_STREAM_DATA, 2, len(code_data)), sf)
    _pb_message_field(1, _enc_stream(ORC_STREAM_LENGTH, 2, len(code_len)), sf)
    _pb_message_field(1, _enc_stream(ORC_STREAM_LENGTH, 3, len(tags_len)), sf)
    _pb_message_field(1, _enc_stream(ORC_STREAM_DATA, 4, len(key_data)), sf)
    _pb_message_field(1, _enc_stream(ORC_STREAM_LENGTH, 4, len(key_len)), sf)
    _pb_message_field(1, _enc_stream(ORC_STREAM_DATA, 5, len(val_data)), sf)
    for _i in range(6):
        _pb_message_field(2, _enc_encoding(ORC_ENCODING_DIRECT_V2, 0), sf)

    var root = List[UInt8]()
    _pb_varint_field(1, UInt64(ORC_KIND_STRUCT), root)
    _pb_varint_field(2, 1, root)
    _pb_varint_field(2, 2, root)
    _pb_varint_field(2, 3, root)
    _pb_string_field(3, String("name"), root)
    _pb_string_field(3, String("code"), root)
    _pb_string_field(3, String("tags"), root)

    var map_t = List[UInt8]()
    _pb_varint_field(1, UInt64(ORC_KIND_MAP), map_t)
    _pb_varint_field(2, 4, map_t)
    _pb_varint_field(2, 5, map_t)

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
    _pb_message_field(4, _enc_varchar_char(ORC_KIND_VARCHAR, 40), footer2)
    _pb_message_field(4, _enc_varchar_char(ORC_KIND_CHAR, 10), footer2)
    _pb_message_field(4, map_t, footer2)
    _pb_message_field(4, _enc_type_leaf(ORC_KIND_STRING), footer2)
    _pb_message_field(4, _enc_type_leaf(ORC_KIND_INT), footer2)
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


def _meta_value(
    keys: List[String], values: List[String], key: String
) -> String:
    for i in range(len(keys)):
        if keys[i] == key:
            return values[i]
    return String("<missing>")


def test_arrow_metadata_roundtrip() raises:
    var file_bytes = _build_metadata_file()
    var rb = read_orc_bytes(Span(file_bytes))

    assert_equal(rb.num_columns(), 3, "3 cols (name, code, tags)")
    ref schema = rb.schema

    # name (col 0) -> arrow.orc.varchar_max_length = "40".
    var k0 = schema.field_metadata_keys(0)
    var v0 = schema.field_metadata_values(0)
    assert_equal(
        _meta_value(k0, v0, ARROW_ORC_VARCHAR_MAX_LENGTH),
        String("40"),
        "name carries varchar_max_length=40",
    )

    # code (col 1) -> arrow.orc.char_length = "10".
    var k1 = schema.field_metadata_keys(1)
    var v1 = schema.field_metadata_values(1)
    assert_equal(
        _meta_value(k1, v1, ARROW_ORC_CHAR_LENGTH),
        String("10"),
        "code carries char_length=10",
    )

    # tags (col 2) -> arrow.orc.map_keys_sorted = "false".
    var k2 = schema.field_metadata_keys(2)
    var v2 = schema.field_metadata_values(2)
    assert_equal(
        _meta_value(k2, v2, ARROW_ORC_MAP_KEYS_SORTED),
        String("false"),
        "tags carries map_keys_sorted=false",
    )

    # Sanity: the values still decode (name strings).
    ref name_col = rb.column_at(0)
    var na = name_col.as_string()
    assert_equal(na.get(0), String("al"), "name[0]")
    assert_equal(na.get(1), String("bo"), "name[1]")


def main() raises:
    test_arrow_metadata_roundtrip()
    print("test_orc_arrow_metadata_roundtrip: ALL PASS")
