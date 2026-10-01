# =============================================================================
# test_ocf_header_decode.mojo — OCF header decode + codec wire-name dispatch.
# =============================================================================
#
# Acceptance:
#   - header + codec extraction.
#   - ASSERT codec dispatch on Avro spec WIRE-NAME strings (e.g. "zstandard"
#     NOT "zstd" shorthand).
#
# Fixtures are synthesized in-test (no external Avro library needed):
#   header := "Obj" 0x01
#             map<string,bytes>{ "avro.schema" -> JSON, "avro.codec" -> name }
#             sync_marker[16]
#
# Coverage:
#   T1  magic + metadata map decode; schema JSON + codec extracted.
#   T2  codec "zstandard" dispatches to ZSTANDARD tag (NOT "zstd").
#   T3  "zstd" shorthand is REJECTED (not a valid Avro wire-name).
#   T4  all 6 spec codecs round-trip wire-name <-> tag.
#   T5  absent avro.codec defaults to null.
#   T6  bad magic raises.
#   T7  sync marker bytes are read verbatim; header_len points past sync.
#   T8  decoded schema JSON parses into an AvroSchema.
# =============================================================================

from std.testing import assert_equal, assert_true

from komira_avro import (
    decode_ocf_header,
    codec_tag_from_wire_name,
    codec_wire_name,
    AVRO_CODEC_NULL,
    AVRO_CODEC_DEFLATE,
    AVRO_CODEC_SNAPPY,
    AVRO_CODEC_BZIP2,
    AVRO_CODEC_XZ,
    AVRO_CODEC_ZSTANDARD,
    OCF_SYNC_LEN,
)


# -----------------------------------------------------------------------------
# In-test OCF binary encoders.
# -----------------------------------------------------------------------------

def _encode_long(n: Int64, mut out: List[UInt8]):
    """Append a zigzag varint Avro `long`."""
    # Zigzag encode: (n << 1) ^ (n >> 63).
    var zz = UInt64((n << 1) ^ (n >> 63))
    while True:
        var b = UInt8(zz & 0x7F)
        zz >>= 7
        if zz != 0:
            out.append(b | 0x80)
        else:
            out.append(b)
            break


def _encode_bytes(data: List[UInt8], mut out: List[UInt8]):
    """Append an Avro `bytes` (long length + raw bytes)."""
    _encode_long(Int64(len(data)), out)
    for i in range(len(data)):
        out.append(data[i])


def _encode_string(s: String, mut out: List[UInt8]):
    """Append an Avro `string` (long length + UTF-8 bytes)."""
    var b = s.as_bytes()
    _encode_long(Int64(len(b)), out)
    for i in range(len(b)):
        out.append(b[i])


def _str_bytes(s: String) -> List[UInt8]:
    var out = List[UInt8]()
    var b = s.as_bytes()
    for i in range(len(b)):
        out.append(b[i])
    return out^


def _make_header(schema_json: String, codec: String, with_codec: Bool) -> List[UInt8]:
    """Build a synthetic OCF header byte buffer."""
    var out = List[UInt8]()
    # Magic.
    out.append(UInt8(ord("O")))
    out.append(UInt8(ord("b")))
    out.append(UInt8(ord("j")))
    out.append(0x01)
    # Metadata map: one block of (with_codec ? 2 : 1) pairs, then terminator.
    var n_pairs = 2 if with_codec else 1
    _encode_long(Int64(n_pairs), out)
    _encode_string(String("avro.schema"), out)
    _encode_bytes(_str_bytes(schema_json), out)
    if with_codec:
        _encode_string(String("avro.codec"), out)
        _encode_bytes(_str_bytes(codec), out)
    _encode_long(Int64(0), out)  # terminator
    # 16-byte sync marker (deterministic for the test).
    for i in range(OCF_SYNC_LEN):
        out.append(UInt8(0xA0 + i))
    return out^


comptime _SCHEMA = String(
    '{"type":"record","name":"User","fields":['
    '{"name":"id","type":"long"},{"name":"name","type":"string"}]}'
)


def test_header_decode_basic() raises:
    """T1: magic + metadata map decode; schema + codec extracted."""
    var buf = _make_header(_SCHEMA, String("null"), True)
    var hdr = decode_ocf_header(Span(buf))
    assert_equal(hdr.schema_json, _SCHEMA)
    assert_equal(hdr.codec_tag, AVRO_CODEC_NULL)


def test_codec_zstandard_wire_name() raises:
    """T2: codec dispatch is on the spec wire-name "zstandard"."""
    var buf = _make_header(_SCHEMA, String("zstandard"), True)
    var hdr = decode_ocf_header(Span(buf))
    assert_equal(hdr.codec_tag, AVRO_CODEC_ZSTANDARD)
    assert_equal(hdr.codec_name(), String("zstandard"))


def test_codec_zstd_shorthand_rejected() raises:
    """T3: the "zstd" shorthand is NOT a valid Avro wire-name -> rejected."""
    var buf = _make_header(_SCHEMA, String("zstd"), True)
    var raised = False
    try:
        var _hdr = decode_ocf_header(Span(buf))
    except:
        raised = True
    assert_true(raised, '"zstd" shorthand must be rejected (spec name is "zstandard")')


def test_all_six_codec_wire_names() raises:
    """T4: all 6 spec codecs round-trip wire-name <-> tag."""
    assert_equal(codec_tag_from_wire_name(String("null")), AVRO_CODEC_NULL)
    assert_equal(codec_tag_from_wire_name(String("deflate")), AVRO_CODEC_DEFLATE)
    assert_equal(codec_tag_from_wire_name(String("snappy")), AVRO_CODEC_SNAPPY)
    assert_equal(codec_tag_from_wire_name(String("bzip2")), AVRO_CODEC_BZIP2)
    assert_equal(codec_tag_from_wire_name(String("xz")), AVRO_CODEC_XZ)
    assert_equal(codec_tag_from_wire_name(String("zstandard")), AVRO_CODEC_ZSTANDARD)
    # Inverse.
    assert_equal(codec_wire_name(AVRO_CODEC_NULL), String("null"))
    assert_equal(codec_wire_name(AVRO_CODEC_DEFLATE), String("deflate"))
    assert_equal(codec_wire_name(AVRO_CODEC_SNAPPY), String("snappy"))
    assert_equal(codec_wire_name(AVRO_CODEC_BZIP2), String("bzip2"))
    assert_equal(codec_wire_name(AVRO_CODEC_XZ), String("xz"))
    assert_equal(codec_wire_name(AVRO_CODEC_ZSTANDARD), String("zstandard"))


def test_absent_codec_defaults_null() raises:
    """T5: a header without avro.codec defaults to the null codec."""
    var buf = _make_header(_SCHEMA, String(""), False)
    var hdr = decode_ocf_header(Span(buf))
    assert_equal(hdr.codec_tag, AVRO_CODEC_NULL)


def test_bad_magic_raises() raises:
    """T6: a buffer without the Obj\\x01 magic raises."""
    var buf = List[UInt8]()
    buf.append(UInt8(ord("X")))
    buf.append(UInt8(ord("b")))
    buf.append(UInt8(ord("j")))
    buf.append(0x01)
    for _i in range(40):
        buf.append(0)
    var raised = False
    try:
        var _hdr = decode_ocf_header(Span(buf))
    except:
        raised = True
    assert_true(raised, "bad magic must raise")


def test_sync_marker_and_header_len() raises:
    """T7: sync marker is read verbatim; header_len points past the sync."""
    var buf = _make_header(_SCHEMA, String("snappy"), True)
    var hdr = decode_ocf_header(Span(buf))
    # Sync marker was written as 0xA0..0xAF.
    for i in range(OCF_SYNC_LEN):
        assert_equal(hdr.sync_marker[i], UInt8(0xA0 + i))
    # header_len == total buffer length (no blocks appended in this fixture).
    assert_equal(hdr.header_len, len(buf))


def test_decoded_schema_parses() raises:
    """T8: the decoded avro.schema JSON parses into an AvroSchema."""
    var buf = _make_header(_SCHEMA, String("null"), True)
    var hdr = decode_ocf_header(Span(buf))
    var schema = hdr.parse_schema()
    # The root is a record -> fingerprint is computable + deterministic.
    assert_equal(schema.fingerprint(), schema.fingerprint())


def main() raises:
    test_header_decode_basic()
    test_codec_zstandard_wire_name()
    test_codec_zstd_shorthand_rejected()
    test_all_six_codec_wire_names()
    test_absent_codec_defaults_null()
    test_bad_magic_raises()
    test_sync_marker_and_header_len()
    test_decoded_schema_parses()
    print("test_ocf_header_decode: ALL PASS")
