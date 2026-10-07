# =============================================================================
# test_orc_codec_owner_equivalence.mojo
# =============================================================================
#
# orc_codec.mojo calls komira_compression's codec API and declares no codec
# FFI of its own. This pins what that must not change:
#
#   * compress_stream, for ZLIB, SNAPPY, LZ4 and ZSTD and for four inputs
#     (empty, 4 KiB of incompressible bytes, ~600 bytes of repetitive text,
#     and 300 KiB of text, which is two chunks), is byte-equal to the stream
#     built here from komira_compression's codecs with the parameters the ORC
#     writer has always used: 256 KiB chunks, each behind the 3-byte header
#     and stored verbatim when compressing does not shrink it, raw deflate at
#     level 6, snappy, LZ4_compress_default, zstd level 3. The same file run
#     against the orc_codec.mojo that declared its own FFI passes too, so the
#     old and the new writer emit the same bytes.
#   * decompress_stream of each of those streams returns the input.
#   * a corrupt snappy chunk and a truncated zstd chunk are refused with the
#     exact message: the OrcCodecError code, then komira_compression's
#     account of the failure.
#
# What it catches: a codec parameter changed in the move, a chunk boundary
# or header moved, the verbatim-chunk rule lost, an output cut to the wrong
# length, and an error that drops the library's code or the sizes.
# =============================================================================

from std.testing import TestSuite, assert_equal

from komira_compression.lz4 import lz4_compress_bound, lz4_compress_into
from komira_compression.snappy_block import (
    snappy_compress_into,
    snappy_max_compressed_length,
)
from komira_compression.zlib import (
    ZLIB_WINDOW_BITS_RAW,
    zlib_compress_bound,
    zlib_deflate_into,
)
from komira_compression.zstd_frame import zstd_compress_bound, zstd_compress_into
from komira_orc import (
    ORC_COMPRESSION_LZ4,
    ORC_COMPRESSION_SNAPPY,
    ORC_COMPRESSION_ZLIB,
    ORC_COMPRESSION_ZSTD,
    compress_stream,
    decompress_stream,
)

comptime _CHUNK: Int = 256 * 1024


def _text(n: Int) -> List[UInt8]:
    var out = List[UInt8](capacity=n)
    var r = 0
    while len(out) < n:
        var row = String("orc-equivalence-row-") + String(r % 11) + "|"
        for b in row.as_bytes():
            if len(out) < n:
                out.append(b)
        r += 1
    return out^


def _corpus() -> List[List[UInt8]]:
    var out = List[List[UInt8]]()
    out.append(List[UInt8]())
    var noise = List[UInt8](capacity=4096)
    var state: UInt32 = 0x6C078965
    for _ in range(4096):
        state = state * UInt32(1103515245) + UInt32(12345)
        noise.append(UInt8((state >> 24) & 0xFF))
    out.append(noise^)
    out.append(_text(600))
    out.append(_text(300 * 1024))
    return out^


def _cut(var buf: List[UInt8], n: Int) -> List[UInt8]:
    buf.resize(unsafe_uninit_length=n)
    return buf^


def _block(codec: Int, src: Span[UInt8, _]) raises -> List[UInt8]:
    var n = len(src)
    if codec == ORC_COMPRESSION_ZLIB:
        var out = List[UInt8](length=zlib_compress_bound(n, ZLIB_WINDOW_BITS_RAW), fill=0)
        return _cut(out^, zlib_deflate_into(Span(out), src, Int32(6), ZLIB_WINDOW_BITS_RAW))
    if codec == ORC_COMPRESSION_SNAPPY:
        var out = List[UInt8](length=snappy_max_compressed_length(n), fill=0)
        return _cut(out^, snappy_compress_into(Span(out), src))
    if codec == ORC_COMPRESSION_LZ4:
        var out = List[UInt8](length=lz4_compress_bound(n), fill=0)
        return _cut(out^, lz4_compress_into(Span(out), src))
    var out = List[UInt8](length=zstd_compress_bound(n), fill=0)
    return _cut(out^, zstd_compress_into(Span(out), src, Int32(3)))


def _header(mut out: List[UInt8], length: Int, original: Bool):
    var word = (length << 1) | (1 if original else 0)
    out.append(UInt8(word & 0xFF))
    out.append(UInt8((word >> 8) & 0xFF))
    out.append(UInt8((word >> 16) & 0xFF))


def _reference(codec: Int, data: List[UInt8]) raises -> List[UInt8]:
    """The chunk-framed stream komira_compression makes for `data` with the
    ORC writer's parameters, built here without compress_stream."""
    var out = List[UInt8]()
    var pos = 0
    while pos < len(data):
        var take = min(_CHUNK, len(data) - pos)
        var chunk = Span(data)[pos : pos + take]
        var packed = _block(codec, chunk)
        if len(packed) >= take:
            _header(out, take, True)
            out.extend(chunk)
        else:
            _header(out, len(packed), False)
            out.extend(Span(packed))
        pos += take
    return out^


def _assert_same(got: List[UInt8], want: List[UInt8], what: String) raises:
    assert_equal(len(got), len(want), what + ": length")
    var first = -1
    for i in range(len(want)):
        if got[i] != want[i]:
            first = i
            break
    assert_equal(first, -1, what + ": first differing byte")


def test_compress_stream_is_byte_equal_to_the_codec_api() raises:
    var codecs: List[Int] = [
        ORC_COMPRESSION_ZLIB,
        ORC_COMPRESSION_SNAPPY,
        ORC_COMPRESSION_LZ4,
        ORC_COMPRESSION_ZSTD,
    ]
    var corpus = _corpus()
    for k in range(len(codecs)):
        for c in range(len(corpus)):
            var what = "codec " + String(codecs[k]) + ", input " + String(c)
            var stream = compress_stream(corpus[c], codecs[k])
            _assert_same(stream, _reference(codecs[k], corpus[c]), what)
            var back = decompress_stream(Span(stream), codecs[k], _CHUNK)
            _assert_same(back, corpus[c], what + " decoded")


def _refusal(codec: Int, payload: List[UInt8]) -> String:
    var stream = List[UInt8]()
    _header(stream, len(payload), False)
    stream.extend(Span(payload))
    try:
        _ = decompress_stream(Span(stream), codec, 4096)
    except e:
        return String(e)
    return "accepted"


def test_corrupt_chunks_are_refused_with_exact_messages() raises:
    # A snappy copy whose offset reaches before the output; the block
    # declares 4 bytes.
    var snappy: List[UInt8] = [4, 0x01, 0x05]
    assert_equal(
        _refusal(ORC_COMPRESSION_SNAPPY, snappy),
        "OrcCodecError.SNAPPY_FAILED: snappy_uncompress failed (status=1,"
        " input_len=3, output_cap=4)",
    )
    # A zstd frame declaring 5 bytes whose raw block is cut one byte short;
    # the buffer starts at the chunk's 13 bytes.
    var zstd: List[UInt8] = [
        0x28, 0xB5, 0x2F, 0xFD, 0x20, 0x05, 0x29, 0x00, 0x00,
        0x68, 0x65, 0x6C, 0x6C,
    ]
    assert_equal(
        _refusal(ORC_COMPRESSION_ZSTD, zstd),
        "OrcCodecError.ZSTD_FAILED: ZSTD_decompress failed (result=-72,"
        " input_len=13, output_cap=13) (known_size=5)",
    )


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
