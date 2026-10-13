# =============================================================================
# test_orc_codec_chunk_refusals.mojo: a truncated or corrupt compressed chunk
# is refused at the first attempt; only a full output buffer is grown.
# =============================================================================
#
# `decompress_stream` sizes each chunk's output buffer at the PostScript
# compressionBlockSize (4096 here) and grows it when a chunk decodes to more.
# The zlib, LZ4 and zstd (unknown content size) decoders used to read every
# failure as "buffer too small":
#   - zlib: a chunk cut short (inflate stops with Z_OK and output space left)
#     decoded silently to fewer bytes, and a corrupt one (Z_DATA_ERROR) or an
#     empty one was retried with a doubled buffer up to 1 GiB;
#   - LZ4 and zstd: any decoder error was retried the same way.
#
# What each test proves, and the defect it catches:
#   - test_zlib_truncated_chunk_is_refused: a raw-deflate chunk cut in half
#     raises ZLIB_TRUNCATED (the old code returned the partial output).
#   - test_zlib_empty_chunk_is_refused_as_truncated: a zero-length compressed
#     chunk raises ZLIB_TRUNCATED (the old code grew to 1 GiB first).
#   - test_zlib_corrupt_chunk_is_refused_without_growing: a reserved block
#     type raises inflate rc=-3 at out_cap=4096 (the old code reported it at
#     out_cap=1073741824 after eighteen retries).
#   - test_zlib_chunk_larger_than_block_size_still_grows: 10000 bytes through
#     a 4096-byte block size decode in full (a fix that refused a full buffer,
#     or read Z_OK with no space left as truncation, fails here).
#   - test_lz4_truncated_chunk_is_refused: an LZ4 block missing its last
#     three bytes raises LZ4_TRUNCATED (the old code: retry-cap-exceeded).
#   - test_lz4_corrupt_chunk_is_refused_without_growing: a block whose match
#     offset points before the output's start is refused with liblz4's error
#     at output_cap=4096.
#   - test_lz4_chunk_larger_than_block_size_still_grows: 20000 bytes through a
#     4096-byte block size decode in full.
#   - test_zstd_unknown_size_truncated_chunk_is_refused: a frame without a
#     content size whose raw block runs past the chunk raises ZSTD_TRUNCATED.
#   - test_zstd_unknown_size_corrupt_chunk_is_refused_without_growing: a
#     reserved block type raises zstd error 20 at out_cap=4096.
#   - test_zstd_unknown_size_chunk_larger_than_block_size_still_grows: an RLE
#     block of 10000 bytes in a frame without a content size decodes in full
#     (a fix that refused libzstd's dstSize_tooSmall fails here).
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_true

from komira_compression.lz4 import lz4_compress_bound, lz4_compress_into
from komira_compression.zlib import zlib_compress_bound, zlib_deflate_into

from komira_orc import (
    decompress_stream,
    ORC_COMPRESSION_LZ4,
    ORC_COMPRESSION_ZLIB,
    ORC_COMPRESSION_ZSTD,
)

comptime _BLOCK: Int = 4096


def _chunk(payload: List[UInt8]) -> List[UInt8]:
    """`payload` as one compressed (isOriginal=0) ORC chunk."""
    var header = len(payload) << 1
    var out = List[UInt8]()
    out.append(UInt8(header & 0xFF))
    out.append(UInt8((header >> 8) & 0xFF))
    out.append(UInt8((header >> 16) & 0xFF))
    out.extend(Span(payload))
    return out^


def _pattern(n: Int) -> List[UInt8]:
    """`n` compressible bytes: a short repeating cycle."""
    var out = List[UInt8](capacity=n)
    for i in range(n):
        out.append(UInt8(97 + (i % 7)))
    return out^


def _deflate_raw(src: List[UInt8]) raises -> List[UInt8]:
    var out = List[UInt8](length=zlib_compress_bound(len(src), -15), fill=0)
    var n = zlib_deflate_into(Span(out), Span(src), Int32(6), Int32(-15))
    out.resize(unsafe_uninit_length=n)
    return out^


def _lz4(src: List[UInt8]) raises -> List[UInt8]:
    var out = List[UInt8](length=lz4_compress_bound(len(src)), fill=0)
    var n = lz4_compress_into(Span(out), Span(src))
    out.resize(unsafe_uninit_length=n)
    return out^


def _prefix(src: List[UInt8], n: Int) -> List[UInt8]:
    var out = List[UInt8]()
    out.extend(Span(src)[0:n])
    return out^


def _refusal(stream: List[UInt8], codec: Int) -> String:
    """The message `decompress_stream` raises, or "" when it returns."""
    try:
        _ = decompress_stream(Span(stream), codec, _BLOCK)
    except e:
        return String(e)
    return String("")


def _zstd_unknown_size_frame(var blocks: List[UInt8]) -> List[UInt8]:
    """A zstd frame whose header omits the content size: magic, frame header
    descriptor 0x00 (no content size, not single-segment), window descriptor
    0x38 (a 128 KiB window), then `blocks`."""
    var out = List[UInt8]()
    out.append(0x28)
    out.append(0xB5)
    out.append(0x2F)
    out.append(0xFD)
    out.append(0x00)
    out.append(0x38)
    out.extend(Span(blocks))
    return out^


def _block_header(last: Bool, block_type: Int, size: Int) -> List[UInt8]:
    var word = (1 if last else 0) | (block_type << 1) | (size << 3)
    var out = List[UInt8]()
    out.append(UInt8(word & 0xFF))
    out.append(UInt8((word >> 8) & 0xFF))
    out.append(UInt8((word >> 16) & 0xFF))
    return out^


# -----------------------------------------------------------------------------
# zlib (raw deflate)
# -----------------------------------------------------------------------------


def test_zlib_truncated_chunk_is_refused() raises:
    var packed = _deflate_raw(_pattern(300))
    var stream = _chunk(_prefix(packed, len(packed) // 2))
    var msg = _refusal(stream, ORC_COMPRESSION_ZLIB)
    assert_true(
        msg.startswith("OrcCodecError.ZLIB_TRUNCATED:"),
        "a truncated zlib chunk must be refused, got: '" + msg + "'",
    )


def test_zlib_empty_chunk_is_refused_as_truncated() raises:
    var msg = _refusal(_chunk(List[UInt8]()), ORC_COMPRESSION_ZLIB)
    assert_true(msg.startswith("OrcCodecError.ZLIB_TRUNCATED:"), msg)


def test_zlib_corrupt_chunk_is_refused_without_growing() raises:
    # 0x07: BFINAL=1, BTYPE=11 (reserved), so inflate answers Z_DATA_ERROR.
    var bad = List[UInt8]()
    bad.append(0x07)
    var msg = _refusal(_chunk(bad), ORC_COMPRESSION_ZLIB)
    assert_equal(
        msg,
        "OrcCodecError.ZLIB_FAILED: inflate rc=-3 (in_len=1, out_cap=4096)",
    )


def test_zlib_chunk_larger_than_block_size_still_grows() raises:
    var data = _pattern(10000)
    var out = decompress_stream(
        Span(_chunk(_deflate_raw(data))), ORC_COMPRESSION_ZLIB, _BLOCK
    )
    assert_true(out == data)


# -----------------------------------------------------------------------------
# LZ4 (raw block)
# -----------------------------------------------------------------------------


def test_lz4_truncated_chunk_is_refused() raises:
    # An LZ4 block ends in a run of at least five literals: cutting three
    # bytes leaves that run's declared length past the chunk's end.
    var packed = _lz4(_pattern(300))
    var stream = _chunk(_prefix(packed, len(packed) - 3))
    var msg = _refusal(stream, ORC_COMPRESSION_LZ4)
    assert_true(
        msg.startswith("OrcCodecError.LZ4_TRUNCATED:"),
        "a truncated LZ4 chunk must be refused, got: '" + msg + "'",
    )


def test_lz4_corrupt_chunk_is_refused_without_growing() raises:
    # Sequence 1: one literal 'a', then a match at offset 5 (four bytes
    # before the output's start). Sequence 2: five literals. The block is
    # whole (it declares 10 bytes) but its match is out of range.
    var bad = List[UInt8]()
    bad.append(0x10)
    bad.append(0x61)
    bad.append(0x05)
    bad.append(0x00)
    bad.append(0x50)
    for _ in range(5):
        bad.append(0x62)
    var msg = _refusal(_chunk(bad), ORC_COMPRESSION_LZ4)
    assert_true(msg.startswith("OrcCodecError.LZ4_FAILED:"), msg)
    assert_true(msg.endswith("input_len=10, output_cap=4096)"), msg)


def test_lz4_chunk_larger_than_block_size_still_grows() raises:
    var data = _pattern(20000)
    var out = decompress_stream(
        Span(_chunk(_lz4(data))), ORC_COMPRESSION_LZ4, _BLOCK
    )
    assert_true(out == data)


# -----------------------------------------------------------------------------
# zstd, frame without a content size
# -----------------------------------------------------------------------------


def test_zstd_unknown_size_truncated_chunk_is_refused() raises:
    # A raw block declaring 100 bytes, with 10 present.
    var blocks = _block_header(True, 0, 100)
    for _ in range(10):
        blocks.append(0x41)
    var msg = _refusal(
        _chunk(_zstd_unknown_size_frame(blocks^)), ORC_COMPRESSION_ZSTD
    )
    assert_true(
        msg.startswith("OrcCodecError.ZSTD_TRUNCATED:"),
        "a truncated zstd chunk must be refused, got: '" + msg + "'",
    )


def test_zstd_unknown_size_corrupt_chunk_is_refused_without_growing() raises:
    # Block type 3 is reserved: libzstd answers corruption_detected (20).
    var msg = _refusal(
        _chunk(_zstd_unknown_size_frame(_block_header(True, 3, 0))),
        ORC_COMPRESSION_ZSTD,
    )
    assert_equal(
        msg,
        "OrcCodecError.ZSTD_FAILED: libzstd error 20 (in_len=9, out_cap=4096)",
    )


def test_zstd_unknown_size_chunk_larger_than_block_size_still_grows() raises:
    # One RLE block: 10000 copies of 'z'.
    var blocks = _block_header(True, 1, 10000)
    blocks.append(0x7A)
    var out = decompress_stream(
        Span(_chunk(_zstd_unknown_size_frame(blocks^))),
        ORC_COMPRESSION_ZSTD,
        _BLOCK,
    )
    assert_equal(len(out), 10000)
    for i in range(len(out)):
        assert_equal(out[i], UInt8(0x7A))


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
