# =============================================================================
# test_large_writes.mojo — >2 GiB write coverage (an on-demand binary)
# =============================================================================
#
# These legs need ~2.7 GB of free RAM for a pattern buffer, ~2.7 GB of free
# scratch disk and several seconds of wall time, so this file is built as the
# `large_writes_check` binary rather than a gated test of the library, and
# runs only when invoked with `buck2 run`. There is no environment switch —
# running the binary IS the opt-in.
#
#   * `write_chunked` must land every byte of a >INT32_MAX payload on disk.
#   * A >2 GiB String handed directly to `FileHandle.write` silently flushes
#     0 bytes (the stdlib failure mode `write_chunked` works around); that
#     shape is locked in so a stdlib fix surfaces as a failure here.
#   * `write_all_fd` pushes a >INT_MAX payload to a real fd at the shipped
#     per-call clamp. This leg is scale coverage, NOT the clamp's falsifier:
#     on linux it passes with and without the clamp, because linux
#     short-writes where darwin refuses. The falsifier is
#     `test_fd_write_all_clamps_per_call_length.mojo`.
# =============================================================================

from std.ffi import external_call
from std.io import FileHandle
from std.sys.info import CompilationTarget
from std.testing import TestSuite, assert_equal, assert_true

from komira_core_ffi.posix import _read_env
from komira_core.io.chunked_read import read_chunked
from komira_core.io.chunked_write import write_chunked
from komira_core.io.fd_write_all import write_all_fd
from komira_core.io.posix_io import RawWriteFd


# ---------------------------------------------------------------------------
# ⚠ $TEST_TMPDIR, NOT A HARD-CODED `/tmp` PATH. A test may be executed by more
# than one action at a time on one worker, and a fixed `/tmp` path is shared by
# all of them; `TEST_TMPDIR` is unique per execution.
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


def _make_tmp_path(name: String) raises -> String:
    """A scratch file path; each test name is distinct."""
    return (_scratch_dir() + String("/komira_test_large_writes_")) + name


def _build_pattern(n: Int) -> List[UInt8]:
    """A deterministic n-byte pattern (i % 256)."""
    var out = List[UInt8](capacity=n)
    for i in range(n):
        out.append(UInt8(i & 0xFF))
    return out^


@always_inline
def _at_fdcwd() -> Int32:
    """-2 on Darwin, -100 on Linux. POSIX mandates no value; the wrong one makes
    every relative-path `openat(2)` fail with EBADF. Same constant, same reason,
    as `posix_io.mojo:_at_fdcwd`."""
    comptime if CompilationTarget.is_macos():
        return Int32(-2)
    else:
        return Int32(-100)


def _close(fd: Int32):
    if fd >= 0:
        _ = external_call["close", Int32](fd)


# =============================================================================
# write_chunked above the 2 GiB threshold
# =============================================================================


def test_write_chunked_above_2gb_threshold_emits_full_bytes() raises:
    """2.75 GiB routed through write_chunked must land the full byte count on
    disk. The direct pattern
    (`FileHandle.write(String(unsafe_from_utf8=Span(2.7GB)))`) silently
    flushes 0 bytes — see
    `test_filehandle_write_above_2gb_silent_data_loss_REGRESSION` below.
    """
    var path = _make_tmp_path("above_2gb_chunked")
    var h = FileHandle(path, "w")
    # 2.75 GB — exceeds INT32_MAX (~2.147 GB) so the stdlib's bug fires.
    var n = (2 * 1024 * 1024 * 1024) + (768 * 1024 * 1024)  # 2.75 GiB
    var buf = _build_pattern(n)
    write_chunked(h, Span(buf))
    _ = h^
    # The whole point: file size on disk MUST equal n.
    var h2 = FileHandle(path, "r")
    _ = h2.seek(0, 2)  # SEEK_END
    var sz = Int(h2.seek(0, 1))  # SEEK_CUR
    _ = h2^
    assert_equal(sz, n)


def test_filehandle_write_above_2gb_silent_data_loss_REGRESSION() raises:
    """Document the Mojo stdlib failure mode that `write_chunked` works
    around: handing a >2 GB String directly to `FileHandle.write` silently
    flushes 0 bytes (no exception). This test EXPECTS the bug — it asserts
    the on-disk size is 0, locking the failure shape so any future stdlib fix
    surfaces as a test failure (prompting removal of the chunked workaround).
    """
    var path = _make_tmp_path("above_2gb_direct_BUG")
    var h = FileHandle(path, "w")
    var n = (2 * 1024 * 1024 * 1024) + (768 * 1024 * 1024)  # 2.75 GiB
    var buf = _build_pattern(n)
    # DELIBERATE bug-pattern invocation: the direct write that produces a
    # 0-byte file for a >2 GiB payload.
    var s = String(unsafe_from_utf8=Span(buf))
    h.write(s)
    _ = h^
    var h2 = FileHandle(path, "r")
    _ = h2.seek(0, 2)
    var sz = Int(h2.seek(0, 1))
    _ = h2^
    # If this assertion ever FAILS, the stdlib has fixed the underlying
    # bug and the chunked-write workaround can be removed. Until then,
    # the bug-reproduction is locked in as documentation.
    assert_equal(sz, 0)


# =============================================================================
# write_all_fd above INT_MAX, to a real fd
# =============================================================================


def test_above_int_max_payload_reaches_a_real_fd() raises:
    """Push 2 GiB + 4 KiB through the REAL `write_all_fd` at the REAL shipped
    clamp, to a REAL fd, and assert the kernel accepted every byte.

    On linux this CANNOT FAIL: `write(2)` there caps a single call at
    `0x7ffff000` and returns a partial write, so an unclamped loop completes
    too. The clamp's falsifier is the socketpair test in
    `test_fd_write_all_clamps_per_call_length.mojo`; this leg is scale
    coverage, not proof.

    The source is a SPARSE file mmapped read-only (`pwrite_at` one byte at the
    last offset), so the 2 GiB costs ~one page of disk and page cache the kernel
    can evict, not 2 GiB of anonymous heap. The sink is `/dev/null`, so the
    assertion is over the byte count `write(2)` itself reported, which is the
    number that is -1 when darwin refuses an unclamped call."""
    var total = 2 * 1024 * 1024 * 1024 + 4096
    var path = _scratch_dir() + "/fd_write_all_above_int_max.bin"
    var marker = List[UInt8]()
    marker.append(UInt8(0x5A))
    var w = RawWriteFd.open_truncate(path)
    w.pwrite_at(total - 1, Span(marker))
    w.close()

    var buf = read_chunked(path)
    var span = buf.view_range_ro(0, buf.len()).into_span()
    assert_equal(len(span), total, "the sparse source is the size we asked for")
    assert_true(
        total > 2147483647,
        "this leg is pointless below INT_MAX",
    )

    # O_WRONLY only: /dev/null exists, so no O_CREAT and no platform-divergent
    # flag bits are needed here.
    # SAFETY: `sink_path` is held alive across the syscall by this local; the
    # kernel copies the path and retains nothing.
    var sink_path = String("/dev/null")
    var sink = external_call["komira_openat_creat", Int32](
        _at_fdcwd(),
        sink_path.as_c_string_slice().unsafe_ptr(),
        Int32(1),
        Int32(420),
    )
    if sink < 0:
        raise Error("could not open /dev/null for writing")
    var claimed = 0
    try:
        claimed = write_all_fd(sink, span, String("large-write test"))
    except e:
        _close(sink)
        raise e
    _close(sink)
    assert_equal(claimed, total, "every byte above INT_MAX was accepted")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
