# =============================================================================
# test_mmap_region_open_readonly.mojo — FFI arg-marshaling regression guard
# for `MmapRegion.open_readonly` (Parquet/Arrow READ path).
# =============================================================================
#
# BUG CLASS (the falsifier this test pins):
#   `MmapRegion.open_readonly` opens a file (openat), fstats it for the
#   size, mmaps it MAP_PRIVATE+PROT_READ, then closes the fd. Issuing
#   those syscalls as RAW `external_call["openat"/"fstat"/"mmap"/"munmap",
#   ...]` with C-ABI integer arguments typed `Int32` / `Int` is unsafe:
#   under an AOT build `external_call`'s integer marshaling for these
#   syscalls can differ from the JIT path (raw-syscall-vs-glibc-wrapper +
#   C-`int` width/sign discrepancy). The symptom is the FIRST
#   `openat(AT_FDCWD, ...)` succeeding and a LATER fd-consuming syscall
#   receiving a garbage descriptor and returning EBADF, so
#   `open_readonly` raises "open() failed" on a perfectly readable file.
#
#   With raw calls this test raises out of `open_readonly` under AOT, so the
#   asserts never run and the test FAILS. Routing the syscalls through the
#   fixed-arity C shims (`komira_open_ro` / `komira_fstat_size` /
#   `komira_mmap_ro` / `komira_munmap`, all `int`/`long long` at the C ABI)
#   makes the bytes read back match what was written under BOTH JIT and AOT.
#
# The write path (`posix_io.mojo`) routes every fd syscall through a
# `komira_*` fixed-arity C shim for the same reason.
#
# This test is meaningful under AOT, the configuration where the bug lives;
# it can pass under JIT, which is the trap.
# =============================================================================

from std.io import FileHandle
from std.testing import TestSuite, assert_equal, assert_true

from komira_core.io.chunked_write import write_chunked
from komira_core.io.mmap_region import MmapRegion
from komira_core_ffi.posix import _read_env


# ---------------------------------------------------------------------------
# ⚠ $TEST_TMPDIR, NOT A HARD-CODED `/tmp` PATH.
#
# The same test can run more than once at a time on one host. A fixed `/tmp`
# path is shared by every one of those executions, and no `TMPDIR` /
# `TEST_TMPDIR` the runner sets can redirect it. `TEST_TMPDIR` is private to
# each test execution, which is what keeps them disjoint.
#
# ⚠ `_read_env`, NOT `std.os.getenv` — Mojo's MLIR FFI legalization allows at
# most ONE `getenv` declaration per link unit and `komira_core_ffi.posix` is
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


def _make_tmp_path(name: String) -> String:
    return (_scratch_dir() + String("/komira_test_mmap_region_")) + name


def _write_file_bytes(path: String, bytes: List[UInt8]) raises:
    """Write a `List[UInt8]` to `path` via the proven `write_chunked`
    helper (the same writer `test_chunked_read.mojo` uses)."""
    var h = FileHandle(path, "w")
    write_chunked(h, Span(bytes))
    _ = h^


def _build_pattern(n: Int) -> List[UInt8]:
    var out = List[UInt8](capacity=n)
    for i in range(n):
        out.append(UInt8(i & 0xFF))
    return out^


# =============================================================================
# Tests
# =============================================================================


def test_open_readonly_single_byte() raises:
    """1-byte file: the smallest non-zero mapping. Raw calls
    raise "open() failed" here under AOT because the fd / dirfd / flags
    are mis-marshaled; the shim path reads the byte back."""
    var path = _make_tmp_path("onebyte")
    var src = List[UInt8]()
    src.append(UInt8(0x42))
    _write_file_bytes(path, src)

    var region = MmapRegion.open_readonly(path)
    assert_equal(region.len(), 1, "mmap'd length must equal file size")
    var view = region.data()
    assert_equal(
        Int(view.read_u8_at(0)), 0x42, "first byte must read back as 0x42"
    )
    _ = region^


def test_open_readonly_small_payload_byte_identity() raises:
    """1 KiB deterministic pattern, full byte-for-byte compare. This is
    the direct READ-path falsifier: if the mmap open succeeds but the fd
    or size is mis-marshaled, the bytes will not match."""
    var path = _make_tmp_path("small_1k")
    var n = 1024
    var src = _build_pattern(n)
    _write_file_bytes(path, src)

    var region = MmapRegion.open_readonly(path)
    assert_equal(region.len(), n, "mmap'd length must equal file size")
    var view = region.data()
    for i in range(n):
        assert_equal(
            Int(view.read_u8_at(i)),
            Int(UInt8(i & 0xFF)),
            "byte mismatch at offset " + String(i),
        )
    _ = region^


def test_open_readonly_64k_byte_identity() raises:
    """64 KiB payload spanning > 1 page. Spot-check 64 evenly-spaced
    offsets so a mis-marshaled length / offset surfaces as a read fault
    or a value mismatch, not a silent first-page-only success."""
    var path = _make_tmp_path("sixtyfour_k")
    var n = 64 * 1024
    var src = _build_pattern(n)
    _write_file_bytes(path, src)

    var region = MmapRegion.open_readonly(path)
    assert_equal(region.len(), n, "mmap'd length must equal file size")
    var view = region.data()
    for k in range(64):
        var i = (n // 64) * k
        if i >= n:
            i = n - 1
        assert_equal(
            Int(view.read_u8_at(i)),
            Int(UInt8(i & 0xFF)),
            "byte mismatch at sampled offset " + String(i),
        )
    _ = region^


def test_open_readonly_missing_file_raises() raises:
    """A genuinely-absent path must still raise (openat returns a real
    negative fd). This guards against a fix that "succeeds" on a bad fd."""
    var path = _make_tmp_path("definitely_absent_xyzzy")
    # Best-effort: ensure it does not exist by NOT creating it.
    var raised = False
    try:
        var _r = MmapRegion.open_readonly(path)
    except:
        raised = True
    assert_true(raised, "open_readonly on a missing file must raise")


def main() raises:
    var suite = TestSuite()
    suite.test[test_open_readonly_single_byte]()
    suite.test[test_open_readonly_small_payload_byte_identity]()
    suite.test[test_open_readonly_64k_byte_identity]()
    suite.test[test_open_readonly_missing_file_raises]()
    suite^.run()
