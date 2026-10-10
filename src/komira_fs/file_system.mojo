# =============================================================================
# komira_fs.file_system — FileSystem trait
# =============================================================================
# FileSystem trait + monomorphization decision (Mojo has no `dyn` dispatch;
# trait-objects are off the table; URI-scheme dispatch resolves to a concrete
# monomorphization at session-construction time).
#
# The trait shape is sync and buffer-returning (`read_at`). Alternatives
# rejected: threading dataplane parameters through every format reader bleeds
# them into every reader; requiring MmapAlignedBuffer to be Copyable is a perf
# regression. Keeping the dataplane state on the cloud-FS conformer struct and
# exposing a sync buffer-returning method matches every existing call site's
# expectation.
#
# Canonical trait shape (read + write):
#
#   trait FileSystem(Movable, Deinitable):
#       alias File: Movable & Deinitable
#       alias WriteFile: Movable & Deinitable       #
#       alias IS_MMAP_BACKED: Bool = False
#       alias SUPPORTS_PARALLEL_WRITES: Bool = False             #
#       def list(self, prefix: String) raises -> List[String]
#       def open(self, path: String) raises -> Self.File
#       def read_at(self, mut file: Self.File, offset: Int64,
#                   length: Int64) raises -> MmapAlignedBuffer[64]
#       def prefetch_depth(self) -> Int
#       def supports_random_read(self) -> Bool
#       def read_footer(self, path: String,
#                   window: Int) raises -> FooterRegion
#       def is_dir(self, path: String) raises -> Bool
#       def file_size(self, path: String) raises -> Int
#       # ---- --
#       def open_write(self, path: String, mode: WriteMode)
#                   raises -> Self.WriteFile
#       def write_at(self, mut file: Self.WriteFile,
#                   data: Span[UInt8, _]) raises -> Int64
#       def pwrite_at(self, file: Self.WriteFile, offset: Int64,
#                   data: Span[UInt8, _]) raises -> Int64
#       def close_write(self, var file: Self.WriteFile) raises -> None
#
# What changed in
#   * `alias S: WakerSink & Movable & Deinitable` REMOVED.
#     The async waker-sink type is no longer threaded through the trait;
#     cloud-FS conformers (S3Fs / GcsFs / AzureFs in/E) hold the
#     reactor + connector as struct fields and drive any async work
#     internally inside `read_at`.
#   * `read_at` return type swapped from
#     `IoOp[Int64, Self.S, never_origin]` (with caller-owned destination
#     buffer) to `MmapAlignedBuffer[64]` (buffer-returning, FS-allocated).
#     LocalFs returns a borrow-from-mmap MmapAlignedBuffer (zero-copy);
#     cloud-FS conformers return an owning MmapAlignedBuffer holding the
#     response body bytes (one alloc + one memcpy per range, dominated
#     by HTTP latency anyway).
#   * IoOp / WakerSink / never_origin imports removed; MmapAlignedBuffer
#     import added.
#   * No trait conformer is required to be Movable BEYOND the existing
#     `(Movable, Deinitable)` umbrella. Cloud-FS conformers
#     (S3Fs) that need parametric-origin Pointer fields can
#     drop `Movable` and document the per-call-site construction pattern
#     (StreamingFileBodySink[O] precedent at
#     `src/komira_arrow/ipc_body_sink.mojo:221-260`). That is a
#     concern;'s LocalFs is straightforwardly Movable.
#
# Pointer discipline (unchanged):
#   * ZERO `UnsafePointer` in any public method signature.
#   * MmapAlignedBuffer's internal UnsafePointer (for mmap-borrow and
#     owning-heap paths) is documented at the type level; the trait
#     surface itself only references the value type.
# =============================================================================

from komira_buffer.shared_aligned_buffer import SharedAlignedBuffer
from komira_collections.slab import Slab
from komira_buffer.heap_region import HeapRegion
from komira_fs.footer_region import FooterRegion
from komira_fs.shallow_dir_entry import ShallowDirEntry


# =============================================================================
# WriteMode — open-mode enum for FileSystem.open_write
# =============================================================================
#
# Scope:
#
#   * CREATE_TRUNCATE  — O_WRONLY|O_CREAT|O_TRUNC; create or overwrite.
#                        Matches existing `RawWriteFd.open_truncate` and
#                        every codec writer's default semantics today.
#   * CREATE_EXCLUSIVE — O_WRONLY|O_CREAT|O_EXCL; atomic create-or-fail.
#                        Raises if path already exists. Load-bearing for
#                        future atomic-rename SDK flows.
#   * APPEND           — O_WRONLY|O_APPEND; opens existing (no O_CREAT,
#                        no O_TRUNC). Matches existing
#                        `RawWriteFd.open_existing_append` shape.
#
# Rejected: CREATE_OR_OPEN (no current call site); random-RDWR (out of
# scope — open separate read+write handles).
#
# TrivialRegisterPassable POD: just a u8 discriminant. Safe to copy /
# return-by-value through the trait surface. Pattern matches the
# canonical u8-discriminant POD-enum shape used widely in the engine.
# =============================================================================


struct WriteMode(
    TrivialRegisterPassable,
    Copyable,
    ImplicitlyCopyable,
    Movable,
    Deinitable,
):
    """Open-mode discriminant for `FileSystem.open_write`.

    Three modes (see file header for the design rationale):
      * `CREATE_TRUNCATE`  — create-or-overwrite (existing files lose
        their contents). The default for codec writers.
      * `CREATE_EXCLUSIVE` — atomic create-or-fail (raises if the path
        already exists).
      * `APPEND`           — open existing file; every write positioned
        at end-of-file atomically.

    Use the named static constructors (`WriteMode.create_truncate()`
    / `WriteMode.create_exclusive()` / `WriteMode.append()`) rather
    than constructing from the raw discriminant. Equality is defined.
    """

    # Discriminant values. Stable for IPC / serialization; new modes
    # must extend the tail.
    comptime _CREATE_TRUNCATE: UInt8 = 0
    comptime _CREATE_EXCLUSIVE: UInt8 = 1
    comptime _APPEND: UInt8 = 2

    var value: UInt8

    def __init__(out self, value: UInt8):
        """Construct from a raw discriminant. Prefer the static factories."""
        self.value = value

    @staticmethod
    @always_inline
    def create_truncate() -> Self:
        """O_WRONLY|O_CREAT|O_TRUNC — create or overwrite."""
        return Self(value=Self._CREATE_TRUNCATE)

    @staticmethod
    @always_inline
    def create_exclusive() -> Self:
        """O_WRONLY|O_CREAT|O_EXCL — atomic create-or-fail."""
        return Self(value=Self._CREATE_EXCLUSIVE)

    @staticmethod
    @always_inline
    def append() -> Self:
        """O_WRONLY|O_APPEND — open existing, every write at EOF."""
        return Self(value=Self._APPEND)

    @always_inline
    def __eq__(self, other: Self) -> Bool:
        return self.value == other.value

    @always_inline
    def __ne__(self, other: Self) -> Bool:
        return self.value != other.value

    @always_inline
    def is_create_truncate(self) -> Bool:
        return self.value == Self._CREATE_TRUNCATE

    @always_inline
    def is_create_exclusive(self) -> Bool:
        return self.value == Self._CREATE_EXCLUSIVE

    @always_inline
    def is_append(self) -> Bool:
        return self.value == Self._APPEND


# =============================================================================
# FileSystem trait (sync buffer-returning)
# =============================================================================
#
# One associated-type alias:
#   * File — the per-fs file handle type. Concrete impls bind this to e.g.
#     `LocalFile`, `S3FileHandle`, `HdfsFileHandle`. Movable so it can flow
#     by value through the source operator's cursor; Deinitable
#     so its drop is checked under ASAP destruction.
#
# Method shape:
#   * Sync metadata: list / open / read_footer / is_dir / file_size
#   * Sync byte ops: read_at returns MmapAlignedBuffer[64] (buffer-returning;
#     LocalFs zero-copy via mmap; cloud-FS conformers own the bytes)
#   * Capability queries: prefetch_depth / supports_random_read
#     (compile-time-known per impl; the operator reads them at
#     construction time to size its PrefetchRing).
#
# Why sync:
#   The trait's previous async `IoOp[Int64, Self.S, never_origin]` shape
#   forced every format-reader call site to either drive an IoOp to
#   completion (boilerplate `.wait()` against a never-Pending IoOp) or
#   carry the WakerSink type parameter through. NO existing call site
#   today provided a destination buffer (every call site allocated +
#   returned a buffer; the IoOp's Int64 payload was the byte count).
#   The buffer-returning shape matches the actual call-site shape directly.
# =============================================================================


trait FileSystem(Movable, Deinitable):
    """Storage backend trait — URI-scheme dispatched at session-construction
    time, monomorphized per (FS, FMT) pair on the source operator (per
 recommendation).

    Concrete impls (one per storage backend):
      * LocalFs — local POSIX filesystem (this file's sibling
        `local_fs.mojo`); mmap-backed zero-copy random-access reads via
        `MmapAlignedBuffer.borrow_from_mmap`.
      * S3Fs — AWS S3; HTTP GET-Range + IAM auth. `read_at`
        body internally drives `S3Store.get_range[RT, C]` to completion
        and wraps the returned `List[UInt8]` in an owning MmapAlignedBuffer.
      * HdfsFs / GcsFs / AzureFs — follow-ups.

    Associated types:
      * `File` — per-fs file handle (Movable); flows through the source
        operator's cursor. For LocalFs this carries the lazy-mmap state
        (an `Optional[ArcPointer[MmapRegion]]` field) so multiple
        `read_at` calls reuse the same kernel mapping.

    Capability queries (`supports_random_read`, `prefetch_depth`) are
    compile-time-known per impl; the source operator reads them at
    construction time to size its PrefetchRing.

    Pointer discipline:
      * No UnsafePointer in any method signature.
      * `Self.File` associated-type binding is typed
        Movable/Deinitable; concrete impls drive any IO
        (mmap for local, HTTP GET-Range for cloud) inside the method
        body. Cloud-FS conformers hold their dataplane state (runtime,
        connector, reactor) as struct fields constructed per-query.
    """

    comptime File: Movable & Deinitable

    # ----
    # `WriteFile` is a SEPARATE associated-type alias from `File`. The
    # read-side `File` carries mmap state (`Optional[ArcPointer[MmapRegion]]`)
    # that writes must NOT pay for; a write-only handle wraps the
    # write-side fd primitive (e.g. `RawWriteFd` for LocalFs) without
    # any read-side bookkeeping. Two aliases is the clean shape; bundling
    # would either bloat LocalFile with a stale `Optional[RawWriteFd]`
    # field or force writes to mmap.
    comptime WriteFile: Movable & Deinitable

    # ---- Capability flag: SUPPORTS_PARALLEL_WRITES ----
    # Advertises whether `pwrite_at` (disjoint-range concurrent writes)
    # is viable on this conformer. Parallels `IS_MMAP_BACKED` shape.
    #   * LocalFs       — True (POSIX pwrite(2) is atomic for disjoint
    #                     ranges on a regular file).
    #   * Cloud-FS      — False (multipart / resumable / block-list
    #                     protocols are serial finalize).
    # Consumer-side use: parallel codec writers (JSONL parallel-pwrite,
    # future Parquet column-parallel) `@parameter if`-branch on this at
    # comptime. Branch resolves per monomorphized [FS]; no runtime cost.
    comptime SUPPORTS_PARALLEL_WRITES: Bool = False

    # ---- Capability flags ----
    # `IS_MMAP_BACKED` advertises whether the FS exposes a kernel-mmap'd
    # zero-copy substrate (`MmapRegion.open_readonly` + `MmapAlignedBuffer.
    # borrow_from_mmap`). Conformers that DO (LocalFs) override to True;
    # cloud-FS conformers (S3Fs, GcsFs, AzureFs) leave the default False
    # — their bytes live on the network and require a copy into an owning
    # buffer.
    #
    # Consumer-side use: format readers (ParquetFileReader, CSV/ORC/JSON)
    # branch via
    # `@parameter if FS.IS_MMAP_BACKED` to select between
    # `borrow_from_mmap` (LocalFs fast path) vs `fs.read_at(file, ...)`
    # (cloud owning-buffer path). The branch resolves at comptime per
    # monomorphized [FS]; no runtime cost.
    comptime IS_MMAP_BACKED: Bool = False

    # ---- Capability flag: SUPPORTS_LAZY_HIVE ----
    # Advertises whether this FS has a WORKING `list_dir_shallow` (for the
    # SDK partition-schema probe) + `list` (for the engine ctor's targeted
    # prefix listing) that `PrunedHiveDiscovery.open_pruned` can prune over.
    # When True, the lazy Hive dir-scan re-route (/b) admits this
    # FS: the engine binds `DISC = PrunedHiveDiscovery` and lists ONLY the
    # surviving partition prefixes (the marquee "never list pruned
    # partitions" cloud-listing win).
    #
    #   * LocalFs        — True (POSIX shallow walk + recursive list; the
    # lazy path validated on local).
    #   * S3Fs / GcsFs   — True (they implement `list_dir_shallow`; `list` is
    #                      the paginated recursive list.)
    #   * AzureFs        — True (landed `list_dir_shallow`
    #                      (BlobPrefixes -> dir / Blob -> file) + the
    #                      paginated recursive `list` (NextMarker loop) + the
    #                      shallow-probe `is_dir` fix. Azure is now at
    #                      S3/GCS directory-read parity.)
    #
    # Consumer-side use: `pq_data_can_carry_hive[FS]()`
    # (`materialize_parquet.mojo`) gates the comptime `DISC` branch on this
    # flag — it keeps the second (PrunedHive) source monomorph OUT of every
    # FS conformer that has NOT validated the cloud lazy path. This is a
    # capability flag (not an FS-identity check) so flips Azure's flag
    # in ONE place when its shallow listing is ready.
    comptime SUPPORTS_LAZY_HIVE: Bool = False

    # ---- Capability flag: SCHEME ----
    # The FS scheme code, BYTE-IDENTICAL to `komira_plan_expr.fs_descriptor_pod`
    # `FS_SCHEME_*` (this package cannot import it, so the default is a
    # literal):
    #   FILE = 0, S3 = 1, GCS = 2, AZURE = 3.
    # Defaulted to FILE (local). Cloud conformers (S3Fs / GcsFs / AzureFs)
    # override. A plan names its source by this code (komira_source_url maps
    # a URL's prefix to it before the plan is built); komira_source_url's
    # test_source_scheme_agrees holds every conformer's SCHEME to that
    # mapping. Resolves at comptime per monomorphized [FS]; no runtime cost.
    comptime SCHEME: UInt8 = 0

    # -----α — clone() for multi-file factory loops ----
    # `ParquetReaderFactory.open[FS]` consumes its FS argument via move
    # (`fs^`) for the inner pImpl construction, but the factory may need
    # to open multiple files in a single directory scan. Without
    # `clone()`, the factory can only open ONE file before the FS moves
    # into the inner reader and the factory loses its handle.
    #
    # Contract:
    #   * Non-consuming (`self`, not `mut self` / `var self`); the original
    #     remains usable.
    #   * Returns a Self by value (Movable trait bound on the conformer
    #     guarantees this composes).
    #
    # Cost contract (per conformer):
    #   * LocalFs[Sink] — `_root: String` copy; no heap-shared state; zero
    #     atomic ops. Cheap (~tens of ns per call).
    #   * S3Fs[C, dispatch_o] — `_bucket: String` copy + borrowed-Pointer
    #     POD copy (borrowed-Pointer shape; both fs and clone
    #     borrow the SAME caller-owned S3Client via duplicate Pointers
    #     rooted in the same `dispatch_o` origin). NO atomic ops; NO
    #     Arc-bump. Cost is dominated by network RTT for the subsequent
    #     reads.
    #   * Future cloud-FS conformers (GcsFs, AzureFs) should follow the
    #     S3Fs pattern: `[C, dispatch_o]`-parametric with a borrowed
    #     Pointer to a caller-owned client; clone duplicates the
    #     borrowed Pointer (POD copy).
    def clone(self) -> Self:
        """Return a fresh, by-value Self that shares any borrowed
        heavy state with `self` via duplicated Pointers (so multiple
        consumers can drive independent reads through one underlying
        caller-owned client). Required by factory loops that open
        multiple files from one configured FileSystem (e.g.
        ParquetReaderFactory directory scans)."""
        ...

    # ---- Sync metadata ops (small, cheap; OK to block briefly) ----
    def list(self, prefix: String) raises -> List[String]:
        """List file paths matching `prefix`. Returns absolute paths.
        Sync because metadata ops are bounded (<ms locally; paginated for
        cloud — streaming listing is a later step)."""
        ...

    def open(self, path: String) raises -> Self.File:
        """Open a read-handle. Returned `File` is Movable; the caller
        threads it through `read_at` for random-access reads. The caller
        owns the handle — drop closes the underlying fd / connection
        (or releases the mmap keepalive for LocalFs).

        Open semantics are lazy where possible: LocalFs.open does NOT
        mmap at open time; the mmap fires on the first `read_at` to
        avoid paying for files that are stat'd but never read."""
        ...

    # ---- Sync byte ops (buffer-returning) ----
    def read_at(
        self,
        mut file: Self.File,
        offset: Int64,
        length: Int64,
    ) raises -> SharedAlignedBuffer[HeapRegion]:
        """Read `length` bytes from `offset` in `file`. Returns a
        `SharedAlignedBuffer[HeapRegion]` whose bytes span `[offset, offset+length)`.

        Backend semantics:
          * LocalFs — borrowed-from-mmap (zero-copy). The buffer's
            `_keepalive` holds an `ArcPointer[MmapRegion]` refcount;
            the mmap stays alive until the last buffer drops. Multiple
            parallel reads on the same `file` reuse the same mapping.
          * S3Fs / GcsFs / AzureFs (/E) — owning. The body
            internally calls `S3Store.get_range[RT, C]` (or equivalent
            via the FS-held connector + reactor fields) which parks
            the calling worker on the reactor until the HTTP response
            body lands; the returned `List[UInt8]` is then copied into
            an owning `MmapAlignedBuffer[64]` (one alloc + one memcpy per
            range, dominated by network latency).

        Why sync return (vs an IoOp wrapper):
        Every existing call site (ParquetFileReader.read_bytes,
        read_chunked) is buffer-returning today; the trait now matches
        rather than asking each call site to morph.

        Raises:
          * LocalFs: mmap failures (file not found, permissions,
            address-space exhaustion), out-of-bounds offset+length.
          * Cloud-FS conformers: HTTP errors (4xx/5xx, body truncation,
            signature failures) surfaced via `S3Store.get_range`'s
            existing `Error(String)` channel.
        """
        ...

    # ---- prefetch fan-out read ----
    def read_ranges_prefetched(
        self,
        mut file: Self.File,
        ranges: List[Tuple[Int64, Int64]],
    ) raises -> Slab[SharedAlignedBuffer[HeapRegion]]:
        """read N `(offset, length)`
        ranges from `file`, returning one owning buffer per range in INPUT
        ORDER.

        This is the trait-method form of the cloud `read_ranges`
        fan-out (the free `read_ranges` at the bottom of `s3_fs.mojo` is
        the sequential default; a cloud conformer overrides this method
        with an N-in-flight prefetch strategy to overlap the per-range
        body transfers).

        Backend semantics:
          * LocalFs (`IS_MMAP_BACKED == True`) — sequential `read_at`
            (mmap is already zero-copy; there is no transfer to overlap).
            Consumers branch `@parameter if FS.IS_MMAP_BACKED` and DON'T
            call this for LocalFs, but the conformer still implements it
            so the generic `[FS: FileSystem]` decode path type-checks.
          * S3Fs (`IS_MMAP_BACKED == False`) — issues all N ranged GETs as
            STREAMING requests up front, then round-robin drains their
            bodies so a Pending on one stream yields immediately to the
            next (the per-core spin self-resolves; the per-read
            EWOULDBLOCK storm collapses).

        Returns a `Slab[SharedAlignedBuffer[HeapRegion]]` of size N;
        entry `i` is the owning buffer for `ranges[i]`.
        """
        ...

    # ---- Capability queries (compile-time-known per impl) ----
    def prefetch_depth(self) -> Int:
        """Per-storage-type prefetch depth — operator uses this to size
        its PrefetchRing. Values from `prefetch_source.mojo`:
          * Local NVMe = 4
          * Networked block (EBS) = 16
          * S3 standard = 64
          * S3 Express = 32
          * HDFS = 16
        These defaults come from an empirical prefetch-depth
        calibration per backend."""
        ...

    def supports_random_read(self) -> Bool:
        """True for filesystems that support pread / range-GET style
        random-access reads; False for sequential-only sources (e.g.
        HTTP without Range header). Most production FS impls return
        True."""
        ...

    # ---- sync metadata + footer-region read ----
    # Three blocking-
    # fetch methods used at construction time by `ReaderFactory.open`
    # (footer parses) and `PathDiscovery.open` (auto-detect single vs
    # directory). Sync (blocking) by intent — see spec (rationale)
    # and (orthogonal to the hot-path `read_at` shape).
    def read_footer(self, path: String, window: Int) raises -> FooterRegion:
        """Bounded one-shot **speculative tail read** — the file's trailing
        region bytes AND its total size, in ONE conformer call.

        Used at construction time by `ReaderFactory.open` for footer parses;
        bypassed when the EngineContext-scoped footer cache hits.

        Sync (blocking) by intent — NOT a wrapper around `read_at`'s
        mmap/HTTP cycle.

        the return type carries `file_size`
        because the callers all need it and the conformer already knows it —
        a `List[UInt8]` return forced a SECOND, serially-dependent
        `fs.file_size(path)` call, which on every object store is an HTTP
        HEAD, i.e. an entire extra round trip. A cloud conformer satisfies
        the whole call with ONE **suffix range** request
        (`Range: bytes=-N`) whose `Content-Range: bytes A-B/TOTAL` response
        header supplies the size; a local conformer gets it from the same
        stat/seek it already performs. See
        `komira_fs/footer_region.mojo` for the window policy.

        The region is `window` trailing bytes (or the whole file if
        smaller); conformers derive the start offset with the shared
        `speculative_tail_start(file_size, window)` so the clamping policy
        lives in one place. A format whose footer exceeds the window issues
        ONE exact follow-up `read_footer` with the now-known exact size —
        correctness never depends on the speculation being large enough.

        `window` became a
        PARAMETER because a fixed constant is provably wrong — 20 of the 167
        bench fixtures have footers larger than the old 256 KiB constant,
        under a comment claiming none did. Callers pass
        `FooterWindowHints.suggest(path)`, which is the cold default
        `FOOTER_SPECULATIVE_WINDOW` for an unseen dataset and the learned
        size for one this session has already opened a file from.

        Returned bytes are owned. `FooterRegion.offset + len(bytes)` MUST
        equal `file_size` (callers index the trailer from the END).

        Raises on: file-not-found, permissions, truncation below
        minimum format size.
        """
        ...

    def is_dir(self, path: String) raises -> Bool:
        """Return True iff `path` is a directory. Used by
        `PathDiscovery.open` to auto-detect single-file vs
        directory-scan mode.

        For local POSIX, `stat() & S_IFDIR`. For object stores, returns
        True iff `path` ends with `/` (prefix-list semantics) — adjust
        per backend.
        """
        ...

    def list_dir_shallow(
        self, dir: String
    ) raises -> List[ShallowDirEntry]:
        """SHALLOW (one-level) listing of `dir`'s immediate children — the
        / partition-schema probe primitive. NOT
        recursive: returns only the direct children (each tagged dir vs
        file), never descending into the data leaves.

        Trait-method form added in all four
        conformers (LocalFs / S3Fs / GcsFs / AzureFs) already implement
        this; promoting it onto the trait lets the `[FS]`-generic Hive
        shallow-probe (`_probe_hive_partition_schema_shallow[FS]`) call it
        uniformly, gated by `FS.SUPPORTS_LAZY_HIVE`.

        Backend semantics:
          * LocalFs — single `getdents`/`readdir` syscall over `dir`.
          * S3Fs / GcsFs / AzureFs — a delimiter-`/` `ListObjects` /
            `ListBlobs` page over the `dir` prefix; `CommonPrefixes`
            become `is_dir=True` entries, object keys become files. ONE
            listing per partition level (the cloud-listing win — never a
            recursive enumeration of the leaf data files).
        """
        ...

    def file_size(self, path: String) raises -> Int:
        """Return the size of `path` in bytes. Used by the footer cache
        validity check `(path, file_size)` per
        `ParquetMetadataCache._RuntimeFooterEntry`.

        For local POSIX, `stat()` reports `st_size`. For S3,
        HEAD-Object reports `Content-Length`. Sync (blocking) by intent
; called once per Reader open at construction time.

        Raises on: file-not-found, permissions.
        """
        ...

    # =========================================================================
    # WRITE-side trait surface
    # =========================================================================
    #
    # Four methods, mirror of the read-side buffer-returning shape:
    #   * `open_write`    — opens a write handle with the given mode
    #   * `write_at`      — cursor-advancing write (mut file)
    #   * `pwrite_at`     — disjoint-range concurrent-safe write (non-mut)
    #   * `close_write`   — explicit commit boundary (multi-call protocols
    #                       for cloud-FS conformers: multipart-finalize,
    #                       resumable-finalize, block-list-commit)
    #
    # The chunked-write 64 MiB workaround for the Mojo 1.0.0b1 stdlib
    # `FileHandle.write` >2 GB silent-flush bug is absorbed INSIDE
    # `LocalFs.write_at`. Codec writers do not import
    # `komira_libc.chunked_write` directly.
    # =========================================================================

    def open_write(
        self, path: String, mode: WriteMode
    ) raises -> Self.WriteFile:
        """Open a write handle for `path` with the given `mode`.

        Semantics per `WriteMode`:
          * `CREATE_TRUNCATE`  — create or overwrite (existing files lose
            their contents). The default for codec writers.
          * `CREATE_EXCLUSIVE` — atomic create-or-fail. Raises if the
            path already exists.
          * `APPEND`           — open existing; every write positioned at
            EOF atomically by the kernel. Raises if path does not exist.

        Returned `WriteFile` is Movable; the caller threads it through
        `write_at` / `pwrite_at`, then `close_write` to commit. The
        caller owns the handle — drop closes the underlying fd /
        connection (or aborts the upload for cloud-FS conformers without
        an explicit `close_write`).

        Raises on:
          * File-not-found (APPEND mode), permissions
          * Already-exists (CREATE_EXCLUSIVE mode)
          * Underlying open(2) / network-create errors
        """
        ...

    def write_at(
        self,
        mut file: Self.WriteFile,
        data: Span[UInt8, _],
    ) raises -> Int64:
        """Cursor-advancing write of `data` to `file`. Returns total
        bytes written.

        `file` is `mut` because each write advances the per-handle
        cursor (the kernel's per-fd file-position pointer for LocalFs;
        an internal byte-counter for cloud-FS conformers driving
        multipart uploads in offset order).

        LocalFs absorbs the 64 MiB chunking workaround for the
        Mojo 1.0.0b1 stdlib `FileHandle.write` >2 GB silent-flush
        bug INTERNALLY — callers do not need to chunk themselves.
        Empty input is a no-op.

        Concurrency contract: NOT safe to call concurrently on the
        same `file` (the cursor races). For parallel disjoint-range
        writes, use `pwrite_at` and gate the conformer on
        `Self.SUPPORTS_PARALLEL_WRITES`.

        Raises on: closed handle, write(2) failure (disk full,
        signal, etc.), cloud-FS upload-part errors.
        """
        ...

    def pwrite_at(
        self,
        file: Self.WriteFile,
        offset: Int64,
        data: Span[UInt8, _],
    ) raises -> Int64:
        """Positional (non-cursor-advancing) write of `data` at `offset`
        in `file`. Returns total bytes written.

        BOTH `self` and `file` are NON-MUT — this is the disjoint-range
        concurrent-safe path. POSIX `pwrite(2)` is documented atomic for
        regular files; multiple threads MAY call `pwrite_at` concurrently
        on the same `file` provided each thread's
        `[offset, offset+len(data))` range is disjoint from every other
        thread's. This shape matches the load-bearing JSONL parallel
        writer's existing `RawWriteFd.pwrite_at` call site.

        Conformers that DO NOT support disjoint-range concurrent writes
        (cloud-FS: multipart / resumable / block-list serial finalize)
        MUST advertise `SUPPORTS_PARALLEL_WRITES = False` AND raise an
        explanatory `Error` when `pwrite_at` is called (
        resolution: raise fail-fast for clearer debug, do not silently
        delegate to write_at).

        Empty input is a no-op.

        Raises on:
          * Closed handle
          * Negative offset
          * `Self.SUPPORTS_PARALLEL_WRITES == False` (cloud-FS)
          * pwrite(2) failure (disk full, signal, etc.)
        """
        ...

    # =========================================================================
    # delete
    # =========================================================================
    #
    # Added so that `FileSystemSpillStorage[FS].release_chunk` can reclaim
    # disk / object-store space by deleting a chunk's backing path (the
    # spill layer is chunk-keyed; FileSystem is path-keyed, so the spill
    # layer maps ChunkId -> path and calls `delete(path)`).
    #
    # DEFAULT BODY (raises "unimplemented"): the FileSystem trait surface
    # is shared across the S3Fs / GcsFs / AzureFs
    # conformers. Rather than force a
    # breaking trait change across those 3+ conformers, `delete` ships with
    # a default trait-method body that raises. Only `LocalFs` overrides it
    # concretely (POSIX unlink, ENOENT-tolerant). S3Fs / GcsFs / AzureFs
    # INHERIT this default and compile unchanged; implements
    # them for real (object DELETE) in a follow-up. Mojo 1.0.0b1 supports
    # default trait-method bodies (see e.g. `auto_schema.schema`,
    # `expr_udf_traits.filter_expr` in-tree).
    def delete(self, path: String) raises -> None:
        """Delete the file / object at `path`. ENOENT-tolerant: deleting a
        path that does not exist is a no-op (does NOT raise) — matches the
        POSIX `unlink(2)`/ENOENT idempotence the spill layer relies on for
        double-release safety.

        DEFAULT BODY raises an "unimplemented" error. Concrete conformers
        override:
          * LocalFs — POSIX `remove(3)`/`unlink(2)`, ENOENT swallowed.
          * S3Fs / GcsFs / AzureFs — object DELETE (a
            follow-up; today they inherit this raising default).

        Raises:
          * On unexpected backend failure (e.g. EACCES, EIO unlinking from
            a failing disk; cloud DELETE 5xx). ENOENT does NOT raise.
          * Default body: always raises "FileSystem.delete: unimplemented".
        """
        raise Error(
            "FileSystem.delete: unimplemented for this conformer "
            "(only LocalFs implements delete today; cloud-FS conformers "
            "do not implement delete yet). path=" + path
        )

    # =========================================================================
    # durable-flush barrier surface
    # =========================================================================
    # Without these, the FileSystem spill durable-flush
    # (`FileSystemSpillStorage[FS].sync()`) would be a PAGE-CACHE NO-OP — a
    # "synced" spill segment would survive a process crash but NOT a power
    # loss (no fsync(2)). A streaming WAL + exactly-once + checkpoint depend on
    # this LOCAL-FS durable barrier.
    #
    # Durability model: durable = await-the-backend-durable-
    # ack = fsync on LOCAL-FS (these two methods) | PUT-ack on S3 (already
    # durable; cloud-FS conformers make the bytes durable at `close_write`
    # finalize time, so their fsync surface is a no-op override — see below).
    #
    # DEFAULT BODY (raises "unimplemented"): mirror of `delete` / `abort_write`
    # — the trait surface is shared across the cloud-FS conformers, so a default-raising body keeps them compiling unchanged.
    # Conformer overrides:
    #   * LocalFs  — `fsync_file` -> `posix_io.fsync_path(path)`;
    #                `fsync_dir`  -> `posix_io.fsync_dir(dir)`.
    #   * S3Fs / GcsFs / AzureFs — bytes durable at PUT/finalize; override
    #     both to a NO-OP (return without raising) once their write surface
    #     lands, so a generic `[FS]` spill durable-flush composes uniformly.
    def fsync_file(self, path: String) raises -> None:
        """Flush the file at `path` to underlying storage so its bytes
        survive a power loss (not just a process crash). Returns only after
        the backend acknowledges durability.

        Conformer semantics:
          * LocalFs — `fsync(2)` the inode behind `path` (via
            `posix_io.fsync_path`: re-open write-append, fsync, close).
          * S3Fs / GcsFs / AzureFs — no-op once their write surface lands
            (object bytes are durable at PUT / multipart-finalize ack; there
            is no separate fsync step). Today they inherit this raising
            default.

        Encapsulation: takes a `String` path, returns `raises`. NO raw fd /
        UnsafePointer crosses the boundary — the fsync syscall lives INSIDE
        the conformer.

        DEFAULT BODY raises "unimplemented".
        """
        raise Error(
            "FileSystem.fsync_file: unimplemented for this conformer "
            "(only LocalFs implements fsync today; cloud-FS conformers are "
            "durable at PUT/finalize ack and override to a no-op when their "
            "write surface lands). path=" + path
        )

    def fsync_dir(self, dir: String) raises -> None:
        """Flush the directory inode at `dir` so newly-created / renamed
        directory ENTRIES (filenames) under `dir` survive a power loss.

        Power-loss durability for a CREATED file requires fsync'ing both the
        file's data (`fsync_file`) AND the parent directory's inode: the new
        directory entry that names the file is metadata in the directory
        inode. Without this, after a power loss the file's data can be durable
        while the entry that NAMES it is lost — the file becomes unreachable.

        Conformer semantics:
          * LocalFs — `fsync(2)` a read-only directory fd (via
            `posix_io.fsync_dir`).
          * S3Fs / GcsFs / AzureFs — no-op (object stores have no directory
            inode; key visibility is atomic at PUT ack). Today they inherit
            this raising default.

        Encapsulation: takes a `String` dir, returns `raises`. NO raw fd /
        UnsafePointer crosses the boundary.

        DEFAULT BODY raises "unimplemented".
        """
        raise Error(
            "FileSystem.fsync_dir: unimplemented for this conformer "
            "(only LocalFs implements directory fsync today; object stores "
            "have no directory inode and override to a no-op). dir=" + dir
        )

    def seek_write_to_end(self, mut file: Self.WriteFile) raises -> Int64:
        """Re-sync `file`'s write offset to the current EOF; return the
        new offset.

        After a parallel disjoint-
        range `pwrite_at` page commit (which is positional and does NOT
        advance the cursor), the streaming parquet writer calls this to
        restore the cursor so the subsequent cursor-advancing `write_at`
        (footer) appends correctly.

        DEFAULT BODY raises "unimplemented". Only `LocalFs` overrides it
        concretely (`lseek(fd, 0, SEEK_END)`). Cloud-FS conformers
        advertise `SUPPORTS_PARALLEL_WRITES = False`, so the parallel-
        pwrite commit path is gated off for them and this is never
        reached — they inherit the raising default unchanged (same
        pattern as `delete`).
        """
        raise Error(
            "FileSystem.seek_write_to_end: unimplemented for this "
            "conformer (only LocalFs supports the parallel-pwrite commit "
            "path; cloud-FS conformers gate it off via "
            "SUPPORTS_PARALLEL_WRITES=False)."
        )

    def writev_at_cursor(
        self,
        mut file: Self.WriteFile,
        addrs: Span[Int, _],
        lens: Span[Int, _],
    ) raises -> Int64:
        """Single-threaded, in-order GATHER write of N scattered source
        buffers (`addrs[i]`/`lens[i]`) from `file`'s current cursor via
        `writev(2)` (kernel scatter-gather, ZERO userspace memcpy).
        Advances the cursor by the total bytes written. Returns the total.

        Preferred over a
        parallel disjoint-range `pwrite_at` fan-out for the
        per-flush page commit: an A/B microbench (410 MB / 1008 scattered
        pages, one filesystem) measured N-thread parallel `pwrite` to one shared fd
        STRICTLY SLOWER than a single-threaded in-order gather, with the
        penalty MONOTONIC in thread count (par-20 +20% on the copy_user
        term vs a single sequential pass) — the inode `i_rwsem` /
        page-cache contention signature. A single-thread `writev`
        reclaims the full contention penalty AND avoids any gather
        memcpy (the iovec points directly at the scattered page buffers).

        DEFAULT BODY raises "unimplemented". Only `LocalFs` overrides it
        concretely (IOV_MAX-batched `writev(2)` via
        `RawWriteFd.writev_addr_len`). Cloud-FS conformers advertise
        `SUPPORTS_PARALLEL_WRITES = False`, so the writev commit path is
        gated off for them and this is never reached — they inherit the
        raising default unchanged (same pattern as `seek_write_to_end`).

        Caller MUST keep every source buffer addressed by `addrs` alive
        for the duration of this synchronous call.
        """
        raise Error(
            "FileSystem.writev_at_cursor: unimplemented for this "
            "conformer (only LocalFs supports the writev page-commit "
            "path; cloud-FS conformers gate it off via "
            "SUPPORTS_PARALLEL_WRITES=False)."
        )

    def close_write(
        self, var file: Self.WriteFile
    ) raises -> None:
        """Explicit commit boundary. Consumes `file`.

        For LocalFs, this flushes outstanding writes (the kernel
        already buffers via page cache; no userspace flush is needed)
        and closes the underlying fd via `close(2)`.

        For cloud-FS conformers, this is the multi-call commit step:
          * S3      — `CompleteMultipartUpload` (assembles uploaded
                      parts into the final object).
          * GCS     — Resumable-upload finalize (zero-length chunk with
                      Content-Range total).
          * Azure   — `PutBlockList` (commits the in-memory block list).

        Callers MUST call `close_write` to make the bytes durable /
        visible. Dropping the `WriteFile` without `close_write`:
          * LocalFs — closes the fd (bytes already in page cache;
            durability requires an explicit `fsync(2)` separately —
            see `posix_io.fsync_path`).
          * Cloud-FS — aborts the upload (no finalize → no object).

        Raises on: close(2) failure (rare on regular files), cloud-FS
        finalize errors (network, S3 service errors, etc.).
        """
        ...

    # =========================================================================
    # abort_write — error-path cleanup
    # =========================================================================
    # Mirror of `delete`'s default-raising shape (file_system.mojo:609). The
    # cloud-FS write protocols (S3 multipart, GCS resumable, Azure block-list)
    # leave server-side state when an upload is INITIATED but not COMMITTED
    # (no `close_write`). An in-flight multipart upload that is dropped without
    # `complete` or `abort` accrues storage cost indefinitely. `close_write`
    # cannot be relied on for the error case (the writer raises mid-feed before
    # reaching `finish()`), and a `var file` destructor cannot `raise` nor reach
    # a `mut` transport easily. `abort_write` is the EXPLICIT error-path seam
    # the writer's mid-feed-raise / drop path calls to release server state.
    #
    # DEFAULT BODY raises "unimplemented" (same rationale as `delete`): the
    # trait surface is shared across S3Fs / GcsFs / AzureFs; a default body keeps the other conformers compiling. Only
    # LocalFs (best-effort unlink the partial corpse) and S3Fs
    # (`abort_multipart_upload`) override it concretely today.
    def abort_write(
        self, var file: Self.WriteFile
    ) raises -> None:
        """Abort an in-flight write, releasing any backend state. Consumes
        `file`. Called from a codec writer's error path (mid-feed raise /
        drop-without-`close_write`) so a partial upload does not leak.

        Conformer semantics:
          * LocalFs — best-effort unlink the partial file at the handle's
            path (the footerless corpse). Drop the fd. ENOENT-tolerant.
          * S3Fs    — `AbortMultipartUpload` (DELETE /key?uploadId=ID),
            releasing all uploaded parts. Idempotent (NoSuchUpload = success).
          * GcsFs / AzureFs — inherit the raising default until their slots.

        DEFAULT BODY raises an "unimplemented" error.

        Raises:
          * On unexpected backend failure (cloud DELETE 5xx). ENOENT /
            NoSuchUpload do NOT raise.
          * Default body: always raises "FileSystem.abort_write: unimplemented".
        """
        _ = file^
        raise Error(
            "FileSystem.abort_write: unimplemented for this conformer "
            "(LocalFs / S3Fs implement abort_write; GcsFs / AzureFs land it "
            "in their write follow-up slots)."
        )
