# =============================================================================
# komira_engine_runtime/spill/shuffle_stream_combine.mojo
#   `stream_combine_segment` and `stream_combine_segment_spilling`: write a
#   shuffle producer's R partition slices into one `.seg` object through a
#   streaming write, optionally staging an oversized partition in spill storage
#   under a byte budget.
# =============================================================================
#
# # What it does
#
# The one-shot `SegWriter` (komira_shuffle.segment) builds the whole `.seg`
# object in one `List[UInt8]` and issues one put. The combine here streams
# instead:
#
#     open_write(seg_path)                              once
#     for p in 0..R:
#         slice = source.slice_bytes(p)
#         write the slice in <= _WRITE_CHUNK_BYTES spans
#         record the dense slot (running_offset, len, row_count)
#     write_at(encode_seg_trailer(slots))               the dense trailer
#     close_write(seg_file)                             commit
#
# The `.seg` it produces for a set of slices is byte-for-byte what
# `SegWriter`/`write_segment` produces for the same slices: the same partition
# bodies in order, the same dense slots (a zero-length partition records
# `(running_offset, 0, row_count)` and leaves `running_offset` unchanged) and
# the same `encode_seg_trailer` trailer. `SegReader` reads it unchanged.
#
# # The byte budget
#
# `stream_combine_segment_spilling` takes a budget `T` (`spill_threshold`, in
# bytes). A partition of at most `T` bytes is staged in the per-partition
# `ShuffleCombineBuffer` and written out; it never touches spill storage. A
# partition of more than `T` bytes is cut into chunks of at most `T` bytes, each
# written to the `SpillStorage` (`write_chunk`) as it is cut; at the partition
# boundary the chunks are read back one at a time (`read_chunk`), streamed into
# the segment and released (`release_chunk`). Spilling only stages bytes: the
# segment is identical to the unspilled one.
#
# The combine counts the bytes it stages itself in `CombineResult.peak_staged_bytes`:
# the combine buffer's live length after each append, the length of each chunk
# at the moment it is cut, and the length of each chunk at the moment it is read
# back, whichever is largest. With a positive `T` that count never exceeds `T`.
# It bounds the combine's own staging, not the process's memory. Outside it:
# the slice the `PartitionSliceSource` returns (a whole partition, live until
# the combine has cut it into chunks or appended it to the combine buffer, so
# for a short while it coexists with the chunk or the buffer copy), the dense
# trailer (24 * R + 16 bytes), and whatever the `FileSystem` buffers inside
# `write_at`. Spilling therefore lowers the memory the combine holds across a
# partition's write, not the peak while the source's slice is live.
# With `spill_threshold <= 0` nothing is spilled and a partition is staged
# whole, so the count is the largest partition.
#
# # Failure
#
# Any raise (the source, the spill storage, the file system) is reported to the
# caller with its message. Before it is re-raised, the chunks written so far are
# released and the in-flight write is aborted (`FileSystem.abort_write`), each
# best effort: a cleanup failure is dropped so that it cannot replace the error
# that caused it.
#
# # Pointer discipline
#
# No `UnsafePointer` appears in this file. Bytes flow as owned `List[UInt8]` and
# as `Span[UInt8, _]` into `write_at`.
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


# Each slice is streamed into the file system's write in spans of at most this
# many bytes, so a conformer that copies a span into its own buffer before it
# peels parts holds about one part rather than a second copy of the partition.
# The byte stream is the same however the spans are cut.
comptime _WRITE_CHUNK_BYTES: Int = 8 * 1024 * 1024

# `spill_threshold <= 0` means no spill. `stream_combine_segment` passes it.
comptime _SPILL_DISABLED: Int64 = Int64(-1)


# =============================================================================
# PartitionSliceSource: the R partition slices, one partition at a time
# =============================================================================


trait PartitionSliceSource(Movable, Deinitable):
    """The R partition byte slices of one producer, consumed in partition order,
    one partition at a time.

    `partition_count()` is R, the length of the dense index: exactly R slices,
    including zero-length ones for partitions the producer wrote no rows for.
    `slice_bytes(p)` is called exactly once per partition, in order, so a source
    may drain and free partition `p` there."""

    def partition_count(self) -> Int:
        """R, the dense-index length."""
        ...

    def slice_bytes(mut self, p: Int) raises -> List[UInt8]:
        """Partition `p`'s encoded bytes (owned; empty for a zero-length
        partition)."""
        ...

    def slice_row_count(self, p: Int) -> Int64:
        """Partition `p`'s row count (0 for an empty partition)."""
        ...


struct ListPartitionSource(PartitionSliceSource, Movable, Deinitable):
    """A `PartitionSliceSource` over R already-materialized slices and their R
    row counts. It holds all R slices and `slice_bytes` copies, so it suits
    tests and small inputs, not a producer with large partitions; the combine
    still asks for the slices one at a time.

    Fields:
      _slices:     R partition byte slices (including zero-length ones).
      _row_counts: R per-partition row counts.
    """

    var _slices: List[List[UInt8]]
    var _row_counts: List[Int64]

    def __init__(
        out self,
        var slices: List[List[UInt8]],
        var row_counts: List[Int64],
    ) raises:
        """Raises if the two lists differ in length."""
        if len(slices) != len(row_counts):
            raise Error(
                "ListPartitionSource: "
                + String(len(slices))
                + " slices but "
                + String(len(row_counts))
                + " row counts"
            )
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
        # A copy: the source keeps its slices for any later inspection.
        return self._slices[p].copy()

    def slice_row_count(self, p: Int) -> Int64:
        return self._row_counts[p]


# =============================================================================
# CombineResult
# =============================================================================


@fieldwise_init
struct CombineResult(Movable, Deinitable):
    """What a combine returns.

    Fields:
      slots:             the dense R-entry index, one `PartitionSlot` per
                         partition (including zero-length ones).
      high_water:        `ShuffleCombineBuffer.high_water()` of the combine's
                         buffer: the largest slice it held at once (0 when every
                         partition was staged in spill storage).
      peak_staged_bytes: the largest number of bytes the combine itself held at
                         once, counted at the steps listed in the file header.
                         At most `spill_threshold` when that is positive.
      chunks_spilled:    the number of `write_chunk` calls made (0 when no
                         partition exceeded the budget).
    """

    var slots: List[PartitionSlot]
    var high_water: Int
    var peak_staged_bytes: Int
    var chunks_spilled: Int


# =============================================================================
# Helpers
# =============================================================================


def _write_span_chunked[
    FS: FileSystem
](fs: FS, mut seg_file: FS.WriteFile, span: Span[UInt8, _]) raises:
    """Stream `span` into `seg_file` in spans of at most `_WRITE_CHUNK_BYTES`.
    The byte stream is the same as one whole-span `write_at`. Empty input
    writes nothing."""
    var n = len(span)
    var off = 0
    while off < n:
        var take = _WRITE_CHUNK_BYTES
        if take > n - off:
            take = n - off
        _ = fs.write_at(seg_file, span[off : off + take])
        off += take


def _span_to_sab(span: Span[UInt8, _]) -> SharedAlignedBuffer[HeapRegion]:
    """Copy `span` into a new `SharedAlignedBuffer`, the form
    `SpillStorage.write_chunk` takes."""
    var n = len(span)
    var oab = OwnedAlignedBuffer(capacity=n)
    if n > 0:
        oab.copy_from_span_at(0, span)
        oab.set_length(Int64(n))
    return SharedAlignedBuffer[HeapRegion].from_owned(oab^)


def _note(mut peak: Int, staged: Int):
    if staged > peak:
        peak = staged


# =============================================================================
# The combine body
# =============================================================================


def _combine_body[
    FS: FileSystem, Src: PartitionSliceSource, S: SpillStorage
](
    fs: FS,
    mut seg_file: FS.WriteFile,
    mut buf: ShuffleCombineBuffer,
    mut source: Src,
    mut storage: S,
    spill_threshold: Int64,
    mut live_chunks: List[ChunkId],
    mut released: Int,
    mut peak_staged: Int,
    mut chunks_spilled: Int,
) raises -> List[PartitionSlot]:
    """Write every partition and the dense trailer into `seg_file`. Does not
    close it. `live_chunks` holds the ids written to `storage` for the
    partition being combined; the first `released` of them have had their
    release attempted. A caller that sees a raise releases the rest."""
    var r = source.partition_count()
    var spill_enabled = spill_threshold > 0
    var slots = List[PartitionSlot]()
    var running_offset = Int64(0)

    for p in range(r):
        var row_count = source.slice_row_count(p)
        var pbytes = source.slice_bytes(p)
        var plen = len(pbytes)

        if spill_enabled and Int64(plen) > spill_threshold:
            # Oversized: cut it into chunks of at most T bytes and stage each
            # in spill storage, then stream them back in order.
            var cap = Int(spill_threshold)
            var fed = 0
            while fed < plen:
                var step = cap
                if step > plen - fed:
                    step = plen - fed
                _note(peak_staged, step)
                var cid = storage.write_chunk(
                    _span_to_sab(Span(pbytes)[fed : fed + step])
                )
                live_chunks.append(cid)
                chunks_spilled += 1
                fed += step
            _ = pbytes^
            # `released` counts the ids at the front of `live_chunks` whose
            # release has been attempted, so the failure cleanup skips them
            # whether or not that attempt raised.
            for i in range(len(live_chunks)):
                var cid = live_chunks[i]
                var chunk = storage.read_chunk(cid)
                _note(peak_staged, Int(chunk.length()))
                var view = chunk.as_view()
                _write_span_chunked(fs, seg_file, view.into_span())
                _ = chunk^
                released = i + 1
                storage.release_chunk(cid)
            live_chunks.clear()
            released = 0
        else:
            # At most T bytes (or no budget): stage the slice in the combine
            # buffer, hand it out, write it.
            buf.append_bytes(Span(pbytes))
            _ = pbytes^
            _note(peak_staged, buf.len())
            var slice = buf.take()
            _write_span_chunked(fs, seg_file, Span(slice))
            _ = slice^

        slots.append(PartitionSlot(running_offset, Int64(plen), row_count))
        running_offset += Int64(plen)

    # The dense trailer is never empty (24 * R + 16 bytes), so the write stream
    # always carries at least one byte even when every partition is empty.
    var trailer = encode_seg_trailer(slots)
    _ = fs.write_at(seg_file, Span(trailer))
    return slots^


def _combine[
    FS: FileSystem, Src: PartitionSliceSource, S: SpillStorage
](
    fs: FS,
    seg_path: String,
    var source: Src,
    mut storage: S,
    spill_threshold: Int64,
) raises -> CombineResult:
    var seg_file = fs.open_write(seg_path, WriteMode.create_truncate())
    var buf = ShuffleCombineBuffer()
    var live_chunks = List[ChunkId]()
    var released = 0
    var peak_staged = 0
    var chunks_spilled = 0
    var slots = List[PartitionSlot]()
    var failed = False
    var message = String("")
    try:
        slots = _combine_body(
            fs,
            seg_file,
            buf,
            source,
            storage,
            spill_threshold,
            live_chunks,
            released,
            peak_staged,
            chunks_spilled,
        )
    except e:
        failed = True
        message = String(e)
    if failed:
        # Best effort: release what was spilled and abort the partial write. A
        # cleanup failure must not replace the error that caused it.
        for i in range(released, len(live_chunks)):
            try:
                storage.release_chunk(live_chunks[i])
            except:
                pass
        try:
            fs.abort_write(seg_file^)
        except:
            pass
        raise Error(message)
    fs.close_write(seg_file^)
    var hw = buf.high_water()
    return CombineResult(slots^, hw, peak_staged, chunks_spilled)


# =============================================================================
# Entry points
# =============================================================================


struct _NoSpillStorage(SpillStorage, Movable, Deinitable):
    """The storage `stream_combine_segment` passes. With the budget disabled the
    combine never calls it; if it is ever called it raises."""

    def __init__(out self):
        pass

    def write_chunk(
        mut self, var bytes: SharedAlignedBuffer[HeapRegion]
    ) raises -> ChunkId:
        _ = bytes^
        raise Error("_NoSpillStorage.write_chunk: spilling is disabled")

    def read_chunk(
        self, chunk_id: ChunkId
    ) raises -> SharedAlignedBuffer[HeapRegion]:
        _ = chunk_id
        raise Error("_NoSpillStorage.read_chunk: spilling is disabled")

    def release_chunk(mut self, chunk_id: ChunkId) raises:
        _ = chunk_id

    def nbytes_in_use(self) -> Int64:
        return Int64(0)

    def sync(mut self) raises:
        pass


def stream_combine_segment[
    FS: FileSystem, Src: PartitionSliceSource
](
    fs: FS,
    seg_path: String,
    var source: Src,
) raises -> CombineResult:
    """Combine the producer's R partition slices into the `.seg` object at
    `seg_path` with a streaming write, staging each partition whole in the
    combine buffer. Nothing is spilled.

    The `.seg` is byte-identical to the one `SegWriter` builds for the same
    slices.

    Raises: whatever the source or the file system raises, after the partial
    write has been aborted (best effort).
    """
    var none = _NoSpillStorage()
    return _combine(fs, seg_path, source^, none, _SPILL_DISABLED)


def stream_combine_segment_spilling[
    FS: FileSystem, Src: PartitionSliceSource, S: SpillStorage
](
    fs: FS,
    seg_path: String,
    var source: Src,
    mut storage: S,
    spill_threshold: Int64,
) raises -> CombineResult:
    """Like `stream_combine_segment`, with the byte budget `spill_threshold`
    described in the file header: a partition above it is staged in `storage`
    in chunks of at most `spill_threshold` bytes and streamed back, so
    `CombineResult.peak_staged_bytes` is at most `spill_threshold`. A value
    `<= 0` disables spilling.

    The `.seg` is byte-identical to the unspilled one. Every chunk written is
    released before a successful return; after a raise the chunks written so far
    are released best effort.

    Raises: whatever the source, the spill storage or the file system raises,
    with its message.
    """
    return _combine(fs, seg_path, source^, storage, spill_threshold)
