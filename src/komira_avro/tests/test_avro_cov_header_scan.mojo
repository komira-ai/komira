# =============================================================================
# test_avro_cov_header_scan.mojo -- OCF header decode, block scan and the JSON
# number scanner: the refusal arms and the rarely-written header shapes.
# =============================================================================
#
# What each case proves, and the mutant planted in the product code to see
# it fail (each alone, then restored; the red message is quoted):
#   H1  a metadata map written as a NEGATIVE pair count (the Avro block form:
#       count, byte size, pairs) decodes to the same schema and codec.
#       Mutant `count = -count` -> `count = count`: red, "MALFORMED_HEADER:
#       metadata map pair count out of range".
#   H2  a pair count of Int64.MIN (whose negation is still negative) is
#       refused by name. Mutant: the second `count < 0` check made False:
#       red, MISSING_SCHEMA instead of the pair-count refusal.
#   H3  every TRUNCATED_HEADER / MALFORMED_VARINT / MISSING_SCHEMA arm of
#       the header, each pinned by its message; a 20-byte header passes the
#       length check. Mutant `len(bytes) < MAGIC + SYNC` -> `<=`: red,
#       "file too short for header" where MISSING_SCHEMA was expected.
#   H4  `_bytes_to_string` checks its own range (start < 0, n < 0, n past
#       the end). Mutant: `start < 0` dropped from its check: red, an
#       assert abort ("slice start index -1 is out of bounds").
#   H5  `codec_wire_name` of an unknown tag is "unknown".
#   S1  block scan: a negative object_count, a varint running off the end,
#       an 11-byte varint, each refused by name. Mutant: the
#       `object_count < 0` check made False: red, "(accepted)" where
#       MALFORMED_BLOCK was expected.
#   S2  `find_sync_marker_from` answers -1 for a start before 0, past the
#       end, and when no marker follows; `_sync_matches` answers False when
#       fewer than 16 bytes remain.
#   N1  `scan_json_number` refuses a literal that starts with neither '-'
#       nor a digit (or starts past the end), naming the offset.
# =============================================================================

from std.testing import assert_equal, assert_true

from komira_avro import (
    decode_ocf_header,
    scan_ocf_blocks,
    find_sync_marker_from,
    codec_wire_name,
    OCF_SYNC_LEN,
)
from komira_avro.ocf_header import _bytes_to_string
from komira_avro.ocf_block_scan import _sync_matches
from komira_avro.json_number import scan_json_number


comptime _SCHEMA = String(
    '{"type":"record","name":"R","fields":[{"name":"v","type":"long"}]}'
)


def _encode_long(n: Int64, mut out: List[UInt8]):
    var zz = UInt64((n << 1) ^ (n >> 63))
    while True:
        var b = UInt8(zz & 0x7F)
        zz >>= 7
        if zz != 0:
            out.append(b | 0x80)
        else:
            out.append(b)
            break


def _encode_string(s: String, mut out: List[UInt8]):
    var b = s.as_bytes()
    _encode_long(Int64(len(b)), out)
    for i in range(len(b)):
        out.append(b[i])


def _magic(mut out: List[UInt8]):
    out.append(UInt8(ord("O")))
    out.append(UInt8(ord("b")))
    out.append(UInt8(ord("j")))
    out.append(0x01)


def _sync(mut out: List[UInt8]):
    for i in range(OCF_SYNC_LEN):
        out.append(UInt8(0xA0 + i))


def _pairs(mut out: List[UInt8]):
    _encode_string(String("avro.schema"), out)
    _encode_string(_SCHEMA, out)
    _encode_string(String("avro.codec"), out)
    _encode_string(String("deflate"), out)


def _header() -> List[UInt8]:
    var out = List[UInt8]()
    _magic(out)
    _encode_long(Int64(2), out)
    _pairs(out)
    _encode_long(Int64(0), out)
    _sync(out)
    return out^


def _header_refusal(bytes: List[UInt8]) -> String:
    try:
        var _h = decode_ocf_header(Span(bytes))
    except e:
        return String(e)
    return String("(accepted)")


def _scan_refusal(bytes: List[UInt8]) -> String:
    try:
        var _b = scan_ocf_blocks(Span(bytes))
    except e:
        return String(e)
    return String("(accepted)")


def test_negative_pair_count_block_form() raises:
    """H1."""
    var pairs = List[UInt8]()
    _pairs(pairs)
    var out = List[UInt8]()
    _magic(out)
    _encode_long(Int64(-2), out)
    _encode_long(Int64(len(pairs)), out)
    out.extend(Span(pairs))
    _encode_long(Int64(0), out)
    _sync(out)
    var h = decode_ocf_header(Span(out))
    assert_equal(h.schema_json, _SCHEMA)
    assert_equal(h.codec_name(), "deflate")
    assert_equal(h.header_len, len(out))
    assert_equal(Int(h.sync_marker[15]), 0xAF)


def test_pair_count_int64_min_refused() raises:
    """H2: zigzag(Int64.MIN) is ten bytes ff..ff 01."""
    var out = List[UInt8]()
    _magic(out)
    for _ in range(9):
        out.append(0xFF)
    out.append(0x01)
    for _ in range(16):
        out.append(0x00)
    assert_equal(
        _header_refusal(out),
        "AvroOcfError.MALFORMED_HEADER: metadata map pair count out of range",
    )


def test_header_truncations() raises:
    """H3."""
    # 19 bytes: one short of magic + sync.
    var short = List[UInt8]()
    _magic(short)
    for _ in range(15):
        short.append(0)
    assert_equal(
        _header_refusal(short),
        "AvroOcfError.TRUNCATED_HEADER: file too short for header",
    )
    # 20 bytes is not refused by the length check: magic, an empty map,
    # then 15 bytes of a 16-byte sync -> it is the missing-schema arm.
    var twenty = List[UInt8]()
    _magic(twenty)
    _encode_long(Int64(0), twenty)
    for _ in range(15):
        twenty.append(0)
    assert_equal(len(twenty), 20)
    assert_equal(
        _header_refusal(twenty),
        "AvroOcfError.MISSING_SCHEMA: header has no 'avro.schema'",
    )
    # The map ends, the schema is present, the sync marker is cut short.
    var full = _header()
    var cut = List[UInt8]()
    cut.extend(Span(full)[0 : len(full) - 1])
    assert_equal(
        _header_refusal(cut),
        "AvroOcfError.TRUNCATED_HEADER: missing sync marker",
    )
    # A value-length varint running off the end of the bytes (20 bytes:
    # magic, count, a 13-byte key, then one continuation byte).
    var overrun = List[UInt8]()
    _magic(overrun)
    _encode_long(Int64(1), overrun)
    _encode_string(String("avro.schema.x"), overrun)
    overrun.append(0x80)
    assert_equal(len(overrun), 20)
    assert_equal(
        _header_refusal(overrun),
        "AvroOcfError.TRUNCATED_HEADER: varint overrun",
    )
    # A pair count with ten continuation bytes.
    var long_varint = List[UInt8]()
    _magic(long_varint)
    for _ in range(10):
        long_varint.append(0x80)
    for _ in range(10):
        long_varint.append(0x00)
    assert_equal(
        _header_refusal(long_varint),
        "AvroOcfError.MALFORMED_VARINT: long > 10 bytes",
    )
    # A key whose declared length runs past the end, and a negative one.
    var key_over = List[UInt8]()
    _magic(key_over)
    _encode_long(Int64(1), key_over)
    _encode_long(Int64(100), key_over)
    for _ in range(20):
        key_over.append(0x61)
    assert_equal(
        _header_refusal(key_over),
        "AvroOcfError.TRUNCATED_HEADER: string declares length 100 but only"
        " 20 header bytes remain",
    )
    var key_neg = List[UInt8]()
    _magic(key_neg)
    _encode_long(Int64(1), key_neg)
    _encode_long(Int64(-3), key_neg)
    for _ in range(20):
        key_neg.append(0x61)
    assert_equal(
        _header_refusal(key_neg),
        "AvroOcfError.TRUNCATED_HEADER: string declares length -3 but only"
        " 20 header bytes remain",
    )


def _range_refusal(bytes: List[UInt8], start: Int, n: Int) -> String:
    try:
        return _bytes_to_string(Span(bytes), start, n, "what")
    except e:
        return String(e)


def test_bytes_to_string_owns_its_range() raises:
    """H4."""
    var b: List[UInt8] = [0x61, 0x62, 0x63]
    assert_equal(_range_refusal(b, 1, 2), "bc")
    assert_equal(_range_refusal(b, 3, 0), "")
    assert_equal(
        _range_refusal(b, -1, 1),
        "AvroOcfError.TRUNCATED_HEADER: byte range [-1, -1+1) is not"
        " contained in the 3-byte header view",
    )
    assert_equal(
        _range_refusal(b, 0, -1),
        "AvroOcfError.TRUNCATED_HEADER: byte range [0, 0+-1) is not"
        " contained in the 3-byte header view",
    )
    assert_equal(
        _range_refusal(b, 2, 2),
        "AvroOcfError.TRUNCATED_HEADER: byte range [2, 2+2) is not"
        " contained in the 3-byte header view",
    )


def test_codec_wire_name_unknown() raises:
    """H5."""
    assert_equal(codec_wire_name(99), "unknown")
    assert_equal(codec_wire_name(-1), "unknown")


def test_block_scan_refusals() raises:
    """S1."""
    var neg = _header()
    _encode_long(Int64(-5), neg)
    _encode_long(Int64(0), neg)
    _sync(neg)
    assert_equal(
        _scan_refusal(neg),
        "AvroOcfError.MALFORMED_BLOCK: negative block object_count -5",
    )
    var overrun = _header()
    overrun.append(0x80)
    assert_equal(
        _scan_refusal(overrun),
        "AvroOcfError.TRUNCATED_BLOCK: varint overrun",
    )
    var eleven = _header()
    for _ in range(10):
        eleven.append(0xFF)
    eleven.append(0x01)
    assert_equal(
        _scan_refusal(eleven),
        "AvroOcfError.MALFORMED_VARINT: long > 10 bytes",
    )


def test_sync_search_edges() raises:
    """S2."""
    var bytes = List[UInt8]()
    for _ in range(4):
        bytes.append(0x00)
    _sync(bytes)
    bytes.append(0x07)
    var n = len(bytes)
    var marker = Array[UInt8, OCF_SYNC_LEN](fill=0)
    for i in range(OCF_SYNC_LEN):
        marker[i] = UInt8(0xA0 + i)
    assert_equal(find_sync_marker_from(Span(bytes), 0, marker), 20)
    assert_equal(find_sync_marker_from(Span(bytes), -1, marker), -1)
    assert_equal(find_sync_marker_from(Span(bytes), n + 1, marker), -1)
    assert_equal(find_sync_marker_from(Span(bytes), 5, marker), -1)
    assert_true(_sync_matches(Span(bytes), 4, marker))
    assert_true(not _sync_matches(Span(bytes), 5, marker))
    assert_true(not _sync_matches(Span(bytes), n - 15, marker))


def test_number_scan_first_byte() raises:
    """N1."""
    var text = String("x1")
    var got = String("(accepted)")
    try:
        _ = scan_json_number(text.as_bytes(), 0)
    except e:
        got = String(e)
    assert_equal(
        got,
        "AvroSchemaError.MALFORMED_JSON: bad number at byte 0: a number"
        " starts with '-' or a digit",
    )
    var end = String("1")
    got = String("(accepted)")
    try:
        _ = scan_json_number(end.as_bytes(), 1)
    except e:
        got = String(e)
    assert_equal(
        got,
        "AvroSchemaError.MALFORMED_JSON: bad number at byte 1: a number"
        " starts with '-' or a digit",
    )


def main() raises:
    test_negative_pair_count_block_form()
    test_pair_count_int64_min_refused()
    test_header_truncations()
    test_bytes_to_string_owns_its_range()
    test_codec_wire_name_unknown()
    test_block_scan_refusals()
    test_sync_search_edges()
    test_number_scan_first_byte()
    print("test_avro_cov_header_scan: ALL PASS")
