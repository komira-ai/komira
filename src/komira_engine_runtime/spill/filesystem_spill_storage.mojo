# =============================================================================
# filesystem_spill_storage.mojo — `FileSystemSpillStorage[FS: FileSystem]`.
# =============================================================================
#
# # Storage composes a file system
#
# Spill **storage composes a `FileSystem`**: an object store is just another
# `FileSystem` conformer, not a bespoke spill backend.
#
# This file delivers ONE generic `SpillStorage` conformer parameterized over
# any `FileSystem`:
#
#     FileSystemSpillStorage[FS: FileSystem]
#
# Cloud spill (S3/GCS/Azure) is then "just" `FileSystemSpillStorage[S3Fs]` /
# `FileSystemSpillStorage[GcsFs]` once those FS conformers land their write
# + delete surface. NO new per-backend spill conformers are ever written
# again — the storage layer is backend-agnostic.
#
# # How the trait surfaces map onto FileSystem
#
#   * `write_chunk(bytes)` →
#       fs.open_write(path, WriteMode.create_truncate())   (open)
#       fs.write_at(file, span)                              (write the bytes)
#       fs.close_write(file^)                               (commit)
#     The multipart-for-large-blobs concern is absorbed INSIDE the cloud-FS
#     conformers (S3 multipart / GCS resumable) — NOT this layer's concern.
#     LocalFs writes directly (RawWriteFd, with the 64 MiB chunking workaround
#     already absorbed inside LocalFs.write_at).
#
#   * `read_chunk(id)` →
#       fs.open(path)                                        (read handle)
#       fs.read_at(file, 0, length)                          (bytes)
#     `FileSystem.read_at` returns `SharedAlignedBuffer[HeapRegion]` — the
#     EXACT type `read_chunk` is contractually required to return. Zero-
#     friction compose: no realign, no bridge, no copy at this layer
#     (LocalFs's read_at already realigns to 64 internally; cloud-FS owns
#     its response bytes).
#
#   * `release_chunk(id)` →
#       fs.delete(path)
#     `FileSystem.delete` is ENOENT-tolerant. Until/unless a given FS
#     conformer implements delete (today only LocalFs does; S3Fs/GcsFs/AzureFs
#     inherit the trait's raising default), `release_chunk` surfaces the
#     raise — and the chunk is reclaimed at process-exit by the conformer's
#     own teardown / next-session directory scan (the documented fallback).
#
# # Why the spill layer owns the ChunkId -> (path, length) map
#
# `FileSystem` is PATH-keyed (open/read_at/delete take a `String` path).
# `SpillStorage` is CHUNK-keyed (write_chunk mints an opaque `ChunkId`;
# read/release take a `ChunkId`). The impedance match — minting a fresh
# path per chunk, and recording the byte length so `read_chunk` knows how
# many bytes to ask `read_at` for — lives HERE, in the spill layer. That's
# the one piece of bookkeeping `FileSystem` does not provide.
#
# # Encapsulation rule
#
# - Public API takes / returns `String`, `Int64`, `ChunkId`,
#   `SharedAlignedBuffer[HeapRegion]`. NO `UnsafePointer` at the boundary.
# - NO wildcard origins on any struct field. The `_live_chunks` Dict holds
#   POD `UInt64 -> Int64`; `_fs` is the FS value (Movable); `_root_prefix`
#   is a String. None is a gap6 hazard (no heap-owning inner field inside a
#   byte-slab; no wildcard-origin pointer field).
# - All FFI / pointer arithmetic lives INSIDE the composed `FS` conformer,
#   which already guards it with `# SAFETY:` comments. This file does none.
# =============================================================================

from std.collections import Dict

from komira_fs.file_system import FileSystem, WriteMode
from komira_buffer.owned_aligned_buffer import OwnedAlignedBuffer
from komira_buffer.shared_aligned_buffer import SharedAlignedBuffer
from komira_buffer.heap_region import HeapRegion

from .spill_storage import ChunkId, SpillStorage


# =============================================================================
# Path helper (file-private) — mints the per-chunk path under root_prefix.
# =============================================================================


def _chunk_path(root_prefix: String, chunk_value: UInt64) -> String:
    """Construct the path for `ChunkId(chunk_value)` under `root_prefix`.

    Format: `<root_prefix>/chunk_<16-hex-digits>.bin`. 16 hex digits is the
    full UInt64 width — guarantees per-session uniqueness for a monotonic
    chunk counter. This mirrors the original `LocalDiskSpillStorage`
    layout so on-disk artifacts are byte-for-byte path-compatible.

    `root_prefix` is the spill-layer's namespace (a directory for LocalFs,
    a key-prefix for object stores). The composed FileSystem interprets the
    resulting path per its own scheme.
    """
    var hex_digits = String("0123456789") + String("abcdef")
    var v = chunk_value
    var buf = List[UInt8](capacity=16)
    for _i in range(16):
        buf.append(UInt8(0))
    var i = 15
    while i >= 0:
        var nibble = Int(v & UInt64(0xF))
        var ch_byte = hex_digits.as_bytes()[nibble]
        buf[i] = ch_byte
        v = v >> UInt64(4)
        i -= 1
    var hex_str = String(unsafe_from_utf8=buf^)
    return root_prefix + String("/chunk_") + hex_str + String(".bin")


# =============================================================================
# FileSystemSpillStorage[FS] — the one generic SpillStorage conformer.
# =============================================================================


struct FileSystemSpillStorage[FS: FileSystem](SpillStorage):
    """Generic `SpillStorage` conformer that layers on any `FileSystem`.

    ONE conformer for ALL backends. `FileSystemSpillStorage[LocalFs]` is the
    local-disk spill path (replacing the bespoke `LocalDiskSpillStorage`);
    `FileSystemSpillStorage[S3Fs]` / `[GcsFs]` / `[AzureFs]` are cloud spill
    once those FS conformers land their write + delete surface. No new
    per-backend spill conformer is ever written — the cloud-specific concerns
    (multipart, resumable, block-list, auth) live entirely inside the
    composed `FileSystem` conformer.

    # Trait-hierarchy binding (PINNED — Streaming ADR §1.2)

    SPILL is the ONLY substrate face that binds `FileSystem` ALONE (the
    `[FS: FileSystem]` parameter here — note the ABSENCE of any
    `ConditionalWriteStore`). Spill needs no linearization: it is
    single-writer, single-kernel, allocates no offsets, and decides nothing
    about "which is committed". It needs only byte IO (+ a durable-flush
    barrier — gap B). The rule, structural across the unified substrate:

      * anything that ALLOCATES A POSITION / decides "which is committed"
        (broker-log, WAL, checkpoint, shuffle) binds `ConditionalWriteStore`
        via `CasManifestStore` (the CAS append IS the offset/LSN allocator);
      * anything that only MOVES BYTES binds `FileSystem`.

    The streaming source / sink contracts
    (`komira_morsel/streaming_{source,sink}.mojo`) bind the FORMER (their
    position / commit-log is a CAS manifest). This conformer is the structural
    proof that "one substrate, two backend traits" holds: spill is the
    `FileSystem`-alone face; everything position-bearing is the
    `ConditionalWriteStore` face.

    # Construction

    `FileSystemSpillStorage(fs^, root_prefix, budget_bytes)` takes ownership
    of a constructed `FileSystem` and a `root_prefix` namespace. The caller
    is responsible for ensuring `root_prefix` exists where the backend needs
    it (for LocalFs that's `mkdir -p`; the SDK / arbitrator wiring does this
    at the trust boundary — see `LocalDiskSpillStorage` alias below for the
    self-mkdir'ing convenience ctor that preserves the old call shape).

    `budget_bytes` caps `nbytes_in_use()`; `write_chunk` raises rather than
    exceeding it. Any negative `budget_bytes` disables the limit.

    # Threading

    Same contract as the original `SpillStorage` trait: single-writer per
    arbitrator pass (the `SpillArbitrator` is single-writer by construction);
    concurrent reads to DISTINCT chunks are safe (each `read_chunk` opens its
    own `FileSystem.File`). Reads to the SAME chunk concurrently are also
    safe but produce independent buffers.

    # ChunkId -> (path, length) map

    `FileSystem` is path-keyed; `SpillStorage` is chunk-keyed. This struct
    owns the impedance match: a monotonic `_next_chunk_id` counter mints the
    path, and `_live_chunks` records each live chunk's byte length so
    `read_chunk` can ask `read_at` for the exact span.

    # Encapsulation

    All fields PRIVATE. Public API exposes only the `SpillStorage` trait
    surface + `root_prefix()` (observability) + `num_live_chunks()` (tests).

    Fields:
        _fs:            The composed FileSystem (owned, Movable). All actual
                        byte I/O + delete is delegated to it.
        _root_prefix:   Namespace under which `chunk_*.bin` paths are minted.
        _next_chunk_id: Monotonic counter for `write_chunk`. Never wraps
                        within a session.
        _live_chunks:   Maps the raw ChunkId value -> on-disk byte length.
                        Drives `nbytes_in_use` accounting + the existence
                        check for `read_chunk` / `release_chunk`.
        _budget_bytes:  Max `nbytes_in_use()`; any negative = no limit.
        _nbytes_in_use: Sum of live chunk payload lengths.
        _fsync_calls:   Count of fsync invocations issued by `sync()` (one
                        per live chunk file + one for the directory). Drives
                        the durability-gate test (`num_fsync_calls()`); the
                        no-op pre-fix `sync()` never incremented it.
    """

    var _fs: Self.FS
    var _root_prefix: String
    var _next_chunk_id: UInt64
    var _live_chunks: Dict[UInt64, Int64]
    var _budget_bytes: Int64
    var _nbytes_in_use: Int64
    var _fsync_calls: Int64

    # -------------------------------------------------------------------------
    # Construction
    # -------------------------------------------------------------------------

    def __init__(
        out self,
        var fs: Self.FS,
        root_prefix: String,
        budget_bytes: Int64,
    ):
        """Construct over an owned `FileSystem` + `root_prefix` namespace.

        Does NOT create `root_prefix` — the caller ensures it exists at the
        trust boundary (the `LocalDiskSpillStorage` alias provides the
        self-mkdir'ing convenience ctor for the local-disk path that
        preserves the original call shape).

        Args:
            fs: The composed FileSystem (consumed via `^`). All byte I/O +
                delete delegates to this.
            root_prefix: Namespace for minted `chunk_*.bin` paths.
            budget_bytes: Cap on `nbytes_in_use()`; any negative disables.
        """
        self._fs = fs^
        self._root_prefix = root_prefix
        self._next_chunk_id = UInt64(1)
        self._live_chunks = Dict[UInt64, Int64]()
        self._budget_bytes = budget_bytes
        self._nbytes_in_use = Int64(0)
        self._fsync_calls = Int64(0)

    @staticmethod
    def with_unlimited(var fs: Self.FS, root_prefix: String) -> Self:
        """Convenience ctor: no budget limit (budget tracking lives in the
        arbitrator). Mirrors `LocalDiskSpillStorage.with_unlimited`.
        """
        return Self(fs^, root_prefix, Int64(-1))

    # -------------------------------------------------------------------------
    # SpillStorage trait surface
    # -------------------------------------------------------------------------

    def write_chunk(
        mut self, var bytes: SharedAlignedBuffer[HeapRegion]
    ) raises -> ChunkId:
        """Append `bytes` as a fresh chunk via the composed FileSystem.

        Maps to: `fs.open_write(path, CREATE_TRUNCATE)` → `fs.write_at` →
        `fs.close_write`. Empty buffers (`length() == 0`) are valid — they
        produce an empty file; `read_chunk` returns an empty buffer.

        On write failure the chunk is NOT recorded as live and the
        partially-written path is best-effort deleted so the conformer's
        accounting stays consistent.
        """
        var n = bytes.length()
        if self._budget_bytes >= 0:
            if n > self._budget_bytes - self._nbytes_in_use:
                raise Error(
                    "FileSystemSpillStorage.write_chunk: budget exceeded"
                    " (in_use="
                    + String(self._nbytes_in_use)
                    + ", requested="
                    + String(n)
                    + ", budget="
                    + String(self._budget_bytes)
                    + ")"
                )

        var value = self._next_chunk_id
        var path = _chunk_path(self._root_prefix, value)

        # open_write → write_at → close_write. On failure (open_write
        # included, which may create the file before failing), best-effort
        # delete the partial path and re-raise.
        try:
            var wfile = self._fs.open_write(path, WriteMode.create_truncate())
            if n > 0:
                # SAFETY: `bytes.as_view()` returns a ByteView tied to the
                # local `bytes` (the SharedAlignedBuffer's Arc pins the
                # storage); `into_span()` yields a Span over the same origin,
                # alive across the synchronous `write_at`. No pointer escapes
                # this method — the Span is consumed inside the FS conformer.
                var view = bytes.as_view()
                var span = view.into_span()
                _ = self._fs.write_at(wfile, span)
            self._fs.close_write(wfile^)
        except e:
            # Roll back: the partial path is unusable — best-effort delete.
            # `delete` is ENOENT-tolerant; if it itself raises (e.g. cloud-FS
            # without delete wired), we swallow the secondary failure and
            # surface the PRIMARY write error.
            try:
                self._fs.delete(path)
            except:
                pass
            raise e^

        self._live_chunks[value] = n
        self._nbytes_in_use += n
        self._next_chunk_id = value + UInt64(1)
        return ChunkId(value)

    def read_chunk(
        self, chunk_id: ChunkId
    ) raises -> SharedAlignedBuffer[HeapRegion]:
        """Read back the chunk via the composed FileSystem.

        Maps to: `fs.open(path)` → `fs.read_at(file, 0, length)`. The
        length comes from `_live_chunks` (recorded at `write_chunk` time).
        `FileSystem.read_at` already returns `SharedAlignedBuffer[HeapRegion]`
        — returned through unchanged (zero-friction).

        Raises if the chunk is not live (never written OR released).
        """
        var value = chunk_id._unsafe_value()
        var maybe_len = self._live_chunks.find(value)
        if not maybe_len:
            raise Error(
                "FileSystemSpillStorage.read_chunk: ChunkId not live"
                " (value="
                + String(Int(value))
                + ") — was never written OR was released"
            )
        var expected_len = maybe_len.value()
        var path = _chunk_path(self._root_prefix, value)

        if expected_len == Int64(0):
            # Empty chunk — return an empty heap buffer without touching
            # read_at (cloud-FS GET-Range of 0 bytes is an edge case;
            # LocalFs mmap of a 0-byte file is also degenerate).
            return SharedAlignedBuffer[HeapRegion].from_owned(
                OwnedAlignedBuffer(capacity=0)
            )
        var rfile = self._fs.open(path)
        return self._fs.read_at(rfile, Int64(0), expected_len)

    def release_chunk(mut self, chunk_id: ChunkId) raises:
        """Release the chunk: drop the live entry + delete the backing path.

        Maps to `fs.delete(path)` (ENOENT-tolerant). Idempotent: a
        second release of the same `chunk_id` is a no-op (entry already
        absent → return without touching the FileSystem).

        FALLBACK when delete is not wired on the composed FS (today: only
        LocalFs implements delete; S3Fs/GcsFs/AzureFs inherit the trait's
        raising default): `fs.delete` raises, which propagates here. The
        live-chunk entry is then NOT dropped, and the chunk's bytes are
        reclaimed at process-exit by the conformer's teardown OR a
        next-session directory/prefix sweep (documented process-exit-sweep
        fallback). Callers on a cloud FS should treat release as best-effort
        while that FS has no delete.
        """
        var value = chunk_id._unsafe_value()
        var maybe_len = self._live_chunks.find(value)
        if not maybe_len:
            # Already released (or never written) — idempotent.
            return
        var n = maybe_len.value()
        var path = _chunk_path(self._root_prefix, value)
        # delete is ENOENT-tolerant per the FileSystem.delete contract; a
        # real failure (or unimplemented-on-cloud) raises and leaves the
        # accounting intact for the process-exit-sweep fallback.
        self._fs.delete(path)
        _ = self._live_chunks.pop(value)
        self._nbytes_in_use -= n

    def nbytes_in_use(self) -> Int64:
        """Sum of live chunk payload lengths (written but not released)."""
        return self._nbytes_in_use

    def sync(mut self) raises:
        """Durable-flush barrier — fsync every live chunk + the spill
        directory inode so the spilled bytes survive a POWER LOSS, not just
        a process crash.

        Without it, `close_write` leaves each chunk in the kernel page
        cache, which survives a PROCESS crash but not a kernel panic or
        power loss.

        Durability model: durable = await-the-backend-
        durable-ack. For LOCAL-FS that is `fsync(2)` on each chunk's data
        (`fs.fsync_file`) AND on the directory inode (`fs.fsync_dir`) — the
        latter makes the newly-CREATED chunk filenames durable (a created
        file's directory entry is metadata in the directory inode; without
        it a power loss can leave the data durable but the entry naming it
        lost, rendering the chunk unreachable). For S3/GCS/Azure the bytes
        are already durable at PUT / multipart-finalize ack, so those FS
        conformers override `fsync_file` / `fsync_dir` to a no-op and this
        method composes uniformly (NO branch on FS identity here).

        Returns only AFTER every barrier acknowledges. Idempotent: a second
        `sync()` with no intervening `write_chunk` re-fsyncs the live set (a
        redundant but valid barrier).

        Raises on durability-barrier failure (e.g. EIO from `fsync(2)`).
        """
        # Snapshot the live chunk ids so we don't hold a Dict borrow across
        # the (raising) fsync calls. fsync each chunk's backing file.
        var live = self.live_chunk_ids()
        for i in range(len(live)):
            var value = live[i]._unsafe_value()
            var path = _chunk_path(self._root_prefix, value)
            self._fs.fsync_file(path)
            self._fsync_calls += Int64(1)
        # fsync the spill directory inode once so the (created) chunk
        # filenames themselves are durable across a power loss.
        self._fs.fsync_dir(self._root_prefix)
        self._fsync_calls += Int64(1)

    # -------------------------------------------------------------------------
    # Conformer-specific helpers (NOT part of the SpillStorage trait).
    # -------------------------------------------------------------------------

    def root_prefix(self) -> String:
        """The root namespace under which chunk paths are minted. Used by
        tests + observability."""
        return self._root_prefix

    def chunk_prefetch_path(self, chunk_id: ChunkId) -> String:
        """Part B form-(a) prefetch-offload — the on-disk path for
        `chunk_id` (the SAME path `read_chunk` will open).

        Returns the minted `<root_prefix>/chunk_<hex>.bin` path so the IO-lane
        prefetch producer can prime its pages into the OS page cache AHEAD of
        the compute thread's `read_chunk` (design §3.5 form (a)). Pure path
        construction — no IO, no live-chunk check (a not-live chunk yields a
        valid-but-nonexistent path; the prefetch of a missing file is a benign
        no-op). Cheap (string concat) so it is safe to call per-chunk in the
        restore loop."""
        return _chunk_path(self._root_prefix, chunk_id._unsafe_value())

    def chunk_recorded_length(self, chunk_id: ChunkId) -> Int64:
        """Part B form-(a) — the recorded byte length of `chunk_id`, or 0 if not
        live. The prefetch producer bounds its page-cache warm to this length so
        it never reads past the chunk payload. 0 means "unknown" -> the prefetch
        warms to EOF (still bounded by the file size)."""
        var maybe_len = self._live_chunks.find(chunk_id._unsafe_value())
        if maybe_len:
            return maybe_len.value()
        return Int64(0)

    def num_live_chunks(self) -> Int:
        """Count of live (written, not released) chunks. Tests +
        observability."""
        return len(self._live_chunks)

    def num_fsync_calls(self) -> Int64:
        """Count of fsync invocations issued by `sync()` so far (one per
        live chunk file + one for the spill directory, per `sync()` call).

        SPILL-DURABILITY-GAP-B. The durability gate: the no-op
        pre-fix `sync()` never fsync'd anything, so this stayed 0; the wired
        `sync()` increments it once per `fs.fsync_file` / `fs.fsync_dir`
        call. Tests + observability."""
        return self._fsync_calls

    def live_chunk_ids(self) -> List[ChunkId]:
        """Snapshot the currently-live ChunkIds. Used by teardown helpers
        (e.g. `LocalDiskSpillStorage.cleanup`) that release every live chunk
        without holding a borrow across the mutating `release_chunk`."""
        var out = List[ChunkId]()
        for entry in self._live_chunks.items():
            out.append(ChunkId(entry.key))
        return out^

    def reopen_chunk(mut self, chunk_id: ChunkId) raises:
        """Re-register a chunk written by a PRIOR writer over the same root.

        The `ChunkId -> length` map is per-instance. When a spill RUN is
        written by one `SpillStorage` instance, closed/dropped, and then
        re-opened by a FRESH instance over the same `root_prefix` (the
        write-run-then-read-back-in-a-later-phase shape — external sort spills
        runs during accumulation, merges them at finalize), the fresh instance
        has no record of the chunk. This recovers the chunk's byte length from
        the on-disk file via `FileSystem.file_size` and registers it as live
        so a subsequent `read_chunk` / `release_chunk` finds it.

        Idempotent: re-registering an already-live chunk re-stats and updates
        the recorded length (no double-count — the prior length is subtracted
        first).

        Raises if the backing file does not exist (the chunk was never written
        OR the root is wrong).
        """
        var value = chunk_id._unsafe_value()
        var path = _chunk_path(self._root_prefix, value)
        var n = Int64(self._fs.file_size(path))
        var existing = self._live_chunks.find(value)
        if existing:
            self._nbytes_in_use -= existing.value()
        # Recovery path: re-registering a chunk that already exists on disk is
        # not budget-checked, so this can take `nbytes_in_use()` past the
        # budget.
        self._live_chunks[value] = n
        self._nbytes_in_use += n
        # Keep the mint counter ahead of any re-registered id so a later
        # write_chunk on this instance does not collide with a reopened chunk.
        if value >= self._next_chunk_id:
            self._next_chunk_id = value + UInt64(1)
