# =============================================================================
# test_codec_owner_equivalence.mojo
# =============================================================================
#
# The page codecs call komira_compression (snappy_block, zstd_frame, zlib,
# lz4) and this package declares no snappy, zstd or LZ4 FFI of its own. This
# pins what that must not change:
#
#   * `compress` for SNAPPY, ZSTD, LZ4_RAW and GZIP, and `compress_lz4_frame`,
#     over four inputs (empty, 4 KiB of incompressible bytes, ~600 bytes of
#     repetitive text, 64 KiB of words drawn from a 50-word vocabulary), are
#     byte-equal to komira_compression called directly with the parameters
#     this package has always used (zstd level 3, gzip level 6 with the gzip
#     wrapper, LZ4_compress_default, the default LZ4 frame preferences);
#     `decompress` / `decompress_lz4_frame` return the input into a
#     destination of exactly its size.
#   * the word input tells the neighbouring levels apart: zstd level 3 differs
#     from levels 1 and 2, gzip level 6 from levels 5 and 7. Without it the
#     equality above would not see a level moved by one (the other three
#     inputs compress to the same bytes at neighbouring levels).
#   * the refusals keep this package's text: a corrupt snappy block, junk and
#     empty ZSTD input, an LZ4 frame into a destination one byte short
#     ("LZ4F dst buffer too small"), and an LZ4 frame cut before its end mark
#     ("LZ4F frame truncated: the <n>-byte input ends before the frame does").
#
# The same file run against the shims that declared their own FFI passes too:
# the bytes and the messages are the old ones.
#
# What it catches: a codec level changed in the move (by one level or more),
# an output cut to the wrong length, a lost refusal (an empty ZSTD page
# accepted), and changed error text that callers match on
# ("snappy_uncompress failed", "LZ4F dst buffer too small",
# "LZ4F frame truncated").
# =============================================================================

from std.testing import TestSuite, assert_equal

from komira_compression.lz4 import (
    lz4_compress_bound,
    lz4_compress_into,
    lz4_frame_compress_bound as _api_lz4_frame_compress_bound,
    lz4_frame_compress_into,
)
from komira_compression.snappy_block import (
    snappy_compress_into,
    snappy_max_compressed_length as _api_snappy_max,
)
from komira_compression.zlib import (
    ZLIB_WINDOW_BITS_GZIP,
    zlib_compress_bound,
    zlib_deflate_into,
)
from komira_compression.zstd_frame import zstd_compress_bound, zstd_compress_into
from komira_parquet_api import CompressionCodec
from komira_parquet_codec import (
    compress,
    compress_bound,
    compress_lz4_frame,
    decompress,
    decompress_lz4_frame,
    lz4_frame_compress_bound,
)


def _corpus() -> List[List[UInt8]]:
    var out = List[List[UInt8]]()
    out.append(List[UInt8]())
    var noise = List[UInt8](capacity=4096)
    var state: UInt32 = 0x41C64E6D
    for _ in range(4096):
        state = state * UInt32(1103515245) + UInt32(12345)
        noise.append(UInt8((state >> 24) & 0xFF))
    out.append(noise^)
    var text = List[UInt8]()
    for r in range(40):
        var row = String("parquet-equivalence-row-") + String(r % 5) + "|"
        for b in row.as_bytes():
            text.append(b)
    out.append(text^)
    out.append(_words(65536))
    return out^


def _words(size: Int) -> List[UInt8]:
    """`size` bytes of space-separated words, each picked by an LCG from a
    50-word vocabulary: matches everywhere at many distances, so the match
    search effort a level sets changes the output."""
    var vocab: List[String] = [
        "page", "row", "group", "column", "chunk", "dictionary", "offset",
        "index", "footer", "schema", "repetition", "definition", "level",
        "encoding", "plain", "delta", "binary", "packed", "bloom", "filter",
        "statistics", "minimum", "maximum", "null", "count", "value", "header",
        "compressed", "uncompressed", "size", "codec", "snappy", "zstd",
        "gzip", "brotli", "lz4", "raw", "frame", "block", "stream", "buffer",
        "length", "logical", "physical", "type", "decimal", "timestamp",
        "integer", "boolean", "float",
    ]
    var out = List[UInt8](capacity=size + 16)
    var state: UInt32 = 0x2545F491
    while len(out) < size:
        state = state * UInt32(1103515245) + UInt32(12345)
        var w = Int((state >> 16) % UInt32(len(vocab)))
        for b in vocab[w].as_bytes():
            out.append(b)
        out.append(UInt8(ord(" ")))
    return _cut(out^, size)


def _cut(var buf: List[UInt8], n: Int) -> List[UInt8]:
    buf.resize(unsafe_uninit_length=n)
    return buf^


def _reference(codec: CompressionCodec, src: List[UInt8]) raises -> List[UInt8]:
    var n = len(src)
    if codec == CompressionCodec.SNAPPY:
        var out = List[UInt8](length=_api_snappy_max(n), fill=0)
        return _cut(out^, snappy_compress_into(Span(out), Span(src)))
    if codec == CompressionCodec.ZSTD:
        return _zstd_at(src, Int32(3))
    if codec == CompressionCodec.LZ4_RAW:
        var out = List[UInt8](length=lz4_compress_bound(n), fill=0)
        return _cut(out^, lz4_compress_into(Span(out), Span(src)))
    return _gzip_at(src, Int32(6))


def _zstd_at(src: List[UInt8], level: Int32) raises -> List[UInt8]:
    var out = List[UInt8](length=zstd_compress_bound(len(src)), fill=0)
    return _cut(out^, zstd_compress_into(Span(out), Span(src), level))


def _gzip_at(src: List[UInt8], level: Int32) raises -> List[UInt8]:
    var out = List[UInt8](
        length=zlib_compress_bound(len(src), ZLIB_WINDOW_BITS_GZIP), fill=0
    )
    return _cut(
        out^,
        zlib_deflate_into(Span(out), Span(src), level, ZLIB_WINDOW_BITS_GZIP),
    )


def _differ(a: List[UInt8], b: List[UInt8]) -> Bool:
    if len(a) != len(b):
        return True
    for i in range(len(a)):
        if a[i] != b[i]:
            return True
    return False


def _assert_same(got: List[UInt8], want: List[UInt8], what: String) raises:
    assert_equal(len(got), len(want), what + ": length")
    var first = -1
    for i in range(len(want)):
        if got[i] != want[i]:
            first = i
            break
    assert_equal(first, -1, what + ": first differing byte")


def test_page_codecs_are_byte_equal_to_the_codec_api() raises:
    var codecs: List[CompressionCodec] = [
        CompressionCodec.SNAPPY,
        CompressionCodec.ZSTD,
        CompressionCodec.LZ4_RAW,
        CompressionCodec.GZIP,
    ]
    var corpus = _corpus()
    for k in range(len(codecs)):
        for c in range(len(corpus)):
            var what = "codec " + String(codecs[k]) + ", input " + String(c)
            var src = corpus[c].copy()
            var packed = List[UInt8](length=compress_bound(codecs[k], len(src)), fill=0)
            packed = _cut(packed^, compress(codecs[k], Span(src), Span(packed)))
            _assert_same(packed, _reference(codecs[k], src), what)
            if len(src) == 0 and codecs[k] == CompressionCodec.LZ4_RAW:
                # The one-byte empty block decodes to nothing.
                assert_equal(len(packed), 1, what)
            var back = List[UInt8](length=len(src), fill=0)
            var n = decompress(codecs[k], Span(packed), Span(back))
            assert_equal(n, len(src), what + " decoded length")
            _assert_same(back, src, what + " decoded")


def test_word_input_tells_neighbouring_levels_apart() raises:
    # If two levels compressed every input to the same bytes, the byte
    # equality above could not see the level move between them.
    var words = _corpus()[3].copy()
    var zstd3 = _zstd_at(words, Int32(3))
    assert_equal(_differ(zstd3, _zstd_at(words, Int32(1))), True, "zstd 3 vs 1")
    assert_equal(_differ(zstd3, _zstd_at(words, Int32(2))), True, "zstd 3 vs 2")
    var gzip6 = _gzip_at(words, Int32(6))
    assert_equal(_differ(gzip6, _gzip_at(words, Int32(5))), True, "gzip 6 vs 5")
    assert_equal(_differ(gzip6, _gzip_at(words, Int32(7))), True, "gzip 6 vs 7")


def test_lz4_frame_is_byte_equal_to_the_codec_api() raises:
    var corpus = _corpus()
    for c in range(len(corpus)):
        var src = corpus[c].copy()
        var what = "lz4 frame, input " + String(c)
        assert_equal(
            lz4_frame_compress_bound(len(src)),
            _api_lz4_frame_compress_bound(len(src)),
            what + " bound",
        )
        var packed = List[UInt8](length=lz4_frame_compress_bound(len(src)), fill=0)
        packed = _cut(packed^, compress_lz4_frame(Span(src), Span(packed)))
        var want = List[UInt8](length=lz4_frame_compress_bound(len(src)), fill=0)
        want = _cut(want^, lz4_frame_compress_into(Span(want), Span(src)))
        _assert_same(packed, want, what)
        var back = List[UInt8](length=len(src), fill=0)
        assert_equal(decompress_lz4_frame(Span(packed), Span(back)), len(src))
        _assert_same(back, src, what + " decoded")


def _refusal(codec: CompressionCodec, block: List[UInt8], cap: Int) -> String:
    var out = List[UInt8](length=cap, fill=0)
    try:
        _ = decompress(codec, Span(block), Span(out))
    except e:
        return String(e)
    return "accepted"


def test_refusals_keep_their_text() raises:
    var snappy: List[UInt8] = [4, 0x01, 0x05]
    assert_equal(
        _refusal(CompressionCodec.SNAPPY, snappy, 4),
        "snappy_uncompress failed (status=1, input_len=3, output_cap=4)",
    )
    var junk = List[UInt8](length=16, fill=0x58)
    assert_equal(
        _refusal(CompressionCodec.ZSTD, junk, 16),
        "ZSTD_decompress failed (result=-10, input_len=16, output_cap=16)",
    )
    var empty = List[UInt8]()
    assert_equal(
        _refusal(CompressionCodec.ZSTD, empty, 16),
        "ZSTD_decompress: empty input holds no zstd frame",
    )
    var text = _corpus()[2].copy()
    var frame = List[UInt8](length=lz4_frame_compress_bound(len(text)), fill=0)
    frame = _cut(frame^, compress_lz4_frame(Span(text), Span(frame)))
    var short = List[UInt8](length=len(text) - 1, fill=0)
    var msg = String("")
    try:
        _ = decompress_lz4_frame(Span(frame), Span(short))
    except e:
        msg = String(e)
    assert_equal(msg, "LZ4F dst buffer too small")
    # Without its 4-byte end mark the frame has not ended, and the
    # destination has room left: the input ran out first.
    var cut = len(frame) - 4
    var room = List[UInt8](length=len(text) + 8, fill=0)
    msg = String("")
    try:
        _ = decompress_lz4_frame(Span(frame)[0:cut], Span(room))
    except e:
        msg = String(e)
    assert_equal(
        msg,
        "LZ4F frame truncated: the "
        + String(cut)
        + "-byte input ends before the frame does",
    )


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
