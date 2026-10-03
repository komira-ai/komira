# =============================================================================
# test_pwrite_at.mojo — positional-write POSIX helpers
# =============================================================================
#
# Direct unit-test coverage for the `RawWriteFd.pwrite_at` and
# `RawWriteFd.ftruncate_size` POSIX helpers in `io/posix_io.mojo`.
#
# These primitives are the load-bearing infrastructure for a parallel-pwrite
# JSONL WRITE path (a file sink's `accept_jsonl`): N encoder workers compute per-worker
# byte buffers; the main thread prefix-sums byte sizes into per-worker
# file offsets; N writer workers `pwrite_at` their buffers in parallel
# to disjoint file ranges of the same fd.
#
# Coverage matrix:
#   T1  — pwrite_at at offset 0 on an empty file (basic correctness).
#   T2  — pwrite_at at offset > 0 (positional write with auto-extend).
#   T3  — sequential pwrite_at calls at increasing offsets (mirror of the
#         JSONL multi-batch shape that the file_sink uses serially).
#   T4  — pwrite_at at offsets that produce a contiguous file (mirror of
#         the JSONL parallel-pwrite shape — offsets land back-to-back
#         from a prefix-sum and the resulting file is byte-identical
#         to a sequential append).
#   T5  — pwrite_at empty-bytes is a no-op (no syscall, no error).
#   T6  — ftruncate_size to a specific size, then read back to confirm
#         file is exactly that size with trailing zero bytes.
#   T7  — ftruncate_size + pwrite_at into the truncated range (mirrors
#         the file_sink's "ftruncate to EOF, then per-worker pwrite to
#         disjoint ranges" shape).
#   T8  — ftruncate_size to ZERO truncates an existing file.
#   T9  — pwrite_at on a closed fd raises (sentinel-state safety).
#   T10 — ftruncate_size on a closed fd raises.
#   T11 — pwrite_at with negative offset raises (input validation).
#   T12 — ftruncate_size with negative length raises (input validation).
# =============================================================================

from std.io import FileHandle
from std.testing import TestSuite, assert_equal, assert_true

from komira_libc.posix_io import RawWriteFd
from komira_libc.posix import _read_env


# ---------------------------------------------------------------------------
# ⚠ $TEST_TMPDIR, NOT A HARD-CODED `/tmp` PATH.
#
# The same test can run more than once at a time on one host. A fixed `/tmp`
# path is shared by every one of those executions, and no `TMPDIR` /
# `TEST_TMPDIR` the runner sets can redirect it. `TEST_TMPDIR` is private to
# each test execution, which is what keeps them disjoint.
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
    """Construct a fresh tmp file path under /tmp."""
    return (_scratch_dir() + String("/komira_test_pwrite_at_")) + name


def _read_file_bytes(path: String) raises -> List[UInt8]:
    """Read the whole file at `path` into a List[UInt8]."""
    var h = FileHandle(path, "r")
    _ = h.seek(0, 2)  # SEEK_END
    var size = Int(h.seek(0, 1))  # SEEK_CUR == 0 after SEEK_END
    _ = h.seek(0, 0)  # SEEK_SET
    var s = h.read_bytes(size)
    var out = List[UInt8]()
    out.reserve(len(s))
    var i = 0
    while i < len(s):
        out.append(s[i])
        i = i + 1
    return out^


def _bytes(b: String) -> List[UInt8]:
    """Materialize a String into a fresh List[UInt8] for write input."""
    var out = List[UInt8]()
    var bs = b.as_bytes()
    out.reserve(len(bs))
    var i = 0
    while i < len(bs):
        out.append(bs[i])
        i = i + 1
    return out^


def _assert_bytes_eq(actual: List[UInt8], expected: List[UInt8]) raises:
    assert_equal(len(actual), len(expected))
    var i = 0
    while i < len(actual):
        if actual[i] != expected[i]:
            raise Error(
                "Byte mismatch at offset " + String(i)
                + ": got " + String(Int(actual[i]))
                + ", expected " + String(Int(expected[i]))
            )
        i = i + 1


# =============================================================================
# Tests
# =============================================================================


def test_t1_pwrite_at_offset_zero() raises:
    var path = _make_tmp_path("t1_offset_zero")
    var fd = RawWriteFd.open_truncate(path)
    var data = _bytes(String("hello world"))
    fd.pwrite_at(0, Span(data))
    fd.close()
    var read_back = _read_file_bytes(path)
    _assert_bytes_eq(read_back, data)


def test_t2_pwrite_at_nonzero_offset() raises:
    var path = _make_tmp_path("t2_nonzero_offset")
    var fd = RawWriteFd.open_truncate(path)
    var data = _bytes(String("XYZ"))
    # Write "XYZ" at offset 10 — auto-extends file, bytes 0..9 are zero.
    fd.pwrite_at(10, Span(data))
    fd.close()
    var read_back = _read_file_bytes(path)
    assert_equal(len(read_back), 13)
    # Bytes 0..9 must be zero (file extended).
    var i = 0
    while i < 10:
        assert_equal(Int(read_back[i]), 0)
        i = i + 1
    # Bytes 10..12 must be "XYZ".
    assert_equal(Int(read_back[10]), Int(UInt8(ord("X"))))
    assert_equal(Int(read_back[11]), Int(UInt8(ord("Y"))))
    assert_equal(Int(read_back[12]), Int(UInt8(ord("Z"))))


def test_t3_sequential_pwrite_at() raises:
    """Mirror of multi-batch serial path in `accept_jsonl` (each batch
    pwrites at the running `jsonl_offset` and advances)."""
    var path = _make_tmp_path("t3_sequential")
    var fd = RawWriteFd.open_truncate(path)
    var a = _bytes(String("aaaa"))
    var b = _bytes(String("BBBB"))
    var c = _bytes(String("ccccc"))
    var offset = 0
    fd.pwrite_at(offset, Span(a))
    offset = offset + len(a)
    fd.pwrite_at(offset, Span(b))
    offset = offset + len(b)
    fd.pwrite_at(offset, Span(c))
    offset = offset + len(c)
    fd.close()
    var read_back = _read_file_bytes(path)
    var expected = _bytes(String("aaaaBBBBccccc"))
    _assert_bytes_eq(read_back, expected)


def test_t4_pwrite_at_disjoint_offsets() raises:
    """Mirror of parallel pwrite path in `accept_jsonl`: prefix-sum
    offsets, then issue each worker's pwrite_at at its assigned offset.
    Verifies that disjoint-range pwrites concatenate into the expected
    contiguous file."""
    var path = _make_tmp_path("t4_disjoint")
    var fd = RawWriteFd.open_truncate(path)
    # Simulate 4 workers with byte buffers of varying sizes.
    var w0 = _bytes(String("WW0"))      # 3 bytes
    var w1 = _bytes(String("[ww1]"))    # 5 bytes
    var w2 = _bytes(String("ww-2-ww"))  # 7 bytes
    var w3 = _bytes(String("|"))        # 1 byte
    # Prefix-sum: w0 at 0, w1 at 3, w2 at 8, w3 at 15. Total = 16.
    fd.pwrite_at(0, Span(w0))
    fd.pwrite_at(3, Span(w1))
    fd.pwrite_at(8, Span(w2))
    fd.pwrite_at(15, Span(w3))
    fd.close()
    var read_back = _read_file_bytes(path)
    var expected = _bytes(String("WW0[ww1]ww-2-ww|"))
    _assert_bytes_eq(read_back, expected)


def test_t5_pwrite_at_empty_no_op() raises:
    var path = _make_tmp_path("t5_empty")
    var fd = RawWriteFd.open_truncate(path)
    var empty = List[UInt8]()
    # Empty write at offset 0 — must NOT extend the file, must NOT error.
    fd.pwrite_at(0, Span(empty))
    # Also at non-zero offset.
    fd.pwrite_at(100, Span(empty))
    fd.close()
    var read_back = _read_file_bytes(path)
    # File must still be 0 bytes — empty pwrite is a no-op (no syscall).
    assert_equal(len(read_back), 0)


def test_t6_ftruncate_size_basic() raises:
    var path = _make_tmp_path("t6_ftruncate_basic")
    var fd = RawWriteFd.open_truncate(path)
    fd.ftruncate_size(100)
    fd.close()
    var read_back = _read_file_bytes(path)
    assert_equal(len(read_back), 100)
    # All bytes must be zero (POSIX hole / zero-fill on extend).
    var i = 0
    while i < 100:
        assert_equal(Int(read_back[i]), 0)
        i = i + 1


def test_t7_ftruncate_then_pwrite_disjoint() raises:
    """Mirror of the `accept_jsonl` shape: ftruncate up-front
    to EOF, then per-worker disjoint pwrite_at fills the range."""
    var path = _make_tmp_path("t7_ftruncate_then_pwrite")
    var fd = RawWriteFd.open_truncate(path)
    # Pre-allocate 12 bytes via ftruncate.
    fd.ftruncate_size(12)
    # Fill via 3 disjoint pwrite_at calls.
    var a = _bytes(String("ABCD"))
    var b = _bytes(String("efgh"))
    var c = _bytes(String("IJKL"))
    fd.pwrite_at(0, Span(a))
    fd.pwrite_at(4, Span(b))
    fd.pwrite_at(8, Span(c))
    fd.close()
    var read_back = _read_file_bytes(path)
    var expected = _bytes(String("ABCDefghIJKL"))
    _assert_bytes_eq(read_back, expected)


def test_t8_ftruncate_size_zero() raises:
    var path = _make_tmp_path("t8_ftruncate_zero")
    var fd = RawWriteFd.open_truncate(path)
    # Write some bytes first.
    var data = _bytes(String("preexisting bytes"))
    fd.pwrite_at(0, Span(data))
    # Truncate back to 0 — bytes are discarded.
    fd.ftruncate_size(0)
    fd.close()
    var read_back = _read_file_bytes(path)
    assert_equal(len(read_back), 0)


def test_t9_pwrite_at_closed_fd_raises() raises:
    var path = _make_tmp_path("t9_closed_pwrite")
    var fd = RawWriteFd.open_truncate(path)
    fd.close()
    var data = _bytes(String("nope"))
    var raised = False
    try:
        fd.pwrite_at(0, Span(data))
    except:
        raised = True
    assert_true(raised, "pwrite_at on closed fd must raise")


def test_t10_ftruncate_size_closed_fd_raises() raises:
    var path = _make_tmp_path("t10_closed_ftruncate")
    var fd = RawWriteFd.open_truncate(path)
    fd.close()
    var raised = False
    try:
        fd.ftruncate_size(42)
    except:
        raised = True
    assert_true(raised, "ftruncate_size on closed fd must raise")


def test_t11_pwrite_at_negative_offset_raises() raises:
    var path = _make_tmp_path("t11_neg_offset")
    var fd = RawWriteFd.open_truncate(path)
    var data = _bytes(String("x"))
    var raised = False
    try:
        fd.pwrite_at(-1, Span(data))
    except:
        raised = True
    assert_true(raised, "pwrite_at with negative offset must raise")
    fd.close()


def test_t12_ftruncate_size_negative_length_raises() raises:
    var path = _make_tmp_path("t12_neg_length")
    var fd = RawWriteFd.open_truncate(path)
    var raised = False
    try:
        fd.ftruncate_size(-5)
    except:
        raised = True
    assert_true(raised, "ftruncate_size with negative length must raise")
    fd.close()


# =============================================================================
# Entry point
# =============================================================================


def main() raises:
    var suite = TestSuite()
    suite.test[test_t1_pwrite_at_offset_zero]()
    suite.test[test_t2_pwrite_at_nonzero_offset]()
    suite.test[test_t3_sequential_pwrite_at]()
    suite.test[test_t4_pwrite_at_disjoint_offsets]()
    suite.test[test_t5_pwrite_at_empty_no_op]()
    suite.test[test_t6_ftruncate_size_basic]()
    suite.test[test_t7_ftruncate_then_pwrite_disjoint]()
    suite.test[test_t8_ftruncate_size_zero]()
    suite.test[test_t9_pwrite_at_closed_fd_raises]()
    suite.test[test_t10_ftruncate_size_closed_fd_raises]()
    suite.test[test_t11_pwrite_at_negative_offset_raises]()
    suite.test[test_t12_ftruncate_size_negative_length_raises]()
    suite^.run()
