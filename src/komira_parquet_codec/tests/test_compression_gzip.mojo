# =============================================================================
# Tests for GZIP decompression via the public compression API (zlib)
# =============================================================================
#
# These tests exercise the module's public `decompress(CompressionCodec.GZIP,
# ...)` dispatcher, which reaches libz through komira_zlib.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_true
from std.memory import alloc, unsafe_memcpy

from komira_parquet_codec.compression import decompress
from komira_parquet_api import CompressionCodec


def test_gzip_decompress_known_data() raises:
    """Decompress a known gzip-compressed payload.

    This is a gzip-compressed version of "Hello, Parquet!" (15 bytes).
    Generated with: printf 'Hello, Parquet!' | gzip -n -9
    """
    # Pre-compressed gzip data for "Hello, Parquet!" (35 bytes compressed).
    var compressed_bytes: List[UInt8] = [
        31, 139, 8, 0, 0, 0, 0, 0, 2, 3,
        243, 72, 205, 201, 201, 215, 81, 8, 72, 44,
        42, 44, 77, 45, 81, 4, 0,
        157, 48, 10, 152, 15, 0, 0, 0,
    ]

    var input_len = len(compressed_bytes)
    var input_buf = alloc[UInt8](input_len)
    for i in range(input_len):
        (input_buf + i)[] = compressed_bytes[i]

    var output_len = 64  # more than enough
    var output_buf = alloc[UInt8](output_len)

    var written = decompress(
        CompressionCodec.GZIP, input_buf, input_len, output_buf, output_len
    )
    assert_equal(written, 15, "Should decompress to 15 bytes")

    # Verify content: "Hello, Parquet!"
    var expected: List[UInt8] = [
        72, 101, 108, 108, 111, 44, 32, 80, 97, 114, 113, 117, 101, 116, 33,
    ]
    for i in range(15):
        assert_equal(
            Int((output_buf + i)[]),
            Int(expected[i]),
            "Byte " + String(i) + " mismatch",
        )

    input_buf.free()
    output_buf.free()


def test_gzip_dispatch_via_decompress() raises:
    """GZIP decompression works through the unified decompress() dispatcher.

    Same compressed data as test_gzip_decompress_known_data; duplicated as a
    distinct test to keep the "dispatch through the public API" contract
    covered if we ever add a separate codec-specific entry point.
    """
    var compressed_bytes: List[UInt8] = [
        31, 139, 8, 0, 0, 0, 0, 0, 2, 3,
        243, 72, 205, 201, 201, 215, 81, 8, 72, 44,
        42, 44, 77, 45, 81, 4, 0,
        157, 48, 10, 152, 15, 0, 0, 0,
    ]

    var input_len = len(compressed_bytes)
    var input_buf = alloc[UInt8](input_len)
    for i in range(input_len):
        (input_buf + i)[] = compressed_bytes[i]

    var output_len = 64
    var output_buf = alloc[UInt8](output_len)

    var written = decompress(
        CompressionCodec.GZIP,
        input_buf,
        input_len,
        output_buf,
        output_len,
    )
    assert_equal(written, 15, "Dispatch should decompress to 15 bytes")

    input_buf.free()
    output_buf.free()


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
