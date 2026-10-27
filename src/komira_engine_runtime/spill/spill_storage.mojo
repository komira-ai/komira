# =============================================================================
# spill_storage.mojo — `SpillStorage` trait + opaque `ChunkId` handle.
# =============================================================================
#
# The spill substrate is intentionally separated from `MemoryRegion`.
# `MemoryRegion` is a
# READ-ONLY `as_view` trait whose sole purpose is to expose a stable
# `ByteView[origin]` view over already-allocated bytes (mmap / heap /
# future S3-mmap-shim). `SpillStorage` is the INVERSE: append-write of
# NEW bytes + random-read-back of prior writes + chunk-level free-list.
#
# The two traits compose naturally via `SharedAlignedBuffer[K]` — bytes
# returned by `SpillStorage.read_chunk(...)` are a `SharedAlignedBuffer
# [HeapRegion]` whose `as_view()` shape (inherited from the existing
# AlignedBufferTrait surface) plugs straight into the existing
# column/row consumers. No new wrapper trait needed.
#
# # Why this lives in `komira_engine_runtime/spill/` (not `komira_core/`)
#
# Spill is engine-internal. Its
# consumers are spill paths (write) + restore paths (read), both inside
# the runtime. SDK / Flight / Arrow C-Data consumers never see spill
# bytes. Keeping the substrate under `engine_runtime` avoids leaking
# spill-internal concerns into substrate layers.
#
# # P-1.A scope (what this file ships)
#
#   * `ChunkId` — opaque Copyable wrapper over a 64-bit chunk index.
#   * `SpillStorage` trait — append-write, random-read-back, chunk
#     free-list, durability sync.
#
# # Encapsulation rule
#
# - Public trait surface uses `String`, `Int`, `SharedAlignedBuffer
#   [HeapRegion]`, `ChunkId`. NO `UnsafePointer` at the trait boundary.
# - NO wildcard origins. The trait does not declare any pointer fields.
# - Conformers (`LocalDiskSpillStorage` etc.) confine FFI / pointer
#   arithmetic to their own bodies, guarded by `# SAFETY:` comments.
# =============================================================================

from komira_buffer.shared_aligned_buffer import SharedAlignedBuffer
from komira_buffer.heap_region import HeapRegion


# =============================================================================
# ChunkId — opaque 64-bit handle returned by `write_chunk`.
# =============================================================================


struct ChunkId(Copyable, ImplicitlyCopyable, Movable, Deinitable):
    """Opaque handle returned by `SpillStorage.write_chunk`. The handle
    is logically a `(storage_id, chunk_index)` pair; the storage_id is
    implicit on the `SpillStorage` instance, so the wire shape is just
    a 64-bit chunk index. Callers treat it as opaque.

    Why a newtype (not a bare `UInt64`):
      * Self-documenting public sigs (`read_chunk(id: ChunkId)` vs
        `read_chunk(id: UInt64)`).
      * Future bookkeeping (v0.6+ may attach storage_id, generation,
        etc.) lands without churning the call sites.

    Movable + Copyable: the handle is POD (single 64-bit integer). Copy
    is the natural shape — handing a ChunkId to N consumers does NOT
    create N references to the underlying bytes (consumers must call
    `read_chunk` to access bytes, which still go through the
    `SpillStorage` instance's lifecycle).

    Fields:
        _value: The raw 64-bit chunk index. PRIVATE — accessed only by
                the owning `SpillStorage` conformer via the
                `_unsafe_value()` accessor below (file-private by
                convention; callers MUST NOT consume the raw value).
    """

    var _value: UInt64

    def __init__(out self, value: UInt64):
        """Construct from a raw 64-bit value. Only `SpillStorage`
        conformers should construct ChunkIds — external callers receive
        them from `write_chunk`.
        """
        self._value = value

    def _unsafe_value(self) -> UInt64:
        """File-private accessor for conformers. Returns the raw 64-bit
        value. NOT for external use — the value is opaque outside the
        conformer that minted the ChunkId.
        """
        return self._value

    def __eq__(self, other: Self) -> Bool:
        """Equality on the underlying value. Used by tests + the
        free-list / `_live_chunks` membership checks inside conformers.
        """
        return self._value == other._value

    def __ne__(self, other: Self) -> Bool:
        """Inverse of `__eq__`."""
        return self._value != other._value


# =============================================================================
# SpillStorage trait
# =============================================================================


trait SpillStorage(Movable, Deinitable):
    """Append-write + random-read-back chunked byte storage for spill.

    Distinct from `MemoryRegion` (which is a read-only `as_view` trait
    over already-allocated bytes). `SpillStorage` is the inverse:
    NEW bytes written by spilling operators, read back at restore
    time, released when the operator's restore completes.

    # Conformers (storage COMPOSES a FileSystem)

    Spill storage layers on the existing `FileSystem` trait rather than
    owning bespoke backends. There is ONE generic conformer:
      * `FileSystemSpillStorage[FS: FileSystem]` — parameterized over any
        `FileSystem`. `write_chunk`/`read_chunk`/`release_chunk` map onto
        `FileSystem.open_write`/`write_at`/`close_write`,
        `FileSystem.open`/`read_at`, and `FileSystem.delete` respectively.
        The spill layer owns only the `ChunkId -> (path, length)` map (the
        impedance match between path-keyed FileSystem and chunk-keyed
        SpillStorage).

    Concrete spill paths are then just FileSystem choices — NO bespoke
    spill backends:
      * `FileSystemSpillStorage[LocalFs]` — local-disk, NVMe-default; one
        file per chunk. `LocalDiskSpillStorage` is the thin self-mkdir'ing
        wrapper preserving the original call shape.
      * `FileSystemSpillStorage[S3Fs]` / `[GcsFs]` / `[AzureFs]` — cloud
        object-store spill, once those `FileSystem` conformers land their
        write + delete surface (the multipart / resumable / block-list
        protocols live INSIDE the FS conformer, not the spill layer). S3
        and GCS are `FileSystem` conformers, NOT spill backends.

    # Threading contract

    Single-writer-per-arbitrator-pass; concurrent reads from multiple
    consumers OK (restore paths may run in parallel under the
    EngineContext's worker pool, but each restore reads a distinct
    `chunk_id`). Implementers MUST document their concurrent-read
    contract in the conformer's struct docstring.

    For P-1.A's `LocalDiskSpillStorage`: writes are serialized by the
    caller (the `SpillArbitrator` in P-1.C is single-writer by
    construction — one victim at a time). Reads to distinct
    `chunk_id`s are safe to run concurrently because each chunk lives
    in its own file (no shared fd, no shared seek pointer).

    # Format

    The serialization format (THSPILL2 / THSPLC) is the CALLER's
    concern; `SpillStorage` moves opaque bytes only. The
    `SharedAlignedBuffer[HeapRegion]` payload is treated as an opaque
    byte sequence — the conformer does NOT parse, validate, or
    interpret the bytes.

    # Encapsulation

    NO `UnsafePointer` on the public trait surface. Bytes flow as `SharedAlignedBuffer[HeapRegion]` (an Arc-wrapped
    aligned buffer; the public API exposes `as_view() -> ByteView
    [origin]` for consumption). The conformer's internal FFI / pointer
    arithmetic is confined to its own body, guarded by `# SAFETY:`
    comments.

    # Why read_chunk is not parametric over the region

    A `read_chunk[K: MemoryRegion = HeapRegion]` would leave room for a future zero-copy mmap restore path
    (LocalDiskSpillStorage mmap mode that returns
    `SharedAlignedBuffer[MmapRegion]`). This trait has the simpler
    non-parametric shape (`-> SharedAlignedBuffer[HeapRegion]` always)
    — the K-parametric extension lands in a follow-up sub-slot when
    the mmap restore path is built. This keeps the trait surface
    minimal and avoids parametric-trait-method compile-risk under
    Mojo.
    """

    def write_chunk(
        mut self, var bytes: SharedAlignedBuffer[HeapRegion]
    ) raises -> ChunkId:
        """Append `bytes` and return a `ChunkId` for later read-back /
        release. Takes ownership of the buffer (passed via `var`) — the
        conformer may drop the in-memory copy as soon as the bytes are
        durable on the backing store.

        Raises if the underlying append fails (e.g. disk full, EROFS,
        EIO). The conformer MUST leave its internal state consistent
        on failure — the partial write must be cleaned up (e.g. unlink
        the partially-written file) so a subsequent `write_chunk` can
        succeed.

        Args:
            bytes: The chunk to write. Consumed. Empty buffers are
                valid (some conformers may special-case zero-length
                chunks; the trait makes no demand).

        Returns:
            A `ChunkId` opaque handle for subsequent `read_chunk` /
            `release_chunk` calls.
        """
        ...

    def read_chunk(
        self, chunk_id: ChunkId
    ) raises -> SharedAlignedBuffer[HeapRegion]:
        """Read back the chunk identified by `chunk_id`. Returns
        heap-resident bytes (`SharedAlignedBuffer[HeapRegion]`).

        Multiple reads of the SAME chunk return byte-identical copies
        (the conformer may cache, but the wire shape is "fresh
        SharedAlignedBuffer per call" — the caller owns the returned
        Arc).

        Raises if the chunk does not exist (was never written, OR was
        released, OR the conformer's backing store is unreadable
        (EIO)).

        Args:
            chunk_id: Handle minted by a prior `write_chunk` on the
                same `SpillStorage` instance. ChunkIds from one
                instance are NOT transferable to another.

        Returns:
            A `SharedAlignedBuffer[HeapRegion]` over the chunk's
            bytes. The buffer's `length()` equals the byte length of
            the original `write_chunk` payload.
        """
        ...

    def release_chunk(mut self, chunk_id: ChunkId) raises:
        """Mark the chunk reusable. The conformer MAY free / compact
        the underlying storage lazily.

        Called when the operator that wrote the chunk completes its
        restore and no longer needs the on-disk copy. After
        `release_chunk`, any subsequent `read_chunk` with the same
        `chunk_id` MUST raise (the handle is invalidated).

        Idempotent: releasing an already-released chunk is a no-op
        (does NOT raise). This matches the POSIX `unlink(2)` -ENOENT
        tolerance pattern in the LocalDiskSpillStorage conformer.

        Args:
            chunk_id: Handle to release. After return, the handle is
                invalidated; future use raises.

        Raises:
            On unexpected backend failure (e.g. EIO unlinking a file
            from a failing disk). ENOENT does NOT raise.
        """
        ...

    def nbytes_in_use(self) -> Int64:
        """Current accounting: bytes written but not yet released.

        Used by the `SpillArbitrator` (P-1.C) for budget tracking and
        by tests for the release-then-reuse assertion.

        For one-file-per-chunk conformers (e.g.
        `LocalDiskSpillStorage`), this is the sum of `length()` for
        every live chunk — NOT the sum of underlying file sizes
        (those may include filesystem block padding).

        Returns:
            Bytes of live (written but not released) chunk payload.
            0 when no chunks are live or after every chunk has been
            released.
        """
        ...

    def sync(mut self) raises:
        """Flush durability barrier. Called before the
        `SpillArbitrator` returns control to the caller that
        triggered the spill — guarantees the spilled bytes survive a
        crash before the operator's in-memory state is freed.

        For `LocalDiskSpillStorage`: `fsync(2)` every live chunk fd
        OR fsync the spill directory's inode (depending on the
        conformer's per-chunk-file-keep-open policy).

        Raises on durability barrier failure (e.g. EIO from `fsync(2)`).

        Idempotent: a second `sync()` with no intervening
        `write_chunk` is a cheap no-op (or a redundant `fsync(2)`).
        """
        ...

    # `__del__` inherited from `Deinitable`. Conformer-
    # specific cleanup happens there:
    #   * FileSystemSpillStorage[FS].__del__ — drops the composed FS +
    #     the `_live_chunks` map (POD); on-disk artifacts are reclaimed
    #     by explicit `release_chunk` / `cleanup`, or a process-exit /
    #     next-session directory/prefix sweep (FileSystem.delete may not
    #     be wired on every FS conformer yet — cloud-FS inherit the
    #     raising default).
    # Conformers MUST NOT raise from `__del__`; on cleanup failure,
    # log + leak. Drop-path failures are detectable via subsequent
    # session-startup directory-scan cleanup paths.
