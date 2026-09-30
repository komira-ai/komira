# =============================================================================
# src/komira/komira_core_ffi/tests/test_lz4_codec.mojo
#   Round-trip tests for the shared LZ4 raw-block codec
#   (komira_core_ffi.lz4_codec).
# =============================================================================
#
# The codec's PUBLIC SAFE API is Span-in / List-out:
#   lz4_compress(Span[UInt8]) -> List[UInt8]
#   lz4_decompress(Span[UInt8], uncompressed_len: Int) -> List[UInt8]
# These tests exercise the round-trip `lz4_decompress(lz4_compress(x), len(x))
# == x` over various blobs (empty / small / large / highly-compressible JSON)
# + the storage-win property (compressible input shrinks).
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_true

from komira_core_ffi.lz4_codec import (
    lz4_compress,
    lz4_decompress,
    lz4_compress_bound,
)


def _bytes(s: String) -> List[UInt8]:
    var out = List[UInt8]()
    var sb = s.as_bytes()
    for i in range(len(sb)):
        out.append(sb[i])
    return out^


def _assert_round_trip(data: List[UInt8]) raises:
    """lz4_decompress(lz4_compress(x), len(x)) == x, byte-for-byte."""
    var compressed = lz4_compress(Span(data))
    var decoded = lz4_decompress(Span(compressed), len(data))
    assert_equal(len(decoded), len(data))
    for i in range(len(data)):
        assert_equal(Int(decoded[i]), Int(data[i]))


def test_round_trip_empty() raises:
    """Empty input → empty compressed → empty decoded (the empty-blob
    convention; no FFI call)."""
    var data = List[UInt8]()
    var compressed = lz4_compress(Span(data))
    assert_equal(len(compressed), 0)
    var decoded = lz4_decompress(Span(compressed), 0)
    assert_equal(len(decoded), 0)


def test_round_trip_small() raises:
    """A tiny blob round-trips byte-identical."""
    _assert_round_trip(_bytes(String("hello world")))


def test_round_trip_single_byte() raises:
    var data = List[UInt8]()
    data.append(UInt8(42))
    _assert_round_trip(data)


def test_round_trip_varied_1k() raises:
    """1 KiB of varied (incompressible-ish) bytes round-trips byte-identical."""
    var data = List[UInt8]()
    for i in range(1024):
        data.append(UInt8((i * 7 + 13) & 0xFF))
    _assert_round_trip(data)


def test_round_trip_large_64k() raises:
    """64 KiB round-trips byte-identical."""
    var data = List[UInt8]()
    for i in range(65536):
        data.append(UInt8((i * 31 + 5) & 0xFF))
    _assert_round_trip(data)


def test_round_trip_json_blob() raises:
    """A realistic `_source` JSON line round-trips byte-identical."""
    var json = String(
        '{"@timestamp":"2026-09-09T12:00:00Z","level":"INFO",'
        '"service":"search-ingest","message":"request completed",'
        '"status":200,"latency_ms":12.5,"trace_id":"abc123def456"}'
    )
    _assert_round_trip(_bytes(json))


def test_storage_win_highly_compressible() raises:
    """Highly-compressible JSON-ish text compresses to FAR below its original
    size (the doc-store storage win — log lines are repetitive)."""
    var line = String(
        '{"level":"INFO","service":"search-ingest","message":"ok"}\n'
    )
    var data = List[UInt8]()
    # 200 repeated identical log lines — LZ4 collapses these dramatically.
    for _ in range(200):
        var lb = line.as_bytes()
        for i in range(len(lb)):
            data.append(lb[i])
    var compressed = lz4_compress(Span(data))
    assert_true(
        len(compressed) < len(data),
        "compressed (" + String(len(compressed)) + ") should be < original ("
        + String(len(data)) + ")",
    )
    assert_true(
        len(compressed) * 10 < len(data),
        "200 identical log lines should compress >10x (got "
        + String(len(data)) + " -> " + String(len(compressed)) + ")",
    )
    # And it still round-trips exactly.
    var decoded = lz4_decompress(Span(compressed), len(data))
    assert_equal(len(decoded), len(data))
    for i in range(len(data)):
        assert_equal(Int(decoded[i]), Int(data[i]))


def test_compress_bound_positive() raises:
    var b0 = lz4_compress_bound(0)
    assert_true(b0 > 0, "bound(0) should be positive")
    var b100 = lz4_compress_bound(100)
    assert_true(b100 >= 100, "bound(100) should be >= 100")


def test_decompress_wrong_len_raises() raises:
    """Passing a wrong uncompressed_len raises (fail-loud — the split is
    attacker-influenced at query time)."""
    var data = _bytes(String("the quick brown fox jumps over the lazy dog"))
    var compressed = lz4_compress(Span(data))
    var raised = False
    try:
        # Claim a far-too-large uncompressed_len.
        var _bad = lz4_decompress(Span(compressed), len(data) + 1000)
    except:
        raised = True
    assert_true(raised, "wrong uncompressed_len should raise")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
