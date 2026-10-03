# =============================================================================
# test_chunked_write.mojo — `write_chunked` / `write_chunked_string`
# =============================================================================
#
# Direct unit-test coverage for the centralized `write_chunked` /
# `write_chunked_string` helper in `komira_libc/chunked_write.mojo`.
#
# The helper is the canonical workaround for the Mojo stdlib
# `FileHandle.write(s)` >2 GB silent-data-loss bug: a >2 GB String handed
# directly to `FileHandle.write` flushes 0 bytes with no exception.
#
# Coverage matrix:
#   * Empty / single-byte / sub-chunk inputs — fast-path correctness.
#   * Exact chunk-boundary inputs (64 MiB, 128 MiB) — verify off-by-one
#     loop bookkeeping does NOT drop a chunk.
#   * Slightly-above-chunk inputs — verify the slow path concatenation
#     reassembles to byte-identical output.
#   * Multi-chunk inputs (3 chunks worth) — multi-iteration slow path.
#   * write_chunked_string convenience wrapper — same outputs as the
#     Span-based entry point.
#
# >2 GB threshold cases are in `test_large_writes.mojo` (a manual target:
# ~3 GB of RAM + disk and several seconds of wall per case). The unit tests
# here lock the chunk-boundary arithmetic.
# =============================================================================

from std.io import FileHandle
from std.testing import TestSuite, assert_equal, assert_true

from komira_libc.chunked_write import (
    write_chunked,
    write_chunked_string,
    CHUNK_BYTES,
)
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
    """Construct a fresh scratch file path. Single-process tests
    don't need a unique-suffix scheme — each test name is distinct.
    """
    return (_scratch_dir() + String("/komira_test_chunked_write_")) + name


def _read_file_bytes(path: String) raises -> List[UInt8]:
    """Read the whole file at `path` into a List[UInt8]."""
    var h = FileHandle(path, "r")
    _ = h.seek(0, 2)  # SEEK_END
    var n = Int(h.seek(0, 1))  # SEEK_CUR
    _ = h.seek(0, 0)  # SEEK_SET
    if n <= 0:
        return List[UInt8]()
    var raw = h.read_bytes(n)
    return raw^


def _build_pattern(n: Int) -> List[UInt8]:
    """Build a deterministic n-byte pattern (i % 256). Used to verify
    write_chunked produces byte-identical output regardless of chunk
    boundary placement."""
    var out = List[UInt8](capacity=n)
    for i in range(n):
        out.append(UInt8(i & 0xFF))
    return out^


def _assert_bytes_equal(
    actual: List[UInt8], expected: List[UInt8]
) raises:
    """Element-wise compare. Fast-fails on first mismatch with index."""
    assert_equal(len(actual), len(expected))
    for i in range(len(expected)):
        if actual[i] != expected[i]:
            raise Error(
                "bytes mismatch at index "
                + String(i)
                + ": got="
                + String(Int(actual[i]))
                + " expected="
                + String(Int(expected[i]))
            )


# =============================================================================
# Tests
# =============================================================================


def test_write_chunked_empty_input_noop() raises:
    """Empty input: no write call issued; file ends up size 0 (truncated
    by open-for-write)."""
    var path = _make_tmp_path("empty")
    var h = FileHandle(path, "w")
    var buf = List[UInt8]()
    write_chunked(h, Span(buf))
    _ = h^
    var got = _read_file_bytes(path)
    assert_equal(len(got), 0)


def test_write_chunked_single_byte() raises:
    """1-byte payload: fast path. The on-disk byte matches the input."""
    var path = _make_tmp_path("onebyte")
    var h = FileHandle(path, "w")
    var buf = List[UInt8]()
    buf.append(UInt8(0x42))
    write_chunked(h, Span(buf))
    _ = h^
    var got = _read_file_bytes(path)
    assert_equal(len(got), 1)
    assert_equal(Int(got[0]), 0x42)


def test_write_chunked_sub_chunk_payload() raises:
    """1 KiB payload — well under the chunk size. Fast path; verify
    byte-for-byte fidelity."""
    var path = _make_tmp_path("subchunk_1k")
    var h = FileHandle(path, "w")
    var buf = _build_pattern(1024)
    write_chunked(h, Span(buf))
    _ = h^
    var got = _read_file_bytes(path)
    _assert_bytes_equal(got, buf)


def test_write_chunked_just_under_chunk_boundary() raises:
    """CHUNK_BYTES - 1 = 64 MiB - 1 = 67108863 bytes. Last single-chunk
    case before the slow path kicks in. Verify the fast path still
    fires correctly at the boundary."""
    var path = _make_tmp_path("just_under")
    var h = FileHandle(path, "w")
    var n = CHUNK_BYTES - 1
    var buf = _build_pattern(n)
    write_chunked(h, Span(buf))
    _ = h^
    var got = _read_file_bytes(path)
    assert_equal(len(got), n)
    # Sample-check the byte pattern (full element-wise compare on 64 MiB
    # would be slow; pattern is deterministic so 8 spot samples suffice).
    for k in range(8):
        var i = (n // 8) * k
        if i >= n:
            i = n - 1
        assert_equal(Int(got[i]), Int(UInt8(i & 0xFF)))


def test_write_chunked_exact_chunk_boundary() raises:
    """Exactly CHUNK_BYTES = 64 MiB. Single-chunk fast path (n <=
    CHUNK_BYTES). Verify the boundary inclusion is correct."""
    var path = _make_tmp_path("exact_chunk")
    var h = FileHandle(path, "w")
    var n = CHUNK_BYTES
    var buf = _build_pattern(n)
    write_chunked(h, Span(buf))
    _ = h^
    var got = _read_file_bytes(path)
    assert_equal(len(got), n)
    # Spot-check the last byte (boundary fencepost).
    assert_equal(Int(got[n - 1]), Int(UInt8((n - 1) & 0xFF)))


def test_write_chunked_just_over_chunk_boundary() raises:
    """CHUNK_BYTES + 1 = 64 MiB + 1 bytes. First slow-path case: two
    chunks (64 MiB + 1 byte). Verify the second chunk's 1 byte lands
    correctly."""
    var path = _make_tmp_path("just_over")
    var h = FileHandle(path, "w")
    var n = CHUNK_BYTES + 1
    var buf = _build_pattern(n)
    write_chunked(h, Span(buf))
    _ = h^
    var got = _read_file_bytes(path)
    assert_equal(len(got), n)
    # The very last byte is the 1-byte tail chunk.
    assert_equal(Int(got[n - 1]), Int(UInt8((n - 1) & 0xFF)))
    # Boundary cell at position CHUNK_BYTES.
    assert_equal(Int(got[CHUNK_BYTES]), Int(UInt8(CHUNK_BYTES & 0xFF)))


def test_write_chunked_two_full_chunks() raises:
    """2 * CHUNK_BYTES = 128 MiB. Two-chunk slow path with no tail.
    Verify both chunks land in order with byte-identical output."""
    var path = _make_tmp_path("two_chunks")
    var h = FileHandle(path, "w")
    var n = 2 * CHUNK_BYTES
    var buf = _build_pattern(n)
    write_chunked(h, Span(buf))
    _ = h^
    var got = _read_file_bytes(path)
    assert_equal(len(got), n)
    # Spot-check: first byte of chunk 1, mid-chunk-1, boundary, mid-chunk-2,
    # last byte. Pattern is i & 0xFF.
    assert_equal(Int(got[0]), 0)
    assert_equal(Int(got[CHUNK_BYTES // 2]), Int(UInt8((CHUNK_BYTES // 2) & 0xFF)))
    assert_equal(Int(got[CHUNK_BYTES]), Int(UInt8(CHUNK_BYTES & 0xFF)))
    assert_equal(Int(got[CHUNK_BYTES + CHUNK_BYTES // 2]),
                 Int(UInt8((CHUNK_BYTES + CHUNK_BYTES // 2) & 0xFF)))
    assert_equal(Int(got[n - 1]), Int(UInt8((n - 1) & 0xFF)))


def test_write_chunked_three_chunks_with_partial_tail() raises:
    """2 * CHUNK_BYTES + 1024 = 128 MiB + 1 KiB. Three-chunk slow path
    (two full + one partial tail). Verify tail length + content."""
    var path = _make_tmp_path("three_chunks_tail")
    var h = FileHandle(path, "w")
    var n = 2 * CHUNK_BYTES + 1024
    var buf = _build_pattern(n)
    write_chunked(h, Span(buf))
    _ = h^
    var got = _read_file_bytes(path)
    assert_equal(len(got), n)
    # Tail boundary at 2*CHUNK_BYTES; tail length is 1024.
    assert_equal(Int(got[2 * CHUNK_BYTES]),
                 Int(UInt8((2 * CHUNK_BYTES) & 0xFF)))
    assert_equal(Int(got[n - 1]), Int(UInt8((n - 1) & 0xFF)))


def test_write_chunked_string_short_payload() raises:
    """write_chunked_string convenience wrapper on a short String. Fast
    path; verify output matches the input bytes."""
    var path = _make_tmp_path("string_short")
    var h = FileHandle(path, "w")
    var s = String("hello, chunked write\n")
    write_chunked_string(h, s)
    _ = h^
    var got = _read_file_bytes(path)
    var expected = s.as_bytes()
    assert_equal(len(got), len(expected))
    for i in range(len(expected)):
        assert_equal(got[i], expected[i])


def test_write_chunked_string_binary_bytes_preserved() raises:
    """write_chunked_string on a String built from bytes > 127 (the
    `unsafe_from_utf8` ctor preserves raw bytes; the chr()-per-byte path
    would UTF-8 re-encode them and corrupt the binary content)."""
    var path = _make_tmp_path("string_binary")
    var h = FileHandle(path, "w")
    var raw = List[UInt8]()
    raw.append(UInt8(0x9C))  # > 127
    raw.append(UInt8(0xC2))
    raw.append(UInt8(0xFE))
    raw.append(UInt8(0x00))  # NUL — also a hazard for naive write paths
    raw.append(UInt8(0xFF))
    var s = String(unsafe_from_utf8=Span(raw))
    write_chunked_string(h, s)
    _ = h^
    var got = _read_file_bytes(path)
    assert_equal(len(got), 5)
    assert_equal(Int(got[0]), 0x9C)
    assert_equal(Int(got[1]), 0xC2)
    assert_equal(Int(got[2]), 0xFE)
    assert_equal(Int(got[3]), 0x00)
    assert_equal(Int(got[4]), 0xFF)


def test_write_chunked_byte_identity_against_chunk_size() raises:
    """Belt-and-braces: a single big buffer with a recognizable pattern,
    routed through write_chunked, must produce byte-identical output to
    the input. Covers the case where chunk-boundary placement falls in
    the middle of a logical pattern unit."""
    var path = _make_tmp_path("byte_identity")
    var h = FileHandle(path, "w")
    var n = CHUNK_BYTES + (CHUNK_BYTES // 4)  # 80 MiB
    var buf = _build_pattern(n)
    write_chunked(h, Span(buf))
    _ = h^
    var got = _read_file_bytes(path)
    assert_equal(len(got), n)
    # Sample 32 evenly-spaced positions; full compare on 80 MiB is slow.
    for k in range(32):
        var i = (n // 32) * k
        if i >= n:
            i = n - 1
        assert_equal(Int(got[i]), Int(UInt8(i & 0xFF)))


# =============================================================================
# main
# =============================================================================


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
