# =============================================================================
# test_avro_codec_matrix.mojo — full Avro read codec matrix.
# =============================================================================
#
# Round-trip tests for
# all 6 officially-spec Avro codecs (null/deflate/snappy/bzip2/xz/zstandard)
# plus 3 wire-detail guards:
#   - test_codec_zstd_wire_name_zstandard — "zstandard" accepted, "zstd" rejected.
#   - test_codec_deflate_raw_rfc1951_not_zlib_wrapped — raw deflate decodes,
#     zlib-wrapped payload does NOT (proves inflateInit2(-15)).
#   - test_codec_snappy_be4_crc32_trailer — strip-and-validate (regression guard).
#
# Fixtures: no Java DataFileWriter is needed: each compressed
# fixture is built IN-TEST by calling the same C library's compress entry
# through komira_compression's codec API, not through avro's compress_block.
# This exercises both directions (compress in-test, decompress through
# decompress_block).
# =============================================================================

from std.testing import assert_equal, assert_true

from komira_avro import (
    decompress_block,
    codec_tag_from_wire_name,
    AVRO_CODEC_NULL,
    AVRO_CODEC_DEFLATE,
    AVRO_CODEC_SNAPPY,
    AVRO_CODEC_BZIP2,
    AVRO_CODEC_XZ,
    AVRO_CODEC_ZSTANDARD,
    crc32_ieee,
)
from komira_compression.bzip2_buffer import bzip2_compress_into
from komira_compression.xz_buffer import (
    XZ_CHECK_CRC64,
    XZ_PRESET_DEFAULT,
    xz_compress_into,
)
from komira_compression.zlib import (
    ZLIB_WINDOW_BITS_RAW,
    ZLIB_WINDOW_BITS_ZLIB,
    zlib_compress_bound,
    zlib_deflate_into,
)
from komira_compression.zstd_frame import zstd_compress_bound, zstd_compress_into


def _sample_payload() -> List[UInt8]:
    """A compressible ~600-byte payload (repeats so every codec shrinks it)."""
    var out = List[UInt8]()
    for r in range(60):
        var base = String("avro-codec-row-") + String(r) + String("|")
        var b = base.as_bytes()
        for i in range(len(b)):
            out.append(b[i])
    return out^


def _assert_roundtrip(decompressed: List[UInt8], original: List[UInt8]) raises:
    assert_equal(len(decompressed), len(original), "length matches")
    for i in range(len(original)):
        assert_equal(
            Int(decompressed[i]), Int(original[i]), "byte " + String(i)
        )


# =============================================================================
# null
# =============================================================================
def test_codec_null_roundtrip() raises:
    var raw = _sample_payload()
    var out = decompress_block(AVRO_CODEC_NULL, Span(raw))
    _assert_roundtrip(out, raw)


# =============================================================================
# snappy (raw_snappy ‖ BE4 crc32(uncompressed))
# =============================================================================
def _snappy_compress_literal(raw: List[UInt8]) -> List[UInt8]:
    """Minimal valid snappy raw stream for a payload as a single literal run.

    For runs > 60 bytes, snappy uses a 1-byte tag with the literal-length
    encoded in the following 1-2 bytes (tag value 60/61 => 1/2 trailing bytes).
    """
    var out = List[UInt8]()
    var n = UInt64(len(raw))
    while True:
        var b = UInt8(n & 0x7F)
        n >>= 7
        if n != 0:
            out.append(b | 0x80)
        else:
            out.append(b)
            break
    var L = len(raw)
    if L <= 60:
        out.append(UInt8((L - 1) << 2))
    elif L < 256:
        out.append(UInt8(60 << 2))  # tag type 00, len-of-len = 1 byte
        out.append(UInt8(L - 1))
    else:
        out.append(UInt8(61 << 2))  # 2 trailing length bytes
        out.append(UInt8((L - 1) & 0xFF))
        out.append(UInt8(((L - 1) >> 8) & 0xFF))
    for i in range(L):
        out.append(raw[i])
    return out^


def _be4(crc: UInt32, mut out: List[UInt8]):
    out.append(UInt8((crc >> 24) & 0xFF))
    out.append(UInt8((crc >> 16) & 0xFF))
    out.append(UInt8((crc >> 8) & 0xFF))
    out.append(UInt8(crc & 0xFF))


def test_codec_snappy_roundtrip() raises:
    var raw = _sample_payload()
    var payload = _snappy_compress_literal(raw)
    var crc = crc32_ieee(Span(raw))
    _be4(crc, payload)
    var out = decompress_block(AVRO_CODEC_SNAPPY, Span(payload))
    _assert_roundtrip(out, raw)


def test_codec_snappy_be4_crc32_trailer() raises:
    """Regression guard: the BE4 CRC32 trailer is stripped and
    validated; a corrupt trailer must raise."""
    var raw = _sample_payload()
    # Good CRC decodes.
    var good = _snappy_compress_literal(raw)
    var crc = crc32_ieee(Span(raw))
    _be4(crc, good)
    var out = decompress_block(AVRO_CODEC_SNAPPY, Span(good))
    _assert_roundtrip(out, raw)

    # Corrupt CRC must raise.
    var bad = _snappy_compress_literal(raw)
    _be4(crc ^ UInt32(0xFFFFFFFF), bad)
    var raised = False
    try:
        var _x = decompress_block(AVRO_CODEC_SNAPPY, Span(bad))
    except:
        raised = True
    assert_true(raised, "corrupt BE4 CRC32 trailer must raise")


# =============================================================================
# deflate — RAW RFC-1951 (compress in-test, level 6, windowBits -15).
# =============================================================================


def _deflate(raw: List[UInt8], window_bits: Int32) raises -> List[UInt8]:
    var out = List[UInt8](length=zlib_compress_bound(len(raw), window_bits), fill=0)
    var n = zlib_deflate_into(Span(out), Span(raw), Int32(6), window_bits)
    out.resize(unsafe_uninit_length=n)
    return out^


def _deflate_raw_compress(raw: List[UInt8]) raises -> List[UInt8]:
    """RAW RFC-1951 deflate of `raw` (windowBits -15)."""
    return _deflate(raw, ZLIB_WINDOW_BITS_RAW)


def _zlib_wrapped_compress(raw: List[UInt8]) raises -> List[UInt8]:
    """ZLIB-WRAPPED deflate (windowBits=+15) — has 0x78 header + ADLER32. Used
    by the negative-case wire-detail test to prove the reader is raw-only."""
    return _deflate(raw, ZLIB_WINDOW_BITS_ZLIB)


def test_codec_deflate_roundtrip() raises:
    var raw = _sample_payload()
    var payload = _deflate_raw_compress(raw)
    var out = decompress_block(AVRO_CODEC_DEFLATE, Span(payload))
    _assert_roundtrip(out, raw)


def test_codec_deflate_raw_rfc1951_not_zlib_wrapped() raises:
    """Raw RFC-1951 payload decodes; a zlib-WRAPPED payload does NOT — proves
    the reader uses inflateInit2(-15), not the default zlib-wrapped init."""
    var raw = _sample_payload()

    # (1) Raw deflate decodes correctly.
    var raw_payload = _deflate_raw_compress(raw)
    var out = decompress_block(AVRO_CODEC_DEFLATE, Span(raw_payload))
    _assert_roundtrip(out, raw)

    # (2) The raw payload must NOT begin with a zlib header byte (0x78).
    assert_true(
        raw_payload[0] != UInt8(0x78),
        "raw RFC-1951 deflate has no 0x78 zlib header",
    )

    # (3) A zlib-wrapped payload (0x78 header + ADLER32) must FAIL through the
    # raw (-15) reader. zlib's header bytes are not valid raw-deflate, so
    # inflate(-15) raises.
    var wrapped = _zlib_wrapped_compress(raw)
    assert_true(
        wrapped[0] == UInt8(0x78),
        "zlib-wrapped payload starts with the 0x78 header byte",
    )
    var raised = False
    try:
        var _x = decompress_block(AVRO_CODEC_DEFLATE, Span(wrapped))
    except:
        raised = True
    assert_true(
        raised, "zlib-wrapped payload must fail through inflateInit2(-15)"
    )


# =============================================================================
# zstandard — libzstd ZSTD_compress (compress in-test, level 3).
# =============================================================================
def _zstd_compress(raw: List[UInt8]) raises -> List[UInt8]:
    var out = List[UInt8](length=zstd_compress_bound(len(raw)), fill=0)
    var n = zstd_compress_into(Span(out), Span(raw), Int32(3))
    out.resize(unsafe_uninit_length=n)
    return out^


def test_codec_zstd_roundtrip() raises:
    var raw = _sample_payload()
    var payload = _zstd_compress(raw)
    var out = decompress_block(AVRO_CODEC_ZSTANDARD, Span(payload))
    _assert_roundtrip(out, raw)


def test_codec_zstd_wire_name_zstandard() raises:
    """"zstandard" maps to the zstd codec; "zstd" shorthand is rejected."""
    var tag = codec_tag_from_wire_name(String("zstandard"))
    assert_equal(tag, AVRO_CODEC_ZSTANDARD, "'zstandard' -> ZSTANDARD tag")

    var raised = False
    try:
        var _t = codec_tag_from_wire_name(String("zstd"))
    except:
        raised = True
    assert_true(raised, "'zstd' shorthand must be rejected (not spec wire name)")


# =============================================================================
# bzip2 — libbz2 BZ2_bzBuffToBuffCompress (compress in-test).
# =============================================================================
def _bzip2_compress(raw: List[UInt8]) raises -> List[UInt8]:
    # bzip2 worst case: source + 1% + 600 bytes.
    var out = List[UInt8](length=len(raw) + len(raw) // 100 + 600, fill=0)
    var n = bzip2_compress_into(Span(out), Span(raw), Int32(9), Int32(0))
    out.resize(unsafe_uninit_length=n)
    return out^


def test_codec_bzip2_roundtrip() raises:
    var raw = _sample_payload()
    var payload = _bzip2_compress(raw)
    var out = decompress_block(AVRO_CODEC_BZIP2, Span(payload))
    _assert_roundtrip(out, raw)


# =============================================================================
# xz — liblzma lzma_easy_buffer_encode (compress in-test).
# =============================================================================
def _xz_compress(raw: List[UInt8]) raises -> List[UInt8]:
    var out = List[UInt8](length=len(raw) + len(raw) // 3 + 1024, fill=0)
    var n = xz_compress_into(
        Span(out), Span(raw), XZ_PRESET_DEFAULT, XZ_CHECK_CRC64
    )
    out.resize(unsafe_uninit_length=n)
    return out^


def test_codec_xz_roundtrip() raises:
    var raw = _sample_payload()
    var payload = _xz_compress(raw)
    var out = decompress_block(AVRO_CODEC_XZ, Span(payload))
    _assert_roundtrip(out, raw)


def main() raises:
    test_codec_null_roundtrip()
    test_codec_snappy_roundtrip()
    test_codec_snappy_be4_crc32_trailer()
    test_codec_deflate_roundtrip()
    test_codec_deflate_raw_rfc1951_not_zlib_wrapped()
    test_codec_zstd_roundtrip()
    test_codec_zstd_wire_name_zstandard()
    test_codec_bzip2_roundtrip()
    test_codec_xz_roundtrip()
    print("test_avro_codec_matrix: ALL PASS")
