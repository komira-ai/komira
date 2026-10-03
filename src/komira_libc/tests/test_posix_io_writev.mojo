# =============================================================================
# test_posix_io_writev.mojo — RawWriteFd + writev_addr_len smoke + edge cases.
# =============================================================================
#
# Asserts the FFI primitive that the StreamingFileBodySink uses to coalesce per-buffer
# writes into ONE writev syscall per RecordBatch.
#
# Test cases:
#   1. 0-byte file (open + close, no writes) → file exists, size 0.
#   2. Single write_bytes → byte-identity.
#   3. writev_addr_len with N=1 → single iovec; byte-identity.
#   4. writev_addr_len with N=4 → 4 disjoint buffers; concatenated byte-
#      identity in file.
#   5. Mixed: write_bytes header + writev_addr_len body + write_bytes
#      footer — interleaved write semantics; byte-identity for the full
#      file.
#   6. Empty iovec list (n=0) → no-op, no syscall.
# =============================================================================

from std.io import FileHandle
from std.os.path import exists
from std.os import remove
from std.testing import assert_equal, assert_true

from komira_libc.posix_io import RawWriteFd, fsync_path
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


def _read_file_bytes(path: String) raises -> List[UInt8]:
    """Read entire file as bytes. Used to verify byte-identity.

    Uses `FileHandle.read_bytes()` (NOT `.read()`) so non-UTF-8
    payloads (e.g. raw 0xAA, 0xFF) round-trip correctly.
    """
    var h = FileHandle(path, "r")
    # Read until EOF: pass a large size; FileHandle.read_bytes returns
    # only what's available. For 1 KB test files this is always one
    # call.
    var raw = h.read_bytes(1024 * 1024)
    h.close()
    return raw^


def _tmp_path(name: String) -> String:
    return (_scratch_dir() + String("/komira_test_posix_io_")) + name + ".bin"


def _cleanup(path: String) raises:
    if exists(path):
        remove(path)


def _make_bytes(*vals: Int) raises -> List[UInt8]:
    var out = List[UInt8]()
    for v in vals:
        out.append(UInt8(v))
    return out^


def test_open_close_empty() raises:
    var path = _tmp_path("open_close")
    _cleanup(path)
    var w = RawWriteFd.open_truncate(path)
    w.close()
    assert_true(exists(path), "file not created")
    var bytes = _read_file_bytes(path)
    assert_equal(len(bytes), 0, "expected size 0")
    _cleanup(path)
    print("test_open_close_empty: PASS")


def test_write_bytes_single() raises:
    var path = _tmp_path("write_single")
    _cleanup(path)
    var w = RawWriteFd.open_truncate(path)
    var data = _make_bytes(0x41, 0x42, 0x43, 0x44)
    w.write_bytes(Span(data))
    w.close()
    var bytes = _read_file_bytes(path)
    assert_equal(len(bytes), 4)
    assert_equal(Int(bytes[0]), 0x41)
    assert_equal(Int(bytes[1]), 0x42)
    assert_equal(Int(bytes[2]), 0x43)
    assert_equal(Int(bytes[3]), 0x44)
    _cleanup(path)
    print("test_write_bytes_single: PASS")


def test_writev_n1() raises:
    """writev with N=1 — degenerate case; equivalent to write_bytes."""
    var path = _tmp_path("writev_n1")
    _cleanup(path)
    var w = RawWriteFd.open_truncate(path)
    var data = _make_bytes(0x10, 0x20, 0x30)
    var addrs = List[Int]()
    addrs.append(Int(Span(data).unsafe_ptr()))
    var lens = List[Int]()
    lens.append(3)
    var rc = w.writev_addr_len(Span(addrs), Span(lens))
    assert_equal(rc, 3)
    w.close()
    var bytes = _read_file_bytes(path)
    assert_equal(len(bytes), 3)
    assert_equal(Int(bytes[0]), 0x10)
    assert_equal(Int(bytes[1]), 0x20)
    assert_equal(Int(bytes[2]), 0x30)
    _cleanup(path)
    _ = data^
    print("test_writev_n1: PASS")


def test_writev_n4() raises:
    """writev with N=4 disjoint buffers — the core gather contract.

    Verifies:
      - ONE syscall writes all 4 buffers.
      - On-disk byte sequence is concatenation of the 4 in order.
    """
    var path = _tmp_path("writev_n4")
    _cleanup(path)
    var w = RawWriteFd.open_truncate(path)

    var b1 = _make_bytes(0xAA, 0xBB)
    var b2 = _make_bytes(0xCC)
    var b3 = _make_bytes(0xDD, 0xEE, 0xFF)
    var b4 = _make_bytes(0x11, 0x22, 0x33, 0x44)

    var addrs = List[Int]()
    addrs.append(Int(Span(b1).unsafe_ptr()))
    addrs.append(Int(Span(b2).unsafe_ptr()))
    addrs.append(Int(Span(b3).unsafe_ptr()))
    addrs.append(Int(Span(b4).unsafe_ptr()))
    var lens = List[Int]()
    lens.append(2)
    lens.append(1)
    lens.append(3)
    lens.append(4)
    var rc = w.writev_addr_len(Span(addrs), Span(lens))
    assert_equal(rc, 10)
    w.close()
    var bytes = _read_file_bytes(path)
    assert_equal(len(bytes), 10)
    # Expected concatenation: AA BB CC DD EE FF 11 22 33 44
    var expected = _make_bytes(
        0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF, 0x11, 0x22, 0x33, 0x44
    )
    for i in range(10):
        assert_equal(
            Int(bytes[i]), Int(expected[i]), "byte mismatch at i"
        )
    _cleanup(path)
    # Keep buffers alive to the end of scope.
    _ = b1^
    _ = b2^
    _ = b3^
    _ = b4^
    print("test_writev_n4: PASS")


def test_writev_mixed_write_writev() raises:
    """Mixed sequence: write_bytes header + writev body + write_bytes
    footer. Verifies kernel file-position advances correctly across
    the two syscalls types via the same fd."""
    var path = _tmp_path("mixed")
    _cleanup(path)
    var w = RawWriteFd.open_truncate(path)
    var header = _make_bytes(0xA1, 0xA2)
    w.write_bytes(Span(header))
    var body1 = _make_bytes(0xB1, 0xB2, 0xB3)
    var body2 = _make_bytes(0xC1, 0xC2)
    var addrs = List[Int]()
    addrs.append(Int(Span(body1).unsafe_ptr()))
    addrs.append(Int(Span(body2).unsafe_ptr()))
    var lens = List[Int]()
    lens.append(3)
    lens.append(2)
    _ = w.writev_addr_len(Span(addrs), Span(lens))
    var footer = _make_bytes(0xF1)
    w.write_bytes(Span(footer))
    w.close()
    var bytes = _read_file_bytes(path)
    assert_equal(len(bytes), 8)
    var expected = _make_bytes(
        0xA1, 0xA2, 0xB1, 0xB2, 0xB3, 0xC1, 0xC2, 0xF1
    )
    for i in range(8):
        assert_equal(Int(bytes[i]), Int(expected[i]))
    _cleanup(path)
    _ = header^
    _ = body1^
    _ = body2^
    _ = footer^
    print("test_writev_mixed_write_writev: PASS")


def test_writev_empty() raises:
    """N=0 iovec list — no-op, no syscall, file remains empty."""
    var path = _tmp_path("writev_empty")
    _cleanup(path)
    var w = RawWriteFd.open_truncate(path)
    var addrs = List[Int]()
    var lens = List[Int]()
    var rc = w.writev_addr_len(Span(addrs), Span(lens))
    assert_equal(rc, 0)
    w.close()
    var bytes = _read_file_bytes(path)
    assert_equal(len(bytes), 0)
    _cleanup(path)
    print("test_writev_empty: PASS")


def test_open_existing_append_dual_fd_interleave() raises:
    """Dual-fd interleave smoke. Writes the file via TWO fds (one stdlib FileHandle,
    one RawWriteFd opened with O_APPEND on the existing file). Verifies:

      1. RawWriteFd.open_existing_append succeeds on a file that already
         has bytes written via FileHandle (i.e. doesn't re-truncate).
      2. The interleave sequence
         [FileHandle.header → RawWriteFd.body → FileHandle.footer]
         produces a byte-identical file (no data loss, no out-of-order
         landing, no overwrite of header bytes).
      3. Closing RawWriteFd does not corrupt FileHandle state — the
         post-writev FileHandle write lands at the correct offset.

    This is the load-bearing safety smoke for a dual-fd path-mode file
    sink (stdlib FileHandle for framing, RawWriteFd for bodies).
    """
    var path = _tmp_path("dual_fd_interleave")
    _cleanup(path)

    # Step 1: open + write header via FileHandle (truncates the file).
    var fh = FileHandle(path, "w")
    var header = _make_bytes(0x48, 0x44, 0x52)  # "HDR"
    fh.write_bytes(Span(header))

    # Step 2: open RawWriteFd in append mode on the same path.
    # File now contains "HDR" (3 bytes); RawWriteFd's first writev should
    # land bytes 3..N via O_APPEND atomic-seek-to-EOF.
    #
    # REGRESSION GUARD: O_APPEND is platform-specific (Darwin 0x0008, Linux
    # 0x0400; posix_io.mojo:_o_append). With the Darwin constant on Linux the
    # fd opens WITHOUT O_APPEND, so this writev lands at offset 0 and
    # CLOBBERS "HDR" — the file ends up "BDY12FOO" (8 bytes) instead of
    # "HDRBDY12FOO" (11). The bug is latent on macOS, so this test must run
    # on Linux to catch it.
    var raw = RawWriteFd.open_existing_append(path)
    var b1 = _make_bytes(0x42, 0x44, 0x59)  # "BDY"
    var b2 = _make_bytes(0x31, 0x32)  # "12"
    var addrs = List[Int]()
    addrs.append(Int(Span(b1).unsafe_ptr()))
    addrs.append(Int(Span(b2).unsafe_ptr()))
    var lens = List[Int]()
    lens.append(3)
    lens.append(2)
    var rc = raw.writev_addr_len(Span(addrs), Span(lens))
    assert_equal(rc, 5)
    raw.close()

    # Step 3: write footer via FileHandle. CRITICAL: FileHandle's own
    # offset is still at 3 (where it last wrote); without re-seeking,
    # write_bytes("FOO") would overwrite the "BDY" bytes we just landed
    # at offsets 3-5. The dual-fd contract REQUIRES the FileHandle to
    # re-sync to EOF before each post-writev write. This is the load-
    # bearing safety dance.
    _ = fh.seek(0, 2)  # SEEK_END
    var footer = _make_bytes(0x46, 0x4F, 0x4F)  # "FOO"
    fh.write_bytes(Span(footer))
    fh.close()

    # Verify byte-identity: "HDR" + "BDY" + "12" + "FOO".
    var bytes = _read_file_bytes(path)
    assert_equal(len(bytes), 11)
    var expected = _make_bytes(
        0x48, 0x44, 0x52,  # HDR
        0x42, 0x44, 0x59,  # BDY
        0x31, 0x32,        # 12
        0x46, 0x4F, 0x4F,  # FOO
    )
    for i in range(11):
        assert_equal(
            Int(bytes[i]), Int(expected[i]),
            "byte mismatch at i — dual-fd interleave landed wrong",
        )
    _cleanup(path)
    _ = header^
    _ = b1^
    _ = b2^
    _ = footer^
    print("test_open_existing_append_dual_fd_interleave: PASS")


def test_fsync_after_write() raises:
    """RawWriteFd.fsync on an open fd that just had bytes written via write_bytes returns 0 and
    preserves file content (fsync is a flush, not a truncate)."""
    var path = _tmp_path("fsync_after_write")
    _cleanup(path)
    var w = RawWriteFd.open_truncate(path)
    var data = _make_bytes(0x55, 0x66, 0x77, 0x88)
    w.write_bytes(Span(data))
    w.fsync()  # must succeed; file content must survive.
    w.close()
    var bytes = _read_file_bytes(path)
    assert_equal(len(bytes), 4)
    assert_equal(Int(bytes[0]), 0x55)
    assert_equal(Int(bytes[3]), 0x88)
    _cleanup(path)
    _ = data^
    print("test_fsync_after_write: PASS")


def test_fsync_path_helper() raises:
    """The module-level `fsync_path(path)` helper opens the file via the
    dual-fd append pattern, fsyncs, closes — without touching the file
    content. A writer calls it after writing a file to make the write
    durable.

    Verifies:
      1. fsync_path on a file with bytes written succeeds (returns).
      2. File content is byte-identical before vs after the fsync.
      3. fsync_path on a non-existent path raises (open fails).
    """
    var path = _tmp_path("fsync_path_helper")
    _cleanup(path)

    # Write some bytes via the stdlib FileHandle (simulates SDK write_*).
    var fh = FileHandle(path, "w")
    var data = _make_bytes(0xDE, 0xAD, 0xBE, 0xEF, 0x42)
    fh.write_bytes(Span(data))
    fh.close()

    # fsync_path on the just-written file: no error, content preserved.
    fsync_path(path)
    var bytes = _read_file_bytes(path)
    assert_equal(len(bytes), 5)
    assert_equal(Int(bytes[0]), 0xDE)
    assert_equal(Int(bytes[1]), 0xAD)
    assert_equal(Int(bytes[4]), 0x42)

    # fsync_path on a non-existent path: must raise.
    var missing = _tmp_path("nonexistent_DO_NOT_CREATE")
    _cleanup(missing)
    var raised = False
    try:
        fsync_path(missing)
    except:
        raised = True
    assert_true(raised, "fsync_path on missing file must raise")

    _cleanup(path)
    _ = data^
    print("test_fsync_path_helper: PASS")


def main() raises:
    test_open_close_empty()
    test_write_bytes_single()
    test_writev_n1()
    test_writev_n4()
    test_writev_mixed_write_writev()
    test_writev_empty()
    test_open_existing_append_dual_fd_interleave()
    test_fsync_after_write()
    test_fsync_path_helper()
    print("ALL POSIX_IO WRITEV TESTS PASSED")
