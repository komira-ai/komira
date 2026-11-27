# =============================================================================
# agg_values -- the values MEDIAN and QUANTILE_CONT keep
# =============================================================================
#
# MEDIAN(x) is DuckDB's quantile_cont(x, 0.5), and QUANTILE_CONT(x, q) the
# value at the fraction q of the sorted non-NULL values of x, interpolated.
# Neither folds into a fixed cell: the three aggregation sinks keep every
# non-NULL value of such an aggregate beside their cells, here, and answer
# when the workers' values are merged.
#
# A worker's state is a `ValueSlot`: per aggregate, the worker group index and
# the value of every non-NULL row it folded, in two lists side by side. A
# value is kept as a double: a FLOAT64 as it is, a signed integer converted,
# which is the double DuckDB interpolates (it sorts the integers and converts
# the two it picks; the conversion keeps their order, so the two picked are
# the same values). A DECIMAL128 or a FLOAT32 (DuckDB's answer keeps the
# input's type there, not the DOUBLE the plan declares) and any other type
# are refused by `agg_fold.bind_column`, by name. The cell of the aggregate (`agg_fold`)
# still takes the column's type and counts the values, so a group with none is
# NULL as for any other aggregate.
#
# `combine` (`ValueMerge`) runs once after the workers joined. Each worker's
# values move under the merged group index of their worker group (the
# caller's `group_map`), and the worker's lists are freed. `finish` then sorts
# each group's values and writes the answer into the merged cell's `fvalue`:
#
#   n values, RN = (n - 1) * q, FRN = floor(RN), CRN = ceil(RN)
#   FRN == CRN   the value at FRN
#   otherwise    lo * (1 - d) + hi * d, lo and hi the values at FRN and CRN,
#                d = RN - FRN
#
# which is DuckDB's continuous interpolation, and is the mean of the two middle
# values for MEDIAN of an even count. The order is DuckDB's order of floats:
# NaN is above every other value, +inf included, and is counted, so a group
# whose upper half is NaN answers NaN.
#
# Memory is charged before it is used: 16 bytes a value to the worker's
# reservation as it is kept (the sink returns it once the worker is merged),
# 16 bytes a value to the merge's own reservation as it is moved, and 8 bytes
# a value more while `finish` sorts the values by group. A denial fails the
# query by name. The grouped sink with such an aggregate does not spill: its
# values are kept apart from the group table it would write.

from std.math import ceil, floor, nan

from arrow.arrow_types import ArrowType
from arrow.schema import RecordBatch
from plan_expr.agg_expr import (
    AGG_COUNT,
    AGG_MEDIAN,
    AGG_QUANTILE_CONT,
    AggExpr,
)

from .agg_fold import (
    AggCell,
    IN_FLOAT,
    SERVED_AGGREGATES,
    WideColumn,
    keeps_values,
    sink_serves,
)
from .segment_pool import MEMORY_BUDGET_EXCEEDED, SegmentPool, WorkerReservation

comptime VALUE_BYTES = 16
"""The bytes a kept value is charged: its group index and its double."""


def values_denied(
    ref where_: String, bytes: Int, ref pool: SegmentPool
) -> Error:
    """The refusal of a sink whose MEDIAN or QUANTILE_CONT values the pool
    denied."""
    return Error(
        String(MEMORY_BUDGET_EXCEEDED)
        + ": "
        + where_
        + " was denied "
        + String(bytes)
        + " bytes of the segment's memory pool for its MEDIAN and"
        " QUANTILE_CONT values (budget "
        + String(pool.budget())
        + ", granted "
        + String(pool.granted())
        + ")"
    )


def check_agg_args(
    ref agg: AggExpr, ref where_: String, ref label: String
) raises -> Float64:
    """Refuse by name, when a sink is built, an aggregate the sinks do not
    serve or one without the arguments it takes. The fraction of a MEDIAN
    (0.5) or a QUANTILE_CONT (its second argument, a FLOAT64 constant in
    [0, 1]); 0.0 for any other aggregate."""
    var func = agg.func
    if not sink_serves(func):
        raise Error(
            where_
            + " does not serve aggregate tag "
            + String(Int(func))
            + " ("
            + SERVED_AGGREGATES
            + ")"
        )
    if func == AGG_QUANTILE_CONT:
        if agg.num_children() != 2:
            raise Error(
                where_
                + ": "
                + label
                + " takes two arguments, a value and a constant fraction"
            )
        ref fraction = agg.child1.value()
        if not fraction.is_literal():
            raise Error(
                where_ + ": " + label + " takes a constant fraction, not an"
                " expression"
            )
        var v = fraction.literal_value()
        if not v.is_float():
            raise Error(
                where_ + ": " + label + " takes a FLOAT64 constant fraction"
            )
        var q = v.float_val
        if not (q >= 0.0 and q <= 1.0):
            raise Error(
                where_
                + ": "
                + label
                + ": QUANTILE can only take parameters in the range [0, 1]"
            )
        return q
    if agg.num_children() > 1:
        raise Error(where_ + ": " + label + " takes one argument")
    if not agg.child and func != AGG_COUNT:
        raise Error(where_ + ": " + label + " has no argument")
    if func == AGG_MEDIAN:
        return 0.5
    return 0.0


struct ValueSlot(Movable):
    """The kept values of a worker (or of the merge): per aggregate, the group
    index and the value of each, side by side."""

    var groups: List[List[Int]]
    var values: List[List[Float64]]

    def __init__(out self, n_aggs: Int):
        self.groups = List[List[Int]](capacity=n_aggs)
        self.values = List[List[Float64]](capacity=n_aggs)
        for _ in range(n_aggs):
            self.groups.append(List[Int]())
            self.values.append(List[Float64]())

    def count(self, agg: Int) -> Int:
        """The values kept for aggregate `agg`."""
        return len(self.values[agg])


def reserve_values(
    mut reservation: WorkerReservation,
    n: Int,
    ref where_: String,
    ref pool: SegmentPool,
) raises:
    """Charge `n` values to `reservation`, or fail the query by name."""
    var bytes = n * VALUE_BYTES
    if not reservation.try_grow(bytes):
        raise values_denied(where_, bytes, pool)


@always_inline
def keep_value(mut slot: ValueSlot, agg: Int, group: Int, value: Float64):
    """Keep `value` of group `group` for aggregate `agg`; charged by the
    caller."""
    slot.groups[agg].append(group)
    slot.values[agg].append(value)


def reserve_wide(
    mut reservation: WorkerReservation,
    ref w: WideColumn,
    rows: Int,
    ref where_: String,
    ref pool: SegmentPool,
) raises:
    """Charge the non-NULL values of the first `rows` rows of `w`."""
    var n = rows
    if len(w.valid) > 0:
        n = 0
        for r in range(rows):
            if w.valid[r]:
                n += 1
    reserve_values(reservation, n, where_, pool)


def keep_wide(mut slot: ValueSlot, agg: Int, group: Int, ref w: WideColumn, row: Int):
    """Keep row `row` of `w` under group `group` unless it is NULL; charged
    by the caller (`reserve_wide`)."""
    if len(w.valid) > 0 and not w.valid[row]:
        return
    if w.bind.kind == IN_FLOAT:
        keep_value(slot, agg, group, w.fvals[row])
    else:
        keep_value(slot, agg, group, w.vals[row].cast[DType.float64]())


def keep_column[
    dtype: DType
](
    mut slot: ValueSlot,
    agg: Int,
    group: Int,
    ref batch: RecordBatch,
    col_idx: Int,
    rows: Int,
):
    """Keep the non-NULL values of the first `rows` rows of column `col_idx`
    of `batch`, a column of `dtype`, under group `group`."""
    ref col = batch.column_at(col_idx)
    var arr = col.as_primitive[dtype]()
    var has_nulls = col.null_count() > 0
    for r in range(rows):
        if has_nulls and arr.is_null(r):
            continue
        keep_value(slot, agg, group, arr.get(r).cast[DType.float64]())


def keep_column_values(
    mut slot: ValueSlot,
    agg: Int,
    group: Int,
    ref batch: RecordBatch,
    col_idx: Int,
    rows: Int,
    mut reservation: WorkerReservation,
    ref where_: String,
    ref pool: SegmentPool,
) raises:
    """Charge and keep the non-NULL values of column `col_idx` (`rows` rows)
    under group `group`. The column was bound by `agg_fold.fold_column`, which
    refused any type but a signed integer and FLOAT64."""
    ref col = batch.column_at(col_idx)
    reserve_values(reservation, rows - col.null_count(), where_, pool)
    var at = col.arrow_type
    if at == ArrowType.FLOAT64:
        keep_column[DType.float64](slot, agg, group, batch, col_idx, rows)
    elif at == ArrowType.INT64:
        keep_column[DType.int64](slot, agg, group, batch, col_idx, rows)
    elif at == ArrowType.INT8:
        keep_column[DType.int8](slot, agg, group, batch, col_idx, rows)
    elif at == ArrowType.INT16:
        keep_column[DType.int16](slot, agg, group, batch, col_idx, rows)
    else:
        keep_column[DType.int32](slot, agg, group, batch, col_idx, rows)


def _value_at(ref sorted: List[Float64], i: Int) -> Float64:
    """The value at index `i` of the values in DuckDB's order of floats:
    `sorted` holds the values that are not NaN, sorted, and every index past
    them is a NaN."""
    if i < len(sorted):
        return sorted[i]
    return nan[DType.float64]()


def quantile_cont(var values: List[Float64], q: Float64) -> Float64:
    """DuckDB's quantile_cont of `values` (not empty) at the fraction `q`, in
    [0, 1]."""
    var n = len(values)
    var sorted = List[Float64](capacity=n)
    for i in range(n):
        if values[i] == values[i]:
            sorted.append(values[i])
    sort(sorted)
    var rn = Float64(n - 1) * q
    var frn = floor(rn)
    var crn = ceil(rn)
    var lo = _value_at(sorted, Int(frn))
    if frn == crn:
        return lo
    var hi = _value_at(sorted, Int(crn))
    var d = rn - frn
    return lo * (1.0 - d) + hi * d


struct ValueMerge(Movable):
    """The values of every worker, under the merged groups."""

    var slot: ValueSlot
    var reservation: WorkerReservation

    def __init__(out self, n_aggs: Int, var reservation: WorkerReservation):
        self.slot = ValueSlot(n_aggs)
        self.reservation = reservation^

    def merge_worker(
        mut self,
        mut worker: ValueSlot,
        ref group_map: List[Int],
        ref where_: String,
        ref pool: SegmentPool,
    ) raises:
        """Move the values of `worker` under the merged group of their worker
        group (`group_map`); the worker's lists are emptied."""
        for agg in range(len(worker.values)):
            var n = worker.count(agg)
            if n == 0:
                continue
            reserve_values(self.reservation, n, where_, pool)
            ref groups = worker.groups[agg]
            ref values = worker.values[agg]
            for k in range(n):
                keep_value(self.slot, agg, group_map[groups[k]], values[k])
            worker.groups[agg] = List[Int]()
            worker.values[agg] = List[Float64]()

    def finish(
        mut self,
        mut cells: List[AggCell],
        ref funcs: List[UInt8],
        ref fractions: List[Float64],
        n_groups: Int,
        ref where_: String,
        ref pool: SegmentPool,
    ) raises:
        """Write the answer of every MEDIAN and QUANTILE_CONT of every group
        into its cell (`cells[g * len(funcs) + agg]`), then free the values and
        return their memory."""
        var na = len(funcs)
        for agg in range(na):
            if not keeps_values(funcs[agg]):
                continue
            var n = self.slot.count(agg)
            if n == 0:
                continue
            # The values by group: a count per group, the start of each group,
            # then every value moved to its group's run.
            reserve_values(self.reservation, (n + 1) // 2, where_, pool)
            var starts = List[Int](capacity=n_groups + 1)
            for _ in range(n_groups + 1):
                starts.append(0)
            ref groups = self.slot.groups[agg]
            ref values = self.slot.values[agg]
            for k in range(n):
                starts[groups[k] + 1] += 1
            for g in range(n_groups):
                starts[g + 1] += starts[g]
            var next = starts.copy()
            var by_group = List[Float64](capacity=n)
            for _ in range(n):
                by_group.append(0.0)
            for k in range(n):
                var g = groups[k]
                by_group[next[g]] = values[k]
                next[g] += 1
            self.slot.groups[agg] = List[Int]()
            self.slot.values[agg] = List[Float64]()
            for g in range(n_groups):
                var lo = starts[g]
                var hi = starts[g + 1]
                if lo == hi:
                    continue
                var run = List[Float64](capacity=hi - lo)
                for k in range(lo, hi):
                    run.append(by_group[k])
                ref cell = cells[g * na + agg]
                cell.fvalue = quantile_cont(run^, fractions[agg])
                cell.count = hi - lo
        self.reservation.give_back_all()
