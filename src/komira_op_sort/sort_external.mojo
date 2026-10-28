# =============================================================================
# sort_external -- ExternalSorter: accumulate, sort, spill past a budget, and
# k-way merge
# =============================================================================
#
#   1. `absorb(batch)` buffers the batch and adds its buffer bytes to the
#      running estimate. Past `memory_budget` (bytes; 0 = never), the buffer is
#      sorted (`sort_multi.sort_batch_by_keys`), cut into `output_batch_size`
#      batches and written as one run of THSPLC chunks to a spill storage on
#      the local disk (`komira_engine_runtime.spill`), and the buffer is freed.
#   2. `finish()` sorts what is left as one in-memory run, reads every spilled
#      run back, and merges all runs (`sort_external_merge.k_way_merge_cursors`:
#      the loser tree, then `cross_batch_gather`).
#
# The output is the rows of one stable `sort_batch_by_keys` over every absorbed
# batch in absorb order: each run is a stable sort of a contiguous stretch of
# the input, runs are merged in that order, and the merge breaks a full tie
# by the lower run.
#
# Sort keys: INT32, INT64, FLOAT64 (checked on the first batch). Not done
# here: a normalized-key encoding, a radix sort of the run, a parallel run
# sort.
# =============================================================================

from std.collections import Optional
from std.time import perf_counter_ns

from komira_arrow.arrow_types import ArrowType
from komira_arrow.record_batch import RecordBatch
from komira_arrow.schema import Field, Schema, SchemaBuilder
from komira_collections.slab import Slab
from komira_column_kernels.compiler_helpers import copy_batch
from komira_column_kernels.cross_batch_gather import cross_batch_gather
from komira_engine_runtime.spill.local_disk import LocalDiskSpillStorage
from komira_engine_runtime.spill.native_spill import (
    native_column_read_chunk,
    native_column_write_chunk,
)
from komira_engine_runtime.spill.spill_storage import ChunkId

from .sort_external_merge import RunCursor, k_way_merge_cursors
from .sort_multi import sort_batch_by_keys


comptime DEFAULT_OUTPUT_BATCH_SIZE: Int = 8192
"""Rows per merged output batch."""


# =============================================================================
# ExternalSorter
# =============================================================================


struct ExternalSorter(Movable, Deinitable):
    """Accumulating external sort with optional spill-to-disk and k-way merge.

    Usage:
        var s = ExternalSorter.create(memory_budget=64<<20, key_names=..,
                                       descending=..)
        for batch in input:
            s.absorb(batch^)
        var sorted = s^.finish()  # returns Slab[RecordBatch]

    See the module header for what is not done.
    """

    var _key_names: List[String]
    var _descending: List[Bool]
    var _memory_budget: Int
    """Bytes; 0 means unlimited (no spilling)."""

    var _output_batch_size: Int

    var _buffer: Slab[RecordBatch]
    """Accumulating in-memory unsorted batches."""

    var _current_memory: Int
    """Estimated bytes in `_buffer`."""

    var _has_schema: Bool
    var _schema_fields: List[Field]
    """Captured from the first absorbed batch. We rebuild a Schema on demand
    rather than storing one. Whole Field clones, so field metadata (time zone,
    decimal precision and scale, dictionary index type, union type ids, flags,
    key-value metadata) survives the rebuild."""

    var _spill_dir: String
    # ONE shared THSPLC spill storage for the WHOLE sort (lazily created on the
    # first spill). Every run's batches are appended as chunks into it; the
    # finalize merge reads them back by ChunkId from the same instance, so the
    # whole sort makes one directory.
    var _spill_storage: Optional[LocalDiskSpillStorage]
    # Per spilled run: the first ChunkId value + the number of batches in the
    # run. Chunk ids are monotonic from 1 within the shared storage, so run i's
    # chunks are `[first, first + n_batches)`. Parallel lists (Int is Copyable).
    var _spill_run_first_chunk: List[Int]
    var _spill_run_nbatches: List[Int]
    # Running ChunkId value (== last minted chunk's value; storage mints from 1).
    var _spill_next_chunk: Int
    var _spill_counter: Int

    var _sorted_runs: Slab[Slab[RecordBatch]]
    """In-memory sorted runs accumulated from final-buffer sort. Each entry
    is one sorted run (possibly multi-batch after split)."""

    def __del__(deinit self):
        """Release the spill files of a sorter dropped before `finish` (a
        cancelled or failed query). Best-effort: a destructor cannot raise."""
        if self._spill_storage:
            try:
                self._spill_storage.value().cleanup()
            except:
                pass

    @staticmethod
    def create(
        memory_budget: Int,
        var key_names: List[String],
        var descending: List[Bool],
        var spill_dir: String,
        output_batch_size: Int = DEFAULT_OUTPUT_BATCH_SIZE,
    ) raises -> ExternalSorter:
        """Construct a new sorter.

        Args:
            memory_budget: Bytes; 0 = unlimited (no spill). When current
                in-memory buffer estimate exceeds this, spill is triggered.
            key_names: Sort key column names, primary key first.
            descending: Per-key direction. Must match len(key_names).
            spill_dir: Directory for spill files, chosen by the caller (the
                sorter reads no environment); a sub-directory is created
                under it on the first spill and removed when the sorter
                finishes, fails or is dropped.
            output_batch_size: Rows per merged output batch.
        """
        if len(key_names) != len(descending):
            raise Error(
                "ExternalSorter.create: key_names and descending lengths differ ("
                + String(len(key_names))
                + " vs "
                + String(len(descending))
                + ")"
            )
        if len(key_names) == 0:
            raise Error("ExternalSorter.create: at least one sort key required")

        return ExternalSorter(
            key_names^,
            descending^,
            memory_budget,
            output_batch_size,
            spill_dir^,
        )

    def __init__(
        out self,
        var key_names: List[String],
        var descending: List[Bool],
        memory_budget: Int,
        output_batch_size: Int,
        var spill_dir: String,
    ):
        self._key_names = key_names^
        self._descending = descending^
        self._memory_budget = memory_budget
        self._output_batch_size = output_batch_size
        self._buffer = Slab[RecordBatch]()
        self._current_memory = 0
        self._has_schema = False
        self._schema_fields = List[Field]()
        self._spill_dir = spill_dir^
        self._spill_storage = Optional[LocalDiskSpillStorage](None)
        self._spill_run_first_chunk = List[Int]()
        self._spill_run_nbatches = List[Int]()
        self._spill_next_chunk = 1
        self._spill_counter = 0
        self._sorted_runs = Slab[Slab[RecordBatch]]()

    # -------------------------------------------------------------------------
    # absorb
    # -------------------------------------------------------------------------

    def _capture_schema(mut self, batch: RecordBatch) raises:
        """Capture the schema of the first absorbed batch, plus validate that
        every declared sort key resolves to a supported ArrowType."""
        if self._has_schema:
            return
        var nc = batch.num_columns()
        for i in range(nc):
            # The whole Field, so its metadata survives the rebuild.
            self._schema_fields.append(batch.schema.field_at(i))
        # Validate that each sort key resolves and has a supported dtype.
        for k in range(len(self._key_names)):
            var name = self._key_names[k]
            var col_idx = batch.schema.column_index(name)
            var at = batch.schema.field_arrow_type(col_idx)
            # INT32, INT64 and FLOAT64 keys only (the merge comparator also
            # orders STRING and FLOAT32, but the sorter does not admit them).
            if not (
                at == ArrowType.INT32
                or at == ArrowType.INT64
                or at == ArrowType.FLOAT64
            ):
                raise Error(
                    "ExternalSorter: unsupported sort key dtype "
                    + String(at)
                    + " for key '"
                    + name
                    + "' (supported: INT32, INT64, FLOAT64)"
                )
        self._has_schema = True

    def _rebuild_schema(self) raises -> Schema:
        var sb = SchemaBuilder()
        for i in range(len(self._schema_fields)):
            sb.add_field(self._schema_fields[i].copy())
        return sb.build()

    @staticmethod
    def _estimate_batch_bytes(batch: RecordBatch) raises -> Int:
        """Rough estimate of array-memory footprint (sum of buffer bytes per
        column)."""
        var total = 0
        var nc = batch.num_columns()
        for c in range(nc):
            ref col = batch.column_at(c)
            total += col._data.len()
            if col._offsets:
                total += col._offsets.value().len()
            if col._validity:
                # Bitmap stores `length` in bits; storage is (length+7)>>3 bytes.
                total += (col._validity.value().length + 7) >> 3
        return total

    def absorb(mut self, var batch: RecordBatch) raises:
        """Add a batch to the sorter. Triggers spill if budget exceeded."""
        self._capture_schema(batch)

        var bytes = ExternalSorter._estimate_batch_bytes(batch)
        self._current_memory += bytes
        self._buffer.append(batch^)

        if self._memory_budget > 0 and self._current_memory > self._memory_budget and len(self._buffer) > 0:
            self._spill_current_run()

    # -------------------------------------------------------------------------
    # spill
    # -------------------------------------------------------------------------

    def _sort_buffer_into_batches(
        mut self,
    ) raises -> Slab[RecordBatch]:
        """Sort-and-split the current `_buffer` into one sorted run.

        Concatenates buffered batches via `cross_batch_gather` (when >1
        batch is buffered), sorts the combined batch via `sort_batch_by_keys`,
        then splits into output-sized chunks.
        """
        var out = Slab[RecordBatch]()
        var n_buf = len(self._buffer)
        if n_buf == 0:
            return out^

        # Combine all buffered batches into one: cross_batch_gather with an
        # (i, row) pair per row of every buffered batch, a concatenation.
        var combined: RecordBatch
        if n_buf == 1:
            # The single batch is deep-copied (copy_batch), then the buffer
            # is dropped.
            combined = copy_batch(self._buffer[0])
            self._buffer = Slab[RecordBatch]()
        else:
            var idx = List[Tuple[Int, Int]]()
            for b in range(n_buf):
                var nr = self._buffer[b].num_rows()
                for r in range(nr):
                    idx.append((b, r))
            combined = cross_batch_gather(self._buffer, idx)
            # Drain buffer (gather did not consume; safe to discard).
            self._buffer = Slab[RecordBatch]()

        self._current_memory = 0

        # Sort the combined batch by keys.
        # sort_batch_by_keys takes `var batch` so we move-pass.
        var key_copy = List[String]()
        for i in range(len(self._key_names)):
            key_copy.append(self._key_names[i])
        var desc_copy = List[Bool]()
        for i in range(len(self._descending)):
            desc_copy.append(self._descending[i])
        var sorted = sort_batch_by_keys(combined^, key_copy, desc_copy)

        # Split into output-batch-size chunks by row-index gathers.
        var total = sorted.num_rows()
        var off = 0
        # Wrap `sorted` into a single-element source array for the gathers.
        var single_src = Slab[RecordBatch]()
        single_src.append(sorted^)
        while off < total:
            var len_chunk = min(self._output_batch_size, total - off)
            var chunk_idx = List[Tuple[Int, Int]]()
            for r in range(off, off + len_chunk):
                chunk_idx.append((0, r))
            var chunk = cross_batch_gather(single_src, chunk_idx)
            out.append(chunk^)
            off += len_chunk
        return out^

    def _spill_current_run(mut self) raises:
        """Sort the current buffer and write the resulting sorted batches to a
        native THSPLC spill run (`native_column_write_chunk`).

        The spilled bytes are the in-memory column buffers (no transpose, no
        IPC framing); restore copies them back (`decode_copy`), so the merged
        batches do not depend on the storage. The run stays sorted.
        """
        var sorted_run = self._sort_buffer_into_batches()
        if len(sorted_run) == 0:
            return

        # The one shared spill storage, created on the first spill.
        if not self._spill_storage:
            var dir_copy = self._spill_dir + "/thsplc_sort_" + String(
                Int(perf_counter_ns())
            )
            self._spill_storage = Optional[LocalDiskSpillStorage](
                LocalDiskSpillStorage.with_unlimited(dir_copy)
            )

        ref storage = self._spill_storage.value()
        var first_chunk = self._spill_next_chunk

        # `sorted_run` is consumed batch-by-batch into the THSPLC encoder.
        # Drain via take_slot_unchecked (the canonical in-place drain
        # primitive), then set_len_unchecked(0) so the slab drop does not
        # double-destroy the moved-out slots.
        var n_run = len(sorted_run)
        var taken = 0
        try:
            for i in range(n_run):
                var b = sorted_run.take_slot_unchecked(i)
                taken = i + 1
                _ = native_column_write_chunk(storage, b^)
                self._spill_next_chunk += 1
        except e:
            # Drop the batches not yet written, then forget every slot: the
            # slab must not destroy a moved-out slot again.
            for k in range(taken, n_run):
                _ = sorted_run.take_slot_unchecked(k)
            sorted_run.set_len_unchecked(0)
            raise e^
        sorted_run.set_len_unchecked(0)

        # The sync the spill contract asks for before the in-memory state is
        # freed.
        storage.sync()

        self._spill_run_first_chunk.append(first_chunk)
        self._spill_run_nbatches.append(n_run)
        self._spill_counter += 1

    # -------------------------------------------------------------------------
    # finish
    # -------------------------------------------------------------------------

    def finish(var self) raises -> Slab[RecordBatch]:
        """Sort the final in-memory buffer, then k-way merge all sorted runs
        (in-memory + spilled) into the final output."""
        # 1. Sort whatever's left in the in-memory buffer.
        if len(self._buffer) > 0:
            var last_run = self._sort_buffer_into_batches()
            if len(last_run) > 0:
                self._sorted_runs.append(last_run^)

        var have_in_memory = len(self._sorted_runs) > 0
        var have_spilled = len(self._spill_run_first_chunk) > 0

        # Empty sorter: no schema captured, nothing to emit.
        if not self._has_schema:
            return Slab[RecordBatch]()

        # 2. Build cursors for all runs (in-memory + spilled).
        var cursors = Slab[RunCursor]()

        if have_in_memory:
            var nr = len(self._sorted_runs)
            for r in range(nr):
                var run = self._sorted_runs.take_slot_unchecked(r)
                if len(run) > 0:
                    cursors.append(RunCursor(run^))
            # Every slot was taken: mark the slab empty.
            self._sorted_runs.set_len_unchecked(0)

        if have_spilled:
            # Move the shared storage OUT of the Optional so the read loop's
            # mutable borrow of `storage` (now a local var, not a borrow of
            # self) does not conflict with the `self._rebuild_schema()` borrow.
            var storage = self._spill_storage.take()
            try:
                for i in range(len(self._spill_run_first_chunk)):
                    var first = self._spill_run_first_chunk[i]
                    var n = self._spill_run_nbatches[i]
                    var rb = Slab[RecordBatch]()
                    for j in range(n):
                        # THSPLC decode reattaches the captured schema directly
                        # (the codec restores into the caller's expected Schema —
                        # field names are preserved, no "col_0" patch needed).
                        # Chunk ids are monotonic from 1: run i's j-th batch is at
                        # ChunkId(first + j) in the shared storage.
                        var raw = native_column_read_chunk(
                            storage,
                            ChunkId(UInt64(first + j)),
                            self._rebuild_schema(),
                        )
                        rb.append(raw^)
                    if len(rb) > 0:
                        cursors.append(RunCursor(rb^))
            except e:
                # A failed read must not leave the run files behind.
                try:
                    storage.cleanup()
                except:
                    pass
                raise e^
            # All runs restored into memory (decode_copy made them storage-
            # independent). Release every chunk file + rmdir the shared root.
            storage.cleanup()
            _ = storage^

        var num_streams = len(cursors)
        if num_streams == 0:
            return Slab[RecordBatch]()

        # Single run: no merge; its batches are the output.
        if num_streams == 1:
            var c0 = cursors.take_slot_unchecked(0)
            cursors.set_len_unchecked(0)
            return c0^.take_batches()

        # 4. K-way merge via LoserTree + cross_batch_gather (multi-run).
        return self._k_way_merge(cursors^)

    def _k_way_merge(
        mut self, var cursors_arr: Slab[RunCursor]
    ) raises -> Slab[RecordBatch]:
        """K-way merge core. Resolves the per-key column indices + ArrowTypes
        from `self._key_names` against the first cursor's first batch, then
        delegates to the reusable `k_way_merge_cursors` free function.
        """
        var num_streams = len(cursors_arr)
        if num_streams == 0:
            return Slab[RecordBatch]()

        # Resolve key column indices once using the first cursor's first batch
        # (all batches in all runs share schema by the sorter contract).
        var num_keys = len(self._key_names)
        var key_indices = List[Int]()
        var descending = List[Bool]()
        var arrow_types = List[UInt8]()
        ref first_batch = cursors_arr[0].batches[0]
        for k in range(num_keys):
            var col_idx = first_batch.schema.column_index(self._key_names[k])
            key_indices.append(col_idx)
            descending.append(self._descending[k])
            arrow_types.append(
                first_batch.schema.field_arrow_type(col_idx).type_id
            )

        return k_way_merge_cursors(
            cursors_arr^,
            num_keys,
            key_indices^,
            descending^,
            arrow_types^,
            self._output_batch_size,
        )
