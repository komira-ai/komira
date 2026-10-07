# =============================================================================
# test_avro_codec_owner_equivalence.mojo
# =============================================================================
#
# avro_codec.mojo calls komira_compression's codec API and declares no codec
# FFI of its own. This pins what that must not change:
#
#   * compress_block, for every codec and for three inputs (empty, 4 KiB of
#     incompressible bytes, ~600 bytes of repetitive text), is byte-equal to
#     komira_compression's codec called directly with the parameters the Avro
#     writer has always used: raw deflate at level 6, snappy plus the BE4
#     CRC-32 of the uncompressed bytes, zstd level 3, bzip2 with 900k blocks
#     and work factor 0, xz preset 6 with a CRC-64 check. The same file run
#     against the avro_codec.mojo that declared its own FFI passes too, so
#     the old and the new writer emit the same bytes.
#   * decompress_block of each of those blocks returns the input.
#   * a corrupt block of each codec is refused with the exact message: the
#     AvroCodecError code, then komira_compression's account of the failure.
#
# What it catches: a codec parameter changed in the move (a level, a window,
# a block size), a lost or misplaced CRC trailer, an output cut to the wrong
# length, and an error that drops the library's code or the sizes.
# =============================================================================

from std.testing import TestSuite, assert_equal

from komira_avro import (
    AVRO_CODEC_BZIP2,
    AVRO_CODEC_DEFLATE,
    AVRO_CODEC_NULL,
    AVRO_CODEC_SNAPPY,
    AVRO_CODEC_XZ,
    AVRO_CODEC_ZSTANDARD,
    compress_block,
    crc32_ieee,
    decompress_block,
)
from komira_compression.bzip2_buffer import bzip2_compress_into
from komira_compression.snappy_block import (
    snappy_compress_into,
    snappy_max_compressed_length,
)
from komira_compression.xz_buffer import xz_compress_into
from komira_compression.zlib import (
    ZLIB_WINDOW_BITS_RAW,
    zlib_compress_bound,
    zlib_deflate_into,
)
from komira_compression.zstd_frame import zstd_compress_bound, zstd_compress_into


def _corpus() -> List[List[UInt8]]:
    var out = List[List[UInt8]]()
    out.append(List[UInt8]())
    var noise = List[UInt8](capacity=4096)
    var state: UInt32 = 0x2545F491
    for _ in range(4096):
        state = state * UInt32(1103515245) + UInt32(12345)
        noise.append(UInt8((state >> 24) & 0xFF))
    out.append(noise^)
    var text = List[UInt8]()
    for r in range(40):
        var row = String("avro-equivalence-row-") + String(r % 7) + "|"
        for b in row.as_bytes():
            text.append(b)
    out.append(text^)
    return out^


def _cut(var buf: List[UInt8], n: Int) -> List[UInt8]:
    buf.resize(unsafe_uninit_length=n)
    return buf^


def _reference(tag: Int, src: List[UInt8]) raises -> List[UInt8]:
    """The block komira_compression makes for `src` with the Avro writer's
    parameters, built here without compress_block."""
    var n = len(src)
    if tag == AVRO_CODEC_NULL:
        return src.copy()
    if tag == AVRO_CODEC_DEFLATE:
        var out = List[UInt8](length=zlib_compress_bound(n, ZLIB_WINDOW_BITS_RAW), fill=0)
        var w = zlib_deflate_into(Span(out), Span(src), Int32(6), ZLIB_WINDOW_BITS_RAW)
        return _cut(out^, w)
    if tag == AVRO_CODEC_SNAPPY:
        var out = List[UInt8](length=snappy_max_compressed_length(n), fill=0)
        var w = snappy_compress_into(Span(out), Span(src))
        out = _cut(out^, w)
        var crc = crc32_ieee(Span(src))
        out.append(UInt8((crc >> 24) & 0xFF))
        out.append(UInt8((crc >> 16) & 0xFF))
        out.append(UInt8((crc >> 8) & 0xFF))
        out.append(UInt8(crc & 0xFF))
        return out^
    if tag == AVRO_CODEC_ZSTANDARD:
        var out = List[UInt8](length=zstd_compress_bound(n), fill=0)
        var w = zstd_compress_into(Span(out), Span(src), Int32(3))
        return _cut(out^, w)
    if tag == AVRO_CODEC_BZIP2:
        var out = List[UInt8](length=n + n // 100 + 1024, fill=0)
        var w = bzip2_compress_into(Span(out), Span(src), Int32(9), Int32(0))
        return _cut(out^, w)
    var out = List[UInt8](length=n + n // 3 + 1024, fill=0)
    var w = xz_compress_into(Span(out), Span(src), UInt32(6), Int32(4))
    return _cut(out^, w)


def _assert_same(got: List[UInt8], want: List[UInt8], what: String) raises:
    assert_equal(len(got), len(want), what + ": length")
    var first = -1
    for i in range(len(want)):
        if got[i] != want[i]:
            first = i
            break
    assert_equal(first, -1, what + ": first differing byte")


def test_compress_block_is_byte_equal_to_the_codec_api() raises:
    var tags: List[Int] = [
        AVRO_CODEC_NULL,
        AVRO_CODEC_DEFLATE,
        AVRO_CODEC_SNAPPY,
        AVRO_CODEC_ZSTANDARD,
        AVRO_CODEC_BZIP2,
        AVRO_CODEC_XZ,
    ]
    var corpus = _corpus()
    for t in range(len(tags)):
        for c in range(len(corpus)):
            var what = "codec " + String(tags[t]) + ", input " + String(c)
            var block = compress_block(tags[t], Span(corpus[c]))
            _assert_same(block, _reference(tags[t], corpus[c]), what)
            var back = decompress_block(tags[t], Span(block))
            _assert_same(back, corpus[c], what + " decoded")


def _refusal(tag: Int, block: List[UInt8]) -> String:
    try:
        _ = decompress_block(tag, Span(block))
    except e:
        return String(e)
    return "accepted"


def test_corrupt_blocks_are_refused_with_exact_messages() raises:
    # A snappy copy whose offset reaches before the output, then a trailer.
    var snappy: List[UInt8] = [4, 0x01, 0x05, 0, 0, 0, 0]
    assert_equal(
        _refusal(AVRO_CODEC_SNAPPY, snappy),
        "AvroCodecError.SNAPPY_UNCOMPRESS_FAILED: snappy_uncompress failed"
        " (status=1, input_len=3, output_cap=4)",
    )
    # Only a trailer: an empty snappy block has no length preamble.
    var trailer_only: List[UInt8] = [0, 0, 0, 0]
    assert_equal(
        _refusal(AVRO_CODEC_SNAPPY, trailer_only),
        "AvroCodecError.SNAPPY_LENGTH_FAILED",
    )
    # BFINAL=1 with the reserved block type 3: Z_DATA_ERROR.
    var deflate: List[UInt8] = [0x07, 0x00]
    assert_equal(
        _refusal(AVRO_CODEC_DEFLATE, deflate),
        "AvroCodecError.DEFLATE_FAILED: inflate rc -3",
    )
    # 16 bytes that are no codec's magic; the first output guess is 4096.
    var junk = List[UInt8](length=16, fill=0x58)
    assert_equal(
        _refusal(AVRO_CODEC_ZSTANDARD, junk),
        "AvroCodecError.ZSTD_FAILED: ZSTD_decompress failed (result=-10,"
        " input_len=16, output_cap=4096)",
    )
    assert_equal(
        _refusal(AVRO_CODEC_BZIP2, junk),
        "AvroCodecError.BZIP2_FAILED: BZ2_bzBuffToBuffDecompress failed"
        " (rc=-5, input_len=16, output_cap=4096)",
    )
    assert_equal(
        _refusal(AVRO_CODEC_XZ, junk),
        "AvroCodecError.XZ_FAILED: lzma_stream_buffer_decode failed (rc=7,"
        " input_len=16, output_cap=4096)",
    )


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
