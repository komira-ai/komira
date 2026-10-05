# =============================================================================
# Tests for ZSTD, LZ4_RAW, SNAPPY and UNCOMPRESSED via the public compression
# API
# =============================================================================
#
# These tests call the module's public `compress` / `decompress` /
# `compress_bound` dispatchers with the appropriate `CompressionCodec`.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_true

from komira_parquet_api import CompressionCodec
from komira_parquet_codec.compression import (
    compress,
    compress_bound,
    decompress,
)


def _filled(n: Int, b: UInt8) -> List[UInt8]:
    var out = List[UInt8](capacity=n)
    for _ in range(n):
        out.append(b)
    return out^


def _round_trip(codec: CompressionCodec, data: List[UInt8]) raises -> Int:
    """Compress then decompress `data` with `codec`; return the compressed
    size after checking the bytes come back."""
    var packed = _filled(compress_bound(codec, len(data)), 0)
    var comp_size = compress(codec, Span(data), Span(packed))
    assert_true(comp_size > 0, "Compressed size should be > 0")
    var out = _filled(len(data), 0)
    var decomp_size = decompress(codec, Span(packed)[0:comp_size], Span(out))
    assert_equal(decomp_size, len(data))
    for i in range(len(data)):
        assert_equal(Int(out[i]), Int(data[i]), "byte " + String(i))
    return comp_size


def _varied(n: Int) -> List[UInt8]:
    var out = List[UInt8](capacity=n)
    for i in range(n):
        out.append(UInt8(i & 0xFF))
    return out^


def _scrambled(n: Int) -> List[UInt8]:
    var out = List[UInt8](capacity=n)
    for i in range(n):
        out.append(UInt8((i * 7 + 13) & 0xFF))
    return out^


def test_zstd_compress_bound() raises:
    """ZSTD compress bound returns a reasonable upper bound."""
    var bound = compress_bound(CompressionCodec.ZSTD, 100)
    assert_true(bound > 0, "ZSTD compress bound should be positive")
    assert_true(bound >= 100, "ZSTD compress bound should be >= input size")


def test_lz4_raw_compress_bound() raises:
    """LZ4 compress bound returns a reasonable upper bound."""
    var bound = compress_bound(CompressionCodec.LZ4_RAW, 100)
    assert_true(bound > 0, "LZ4 compress bound should be positive")
    assert_true(bound >= 100, "LZ4 compress bound should be >= input size")


def test_zstd_round_trip_small() raises:
    """ZSTD compress + decompress round-trip with small data."""
    var n = _round_trip(CompressionCodec.ZSTD, _filled(64, 65))
    assert_true(n < 64, "Repetitive data should compress well")


def test_zstd_round_trip_varied() raises:
    _ = _round_trip(CompressionCodec.ZSTD, _varied(1024))


def test_zstd_large_data() raises:
    _ = _round_trip(CompressionCodec.ZSTD, _scrambled(65536))


def test_lz4_raw_round_trip_small() raises:
    _ = _round_trip(CompressionCodec.LZ4_RAW, _filled(64, 66))


def test_lz4_raw_round_trip_varied() raises:
    _ = _round_trip(CompressionCodec.LZ4_RAW, _varied(1024))


def test_lz4_raw_large_data() raises:
    _ = _round_trip(CompressionCodec.LZ4_RAW, _scrambled(65536))


def test_snappy_round_trip() raises:
    var n = _round_trip(CompressionCodec.SNAPPY, _filled(4096, 7))
    assert_true(n < 4096, "Repetitive data should compress well")
    _ = _round_trip(CompressionCodec.SNAPPY, _scrambled(65536))


def test_uncompressed_is_a_copy() raises:
    var data = _varied(300)
    assert_equal(_round_trip(CompressionCodec.UNCOMPRESSED, data), 300)


def test_uncompressed_refuses_a_too_small_output() raises:
    var data = _varied(10)
    var out = _filled(9, 0)
    var raised = False
    try:
        _ = decompress(CompressionCodec.UNCOMPRESSED, Span(data), Span(out))
    except:
        raised = True
    assert_true(raised, "10 bytes do not fit in 9")


def test_zstd_refuses_a_too_small_output() raises:
    var data = _scrambled(1000)
    var packed = _filled(compress_bound(CompressionCodec.ZSTD, len(data)), 0)
    var n = compress(CompressionCodec.ZSTD, Span(data), Span(packed))
    var out = _filled(999, 0)
    var raised = False
    try:
        _ = decompress(CompressionCodec.ZSTD, Span(packed)[0:n], Span(out))
    except:
        raised = True
    assert_true(raised, "a 1000-byte frame into 999 bytes must raise")


def _hello3() -> List[UInt8]:
    # "Hello, Parquet! Hello, Parquet! Hello, Parquet!" (47 bytes).
    var one: List[UInt8] = [
        72, 101, 108, 108, 111, 44, 32, 80, 97, 114, 113, 117, 101, 116, 33,
    ]
    var out = List[UInt8]()
    for k in range(3):
        if k > 0:
            out.append(32)
        for i in range(len(one)):
            out.append(one[i])
    return out^


def _hello3_zstd() -> List[UInt8]:
    """`_hello3()` as one zstd frame holding one compressed block (a literal
    section and a repeat match), 32 bytes. Generated with:

        printf 'Hello, Parquet! Hello, Parquet! Hello, Parquet!' \\
            | zstd -19 --no-check
    """
    return [
        40, 181, 47, 253, 0, 104, 189, 0, 0, 136, 72, 101, 108, 108, 111, 44,
        32, 80, 97, 114, 113, 117, 101, 116, 33, 32, 72, 1, 0, 71, 156, 75,
    ]


def test_zstd_decompress_known_frame() raises:
    var want = _hello3()
    assert_equal(len(want), 47)
    var frame = _hello3_zstd()
    var out = _filled(len(want), 0)
    var n = decompress(CompressionCodec.ZSTD, Span(frame), Span(out))
    assert_equal(n, len(want))
    for i in range(len(want)):
        assert_equal(Int(out[i]), Int(want[i]), "byte " + String(i))


def test_zstd_refuses_a_truncated_frame() raises:
    var frame = _hello3_zstd()
    var cut = List[UInt8]()
    for i in range(len(frame) - 1):
        cut.append(frame[i])
    var out = _filled(64, 0)
    var raised = False
    try:
        _ = decompress(CompressionCodec.ZSTD, Span(cut), Span(out))
    except:
        raised = True
    assert_true(raised, "a zstd frame missing its last byte must raise")


def test_zstd_refuses_an_empty_input() raises:
    # libzstd decodes no input to 0 bytes with no error; a page always holds
    # a frame, so the dispatch refuses it, as it does for SNAPPY.
    var empty = List[UInt8]()
    var out = _filled(16, 0)
    var raised = False
    try:
        _ = decompress(CompressionCodec.ZSTD, Span(empty), Span(out))
    except:
        raised = True
    assert_true(raised, "an empty ZSTD input must raise")


def test_lzo_is_refused() raises:
    var data = _varied(10)
    var out = _filled(10, 0)
    var raised = False
    try:
        _ = decompress(CompressionCodec.LZO, Span(data), Span(out))
    except:
        raised = True
    assert_true(raised)


def test_deprecated_lz4_is_never_written() raises:
    var data = _varied(10)
    var out = _filled(100, 0)
    var raised = False
    try:
        _ = compress(CompressionCodec.LZ4, Span(data), Span(out))
    except:
        raised = True
    assert_true(raised, "compress must refuse codec id 5")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
