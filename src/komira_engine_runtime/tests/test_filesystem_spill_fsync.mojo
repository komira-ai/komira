# =============================================================================
# test_filesystem_spill_fsync.mojo — gap B durability keystone (test-first).
# =============================================================================
#
# The FileSystem spill durable-flush
# (`FileSystemSpillStorage[FS].sync()`) was once a PAGE-CACHE NO-OP — it did NOT
# issue `fsync(2)`, so a "synced" spill/checkpoint segment survived a plain
# process crash (page cache still held it) but NOT a power loss / kernel
# panic (no durable barrier). The streaming WAL + exactly-once + checkpoint
# all depend on this LOCAL-FS durable barrier.
#
# # Why a "data survives process exit" test is TOO WEAK (reviewers' warning)
#
# The OS page cache survives a plain `exit()` / SIGKILL of the writer — the
# bytes are readable by the next process EVEN WITHOUT fsync. A test that
# merely re-reads the chunk after a process boundary would PASS FALSELY on
# the pre-fix no-op. The durability guarantee gap B closes is power-loss
# durability, which a userspace test cannot literally trigger.
#
# # What this test asserts instead: the fsync syscall IS invoked
#
# We assert the spill durable-flush path actually INVOKES fsync on every
# live chunk (+ the spill directory inode for atomic-create durability):
#
#   (a) FSYNC-INVOCATION GATE (the load-bearing assertion). A spill storage
#       with N live chunks, after `sync()`, must have invoked the FS fsync
#       surface N times for the chunk files + 1 for the directory. PRE-FIX
#       (no-op `sync()` -> `pass`) this count is 0 -> the test FAILS, proving
#       the no-op. POST-FIX it is N + 1.
#   (b) DURABLE PRIMITIVE REACHABILITY. `LocalFs.fsync_file(path)` on a real
#       just-written file returns without raising (the underlying
#       `posix_io.fsync_path` -> `RawWriteFd.fsync` -> `fsync(2)` succeeds on
#       a real inode), and `LocalFs.fsync_dir(dir)` likewise. PRE-FIX these
#       methods do not exist (the test would not compile) -> POST-FIX they
#       fsync the real inode.
#   (c) CORRECTNESS PRESERVED. After `sync()` the chunks still read back
#       byte-identical (the durable barrier must not corrupt / drop data).
#
# The fsync-invocation counter lives in the spill storage struct
# (`num_fsync_calls()`), incremented once per `fs.fsync_file` / `fs.fsync_dir`
# call the durable-flush issues. The no-op `pass` never touches it -> 0.
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
# Helpers (mirror test_filesystem_spill_storage.mojo)
# =============================================================================

comptime _SpillFs = LocalFs[NoopSink]
comptime _Storage = FileSystemSpillStorage[_SpillFs]


def _mkdir_p(path: String) raises:
    """Create `path` and its missing parents (no shell)."""
    makedirs(path, exist_ok=True)


def _temp_root(tag: String) raises -> String:
    var pid = external_call["getpid", Int32]()
    var root = (
        (_scratch_dir() + String("/komira-fsspill-fsync-test-"))
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


def _assert_bytes_equal(
    imm sab: SharedAlignedBuffer[HeapRegion], *expected: Int
) raises:
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
    var live = storage.live_chunk_ids()
    for i in range(len(live)):
        storage.release_chunk(live[i])


# =============================================================================
# Test (a): the FSYNC-INVOCATION GATE — the load-bearing assertion
# =============================================================================


def test_sync_invokes_fsync_per_chunk_plus_dir() raises:
    var root = _temp_root("invoke")
    var storage = _new_storage(root)

    # Write three live chunks.
    var id0 = storage.write_chunk(_make_buf(1, 2, 3, 4))
    var id1 = storage.write_chunk(_make_buf(10, 20, 30))
    var id2 = storage.write_chunk(_make_buf(255, 0, 128, 64, 7))
    assert_equal(storage.num_live_chunks(), 3, "3 live chunks")

    # Before sync(), no fsync has been issued on the durable-flush path.
    assert_equal(
        storage.num_fsync_calls(), 0, "no fsync before sync()"
    )

    # The durable-flush barrier: MUST fsync every live chunk file (3) + the
    # spill directory inode (1) for atomic-create durability = 4 invocations.
    # PRE-FIX (no-op sync() -> pass) this stays 0 -> assertion FAILS.
    storage.sync()
    assert_equal(
        storage.num_fsync_calls(),
        3 + 1,
        "sync() must fsync 3 chunk files + 1 directory",
    )

    # Correctness preserved: chunks still read byte-identical after the
    # durable barrier.
    _assert_bytes_equal(storage.read_chunk(id0), 1, 2, 3, 4)
    _assert_bytes_equal(storage.read_chunk(id1), 10, 20, 30)
    _assert_bytes_equal(storage.read_chunk(id2), 255, 0, 128, 64, 7)

    _cleanup(storage)


def test_sync_empty_storage_only_dir_fsync() raises:
    # With zero live chunks, sync() still fsyncs the directory inode once
    # (cheap, idempotent) — and never raises.
    var root = _temp_root("empty")
    var storage = _new_storage(root)
    assert_equal(storage.num_live_chunks(), 0, "0 live chunks")

    storage.sync()
    assert_equal(
        storage.num_fsync_calls(),
        1,
        "sync() on empty storage fsyncs only the directory",
    )

    _cleanup(storage)


# =============================================================================
# Test (b): DURABLE PRIMITIVE REACHABILITY — LocalFs.fsync_file / fsync_dir
# =============================================================================


def test_localfs_fsync_file_and_dir_on_real_inode() raises:
    var root = _temp_root("prim")
    var fs = _SpillFs.new()

    # Write a real file via the FS write surface, then fsync it by path.
    var path = root + String("/durable.bin")
    var wfile = fs.open_write(path, WriteMode.create_truncate())
    var oab = OwnedAlignedBuffer(capacity=3)
    var view = oab.view_mut()
    view.write_u8_at(0, UInt8(7))
    view.write_u8_at(1, UInt8(8))
    view.write_u8_at(2, UInt8(9))
    var sab = SharedAlignedBuffer[HeapRegion].from_owned(oab^)
    var sv = sab.as_view()
    _ = fs.write_at(wfile, sv.into_span())
    fs.close_write(wfile^)

    # fsync_file on the real inode must succeed (does NOT raise).
    fs.fsync_file(path)

    # fsync_dir on the real directory must succeed (does NOT raise).
    fs.fsync_dir(root)

    # Cleanup.
    fs.delete(path)


# =============================================================================
# Test (c): sync() is idempotent — a second sync() re-fsyncs (cheap), no raise
# =============================================================================


def test_sync_idempotent() raises:
    var root = _temp_root("idem")
    var storage = _new_storage(root)

    var id0 = storage.write_chunk(_make_buf(42))
    storage.sync()
    var after_first = storage.num_fsync_calls()
    assert_equal(after_first, 1 + 1, "first sync: 1 chunk + 1 dir")

    # Second sync with no intervening write: re-fsyncs the live set (1 chunk
    # + 1 dir) — a redundant but valid durable barrier, never raises.
    storage.sync()
    assert_equal(
        storage.num_fsync_calls(),
        after_first + (1 + 1),
        "second sync re-fsyncs the live set",
    )

    _assert_bytes_equal(storage.read_chunk(id0), 42)
    _cleanup(storage)


# =============================================================================
# Test (d): the barrier reaches the FS. The call counter alone cannot tell a
# real fsync from a skipped one, so each call is made to fail on the FS.
# =============================================================================


def test_sync_raises_when_a_chunk_file_is_gone() raises:
    """`sync()` fsyncs each chunk file by path: with the file removed behind
    its back, the fsync of that path fails and `sync()` raises."""
    var root = _temp_root("gonefile")
    var storage = _new_storage(root)
    var id0 = storage.write_chunk(_make_buf(1, 2))
    var fs = _SpillFs.new()
    fs.delete(storage.chunk_prefetch_path(id0))
    var raised = False
    try:
        storage.sync()
    except:
        raised = True
    assert_true(raised, "sync() must reach fsync_file for every live chunk")


def test_sync_raises_when_the_directory_is_gone() raises:
    """`sync()` fsyncs the spill directory: with no chunks and a root that
    does not exist, the directory fsync fails and `sync()` raises."""
    var root = _temp_root("gonedir") + String("/missing")
    var storage = _new_storage(root)
    var raised = False
    try:
        storage.sync()
    except:
        raised = True
    assert_true(raised, "sync() must reach fsync_dir")


# =============================================================================
# main
# =============================================================================


def main() raises:
    test_sync_invokes_fsync_per_chunk_plus_dir()
    test_sync_empty_storage_only_dir_fsync()
    test_localfs_fsync_file_and_dir_on_real_inode()
    test_sync_idempotent()
    test_sync_raises_when_a_chunk_file_is_gone()
    test_sync_raises_when_the_directory_is_gone()
    print("test_filesystem_spill_fsync: ALL PASS")
