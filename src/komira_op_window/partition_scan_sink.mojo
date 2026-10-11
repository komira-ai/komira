# =============================================================================
# partition_scan_sink -- the window operator over one batch
# =============================================================================
#
# `_execute_partition_by_sink` runs a `PartitionBySinkData`
# (`komira_physical_plan`) over one accumulated batch:
#
#   1. sort the batch by (partition keys ++ order keys)
#      (`partition_keys.sort_partition_batch`: NULLs last, floats by
#      `sort_key_lt`, dictionaries by value);
#   2. find the partition starts (`_detect_partition_boundaries`);
#   3. evaluate each `PartitionExpr` into one new column;
#   4. emit the input columns, in sorted order, followed by the new columns.
#
# The output is in (partition keys ASC ++ order keys per direction) order,
# which the plan's window rewrite relies on to drop a Sort above the window
# (`komira_exec_types.partition_by_output_contract`). A float ORDER BY key
# column is emitted with each -0.0 written as 0.0, as DuckDB returns a sorted
# float key (docs/design/query_semantics.md §4.9).
#
# The kernels per function: ranking and running aggregates in
# `partition_scan_kernels`, value functions in `partition_value_fns`, every
# other aggregate frame in `partition_sliding_frame`.
# =============================================================================

from komira_arrow.arrow_types import ArrowType
from komira_arrow.column import Column
from komira_arrow.copy_column_ref import copy_column_ref
from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.record_batch import RecordBatch, RecordBatchBuilder
from komira_arrow.schema import SchemaBuilder
from komira_buffer.heap_region import HeapRegion
from komira_physical_plan.physical_plan import PartitionBySinkData
from komira_plan_expr.partition_expr import (
    FRAME_UNITS_RANGE,
    PF_AVG,
    PF_COUNT,
    PF_CUME_DIST,
    PF_DENSE_RANK,
    PF_FIRST_VALUE,
    PF_LAG,
    PF_LAST_VALUE,
    PF_LEAD,
    PF_MAX,
    PF_MIN,
    PF_NTH_VALUE,
    PF_NTILE,
    PF_PERCENT_RANK,
    PF_RANK,
    PF_ROW_NUMBER,
    PF_SUM,
    PartitionExpr,
)

from .partition_keys import (
    _detect_partition_boundaries,
    _peer_bounds,
    sort_partition_batch,
)
from .partition_scan_kernels import (
    _eval_cume_dist,
    _eval_dense_rank,
    _eval_ntile,
    _eval_percent_rank,
    _eval_rank,
    _eval_row_number,
    _eval_running_avg,
    _eval_running_count,
    _eval_running_max_f64,
    _eval_running_max_i64,
    _eval_running_min_f64,
    _eval_running_min_i64,
    _eval_running_sum_f64,
    _eval_running_sum_i64,
)
from .partition_sliding_frame import eval_sliding_agg
from .partition_value_fns import eval_value_fn


# =============================================================================
# Output columns
# =============================================================================


def _clone_column(col: Column[HeapRegion]) raises -> Column[HeapRegion]:
    """Copy one input column into the window's output batch.

    The window keeps every input column, so this must copy every layout the
    input can carry; it delegates to `copy_column_ref`, the engine's general
    column copy (offset-rebased, validity-preserving). A DICTIONARY column is
    cloned by `dict_clone`, which resolves a numeric dictionary to its flat
    values.
    """
    if col.arrow_type == ArrowType.DICTIONARY:
        return col.dict_clone()
    return copy_column_ref(col, col.length())


def _clone_order_key_column(col: Column[HeapRegion]) raises -> Column[HeapRegion]:
    """`_clone_column` for an ORDER BY key: a FLOAT64 / FLOAT32 key comes back
    with each -0.0 as 0.0 (§4.9). Every other value, NaN payloads included,
    is unchanged."""
    if col.arrow_type == ArrowType.FLOAT64:
        var arr = col.as_primitive[DType.float64]()
        for r in range(arr.length):
            var v = arr.get(r)
            if v == 0.0:
                arr.store[1](r, Float64(0.0))
        return Column.from_primitive[DType.float64](arr)
    elif col.arrow_type == ArrowType.FLOAT32:
        var arr32 = col.as_primitive[DType.float32]()
        for r in range(arr32.length):
            var v32 = arr32.get(r)
            if v32 == 0.0:
                arr32.store[1](r, Float32(0.0))
        return Column.from_primitive[DType.float32](arr32)
    return _clone_column(col)


# =============================================================================
# RANGE peer closure: `CURRENT ROW` is the peer group's last row
# =============================================================================
#
# The batch is sorted by (partition keys ++ order keys), so a peer group is
# contiguous. Under `RANGE BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW` every
# member of a peer group frames over `[partition_start, peer_end)`, exactly the
# prefix the ROWS running kernel aggregated at the group's LAST row. So the
# RANGE answer of every member is the ROWS answer at the last member: an index
# relabel of the running kernel's output, value and validity bit together (a
# NULL result broadcasts as NULL).
#
# The parallel drivers slice the sorted batch at whole partitions, and a peer
# group lies inside one partition, so the closure is slice-local.


def _broadcast_peer_last[
    dt: DType
](
    src: Column[HeapRegion],
    peer: List[Int],
    n: Int,
) raises -> Column[HeapRegion]:
    """Rewrite `src` so every row of a peer group carries the group's last
    cell, value and validity bit. Nullable iff `src` is."""
    var arr: PrimitiveArray[dt]
    var nullable = Bool(src._validity)
    if nullable:
        arr = PrimitiveArray[dt].allocate_nullable(n)
    else:
        arr = PrimitiveArray[dt].allocate(n)
    for gi in range(len(peer)):
        var s = peer[gi]
        var e = n
        if gi + 1 < len(peer):
            e = peer[gi + 1]
        var last = e - 1
        var v = src._data.get_typed[Scalar[dt]](src._offset + last)
        var is_null = nullable and src.is_null_at(last)
        for row in range(s, e):
            arr.store[1](row, v)
            if is_null:
                arr._set_null(row)
    return Column.from_primitive[dt](arr)


def _close_over_peers(
    batch: RecordBatch,
    bounds: List[Int],
    order_keys: List[String],
    var running: Column[HeapRegion],
) raises -> Column[HeapRegion]:
    """Turn a ROWS running-aggregate column into the RANGE one."""
    var n = batch.num_rows()
    if n == 0:
        return running^
    var peer = _peer_bounds(batch, bounds, order_keys)
    if running.arrow_type == ArrowType.INT64:
        return _broadcast_peer_last[DType.int64](running, peer, n)
    elif running.arrow_type == ArrowType.FLOAT64:
        return _broadcast_peer_last[DType.float64](running, peer, n)
    raise Error(
        "partition_scan_sink: RANGE peer closure unsupported output type "
        + String(running.arrow_type)
    )


# =============================================================================
# Dispatch: one PartitionExpr to its kernel
# =============================================================================


def _eval_running_agg(
    batch: RecordBatch,
    bounds: List[Int],
    expr: PartitionExpr,
) raises -> Column[HeapRegion]:
    """The running (ROWS UNBOUNDED PRECEDING .. CURRENT ROW) aggregate
    kernels, by function and argument type. COUNT passes its column: an
    empty name is `COUNT(*)`."""
    if expr.func == PF_COUNT:
        return _eval_running_count(batch, bounds, expr.column)
    elif expr.func == PF_AVG:
        return _eval_running_avg(batch, bounds, expr.column)
    ref col = batch.column_at(batch.schema.column_index(expr.column))
    var is_i64 = col.arrow_type == ArrowType.INT64
    var is_f64 = col.arrow_type == ArrowType.FLOAT64
    if not (is_i64 or is_f64):
        raise Error(
            "partition_scan_sink: running aggregate unsupported type "
            + String(col.arrow_type)
        )
    if expr.func == PF_SUM:
        if is_i64:
            return _eval_running_sum_i64(batch, bounds, expr.column)
        return _eval_running_sum_f64(batch, bounds, expr.column)
    elif expr.func == PF_MIN:
        if is_i64:
            return _eval_running_min_i64(batch, bounds, expr.column)
        return _eval_running_min_f64(batch, bounds, expr.column)
    elif expr.func == PF_MAX:
        if is_i64:
            return _eval_running_max_i64(batch, bounds, expr.column)
        return _eval_running_max_f64(batch, bounds, expr.column)
    raise Error(
        "partition_scan_sink: not a running aggregate " + String(Int(expr.func))
    )


def _eval_partition_expr(
    batch: RecordBatch,
    bounds: List[Int],
    order_keys: List[String],
    descending: List[Bool],
    expr: PartitionExpr,
) raises -> Column[HeapRegion]:
    """Evaluate one PartitionExpr against a sorted batch."""
    if expr.func == PF_ROW_NUMBER:
        return _eval_row_number(batch, bounds)
    elif expr.func == PF_RANK:
        return _eval_rank(batch, bounds, order_keys)
    elif expr.func == PF_DENSE_RANK:
        return _eval_dense_rank(batch, bounds, order_keys)
    elif expr.func == PF_PERCENT_RANK:
        return _eval_percent_rank(batch, bounds, order_keys)
    elif expr.func == PF_CUME_DIST:
        return _eval_cume_dist(batch, bounds, order_keys)
    elif expr.func == PF_NTILE:
        return _eval_ntile(batch, bounds, expr.offset)
    elif (
        expr.func == PF_LAG
        or expr.func == PF_LEAD
        or expr.func == PF_FIRST_VALUE
        or expr.func == PF_LAST_VALUE
        or expr.func == PF_NTH_VALUE
    ):
        return eval_value_fn(batch, bounds, order_keys, descending, expr)
    elif (
        expr.func == PF_SUM
        or expr.func == PF_COUNT
        or expr.func == PF_AVG
        or expr.func == PF_MIN
        or expr.func == PF_MAX
    ):
        # Only the running frame takes the per-row incremental kernels; every
        # other frame (bounded, and the whole partition) is the frame
        # evaluator's. The gate is `is_running()`, not `not is_sliding()`:
        # the whole partition is neither running nor sliding.
        if not expr.frame.is_running():
            return eval_sliding_agg(batch, bounds, order_keys, descending, expr)
        var running = _eval_running_agg(batch, bounds, expr)
        # `is_running()` does not look at the units. Under RANGE (SQL's
        # default frame for an ordered window) CURRENT ROW is the last peer,
        # so the running column needs the peer closure.
        if expr.frame.units != FRAME_UNITS_RANGE:
            return running^
        return _close_over_peers(batch, bounds, order_keys, running^)
    raise Error(
        "partition_scan_sink: unknown partition function " + String(Int(expr.func))
    )


# =============================================================================
# The driver
# =============================================================================


def _empty_output(sink_data: PartitionBySinkData) raises -> RecordBatch:
    """A zero-row batch of the sink's output schema."""
    var sb = SchemaBuilder()
    for i in range(sink_data.output_schema.num_columns()):
        sb.add_field(sink_data.output_schema.field_at(i))
    return RecordBatch.empty_from_schema(sb.build())


def _eval_sorted(
    sorted_batch: RecordBatch,
    sink_data: PartitionBySinkData,
) raises -> RecordBatch:
    """Steps 2-4 over a batch already sorted by (partition keys ++ order
    keys): find the partitions, evaluate every expression, emit the input
    columns followed by the new ones. The parallel drivers call this on each
    whole-partition slice."""
    var bounds = _detect_partition_boundaries(sorted_batch, sink_data.partition_keys)

    var order_cols = List[Int]()
    for k in sink_data.order_keys:
        order_cols.append(sorted_batch.schema.column_index(k))

    var builder = RecordBatchBuilder()
    for i in range(sorted_batch.num_columns()):
        var is_order_key = False
        for j in range(len(order_cols)):
            if order_cols[j] == i:
                is_order_key = True
                break
        ref col = sorted_batch.column_at(i)
        if is_order_key:
            builder.add_column(_clone_order_key_column(col))
        else:
            builder.add_column(_clone_column(col))

    for i in range(len(sink_data.partition_exprs)):
        var new_col = _eval_partition_expr(
            sorted_batch, bounds, sink_data.order_keys, sink_data.descending,
            sink_data.partition_exprs[i],
        )
        builder.add_column(new_col^)

    var out_sb = SchemaBuilder()
    for i in range(sink_data.output_schema.num_columns()):
        out_sb.add_field(sink_data.output_schema.field_at(i))
    return builder.build(out_sb.build())


def _execute_partition_by_sink(
    var batch: RecordBatch,
    sink_data: PartitionBySinkData,
) raises -> RecordBatch:
    """Run a PartitionBy sink over one batch: sort, find partitions, evaluate
    every expression, emit the sorted input columns and the new columns.

    PERF-CRITICAL: the single-thread kernel. The parallel drivers fall back
    to it below their thresholds and run its steps 2-4 per slice.
    """
    if batch.num_rows() == 0:
        return _empty_output(sink_data)
    var sorted_batch = sort_partition_batch(
        batch^, sink_data.partition_keys, sink_data.order_keys, sink_data.descending
    )
    return _eval_sorted(sorted_batch, sink_data)
