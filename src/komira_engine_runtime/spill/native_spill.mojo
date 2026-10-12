# =============================================================================
# native_spill.mojo — thin Native spill writer/reader over THSPILL2 / THSPLC.
# =============================================================================
#
# The codecs (`thspill2.mojo` THSPILL2 row, `thsplc.mojo` THSPLC column) and the
# `SpillStorage` substrate (`filesystem_spill_storage.mojo` /
# `local_disk.mojo`) are DONE. This file is the thin layer the LIVE spill
# consumers call: it takes a `RecordBatch` (column grain) or a row body, runs
# the codec, and writes/reads through a `SpillStorage`-backed file.
#
# # Two grains
#
#   * `NativeColumnSpillWriter` / `NativeColumnSpillReader` — RecordBatch (SoA)
#     via THSPLC. Used by `sort_external._spill_current_run` (external-sort run
#     spill) and the run-merge read side. Each spilled run is one THSPLC chunk
#     per batch on a per-run `LocalDiskSpillStorage`.
#
#   * `NativeRowSpillWriter` / `NativeRowSpillReader` — opaque row body via
#     THSPILL2. Used where the operator already owns a fixed-stride row image
#     (the hash-agg partition `row_data`). The body bytes are byte-identical to
#     the in-memory row image; restore is a `decode_zerocopy` view + cast.
#
# # Why a writer/reader pair (not just the raw codec)
#
# The codec produces/consumes a single `SharedAlignedBuffer[HeapRegion]` and the
# storage moves opaque bytes. Consumers want a batch-stream shape ("write N
# batches to one run, read them back in order"). This file owns that
# multi-chunk-per-run bookkeeping (`Slab[ChunkId]`) so the consumers stay
# small.
#
# # Encapsulation rule
#
# NO `UnsafePointer` on any public surface. Bytes flow via
# `SharedAlignedBuffer[HeapRegion]` (inside the codec) and `RecordBatch` /
# `Schema` at the public boundary. The storage owns all FFI / file I/O. No
# wildcard origins on any field.
# =============================================================================

from komira_arrow.record_batch import RecordBatch
from komira_arrow.schema import Schema
from komira_buffer.shared_aligned_buffer import SharedAlignedBuffer
from komira_collections.slab import Slab
from komira_buffer.byte_view import ByteView
from komira_buffer.heap_region import HeapRegion

from komira_engine_runtime.spill.local_disk import LocalDiskSpillStorage
from komira_engine_runtime.spill.spill_storage import ChunkId
from komira_engine_runtime.spill.thsplc import THSPLCEncoder, THSPLCDecoder
from komira_engine_runtime.spill.thspill2 import (
    THSpill2Encoder,
    THSpill2Decoder,
    Spillable,
)


# =============================================================================
# NativeColumnSpillWriter — RecordBatch -> THSPLC -> SpillStorage.
# =============================================================================


struct NativeColumnSpillWriter(Movable):
    """Writes RecordBatches to a native THSPLC-backed spill run.

    Replaces the Arrow-IPC `SpillWriter` for the columnar (RecordBatch) grain.
    Each `write_batch` THSPLC-encodes the batch into one chunk on an owned
    `LocalDiskSpillStorage` rooted at a unique per-run directory.

    Lifecycle:
      1. `var w = NativeColumnSpillWriter.create(spill_dir, counter)`
      2. `w.write_batch(batch)` (repeat per output-sized chunk)
      3. `w.close()` (sync durability barrier)

    The `NativeColumnSpillReader` opens the SAME storage root and replays the
    chunks in write order.

    Fields:
        _storage:   The owned per-run LocalDiskSpillStorage (one dir).
        _chunk_ids: ChunkId per written batch, in write order.
        _root:      The storage root dir (echoed for the reader to open).
    """

    var _storage: LocalDiskSpillStorage
    var _chunk_ids: Slab[ChunkId]
    var _root: String

    @staticmethod
    def create(
        var spill_dir: String, counter: Int
    ) raises -> NativeColumnSpillWriter:
        """Create a writer over a unique per-run storage root.

        The root is `${spill_dir}/thsplc_run_${counter}` — one directory per
        run, holding one chunk file per written batch. `LocalDiskSpillStorage`
        self-mkdirs the root.
        """
        var root = spill_dir + "/thsplc_run_" + String(counter)
        var storage = LocalDiskSpillStorage.with_unlimited(root)
        return NativeColumnSpillWriter(
            _storage=storage^,
            _chunk_ids=Slab[ChunkId](),
            _root=root,
        )

    def __init__(
        out self,
        var _storage: LocalDiskSpillStorage,
        var _chunk_ids: Slab[ChunkId],
        var _root: String,
    ):
        self._storage = _storage^
        self._chunk_ids = _chunk_ids^
        self._root = _root^

    def write_batch(mut self, var batch: RecordBatch) raises:
        """THSPLC-encode `batch` and append it as one chunk.

        The encoded bytes are byte-identical to the in-memory column buffers
        (no AoS<->SoA transpose, no IPC framing). `batch` is consumed.
        """
        var bytes = THSPLCEncoder.encode(batch^)
        var cid = self._storage.write_chunk(bytes^)
        self._chunk_ids.append(cid)

    def num_batches(self) -> Int:
        """Number of batches written so far."""
        return len(self._chunk_ids)

    def root(self) -> String:
        """The storage root dir — hand to `NativeColumnSpillReader.open`."""
        return self._root

    def close(mut self) raises:
        """Durability barrier. LocalFs flushes per chunk at write time; this
        is the explicit sync the spill contract requires before the operator
        frees its in-memory state.
        """
        self._storage.sync()

    def cleanup(mut self) raises:
        """Release every chunk file + rmdir the run root."""
        self._storage.cleanup()


# =============================================================================
# NativeColumnSpillReader — SpillStorage -> THSPLC -> RecordBatch.
# =============================================================================


struct NativeColumnSpillReader(Movable):
    """Reads RecordBatches back from a native THSPLC-backed spill run.

    Replaces the Arrow-IPC `SpillReader` for the columnar grain. Opens the
    storage root the writer used and replays chunks 1..N in write order
    (chunk ids are monotonic from 1 — `FileSystemSpillStorage._next_chunk_id`
    starts at 1).

    The caller supplies its expected `Schema` per `read_batch` (the operator
    knows its output shape — THSPLC restore needs it for the 0-copy column
    rebuild + fingerprint check). The sort path captures the schema and
    rebuilds it via `_rebuild_schema()`.

    Restore path: `decode_copy` (the honest, storage-independent baseline). The
    sort merge holds many runs' batches alive simultaneously and then deletes
    the spill files, so a 0-copy restore (which would pin the storage) is not
    the right default here — `decode_copy` produces fully-independent batches.

    Fields:
        _storage:     The owned per-run LocalDiskSpillStorage, re-opened.
        _num_chunks:  Count of chunks (batches) in the run.
    """

    var _storage: LocalDiskSpillStorage
    var _num_chunks: Int

    @staticmethod
    def open(
        var root: String, num_batches: Int
    ) raises -> NativeColumnSpillReader:
        """Re-open the storage root the writer created.

        `num_batches` is the count the writer reported via `num_batches()`;
        chunk ids are `1..num_batches` inclusive. Each chunk is re-registered
        by stat-ing its on-disk file (the fresh storage instance has no
        ChunkId map of its own — see `reopen_chunk`).
        """
        # with_unlimited self-mkdirs (the dir already exists from the writer).
        var storage = LocalDiskSpillStorage.with_unlimited(root)
        for i in range(num_batches):
            storage.reopen_chunk(ChunkId(UInt64(i + 1)))
        return NativeColumnSpillReader(
            _storage=storage^,
            _num_chunks=num_batches,
        )

    def __init__(
        out self,
        var _storage: LocalDiskSpillStorage,
        _num_chunks: Int,
    ):
        self._storage = _storage^
        self._num_chunks = _num_chunks

    def count_batches(self) -> Int:
        """Number of batches in the run."""
        return self._num_chunks

    def read_batch(
        mut self, index: Int, var schema: Schema
    ) raises -> RecordBatch:
        """Read + THSPLC-decode the `index`-th batch into a RecordBatch.

        `index` is 0-based; the underlying ChunkId is `index + 1` (the storage
        mints monotonic ids from 1). The restored batch is fully independent
        of the storage (decode_copy).

        Args:
            index:  Zero-based batch index in write order.
            schema: The caller's expected output schema. Consumed.
        """
        if index < 0 or index >= self._num_chunks:
            raise Error(
                "NativeColumnSpillReader.read_batch: index "
                + String(index)
                + " out of range [0, "
                + String(self._num_chunks)
                + ")"
            )
        # Chunk ids are minted monotonically from 1; the `open` ctor already
        # re-registered each via `reopen_chunk`, so `read_chunk` finds the
        # chunk and `read_at`s its exact span.
        var bytes = self._storage.read_chunk(ChunkId(UInt64(index + 1)))
        return THSPLCDecoder.decode_copy(bytes^, schema^)

    def cleanup(mut self) raises:
        """Release every chunk file + rmdir the run root.

        `open` already re-registered every chunk, so `cleanup` (which walks
        the live-chunk set) unlinks each file and rmdir's the root.
        """
        self._storage.cleanup()


# =============================================================================
# Shared-storage helpers — write/read THSPLC chunks into a CALLER-OWNED storage.
# =============================================================================
#
# PERF: the owned-storage writer/reader above mint ONE storage (one directory)
# PER spill run; on a multi-run external sort the per-run directory setup cost
# more than the THSPLC codec. The shared-storage helpers below let a multi-run
# operator (ExternalSorter) construct ONE storage for the WHOLE sort (one
# mkdir) and append every run's batches as chunks into it — no per-run
# directory, no per-run mkdir, no reopen-stat. The operator records the
# `(first_chunk_id, n_batches)` span per run and reads each back by id from the
# SAME live storage (the ChunkId -> length map is already populated, so no
# `reopen_chunk` stat is needed).
# =============================================================================


def native_column_write_chunk(
    mut storage: LocalDiskSpillStorage, var batch: RecordBatch
) raises -> ChunkId:
    """THSPLC-encode `batch` and append it as one chunk on `storage`.

    Returns the minted ChunkId. The bytes are byte-identical to the in-memory
    column buffers (no transpose, no IPC framing). `batch` is consumed.
    """
    var bytes = THSPLCEncoder.encode(batch^)
    return storage.write_chunk(bytes^)


def native_column_read_chunk(
    imm storage: LocalDiskSpillStorage,
    chunk_id: ChunkId,
    var schema: Schema,
) raises -> RecordBatch:
    """Read + THSPLC-decode the chunk `chunk_id` from `storage` into a
    RecordBatch (decode_copy — storage-independent restore). `schema` is the
    caller's expected output shape (THSPLC restore reattaches it)."""
    var bytes = storage.read_chunk(chunk_id)
    return THSPLCDecoder.decode_copy(bytes^, schema^)


# =============================================================================
# NativeRowBlock — minimal `Spillable` row body for the THSPILL2 row grain.
# =============================================================================


struct NativeRowBlock(Spillable):
    """A fixed-stride row image as an opaque THSPILL2 body.

    This is the production row `Spillable` conformer for the row grain: the
    body bytes are byte-identical to the operator's in-memory row image (e.g.
    the hash-agg partition `row_data`). `row_count` × `entry_stride` ==
    `nbytes`. The fingerprint is the canonical FNV-1a-64 the agg path uses.

    Restore (`from_bytes`) keeps the decoded bytes as the body, exposing
    `entry_stride` (recovered as `nbytes / row_count`) so the operator can
    re-stride the rows.

    Fields:
        _bytes:       The row image bytes (SAB-backed; gap6-safe POD handle).
        _row_count:   Logical row count.
        _fingerprint: Schema identity (entry_stride + agg-tag fold).
    """

    var _bytes: SharedAlignedBuffer[HeapRegion]
    var _row_count: Int64
    var _fingerprint: UInt64

    def __init__(
        out self,
        var bytes: SharedAlignedBuffer[HeapRegion],
        row_count: Int64,
        fingerprint: UInt64,
    ):
        self._bytes = bytes^
        self._row_count = row_count
        self._fingerprint = fingerprint

    def row_count(self) -> Int64:
        return self._row_count

    def nbytes(self) -> Int64:
        return Int64(self._bytes.length())

    def schema_fingerprint(self) -> UInt64:
        return self._fingerprint

    def as_byte_view[
        _mut: Bool, origin: Origin[mut=_mut], //,
    ](ref [origin] self) -> ByteView[origin]:
        var inner_view = self._bytes.as_view()
        return rebind[ByteView[origin]](inner_view)

    @staticmethod
    def from_bytes(
        var bytes: SharedAlignedBuffer[HeapRegion],
        row_count: Int64,
        schema_fingerprint: UInt64,
    ) raises -> Self:
        return Self(bytes^, row_count, schema_fingerprint)

    def entry_stride(self) raises -> Int:
        """Bytes per row, recovered as `nbytes / row_count`. Raises on a
        zero row count (the caller should not restore an empty block)."""
        if self._row_count <= 0:
            raise Error(
                "NativeRowBlock.entry_stride: row_count is "
                + String(self._row_count)
                + " — cannot recover stride"
            )
        return Int(self._bytes.length()) // Int(self._row_count)

    def byte_view[
        _mut: Bool, origin: Origin[mut=_mut], //,
    ](ref [origin] self) -> ByteView[origin]:
        """Borrow the body bytes for the operator's re-stride pass. Lifetime
        tied to the receiver borrow (same shape as `as_byte_view`)."""
        var inner_view = self._bytes.as_view()
        return rebind[ByteView[origin]](inner_view)


# =============================================================================
# NativeRowSpillWriter — row body -> THSPILL2 -> SpillStorage.
# =============================================================================


struct NativeRowSpillWriter(Movable):
    """Writes fixed-stride row blocks to a native THSPILL2-backed spill run.

    The row-grain sibling of `NativeColumnSpillWriter`. Each `write_block`
    THSPILL2-encodes a `NativeRowBlock` into one chunk. The body bytes are
    byte-identical to the in-memory row image (no transpose, no IPC framing).

    Fields:
        _storage:   The owned per-run LocalDiskSpillStorage.
        _chunk_ids: ChunkId per written block, in write order.
        _root:      The storage root dir.
    """

    var _storage: LocalDiskSpillStorage
    var _chunk_ids: Slab[ChunkId]
    var _root: String

    @staticmethod
    def create(
        var spill_dir: String, counter: Int
    ) raises -> NativeRowSpillWriter:
        var root = spill_dir + "/thspill2_run_" + String(counter)
        var storage = LocalDiskSpillStorage.with_unlimited(root)
        return NativeRowSpillWriter(
            _storage=storage^,
            _chunk_ids=Slab[ChunkId](),
            _root=root,
        )

    def __init__(
        out self,
        var _storage: LocalDiskSpillStorage,
        var _chunk_ids: Slab[ChunkId],
        var _root: String,
    ):
        self._storage = _storage^
        self._chunk_ids = _chunk_ids^
        self._root = _root^

    def write_block(mut self, var block: NativeRowBlock) raises:
        """THSPILL2-encode `block` and append it as one chunk."""
        var cid = THSpill2Encoder[NativeRowBlock].encode(self._storage, block^)
        self._chunk_ids.append(cid)

    def num_blocks(self) -> Int:
        return len(self._chunk_ids)

    def root(self) -> String:
        return self._root

    def close(mut self) raises:
        self._storage.sync()

    def cleanup(mut self) raises:
        self._storage.cleanup()


# =============================================================================
# NativeRowSpillReader — SpillStorage -> THSPILL2 -> NativeRowBlock.
# =============================================================================


struct NativeRowSpillReader(Movable):
    """Reads fixed-stride row blocks back from a native THSPILL2 spill run.

    Row-grain sibling of `NativeColumnSpillReader`. Re-registers each chunk
    (the fresh storage has no ChunkId map) and replays them in write order via
    `decode_copy` (the restored block is storage-independent).
    """

    var _storage: LocalDiskSpillStorage
    var _num_chunks: Int

    @staticmethod
    def open(
        var root: String, num_blocks: Int
    ) raises -> NativeRowSpillReader:
        var storage = LocalDiskSpillStorage.with_unlimited(root)
        for i in range(num_blocks):
            storage.reopen_chunk(ChunkId(UInt64(i + 1)))
        return NativeRowSpillReader(
            _storage=storage^,
            _num_chunks=num_blocks,
        )

    def __init__(
        out self,
        var _storage: LocalDiskSpillStorage,
        _num_chunks: Int,
    ):
        self._storage = _storage^
        self._num_chunks = _num_chunks

    def count_blocks(self) -> Int:
        return self._num_chunks

    def read_block(mut self, index: Int) raises -> NativeRowBlock:
        if index < 0 or index >= self._num_chunks:
            raise Error(
                "NativeRowSpillReader.read_block: index "
                + String(index)
                + " out of range [0, "
                + String(self._num_chunks)
                + ")"
            )
        return THSpill2Decoder[NativeRowBlock].decode_copy(
            self._storage, ChunkId(UInt64(index + 1))
        )

    def cleanup(mut self) raises:
        self._storage.cleanup()
