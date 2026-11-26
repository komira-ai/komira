# =============================================================================
# src/lz4/tests/test_codec.mojo
#   Round-trip tests for the shared LZ4 raw-block codec
#   (lz4.codec).
# =============================================================================
#
# The codec's PUBLIC SAFE API is Span-in / List-out:
#   lz4_compress(Span[UInt8]) -> List[UInt8]
#   lz4_decompress(Span[UInt8], uncompressed_len: Int) -> List[UInt8]
# These tests exercise the round-trip `lz4_decompress(lz4_compress(x), len(x))
# == x` over various blobs (empty / small / large / highly-compressible JSON)
# + the storage-win property (compressible input shrinks).
#
# The handle slot: liblz4 is held as its handle and calls answer through it;
# a soname that does not exist is held as its refusal, raised at every use.
# =============================================================================

from std.ffi import OwnedDLHandle, _Global
from std.testing import TestSuite, assert_equal, assert_false, assert_true

from lz4.codec import (
    LIBLZ4_SONAME,
    _Lz4Library,
    _default_lz4_codec_handle,
    _load_lz4_library,
    _lz4_library_handle,
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


# The handle slot (lz4.codec): a library that loads is held as its handle, and
# a soname that does not exist as the refusal
# `lz4: cannot load <soname>: <the loader's error>`, which the slot's
# accessor raises, word for word, on every call (the slot is filled once; it
# neither aborts nor opens the library again).
comptime _ABSENT = "liblz4.so.komira-absent"


def _loader_error(soname: String) -> String:
    """What OwnedDLHandle raises for `soname`, or "" when it opens."""
    try:
        _ = OwnedDLHandle(soname)
    except e:
        return String(e)
    return ""


def _init_absent() -> _Lz4Library:
    return _load_lz4_library(_ABSENT)


comptime _ABSENT_GLOBAL = _Global["komira_lz4_test_absent", _init_absent]


def _handle_message() -> String:
    """What the accessor of the absent slot raises, or "" when it returns."""
    try:
        _ = _lz4_library_handle(_ABSENT_GLOBAL.get_or_create_ptr())
    except e:
        return String(e)
    return ""


def test_the_slot_over_the_library_holds_its_handle() raises:
    var library = _load_lz4_library(LIBLZ4_SONAME)
    assert_true(Bool(library.handle))
    assert_equal(library.refusal, "")
    var handle = _default_lz4_codec_handle()
    # LZ4_compressBound(0) is 16, the bound of an empty block.
    assert_equal(handle[].call["LZ4_compressBound", Int32](Int32(0)), Int32(16))


def test_a_slot_over_a_missing_library_keeps_the_refusal() raises:
    var reason = _loader_error(_ABSENT)
    assert_true(reason.byte_length() > 0, String(_ABSENT) + " opened")
    var want = "lz4: cannot load " + String(_ABSENT) + ": " + reason
    var library = _load_lz4_library(_ABSENT)
    assert_false(Bool(library.handle))
    assert_equal(library.refusal, want)
    assert_equal(_handle_message(), want)
    assert_equal(_handle_message(), want)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
