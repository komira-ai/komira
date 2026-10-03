# =============================================================================
# test_orc_stripe_footer_decode.mojo — ORC StripeFooter + chunk-header decode.
# =============================================================================
#
# Acceptance: StripeFooter decode (streams + encodings).
#
# StripeFooter carries the per-stripe stream catalog (PRESENT / DATA / LENGTH
# / SECONDARY / DICTIONARY_DATA byte sizes per column) + the per-column
# ColumnEncoding (DIRECT_V2 vs DICTIONARY_V2 etc). This is the input the
# per-column decoder dispatches on.
#
# Coverage:
#   T1  StripeFooter.streams: per-column stream kinds + byte lengths.
#   T2  StripeFooter.columns: per-column encoding kinds + dictionary sizes.
#   T3  StripeFooter.writerTimezone string.
#   T4  Mixed DIRECT_V2 + DICTIONARY_V2 columns (lineitem-shape).
#   T5  Chunk header: compressed chunk (isOriginal=False) length unpack.
#   T6  Chunk header: original/uncompressed chunk (isOriginal=True).
#   T7  Stream byte-skip: sum of stream lengths == data span (projection
#       byte-skip arithmetic the reader relies on).
# =============================================================================

from std.testing import assert_equal, assert_true

from komira_orc import (
    StripeFooter,
    OrcStream,
    OrcColumnEncoding,
    ChunkHeader,
    parse_chunk_header,
    PB_WIRE_VARINT,
    PB_WIRE_LEN,
    ORC_STREAM_PRESENT,
    ORC_STREAM_DATA,
    ORC_STREAM_LENGTH,
    ORC_STREAM_DICTIONARY_DATA,
    ORC_ENCODING_DIRECT_V2,
    ORC_ENCODING_DICTIONARY_V2,
    orc_encoding_name,
)


# -----------------------------------------------------------------------------
# In-test protobuf encoders.
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


def _build_stripe_footer() -> List[UInt8]:
    """A lineitem-shaped StripeFooter:
      col 0 (root struct): no streams.
      col 1 (bigint, DIRECT_V2): PRESENT + DATA.
      col 2 (int, DIRECT_V2): PRESENT + DATA.
      col 3 (string, DICTIONARY_V2): PRESENT + DATA(indices) + LENGTH +
            DICTIONARY_DATA.
    """
    var out = List[UInt8]()
    # Streams (field 1).
    _pb_message_field(1, _enc_stream(ORC_STREAM_PRESENT, 1, 16), out)
    _pb_message_field(1, _enc_stream(ORC_STREAM_DATA, 1, 800), out)
    _pb_message_field(1, _enc_stream(ORC_STREAM_PRESENT, 2, 16), out)
    _pb_message_field(1, _enc_stream(ORC_STREAM_DATA, 2, 400), out)
    _pb_message_field(1, _enc_stream(ORC_STREAM_PRESENT, 3, 16), out)
    _pb_message_field(1, _enc_stream(ORC_STREAM_DATA, 3, 200), out)
    _pb_message_field(1, _enc_stream(ORC_STREAM_LENGTH, 3, 24), out)
    _pb_message_field(1, _enc_stream(ORC_STREAM_DICTIONARY_DATA, 3, 128), out)

    # Columns (field 2): 4 entries (root + 3 leaves).
    _pb_message_field(2, _enc_encoding(ORC_ENCODING_DIRECT_V2, 0), out)
    _pb_message_field(2, _enc_encoding(ORC_ENCODING_DIRECT_V2, 0), out)
    _pb_message_field(2, _enc_encoding(ORC_ENCODING_DIRECT_V2, 0), out)
    _pb_message_field(2, _enc_encoding(ORC_ENCODING_DICTIONARY_V2, 12), out)

    # writerTimezone (field 3).
    _pb_string_field(3, String("UTC"), out)
    return out^


# -----------------------------------------------------------------------------
# Tests.
# -----------------------------------------------------------------------------


def test_stripe_footer_streams() raises:
    """T1: streams decode with correct kind / column / length."""
    var sf = StripeFooter.parse(Span(_build_stripe_footer()))
    assert_equal(len(sf.streams), 8)
    assert_equal(sf.streams[0].kind, ORC_STREAM_PRESENT)
    assert_equal(sf.streams[0].column, 1)
    assert_equal(sf.streams[0].length, 16)
    assert_equal(sf.streams[1].kind, ORC_STREAM_DATA)
    assert_equal(sf.streams[1].column, 1)
    assert_equal(sf.streams[1].length, 800)


def test_stripe_footer_columns() raises:
    """T2: per-column encodings decode."""
    var sf = StripeFooter.parse(Span(_build_stripe_footer()))
    assert_equal(len(sf.columns), 4)
    assert_equal(sf.columns[0].kind, ORC_ENCODING_DIRECT_V2)
    assert_equal(sf.columns[3].kind, ORC_ENCODING_DICTIONARY_V2)
    assert_equal(sf.columns[3].dictionary_size, 12)


def test_stripe_footer_timezone() raises:
    """T3: writerTimezone string decodes."""
    var sf = StripeFooter.parse(Span(_build_stripe_footer()))
    assert_equal(sf.writer_timezone, String("UTC"))


def test_mixed_encoding_lineitem_shape() raises:
    """T4: the DICTIONARY_V2 string column carries 4 streams (PRESENT + DATA +
    LENGTH + DICTIONARY_DATA); the DIRECT_V2 numerics carry 2."""
    var sf = StripeFooter.parse(Span(_build_stripe_footer()))
    var col3_streams = 0
    var col3_has_dict_data = False
    for i in range(len(sf.streams)):
        if sf.streams[i].column == 3:
            col3_streams += 1
            if sf.streams[i].kind == ORC_STREAM_DICTIONARY_DATA:
                col3_has_dict_data = True
    assert_equal(col3_streams, 4)
    assert_true(col3_has_dict_data, "dict string col must have DICTIONARY_DATA")
    assert_equal(orc_encoding_name(sf.columns[3].kind), String("DICTIONARY_V2"))


def test_chunk_header_compressed() raises:
    """T5: a compressed chunk header unpacks length = header24 >> 1."""
    # compressed_length = 500, isOriginal = False.
    # header24 = 500 << 1 = 1000 = 0x0003E8.
    var buf = List[UInt8]()
    buf.append(0xE8)  # low byte
    buf.append(0x03)  # mid byte
    buf.append(0x00)  # high byte
    var ch = parse_chunk_header(Span(buf), 0)
    assert_equal(ch.compressed_length, 500)
    assert_true(not ch.is_original, "compressed chunk must not be original")
    assert_equal(ch.payload_start, 3)
    assert_equal(ch.payload_end(), 503)


def test_chunk_header_original() raises:
    """T6: an original (uncompressed) chunk has the isOriginal low bit set."""
    # compressed_length = 256, isOriginal = True.
    # header24 = (256 << 1) | 1 = 513 = 0x000201.
    var buf = List[UInt8]()
    buf.append(0x01)
    buf.append(0x02)
    buf.append(0x00)
    var ch = parse_chunk_header(Span(buf), 0)
    assert_equal(ch.compressed_length, 256)
    assert_true(ch.is_original, "original chunk must report is_original")


def test_stream_byte_skip_arithmetic() raises:
    """T7: summing per-column stream lengths gives the column's data span —
    the projection byte-skip arithmetic the reader relies on."""
    var sf = StripeFooter.parse(Span(_build_stripe_footer()))
    var total = 0
    for i in range(len(sf.streams)):
        total += sf.streams[i].length
    # 16+800 + 16+400 + 16+200+24+128 = 1600.
    assert_equal(total, 1600)


def main() raises:
    test_stripe_footer_streams()
    test_stripe_footer_columns()
    test_stripe_footer_timezone()
    test_mixed_encoding_lineitem_shape()
    test_chunk_header_compressed()
    test_chunk_header_original()
    test_stream_byte_skip_arithmetic()
    print("test_orc_stripe_footer_decode: ALL PASS")
