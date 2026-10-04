# =============================================================================
# test_avro_snappy_codec_decode.mojo — snappy codec + CRC32 trailer.
# =============================================================================
#
# Acceptance:
#   Codecs: null + snappy. Avro snappy block payload is
#       raw_snappy_compressed_bytes ‖ BE4 crc32(uncompressed_bytes)
#   The decoder MUST strip + validate the 4-byte big-endian CRC32 trailer
#   BEFORE calling snappy_uncompress. A wrong-CRC trailer MUST
#   raise.
#
# fastavro + a snappy-compress binding are unavailable, so the snappy stream
# is hand-constructed (a single literal element for a small payload: snappy
# raw format = <uncompressed_len varint> <literal tag = (L-1)<<2> <L bytes>).
# This exercises the real libsnappy `snappy_uncompress` + CRC32 path.
# =============================================================================

from std.testing import assert_equal, assert_true

from komira_avro import read_avro_bytes, OCF_SYNC_LEN, crc32_ieee


def _enc_long(n: Int64, mut out: List[UInt8]):
    var zz = UInt64((n << 1) ^ (n >> 63))
    while True:
        var b = UInt8(zz & 0x7F)
        zz >>= 7
        if zz != 0:
            out.append(b | 0x80)
        else:
            out.append(b)
            break


def _str_bytes(s: String) -> List[UInt8]:
    var b = s.as_bytes()
    var out = List[UInt8]()
    for i in range(len(b)):
        out.append(b[i])
    return out^


def _enc_str(s: String, mut out: List[UInt8]):
    var b = s.as_bytes()
    _enc_long(Int64(len(b)), out)
    for i in range(len(b)):
        out.append(b[i])


def _enc_bytes(b: List[UInt8], mut out: List[UInt8]):
    _enc_long(Int64(len(b)), out)
    for i in range(len(b)):
        out.append(b[i])


def _sync() -> List[UInt8]:
    var s = List[UInt8]()
    for i in range(OCF_SYNC_LEN):
        s.append(UInt8(0xA0 + i))
    return s^


def _make_header_snappy(schema: String, mut out: List[UInt8]):
    out.append(UInt8(ord("O")))
    out.append(UInt8(ord("b")))
    out.append(UInt8(ord("j")))
    out.append(0x01)
    _enc_long(Int64(2), out)
    _enc_str(String("avro.schema"), out)
    _enc_bytes(_str_bytes(schema), out)
    _enc_str(String("avro.codec"), out)
    _enc_bytes(_str_bytes(String("snappy")), out)  # snappy codec
    _enc_long(Int64(0), out)
    var s = _sync()
    for i in range(len(s)):
        out.append(s[i])


def _snappy_compress_literal(raw: List[UInt8]) -> List[UInt8]:
    """Build a minimal valid snappy raw stream for a small payload (< 60 bytes)
    as a single literal element: <uncompressed_len varint> <(L-1)<<2 tag> bytes.
    """
    var out = List[UInt8]()
    # Preamble: uncompressed length as a base-128 varint (little-endian).
    var n = UInt64(len(raw))
    while True:
        var b = UInt8(n & 0x7F)
        n >>= 7
        if n != 0:
            out.append(b | 0x80)
        else:
            out.append(b)
            break
    # Single literal element. For L <= 60, tag = (L-1) << 2 (type bits 00).
    var L = len(raw)
    out.append(UInt8((L - 1) << 2))
    for i in range(L):
        out.append(raw[i])
    return out^


def _be4(crc: UInt32, mut out: List[UInt8]):
    out.append(UInt8((crc >> 24) & 0xFF))
    out.append(UInt8((crc >> 16) & 0xFF))
    out.append(UInt8((crc >> 8) & 0xFF))
    out.append(UInt8(crc & 0xFF))


def _append_snappy_block(
    mut out: List[UInt8], object_count: Int64, uncompressed: List[UInt8], good_crc: Bool
):
    var snappy = _snappy_compress_literal(uncompressed)
    var crc = crc32_ieee(Span(uncompressed))
    if not good_crc:
        crc = crc ^ UInt32(0xFFFFFFFF)  # corrupt the trailer
    var payload = List[UInt8]()
    for i in range(len(snappy)):
        payload.append(snappy[i])
    _be4(crc, payload)
    # Block framing: object_count + byte_count + payload + sync.
    _enc_long(object_count, out)
    _enc_long(Int64(len(payload)), out)
    for i in range(len(payload)):
        out.append(payload[i])
    var s = _sync()
    for i in range(len(s)):
        out.append(s[i])


comptime _SCHEMA_SNAPPY = String(
    '{"type":"record","name":"S","fields":['
    '{"name":"a","type":"long"},'
    '{"name":"b","type":"string"}]}'
)


def _record_bytes() -> List[UInt8]:
    """Encode 2 records of (long a, string b) as the uncompressed block body."""
    var p = List[UInt8]()
    _enc_long(Int64(7), p)
    _enc_str(String("foo"), p)
    _enc_long(Int64(13), p)
    _enc_str(String("bar"), p)
    return p^


def test_snappy_codec_decode() raises:
    """A snappy-coded block decodes after the BE4 CRC32 trailer is stripped +
    validated."""
    var buf = List[UInt8]()
    _make_header_snappy(_SCHEMA_SNAPPY, buf)
    _append_snappy_block(buf, Int64(2), _record_bytes(), True)

    var rb = read_avro_bytes(Span(buf))
    assert_equal(rb.num_rows(), 2, "2 rows")
    assert_equal(rb.num_columns(), 2, "2 cols")
    ref acol = rb.column_at(0)
    var aa = acol.as_primitive[DType.int64]()
    assert_equal(Int(aa.get(0)), 7, "a[0]")
    assert_equal(Int(aa.get(1)), 13, "a[1]")
    ref bcol = rb.column_at(1)
    var ba = bcol.as_string()
    assert_equal(ba.get(0), String("foo"), "b[0]")
    assert_equal(ba.get(1), String("bar"), "b[1]")


def test_snappy_bad_crc_raises() raises:
    """A corrupt BE4 CRC32 trailer must raise (the strip-and-validate gate)."""
    var buf = List[UInt8]()
    _make_header_snappy(_SCHEMA_SNAPPY, buf)
    _append_snappy_block(buf, Int64(2), _record_bytes(), False)  # bad CRC

    var raised = False
    try:
        var _rb = read_avro_bytes(Span(buf))
    except:
        raised = True
    assert_true(raised, "corrupt snappy CRC32 trailer must raise")


def main() raises:
    test_snappy_codec_decode()
    test_snappy_bad_crc_raises()
    print("test_avro_snappy_codec_decode: ALL PASS")
