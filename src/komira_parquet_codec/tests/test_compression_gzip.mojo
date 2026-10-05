# =============================================================================
# Tests for GZIP via the public compression API (zlib)
# =============================================================================
#
# These tests exercise the module's public `decompress(CompressionCodec.GZIP,
# ...)` and `compress` dispatchers, which reach libz through komira_zlib's
# Span entries.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_true

from komira_parquet_api import CompressionCodec
from komira_parquet_codec import kSlopBytes
from komira_parquet_codec.compression import (
    compress,
    compress_bound,
    decompress,
)


def _hello_gzip() -> List[UInt8]:
    """A gzip-compressed "Hello, Parquet!" (15 bytes -> 35 bytes).

    Generated with: printf 'Hello, Parquet!' | gzip -n -9
    """
    return [
        31, 139, 8, 0, 0, 0, 0, 0, 2, 3,
        243, 72, 205, 201, 201, 215, 81, 8, 72, 44,
        42, 44, 77, 45, 81, 4, 0,
        157, 48, 10, 152, 15, 0, 0, 0,
    ]


def _hello() -> List[UInt8]:
    # "Hello, Parquet!"
    return [72, 101, 108, 108, 111, 44, 32, 80, 97, 114, 113, 117, 101, 116, 33]


def _filled(n: Int, b: UInt8) -> List[UInt8]:
    var out = List[UInt8](capacity=n)
    for _ in range(n):
        out.append(b)
    return out^


def _assert_prefix(got: List[UInt8], want: List[UInt8]) raises:
    for i in range(len(want)):
        assert_equal(Int(got[i]), Int(want[i]), "byte " + String(i))


def test_gzip_decompress_known_data() raises:
    """Decompress a known gzip payload into a buffer with room to spare."""
    var compressed = _hello_gzip()
    var out = _filled(64, 0)
    var written = decompress(CompressionCodec.GZIP, Span(compressed), Span(out))
    assert_equal(written, 15, "Should decompress to 15 bytes")
    _assert_prefix(out, _hello())


def test_gzip_decompress_exact_capacity() raises:
    """A page decoder sizes the output at uncompressed_page_size exactly."""
    var compressed = _hello_gzip()
    var out = _filled(15, 0)
    var written = decompress(CompressionCodec.GZIP, Span(compressed), Span(out))
    assert_equal(written, 15)
    _assert_prefix(out, _hello())


def test_gzip_decompress_with_snappy_slop() raises:
    """The same page decoded into a buffer with kSlopBytes of slop."""
    var compressed = _hello_gzip()
    var out = _filled(15 + kSlopBytes, 0)
    var written = decompress(CompressionCodec.GZIP, Span(compressed), Span(out))
    assert_equal(written, 15)
    _assert_prefix(out, _hello())


def test_gzip_refuses_a_too_small_output() raises:
    var compressed = _hello_gzip()
    var out = _filled(14, 0)
    var raised = False
    try:
        _ = decompress(CompressionCodec.GZIP, Span(compressed), Span(out))
    except:
        raised = True
    assert_true(raised, "a 15-byte stream into 14 bytes must raise")


def test_gzip_refuses_a_truncated_stream() raises:
    var compressed = _hello_gzip()
    var cut = List[UInt8]()
    for i in range(len(compressed) - 4):
        cut.append(compressed[i])
    var out = _filled(64, 0)
    var raised = False
    try:
        _ = decompress(CompressionCodec.GZIP, Span(cut), Span(out))
    except:
        raised = True
    assert_true(raised, "a gzip stream without its trailer must raise")


def test_gzip_round_trip() raises:
    var data = List[UInt8]()
    for i in range(4096):
        data.append(UInt8((i * 31 + 7) & 0x3F))
    var packed = _filled(compress_bound(CompressionCodec.GZIP, len(data)), 0)
    var n = compress(CompressionCodec.GZIP, Span(data), Span(packed))
    assert_true(n > 0 and n < len(data), "repetitive data should compress")
    # gzip framing, as every Parquet reader expects for the GZIP codec.
    assert_equal(Int(packed[0]), 0x1F)
    assert_equal(Int(packed[1]), 0x8B)
    var out = _filled(len(data), 0)
    var m = decompress(CompressionCodec.GZIP, Span(packed)[0:n], Span(out))
    assert_equal(m, len(data))
    _assert_prefix(out, data)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
