# =============================================================================
# test_filesystem_spill_storage.mojo — FileSystemSpillStorage[LocalFs] round-trip.
# =============================================================================
#
# Exercises the generic
# `FileSystemSpillStorage[FS: FileSystem]` conformer composed over
# `LocalFs[NoopSink]`:
#
#   (a) write 2-3 chunks → read them back → assert byte-identical to input.
#   (b) ChunkId round-trips (the handle minted by write_chunk reads back the
#       SAME bytes; distinct chunks get distinct, non-colliding handles).
#   (c) release_chunk removes the backing file (read-after-release raises)
#       AND is ENOENT-tolerant on double-release (second release is a no-op).
#   (d) accounting: nbytes_in_use / num_live_chunks track the live set.
#   (f) a write that exactly fills the byte budget is accepted, one more is
#       refused.
#   (e) LocalFs.delete ENOENT-tolerance directly (delete a missing path
#       is a no-op; delete a present path removes it).
#
# `release_chunk` maps to `LocalFs.delete` (the FileSystem delete surface),
# which is wired concretely on LocalFs (POSIX remove(3), ENOENT-tolerant), so
# the delete path IS exercised here (not the process-exit-sweep fallback).
# =============================================================================

from std.ffi import external_call
from std.os import makedirs

from std.testing import assert_equal, assert_true

from komira_fs.file_system import WriteMode
from komira_fs.local_fs import LocalFs
from komira_async.ops.waker_sink import NoopSink
from komira_buffer.owned_aligned_buffer import OwnedAlignedBuffer
from komira_buffer.shared_aligned_buffer import SharedAlignedBuffer
from komira_buffer.heap_region import HeapRegion

from komira_engine_runtime.spill.filesystem_spill_storage import (
    FileSystemSpillStorage,
)
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


# =============================================================================
# Helpers
# =============================================================================

comptime _SpillFs = LocalFs[NoopSink]
comptime _Storage = FileSystemSpillStorage[_SpillFs]


def _mkdir_p(path: String) raises:
    """Create `path` and its missing parents (no shell)."""
    makedirs(path, exist_ok=True)


def _temp_root(tag: String) raises -> String:
    """A unique temp dir under the scratch dir for this test invocation."""
    var pid = external_call["getpid", Int32]()
    var root = (
        (_scratch_dir() + String("/komira-fsspill-test-"))
        + String(Int(pid))
        + String("-")
        + tag
    )
    _mkdir_p(root)
    return root


def _make_buf(*vals: Int) -> SharedAlignedBuffer[HeapRegion]:
    """Build a SharedAlignedBuffer[HeapRegion] from the given byte values."""
    var n = len(vals)
    var oab = OwnedAlignedBuffer(capacity=n)
    if n > 0:
        var view = oab.view_mut()
        var i = 0
        for v in vals:
            view.write_u8_at(i, UInt8(v))
            i += 1
    return SharedAlignedBuffer[HeapRegion].from_owned(oab^)


def _assert_bytes_equal(
    imm sab: SharedAlignedBuffer[HeapRegion], *expected: Int
) raises:
    """Assert `sab`'s bytes equal `expected` exactly (length + values)."""
    var view = sab.as_view()
    assert_equal(view.len(), len(expected), "byte length mismatch")
    var i = 0
    for e in expected:
        assert_equal(
            Int(view.read_u8_at(i)),
            e,
            "byte mismatch at offset " + String(i),
        )
        i += 1


def _new_storage(root: String) raises -> _Storage:
    var fs = _SpillFs.new()
    return _Storage.with_unlimited(fs^, root)


def _cleanup(mut storage: _Storage) raises:
    """Release every live chunk (deletes the backing files via
    LocalFs.delete) so the test leaves no artifacts behind."""
    var live = storage.live_chunk_ids()
    for i in range(len(live)):
        storage.release_chunk(live[i])


# =============================================================================
# Test (a) + (b): write/read round-trip + ChunkId round-trip
# =============================================================================


def test_write_read_roundtrip() raises:
    var root = _temp_root("rt")
    var storage = _new_storage(root)

    # Write three distinct chunks.
    var id0 = storage.write_chunk(_make_buf(1, 2, 3, 4))
    var id1 = storage.write_chunk(_make_buf(10, 20, 30))
    var id2 = storage.write_chunk(_make_buf(255, 0, 128, 64, 7))

    # Distinct chunks → distinct, non-colliding handles.
    assert_true(id0 != id1, "id0 != id1")
    assert_true(id1 != id2, "id1 != id2")
    assert_true(id0 != id2, "id0 != id2")

    # Read each back — byte-identical to input.
    _assert_bytes_equal(storage.read_chunk(id0), 1, 2, 3, 4)
    _assert_bytes_equal(storage.read_chunk(id1), 10, 20, 30)
    _assert_bytes_equal(storage.read_chunk(id2), 255, 0, 128, 64, 7)

    # ChunkId round-trips: re-reading the SAME id returns the SAME bytes.
    _assert_bytes_equal(storage.read_chunk(id0), 1, 2, 3, 4)

    # Accounting.
    assert_equal(storage.num_live_chunks(), 3, "3 live chunks")
    assert_equal(
        Int(storage.nbytes_in_use()), 4 + 3 + 5, "nbytes_in_use sum"
    )

    _cleanup(storage)


# =============================================================================
# Test (c): release_chunk removes the file; ENOENT-tolerant double-release
# =============================================================================


def test_release_and_double_release() raises:
    var root = _temp_root("rel")
    var storage = _new_storage(root)

    var id0 = storage.write_chunk(_make_buf(9, 8, 7))
    var id1 = storage.write_chunk(_make_buf(1, 1, 1, 1))
    assert_equal(storage.num_live_chunks(), 2, "2 live before release")

    # Release id0: drops the live entry + deletes the backing file via
    # LocalFs.delete (POSIX remove).
    storage.release_chunk(id0)
    assert_equal(storage.num_live_chunks(), 1, "1 live after release")
    assert_equal(
        Int(storage.nbytes_in_use()), 4, "nbytes_in_use after release"
    )

    # Read-after-release raises (handle invalidated).
    var raised = False
    try:
        var _b = storage.read_chunk(id0)
    except:
        raised = True
    assert_true(raised, "read after release must raise")

    # Double-release is a no-op (idempotent / ENOENT-tolerant) — does NOT
    # raise even though the file is already gone.
    storage.release_chunk(id0)
    assert_equal(storage.num_live_chunks(), 1, "double-release no-op")

    # The still-live chunk reads fine.
    _assert_bytes_equal(storage.read_chunk(id1), 1, 1, 1, 1)

    _cleanup(storage)


# =============================================================================
# Test (d): empty chunk round-trips
# =============================================================================


def test_empty_chunk_roundtrip() raises:
    var root = _temp_root("empty")
    var storage = _new_storage(root)

    var id0 = storage.write_chunk(_make_buf())  # zero-length
    var read = storage.read_chunk(id0)
    assert_equal(read.len(), 0, "empty chunk reads back empty")
    assert_equal(Int(storage.nbytes_in_use()), 0, "empty chunk 0 bytes")

    _cleanup(storage)


# =============================================================================
# Test (e): LocalFs.delete ENOENT-tolerance directly
# =============================================================================


def test_localfs_delete_enoent_tolerant() raises:
    var root = _temp_root("delete")
    var fs = _SpillFs.new()

    # Deleting a path that does not exist is a no-op (ENOENT-tolerant).
    var missing = root + String("/does-not-exist.bin")
    fs.delete(missing)  # must NOT raise

    # Write a real file via the FS write surface, then delete it.
    var present = root + String("/present.bin")
    var wfile = fs.open_write(present, WriteMode.create_truncate())
    var oab = OwnedAlignedBuffer(capacity=3)
    var view = oab.view_mut()
    view.write_u8_at(0, UInt8(1))
    view.write_u8_at(1, UInt8(2))
    view.write_u8_at(2, UInt8(3))
    var sab = SharedAlignedBuffer[HeapRegion].from_owned(oab^)
    var sv = sab.as_view()
    _ = fs.write_at(wfile, sv.into_span())
    fs.close_write(wfile^)

    # File exists → delete removes it.
    fs.delete(present)
    # Second delete of the now-gone path is a no-op (ENOENT-tolerant).
    fs.delete(present)


# =============================================================================
# main
# =============================================================================


def test_budget_exact_fit_and_overshoot() raises:
    """A write that exactly fills the budget is accepted; one byte more is
    refused and leaves the accounting unchanged."""
    var root = _temp_root("budget")
    var fs = _SpillFs.new()
    var storage = _Storage(fs^, root, Int64(5))
    var id0 = storage.write_chunk(_make_buf(1, 2, 3))
    var id1 = storage.write_chunk(_make_buf(4, 5))  # 3 + 2 == 5: exact fit
    assert_equal(Int(storage.nbytes_in_use()), 5)
    var refused = False
    try:
        _ = storage.write_chunk(_make_buf(6))
    except e:
        refused = "budget exceeded" in String(e)
    assert_true(refused, "one byte past the budget is refused")
    assert_equal(Int(storage.nbytes_in_use()), 5)
    assert_equal(storage.num_live_chunks(), 2)
    _ = id0
    _ = id1
    _cleanup(storage)


def main() raises:
    test_write_read_roundtrip()
    test_release_and_double_release()
    test_empty_chunk_roundtrip()
    test_localfs_delete_enoent_tolerant()
    test_budget_exact_fit_and_overshoot()
    print("test_filesystem_spill_storage: ALL PASS")
