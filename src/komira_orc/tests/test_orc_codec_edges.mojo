# =============================================================================
# test_orc_codec_edges.mojo — stream codec refusals, buffer-growth retries and
# the native LZO1X decoder's back-reference / limit refusals.
# =============================================================================
#
#   T1  decompress_stream refusals: a negative or above-1-GiB
#       compressionBlockSize, an unknown CompressionKind; compress_stream
#       refuses an unknown CompressionKind.
#   T2  Growth retries that end in success: LZ4 and zlib chunks decoded with a
#       4-byte compressionBlockSize start at the chunk's own length and double
#       until the chunk fits (the output equals the input).
#   T3  Malformed chunks are refused at the first attempt, without growing
#       the output buffer: a truncated LZ4 block, and a zstd frame with no
#       content size whose first block is corrupt.
#   T4  A zstd frame whose header declares 2 GiB is refused before any
#       allocation.
#   T5  Snappy: a block that declares fewer bytes than its own length (the
#       output buffer is the chunk length), and an unparseable length
#       preamble (falls back to the block size; the decode refuses it).
#   T6  LZO1X: a literal run of exactly the 1024-byte limit decodes, one of
#       1100 is refused; a limit below the floor is refused; a first-literal
#       -run match, an M1 match and an M2 match pointing before the block
#       start are each refused.
# =============================================================================

from std.testing import assert_equal, assert_true, assert_raises

from komira_orc import (
    decompress_stream,
    compress_stream,
    ORC_COMPRESSION_NONE,
    ORC_COMPRESSION_ZLIB,
    ORC_COMPRESSION_SNAPPY,
    ORC_COMPRESSION_LZO,
    ORC_COMPRESSION_LZ4,
    ORC_COMPRESSION_ZSTD,
)
from komira_orc.lzo1x_decompress import lzo1x_decompress


def _b(*vals: Int) -> List[UInt8]:
    var out = List[UInt8]()
    for i in range(len(vals)):
        out.append(UInt8(vals[i]))
    return out^


def _framed(payload: List[UInt8], is_original: Bool) -> List[UInt8]:
    """One ORC chunk: the 3-byte little-endian header, then the payload."""
    var h = (len(payload) << 1) | (1 if is_original else 0)
    var out = _b(h & 0xFF, (h >> 8) & 0xFF, (h >> 16) & 0xFF)
    for i in range(len(payload)):
        out.append(payload[i])
    return out^


def _pattern(n: Int) -> List[UInt8]:
    var out = List[UInt8]()
    for i in range(n):
        out.append(UInt8((i % 7) + 65))
    return out^


# -----------------------------------------------------------------------------
# T1 — refusals.
# -----------------------------------------------------------------------------


def test_stream_refusals() raises:
    var d = _framed(_b(1, 2, 3), True)
    with assert_raises(contains="BAD_BLOCK_SIZE: compressionBlockSize is negative (-1)"):
        _ = decompress_stream(Span(d), ORC_COMPRESSION_ZSTD, -1)
    with assert_raises(
        contains="BAD_BLOCK_SIZE: compressionBlockSize 1073741825 exceeds the maximum 1073741824"
    ):
        _ = decompress_stream(Span(d), ORC_COMPRESSION_ZSTD, (1 << 30) + 1)
    # Exactly 1 GiB is accepted (the chunk is stored, so nothing is allocated).
    var ok = decompress_stream(Span(d), ORC_COMPRESSION_ZSTD, 1 << 30)
    assert_equal(len(ok), 3)
    assert_equal(ok[2], 3)
    # A block size of 0 means "unset" (the 256 KiB default), not an error.
    var z = decompress_stream(Span(d), ORC_COMPRESSION_ZLIB, 0)
    assert_equal(len(z), 3)

    with assert_raises(contains="UNKNOWN_CODEC: codec 'UNKNOWN' is not a recognized ORC CompressionKind"):
        _ = decompress_stream(Span(d), 6, 1024)
    # A span of negative length: what `s[5:2]` yields where slicing is
    # unchecked (assertions off). Built directly, since this test's own
    # slicing asserts start <= end.
    # SAFETY: the span is never read; decompress_stream refuses it first.
    var inv = Span[UInt8, origin_of(d)](unsafe_ptr=d.unsafe_ptr(), length=-3)
    with assert_raises(contains="INVERTED_SPAN: stream span has negative length -3"):
        _ = decompress_stream(inv, ORC_COMPRESSION_NONE, 1024)
    with assert_raises(contains="UNKNOWN_CODEC: codec 'UNKNOWN' is not a recognized ORC CompressionKind"):
        _ = compress_stream(_b(1, 2, 3), 6)


# -----------------------------------------------------------------------------
# T2 — growth retries that succeed.
# -----------------------------------------------------------------------------


def test_growth_retries_succeed() raises:
    var data = _pattern(3000)
    for c in range(2):
        var codec = ORC_COMPRESSION_LZ4 if c == 0 else ORC_COMPRESSION_ZLIB
        var framed = compress_stream(data, codec)
        # The pattern compresses: one chunk, not stored verbatim.
        assert_true(len(framed) < 300)
        assert_equal(Int(framed[0]) & 1, 0)
        var back = decompress_stream(Span(framed), codec, 4)
        assert_equal(len(back), len(data))
        for i in range(len(data)):
            if back[i] != data[i]:
                raise Error("mismatch at byte " + String(i))


# -----------------------------------------------------------------------------
# T3 — malformed chunks refused at the first attempt.
# -----------------------------------------------------------------------------


def test_malformed_chunks_are_refused_without_growing() raises:
    # LZ4: a token promising a 15+ byte literal with no length byte after it.
    var lz4 = _framed(_b(0xF0), False)
    with assert_raises(contains="LZ4_TRUNCATED: the chunk ends inside an LZ4 sequence (in_len=1)"):
        _ = decompress_stream(Span(lz4), ORC_COMPRESSION_LZ4, 1024)

    # zstd: magic, a header with no content size (descriptor 0x00, window
    # 0x00), then a reserved block type (0b11) — corrupt at every size. The
    # refusal names the first attempt's 1024-byte buffer: no growth happened.
    var zs = _framed(_b(0x28, 0xB5, 0x2F, 0xFD, 0x00, 0x00, 0x07, 0x00, 0x00), False)
    with assert_raises(contains="ZSTD_FAILED: libzstd error 20 (in_len=9, out_cap=1024)"):
        _ = decompress_stream(Span(zs), ORC_COMPRESSION_ZSTD, 1024)


# -----------------------------------------------------------------------------
# T4 — zstd declared size above the ceiling.
# -----------------------------------------------------------------------------


def test_zstd_declared_size_ceiling() raises:
    # Single-segment header (0xE0: 8-byte content size), size 2^31.
    var zs = _framed(
        _b(0x28, 0xB5, 0x2F, 0xFD, 0xE0, 0x00, 0x00, 0x00, 0x80, 0, 0, 0, 0),
        False,
    )
    with assert_raises(
        contains="BAD_BLOCK_SIZE: zstd frame declares a decompressed size of 2147483648 bytes, above the maximum 1073741824"
    ):
        _ = decompress_stream(Span(zs), ORC_COMPRESSION_ZSTD, 1024)
    # The same header declaring 2^30 is not refused by the ceiling (the frame
    # is then incomplete, so the decode itself fails with the known size).
    var at = _framed(
        _b(0x28, 0xB5, 0x2F, 0xFD, 0xE0, 0x00, 0x00, 0x00, 0x40, 0, 0, 0, 0),
        False,
    )
    with assert_raises(contains="known_size=1073741824)"):
        _ = decompress_stream(Span(at), ORC_COMPRESSION_ZSTD, 1024)


# -----------------------------------------------------------------------------
# T5 — snappy sizing.
# -----------------------------------------------------------------------------


def test_snappy_sizing() raises:
    # Length 1, one literal byte 'A': a 3-byte block declaring 1 byte.
    var one = _framed(_b(0x01, 0x00, 0x41), False)
    var out = decompress_stream(Span(one), ORC_COMPRESSION_SNAPPY, 1)
    assert_equal(len(out), 1)
    assert_equal(out[0], 0x41)
    # A length varint that never terminates: no size, the decode refuses it.
    var bad = _framed(_b(0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF), False)
    with assert_raises(contains="SNAPPY_FAILED"):
        _ = decompress_stream(Span(bad), ORC_COMPRESSION_SNAPPY, 64)


# -----------------------------------------------------------------------------
# T6 — LZO1X.
# -----------------------------------------------------------------------------


def _lzo_literal_block(run: Int) -> List[UInt8]:
    """A TOP-state literal run of `run` bytes (run = t + 3, t extended over
    zero bytes of 255 each plus a final byte and the base 15), then the
    end-of-stream marker 11 00 00."""
    var t = run - 3
    var out = _b(0x00)
    var rest = t - 15
    while rest > 255:
        out.append(0)
        rest -= 255
    out.append(UInt8(rest))
    for i in range(run):
        out.append(UInt8(i & 0xFF))
    out.append(0x11)
    out.append(0x00)
    out.append(0x00)
    return out^


def test_lzo_limits_and_lookbehind() raises:
    var fits = _lzo_literal_block(1024)
    var out = List[UInt8]()
    lzo1x_decompress(Span(fits), 0, 1024, out)
    assert_equal(len(out), 1024)
    assert_equal(out[1023], 0xFF)
    assert_equal(out[256], 0)

    var over = _lzo_literal_block(1100)
    var out2 = List[UInt8]()
    with assert_raises(contains="OUTPUT_OVERRUN: block expands past the 1024-byte output limit"):
        lzo1x_decompress(Span(over), 0, 1024, out2)
    # Through the stream codec (a 1 GiB limit) the same block decodes.
    var via = decompress_stream(Span(_framed(over, False)), ORC_COMPRESSION_LZO, 64)
    assert_equal(len(via), 1100)

    with assert_raises(contains="BAD_LIMIT: output limit 1023 is below the 1024-byte floor"):
        lzo1x_decompress(Span(fits), 0, 1023, out2)

    # First literal run of 4 (first byte 21), then t=0: the far-M2 form
    # m = 4 - 2049 - 0 - 0.
    var flr = _b(21, 0x61, 0x62, 0x63, 0x64, 0x00, 0x00)
    with assert_raises(
        contains="LOOKBEHIND_OVERRUN: first-literal-run match at output offset 4 points 2045 byte(s) before the start of the block"
    ):
        lzo1x_decompress(Span(flr), 0, 4096, out2)

    # First byte 18: one literal then a match (MATCH_NEXT); t=0 is an M1,
    # m = 1 - 1 - 0 - (1 << 2).
    var m1 = _b(18, 0x61, 0x00, 0x01)
    with assert_raises(
        contains="LOOKBEHIND_OVERRUN: M1 match at output offset 1 points 4 byte(s) before the start of the block"
    ):
        lzo1x_decompress(Span(m1), 0, 4096, out2)

    # First literal run of 4, then an M2 (t=64): m = 4 - 1 - 0 - (1 << 3).
    var m2 = _b(21, 0x61, 0x62, 0x63, 0x64, 0x40, 0x01)
    with assert_raises(
        contains="LOOKBEHIND_OVERRUN: match at output offset 4 points 5 byte(s) before the start of the block"
    ):
        lzo1x_decompress(Span(m2), 0, 4096, out2)
    # The same M2 at distance 4 (offset byte 0, low bits 3 << 2 = 12):
    # m = 4 - 1 - 3 - 0 = 0, a 3-byte copy of "abc".
    var m2ok = _b(21, 0x61, 0x62, 0x63, 0x64, 0x4C, 0x00, 0x11, 0x00, 0x00)
    var ok = List[UInt8]()
    lzo1x_decompress(Span(m2ok), 0, 4096, ok)
    assert_equal(len(ok), 7)
    assert_equal(ok[4], 0x61)
    assert_equal(ok[6], 0x63)


def main() raises:
    test_stream_refusals()
    test_growth_retries_succeed()
    test_malformed_chunks_are_refused_without_growing()
    test_zstd_declared_size_ceiling()
    test_snappy_sizing()
    test_lzo_limits_and_lookbehind()
    print("test_orc_codec_edges: ALL PASS")
