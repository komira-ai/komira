# =============================================================================
# local_disk.mojo — `LocalDiskSpillStorage` thin wrapper over
#                    `FileSystemSpillStorage[LocalFs[NoopSink]]`.
# =============================================================================
#
# # Storage composes a file system
#
# Spill storage COMPOSES a `FileSystem` rather than
# owning bespoke POSIX I/O. The generic conformer
# `FileSystemSpillStorage[FS: FileSystem]` (sibling
# `filesystem_spill_storage.mojo`) now owns ALL the byte I/O via the
# FileSystem trait. The old `LocalDiskSpillStorage` (which did its own
# `pread`/`pwrite`/`openat` FFI) is collapsed into
# `FileSystemSpillStorage[LocalFs[NoopSink]]`.
#
# This file keeps `LocalDiskSpillStorage` as a THIN, self-mkdir'ing wrapper
# that preserves the original call shape — `LocalDiskSpillStorage(root_dir,
# budget_bytes)`, `.with_unlimited(root_dir)`, `.root_dir()`,
# `.num_live_chunks()`, `.cleanup()` — so the surrounding spill substrate
# (`op_coordinator`, `spill_arbitrator`, `spillable_op`, the bench harness)
# is unaffected. The local-disk concerns this wrapper adds on top of the
# generic conformer are exactly the two things that are LOCAL-FS-specific
# and not in the FileSystem trait:
#   * `__init__` does `mkdir -p root_dir` (the FileSystem trait has no
#     mkdir surface; the generic conformer requires the caller to ensure
#     the prefix exists).
#   * `cleanup()` rmdir's the (now-empty) spill root after releasing every
#     live chunk — a best-effort teardown convenience for tests + the
#     arbitrator's session-startup directory scan.
#
# All actual chunk write/read/release flows through the composed
# `FileSystemSpillStorage` → `LocalFs` → POSIX. There is NO bespoke FFI in
# this file: the directory helpers (which the FileSystem trait does not
# provide) use `std.os.makedirs` and `std.os.rmdir`.
#
# # Encapsulation rule
#
# - Public API takes / returns `String`, `Int64`, `ChunkId`,
#   `SharedAlignedBuffer[HeapRegion]`. NO `UnsafePointer` at the boundary.
# - NO wildcard origins on any struct field; the single field is the
#   composed `FileSystemSpillStorage` value.
# - No FFI: directory creation and removal go through `std.os`.
# =============================================================================

from std.os import makedirs, rmdir

from komira_fs.local_fs import LocalFs
from komira_async.ops.waker_sink import NoopSink
from komira_buffer.shared_aligned_buffer import SharedAlignedBuffer
from komira_buffer.heap_region import HeapRegion

from .filesystem_spill_storage import FileSystemSpillStorage
from .spill_storage import ChunkId, SpillStorage


# The concrete FileSystem the local-disk spill path composes. NoopSink is
# the synthetic waker-sink used everywhere LocalFs is driven synchronously
# in-process (matches `file_sink.mojo`'s `LocalFs[NoopSink].new()` shape).
comptime _LocalSpillFs = LocalFs[NoopSink]
comptime _LocalSpillStorageImpl = FileSystemSpillStorage[_LocalSpillFs]


# =============================================================================
# Directory-lifecycle helpers (file-private) — the LOCAL-FS-specific concerns
# that the FileSystem trait does NOT provide.
# =============================================================================


def _mkdir_p(path: String) raises:
    """Create `path` and any missing parents; an existing directory is not an
    error. `std.os.makedirs` (mkdir(2) per segment): no shell, so a path holding
    quotes or spaces is created as written."""
    makedirs(path, exist_ok=True)


def _rmdir_if_empty(path: String):
    """Remove `path` if it is empty. Any failure (ENOTEMPTY, EACCES, ENOENT) is
    swallowed: this is best-effort teardown."""
    try:
        rmdir(path)
    except:
        pass


# =============================================================================
# LocalDiskSpillStorage — thin wrapper over FileSystemSpillStorage[LocalFs].
# =============================================================================


struct LocalDiskSpillStorage(SpillStorage):
    """File-backed `SpillStorage`, a THIN wrapper over
    `FileSystemSpillStorage[LocalFs[NoopSink]]`.

    Its call shape:
      * `LocalDiskSpillStorage(root_dir, budget_bytes)` — `mkdir -p` the
        root, then delegate to the generic conformer.
      * `.with_unlimited(root_dir)` — budget-less convenience ctor.
      * `.root_dir()` / `.num_live_chunks()` — observability.
      * `.cleanup()` — release every live chunk + rmdir the spill root.

    All chunk write/read/release flows through the composed
    `FileSystemSpillStorage` → `LocalFs` → POSIX. This wrapper adds only
    the two LOCAL-FS-specific concerns the FileSystem trait does not
    provide: directory creation (`mkdir -p`) and directory teardown
    (`rmdir`).

    # Threading

    Identical contract to the generic conformer: single-writer per
    arbitrator pass; concurrent reads to distinct chunks safe.

    # Drop

    `__del__` is synthesized; the inner `FileSystemSpillStorage` drops its
    `LocalFs` + `_live_chunks` Dict cleanly. ON-DISK FILES ARE NOT
    AUTO-CLEANED on drop — call `cleanup()` explicitly, or rely on
    `$TMPDIR` housekeeping. (Same rationale as the original P-1.A: Mojo
    Mojo `__del__` cannot raise, so error-visible cleanup must be
    explicit.)

    Fields:
        _impl: The composed generic conformer over LocalFs.
    """

    var _impl: _LocalSpillStorageImpl

    # -------------------------------------------------------------------------
    # Construction
    # -------------------------------------------------------------------------

    def __init__(out self, root_dir: String, budget_bytes: Int64) raises:
        """Construct over `root_dir`. Creates `root_dir` (+ missing parents)
        via `mkdir -p`, then composes a `FileSystemSpillStorage[LocalFs]`
        rooted there.

        Args:
            root_dir: Directory under which chunk files live. Should be
                unique per session (callers combine `$TMPDIR` + pid +
                session_id).
            budget_bytes: Cap on `nbytes_in_use()`; -1 disables.
        """
        _mkdir_p(root_dir)
        var fs = _LocalSpillFs.new()
        self._impl = _LocalSpillStorageImpl(fs^, root_dir, budget_bytes)

    @staticmethod
    def with_unlimited(root_dir: String) raises -> Self:
        """Convenience ctor: no budget limit. Mirrors the original."""
        return Self(root_dir, Int64(-1))

    # -------------------------------------------------------------------------
    # SpillStorage trait surface — pure delegation to the generic conformer.
    # -------------------------------------------------------------------------

    def write_chunk(
        mut self, var bytes: SharedAlignedBuffer[HeapRegion]
    ) raises -> ChunkId:
        """Delegate to the composed `FileSystemSpillStorage.write_chunk`."""
        return self._impl.write_chunk(bytes^)

    def read_chunk(
        self, chunk_id: ChunkId
    ) raises -> SharedAlignedBuffer[HeapRegion]:
        """Delegate to the composed `FileSystemSpillStorage.read_chunk`."""
        return self._impl.read_chunk(chunk_id)

    def release_chunk(mut self, chunk_id: ChunkId) raises:
        """Delegate to the composed `FileSystemSpillStorage.release_chunk`
        (which maps to `LocalFs.delete` — POSIX unlink, ENOENT-tolerant)."""
        self._impl.release_chunk(chunk_id)

    def nbytes_in_use(self) -> Int64:
        """Delegate to the composed conformer."""
        return self._impl.nbytes_in_use()

    def sync(mut self) raises:
        """Delegate to the composed conformer, which fsyncs each live chunk
        file and then the spill directory."""
        self._impl.sync()

    # -------------------------------------------------------------------------
    # Conformer-specific helpers (NOT part of the SpillStorage trait).
    # -------------------------------------------------------------------------

    def root_dir(self) -> String:
        """The root directory path. Used by tests + the arbitrator's
        session-startup directory-scan cleanup."""
        return self._impl.root_prefix()

    def chunk_prefetch_path(self, chunk_id: ChunkId) -> String:
        """Part B form-(a) prefetch-offload — the on-disk path for `chunk_id`
        (the SAME path `read_chunk` opens). Delegates to the composed conformer.
        Used by the IO-lane prefetch producer to prime the file's pages into the
        OS page cache AHEAD of the compute thread's `read_chunk`."""
        return self._impl.chunk_prefetch_path(chunk_id)

    def chunk_recorded_length(self, chunk_id: ChunkId) -> Int64:
        """Part B form-(a) — the recorded byte length of `chunk_id` (0 if not
        live) so the prefetch producer bounds its page-cache warm to the chunk
        payload. Delegates to the composed conformer."""
        return self._impl.chunk_recorded_length(chunk_id)

    def num_live_chunks(self) -> Int:
        """Count of live (written, not released) chunks."""
        return self._impl.num_live_chunks()

    def reopen_chunk(mut self, chunk_id: ChunkId) raises:
        """Re-register a chunk written by a prior writer over the same root.

        Delegates to `FileSystemSpillStorage.reopen_chunk` — stats the
        on-disk file to recover the chunk's byte length and registers it as
        live so `read_chunk` / `release_chunk` find it. The
        write-run-then-read-back-in-a-later-phase shape (external-sort run
        spill + finalize merge) re-opens the storage root in a fresh instance;
        this recovers the chunk map.
        """
        self._impl.reopen_chunk(chunk_id)

    def cleanup(mut self) raises:
        """Release every live chunk file + rmdir the (now-empty) spill root.

        Best-effort: chunk releases go through the generic conformer's
        `release_chunk` (POSIX unlink via `LocalFs.delete`, ENOENT-tolerant);
        the final `rmdir` is silently swallowed on failure. After
        `cleanup()`, the conformer's accounting is reset to zero.
        """
        # Snapshot live ChunkIds, then release each through the generic
        # conformer so the accounting + on-disk files stay in lockstep.
        var live = self._impl.live_chunk_ids()
        for i in range(len(live)):
            self._impl.release_chunk(live[i])
        _rmdir_if_empty(self.root_dir())
