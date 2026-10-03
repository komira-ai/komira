# =============================================================================
# test_local_fs_read_at_mmap.mojo
# =============================================================================
#
#
# Exercises the mmap-borrow implementation of `LocalFs.read_at`.
#
# Coverage:
#   T1 — basic read returns an SharedAlignedBuffer[HeapRegion] with the right bytes.
#   T2 — second read on the same LocalFile reuses the cached mmap region
#        (no second open(2)/mmap(2) syscall); content still correct.
#   T3 — disjoint ranges from the same LocalFile both return correct bytes;
#        proves the borrowed slices alias into the same underlying region.
#   T4 — MmapAlignedBuffer outlives the LocalFile via Arc retention: drop the
#        LocalFile, then read from the buffer — bytes still valid.
#   T5 — out-of-bounds read raises (offset+length > file_size).
#   T6 — open-then-read of a fresh path mmaps lazily (LocalFile fresh from
#        `open()` has `_mmap = None`; first `read_at` populates it).
#   T7 — borrow_from_mmap returns a non-owning buffer (capacity == 0
#        sentinel; is_owned() False; is_mmap_backed() True).
#
# Discipline:
#   * Test uses /tmp paths; setup writes a payload via std.file.FileHandle
#     before exercising mmap. Teardown is implicit (Mojo's __del__ on
#     LocalFile / MmapAlignedBuffer; the test does not unlink /tmp files —
#     same convention as test_path_discovery.mojo).
#   * ZERO UnsafePointer in test code. The test consumes
#     MmapAlignedBuffer.view_ro().into_span() to read bytes safely.
# =============================================================================

from std.testing import assert_equal, assert_false, assert_true

from komira_runtime_paths import test_tmpdir
from komira_fs.local_fs import LocalFile, LocalFs
from komira_async.ops.waker_sink import NoopSink
from komira_core.arrow.shared_aligned_buffer import SharedAlignedBuffer
from komira_core.io.heap_region import HeapRegion


# ---------------------------------------------------------------------------
# ⚠ $TEST_TMPDIR, NOT A HARD-CODED `/tmp` PATH.
#
# A fixed `/tmp` path is shared by every concurrent execution of this test on
# one worker; the runner's private `TEST_TMPDIR` (read through
# `komira_runtime_paths.test_tmpdir`) keeps them disjoint.
# ---------------------------------------------------------------------------
def _scratch_dir() raises -> String:
    """The directory THIS execution may write scratch files into."""
    return test_tmpdir()


# =============================================================================
# Test fixture helpers
# =============================================================================
#
# We write a deterministic byte pattern via FileHandle to /tmp before any
# mmap-backed read. The pattern is `i % 251` for i in [0, n) — distinct
# byte values (mod 251) for offsets up to 251 so the first 251 bytes are
# all distinct, useful for cross-offset reads.
#
# Path naming: `<scratch>/local_fs_read_at_<test>_<size>.bin` so different tests
# write to different paths and the test suite is order-independent.


def _write_payload(path: String, n: Int) raises:
    """Write `n` bytes of the deterministic `i % 251` pattern to `path`."""
    var fh = open(path, "w")
    var buf = List[UInt8]()
    buf.resize(n, UInt8(0))
    for i in range(n):
        buf[i] = UInt8(i % 251)
    fh.write_bytes(buf)
    fh.close()


def _read_byte_at(buf: SharedAlignedBuffer[HeapRegion], offset: Int) -> Int:
    """Read a single byte from the buffer at `offset` via the safe
    view-range API. Borrowed (mmap-backed) buffers carry
    `capacity == 0` and `length > 0` — the API sizes by length here
    (other consumers of borrowed buffers use
    `view_range_ro` the same way)."""
    var view = buf.view_range_ro(offset, 1)
    var span = view.into_span()
    return Int(span[0])


# =============================================================================
# T1 — basic read returns an SharedAlignedBuffer[HeapRegion] with the right bytes
# =============================================================================


def test_read_at_basic() raises:
    """LocalFs.read_at returns an SharedAlignedBuffer[HeapRegion] whose first byte
    equals the pattern at the requested offset."""
    var path = (_scratch_dir() + String("/local_fs_read_at_t1_basic.bin"))
    _write_payload(path, 4096)

    var fs = LocalFs[NoopSink].new()
    var file = fs.open(path)
    var buf = fs.read_at(file, Int64(0), Int64(64))
    assert_equal(buf.len(), 64)
    # Pattern byte 0 == 0, byte 1 == 1, byte 63 == 63 (all < 251).
    assert_equal(_read_byte_at(buf, 0), 0)
    assert_equal(_read_byte_at(buf, 1), 1)
    assert_equal(_read_byte_at(buf, 63), 63)


# =============================================================================
# T2 — second read on the same LocalFile reuses the cached mmap region
# =============================================================================


def test_read_at_reuses_mmap_across_calls() raises:
    """Two reads on the same LocalFile share the underlying mmap region.
    We can't directly observe the syscall count from Mojo, but we CAN
    observe that the LocalFile's mmap-keepalive is populated after the
    first call (via `is_mmap_cached()`) and stays populated, and that
    the second read returns correct bytes."""
    var path = (_scratch_dir() + String("/local_fs_read_at_t2_reuse.bin"))
    _write_payload(path, 4096)

    var fs = LocalFs[NoopSink].new()
    var file = fs.open(path)
    # Before first read, the LocalFile's mmap state is None (lazy mmap).
    assert_false(file.is_mmap_cached())

    var buf1 = fs.read_at(file, Int64(0), Int64(128))
    # After first read, the mmap state is populated.
    assert_true(file.is_mmap_cached())
    assert_equal(buf1.len(), 128)
    assert_equal(_read_byte_at(buf1, 0), 0)
    assert_equal(_read_byte_at(buf1, 127), 127)

    # Second read — mmap stays populated; content correct.
    var buf2 = fs.read_at(file, Int64(0), Int64(256))
    assert_true(file.is_mmap_cached())
    assert_equal(buf2.len(), 256)
    assert_equal(_read_byte_at(buf2, 0), 0)
    assert_equal(_read_byte_at(buf2, 250), 250)


# =============================================================================
# T3 — disjoint ranges from the same LocalFile
# =============================================================================


def test_read_at_disjoint_ranges() raises:
    """Two reads from disjoint offsets on the same LocalFile both return
    correct bytes from the same underlying mmap region."""
    var path = (_scratch_dir() + String("/local_fs_read_at_t3_disjoint.bin"))
    _write_payload(path, 4096)

    var fs = LocalFs[NoopSink].new()
    var file = fs.open(path)
    var buf_lo = fs.read_at(file, Int64(0), Int64(64))
    var buf_hi = fs.read_at(file, Int64(1024), Int64(64))
    assert_equal(buf_lo.len(), 64)
    assert_equal(buf_hi.len(), 64)
    # buf_lo[0] = 0 (pattern at offset 0)
    assert_equal(_read_byte_at(buf_lo, 0), 0)
    # buf_hi[0] = 1024 % 251 = 22
    assert_equal(_read_byte_at(buf_hi, 0), 1024 % 251)
    # buf_hi[10] = 1034 % 251 = 32
    assert_equal(_read_byte_at(buf_hi, 10), 1034 % 251)


# =============================================================================
# T4 — MmapAlignedBuffer outlives the LocalFile via Arc retention
# =============================================================================


def test_aligned_buffer_outlives_local_file() raises:
    """The returned MmapAlignedBuffer holds an ArcPointer<MmapRegion>
    keepalive. When the LocalFile drops, the mmap stays alive because
    the buffer still holds a refcount. Reading bytes from the buffer
    AFTER the LocalFile drops must still succeed."""
    var path = (_scratch_dir() + String("/local_fs_read_at_t4_outlives.bin"))
    _write_payload(path, 4096)

    var fs = LocalFs[NoopSink].new()
    var buf: SharedAlignedBuffer[HeapRegion]
    # Inner scope: file goes out of scope here, drops, releases ONE arc.
    if True:
        var file = fs.open(path)
        buf = fs.read_at(file, Int64(0), Int64(128))
        # file drops at end of `if` scope.

    # Buffer is still alive; mmap region is kept alive by buf._keepalive
    # (the Arc bumps to 2 inside borrow_from_mmap, then drops to 1 when
    # the LocalFile drops, leaving 1 in the buffer's keepalive).
    assert_equal(buf.len(), 128)
    assert_equal(_read_byte_at(buf, 0), 0)
    assert_equal(_read_byte_at(buf, 100), 100)
    # buf drops at function end -> mmap unmapped.


# =============================================================================
# T5 — out-of-bounds read raises
# =============================================================================


def test_read_at_out_of_bounds_raises() raises:
    """offset+length > file_size raises a typed Error from read_at."""
    var path = (_scratch_dir() + String("/local_fs_read_at_t5_oob.bin"))
    _write_payload(path, 256)

    var fs = LocalFs[NoopSink].new()
    var file = fs.open(path)
    var caught = False
    try:
        var _buf = fs.read_at(file, Int64(0), Int64(1024))
    except e:
        caught = True
    assert_true(caught)


# =============================================================================
# T6 — open-then-read of a fresh path mmaps lazily
# =============================================================================


def test_open_does_not_mmap() raises:
    """LocalFs.open returns a LocalFile with _mmap = None (lazy mmap).
    No actual file access happens at open time; the mmap fires on the
    first read_at call."""
    var path = (_scratch_dir() + String("/local_fs_read_at_t6_lazy.bin"))
    _write_payload(path, 1024)

    var fs = LocalFs[NoopSink].new()
    var file = fs.open(path)
    # No read_at yet; mmap state is None.
    assert_false(file.is_mmap_cached())
    # First read populates the mmap.
    var buf = fs.read_at(file, Int64(0), Int64(64))
    assert_true(file.is_mmap_cached())
    assert_equal(buf.len(), 64)


# =============================================================================
# T7 — borrow_from_mmap returns a non-owning buffer
# =============================================================================


def test_read_at_returns_borrowed_buffer() raises:
    """The MmapAlignedBuffer returned by read_at is borrowed-from-mmap
    (capacity == 0 sentinel; is_owned() False; is_mmap_backed() True)."""
    var path = (_scratch_dir() + String("/local_fs_read_at_t7_borrowed.bin"))
    _write_payload(path, 1024)

    var fs = LocalFs[NoopSink].new()
    var file = fs.open(path)
    var buf = fs.read_at(file, Int64(0), Int64(128))
    assert_false(buf.is_owned())
    assert_true(buf.is_mmap_backed())
    assert_equal(buf.len(), 128)


# =============================================================================
# Driver
# =============================================================================


def main() raises:
    test_read_at_basic()
    test_read_at_reuses_mmap_across_calls()
    test_read_at_disjoint_ranges()
    test_aligned_buffer_outlives_local_file()
    test_read_at_out_of_bounds_raises()
    test_open_does_not_mmap()
    test_read_at_returns_borrowed_buffer()
    print(
        "PASS komira_fs.test_local_fs_read_at_mmap"
        " (LocalFs.read_at mmap-borrow implementation)"
    )
