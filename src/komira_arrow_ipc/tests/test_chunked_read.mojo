# =============================================================================
# test_chunked_read.mojo — `read_chunked`
# =============================================================================
#
# Direct unit-test coverage for the centralized `read_chunked` helper in
# `komira_arrow_ipc/chunked_read.mojo`. This helper is the READ-SIDE analog
# of `chunked_write.mojo` — the canonical workaround for the Mojo stdlib
# `Path.read_bytes()` >2 GB silent-truncate / raise bug.
#
# Coverage matrix:
#   * 0-byte file: mmap raises (POSIX implementation-defined; we raise).
#   * 1-byte / small / 1 MiB files — exercise the common path.
#   * Byte-identity vs. write_chunked: write known pattern via the
#     write helper, read it back via read_chunked, compare byte-for-byte.
#   * Span consume: verify the returned MmapAlignedBuffer's
#     `.view_range_ro(0, length).into_span()` yields a usable
#     Span[UInt8, _] (the shape every downstream decoder consumes).
#
# >2 GB integration shape is NOT covered here (~3 GB disk + ~10 s wall per
# case); a >2 GB JSONL write/read round trip is the integration guard.
# =============================================================================

from std.io import FileHandle
from std.testing import TestSuite, assert_equal, assert_true

from komira_arrow_ipc.chunked_read import read_chunked, read_chunked_into_list
from komira_libc.chunked_write import write_chunked
from komira_libc.posix import _read_env


# ---------------------------------------------------------------------------
# ⚠ $TEST_TMPDIR, NOT A HARD-CODED `/tmp` PATH. A test may be executed by more
# than one action at a time on one worker, and a fixed `/tmp` path is shared by
# all of them; `TEST_TMPDIR` is unique per execution.
#
# ⚠ `_read_env`, NOT `std.os.getenv` — Mojo's MLIR FFI legalization allows at
# most ONE `getenv` declaration per link unit and `komira_libc.posix` is
# the canonical one.
# ---------------------------------------------------------------------------
def _scratch_dir() -> String:
    """The directory THIS execution may write scratch files into."""
    var d = _read_env("TEST_TMPDIR")
    if d.byte_length() == 0:
        d = _read_env("TMPDIR")
    if d.byte_length() == 0:
        return String("/tmp")
    return d


# =============================================================================
# Helpers
# =============================================================================


def _make_tmp_path(name: String) raises -> String:
    """Construct a fresh scratch file path."""
    return (_scratch_dir() + String("/komira_test_chunked_read_")) + name


def _write_file_bytes(path: String, bytes: List[UInt8]) raises:
    """Write a `List[UInt8]` to `path` via write_chunked (the proven
    write helper). Truncates any existing file at `path`."""
    var h = FileHandle(path, "w")
    write_chunked(h, Span(bytes))
    _ = h^


def _build_pattern(n: Int) -> List[UInt8]:
    """Deterministic n-byte pattern (i % 256). Same generator as
    test_chunked_write.mojo — round-trip parity by construction."""
    var out = List[UInt8](capacity=n)
    for i in range(n):
        out.append(UInt8(i & 0xFF))
    return out^


# =============================================================================
# Tests
# =============================================================================


def test_read_chunked_zero_length_file_raises() raises:
    """0-byte file: mmap of len=0 is implementation-defined per POSIX;
    `MmapRegion.open_readonly` raises a clean Error rather than relying
    on either kernel arm."""
    var path = _make_tmp_path("zero")
    var h = FileHandle(path, "w")  # truncate to 0 bytes
    _ = h^
    var raised = False
    try:
        var _buf = read_chunked(path)
    except:
        raised = True
    assert_true(raised, "read_chunked on zero-length file must raise")


def test_read_chunked_single_byte() raises:
    """1-byte file: smallest non-zero payload. Verifies the buffer
    length matches and the single byte is exposed via view_range_ro."""
    var path = _make_tmp_path("onebyte")
    var src = List[UInt8]()
    src.append(UInt8(0x42))
    _write_file_bytes(path, src)
    var buf = read_chunked(path)
    assert_equal(buf.len(), 1)
    var span = buf.view_range_ro(0, 1).into_span()
    assert_equal(Int(span[0]), 0x42)


def test_read_chunked_small_payload_byte_identity() raises:
    """1 KiB pattern: byte-for-byte parity with the input (cross-check
    via write_chunked → read_chunked round trip)."""
    var path = _make_tmp_path("small_1k")
    var src = _build_pattern(1024)
    _write_file_bytes(path, src)
    var buf = read_chunked(path)
    assert_equal(buf.len(), 1024)
    var span = buf.view_range_ro(0, buf.len()).into_span()
    for i in range(1024):
        assert_equal(Int(span[i]), Int(UInt8(i & 0xFF)))


def test_read_chunked_one_mib_byte_identity() raises:
    """1 MiB pattern: larger payload, still sub-chunk. Spot-check at 32
    evenly-spaced positions (full element-wise compare would be slow;
    pattern is deterministic so spot samples suffice)."""
    var path = _make_tmp_path("one_mib")
    var n = 1024 * 1024
    var src = _build_pattern(n)
    _write_file_bytes(path, src)
    var buf = read_chunked(path)
    assert_equal(buf.len(), n)
    var span = buf.view_range_ro(0, buf.len()).into_span()
    for k in range(32):
        var i = (n // 32) * k
        if i >= n:
            i = n - 1
        assert_equal(Int(span[i]), Int(UInt8(i & 0xFF)))


def test_read_chunked_buffer_is_non_owning() raises:
    """The returned SharedAlignedBuffer is mmap-backed and non-owning:
    is_mmap_backed() == True and is_owned() == False. This is the load-
    bearing property that ensures the heap-free path is never taken on
    the mmap'd bytes (which are kernel-managed; munmap happens via the
    MmapRegion Arc on the last drop, NOT a heap free).

    `read_chunked` returns SharedAlignedBuffer[MmapRegion], which has no
    separate `_capacity` field — `capacity()` aliases `_length` (= the file
    byte length). The non-owning signal is `is_mmap_backed() == True` /
    `is_owned() == False` (see SharedAlignedBuffer.is_owned: K=MmapRegion is
    non-owning), not a zero capacity."""
    var path = _make_tmp_path("non_owning")
    var src = _build_pattern(256)
    _write_file_bytes(path, src)
    var buf = read_chunked(path)
    # The mmap-backed SAB exposes the file's full byte length, NOT a
    # zero-capacity sentinel; non-owning-ness is signalled by K=MmapRegion.
    assert_equal(buf.capacity(), 256)
    assert_true(buf.is_mmap_backed(),
                "read_chunked must return an mmap-backed buffer")
    assert_true(not buf.is_owned(),
                "mmap-backed buffer must report is_owned() == False")


def test_read_chunked_span_usable_by_decoder_shape() raises:
    """Verifies the returned buffer's `.view_range_ro(0, length).into_span()`
    is a usable Span[UInt8, _] — the exact shape downstream decoders
    (JSONL inferrer, CSV reader, ORC reader) consume. Round-trips a
    known string via the Span (mimicking what the JSONL schema inferrer
    sees)."""
    var path = _make_tmp_path("span_usable")
    var s = String("hello mmap world\n")
    var src = List[UInt8]()
    var sb = s.as_bytes()
    for i in range(len(sb)):
        src.append(sb[i])
    _write_file_bytes(path, src)
    var buf = read_chunked(path)
    var span = buf.view_range_ro(0, buf.len()).into_span()
    # Span supports len() + indexing — the contract every Span-poly
    # decoder relies on.
    assert_equal(len(span), len(sb))
    for i in range(len(sb)):
        assert_equal(Int(span[i]), Int(sb[i]))


def test_read_chunked_into_list_round_trip() raises:
    """read_chunked_into_list returns an owned List[UInt8] with byte-
    identical content. Less efficient than the mmap path; preserved
    for the rare caller that genuinely needs an owned mutable buffer."""
    var path = _make_tmp_path("into_list")
    var n = 4096
    var src = _build_pattern(n)
    _write_file_bytes(path, src)
    var out = read_chunked_into_list(path)
    assert_equal(len(out), n)
    for i in range(n):
        assert_equal(Int(out[i]), Int(UInt8(i & 0xFF)))


# =============================================================================
# main
# =============================================================================


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
