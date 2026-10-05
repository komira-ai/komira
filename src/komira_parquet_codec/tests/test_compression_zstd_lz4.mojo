# =============================================================================
# Tests for ZSTD and LZ4_RAW compression via the public compression API
# =============================================================================
#
# These tests call the module's public `compress` / `decompress` /
# `compress_bound` dispatchers with the appropriate `CompressionCodec`.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_true
from std.memory import alloc, unsafe_memcpy

from komira_parquet_codec.compression import (
    compress,
    decompress,
    compress_bound,
)
from komira_parquet_api import CompressionCodec


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
    var input_len = 64
    var input_buf = alloc[UInt8](input_len)
    for i in range(input_len):
        (input_buf + i)[] = UInt8(65)  # 'A'

    var comp_cap = compress_bound(CompressionCodec.ZSTD, input_len)
    var comp_buf = alloc[UInt8](comp_cap)
    var comp_size = compress(
        CompressionCodec.ZSTD, input_buf, input_len, comp_buf, comp_cap
    )
    assert_true(comp_size > 0, "Compressed size should be > 0")
    assert_true(comp_size < input_len, "Repetitive data should compress well")

    var decomp_buf = alloc[UInt8](input_len)
    var decomp_size = decompress(
        CompressionCodec.ZSTD, comp_buf, comp_size, decomp_buf, input_len
    )
    assert_equal(decomp_size, input_len)

    for i in range(input_len):
        assert_equal(Int((decomp_buf + i)[]), 65)

    input_buf.free()
    comp_buf.free()
    decomp_buf.free()


def test_zstd_round_trip_varied() raises:
    """ZSTD compress + decompress round-trip with varied data."""
    var input_len = 1024
    var input_buf = alloc[UInt8](input_len)
    for i in range(input_len):
        (input_buf + i)[] = UInt8(i & 0xFF)

    var comp_cap = compress_bound(CompressionCodec.ZSTD, input_len)
    var comp_buf = alloc[UInt8](comp_cap)
    var comp_size = compress(
        CompressionCodec.ZSTD, input_buf, input_len, comp_buf, comp_cap
    )
    assert_true(comp_size > 0, "Compressed size should be > 0")

    var decomp_buf = alloc[UInt8](input_len)
    var decomp_size = decompress(
        CompressionCodec.ZSTD, comp_buf, comp_size, decomp_buf, input_len
    )
    assert_equal(decomp_size, input_len)

    for i in range(input_len):
        assert_equal(Int((decomp_buf + i)[]), i & 0xFF)

    input_buf.free()
    comp_buf.free()
    decomp_buf.free()


def test_lz4_raw_round_trip_small() raises:
    """LZ4_RAW compress + decompress round-trip with small data."""
    var input_len = 64
    var input_buf = alloc[UInt8](input_len)
    for i in range(input_len):
        (input_buf + i)[] = UInt8(66)  # 'B'

    var comp_cap = compress_bound(CompressionCodec.LZ4_RAW, input_len)
    var comp_buf = alloc[UInt8](comp_cap)
    var comp_size = compress(
        CompressionCodec.LZ4_RAW, input_buf, input_len, comp_buf, comp_cap
    )
    assert_true(comp_size > 0, "Compressed size should be > 0")

    var decomp_buf = alloc[UInt8](input_len)
    var decomp_size = decompress(
        CompressionCodec.LZ4_RAW, comp_buf, comp_size, decomp_buf, input_len
    )
    assert_equal(decomp_size, input_len)

    for i in range(input_len):
        assert_equal(Int((decomp_buf + i)[]), 66)

    input_buf.free()
    comp_buf.free()
    decomp_buf.free()


def test_lz4_raw_round_trip_varied() raises:
    """LZ4_RAW compress + decompress round-trip with varied data."""
    var input_len = 1024
    var input_buf = alloc[UInt8](input_len)
    for i in range(input_len):
        (input_buf + i)[] = UInt8(i & 0xFF)

    var comp_cap = compress_bound(CompressionCodec.LZ4_RAW, input_len)
    var comp_buf = alloc[UInt8](comp_cap)
    var comp_size = compress(
        CompressionCodec.LZ4_RAW, input_buf, input_len, comp_buf, comp_cap
    )
    assert_true(comp_size > 0, "Compressed size should be > 0")

    var decomp_buf = alloc[UInt8](input_len)
    var decomp_size = decompress(
        CompressionCodec.LZ4_RAW, comp_buf, comp_size, decomp_buf, input_len
    )
    assert_equal(decomp_size, input_len)

    for i in range(input_len):
        assert_equal(Int((decomp_buf + i)[]), i & 0xFF)

    input_buf.free()
    comp_buf.free()
    decomp_buf.free()


def test_zstd_large_data() raises:
    """ZSTD handles larger data (64KB)."""
    var input_len = 65536
    var input_buf = alloc[UInt8](input_len)
    for i in range(input_len):
        (input_buf + i)[] = UInt8((i * 7 + 13) & 0xFF)

    var comp_cap = compress_bound(CompressionCodec.ZSTD, input_len)
    var comp_buf = alloc[UInt8](comp_cap)
    var comp_size = compress(
        CompressionCodec.ZSTD, input_buf, input_len, comp_buf, comp_cap
    )
    assert_true(comp_size > 0, "Compressed size should be > 0")

    var decomp_buf = alloc[UInt8](input_len)
    var decomp_size = decompress(
        CompressionCodec.ZSTD, comp_buf, comp_size, decomp_buf, input_len
    )
    assert_equal(decomp_size, input_len)

    for i in range(input_len):
        assert_equal(Int((decomp_buf + i)[]), (i * 7 + 13) & 0xFF)

    input_buf.free()
    comp_buf.free()
    decomp_buf.free()


def test_lz4_raw_large_data() raises:
    """LZ4_RAW handles larger data (64KB)."""
    var input_len = 65536
    var input_buf = alloc[UInt8](input_len)
    for i in range(input_len):
        (input_buf + i)[] = UInt8((i * 7 + 13) & 0xFF)

    var comp_cap = compress_bound(CompressionCodec.LZ4_RAW, input_len)
    var comp_buf = alloc[UInt8](comp_cap)
    var comp_size = compress(
        CompressionCodec.LZ4_RAW, input_buf, input_len, comp_buf, comp_cap
    )
    assert_true(comp_size > 0, "Compressed size should be > 0")

    var decomp_buf = alloc[UInt8](input_len)
    var decomp_size = decompress(
        CompressionCodec.LZ4_RAW, comp_buf, comp_size, decomp_buf, input_len
    )
    assert_equal(decomp_size, input_len)

    for i in range(input_len):
        assert_equal(Int((decomp_buf + i)[]), (i * 7 + 13) & 0xFF)

    input_buf.free()
    comp_buf.free()
    decomp_buf.free()


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
