# =============================================================================
# komira_engine_runtime/spill/shuffle_stream_combine.mojo
#   `stream_combine_segment` — the producer STREAM-COMBINE (distributed-shuffle
#   Phase B3 + B4). Writes a producer's R partition slices into ONE `.seg`
#   object via a STREAMING multipart write whose peak transient RAM is bounded
#   to ~the current partition's encode-buffer slice + ~one in-flight multipart
#   part — NOT the whole producer output.
#
#   B4 (the incremental-spill route — `stream_combine_segment_spilling`) makes
#   even a SINGLE partition that ALONE exceeds RAM bounded: as a partition's
#   bytes accumulate in the B2 buffer, when `high_water()` crosses a RAM budget
#   threshold `T`, the buffer's current bytes are FLUSHED to the chunk-keyed
#   spill storage (`SpillStorage.write_chunk(bytes) -> ChunkId`) and the buffer
#   is reset; at partition finalize the spilled chunks are streamed back in
#   order (`read_chunk(id)` -> `write_at` -> `release_chunk(id)`) followed by
#   the residual buffer bytes. Peak RAM is then ~T + one read-back chunk + one
#   in-flight part REGARDLESS of partition size. The common case (partition < T)
#   NEVER spills and is BYTE-IDENTICAL to the no-spill B3 path (and to
#   SegWriter) — spill is intermediate staging that `write_at` coalesces back
#   into the same FIFO byte stream. See "B4 incremental spill" below.
# =============================================================================
#
# The hot combine buffer must be spillable: stream-combine, not
# concat-in-RAM.
#
# # What this is (vs Phase A's SegWriter)
#
# Phase A's `SegWriter` (komira_shuffle.segment) builds the WHOLE
# `.seg` object — all R partition bodies concatenated PLUS the dense trailer —
# in ONE `List[UInt8]` in RAM, then issues ONE `put`. That is correct for tiny
# single-process objects but its peak RAM is the FULL object: under power-law
# skew a 2 GB hot partition would materialize entirely in RAM (§7.1, the riskiest
# single piece of code).
#
# `stream_combine_segment` is the Phase-B streaming form:
#
#     open_write(seg_path)  ONCE  (the multipart upload)
#     for p in 0..R:
#         buf.append_bytes(partition p's encoded bytes)   # the B2 combine buffer
#         var slice = buf.take()                          # finalize + free p
#         write slice in <= _WRITE_CHUNK_BYTES spans      # stream into multipart
#         record dense slot (running_offset, len, row_count)
#         running_offset += len                           # (unchanged if len==0)
#     fs.write_at(seg_file, encode_seg_trailer(slots))    # dense R-entry trailer
#     close_write(seg_file)                               # commit the multipart
#
# # Bounded-RAM scope (honest)
#
# Peak transient RAM ≈ the CURRENT partition's encode-buffer slice (the B2
# buffer; freed at each partition boundary by `take()`) + ~one in-flight
# multipart part. The slice is streamed into the FS in `<= _WRITE_CHUNK_BYTES`
# (8 MiB) spans rather than one whole-partition `write_at` so the FS's coalesce
# buffer holds ~one part, NOT a full second copy of the partition: under real S3,
# `S3Fs.write_at` does `_coalesce.extend(data)` over the WHOLE span BEFORE it
# peels parts (`s3_fs.mojo`), so a single `write_at(whole_partition)` for a
# partition larger than the part target would make a needless ~2× transient copy
# of that partition. Chunking bounds the coalesce copy to ~one part. The S3
# K-deep in-flight PUT window adds a further K×part term (the FS conformer
# back-pressures at ≥5 MiB parts). Byte-identity is UNCHANGED by chunking:
# `write_at` is a cursor-advancing FIFO coalesce stream, so N sequential chunked
# writes produce the SAME byte stream as one whole-slice write (the test's
# byte-identity-vs-SegWriter guard verifies this).
#
# What B3 does NOT bound on its own: a SINGLE partition whose encode buffer alone
# exceeds RAM. That is the B4 spill case (route the `take()` drain to the
# operator spill path); B3 bounds the per-partition transient under the common
# case where each partition's slice fits. The B2
# `ShuffleCombineBuffer.high_water()` instrument exposes ONLY the B2 buffer's
# peak live bytes — it does NOT account for the S3 `_coalesce` copy or the K×part
# in-flight PUT window, so the B5 bounded-RAM GATE must measure real RSS or add
# those terms (it cannot read the true peak off `high_water()` alone).
#
# # The LOAD-BEARING invariant: BYTE-IDENTICAL to SegWriter
#
# The `.seg` object `stream_combine_segment` produces for a given set of R
# partition slices is BYTE-FOR-BYTE IDENTICAL to what Phase A's
# `SegWriter`/`write_segment` produces for the SAME slices. Both write:
#   [ partition_0 bytes ][ partition_1 bytes ] ... [ partition_{R-1} bytes ]
#   [ DENSE TRAILER: EXACTLY R × (offset, len, row_count) ][ FOOTER ]
# in partition order, with the SAME dense-slot accounting (a zero-length
# partition records `(running_offset, 0, 0)` with running_offset UNCHANGED — the
# DENSE-INDEX INVARIANT, the design) and the SAME `encode_seg_trailer` codec
# (REUSED from komira_shuffle — NOT reimplemented). That byte-identity is
# the contract that lets `read_shuffle_partition`/`SegReader` consume a
# stream-combined `.seg` UNCHANGED. The B3 test asserts it directly.
#
# # Layering: this lives ABOVE the shuffle codec
#
# `komira_engine_runtime` CAN import `komira_shuffle` (the `.seg` codec)
# AND `komira_fs` (the `FileSystem` multipart write API); `komira_shuffle`
# can NOT import the engine. So the
# stream-combine — which needs BOTH the codec and the FileSystem write surface —
# is the right layer. It USES the B2 buffer
# (komira_engine_runtime.spill.shuffle_combine_buffer.ShuffleCombineBuffer) as
# the per-partition encode accumulator and REUSES the shuffle dense-trailer
# codec (`encode_seg_trailer`, `PartitionSlot`).
#
# SegWriter is NOT deleted: it remains the LocalFs/tiny-object one-shot fallback
# (Phase A); stream-combine is the multipart/streaming path. Bodies are
# disjoint-key writes, no CAS (unchanged from Phase A — the `.seg` body is a
# plain object PUT).
#
# # B4 incremental spill — a single oversized partition never sits whole in RAM
#
# §2.1 step 2: a single hot partition that ALONE exceeds RAM routes through the
# existing operator spill path. B4 wires this as the chunk-keyed spill reframe
# (NOT a Partitioner — the spill substrate has none): the spill path is
# `SpillStorage.write_chunk(bytes) -> ChunkId` / `read_chunk(id)` /
# `release_chunk(id)` (`FileSystemSpillStorage[FS]`). The wiring:
#
#     for p in 0..R:
#         chunk_ids = []
#         for each encoded sub-table chunk of partition p:
#             buf.append_bytes(chunk)
#             if buf.high_water() crosses T:            # over-threshold flush
#                 chunk_ids.append(storage.write_chunk(buf.take() -> SAB))
#         # finalize p: restream spilled chunks IN ORDER, then the residual
#         for cid in chunk_ids:
#             write_slice_chunked(read_chunk(cid)); release_chunk(cid)   # free
#         write_slice_chunked(buf.take())               # residual buffer bytes
#         record dense slot (running_offset, total_partition_bytes, row_count)
#
# Peak RAM is bounded to ~T (the in-RAM buffer cap) + one read-back chunk
# (≤ T) + one in-flight multipart part, REGARDLESS of partition size. The
# common case (a partition whose accumulated bytes never cross T) NEVER spills:
# zero `write_chunk` calls, zero behavior change, BYTE-IDENTICAL to the B3
# no-spill path (spilling only STAGES the bytes — `write_at` re-coalesces the
# restreamed chunks + the residual into the SAME contiguous FIFO byte stream).
#
# This is a CLEAN extension of `_stream_combine_loop` (the single shared site
# B3 created): the no-spill B3 entry points (`stream_combine_segment` /
# `_instrumented`) drive the SAME loop with a no-op spill storage and a disabled
# threshold; the B4 entry points (`stream_combine_segment_spilling` /
# `_instrumented`) supply a real `SpillStorage` + a finite `T`. So the
# plain + instrumented + spilling paths CANNOT diverge.
#
# # The input abstraction (for B6)
#
# The R partition byte-slices are passed as an abstraction (`PartitionSliceSource`)
# rather than a concrete `List[List[UInt8]]` so the later PFA-drain wiring (B6)
# can feed the radix sub-tables WITHOUT first concatenating them into a
# materialized list. The Phase-B test supplies a `ListPartitionSource` (an
# in-RAM `List[List[UInt8]]` adapter); B6 supplies a sub-table-draining source.
# The combine driver only ever asks the source for partition `p`'s bytes + row
# count one partition at a time, in order — so a streaming source never holds
# more than one partition's bytes resident.
#
# # Pointer discipline
#
# ZERO UnsafePointer anywhere in this file. Bytes flow as owned `List[UInt8]`
# (from the source + the B2 `take()`) and as `Span[UInt8, _]` into `write_at`
# (the FileSystem trait's safe write surface). The B2 buffer's owning field is
# `OwnedPointer[List[UInt8]]` (concrete origin, gap6/bug#60-safe). NO wildcard
# origins, NO owning UnsafePointer, NO unsafe_from_address, NO partial-move.
# =============================================================================


from komira_fs.file_system import FileSystem, WriteMode
from komira_buffer.owned_aligned_buffer import OwnedAlignedBuffer
from komira_buffer.shared_aligned_buffer import SharedAlignedBuffer
from komira_buffer.heap_region import HeapRegion

from komira_shuffle.entry import PartitionSlot
from komira_shuffle.segment import encode_seg_trailer

from komira_engine_runtime.spill.shuffle_combine_buffer import (
    ShuffleCombineBuffer,
)
from komira_engine_runtime.spill.spill_storage import ChunkId, SpillStorage


# The per-write chunk size: stream each partition slice into the FS multipart
# write in `<= _WRITE_CHUNK_BYTES` spans rather than one whole-slice `write_at`.
# 8 MiB matches the S3 part-flush target (`s3_fs.mojo:_PART_TARGET_BYTES`, which
# is module-private to the S3 conformer and not exposed on the `FileSystem`
# trait, so we mirror its value here as a local constant). Chunking bounds the
# S3 conformer's `_coalesce` buffer to ~one part instead of a full second copy of
# the partition. Byte-identity is unaffected: `write_at` is a cursor-advancing
# FIFO coalesce stream (the trailer + every partition concatenate contiguously in
# stream order regardless of how the spans are sliced).
comptime _WRITE_CHUNK_BYTES: Int = 8 * 1024 * 1024


# The B4 spill threshold sentinel: a `spill_threshold <= 0` DISABLES the
# incremental-spill route entirely (the B3 no-spill behavior — the buffer
# accumulates the whole partition slice in RAM before write_at, never calling
# `write_chunk`). This is the default for the no-spill B3 entry points so they
# stay byte-identical to Phase A. A finite positive `T` engages the B4 route.
comptime _SPILL_DISABLED: Int64 = Int64(-1)


# The default B4 RAM budget threshold when a caller opts into the spilling route
# without naming one: 256 MiB of accumulated partition-slice bytes before the
# B2 buffer flushes to spill. Chosen well above the typical per-partition encode
# size (so the common case never spills) but far below a multi-GB hot partition
# (so a power-law skew partition is bounded). Callers tune `T` to their RAM
# budget; the B5 gate drives a SMALL `T` so the spill path is exercised cheaply.
comptime _DEFAULT_SPILL_THRESHOLD_BYTES: Int64 = Int64(256 * 1024 * 1024)


# =============================================================================
# PartitionSliceSource — the input abstraction (so B6 can feed sub-tables)
# =============================================================================
#
# The combine driver consumes the R partition slices through this trait, ONE
# partition at a time, in partition order (0..R-1). Keeping the input behind a
# trait means the later PFA-drain wiring (B6) can supply a source that drains a
# radix sub-table on demand (never materializing all R slices at once), while the
# Phase-B test supplies the simple in-RAM `ListPartitionSource`.
#
# Contract:
#   * `partition_count()` returns R (the dense-index length — EXACTLY R slices,
#     including zero-length ones for partitions this producer wrote no rows for).
#   * `slice_bytes(p)` returns partition p's encoded bytes (owned; possibly
#     empty for a zero-length partition).
#   * `slice_row_count(p)` returns partition p's row count (0 for an empty
#     partition).
# The driver calls `slice_bytes(p)` EXACTLY once per partition, in order, so a
# streaming source can drain-and-free each partition as it is asked for.
# =============================================================================


trait PartitionSliceSource(Movable, Deinitable):
    """The R partition byte-slices the producer combine streams into one `.seg`.

    Consumed ONE partition at a time, in partition order — a streaming
    conformer (B6) drains a radix sub-table on demand and never holds more than
    one partition's bytes resident."""

    def partition_count(self) -> Int:
        """R — the dense-index length (EXACTLY R slices, incl. zero-length)."""
        ...

    def slice_bytes(mut self, p: Int) raises -> List[UInt8]:
        """Partition `p`'s encoded bytes (owned; empty for a zero-length
        partition). Called EXACTLY once per partition, in order — a streaming
        source may drain-and-free `p` here."""
        ...

    def slice_row_count(self, p: Int) -> Int64:
        """Partition `p`'s row count (0 for an empty partition)."""
        ...


# =============================================================================
# ListPartitionSource — the in-RAM adapter (the Phase-B test + tiny producers)
# =============================================================================


struct ListPartitionSource(PartitionSliceSource, Movable, Deinitable):
    """A `PartitionSliceSource` over an already-materialized `List[List[UInt8]]`
    of R partition slices + a parallel `List[Int64]` of row counts.

    This is the simple in-RAM source the Phase-B test drives (and a fallback for
    a tiny producer whose R slices already fit in RAM). It does NOT stream — it
    holds all R slices — but the combine driver still asks for them one at a
    time, so the driver's per-partition transient (the B2 buffer + one multipart
    part) is bounded regardless. B6 supplies the genuinely-streaming source.

    Fields:
      var _slices: List[List[UInt8]]  — R partition byte-slices (dense, incl.
                                        zero-length).
      var _row_counts: List[Int64]     — R per-partition row counts (dense).
    """

    var _slices: List[List[UInt8]]
    var _row_counts: List[Int64]

    def __init__(
        out self,
        var slices: List[List[UInt8]],
        var row_counts: List[Int64],
    ):
        self._slices = slices^
        self._row_counts = row_counts^

    def partition_count(self) -> Int:
        return len(self._slices)

    def slice_bytes(mut self, p: Int) raises -> List[UInt8]:
        if p < 0 or p >= len(self._slices):
            raise Error(
                "ListPartitionSource.slice_bytes: partition "
                + String(p)
                + " out of range (R="
                + String(len(self._slices))
                + ")"
            )
        # Return a copy (the in-RAM source keeps its slices for any re-query /
        # test inspection; a streaming source would move-and-free here).
        return self._slices[p].copy()

    def slice_row_count(self, p: Int) -> Int64:
        return self._row_counts[p]


# =============================================================================
# _write_slice_chunked — stream one finalized partition slice into the multipart
# write in <= _WRITE_CHUNK_BYTES spans (FIX 1: bound the S3 _coalesce copy)
# =============================================================================
#
# The S3 conformer's `write_at` does `_coalesce.extend(data)` over the ENTIRE
# span before peeling parts, so a single `write_at(whole_partition)` for a
# partition larger than the part target makes a needless ~2× transient copy of
# the partition. Writing the slice in `<= _WRITE_CHUNK_BYTES` (8 MiB, == the S3
# part target) spans bounds `_coalesce` to ~one part. Byte-identity is preserved:
# `write_at` is a cursor-advancing FIFO coalesce stream, so N sequential chunked
# writes produce the SAME byte stream as one whole-slice write (the conformer
# concatenates the spans contiguously in stream order; LocalFs likewise appends
# to its single fd cursor). Empty input is a no-op (the loop never runs).


def _write_slice_chunked[
    FS: FileSystem
](fs: FS, mut seg_file: FS.WriteFile, slice: List[UInt8]) raises:
    """Stream `slice` into `seg_file` in `<= _WRITE_CHUNK_BYTES` spans (FIX 1).
    Byte-identical to a single whole-slice `write_at` — `write_at` coalesces all
    writes into one FIFO byte stream that the multipart commit reassembles
    contiguously."""
    var n = len(slice)
    var off = 0
    while off < n:
        var take = _WRITE_CHUNK_BYTES
        if take > n - off:
            take = n - off
        _ = fs.write_at(seg_file, Span(slice)[off : off + take])
        off += take


# =============================================================================
# Spill bridge helpers (B4) — the impedance match between the B2 buffer's owned
# `List[UInt8]` and the chunk-keyed `SpillStorage` (which moves bytes as
# `SharedAlignedBuffer[HeapRegion]`). This is the chunk-keyed REFRAME (NOT a
# Partitioner): `bytes -> write_chunk -> ChunkId`, later `read_chunk -> bytes`.
# =============================================================================


def _list_to_sab(var bytes: List[UInt8]) -> SharedAlignedBuffer[HeapRegion]:
    """Bridge an owned `List[UInt8]` (the B2 `take()` output) to the
    `SharedAlignedBuffer[HeapRegion]` the chunk-keyed `SpillStorage.write_chunk`
    consumes. Bulk memcpy via `OwnedAlignedBuffer.copy_from_bytes_list`, then
    promote with `from_owned` (the same idiom the spill tests use). Empty input
    yields an empty buffer (length 0)."""
    var n = len(bytes)
    var oab = OwnedAlignedBuffer(capacity=n)
    if n > 0:
        oab.copy_from_bytes_list(bytes)
    return SharedAlignedBuffer[HeapRegion].from_owned(oab^)


def _write_sab_chunked[
    FS: FileSystem
](
    fs: FS,
    mut seg_file: FS.WriteFile,
    imm sab: SharedAlignedBuffer[HeapRegion],
) raises:
    """Stream a spilled chunk's bytes (read back via `read_chunk`) into the
    multipart write in `<= _WRITE_CHUNK_BYTES` spans — the SAB analogue of
    `_write_slice_chunked`. The chunk's bytes are a `Span[UInt8, _]` over the
    SAB's `as_view()` (the Arc pins the storage across the synchronous
    `write_at`). Byte-identity is preserved: `write_at` is a cursor-advancing
    FIFO coalesce stream, so the restreamed chunk concatenates contiguously in
    stream order, exactly where the in-RAM slice would have gone."""
    # SAFETY: `sab.as_view()` returns a ByteView tied to the local `sab` (the
    # SharedAlignedBuffer's Arc pins the storage); `into_span()` yields a Span
    # over the same origin, alive across the synchronous chunked `write_at`. No
    # pointer escapes this function — the Span is consumed inside the FS
    # conformer.
    var view = sab.as_view()
    var span = view.into_span()
    var n = len(span)
    var off = 0
    while off < n:
        var take = _WRITE_CHUNK_BYTES
        if take > n - off:
            take = n - off
        _ = fs.write_at(seg_file, span[off : off + take])
        off += take


# =============================================================================
# _NoSpillStorage — the inert SpillStorage the B3 no-spill path drives so the
# ONE shared `_stream_combine_loop` body is generic over a single storage type
# without forcing a real spill backend on the common case. Its methods are
# NEVER called when the threshold is disabled (the loop guards every spill call
# on `_spill_enabled`), so it allocates nothing and writes nothing.
# =============================================================================


struct _NoSpillStorage(SpillStorage, Movable, Deinitable):
    """An inert `SpillStorage` for the B3 no-spill path. The combine loop only
    reaches `write_chunk`/`read_chunk`/`release_chunk` when the spill threshold
    is a finite positive `T`; the B3 entry points drive this with the threshold
    DISABLED, so every method here is unreachable and may raise/return-empty.
    Holds NO state (no heap, no wildcard field) — gap6-trivially-safe."""

    def __init__(out self):
        pass

    def write_chunk(
        mut self, var bytes: SharedAlignedBuffer[HeapRegion]
    ) raises -> ChunkId:
        _ = bytes^
        raise Error(
            "_NoSpillStorage.write_chunk: unreachable — the B3 no-spill path"
            " never spills (threshold disabled)"
        )

    def read_chunk(
        self, chunk_id: ChunkId
    ) raises -> SharedAlignedBuffer[HeapRegion]:
        _ = chunk_id
        raise Error("_NoSpillStorage.read_chunk: unreachable")

    def release_chunk(mut self, chunk_id: ChunkId) raises:
        _ = chunk_id

    def nbytes_in_use(self) -> Int64:
        return Int64(0)

    def sync(mut self) raises:
        pass


# =============================================================================
# _stream_combine_loop — the SHARED per-partition combine + trailer + close
# (FIX 3: ONE body all entry points — plain B3, instrumented B3, and the B4
# spilling forms — delegate to, so the spill drain cannot diverge between paths)
# =============================================================================


def _stream_combine_loop[
    FS: FileSystem, Src: PartitionSliceSource, S: SpillStorage
](
    fs: FS,
    var seg_file: FS.WriteFile,
    mut buf: ShuffleCombineBuffer,
    var source: Src,
    mut storage: S,
    spill_threshold: Int64,
) raises -> List[PartitionSlot]:
    """Drive the R partition slices through `buf` into the multipart write at
    `seg_file`, append the dense R-entry trailer, and commit (`close_write`).
    Returns the dense R-entry index. `buf` is passed `mut` (not owned) so the
    instrumented entrypoint can read `buf.high_water()` AFTER this returns — the
    high-water is the per-partition encode-buffer peak, bounded to ~one partition
    slice (B3) or to ~`spill_threshold` (B4) because `take()` frees the slice at
    each partition boundary AND the B4 route flushes to spill when the buffer
    crosses `spill_threshold`.

    B4 wiring (`spill_threshold > 0`): as a partition's bytes accumulate, when
    `buf.high_water()` crosses `spill_threshold` the buffer's current bytes are
    flushed to `storage.write_chunk(...) -> ChunkId` and the buffer reset; at
    partition finalize the spilled chunks are restreamed in order
    (`read_chunk(id)` -> chunked `write_at` -> `release_chunk(id)`) followed by
    the residual buffer bytes. The `.seg` is BYTE-IDENTICAL to the no-spill path
    (spill only STAGES bytes; `write_at` re-coalesces them into the same FIFO
    stream). `spill_threshold <= 0` disables spill (the B3 path — `storage` is
    never touched)."""
    var r = source.partition_count()
    var spill_enabled = spill_threshold > 0

    var slots = List[PartitionSlot]()
    var running_offset = Int64(0)

    for p in range(r):
        var row_count = source.slice_row_count(p)
        # Encode partition p's bytes THROUGH the B2 combine buffer (the
        # append_bytes accumulation point). A streaming source drains-and-frees
        # partition p here; the in-RAM source copies it.
        var pbytes = source.slice_bytes(p)
        var plen = Int64(len(pbytes))

        # ---- B4 over-threshold flush: accumulate the partition's bytes into
        # the B2 buffer, and whenever the LIVE byte count (not the monotonic
        # high-water) would cross `spill_threshold`, flush the accumulated bytes
        # to the chunk-keyed spill storage and reset the buffer. This bounds the
        # in-RAM transient to ~`spill_threshold` even for a SINGLE partition
        # whose bytes alone exceed RAM. The flushed ChunkIds are restreamed in
        # order at the partition boundary below.
        #
        # We feed the partition bytes in `<= spill_threshold`-sized sub-spans so
        # the buffer's live count never exceeds `spill_threshold` between flushes
        # (a single append of the whole partition would momentarily hold it all;
        # sub-span feeding keeps the in-RAM cap faithful). The common case
        # (plen <= spill_threshold, or spill disabled) is ONE append + ZERO
        # flushes — byte-identical to B3.
        var spilled_ids = List[ChunkId]()
        if spill_enabled and plen > spill_threshold:
            var fed = 0
            var total = len(pbytes)
            while fed < total:
                var room = Int(spill_threshold) - buf.len()
                if room <= 0:
                    # Buffer at the cap — flush to spill, reset, continue.
                    spilled_ids.append(
                        storage.write_chunk(_list_to_sab(buf.take()))
                    )
                    room = Int(spill_threshold)
                var step = room
                if step > total - fed:
                    step = total - fed
                buf.append_bytes(Span(pbytes)[fed : fed + step])
                fed += step
        else:
            # Common case (and spill-disabled): one append of the whole slice.
            buf.append_bytes(Span(pbytes))

        # Finalize the partition slice (the B2 take(): hand the residual bytes
        # out + free the buffer's live slice for partition p+1).
        var slice = buf.take()

        # Record the DENSE slot for partition p. An EMPTY partition
        # records (running_offset, 0, 0) with running_offset UNCHANGED — the
        # dense-index invariant, identical to SegWriter.append_partition. The
        # length is the WHOLE partition (`plen`, == spilled chunks + residual),
        # so the dense slot is independent of how the bytes were staged.
        slots.append(PartitionSlot(running_offset, plen, row_count))

        # ---- Restream any spilled chunks IN ORDER, then the residual buffer
        # bytes. read_chunk(id) -> chunked write_at -> release_chunk(id) (free,
        # no leak). The concatenation of [chunk_0][chunk_1]...[residual] is
        # EXACTLY the partition's bytes in original order, so write_at's FIFO
        # coalesce produces the byte-identical body the no-spill path would.
        for i in range(len(spilled_ids)):
            var cid = spilled_ids[i]
            var chunk = storage.read_chunk(cid)
            _write_sab_chunked(fs, seg_file, chunk)
            _ = chunk^
            storage.release_chunk(cid)
        # Stream the residual slice into the multipart upload in
        # <= _WRITE_CHUNK_BYTES spans (FIX 1: bound the S3 _coalesce transient
        # to ~one part). An EMPTY partition (no spill, no residual) writes ZERO
        # body bytes — running_offset does NOT advance, matching SegWriter.
        if len(slice) > 0:
            _write_slice_chunked(fs, seg_file, slice)
        if plen > 0:
            running_offset += plen
        # Keep the taken slice alive across the write; buf is already reset by
        # take() for the next partition.
        _ = slice^
        _ = spilled_ids^

    # ---- Append the dense R-entry trailer + footer (REUSE the objectstore
    # codec — encode_seg_trailer builds the EXACT SegWriter trailer+footer bytes;
    # this file does NOT reimplement the `.seg` format). One bounded buffer (24*R
    # + 16 bytes), written via one final write_at into the multipart stream.
    #
    # INVARIANT: the dense trailer is ALWAYS non-empty (24*R + 16 bytes, R >= 1),
    # so this final write_at ALWAYS feeds at least 24*R + 16 bytes into the FS
    # coalesce stream. That guarantees S3's `close_write` issues >= 1 part (the
    # trailing remainder, issued with no minimum-size floor) even for an all-empty
    # producer where every partition is zero-length — without it, S3's
    # `close_write` raises "no parts uploaded" (s3_fs.mojo). LocalFs has no such
    # >=1-part requirement, so this corner is not exercised by the LocalFs-only
    # test suite — flag for cloud-path coverage.
    var trailer = encode_seg_trailer(slots)
    _ = fs.write_at(seg_file, Span(trailer))

    # ---- Commit the multipart upload (LocalFs: flush + close the fd; S3Fs:
    # issue the final sub-5 MiB part, drain in-flight PUTs, complete the
    # multipart upload — durable on PUT-ack).
    fs.close_write(seg_file^)

    return slots^


# =============================================================================
# stream_combine_segment — the Phase B3 producer stream-combine
# =============================================================================


def stream_combine_segment[
    FS: FileSystem, Src: PartitionSliceSource
](
    fs: FS,
    seg_path: String,
    var source: Src,
) raises -> List[PartitionSlot]:
    """STREAM-COMBINE a producer's R partition slices into the `.seg` object at
    `seg_path` via a STREAMING multipart write. Returns
    the dense R-entry index (`PartitionSlot` per partition, incl. zero-length).

    The produced `.seg` is BYTE-FOR-BYTE IDENTICAL to what Phase A's
    `SegWriter`/`write_segment` produces for the same R slices (the load-bearing
    contract — `read_shuffle_partition`/`SegReader` consume it UNCHANGED).

    Peak transient RAM ≈ the CURRENT partition's encode-buffer slice (freed at
    each partition boundary by the B2 `take()`) + ~one in-flight multipart part,
    NOT the whole producer output. The slice is written in `<= _WRITE_CHUNK_BYTES`
    (8 MiB) spans so the S3 conformer's `_coalesce` buffer holds ~one part instead
    of a full second copy of the partition. The S3 K-deep in-flight PUT window
    adds a further K×part term. NOTE: a SINGLE partition whose encode buffer alone
    exceeds RAM is the B4 spill case — NOT bounded by B3 alone. The buffer's
    `high_water()` instrument observes ONLY the B2 buffer's live bytes (bounded to
    ~one partition slice); it does NOT include the S3 `_coalesce` copy or the
    K×part window, so the B5 gate must measure real RSS / add those terms (see
    `stream_combine_segment_instrumented`).

    Args:
        fs:        The `FileSystem` whose multipart write surface (`open_write`/
                   `write_at`/`close_write`) the combine streams into. LocalFs
                   for the single-process test; S3Fs for real multi-node.
        seg_path:  The `.seg` object key / path to write (the caller resolves it
                   to the producer's `{producer_id}.seg`).
        source:    The R partition byte-slices (consumed one partition at a time,
                   in order — see `PartitionSliceSource`).

    Returns:
        The dense R-entry index — the producer threads these into its `_entries`
        `ShuffleEntry` after the body is durable (Phase A parity).

    Raises:
        On the `FileSystem` write surface failing (open/write/close) or the
        source raising on `slice_bytes`. On a mid-stream raise the caller's
        error path should `abort_write` the in-flight upload (the FS trait's
        error-path seam) — `stream_combine_segment` does not swallow the error.
    """
    # ---- Open the multipart upload ONCE. CREATE_TRUNCATE: the `.seg` body is a
    # disjoint-key write (no CAS — the design "the bodies are plain disjoint-key
    # PUTs"). For S3Fs `mode` is informational (multipart is always create-or-
    # overwrite); for LocalFs it create-or-truncates the file.
    var seg_file = fs.open_write(seg_path, WriteMode.create_truncate())

    # ---- The per-partition encode buffer (B2). ONE buffer reused across all R
    # partitions; `take()`/`reset()` frees the slice at each partition boundary
    # so its high-water stays bounded to ~one partition slice.
    var buf = ShuffleCombineBuffer()

    # Delegate to the SHARED combine loop (FIX 3 — one body, no plain/instrumented
    # divergence). It owns `seg_file`, drains `source` through `buf`, writes the
    # dense trailer, and commits the multipart upload. The B3 path drives the
    # loop with the inert `_NoSpillStorage` + the spill threshold DISABLED, so
    # the spill route is never reached and the output is byte-identical to A.
    var no_spill = _NoSpillStorage()
    return _stream_combine_loop(
        fs, seg_file^, buf, source^, no_spill, _SPILL_DISABLED
    )


# =============================================================================
# stream_combine_segment_instrumented — combine + return the buffer high-water
# =============================================================================
#
# The bounded-RAM B3 guarantee is observable through the B2
# `ShuffleCombineBuffer.high_water()`: the per-partition encode buffer's peak
# resident bytes stay bounded to ~one partition slice (the LARGEST single
# partition), NOT the R×B sum. The plain `stream_combine_segment` keeps the
# buffer module-private; this instrumented variant returns the dense index AND
# the buffer's high-water so the B3 test can assert the bound. Production callers
# use the plain form; the instrumented form exists for the bounded-RAM gate.
# =============================================================================


@fieldwise_init
struct CombineResult(Movable, Deinitable):
    """The result of an instrumented stream-combine: the dense index + the B2
    combine-buffer high-water mark (the bounded-RAM instrument).

    Fields:
      var slots: List[PartitionSlot]  — the dense R-entry index.
      var high_water: Int              — the B2 combine-buffer peak resident
                                        bytes (bounded to ~one partition slice;
                                        the B5 gate / B3 test reads this)."""

    var slots: List[PartitionSlot]
    var high_water: Int


def stream_combine_segment_instrumented[
    FS: FileSystem, Src: PartitionSliceSource
](
    fs: FS,
    seg_path: String,
    var source: Src,
) raises -> CombineResult:
    """Same as `stream_combine_segment` but ALSO returns the B2 combine-buffer
    high-water mark — the bounded-RAM instrument. The
    high-water stays bounded to ~one partition slice (the largest single
    partition), NOT the R×B sum, because `take()` frees the slice at each
    partition boundary. The B3 test asserts that bound.

    CAVEAT (FIX 1): `high_water` observes ONLY the B2 buffer's live bytes. It
    does NOT include the S3 conformer's `_coalesce` copy (bounded to ~one part by
    the chunked write) or the K×part in-flight PUT window — so the B5 gate cannot
    derive the true process peak from `high_water` alone; it must measure real
    RSS or add those FS-side terms."""
    var seg_file = fs.open_write(seg_path, WriteMode.create_truncate())
    var buf = ShuffleCombineBuffer()

    # Delegate to the SHARED combine loop (FIX 3 — identical body to the plain
    # path; `buf` is passed mut so its high_water() survives the call below).
    # B3 no-spill: inert storage + threshold disabled.
    var no_spill = _NoSpillStorage()
    var slots = _stream_combine_loop(
        fs, seg_file^, buf, source^, no_spill, _SPILL_DISABLED
    )

    # The high-water is read AFTER the shared loop returns but BEFORE buf drops
    # (it is the per-partition encode buffer peak — bounded to ~one partition
    # slice, not the R×B sum).
    var hw = buf.high_water()
    _ = buf^

    return CombineResult(slots^, hw)


# =============================================================================
# stream_combine_segment_spilling — the Phase B4 producer combine (bounded even
# for a SINGLE partition larger than RAM)
# =============================================================================
#
# B4. Identical to `stream_combine_segment` EXCEPT it
# threads a real chunk-keyed `SpillStorage` + a finite RAM budget threshold `T`
# through the SAME shared `_stream_combine_loop`. When a partition's accumulating
# bytes cross `T`, the B2 buffer is flushed to `storage.write_chunk(...)` and
# reset; at partition finalize the spilled chunks are restreamed in order and
# released. Peak RAM is bounded to ~`T` + one read-back chunk + one in-flight
# part REGARDLESS of partition size — the §7.1 multi-GB hot-partition case.
#
# The produced `.seg` is BYTE-IDENTICAL to `stream_combine_segment` (the
# no-spill B3 path) and to SegWriter for the same input: spill is intermediate
# staging; `write_at` re-coalesces the restreamed chunks + the residual into the
# same contiguous FIFO byte stream. A partition < `T` never spills (zero
# `write_chunk` calls) — identical to B3.
# =============================================================================


def stream_combine_segment_spilling[
    FS: FileSystem, Src: PartitionSliceSource, S: SpillStorage
](
    fs: FS,
    seg_path: String,
    var source: Src,
    mut storage: S,
    spill_threshold: Int64 = _DEFAULT_SPILL_THRESHOLD_BYTES,
) raises -> List[PartitionSlot]:
    """STREAM-COMBINE a producer's R partition slices into the `.seg` at
    `seg_path` WITH an incremental-spill route (B4) so a single partition that
    ALONE exceeds RAM never sits whole in memory. Returns the dense R-entry
    index.

    The produced `.seg` is BYTE-FOR-BYTE IDENTICAL to `stream_combine_segment`
    (the no-spill B3 path) and to Phase A's SegWriter for the SAME R slices — the
    load-bearing contract. Spill is intermediate staging only.

    Peak transient RAM ≈ `spill_threshold` (the in-RAM buffer cap) + one
    read-back chunk (≤ `spill_threshold`) + one in-flight multipart part,
    REGARDLESS of partition size. A partition whose accumulated bytes never cross
    `spill_threshold` NEVER spills (zero `write_chunk` calls).

    Args:
        fs:              The `FileSystem` the combine streams the `.seg` into.
        seg_path:        The `.seg` object key / path to write.
        source:          The R partition byte-slices (consumed one at a time).
        storage:         The chunk-keyed `SpillStorage` the over-threshold flush
                         drains to (`write_chunk`/`read_chunk`/`release_chunk`).
                         Typically `FileSystemSpillStorage[FS]`. Passed `mut`.
        spill_threshold: The RAM budget `T` in bytes; the buffer flushes to spill
                         when its accumulating bytes would cross `T`. Defaults to
                         `_DEFAULT_SPILL_THRESHOLD_BYTES` (256 MiB). `<= 0`
                         disables spill (degenerates to the B3 path).

    Returns:
        The dense R-entry index (Phase A parity).
    """
    var seg_file = fs.open_write(seg_path, WriteMode.create_truncate())
    var buf = ShuffleCombineBuffer()
    return _stream_combine_loop(
        fs, seg_file^, buf, source^, storage, spill_threshold
    )


def stream_combine_segment_spilling_instrumented[
    FS: FileSystem, Src: PartitionSliceSource, S: SpillStorage
](
    fs: FS,
    seg_path: String,
    var source: Src,
    mut storage: S,
    spill_threshold: Int64 = _DEFAULT_SPILL_THRESHOLD_BYTES,
) raises -> CombineResult:
    """Same as `stream_combine_segment_spilling` but ALSO returns the B2
    combine-buffer high-water mark — the bounded-RAM instrument the B5 gate
    reads. Under the B4 route the high-water is BOUNDED to ~`spill_threshold`
    (NOT the partition size), because the buffer flushes to spill at the
    threshold; the B5 gate asserts that bound.

    CAVEAT (same as the B3 instrumented form): `high_water` observes ONLY the B2
    buffer's live bytes. It does NOT include the FS-side `_coalesce` copy
    (bounded to ~one part by the chunked write), the K×part in-flight PUT window,
    or the one read-back chunk the restream holds — so the B5 gate measures the
    BUFFER bound (which B4 makes faithful, capped at `spill_threshold`), not the
    true process RSS."""
    var seg_file = fs.open_write(seg_path, WriteMode.create_truncate())
    var buf = ShuffleCombineBuffer()
    var slots = _stream_combine_loop(
        fs, seg_file^, buf, source^, storage, spill_threshold
    )
    var hw = buf.high_water()
    _ = buf^
    return CombineResult(slots^, hw)
