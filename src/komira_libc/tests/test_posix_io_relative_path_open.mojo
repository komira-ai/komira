# =============================================================================
# test_posix_io_relative_path_open.mojo — AT_FDCWD platform-constant guard for
# the posix_io.mojo WRITE path (RawWriteFd.open_truncate et al.).
# =============================================================================
#
# BUG CLASS (the falsifier this test pins):
#   `posix_io.mojo` routes its open(2) through the fixed-arity C shim
#   `komira_openat_creat(dirfd, path, oflag, mode)`, passing `dirfd =
#   AT_FDCWD`. The Mojo side hardcoded `AT_FDCWD = -2` — the macOS value.
#   On LINUX `AT_FDCWD == -100`, so `openat(-2, relpath, ...)` is rejected
#   with EBADF for any RELATIVE path (`openat` ignores `dirfd` ONLY for
#   ABSOLUTE paths — which is why the existing write tests, all using
#   /tmp/... absolute paths, would mask the bug). The `mmap_region.mojo`
#   READ path has the same hazard (a literal `-2` dirfd gives EBADF).
#
#   With a hardcoded `-2`, `RawWriteFd.open_truncate` on a RELATIVE path
#   raises "openat() failed" on Linux, so the write+readback assert never
#   runs and the test FAILS. `_at_fdcwd()` returns -100 on Linux and -2 on
#   macOS, so the relative-path open succeeds and the bytes round-trip.
#
# The relative path is created under the test's CWD and removed afterward.
# =============================================================================

from std.io import FileHandle
from std.os.path import exists
from std.os import remove
from std.testing import TestSuite, assert_equal, assert_true

from komira_libc.posix_io import RawWriteFd


def _read_file_bytes(path: String) raises -> List[UInt8]:
    var h = FileHandle(path, "r")
    var raw = h.read_bytes(1024 * 1024)
    h.close()
    return raw^


def _cleanup(path: String) raises:
    if exists(path):
        remove(path)


def test_open_truncate_relative_path_round_trip() raises:
    """RawWriteFd.open_truncate on a RELATIVE path must succeed and the
    bytes must round-trip. This is the direct AT_FDCWD-platform-constant
    falsifier: with the macOS `-2` dirfd hardcoded, Linux openat rejects
    the relative path with EBADF and open_truncate raises here."""
    var path = String("komira_test_posix_io_relpath.bin")
    _cleanup(path)

    var src = List[UInt8]()
    for i in range(256):
        src.append(UInt8(i & 0xFF))

    var fd = RawWriteFd.open_truncate(path)
    fd.write_bytes(Span(src))
    fd.close()

    assert_true(exists(path), "relative-path file must exist after write")
    var got = _read_file_bytes(path)
    assert_equal(len(got), 256, "round-trip length must be 256")
    for i in range(256):
        assert_equal(
            Int(got[i]),
            Int(UInt8(i & 0xFF)),
            "byte mismatch at offset " + String(i),
        )
    _cleanup(path)


def main() raises:
    var suite = TestSuite()
    suite.test[test_open_truncate_relative_path_round_trip]()
    suite^.run()
