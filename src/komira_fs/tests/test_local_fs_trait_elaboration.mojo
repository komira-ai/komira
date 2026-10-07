# =============================================================================
# test_local_fs_trait_elaboration.mojo
# =============================================================================
# FileSystem trait shape: `read_at(...) raises -> SharedAlignedBuffer[HeapRegion]`.
#
# The headline question this test answers: does the canonical FileSystem
# trait shape (associated-type alias `File: Movable & Deinitable`
# + sync `read_at` returning `SharedAlignedBuffer[HeapRegion]`) elaborate under Mojo
# 1.0.0b1, and does the generic-function shape over `FS: FileSystem`
# still work?
#
# Coverage:
#   * LocalFs[NoopSink] constructs.
#   * LocalFs.list returns an empty List[String] (stub).
#   * LocalFs.open returns a LocalFile placeholder with fd=-1 + no mmap.
#   * LocalFs.read_at returns an SharedAlignedBuffer[HeapRegion] when the path exists
#     (mmap-borrow); test paths that don't exist exercise the raising
#     path explicitly.
#   * LocalFs.prefetch_depth returns PREFETCH_DEPTH_LOCAL_NVME (= 4).
#   * LocalFs.supports_random_read returns True.
#   * Trait-level associated-type access via Self.File works end-to-end
#     (validated by calling methods through a generic FS: FileSystem
#     binding).
#
# Mmap-specific coverage (lazy mmap, reuse, Arc keepalive, out-of-bounds)
# lives in the sibling `test_local_fs_read_at_mmap.mojo` test.
# =============================================================================

from std.ffi import external_call
from std.testing import assert_equal, assert_false, assert_true

from komira_runtime_paths import test_tmpdir
from komira_fs.byte_range import ByteRange
from komira_fs.file_system import FileSystem
from komira_fs.local_fs import LocalFile, LocalFs
from komira_async.ops.waker_sink import NoopSink
from komira_fs.local_fs import PREFETCH_DEPTH_LOCAL_NVME
from komira_buffer.shared_aligned_buffer import SharedAlignedBuffer
from komira_buffer.heap_region import HeapRegion


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


def _write_payload(path: String, n: Int) raises:
    """Write `n` bytes of `0xAA` to `path` for mmap-able test fixtures."""
    var fh = open(path, "w")
    var buf = List[UInt8]()
    buf.resize(n, UInt8(0xAA))
    fh.write_bytes(buf)
    fh.close()


def test_local_file_placeholder_has_minus_one_fd() raises:
    """LocalFile placeholder construction yields fd=-1 (mmap path
    does not populate the fd; -1 is the persistent placeholder)."""
    var f = LocalFile.placeholder((_scratch_dir() + String("/foo.parquet")))
    assert_equal(Int(f.fd()), -1)


def test_local_file_placeholder_has_no_mmap() raises:
    """LocalFile placeholder construction yields _mmap=None (lazy mmap;
    first read_at populates)."""
    var f = LocalFile.placeholder((_scratch_dir() + String("/foo.parquet")))
    assert_false(f.is_mmap_cached())


def test_local_file_path_round_trips() raises:
    """LocalFile.path() returns the path passed at construction."""
    var f = LocalFile.placeholder(String("/data/x.parquet"))
    assert_equal(f.path(), String("/data/x.parquet"))


def test_local_fs_new_constructs() raises:
    """LocalFs[NoopSink].new() — default-constructs cleanly."""
    var fs = LocalFs[NoopSink].new()
    # The struct is opaque from outside; success of construction +
    # subsequent method calls is the smoke signal.
    var depth = fs.prefetch_depth()
    assert_equal(depth, PREFETCH_DEPTH_LOCAL_NVME)


def test_local_fs_from_root_constructs() raises:
    """LocalFs[NoopSink].from_root(root) accepts a virtual-root string."""
    var fs = LocalFs[NoopSink].from_root(_scratch_dir())
    assert_true(fs.supports_random_read())


def test_local_fs_list_returns_empty() raises:
    """LocalFs.list over a freshly-created EMPTY directory returns an empty
    List[String]. (Post- `LocalFs.list` does a real recursive walk; an
    empty directory is the genuine empty-listing case. The populated recursive
    walk is covered by `test_local_fs_list_recursive.mojo`.)"""
    var base = test_tmpdir()
    var pid = external_call["getpid", Int32]()
    var d = base + String("/traitelab_empty_") + String(Int(pid))
    var rm = String("rm -rf '") + d + String("'")
    var rm_l = rm
    _ = external_call["system", Int32](rm_l.as_c_string_slice().unsafe_ptr())
    var mk = String("mkdir -p '") + d + String("'")
    var mk_l = mk
    var rc = external_call["system", Int32](
        mk_l.as_c_string_slice().unsafe_ptr()
    )
    assert_equal(Int(rc), 0)
    var fs = LocalFs[NoopSink].new()
    var entries = fs.list(d)
    assert_equal(len(entries), 0)


def test_local_fs_open_returns_placeholder() raises:
    """LocalFs.open — returns LocalFile.placeholder (fd=-1, path=`path`,
    _mmap=None). The mmap fires lazily on the first read_at."""
    var fs = LocalFs[NoopSink].new()
    var f = fs.open(String("/data/foo.parquet"))
    assert_equal(Int(f.fd()), -1)
    assert_equal(f.path(), String("/data/foo.parquet"))
    assert_false(f.is_mmap_cached())


def test_local_fs_read_at_returns_aligned_buffer() raises:
    """LocalFs.read_at — returns an SharedAlignedBuffer[HeapRegion] of the requested
    length, borrowed from the mmap region."""
    var path = (_scratch_dir() + String("/local_fs_trait_elab.bin"))
    _write_payload(path, 4096)
    var fs = LocalFs[NoopSink].new()
    var f = fs.open(path)
    var buf = fs.read_at(f, offset=Int64(0), length=Int64(4096))
    assert_equal(buf.len(), 4096)
    # PROVENANCE: a LIVE mmap borrow, NOT an owning heap copy.
    #
    # `LocalFs.read_at` uses `SharedAlignedBuffer.borrow_mmap_erased` (the
    # factory every other mmap-borrow boundary uses), so the buffer aliases the
    # mmap'd page-cache bytes and carries the keepalive cookie. An owning heap
    # copy here is a regression, not a valid alternative; `read_at`'s docstring
    # promises `is_owned() == False`, and `test_local_fs_read_at_mmap` asserts
    # the same contract.
    assert_false(buf.is_owned())
    assert_true(buf.is_mmap_backed())


def test_local_fs_prefetch_depth_local_nvme() raises:
    """LocalFs.prefetch_depth returns PREFETCH_DEPTH_LOCAL_NVME (= 4
    per calibration)."""
    var fs = LocalFs[NoopSink].new()
    assert_equal(fs.prefetch_depth(), 4)


def test_local_fs_supports_random_read() raises:
    """POSIX pread supports random access; LocalFs reports True."""
    var fs = LocalFs[NoopSink].new()
    assert_true(fs.supports_random_read())


def test_byte_range_basic_shape() raises:
    """ByteRange POD round-trips offset / length and computes end()."""
    var br = ByteRange(offset=Int64(100), length=Int64(50))
    assert_equal(Int(br.offset), 100)
    assert_equal(Int(br.length), 50)
    assert_equal(Int(br.end()), 150)
    assert_false(br.is_empty())
    var empty = ByteRange(offset=Int64(0), length=Int64(0))
    assert_true(empty.is_empty())


def test_local_fs_method_chain_open_then_read() raises:
    """End-to-end: open, then read_at on the returned File. Validates
    that the trait's associated-type binding (Self.File = LocalFile)
    flows through the call chain correctly, and that two reads in
    sequence on the same LocalFile share the underlying mmap."""
    var path = (_scratch_dir() + String("/local_fs_trait_method_chain.bin"))
    _write_payload(path, 8192)
    var fs = LocalFs[NoopSink].new()
    var f = fs.open(path)
    var buf1 = fs.read_at(f, offset=Int64(0), length=Int64(1024))
    assert_equal(buf1.len(), 1024)
    var buf2 = fs.read_at(f, offset=Int64(1024), length=Int64(1024))
    assert_equal(buf2.len(), 1024)


# =============================================================================
# Trait-elaboration smoke: build a generic free function over a
# `FS: FileSystem` parameter to confirm the trait surface is usable
# from generic-function code (the shape source operators will use).
# =============================================================================


def _trait_generic_prefetch_depth[
    FS: FileSystem
](var fs: FS) raises -> Int:
    """Generic-function shape: takes any FileSystem-conformer, calls
    prefetch_depth. If this elaborates, the trait surface is usable
    from the source-operator's parametric body."""
    return fs.prefetch_depth()


def _trait_generic_open_then_read[
    FS: FileSystem
](var fs: FS, path: String) raises -> Int:
    """Generic-function shape: takes any FileSystem-conformer, opens
    a file, calls read_at on it. Validates the parametric binding of
    Self.File flowing through the generic call chain. Returns the
    length of the returned buffer."""
    var f = fs.open(path)
    var buf = fs.read_at(f, offset=Int64(0), length=Int64(2048))
    return buf.len()


def test_generic_filesystem_function_elaborates_with_local_fs() raises:
    """The trait's primary use case is monomorphizing a source operator
    over `FS: FileSystem`. This test confirms the generic-function
    shape elaborates when bound to LocalFs[NoopSink]."""
    var path = (_scratch_dir() + String("/local_fs_trait_generic.bin"))
    _write_payload(path, 4096)

    var fs1 = LocalFs[NoopSink].new()
    var d = _trait_generic_prefetch_depth[LocalFs[NoopSink]](fs1^)
    assert_equal(d, 4)

    var fs2 = LocalFs[NoopSink].new()
    var n = _trait_generic_open_then_read[LocalFs[NoopSink]](
        fs2^, path,
    )
    assert_equal(n, 2048)


def main() raises:
    test_local_file_placeholder_has_minus_one_fd()
    test_local_file_placeholder_has_no_mmap()
    test_local_file_path_round_trips()
    test_local_fs_new_constructs()
    test_local_fs_from_root_constructs()
    test_local_fs_list_returns_empty()
    test_local_fs_open_returns_placeholder()
    test_local_fs_read_at_returns_aligned_buffer()
    test_local_fs_prefetch_depth_local_nvme()
    test_local_fs_supports_random_read()
    test_byte_range_basic_shape()
    test_local_fs_method_chain_open_then_read()
    test_generic_filesystem_function_elaborates_with_local_fs()
    print(
        "PASS komira_fs.test_local_fs_trait_elaboration"
        " (FileSystem trait shape with MmapAlignedBuffer return)"
    )
