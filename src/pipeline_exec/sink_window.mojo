# =============================================================================
# sink_window -- (SINK_PARTITION_BY, KEY_DTYPE_NONE, SINK_ORIENT_COLUMNAR)
# =============================================================================
#
# The window functions of a segment: the rows are collected into one batch and
# `op_window`'s partition-scan kernel sorts them by the plan's partition keys
# and order keys (NULLs last in both directions) and appends one column per
# window expression. The output is the sorted input columns followed by those
# columns, under the `output_schema` of the plan's `PartitionBySinkData`.
#
# Collecting is `CollectSink`'s: each worker keeps its morsels in its own slot
# and `combine` orders them by (partition id, origin hint), the source's
# position, before it concatenates them. The kernel's sort is stable, so rows
# tied on every key come out in source position order, and ROW_NUMBER over such
# rows numbers them the same way on every worker count. `op_window`'s own sink
# (`PartitionBySink`) folds the workers' rows in worker order and is not used
# for that reason.
#
# The kernel runs on the calling thread, in `combine`. `op_window` has a
# parallel driver, but it needs a dispatcher and the sink trait gives `combine`
# none; a later slice that has the dispatch in hand can fan the sort out.
#
# Memory. The sink holds, at its peak, the morsels it collected, the one batch
# they are concatenated into, and what the kernel adds: a sorted copy of the
# rows, 16 bytes per row for each window expression, and, for a STRING value
# function (LAG, LEAD, FIRST_VALUE, LAST_VALUE, NTH_VALUE), the bytes of its
# argument column. That estimate is drawn, before the kernel runs, from the
# segment pool (the kernel's own scratch lists are not counted):
#
#   * a worker draws the buffer bytes of each morsel when it consumes it, so
#     the consume that takes the collected input past the pool fails;
#   * at `combine` the sink draws the concatenation, then, once the workers'
#     morsels are gone, the kernel's estimate; when the kernel is done it
#     returns the estimate and draws the bytes of the output it keeps;
#   * the sink holds the output only, and returns it when the output is taken
#     and when the sink is dropped without a combine (a failed query).
#
# A denied draw fails the query by name; nothing is truncated. A segment with
# no input rows has an output: a batch of no rows under `output_schema`.
#
# Refused when the sink is built, by name: a direction list whose length is not
# the order keys', and an output schema with fewer columns than there are
# window expressions. A kernel refusal (an aggregate over a type it does not
# serve, a key it cannot sort) surfaces from `combine` with the kernel's own
# message.

from std.memory import ArcPointer

from arrow.arrow_types import ArrowType
from arrow.schema import RecordBatch, Schema, SchemaBuilder
from column_kernels.compiler_helpers import (
    batch_buffer_bytes,
    column_buffer_bytes,
    empty_batch_like_schema,
)
from morsel.morsel import Morsel
from morsel.morsel_sink import MorselSinkImpl
from morsel.pipeline_execution import PipelineExecution
from op_window.partition_scan_sink import _execute_partition_by_sink
from physical_plan.physical_plan import PartitionBySinkData
from plan_expr.partition_expr import (
    PF_FIRST_VALUE,
    PF_LAG,
    PF_LAST_VALUE,
    PF_LEAD,
    PF_NTH_VALUE,
    PartitionExpr,
)

from .segment_pool import MEMORY_BUDGET_EXCEEDED, SegmentPool, WorkerReservation
from .sink_collect import CollectSink

# The bytes the kernel's per-row working state takes for one expression.
comptime _BYTES_PER_EXPR_ROW: Int = 16


def _copy_data(ref data: PartitionBySinkData) -> PartitionBySinkData:
    """A deep copy of `data`, whose struct is movable only."""
    var exprs = List[PartitionExpr]()
    for i in range(len(data.partition_exprs)):
        exprs.append(data.partition_exprs[i].copy())
    return PartitionBySinkData(
        data.partition_keys.copy(),
        data.order_keys.copy(),
        data.descending.copy(),
        exprs^,
        data.output_schema.copy(),
    )


def _child_schema(ref data: PartitionBySinkData) raises -> Schema:
    """The first columns of the output schema, the ones the rows had before
    the window columns."""
    var keep = data.output_schema.num_columns() - len(data.partition_exprs)
    var sb = SchemaBuilder()
    for i in range(keep):
        sb.add_field(data.output_schema.field_at(i))
    return sb.build()


def _is_value_fn(func: UInt8) -> Bool:
    return (
        func == PF_LAG
        or func == PF_LEAD
        or func == PF_FIRST_VALUE
        or func == PF_LAST_VALUE
        or func == PF_NTH_VALUE
    )


def _kernel_extra_bytes(
    ref data: PartitionBySinkData, ref rows: RecordBatch
) raises -> Int:
    """An estimate of what the kernel allocates on top of `rows`: a sorted
    copy, the per-row state of every expression and the argument column of a
    STRING value function."""
    var extra = batch_buffer_bytes(rows)
    extra += (
        len(data.partition_exprs) * _BYTES_PER_EXPR_ROW * rows.num_rows()
    )
    for i in range(len(data.partition_exprs)):
        ref expr = data.partition_exprs[i]
        if not _is_value_fn(expr.func):
            continue
        # A column the rows do not have is the kernel's refusal to make.
        try:
            var at = rows.schema.column_index(expr.column)
            if rows.schema.field_at(at).arrow_type == ArrowType.STRING:
                extra += column_buffer_bytes(rows, at)
        except:
            pass
    return extra


struct WindowSink(MorselSinkImpl):
    """Collects the rows of a segment and appends window columns to them."""

    var _seg_id: Int
    var _data: PartitionBySinkData
    var _pool: SegmentPool
    var _inner: CollectSink
    # One draw per worker, each behind its own ArcPointer in a List: a
    # reservation is heap-tracked state, never kept in a Slab mutated through
    # get_mut_interior. A worker touches only the slot of its own task id.
    var _slots: List[ArcPointer[WorkerReservation]]
    var _work: WorkerReservation
    var _result: Optional[RecordBatch]

    def __init__(
        out self,
        ref data: PartitionBySinkData,
        var pool: SegmentPool,
        seg_id: Int,
    ) raises:
        var where_ = (
            "pipeline_exec: the window sink of segment " + String(seg_id)
        )
        if len(data.descending) != len(data.order_keys):
            raise Error(
                where_
                + " lists "
                + String(len(data.descending))
                + " directions for "
                + String(len(data.order_keys))
                + " order keys"
            )
        if data.output_schema.num_columns() < len(data.partition_exprs):
            raise Error(
                where_
                + " has an output schema of "
                + String(data.output_schema.num_columns())
                + " columns for "
                + String(len(data.partition_exprs))
                + " window expressions"
            )
        self._seg_id = seg_id
        self._data = _copy_data(data)
        self._inner = CollectSink(Optional(_child_schema(data)))
        self._work = WorkerReservation(pool.share())
        self._pool = pool^
        self._slots = List[ArcPointer[WorkerReservation]]()
        self._result = None

    def _denied(self, what: String, bytes: Int) -> Error:
        return Error(
            String(MEMORY_BUDGET_EXCEEDED)
            + ": pipeline_exec: the window sink of segment "
            + String(self._seg_id)
            + " was denied "
            + String(bytes)
            + " bytes for "
            + what
            + " (segment pool budget "
            + String(self._pool.budget())
            + ", granted "
            + String(self._pool.granted())
            + "); window functions do not spill"
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
                "pipeline_exec: the window sink holds "
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
        if rows.num_rows() == 0:
            self._work.give_back_all()
            self._result = Optional(
                empty_batch_like_schema(self._data.output_schema)
            )
            return
        var extra = _kernel_extra_bytes(self._data, rows)
        if not self._work.try_grow(extra):
            raise self._denied("the sorted copy and the window columns", extra)
        var result = _execute_partition_by_sink(rows^, self._data)
        # Only the output is left. It is returned and drawn again, not carried
        # over: against a pool that other segments filled in the gap the draw
        # can be refused. That is a refusal by name and nothing leaks (the sink
        # returns what it holds when it is dropped).
        self._work.give_back_all()
        var out_bytes = batch_buffer_bytes(result)
        if not self._work.try_grow(out_bytes):
            raise self._denied("the window output", out_bytes)
        self._result = Optional(result^)

    def finalize(mut self) raises:
        pass

    def take_output(mut self) raises -> RecordBatch:
        if not self._result:
            raise Error(
                "pipeline_exec: the window sink was read before it was"
                " combined"
            )
        var out = self._result.take()
        self._work.give_back_all()
        return out^
