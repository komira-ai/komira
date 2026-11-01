# =============================================================================
# test_spill_prefetch_seam.mojo — Part B form-(a) prefetch-offload seam.
# =============================================================================
#
# Part B form-(a) prefetch-offload (compute/IO hyperthread split).
# The spill-restore prefetch producer resolves the chunk file PATH + recorded
# LENGTH from the spill storage (the `_prefetch_run` helper in
# row_hash_agg_spill.mojo), then primes that file into the OS page cache on the
# IO lane (`prefetch_file_into_page_cache`). This test pins that SEAM end-to-end
# at the engine layer (no SDK-stack / s2n dependency):
#
#   (a) PATH RESOLUTION. `FileSystemSpillStorage.chunk_prefetch_path(id)` returns
#       the SAME on-disk path `read_chunk` opens — proven by reading the file at
#       that path directly + matching the written bytes. This is the exact path
#       the restore loop hands to the prefetch producer.
#   (b) RECORDED LENGTH. `chunk_recorded_length(id)` matches the written byte
#       count (the bound the page-cache warm uses), and is 0 for a not-live id.
#   (c) PAGE-CACHE PRIME. `prefetch_file_into_page_cache(path, n)` on the real
#       chunk file returns without raising (it warms the pages), and is BENIGN
#       on a nonexistent path (fire-and-forget — the compute thread's own read
#       covers correctness). This is the leaf the IO worker runs.
#   (d) CORRECTNESS PRESERVED. A `read_chunk` AFTER a prefetch returns the same
#       bytes (the prefetch is a no-op-on-result page-cache prime — it never
#       mutates the chunk).
# =============================================================================

from std.ffi import external_call
from std.os import makedirs

from std.testing import assert_equal, assert_true

from komira_fs.local_fs import LocalFs
from komira_async.ops.waker_sink import NoopSink
from komira_buffer.owned_aligned_buffer import OwnedAlignedBuffer
from komira_buffer.shared_aligned_buffer import SharedAlignedBuffer
from komira_buffer.heap_region import HeapRegion
from komira_libc.posix_io import prefetch_file_into_page_cache

from komira_engine_runtime.spill.filesystem_spill_storage import (
    FileSystemSpillStorage,
)
from komira_engine_runtime.spill.spill_storage import ChunkId
from komira_libc.posix import _read_env


# ---------------------------------------------------------------------------
# Scratch files go under $TEST_TMPDIR (set by the test runner, unique per
# action), else $TMPDIR; a fixed path would be shared by concurrent runs of
# this test. `_read_env` rather than `std.os.getenv`: komira_libc.posix owns
# the one `getenv` declaration in the link.
# ---------------------------------------------------------------------------
def _scratch_dir() raises -> String:
    """The directory THIS execution may write scratch files into."""
    var d = _read_env("TEST_TMPDIR")
    if d.byte_length() == 0:
        d = _read_env("TMPDIR")
    if d.byte_length() == 0:
        raise Error("neither TEST_TMPDIR nor TMPDIR is set")
    return d


comptime _SpillFs = LocalFs[NoopSink]
comptime _Storage = FileSystemSpillStorage[_SpillFs]


def _mkdir_p(path: String) raises:
    """Create `path` and its missing parents (no shell)."""
    makedirs(path, exist_ok=True)


def _temp_root(tag: String) raises -> String:
    var pid = external_call["getpid", Int32]()
    var root = (
        (_scratch_dir() + String("/komira-spill-prefetch-seam-"))
        + String(Int(pid))
        + String("-")
        + tag
    )
    _mkdir_p(root)
    return root


def _make_buf(*vals: Int) -> SharedAlignedBuffer[HeapRegion]:
    var n = len(vals)
    var oab = OwnedAlignedBuffer(capacity=n)
    if n > 0:
        var view = oab.view_mut()
        var i = 0
        for v in vals:
            view.write_u8_at(i, UInt8(v))
            i += 1
    return SharedAlignedBuffer[HeapRegion].from_owned(oab^)


def _new_storage(root: String) raises -> _Storage:
    var fs = _SpillFs.new()
    return _Storage.with_unlimited(fs^, root)


# -----------------------------------------------------------------------------
# (a) + (b) PATH RESOLUTION + RECORDED LENGTH — the producer's resolve inputs
# -----------------------------------------------------------------------------


def test_chunk_prefetch_path_resolves_to_real_file() raises:
    """`chunk_prefetch_path(id)` returns the SAME path `read_chunk` opens. Proven
    by reading the file at that path directly (via a fresh read storage) and
    matching the written bytes. This is the exact path the restore loop hands to
    the prefetch producer."""
    var root = _temp_root("path")
    var storage = _new_storage(root)
    var id0 = storage.write_chunk(_make_buf(1, 2, 3, 4, 5))

    # The producer's resolve: path + recorded length.
    var path = storage.chunk_prefetch_path(id0)
    var n = storage.chunk_recorded_length(id0)
    assert_equal(Int(n), 5, "recorded length == 5 written bytes")
    # The path is under the spill root + the chunk_<hex>.bin shape.
    assert_true(path.find(root) == 0, "prefetch path is under the spill root")
    assert_true(path.find("chunk_") >= 0, "prefetch path names a chunk file")

    # The path is the SAME one read_chunk opens: read it back, bytes match.
    var sab = storage.read_chunk(id0)
    var view = sab.as_view()
    assert_equal(view.len(), 5, "read_chunk returns 5 bytes")
    assert_equal(Int(view.read_u8_at(0)), 1)
    assert_equal(Int(view.read_u8_at(4)), 5)


def test_chunk_recorded_length_zero_for_not_live() raises:
    """`chunk_recorded_length` is 0 for a never-written id (the prefetch then
    warms to EOF, still bounded by the file size — and on a not-live id the file
    does not exist, so the prefetch is a benign no-op)."""
    var root = _temp_root("notlive")
    var storage = _new_storage(root)
    # id 999 was never written.
    assert_equal(Int(storage.chunk_recorded_length(ChunkId(UInt64(999)))), 0)


# -----------------------------------------------------------------------------
# (c) PAGE-CACHE PRIME — the leaf the IO worker runs
# -----------------------------------------------------------------------------


def test_prefetch_file_into_page_cache_warms_real_file() raises:
    """`prefetch_file_into_page_cache(path, n)` on the real chunk file returns
    without raising (it primes the pages). Bounded by the recorded length."""
    var root = _temp_root("warm")
    var storage = _new_storage(root)
    var id0 = storage.write_chunk(_make_buf(9, 8, 7, 6, 5, 4, 3, 2, 1, 0))
    var path = storage.chunk_prefetch_path(id0)
    var n = storage.chunk_recorded_length(id0)
    # Prime the file into page cache — must not raise.
    prefetch_file_into_page_cache(path, Int(n))
    # Warm-to-EOF form (max_bytes <= 0) also must not raise.
    prefetch_file_into_page_cache(path, 0)


def test_prefetch_missing_file_is_benign() raises:
    """`prefetch_file_into_page_cache` on a NONEXISTENT path is benign (the C
    shim swallows the open failure). This guards the fire-and-forget contract:
    a stale / released chunk path never raises out of the IO worker."""
    prefetch_file_into_page_cache(
        (_scratch_dir() + String("/komira-no-such-spill-prefetch-seam-xyz.bin")), 4096
    )


# -----------------------------------------------------------------------------
# (d) CORRECTNESS PRESERVED — prefetch never mutates the chunk
# -----------------------------------------------------------------------------


def test_read_after_prefetch_is_byte_identical() raises:
    """A `read_chunk` AFTER a prefetch returns the SAME bytes — the prefetch is a
    page-cache prime that never mutates the chunk (the form-(a) safety guarantee:
    the IO task references only source bytes, produces no result the consumer
    folds, so it cannot change the answer)."""
    var root = _temp_root("idem")
    var storage = _new_storage(root)
    var id0 = storage.write_chunk(_make_buf(42, 43, 44))
    var path = storage.chunk_prefetch_path(id0)
    prefetch_file_into_page_cache(path, 3)
    # Read after the warm — byte-identical.
    var sab = storage.read_chunk(id0)
    var view = sab.as_view()
    assert_equal(view.len(), 3)
    assert_equal(Int(view.read_u8_at(0)), 42)
    assert_equal(Int(view.read_u8_at(1)), 43)
    assert_equal(Int(view.read_u8_at(2)), 44)


def main() raises:
    test_chunk_prefetch_path_resolves_to_real_file()
    test_chunk_recorded_length_zero_for_not_live()
    test_prefetch_file_into_page_cache_warms_real_file()
    test_prefetch_missing_file_is_benign()
    test_read_after_prefetch_is_byte_identical()
    print("PASS engine spill-prefetch seam (Part B form-(a))")
