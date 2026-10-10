# =============================================================================
# test_avro_codec_truncation.mojo -- `decompress_block` reports a truncated
# deflate or xz block as truncated, and still grows its output buffer for a
# whole block that decodes past the first guess.
# =============================================================================
#
# What each case proves, and the defect it catches:
#   T1  a deflate block and an xz block of 5000 bytes cut to half their
#       length are refused as DEFLATE_TRUNCATED / XZ_TRUNCATED (exact
#       messages). Catches the decoder that read a short stream as "output
#       buffer too small", quadrupled the buffer up to 2 GiB and then
#       reported DEFLATE_OUTPUT_OVERFLOW / XZ_OUTPUT_OVERFLOW.
#   T2  every proper prefix of those two blocks (a cut at each length from
#       1 to len - 1) is refused as truncated, so no cut point (inside the
#       xz header, between blocks, inside the stream footer, the last byte
#       of the deflate stream) falls back to the grow loop.
#   T3  whole blocks of 1 MiB (256 times the first 4096-byte guess for the
#       deflate block, which compresses to a few KiB) decode to the input,
#       for deflate and xz; and the deflate block cut to 90% of its length,
#       whose first attempt fills the first guess before the input runs
#       out, is still refused as truncated. Catches a fix that treats every
#       stop short of the stream's end as truncation and so refuses a block
#       that only needed a larger buffer. Mutant: deflate raises TRUNCATED
#       whenever rc != Z_STREAM_END: red, the 1 MiB deflate block refused.
#   T4  bytes with no xz header magic are still refused by liblzma
#       (XZ_FAILED, rc=7), not reported as truncated; an xz block whose
#       footer magic or footer CRC-32 is damaged is refused as truncated
#       (it does not end with a valid stream footer). Mutant: drop the
#       footer CRC-32 comparison: red, the damaged-CRC block is passed to
#       liblzma and refused with XZ_FAILED instead.
#   T5  a whole xz block followed by Stream Padding (4 or 8 zero bytes, which
#       the .xz format allows after a stream) still decodes to the input, as
#       it did before the footer check existed. Catches a footer check that
#       looks only at the last 12 bytes. Other trailing bytes (2 zero bytes,
#       which is not a multiple of 4; a 4-byte group with one non-zero byte at
#       either end) and a cut block followed by 4 zero bytes are refused as
#       XZ_TRUNCATED: this reader accepts only one stream plus Stream Padding.
#       Mutants: drop the padding skip: red, the +4 zero block refused; skip
#       zero bytes one at a time: red, the +2 zero block accepted; test only
#       the last byte of each 4-byte group: red, the 01 00 00 00 block
#       accepted; test only the first byte: red earlier, since the footer's
#       Stream Flags start with a zero byte, so the skip eats into the footer
#       and every whole xz block is refused.
# =============================================================================

from std.testing import assert_equal, assert_true

from komira_avro import (
    AVRO_CODEC_DEFLATE,
    AVRO_CODEC_XZ,
    compress_block,
    decompress_block,
)


comptime _DEFLATE_TRUNC = String(
    "AvroCodecError.DEFLATE_TRUNCATED: the deflate stream ends before its"
    " final block does"
)
comptime _XZ_TRUNC = String(
    "AvroCodecError.XZ_TRUNCATED: the block does not end with an xz stream"
    " footer"
)


def _raw(n: Int) -> List[UInt8]:
    var raw = List[UInt8](capacity=n)
    for i in range(n):
        raw.append(UInt8((i * 7919) % 251))
    return raw^


def _refusal(tag: Int, block: List[UInt8]) -> String:
    try:
        _ = decompress_block(tag, Span(block))
    except e:
        return String(e)
    return "(accepted)"


def _prefix(block: List[UInt8], n: Int) -> List[UInt8]:
    var out = List[UInt8](capacity=n)
    out.extend(Span(block)[0:n])
    return out^


def test_half_block_is_truncated() raises:
    """T1."""
    var raw = _raw(5000)
    var d = compress_block(AVRO_CODEC_DEFLATE, Span(raw))
    var x = compress_block(AVRO_CODEC_XZ, Span(raw))
    # Both answers are taken before either is checked, so a failure shows
    # the two codecs' messages side by side.
    var got = (
        _refusal(AVRO_CODEC_DEFLATE, _prefix(d, len(d) // 2))
        + " | "
        + _refusal(AVRO_CODEC_XZ, _prefix(x, len(x) // 2))
    )
    assert_equal(got, _DEFLATE_TRUNC + " | " + _XZ_TRUNC)


def test_every_prefix_is_truncated() raises:
    """T2."""
    var raw = _raw(5000)
    var d = compress_block(AVRO_CODEC_DEFLATE, Span(raw))
    var x = compress_block(AVRO_CODEC_XZ, Span(raw))
    for n in range(1, len(d)):
        assert_equal(
            _refusal(AVRO_CODEC_DEFLATE, _prefix(d, n)),
            _DEFLATE_TRUNC,
            "deflate cut at " + String(n),
        )
    for n in range(1, len(x)):
        assert_equal(
            _refusal(AVRO_CODEC_XZ, _prefix(x, n)),
            _XZ_TRUNC,
            "xz cut at " + String(n),
        )


def _assert_round_trip(tag: Int, raw: List[UInt8]) raises:
    var c = compress_block(tag, Span(raw))
    var back = decompress_block(tag, Span(c))
    assert_equal(len(back), len(raw), "codec " + String(tag) + " length")
    for i in range(len(raw)):
        if back[i] != raw[i]:
            assert_equal(back[i], raw[i], "byte " + String(i))


def test_large_blocks_still_grow() raises:
    """T3."""
    var raw = _raw(1 << 20)
    _assert_round_trip(AVRO_CODEC_DEFLATE, raw)
    _assert_round_trip(AVRO_CODEC_XZ, raw)
    var d = compress_block(AVRO_CODEC_DEFLATE, Span(raw))
    # The first output guess (4 x the block) is far below 1 MiB, so the
    # whole block decodes only after the buffer grows.
    assert_true(len(d) * 4 * 16 < len(raw), "deflate block must grow")
    assert_equal(
        _refusal(AVRO_CODEC_DEFLATE, _prefix(d, len(d) * 9 // 10)),
        _DEFLATE_TRUNC,
    )


def test_xz_footer_checks() raises:
    """T4."""
    var junk = List[UInt8](length=16, fill=0x58)
    assert_equal(
        _refusal(AVRO_CODEC_XZ, junk),
        "AvroCodecError.XZ_FAILED: lzma_stream_buffer_decode failed (rc=7,"
        " input_len=16, output_cap=4096)",
    )
    var x = compress_block(AVRO_CODEC_XZ, Span(_raw(5000)))
    var n = len(x)
    var bad_magic = x.copy()
    bad_magic[n - 1] = UInt8(ord("Q"))
    assert_equal(_refusal(AVRO_CODEC_XZ, bad_magic), _XZ_TRUNC)
    var bad_crc = x.copy()
    bad_crc[n - 12] = bad_crc[n - 12] ^ 0x01
    assert_equal(_refusal(AVRO_CODEC_XZ, bad_crc), _XZ_TRUNC)


def _with_tail(block: List[UInt8], tail: List[UInt8]) -> List[UInt8]:
    var out = block.copy()
    out.extend(Span(tail))
    return out^


def test_xz_stream_padding() raises:
    """T5."""
    var raw = _raw(5000)
    var x = compress_block(AVRO_CODEC_XZ, Span(raw))
    for pad in [4, 8]:
        var padded = _with_tail(x, List[UInt8](length=pad, fill=0))
        var back = decompress_block(AVRO_CODEC_XZ, Span(padded))
        assert_equal(len(back), len(raw), "xz + " + String(pad) + " zero")
        for i in range(len(raw)):
            if back[i] != raw[i]:
                assert_equal(back[i], raw[i], "byte " + String(i))
    assert_equal(
        _refusal(AVRO_CODEC_XZ, _with_tail(x, List[UInt8](length=2, fill=0))),
        _XZ_TRUNC,
        "xz + 2 zero",
    )
    var lead: List[UInt8] = [1, 0, 0, 0]
    assert_equal(
        _refusal(AVRO_CODEC_XZ, _with_tail(x, lead)),
        _XZ_TRUNC,
        "xz + 01 00 00 00",
    )
    var trail: List[UInt8] = [0, 0, 0, 1]
    assert_equal(
        _refusal(AVRO_CODEC_XZ, _with_tail(x, trail)),
        _XZ_TRUNC,
        "xz + 00 00 00 01",
    )
    assert_equal(
        _refusal(
            AVRO_CODEC_XZ,
            _with_tail(_prefix(x, len(x) // 2), List[UInt8](length=4, fill=0)),
        ),
        _XZ_TRUNC,
        "half xz + 4 zero",
    )


def main() raises:
    test_half_block_is_truncated()
    test_every_prefix_is_truncated()
    test_large_blocks_still_grow()
    test_xz_footer_checks()
    test_xz_stream_padding()
    print("test_avro_codec_truncation: ALL PASS")
