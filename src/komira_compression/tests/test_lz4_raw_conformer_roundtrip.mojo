# =============================================================================
# test_lz4_raw_conformer_roundtrip.mojo
# =============================================================================
#
# Regression guard for the `Lz4Raw` (Parquet codec id 7) `Compression`
# trait conformer in `arrow/compression_codecs.mojo`.
#
# These tests exercise the conformer directly — compress a buffer, decompress it, and assert a
# byte-identical round-trip — confirming the liblz4 raw-block API
# (`LZ4_compressBound` / `LZ4_compress_default` / `LZ4_decompress_safe`) is
# correctly routed through the shared OwnedDLHandle singleton.
#
# Raw LZ4 BLOCK format (no frame header) — distinct on-wire from `Lz4Frame`.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_true

from komira_compression.compression_codecs import Lz4Raw


# =============================================================================
# Test 1: repetitive buffer round-trip (compresses well)
# =============================================================================

def test_lz4_raw_roundtrip_repetitive() raises:
    """Lz4Raw compress then decompress matches original repetitive data."""
    var src = List[UInt8](capacity=4096)
    for i in range(4096):
        # Repetitive 16-byte pattern — high LZ4 back-reference density.
        src.append(UInt8(i % 16))

    var compressed = Lz4Raw.compress(Span(src))
    assert_true(
        len(compressed) > 0, "Lz4Raw compressed size should be > 0"
    )
    assert_true(
        len(compressed) < len(src),
        "Lz4Raw should compress repetitive data smaller than original",
    )

    var decompressed = Lz4Raw.decompress(Span(compressed), len(src))
    assert_equal(
        len(decompressed), len(src), "decompressed length must match original"
    )
    for i in range(len(src)):
        assert_equal(decompressed[i], src[i], "byte mismatch at " + String(i))


# =============================================================================
# Test 2: incompressible (high-entropy) buffer round-trip
# =============================================================================

def test_lz4_raw_roundtrip_high_entropy() raises:
    """Lz4Raw round-trips high-entropy data byte-identically even when the
    block format cannot shrink it."""
    var src = List[UInt8](capacity=1024)
    # Pseudo-random sequence via a simple LCG (deterministic, high entropy).
    var state: UInt32 = 0x12345678
    for _ in range(1024):
        state = state * UInt32(1103515245) + UInt32(12345)
        src.append(UInt8((state >> 16) & 0xFF))

    var compressed = Lz4Raw.compress(Span(src))
    assert_true(len(compressed) > 0, "compressed size should be > 0")

    var decompressed = Lz4Raw.decompress(Span(compressed), len(src))
    assert_equal(len(decompressed), len(src))
    for i in range(len(src)):
        assert_equal(decompressed[i], src[i], "byte mismatch at " + String(i))


# =============================================================================
# Test 3: small buffer round-trip (edge case)
# =============================================================================

def test_lz4_raw_roundtrip_small() raises:
    """Lz4Raw handles a tiny buffer (a few bytes)."""
    var src: List[UInt8] = [
        UInt8(1), UInt8(2), UInt8(3), UInt8(4), UInt8(5),
    ]

    var compressed = Lz4Raw.compress(Span(src))
    assert_true(len(compressed) > 0, "compressed size should be > 0")

    var decompressed = Lz4Raw.decompress(Span(compressed), len(src))
    assert_equal(len(decompressed), len(src))
    for i in range(len(src)):
        assert_equal(decompressed[i], src[i])


# =============================================================================
# Test 4: codec identity — PARQUET_CODEC_ID is 7 (LZ4_RAW), not deprecated LZ4
# =============================================================================

def test_lz4_raw_codec_id_is_seven() raises:
    """Lz4Raw is Parquet CompressionCodec 7 (LZ4_RAW raw block), distinct
    from the deprecated LZ4 frame-ish codec."""
    assert_equal(Int(Lz4Raw.PARQUET_CODEC_ID), 7)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
