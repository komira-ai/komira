# =============================================================================
# Parquet File Reader — footer parsing and byte-level file access
# =============================================================================
#
# A Parquet file has this structure:
#
#   [4 bytes magic "PAR1"]
#   [row group 1 data pages...]
#   [row group 2 data pages...]
#   ...
#   [file metadata (Thrift-encoded)]
#   [4 bytes metadata length (little-endian Int32)]
#   [4 bytes magic "PAR1"]
#
# The reader:
#   1. Reads the file's tail through its `FileSystem` (`read_parquet_preamble`)
#   2. Checks the trailing magic and decodes the 4-byte metadata length
#   3. Slices the Thrift metadata bytes out of the tail (or reads them exactly
#      when the tail was too short)
#   4. Stores the raw metadata bytes; `metadata_parser` decodes them
#
# `ParquetFileReader[FS]` is parametric over the `FileSystem` it reads
# through. The caller names the file system: a local reader names `LocalFs`,
# an object-store reader names its own conformer, and this module names no
# storage vendor. An mmap-backed file system (`FS.IS_MMAP_BACKED`, LocalFs)
# maps the file once and lends out views of the mapping; any other reads each
# range through `fs.read_at`.
#
# Pointer discipline: no `UnsafePointer` in any public signature and no
# wildcard origin.
# =============================================================================

from std.memory import unsafe_memcpy
from std.memory import ArcPointer

from komira_fs.local_fs import LocalFs
from komira_fs.file_system import FileSystem
from komira_fs.footer_region import (
    FOOTER_SPECULATIVE_WINDOW,
    FooterRegion,
)
from komira_async.ops.waker_sink import NoopSink
from komira_buffer.owned_aligned_buffer import OwnedAlignedBuffer
from komira_buffer.shared_aligned_buffer import SharedAlignedBuffer
from komira_collections.slab import Slab
from komira_buffer.heap_region import HeapRegion
from komira_buffer.mmap_region import ADVICE_NOT_ISSUED, MmapRegion


# =============================================================================
# Constants
# =============================================================================

# PAR1 magic bytes: P=80, A=65, R=82, 1=49
comptime PARQUET_MAGIC_0 = UInt8(80)   # 'P'
comptime PARQUET_MAGIC_1 = UInt8(65)   # 'A'
comptime PARQUET_MAGIC_2 = UInt8(82)   # 'R'
comptime PARQUET_MAGIC_3 = UInt8(49)   # '1'

# Minimum Parquet file size: 4 (magic) + 0 (empty metadata) + 4 (length) + 4 (magic) = 12
comptime MIN_FILE_SIZE = 12


# =============================================================================
# ParquetFilePreamble — everything a reader open needs from the file's tail
# =============================================================================


struct ParquetFilePreamble(Movable, Deinitable):
    """The bytes + scalars a `ParquetFileReader` open needs from the tail of
    a parquet file, decoupled from FETCHING them.

    Splitting "fetch the preamble" (`read_parquet_preamble`) from "build a
    reader over it" (`ParquetFileReader.open_with_preamble`) lets a scan that
    opens N readers over one file fetch the footer once and hand a `share()`
    of it to every reader, instead of paying the tail reads N times (on an
    object store, each one a round trip).

    Fields:
        file_size:       Total file size in bytes.
        metadata_length: Length of the Thrift-encoded FileMetaData.
        metadata_bytes:  EXACTLY the `metadata_length` Thrift bytes (already
                         sliced out of the tail region). Arc-shared, so
                         handing it to N readers is N refcount bumps, not N
                         copies of the footer.

    Not `Copyable` (`SharedAlignedBuffer` is Movable-only by design); use
    `share()` for the zero-copy duplicate.
    """

    var file_size: Int
    var metadata_length: Int
    var metadata_bytes: SharedAlignedBuffer[HeapRegion]

    def __init__(
        out self,
        file_size: Int,
        metadata_length: Int,
        var metadata_bytes: SharedAlignedBuffer[HeapRegion],
    ):
        self.file_size = file_size
        self.metadata_length = metadata_length
        self.metadata_bytes = metadata_bytes^

    def share(self) -> Self:
        """Zero-copy duplicate — Arc-shares the metadata bytes (refcount
        bump), copies the two scalars. This is what the footer cache hands
        to each per-worker reader."""
        return Self(
            self.file_size,
            self.metadata_length,
            self.metadata_bytes.share(),
        )

    @always_inline
    def metadata_offset(self) -> Int:
        """File offset at which the Thrift metadata begins."""
        return self.file_size - 8 - self.metadata_length


def read_parquet_preamble[FS: FileSystem](
    mut fs: FS, path: String, window: Int = FOOTER_SPECULATIVE_WINDOW
) raises -> ParquetFilePreamble:
    """Fetch a parquet file's preamble through `fs` — normally in ONE
    round trip.

    This is the single definition of "how the footer gets off storage";
    every reader-open path composes it rather than re-deriving the trailer
    arithmetic. Body:

      1. `fs.read_footer(path, window)` — ONE speculative tail read
         returning the trailing `window` bytes AND the total size
         (an object store: a single suffix-range GET; local: one pread).
      2. Validate the trailing `PAR1` and decode the 4-byte LE
         `metadata_length` prefix from the last 8 bytes of the region.
      3. If the region already covers the metadata blob, slice it out with
         ZERO further I/O. Otherwise issue ONE follow-up
         `fs.read_footer(path, metadata_length + 8)` — an EXACT tail read of
         the now-known footer size.

    `window` is the speculative window. The default is the cold constant,
    which is right for a dataset nothing has been learned about; a caller
    that has learned a dataset's footer size (`FooterWindowHints.suggest`)
    passes it, so a large-footer dataset's sibling files hit on the first
    read.

    The miss branch is a second `read_footer`, not `open` + `read_at`: on
    LocalFs, `read_at` would map the whole file to copy out its footer, and
    on an object store the pair costs the same two round trips.

    The LEADING `PAR1` magic is deliberately NOT checked here: on an object
    store it costs an extra dependent round trip, and it validates nothing
    the trailing magic plus a successful Thrift parse does not already
    imply. `ParquetFileReader.validate_magic()` remains available for
    callers that explicitly want the both-ends check.
    """
    var region = fs.read_footer(path, window)
    var file_size = region.file_size
    if file_size < MIN_FILE_SIZE:
        raise Error(
            "parquet: file too small ("
            + String(file_size)
            + " bytes, need at least "
            + String(MIN_FILE_SIZE)
            + ")"
        )
    var region_len = len(region.bytes)
    if region_len < 8:
        raise Error(
            "parquet: footer region returned "
            + String(region_len)
            + " bytes, < 8-byte trailer minimum: "
            + path
        )
    var t = region_len - 8
    if (
        region.bytes[t + 4] != PARQUET_MAGIC_0
        or region.bytes[t + 5] != PARQUET_MAGIC_1
        or region.bytes[t + 6] != PARQUET_MAGIC_2
        or region.bytes[t + 7] != PARQUET_MAGIC_3
    ):
        raise Error("parquet: missing trailing PAR1 magic")

    var metadata_length = (
        Int(region.bytes[t + 0])
        | (Int(region.bytes[t + 1]) << 8)
        | (Int(region.bytes[t + 2]) << 16)
        | (Int(region.bytes[t + 3]) << 24)
    )
    if metadata_length <= 0 or metadata_length + 8 > file_size:
        raise Error(
            "parquet: invalid metadata length "
            + String(metadata_length)
            + " for file of size "
            + String(file_size)
        )

    var metadata_offset = file_size - 8 - metadata_length
    var metadata_buf = OwnedAlignedBuffer(max(metadata_length, 1))
    if region.covers(metadata_offset, metadata_length):
        # Speculation hit: the blob is already in hand. No I/O.
        var src_start = metadata_offset - region.offset
        var dst_view = metadata_buf.view_range_mut(0, metadata_length)
        # SAFETY: `src_start + metadata_length <= region_len` is exactly
        # what `region.covers` just established; `dst_view` was freshly
        # allocated at `metadata_length` bytes. Both spans are alive here.
        unsafe_memcpy(
            dest=dst_view._unsafe_ptr(),
            src=region.bytes.unsafe_ptr() + src_start,
            count=metadata_length,
        )
    else:
        # Speculation miss (footer larger than the window): ONE EXACT tail
        # read, sized to the footer we now know the length of. No `open`, no
        # whole-file mmap, no second guess. See the docstring.
        var exact = fs.read_footer(path, metadata_length + 8)
        var exact_len = len(exact.bytes)
        if exact.offset > metadata_offset or (
            exact.offset + exact_len < metadata_offset + metadata_length
        ):
            raise Error(
                "parquet: exact footer follow-up read did not cover the"
                " metadata blob (region ["
                + String(exact.offset)
                + ", "
                + String(exact.offset + exact_len)
                + ") vs blob ["
                + String(metadata_offset)
                + ", "
                + String(metadata_offset + metadata_length)
                + ")): "
                + path
            )
        var src_start = metadata_offset - exact.offset
        var dst_view = metadata_buf.view_range_mut(0, metadata_length)
        # SAFETY: the bounds check immediately above establishes
        # `src_start + metadata_length <= exact_len`; `dst_view` was freshly
        # allocated at `metadata_length` bytes. Both spans are alive here.
        unsafe_memcpy(
            dest=dst_view._unsafe_ptr(),
            src=exact.bytes.unsafe_ptr() + src_start,
            count=metadata_length,
        )
    metadata_buf.set_length(Int64(metadata_length))

    return ParquetFilePreamble(
        file_size,
        metadata_length,
        SharedAlignedBuffer.from_owned(metadata_buf^),
    )


# =============================================================================
# _ParquetFileReaderImpl[FS: FileSystem] — parametric body (private)
# =============================================================================


struct _ParquetFileReaderImpl[FS: FileSystem](Movable):
    """Private parametric body holding the real Parquet-reader state.

    Parametric over `FS: FileSystem` so the per-FS read paths (a view of
    the mapping for an mmap-backed FS; `fs.read_at` for any other) are
    chosen at compile time. The public `ParquetFileReader[FS]` holds one
    and delegates to it.

    Fields:
        file_path: Path / URI of the Parquet stream.
        file_size: Total size of the file in bytes.
        metadata_length: Length of the Thrift-encoded metadata.
        metadata_bytes: Raw Thrift metadata buffer.
        _fs: The FileSystem handle (owned). A non-mmap read opens a fresh
            per-call file handle through `self._fs.open(self.file_path)`,
            which the trait documents as cheap and lazy for every conformer.
        _mmap: Cached mmap-region (populated only when
            `FS.IS_MMAP_BACKED` resolved True at construction
            time). None for any other FS.

    Why no `_file: FS.File` field:
        The trait's `read_at(self, mut file: Self.File, ...)` requires a
        mutable file binding. Storing the handle here would make
        `read_bytes` take `mut self`, and every reader binding with it.
        Per-call reconstruction via `self._fs.open(self.file_path)` provides a
        fresh mut-binding instead.
    """

    var file_path: String
    var file_size: Int
    var metadata_length: Int
    var metadata_bytes: SharedAlignedBuffer[HeapRegion]
    var _fs: Self.FS
    var _mmap: Optional[ArcPointer[MmapRegion]]

    def __init__(
        out self,
        var file_path: String,
        file_size: Int,
        metadata_length: Int,
        var metadata_bytes: SharedAlignedBuffer[HeapRegion],
        var fs: Self.FS,
        var mmap: Optional[ArcPointer[MmapRegion]],
    ):
        self.file_path = file_path^
        self.file_size = file_size
        self.metadata_length = metadata_length
        self.metadata_bytes = metadata_bytes^
        self._fs = fs^
        self._mmap = mmap^

    @staticmethod
    def open_with_preamble(
        var fs: Self.FS,
        path: String,
        var preamble: ParquetFilePreamble,
        var adopted_mmap: Optional[ArcPointer[MmapRegion]] = None,
        map_whole_file: Bool = True,
    ) raises -> _ParquetFileReaderImpl[Self.FS]:
        """Build the Impl over an ALREADY-FETCHED preamble, and (for
        mmap-eligible FS conformers) eagerly populate the cached mmap region.

        `map_whole_file=False` builds a METADATA-ONLY Impl: real
        `file_size` / `metadata_length` / `metadata_bytes`, but NO mapping
        and no `mmap(2)`. It is threaded from
        `ParquetFileReader.open_metadata_only`; `read_bytes` on such an Impl
        raises rather than dereferencing the absent mapping.

        `adopted_mmap`, when `Some`, IS this Impl's mapping — no `mmap(2)` is
        issued. A caller that keeps one mapping per file for longer than one
        reader (a session cache) passes its share here, so the mapping
        outlives this reader and is neither re-mapped nor unmapped per query.

        `None` (the default) maps the file here and unmaps it when the last
        reader drops.

        This method performs no metadata I/O at all: the preamble was
        fetched by `read_parquet_preamble`, once per file.

        For `FS.IS_MMAP_BACKED == True` (LocalFs): eagerly opens an
        `MmapRegion` for the whole file and caches it as
        `Optional[ArcPointer[MmapRegion]]`; subsequent `read_bytes` calls
        borrow from it directly — no FS hop, no `mut self` cascade.

        For `FS.IS_MMAP_BACKED == False` (an object store): `_mmap`
        is None and every subsequent `read_bytes` goes through
        `fs.read_at`. No handle is opened here — `read_bytes` opens one per
        call (see the struct docstring's "Why no `_file` field").
        """
        var file_size = preamble.file_size
        var metadata_length = preamble.metadata_length
        # Arc-SHARE rather than partial-move the buffer out of `preamble`
        # (Mojo rejects destroying one field out of the middle of a value).
        # `share()` is a refcount bump on the same bytes — no copy.
        var metadata_bytes = preamble.metadata_bytes.share()

        comptime if Self.FS.IS_MMAP_BACKED:
            # Adopt the caller's mapping when one was handed in; otherwise
            # map the file here. Same bytes either way: `MAP_PRIVATE +
            # PROT_READ` over an immutable file is indistinguishable from a
            # second mapping of it.
            if adopted_mmap:
                return _ParquetFileReaderImpl[Self.FS](
                    path,
                    file_size,
                    metadata_length,
                    metadata_bytes^,
                    fs^,
                    adopted_mmap^,
                )
            if not map_whole_file:
                # Metadata-only. The caller reads the footer bytes it
                # already holds and never calls `read_bytes`.
                return _ParquetFileReaderImpl[Self.FS](
                    path,
                    file_size,
                    metadata_length,
                    metadata_bytes^,
                    fs^,
                    Optional[ArcPointer[MmapRegion]](None),
                )
            # No per-FS file handle needed for the mmap path —
            # `MmapRegion.open_readonly` opens its own fd internally.
            #
            # `advise_whole_file=False`: a Parquet scan reads only the
            # column chunks it projects, so a whole-file `MADV_WILLNEED`
            # would fault in the entire file to read a few columns of it.
            # `read_bytes` below advises each range it borrows instead.
            var mmap_region = MmapRegion.open_readonly(
                path, advise_whole_file=False
            )
            var mmap_arc = ArcPointer[MmapRegion](mmap_region^)
            return _ParquetFileReaderImpl[Self.FS](
                path,
                file_size,
                metadata_length,
                metadata_bytes^,
                fs^,
                Optional[ArcPointer[MmapRegion]](mmap_arc^),
            )
        else:
            return _ParquetFileReaderImpl[Self.FS](
                path,
                file_size,
                metadata_length,
                metadata_bytes^,
                fs^,
                Optional[ArcPointer[MmapRegion]](None),
            )

    @staticmethod
    def open(var fs: Self.FS, path: String) raises -> _ParquetFileReaderImpl[Self.FS]:
        """Fetch the preamble through `fs` and build the Impl over it — the
        composition `read_parquet_preamble` + `open_with_preamble` for
        callers with no cached preamble to hand in (single-shot opens).

        A scan that opens N readers over one file should fetch the preamble
        once and use `open_with_preamble` for each reader instead."""
        var preamble = read_parquet_preamble[Self.FS](fs, path)
        return Self.open_with_preamble(fs^, path, preamble^)

    def clone_sharing_mmap(self) raises -> _ParquetFileReaderImpl[Self.FS]:
        """Build a SECOND Impl over the SAME file that SHARES this one's
        `MmapRegion` — a refcount bump on the existing `ArcPointer`, NOT a
        second `mmap(2)` of the same bytes.

        A scan builds one reader per worker so each worker owns its own FS
        handle (on an object store, its own connection) and its own mutable
        decode state; none of that needs a per-worker mapping of a read-only
        file, and N mappings of one file cost N unmaps at teardown.

        What is SHARED (refcount bump, no bytes copied, no syscall):
          * `_mmap` — the `ArcPointer[MmapRegion]` (or `None` for a non-mmap
            FS and for footer-only placeholders, which clone as placeholders).
          * `metadata_bytes` — `.share()` of the same Thrift blob.
        What is FRESH per clone:
          * `_fs` — `self._fs.clone()`, so each clone keeps its own FS
            handle.

        No wildcard origin, no UnsafePointer crosses a module boundary.
        `ArcPointer`'s refcount is atomic.
        """
        var mmap_share: Optional[ArcPointer[MmapRegion]]
        if self._mmap:
            mmap_share = Optional[ArcPointer[MmapRegion]](
                ArcPointer[MmapRegion](copy=self._mmap.value())
            )
        else:
            mmap_share = Optional[ArcPointer[MmapRegion]](None)
        return _ParquetFileReaderImpl[Self.FS](
            String(self.file_path),
            self.file_size,
            self.metadata_length,
            self.metadata_bytes.share(),
            self._fs.clone(),
            mmap_share^,
        )

    def mmap_share_count(self) -> Int:
        """How many live handles share this Impl's mapping — the
        `ArcPointer[MmapRegion]` strong count, or 0 when there is no mapping
        (a non-mmap FS, footer-only placeholders).

        N readers built with `clone_sharing_mmap` all report N; N readers
        each opened separately each report 1.
        """
        if self._mmap:
            return Int(self._mmap.value().count())
        return 0

    def advise_prefetch(self, offset: Int, length: Int) -> Int:
        """Best-effort kernel readahead hint over `[offset, offset+length)`.

        For mmap-backed FS arms: `madvise(MADV_WILLNEED)` over exactly that
        range of the mapping. Returns 0 (issued, accepted), -1 (issued, the
        syscall failed) or `ADVICE_NOT_ISSUED` (nothing to advise — a
        metadata-only reader with no mapping, or an out-of-range request).

        For any other FS: a no-op returning 0 (range coalescing is the
        caller's business there).
        """
        comptime if Self.FS.IS_MMAP_BACKED:
            if not self._mmap:
                return ADVICE_NOT_ISSUED
            return self._mmap.value()[].advise_willneed_range(offset, length)
        else:
            _ = offset
            _ = length
            return 0

    def read_bytes(self, offset: Int, length: Int) raises -> SharedAlignedBuffer[HeapRegion]:
        """Read bytes at a specific file offset.

        For `FS.IS_MMAP_BACKED == True` (LocalFs): returns a NON-owning
        `SharedAlignedBuffer[HeapRegion]` that views the eagerly-cached
        mmap region. Zero-copy on warm page cache.

        For `FS.IS_MMAP_BACKED == False`: routes through
        `self._fs.read_at(file, offset, length)`, which returns an OWNING
        `SharedAlignedBuffer[HeapRegion]` holding the bytes read.
        """
        if (
            offset < 0
            or length < 0
            or offset > self.file_size
            or length > self.file_size - offset
        ):
            raise Error(
                "parquet: read out of bounds: offset="
                + String(offset)
                + " length="
                + String(length)
                + " file_size="
                + String(self.file_size)
            )

        if length == 0:
            # A buffer is born with its length equal to its capacity: set it
            # to 0, or an empty read returns one uninitialized byte.
            var empty = OwnedAlignedBuffer(1)
            empty.set_length(Int64(0))
            return SharedAlignedBuffer.from_owned(empty^)

        comptime if Self.FS.IS_MMAP_BACKED:
            # A metadata-only Impl (`open_metadata_only`) has no mapping on
            # purpose. Say so, instead of dereferencing the empty Optional —
            # that turns a caller mistake into a named error at the exact
            # call that made it.
            if not self._mmap:
                raise Error(
                    "parquet: read_bytes on a METADATA-ONLY reader (no mapping)"
                    " — build it with ParquetFileReader.open(path) if you need"
                    " to read data bytes: " + self.file_path
                )
            # Advise THIS range, rather than having advised the whole file at
            # open. The advice is a hint over a `MAP_PRIVATE + PROT_READ`
            # mapping and cannot change a byte (man 2 madvise); it changes
            # which pages the kernel is told to fetch. Pages already resident
            # cost a page-cache lookup and no I/O.
            _ = self._mmap.value()[].advise_willneed_range(offset, length)
            # `borrow_mmap_erased` returns a `SharedAlignedBuffer[HeapRegion]`
            # aliasing the mapped page-cache bytes directly; the type-erased
            # `ArcPointer[MmapRegion]` keepalive pins the mapping for as long
            # as the buffer lives.
            return SharedAlignedBuffer.borrow_mmap_erased(
                ArcPointer[MmapRegion](copy=self._mmap.value()),
                Int64(offset),
                Int64(length),
            )
        else:
            # Owning-buffer path. `read_at(self, mut file, ...)` takes a
            # mutable file binding; a fresh per-call handle from
            # `self._fs.open(self.file_path)` provides one (`FS.open` is
            # documented as cheap and lazy). The handle drops after the call.
            var file = self._fs.open(self.file_path)
            return self._fs.read_at(file, Int64(offset), Int64(length))

    def read_ranges_prefetched(
        self, ranges: List[Tuple[Int64, Int64]],
    ) raises -> Slab[SharedAlignedBuffer[HeapRegion]]:
        """Fan-out read of N `(offset, length)` byte ranges, returning one
        owning buffer per range in input order. Forwards to the FS's
        `read_ranges_prefetched`, which an object store implements by
        issuing all N ranged reads up front and draining their bodies
        together.

        For a non-mmap FS: callers branch on `FS.IS_MMAP_BACKED` before
        reaching here (an mmap-backed FS reads each column through
        `read_bytes`; its `read_ranges_prefetched` is a sequential
        fallback).
        """
        var file = self._fs.open(self.file_path)
        return self._fs.read_ranges_prefetched(file, ranges)

    def validate_magic(self) raises:
        """Verify PAR1 magic at start and end of file. Re-uses `read_bytes`
        so the per-FS arm branching stays in one place."""
        var header = self.read_bytes(0, 4)
        # The view ties the pointer's lifetime to the buffer it views.
        var header_view = header.view_ro()
        var header_ptr = header_view._unsafe_ptr()
        if (
            (header_ptr + 0)[] != PARQUET_MAGIC_0
            or (header_ptr + 1)[] != PARQUET_MAGIC_1
            or (header_ptr + 2)[] != PARQUET_MAGIC_2
            or (header_ptr + 3)[] != PARQUET_MAGIC_3
        ):
            raise Error("parquet: missing leading PAR1 magic")

        var trailer = self.read_bytes(self.file_size - 4, 4)
        var trailer_view = trailer.view_ro()
        var trailer_ptr = trailer_view._unsafe_ptr()
        if (
            (trailer_ptr + 0)[] != PARQUET_MAGIC_0
            or (trailer_ptr + 1)[] != PARQUET_MAGIC_1
            or (trailer_ptr + 2)[] != PARQUET_MAGIC_2
            or (trailer_ptr + 3)[] != PARQUET_MAGIC_3
        ):
            raise Error("parquet: missing trailing PAR1 magic")

    @always_inline
    def metadata_offset(self) -> Int:
        return self.file_size - 8 - self.metadata_length

    @always_inline
    def data_region_size(self) -> Int:
        return self.file_size - 4 - self.metadata_length - 8


# =============================================================================
# ParquetFileReader[FS] — public `[FS]`-parametric facade
# =============================================================================
# The facade holds `_ParquetFileReaderImpl[Self.FS]` directly. The FS type
# arrives from the caller as a parameter: `open(path)` returns a
# `ParquetFileReader[LocalFs[NoopSink]]`, and `open_with_fs[FS2](fs, path)`
# a reader over any other `FileSystem`.


struct ParquetFileReader[FS: FileSystem](Movable):
    """Public `[FS]`-parametric facade for the Parquet file reader.

    Holds `_ParquetFileReaderImpl[Self.FS]` directly; its public methods
    delegate straight to the Impl.

    Construction:
      * `open(path)` — `@staticmethod` returning `ParquetFileReader[LocalFs[NoopSink]]`.
        The entry point for a local file.
      * `open_with_fs[FS2](var fs, path)` — parametric ctor; returns
        `ParquetFileReader[FS2]`, a reader through any `FileSystem`.
      * `open_with_preamble[FS2](fs, path, preamble)` — over a preamble the
        caller already fetched (no metadata I/O).
      * `open_metadata_only(path)` and `open_footer_only[FS2](fs, path)` —
        readers that are never asked for data bytes.

    Public fields (read-only): file_path / file_size / metadata_length /
    metadata_bytes — snapshot at construction from the Impl. Sound because
    the Impl is immutable after construction.
    """

    var file_path: String
    var file_size: Int
    var metadata_length: Int
    var metadata_bytes: SharedAlignedBuffer[HeapRegion]
    var _impl: _ParquetFileReaderImpl[Self.FS]

    def __init__(
        out self,
        var file_path: String,
        file_size: Int,
        metadata_length: Int,
        var metadata_bytes: SharedAlignedBuffer[HeapRegion],
        var impl: _ParquetFileReaderImpl[Self.FS],
    ):
        self.file_path = file_path^
        self.file_size = file_size
        self.metadata_length = metadata_length
        self.metadata_bytes = metadata_bytes^
        self._impl = impl^

    @staticmethod
    def open(path: String) raises -> ParquetFileReader[LocalFs[NoopSink]]:
        """Open a local Parquet file. Callers write
        `ParquetFileReader[LocalFs[NoopSink]].open(path)`.
        """
        var fs = LocalFs[NoopSink].new()
        var preamble = read_parquet_preamble[LocalFs[NoopSink]](fs, path)
        return Self.open_with_preamble[LocalFs[NoopSink]](
            fs^, path, preamble^
        )

    @staticmethod
    def open_with_fs[
        FS2: FileSystem,
    ](var fs: FS2, path: String) raises -> ParquetFileReader[FS2]:
        """Fetch the preamble through `fs` and build the reader over it —
        the composition for callers with no cached preamble.

        Returns `ParquetFileReader[FS2]`; the Impl's `FS.IS_MMAP_BACKED`
        branch selects the mapped view (LocalFs) or `fs.read_at` (any
        other FS) read path.

        A scan that opens N readers over one file should use
        `open_with_preamble` with one fetched preamble instead.
        """
        var preamble = read_parquet_preamble[FS2](fs, path)
        return Self.open_with_preamble[FS2](fs^, path, preamble^)

    @staticmethod
    def open_with_preamble[
        FS2: FileSystem,
    ](
        var fs: FS2,
        path: String,
        var preamble: ParquetFilePreamble,
        var adopted_mmap: Optional[ArcPointer[MmapRegion]] = None,
        map_whole_file: Bool = True,
    ) raises -> ParquetFileReader[FS2]:
        """Build a reader over an ALREADY-FETCHED preamble — ZERO metadata
        I/O (a non-mmap FS issues no requests at all; the local arm only
        mmaps, and not even that when `adopted_mmap` supplies one).

        `adopted_mmap` threads a mapping the caller keeps straight through
        to the Impl; see `_ParquetFileReaderImpl.open_with_preamble`.

        The facade's `metadata_bytes` snapshot is an Arc `share()` of the
        preamble's buffer, not a memcpy — the Thrift blob exists once no
        matter how many readers reference it.
        """
        var facade_meta = preamble.metadata_bytes.share()
        var file_size = preamble.file_size
        var metadata_length = preamble.metadata_length
        var impl = _ParquetFileReaderImpl[FS2].open_with_preamble(
            fs^, path, preamble^, adopted_mmap^, map_whole_file
        )
        return ParquetFileReader[FS2](
            String(path),
            file_size,
            metadata_length,
            facade_meta^,
            impl^,
        )

    @staticmethod
    def open_metadata_only(
        path: String,
    ) raises -> ParquetFileReader[LocalFs[NoopSink]]:
        """`open(path)` for the callers that only ever read the FOOTER —
        same `file_size`, `metadata_length` and `metadata_bytes`, and NO
        whole-file `mmap(2)`.

        A caller that wants only the footer (a row count, a schema, the
        statistics) has no use for a mapping of the whole file, and creating
        and destroying one per call is pure cost; the footer bytes were
        already fetched by `read_parquet_preamble`.

        CONTRACT. The returned reader MUST NOT be decoded: `read_bytes` raises
        a named error rather than dereferencing the absent mapping. Callers who
        need bytes use `open(path)`. Distinct from `open_footer_only`, which
        also zeroes `file_size` / `metadata_length` / `metadata_bytes` — the
        footer IS what these callers came for.
        """
        var fs = LocalFs[NoopSink].new()
        var preamble = read_parquet_preamble[LocalFs[NoopSink]](fs, path)
        return Self.open_with_preamble[LocalFs[NoopSink]](
            fs^,
            path,
            preamble^,
            Optional[ArcPointer[MmapRegion]](None),
            map_whole_file=False,
        )

    @staticmethod
    def open_footer_only[
        FS2: FileSystem,
    ](var fs: FS2, path: String) raises -> ParquetFileReader[FS2]:
        """FOOTER-ONLY placeholder construction: build a reader that performs
        NO fd open, NO mmap, and carries an EMPTY metadata-bytes buffer
        (`file_size`/`metadata_length` are 0 sentinels — NEVER read).

        For files a scan will never decode (every row group outside the
        rows it reads), the caller needs only their parsed `FileMetaData`,
        supplied separately (from a footer cache). This reader is a
        placeholder for such a file and costs no I/O. Decoding a footer-only
        reader is a contract violation (there are no readable bytes).
        """
        var impl = _ParquetFileReaderImpl[FS2](
            String(path),
            0,  # file_size — never read (footer-only is never decoded)
            0,  # metadata_length — empty
            SharedAlignedBuffer.from_owned(OwnedAlignedBuffer(1)),
            fs^,
            Optional[ArcPointer[MmapRegion]](None),  # no eager mmap
        )
        return ParquetFileReader[FS2](
            String(path),
            0,
            0,
            SharedAlignedBuffer.from_owned(OwnedAlignedBuffer(1)),
            impl^,
        )

    def clone_sharing_mmap(self) raises -> ParquetFileReader[Self.FS]:
        """A second reader over the same file that SHARES this one's mapping
        instead of issuing a second `mmap(2)`. See
        `_ParquetFileReaderImpl.clone_sharing_mmap`.
        """
        return ParquetFileReader[Self.FS](
            String(self.file_path),
            self.file_size,
            self.metadata_length,
            self.metadata_bytes.share(),
            self._impl.clone_sharing_mmap(),
        )

    def mmap_share_count(self) -> Int:
        """How many live handles share this reader's mapping (0 = none). See
        the Impl docstring."""
        return self._impl.mmap_share_count()

    # ---- public methods — direct delegation into the Impl ----

    def advise_prefetch(self, offset: Int, length: Int) -> Int:
        """Best-effort kernel readahead hint. See Impl docstring."""
        return self._impl.advise_prefetch(offset, length)

    def read_bytes(self, offset: Int, length: Int) raises -> SharedAlignedBuffer[HeapRegion]:
        """Read bytes at a specific file offset. See Impl docstring."""
        return self._impl.read_bytes(offset, length)

    def read_ranges_prefetched(
        self, ranges: List[Tuple[Int64, Int64]],
    ) raises -> Slab[SharedAlignedBuffer[HeapRegion]]:
        """Fan-out read of N byte ranges (a non-mmap FS). See Impl
        docstring."""
        return self._impl.read_ranges_prefetched(ranges)

    def validate_magic(self) raises:
        """Verify PAR1 magic at start and end of file."""
        self._impl.validate_magic()

    @always_inline
    def metadata_offset(self) -> Int:
        """Return the file offset where the Thrift metadata begins.

        Computed from the facade's own `file_size` + `metadata_length`
        fields (no Impl hop needed).
        """
        return self.file_size - 8 - self.metadata_length

    @always_inline
    def data_region_size(self) -> Int:
        """Return the size of the data region (everything between the
        leading magic and the metadata)."""
        return self.file_size - 4 - self.metadata_length - 8
