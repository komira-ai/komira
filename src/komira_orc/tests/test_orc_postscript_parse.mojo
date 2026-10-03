# =============================================================================
# test_orc_postscript_parse.mojo — ORC PostScript decode + protobuf primitives.
# =============================================================================
#
# Acceptance: PostScript decode from a fixture file tail.
#
# Coverage:
#   T1  protobuf varint round-trip (single + multi-byte).
#   T2  protobuf tag decode (field number + wire type).
#   T3  protobuf length-delimited field span.
#   T4  protobuf skip-field for all 4 wire types.
#   T5  PostScript decode: footerLength + compression + blockSize + version
#       + metadataLength + magic.
#   T6  PostScript with ZSTD codec + 2-element version list.
#   T7  PostScript missing magic (forward-compat skip of unknown field).
# =============================================================================

from std.testing import assert_equal, assert_true

from komira_orc import (
    PostScript,
    pb_read_varint,
    pb_read_tag,
    pb_read_len_field,
    pb_skip_field,
    pb_read_string,
    PB_WIRE_VARINT,
    PB_WIRE_FIXED64,
    PB_WIRE_LEN,
    PB_WIRE_FIXED32,
    ORC_COMPRESSION_NONE,
    ORC_COMPRESSION_ZSTD,
    orc_compression_name,
)


# -----------------------------------------------------------------------------
# In-test protobuf encoders (the inverse of the footer.mojo decoders).
# -----------------------------------------------------------------------------


def _pb_varint(n: UInt64, mut out: List[UInt8]):
    """Append a protobuf base-128 varint."""
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
    """Append a protobuf field tag."""
    _pb_varint(UInt64((field_number << 3) | wire_type), out)


def _pb_varint_field(field_number: Int, value: UInt64, mut out: List[UInt8]):
    """Append a complete varint-typed field (tag + value)."""
    _pb_tag(field_number, PB_WIRE_VARINT, out)
    _pb_varint(value, out)


def _pb_string_field(field_number: Int, s: String, mut out: List[UInt8]):
    """Append a complete length-delimited string field (tag + len + bytes)."""
    _pb_tag(field_number, PB_WIRE_LEN, out)
    var b = s.as_bytes()
    _pb_varint(UInt64(len(b)), out)
    for i in range(len(b)):
        out.append(b[i])


def _build_postscript(
    footer_len: Int,
    compression: Int,
    block_size: Int,
    versions: List[Int],
    metadata_len: Int,
    magic: String,
) -> List[UInt8]:
    """Build a synthetic PostScript protobuf body."""
    var out = List[UInt8]()
    _pb_varint_field(1, UInt64(footer_len), out)
    _pb_varint_field(2, UInt64(compression), out)
    _pb_varint_field(3, UInt64(block_size), out)
    for i in range(len(versions)):
        _pb_varint_field(4, UInt64(versions[i]), out)
    _pb_varint_field(5, UInt64(metadata_len), out)
    _pb_string_field(8000, magic, out)
    return out^


# -----------------------------------------------------------------------------
# Tests.
# -----------------------------------------------------------------------------


def test_varint_round_trip() raises:
    """T1: varint encode -> decode preserves value across byte-width boundaries.
    """
    var samples = List[UInt64]()
    samples.append(0)
    samples.append(1)
    samples.append(127)  # 1 byte boundary
    samples.append(128)  # 2 byte boundary
    samples.append(300)
    samples.append(16383)  # 2 byte max
    samples.append(16384)  # 3 byte boundary
    samples.append(123456789)
    samples.append(UInt64(1) << 40)
    for i in range(len(samples)):
        var buf = List[UInt8]()
        _pb_varint(samples[i], buf)
        var got = pb_read_varint(Span(buf), 0)
        assert_equal(got.value, samples[i])
        assert_equal(got.new_pos, len(buf))


def test_tag_decode() raises:
    """T2: tag packs (field_number << 3) | wire_type."""
    var buf = List[UInt8]()
    _pb_tag(4, PB_WIRE_LEN, buf)
    var t = pb_read_tag(Span(buf), 0)
    assert_equal(t.field_number, 4)
    assert_equal(t.wire_type, PB_WIRE_LEN)

    var buf2 = List[UInt8]()
    _pb_tag(8000, PB_WIRE_LEN, buf2)  # large field number (>15 → multi-byte tag)
    var t2 = pb_read_tag(Span(buf2), 0)
    assert_equal(t2.field_number, 8000)
    assert_equal(t2.wire_type, PB_WIRE_LEN)


def test_len_delimited_field() raises:
    """T3: length-delimited field exposes its payload span + string decode."""
    var buf = List[UInt8]()
    _pb_string_field(3, String("ORC"), buf)
    var t = pb_read_tag(Span(buf), 0)
    assert_equal(t.field_number, 3)
    assert_equal(t.wire_type, PB_WIRE_LEN)
    var f = pb_read_len_field(Span(buf), t.new_pos)
    assert_equal(f.payload_end - f.payload_start, 3)
    var s = pb_read_string(Span(buf), f.payload_start, f.payload_end)
    assert_equal(s, String("ORC"))


def test_skip_field_all_wire_types() raises:
    """T4: skip-field advances correctly for each wire type."""
    # varint
    var b0 = List[UInt8]()
    _pb_varint(300, b0)
    assert_equal(pb_skip_field(Span(b0), 0, PB_WIRE_VARINT), len(b0))

    # fixed64
    var b1 = List[UInt8]()
    for _i in range(8):
        b1.append(0xAB)
    assert_equal(pb_skip_field(Span(b1), 0, PB_WIRE_FIXED64), 8)

    # fixed32
    var b2 = List[UInt8]()
    for _i in range(4):
        b2.append(0xCD)
    assert_equal(pb_skip_field(Span(b2), 0, PB_WIRE_FIXED32), 4)

    # length-delimited
    var b3 = List[UInt8]()
    _pb_varint(5, b3)  # length prefix
    for _i in range(5):
        b3.append(0xEE)
    assert_equal(pb_skip_field(Span(b3), 0, PB_WIRE_LEN), len(b3))


def test_postscript_basic_decode() raises:
    """T5: PostScript decode pulls every scalar + the magic."""
    var versions = List[Int]()
    versions.append(0)
    versions.append(12)
    var buf = _build_postscript(
        footer_len=42,
        compression=ORC_COMPRESSION_NONE,
        block_size=262144,
        versions=versions,
        metadata_len=17,
        magic=String("ORC"),
    )
    var ps = PostScript.parse(Span(buf))
    assert_equal(ps.footer_length, 42)
    assert_equal(ps.compression, ORC_COMPRESSION_NONE)
    assert_equal(ps.compression_block_size, 262144)
    assert_equal(ps.version_major, 0)
    assert_equal(ps.version_minor, 12)
    assert_equal(ps.metadata_length, 17)
    assert_equal(ps.magic, String("ORC"))
    assert_equal(orc_compression_name(ps.compression), String("NONE"))


def test_postscript_zstd_codec() raises:
    """T6: PostScript with ZSTD codec parses + names correctly."""
    var versions = List[Int]()
    versions.append(0)
    versions.append(12)
    var buf = _build_postscript(
        footer_len=1024,
        compression=ORC_COMPRESSION_ZSTD,
        block_size=65536,
        versions=versions,
        metadata_len=200,
        magic=String("ORC"),
    )
    var ps = PostScript.parse(Span(buf))
    assert_equal(ps.compression, ORC_COMPRESSION_ZSTD)
    assert_equal(orc_compression_name(ps.compression), String("ZSTD"))
    assert_equal(ps.compression_block_size, 65536)


def test_postscript_unknown_field_skipped() raises:
    """T7: an unknown field is skipped (forward-compatibility), known fields
    still decode."""
    var buf = List[UInt8]()
    _pb_varint_field(1, 99, buf)  # footerLength
    # Unknown field 4242, wire type LEN — must be skipped, not an error.
    _pb_string_field(4242, String("future-field"), buf)
    _pb_varint_field(2, UInt64(ORC_COMPRESSION_NONE), buf)
    _pb_string_field(8000, String("ORC"), buf)
    var ps = PostScript.parse(Span(buf))
    assert_equal(ps.footer_length, 99)
    assert_equal(ps.compression, ORC_COMPRESSION_NONE)
    assert_equal(ps.magic, String("ORC"))


def main() raises:
    test_varint_round_trip()
    test_tag_decode()
    test_len_delimited_field()
    test_skip_field_all_wire_types()
    test_postscript_basic_decode()
    test_postscript_zstd_codec()
    test_postscript_unknown_field_skipped()
    print("test_orc_postscript_parse: ALL PASS")
