# =============================================================================
# scan_chunk_sink — the terminal step of the sub-row-group executors
# =============================================================================
#
# The sub-row-group executors decode row groups chunk by chunk into fixed
# per-worker buffers, build a batch per chunk, apply any WHERE predicate, and
# hand each chunk to a `ScanChunkSink`. Everything up to that call (cursors,
# the per-row-group decline, the lockstep fill, the completeness check, the
# whole-row-group fallback) does not depend on the sink; the sink is either
# an aggregate fold or the scan's collect (`ScanCollectChunkSink`).
#
# Lifecycle: `init_worker_state` builds a worker's private accumulator once;
# `consume_chunk` takes each chunk; after the join `combine_workers` folds the
# workers' accumulators into one and `drain` turns it into output batches.
#
# The collect sink stages each chunk stamped `(rg_idx, chunk_idx)` in a
# per-worker `StreamingScanOutputBuilder` and drains every chunk, stably
# sorted by stamp, into file order (row groups are claimed out of order). It
# never concatenates the whole result.
#
# A dictionary STRING column is carried as raw int32 codes (a flat INT32
# placeholder column in the chunk) plus the row group's dictionary as byte
# lists (`StagedStringDictCol`): building or dropping a string array on a
# worker thread is avoided, and the dictionary column is built on the serial
# drain. Each chunk keeps its own row group's dictionary; merging chunks of
# different row groups is left to the batch concatenation, which unions and
# remaps dictionaries.
# =============================================================================

from std.builtin.swap import swap
from std.memory import Pointer

from komira_arrow.arrow_types import ArrowType
from komira_arrow.column import Column
from komira_arrow.dictionary_array import StringDictionaryArray
from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.record_batch import RecordBatch, RecordBatchBuilder
from komira_arrow.schema import Field, Schema, SchemaBuilder
from komira_arrow.string_array import StringArray
from komira_async.ops.waker_sink import NoopSink
from komira_async.runtime.local_dispatcher import LocalDispatcher
from komira_async_api.token import CancellationToken
from komira_buffer.heap_region import HeapRegion
from komira_collections.slab import Slab
from komira_column_kernels.compiler_helpers import copy_column


struct StagedStringDictCol(Copyable, Movable, Deinitable):
    """One dictionary string column of a staged chunk.

    Fields:
        col_pos: the output column the INT32 codes placeholder occupies.
        name: the column's output name.
        dict_offsets: the row group's dictionary as N+1 byte offsets
            (`dict_offsets[0] == 0`, `dict_offsets[N] == len(dict_bytes)`).
        dict_bytes: the packed dictionary bytes; entry `e` is
            `[dict_offsets[e], dict_offsets[e + 1])`.
    """

    var col_pos: Int
    var name: String
    var dict_offsets: List[Int32]
    var dict_bytes: List[UInt8]

    def __init__(out self, col_pos: Int, var name: String, var dict_offsets: List[Int32], var dict_bytes: List[UInt8]):
        self.col_pos = col_pos
        self.name = name^
        self.dict_offsets = dict_offsets^
        self.dict_bytes = dict_bytes^


trait ScanChunkSink(Movable, Deinitable):
    """The terminal per-chunk step of a sub-row-group executor.

    `WorkerLocal` is a worker's private accumulator; it lives in a per-worker
    `Slab[Optional[WorkerLocal]]` of the executor's state.
    """

    comptime WorkerLocal: Movable & Deinitable

    def init_worker_state(self) raises -> Self.WorkerLocal:
        """A worker's private accumulator."""
        ...

    def consume_chunk[o_local: Origin[mut=True]](
        self,
        ref [o_local] local: Self.WorkerLocal,
        rg_idx: Int,
        chunk_idx: Int,
        var batch: RecordBatch,
    ) raises:
        """Take one chunk, stamped `(rg_idx, chunk_idx)` (an order-insensitive
        fold ignores the stamp)."""
        ...

    def combine_workers[disp_o: Origin[mut=True]](
        self,
        var locals: Slab[Optional[Self.WorkerLocal]],
        num_workers: Int,
        dispatcher_ptr: Pointer[LocalDispatcher[NoopSink], disp_o],
        var cancel_token: CancellationToken,
    ) raises -> Self.WorkerLocal:
        """After the join: fold every worker's accumulator into one. The
        dispatcher lets a sink fan its combine out on the idle pool."""
        ...

    def drain[disp_o: Origin[mut=True]](
        self,
        var combined: Self.WorkerLocal,
        var output_schema: Schema,
        dispatcher_ptr: Pointer[LocalDispatcher[NoopSink], disp_o],
        var cancel_token: CancellationToken,
    ) raises -> Slab[RecordBatch]:
        """The combined accumulator as output batches (an aggregate: one
        batch; the collect: the chunks in file order)."""
        ...


struct StagedChunk(Movable, Deinitable):
    """One staged chunk: its batch, its `(rg_idx, chunk_idx)` stamp, and the
    dictionary string columns whose codes placeholders it carries."""

    var batch: RecordBatch
    var rg_idx: Int
    var chunk_idx: Int
    var str_dict_cols: List[StagedStringDictCol]

    def __init__(out self, var batch: RecordBatch, rg_idx: Int, chunk_idx: Int, var str_dict_cols: List[StagedStringDictCol]):
        self.batch = batch^
        self.rg_idx = rg_idx
        self.chunk_idx = chunk_idx
        self.str_dict_cols = str_dict_cols^

    def into_batch(var self) raises -> RecordBatch:
        """The batch of a chunk with no dictionary string column."""
        var out = RecordBatch()
        swap(self.batch, out)
        _ = self^
        return out^

    def has_string_dict(self) -> Bool:
        """The chunk carries a dictionary string column to build."""
        return len(self.str_dict_cols) > 0


def _chunk_bytes(batch: RecordBatch, str_dict_cols: List[StagedStringDictCol]) -> Int:
    """A cheap over-estimate of a staged chunk's bytes: 8 per cell, plus its
    dictionaries."""
    var cols = batch.num_columns()
    var n = batch.num_rows() * (cols if cols > 0 else 1) * 8
    for i in range(len(str_dict_cols)):
        n += len(str_dict_cols[i].dict_bytes)
    return n


struct StreamingScanOutputBuilder(Movable, Deinitable):
    """A worker's staged scan output.

    Fields:
        _staged: chunks since the last flush.
        _flushed: chunks moved out of the staging window once it reached
            `byte_budget`.
        _staged_bytes: the estimated bytes of `_staged`.
        byte_budget: the staging window's flush threshold.
    """

    var _staged: Slab[StagedChunk]
    var _flushed: Slab[StagedChunk]
    var _staged_bytes: Int
    var byte_budget: Int

    def __init__(out self, byte_budget: Int):
        self._staged = Slab[StagedChunk]()
        self._flushed = Slab[StagedChunk]()
        self._staged_bytes = 0
        self.byte_budget = byte_budget if byte_budget > 0 else (1 << 20)

    def append(
        mut self,
        var batch: RecordBatch,
        rg_idx: Int,
        chunk_idx: Int,
        var str_dict_cols: List[StagedStringDictCol] = List[StagedStringDictCol](),
    ) raises:
        """Stage one stamped chunk; flush the window once it reaches the
        budget."""
        self._staged_bytes += _chunk_bytes(batch, str_dict_cols)
        self._staged.append(StagedChunk(batch^, rg_idx, chunk_idx, str_dict_cols^))
        if self._staged_bytes >= self.byte_budget:
            self._flush()

    def _flush(mut self) raises:
        """Move the staging window to `_flushed`, chunk by chunk."""
        var n = len(self._staged)
        for i in range(n):
            self._flushed.append(self._staged.take_slot_unchecked(i))
        self._staged.set_len_unchecked(0)
        self._staged_bytes = 0

    def num_chunks(self) -> Int:
        """Chunks held (staged and flushed)."""
        return len(self._staged) + len(self._flushed)

    def discard_rg(mut self, rg_idx: Int) raises -> Int:
        """Drop every chunk stamped `rg_idx`; return the rows dropped.

        A cursor can refuse a page shape mid-row-group (a page's nulls show
        only once its levels are decoded), after some chunks of the row group
        were already consumed; the executor then decodes the row group whole.
        Without this retraction both the consumed prefix and the whole row
        group would reach the drain, and the prefix would come out twice. It
        is exact because a row group is decoded by exactly one worker, whose
        builder this is, and because a staged chunk holds one row group
        (`_flush` moves chunks as they are: a compaction that merged row
        groups would break it)."""
        var dropped = 0
        var keep_staged = Slab[StagedChunk]()
        var kept_bytes = 0
        var ns = len(self._staged)
        for i in range(ns):
            var sc = self._staged.take_slot_unchecked(i)
            if sc.rg_idx == rg_idx:
                dropped += sc.batch.num_rows()
                _ = sc^
                continue
            kept_bytes += _chunk_bytes(sc.batch, sc.str_dict_cols)
            keep_staged.append(sc^)
        self._staged.set_len_unchecked(0)
        swap(self._staged, keep_staged)
        _ = keep_staged^
        self._staged_bytes = kept_bytes
        var keep_flushed = Slab[StagedChunk]()
        var nf = len(self._flushed)
        for i in range(nf):
            var sc = self._flushed.take_slot_unchecked(i)
            if sc.rg_idx == rg_idx:
                dropped += sc.batch.num_rows()
                _ = sc^
                continue
            keep_flushed.append(sc^)
        self._flushed.set_len_unchecked(0)
        swap(self._flushed, keep_flushed)
        _ = keep_flushed^
        return dropped

    def merge_from(mut self, var other: StreamingScanOutputBuilder) raises:
        """Fold another worker's chunks into this builder (the drain restores
        the order). Consumes `other`."""
        var of = Slab[StagedChunk]()
        swap(other._flushed, of)
        for i in range(len(of)):
            self._flushed.append(of.take_slot_unchecked(i))
        of.set_len_unchecked(0)
        var os = Slab[StagedChunk]()
        swap(other._staged, os)
        for i in range(len(os)):
            self._flushed.append(os.take_slot_unchecked(i))
        os.set_len_unchecked(0)
        _ = other^

    def drain(mut self) raises -> Slab[RecordBatch]:
        """Every chunk as a batch, stably sorted by `(rg_idx, chunk_idx)`,
        dictionary string columns built. No concatenation."""
        var all_chunks = Slab[StagedChunk]()
        for i in range(len(self._flushed)):
            all_chunks.append(self._flushed.take_slot_unchecked(i))
        self._flushed.set_len_unchecked(0)
        for i in range(len(self._staged)):
            all_chunks.append(self._staged.take_slot_unchecked(i))
        self._staged.set_len_unchecked(0)
        self._staged_bytes = 0
        var n = len(all_chunks)
        var order = List[Int](capacity=n)
        for i in range(n):
            order.append(i)
        _stable_sort_index_by_stamp(all_chunks, order)
        # Move every chunk out, in reverse order, before anything can raise:
        # a slab whose slots were taken must not be dropped with its length
        # unchanged, and `pop` keeps the reversed slab whole at every step.
        var rev = Slab[StagedChunk]()
        for k in range(n - 1, -1, -1):
            rev.append(all_chunks.take_slot_unchecked(order[k]))
        all_chunks.set_len_unchecked(0)
        var out = Slab[RecordBatch]()
        while len(rev) > 0:
            var got = rev.pop()
            var sc = got.take()
            if sc.has_string_dict():
                out.append(_resolve_string_dict_chunk(sc^))
            else:
                out.append(sc^.into_batch())
        return out^


def _resolve_string_dict_chunk(var sc: StagedChunk) raises -> RecordBatch:
    """Serial drain only: replace each INT32 codes placeholder of a staged
    chunk with a dictionary string column over the chunk's row group
    dictionary.

    Raises:
        If a codes column's length is not the chunk's row count.
    """
    var batch = RecordBatch()
    swap(sc.batch, batch)
    var n_cols = batch.num_columns()
    var n_rows = batch.num_rows()
    var sb = SchemaBuilder()
    var rbb = RecordBatchBuilder.with_capacity(n_cols)
    for c in range(n_cols):
        var sdc_idx = -1
        for j in range(len(sc.str_dict_cols)):
            if sc.str_dict_cols[j].col_pos == c:
                sdc_idx = j
                break
        if sdc_idx < 0:
            sb.add_field(batch.schema.field_at(c))
            rbb.add_column(copy_column(batch, c))
            continue
        ref sdc = sc.str_dict_cols[sdc_idx]
        var codes = batch.column_at(c).as_primitive[DType.int32]()
        if codes.length != n_rows:
            raise Error(
                "scan chunk: codes column '" + sdc.name + "' has " + String(codes.length)
                + " rows, the chunk " + String(n_rows)
            )
        var indices = PrimitiveArray[DType.int32].allocate(n_rows)
        for r in range(n_rows):
            indices.set_typed[Scalar[DType.int32]](r, codes.get_typed[Scalar[DType.int32]](r))
        var dict_arr = StringArray.from_buffers(sdc.dict_offsets, sdc.dict_bytes, None, 0)
        var sda = StringDictionaryArray.from_parts(indices^, dict_arr^)
        sb.add_field(Field(sdc.name, ArrowType.DICTIONARY, False))
        rbb.add_column(Column.from_dictionary(sda^))
    _ = batch^
    _ = sc^
    return rbb.build(sb.build())


def _stable_sort_index_by_stamp(chunks: Slab[StagedChunk], mut order: List[Int]):
    """Stable insertion sort of `order` by each chunk's `(rg_idx,
    chunk_idx)`; the chunks themselves do not move."""
    for i in range(1, len(order)):
        var j = i
        while j > 0 and _stamp_gt(chunks[order[j - 1]], chunks[order[j]]):
            var tmp = order[j - 1]
            order[j - 1] = order[j]
            order[j] = tmp
            j -= 1


@always_inline
def _stamp_gt(a: StagedChunk, b: StagedChunk) -> Bool:
    if a.rg_idx != b.rg_idx:
        return a.rg_idx > b.rg_idx
    return a.chunk_idx > b.chunk_idx


struct ScanCollectChunkSink(ScanChunkSink, Movable, Deinitable):
    """The scan's collect sink over `StreamingScanOutputBuilder`, with a
    per-worker flush budget in bytes."""

    comptime WorkerLocal = StreamingScanOutputBuilder

    var _byte_budget: Int

    def __init__(out self, byte_budget: Int):
        self._byte_budget = byte_budget if byte_budget > 0 else (1 << 20)

    def init_worker_state(self) raises -> StreamingScanOutputBuilder:
        return StreamingScanOutputBuilder(self._byte_budget)

    def consume_chunk[o_local: Origin[mut=True]](
        self,
        ref [o_local] local: StreamingScanOutputBuilder,
        rg_idx: Int,
        chunk_idx: Int,
        var batch: RecordBatch,
    ) raises:
        local.append(batch^, rg_idx, chunk_idx, List[StagedStringDictCol]())

    def consume_string_dict_chunk[o_local: Origin[mut=True]](
        self,
        ref [o_local] local: StreamingScanOutputBuilder,
        rg_idx: Int,
        chunk_idx: Int,
        var batch: RecordBatch,
        var str_dict_cols: List[StagedStringDictCol],
    ) raises:
        """Stage a chunk carrying dictionary string columns (codes
        placeholders in `batch`, dictionaries in `str_dict_cols`)."""
        local.append(batch^, rg_idx, chunk_idx, str_dict_cols^)

    def combine_workers[disp_o: Origin[mut=True]](
        self,
        var locals: Slab[Optional[StreamingScanOutputBuilder]],
        num_workers: Int,
        dispatcher_ptr: Pointer[LocalDispatcher[NoopSink], disp_o],
        var cancel_token: CancellationToken,
    ) raises -> StreamingScanOutputBuilder:
        _ = cancel_token^
        var have_acc = False
        var acc = StreamingScanOutputBuilder(self._byte_budget)
        for wid in range(num_workers):
            if locals[wid]:
                var b = locals[wid].take()
                if not have_acc:
                    acc = b^
                    have_acc = True
                else:
                    acc.merge_from(b^)
        _ = locals^
        return acc^

    def drain[disp_o: Origin[mut=True]](
        self,
        var combined: StreamingScanOutputBuilder,
        var output_schema: Schema,
        dispatcher_ptr: Pointer[LocalDispatcher[NoopSink], disp_o],
        var cancel_token: CancellationToken,
    ) raises -> Slab[RecordBatch]:
        _ = cancel_token^
        _ = output_schema^
        var out = combined.drain()
        _ = combined^
        return out^
