# =============================================================================
# sink_partition_topn -- (SINK_PARTITION_TOPN, KEY_DTYPE_NONE, COLUMNAR)
# =============================================================================
#
# The top rows of each partition: the rows are collected into one batch and
# `op_window`'s `PartitionTopNSink` keeps, per partition of the plan's
# partition keys, those whose ROW_NUMBER (or RANK) over the sort keys is at
# most `k`, every row tied within `k` for RANK, with that number appended as
# an INT64 column when the plan's `PartitionTopNSinkData` names one. Order and
# ties are the window sink's: NULL partition keys are one partition, NULL sort
# keys last in both directions, and of rows tied at the k-th place ROW_NUMBER
# keeps the earliest, so the rows kept are the ones `rn <= k` over the window
# keeps.
#
# Collecting is `CollectSink`'s, as in `sink_window`: each worker keeps its
# morsels in its own slot and `combine` orders them by (partition id, origin
# hint), the source's position, before it concatenates them. The kernel keeps
# the earliest of tied rows in that order, so ROW_NUMBER keeps the same rows
# on every worker count. The kernel runs on the calling thread, in `combine`.
#
# Memory. The sink holds, at its peak, the morsels it collected, the one batch
# they are concatenated into, and what the kernel adds: a sorted copy of the
# rows and 16 bytes of working state per row. That estimate is drawn, before
# the kernel runs, from the segment pool:
#
#   * a worker draws the buffer bytes of each morsel when it consumes it, so
#     the consume that takes the collected input past the pool fails;
#   * at `combine` the sink draws the concatenation, then, once the workers'
#     morsels are gone, the kernel's estimate; when the kernel is done it
#     returns the estimate and draws the bytes of the output it keeps;
#   * the sink holds the output only, and returns it when the output is taken
#     and when the sink is dropped without a combine (a failed query).
#
# A denied draw fails the query by name; nothing is truncated. A segment that
# keeps no row (no input rows, or `k` = 0) has an output: a batch of no rows
# under `output_schema`.
#
# Refused when the sink is built, by name: a direction list whose length is not
# the sort keys', and a function that is neither ROW_NUMBER nor RANK.

from std.memory import ArcPointer

from arrow.schema import RecordBatch, Schema, SchemaBuilder
from column_kernels.compiler_helpers import (
    batch_buffer_bytes,
    empty_batch_like_schema,
)
from morsel.morsel import Morsel
from morsel.morsel_sink import MorselSinkImpl
from morsel.pipeline_execution import PipelineExecution
from op_window.partition_topn_sink import PartitionTopNSink
from physical_plan.physical_plan import PartitionTopNSinkData
from plan_expr.partition_expr import PF_RANK, PF_ROW_NUMBER

from .segment_pool import MEMORY_BUDGET_EXCEEDED, SegmentPool, WorkerReservation
from .sink_collect import CollectSink

# The bytes the kernel's per-row working state takes.
comptime _BYTES_PER_ROW: Int = 16


def _copy_data(ref data: PartitionTopNSinkData) -> PartitionTopNSinkData:
    """A deep copy of `data`, whose struct is movable only."""
    return PartitionTopNSinkData(
        data.partition_keys.copy(),
        data.sort_keys.copy(),
        data.descending.copy(),
        data.k,
        data.output_schema.copy(),
        func=data.func,
        over_fetch_k=data.over_fetch_k,
        output_rank_col_name=data.output_rank_col_name.copy(),
    )


def _rows_schema(ref data: PartitionTopNSinkData) raises -> Schema:
    """The columns the rows have before the sink: the output schema without
    the rank column, when it has one."""
    var keep = data.output_schema.num_columns()
    if data.output_rank_col_name:
        keep -= 1
    var sb = SchemaBuilder()
    for i in range(keep):
        sb.add_field(data.output_schema.field_at(i))
    return sb.build()


struct PartitionTopNPipelineSink(MorselSinkImpl):
    """Collects the rows of a segment and keeps the top rows of each
    partition."""

    var _seg_id: Int
    var _data: PartitionTopNSinkData
    var _pool: SegmentPool
    var _inner: CollectSink
    # One draw per worker, each behind its own ArcPointer in a List, as in
    # `sink_window`. A worker touches only the slot of its own task id.
    var _slots: List[ArcPointer[WorkerReservation]]
    var _work: WorkerReservation
    var _result: Optional[RecordBatch]

    def __init__(
        out self,
        ref data: PartitionTopNSinkData,
        var pool: SegmentPool,
        seg_id: Int,
    ) raises:
        var where_ = (
            "pipeline_exec: the partition top-n sink of segment "
            + String(seg_id)
        )
        if len(data.descending) != len(data.sort_keys):
            raise Error(
                where_
                + " lists "
                + String(len(data.descending))
                + " directions for "
                + String(len(data.sort_keys))
                + " sort keys"
            )
        if data.func != PF_ROW_NUMBER and data.func != PF_RANK:
            raise Error(
                where_
                + " numbers its rows with function "
                + String(Int(data.func))
                + "; only ROW_NUMBER and RANK are served"
            )
        self._seg_id = seg_id
        self._data = _copy_data(data)
        self._inner = CollectSink(Optional(_rows_schema(data)))
        self._work = WorkerReservation(pool.share())
        self._pool = pool^
        self._slots = List[ArcPointer[WorkerReservation]]()
        self._result = None

    def _denied(self, what: String, bytes: Int) -> Error:
        return Error(
            String(MEMORY_BUDGET_EXCEEDED)
            + ": pipeline_exec: the partition top-n sink of segment "
            + String(self._seg_id)
            + " was denied "
            + String(bytes)
            + " bytes for "
            + what
            + " (segment pool budget "
            + String(self._pool.budget())
            + ", granted "
            + String(self._pool.granted())
            + "); a partition top-n does not spill"
        )

    def resize_worker_state(mut self, num_workers: Int) -> None:
        self._inner.resize_worker_state(num_workers)
        self._slots = List[ArcPointer[WorkerReservation]](
            capacity=num_workers
        )
        for _ in range(num_workers):
            self._slots.append(
                ArcPointer[WorkerReservation](
                    WorkerReservation(self._pool.share())
                )
            )

    def consume(self, worker_id: Int, var morsel: Morsel) raises:
        if worker_id < 0 or worker_id >= len(self._slots):
            raise Error(
                "pipeline_exec: the partition top-n sink holds "
                + String(len(self._slots))
                + " worker slots, got worker "
                + String(worker_id)
            )
        var bytes = batch_buffer_bytes(morsel.batch)
        if not self._slots[worker_id][].try_grow(bytes):
            raise self._denied("a morsel it keeps", bytes)
        self._inner.consume(worker_id, morsel^)

    def combine(mut self, mut pipeline: PipelineExecution) raises -> None:
        var kept = 0
        for w in range(len(self._slots)):
            kept += self._slots[w][].used()
        # The concatenation is another batch the size of what was kept.
        if not self._work.try_grow(kept):
            raise self._denied("the concatenation", kept)
        self._inner.combine(pipeline)
        var rows = self._inner.take_output()
        for w in range(len(self._slots)):
            self._slots[w][].give_back_all()
        var extra = batch_buffer_bytes(rows) + _BYTES_PER_ROW * rows.num_rows()
        if not self._work.try_grow(extra):
            raise self._denied("the sorted copy and the kernel's state", extra)
        var kernel = PartitionTopNSink(_copy_data(self._data))
        kernel.consume(rows^)
        kernel.combine()
        var result = kernel.take_output()
        # The kernel answers a batch that keeps no row with a batch of no
        # columns; the segment's readers expect the declared columns.
        if result.num_rows() == 0:
            result = empty_batch_like_schema(self._data.output_schema)
        # Only the output is left. It is returned and drawn again, as in
        # `sink_window`: a refusal by name, and nothing leaks.
        self._work.give_back_all()
        var out_bytes = batch_buffer_bytes(result)
        if not self._work.try_grow(out_bytes):
            raise self._denied("the partition top-n output", out_bytes)
        self._result = Optional(result^)

    def finalize(mut self) raises:
        pass

    def take_output(mut self) raises -> RecordBatch:
        if not self._result:
            raise Error(
                "pipeline_exec: the partition top-n sink was read before it"
                " was combined"
            )
        var out = self._result.take()
        self._work.give_back_all()
        return out^
