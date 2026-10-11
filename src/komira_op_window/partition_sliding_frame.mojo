# =============================================================================
# partition_sliding_frame -- window aggregates over a bounded frame or the
# whole partition
# =============================================================================
#
# SUM / COUNT / AVG / MIN / MAX over any frame other than the running one
# (which `partition_scan_kernels` folds). The frame of every row is resolved
# once by `partition_frame_index.frame_index` into `[lo, hi)` row indices; the
# kernels here never see a bound.
#
# SUM, COUNT and AVG are invertible, so the frame is a two-pointer window over
# the partition: as `[lo, hi)` advances, the rows leaving at the back are
# removed and the rows entering at the front are added, O(rows) per partition.
# When the frame jumps past everything it held (`1 FOLLOWING .. 2 FOLLOWING`
# on a partition's first row), the rows it removes and never added are the
# rows it adds again, so the two cancel.
#
# A FLOAT64 sum cannot remove an infinity or a NaN by subtraction (inf - inf
# is NaN), so the window keeps the finite part of its sum and counts its +inf,
# -inf and NaN values apart (`_F64Window`); the frame's sum is NaN if it holds
# a NaN or both infinities, the infinity if it holds one kind, else the
# finite sum.
#
# MIN and MAX are not invertible and rescan the frame per row, O(rows x
# width). Float MIN / MAX use DuckDB's order (NaN above every number, §2.7).
#
# The whole partition (`UNBOUNDED PRECEDING .. UNBOUNDED FOLLOWING`, in ROWS or
# RANGE) is computed once per partition and broadcast, O(rows) for every
# function, MIN / MAX included.
#
# An INT64 SUM / AVG accumulates exactly, in 128 bits: a SUM whose total
# leaves INT64 raises rather than wrapping (query_semantics_types.md §8.1), an
# AVG divides the exact total once (§2.12).
#
# NULLs follow `partition_null_policy`: every kernel skips NULL cells and
# answers NULL for a frame with no surviving value; a framed output is
# nullable iff the input carries NULLs or some frame is empty.
# =============================================================================

from std.math import inf, isinf, isnan

from komira_arrow.arrow_types import ArrowType
from komira_arrow.column import Column
from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.record_batch import RecordBatch
from komira_buffer.heap_region import HeapRegion
from komira_op_sort.sort import sort_key_lt
from komira_plan_expr.partition_expr import (
    PF_AVG,
    PF_COUNT,
    PF_MAX,
    PF_MIN,
    PF_SUM,
    PartitionExpr,
)

from .partition_frame_index import frame_index
from .partition_keys import _segment_ends
from .partition_null_policy import (
    AggF64,
    AggI128,
    AggI64,
    I128,
    alloc_frame_out_f64,
    alloc_frame_out_i64,
    alloc_out_f64,
    alloc_out_i64,
    cell_is_null,
    count_is_star,
    i64_mean,
    i64_sum_result,
    store_f64_or_null,
    store_i64_or_null,
)


# =============================================================================
# Loads and per-frame reducers
# =============================================================================


@always_inline
def _load_i64(col: Column[HeapRegion], r: Int) -> Int64:
    # PERF-CRITICAL: the two-pointer SUM / AVG path loads one element per add
    # and per remove; this inlines to one typed load.
    return Int64(col._data.get_typed[Scalar[DType.int64]](col._offset + r))


@always_inline
def _load_f64(col: Column[HeapRegion], r: Int) -> Float64:
    # PERF-CRITICAL: see _load_i64.
    return Float64(col._data.get_typed[Scalar[DType.float64]](col._offset + r))


@always_inline
def _frame_sum_i64(col: Column[HeapRegion], lo: Int, hi: Int) -> AggI128:
    var nulls = col.has_validity_buffer()
    var total = I128(0)
    var cnt = 0
    for r in range(lo, hi):
        if nulls and cell_is_null(col, r):
            continue
        total += I128(_load_i64(col, r))
        cnt += 1
    return AggI128(total, cnt)


@always_inline
def _frame_sum_f64(col: Column[HeapRegion], lo: Int, hi: Int) -> AggF64:
    var nulls = col.has_validity_buffer()
    var total: Float64 = 0.0
    var cnt = 0
    for r in range(lo, hi):
        if nulls and cell_is_null(col, r):
            continue
        total += _load_f64(col, r)
        cnt += 1
    return AggF64(total, cnt)


@always_inline
def _frame_extreme_i64[is_min: Bool](col: Column[HeapRegion], lo: Int, hi: Int) -> AggI64:
    var nulls = col.has_validity_buffer()
    var cnt = 0
    var best: Int64 = 0
    for r in range(lo, hi):
        if nulls and cell_is_null(col, r):
            continue
        var v = _load_i64(col, r)
        comptime if is_min:
            if cnt == 0 or v < best:
                best = v
        else:
            if cnt == 0 or v > best:
                best = v
        cnt += 1
    return AggI64(best, cnt)


@always_inline
def _frame_extreme_f64[is_min: Bool](col: Column[HeapRegion], lo: Int, hi: Int) -> AggF64:
    """MIN / MAX of a FLOAT64 frame in DuckDB's order: NaN above every
    number."""
    var nulls = col.has_validity_buffer()
    var cnt = 0
    var best: Float64 = 0.0
    for r in range(lo, hi):
        if nulls and cell_is_null(col, r):
            continue
        var v = _load_f64(col, r)
        comptime if is_min:
            if cnt == 0 or sort_key_lt[DType.float64](v, best):
                best = v
        else:
            if cnt == 0 or sort_key_lt[DType.float64](best, v):
                best = v
        cnt += 1
    return AggF64(best, cnt)


struct _F64Window(Movable):
    """The running state of a FLOAT64 sum over a sliding window: the sum of
    its finite values, its non-NULL count, and how many +inf, -inf and NaN
    values it holds. Removing a value undoes adding it, which a plain float
    sum cannot do for a non-finite value."""

    var finite: Float64
    var cnt: Int
    var n_nan: Int
    var n_pinf: Int
    var n_ninf: Int

    def __init__(out self):
        self.finite = 0.0
        self.cnt = 0
        self.n_nan = 0
        self.n_pinf = 0
        self.n_ninf = 0

    @always_inline
    def reset(mut self):
        self.finite = 0.0
        self.cnt = 0
        self.n_nan = 0
        self.n_pinf = 0
        self.n_ninf = 0

    @always_inline
    def add(mut self, v: Float64):
        self.cnt += 1
        if isnan(v):
            self.n_nan += 1
        elif isinf(v):
            if v > 0:
                self.n_pinf += 1
            else:
                self.n_ninf += 1
        else:
            self.finite += v

    @always_inline
    def remove(mut self, v: Float64):
        self.cnt -= 1
        if isnan(v):
            self.n_nan -= 1
        elif isinf(v):
            if v > 0:
                self.n_pinf -= 1
            else:
                self.n_ninf -= 1
        else:
            self.finite -= v

    @always_inline
    def sum(self) -> Float64:
        if self.n_nan > 0 or (self.n_pinf > 0 and self.n_ninf > 0):
            return Float64(0.0) / Float64(0.0)
        if self.n_pinf > 0:
            return inf[DType.float64]()
        if self.n_ninf > 0:
            return -inf[DType.float64]()
        if self.cnt == 0:
            return 0.0
        return self.finite


# =============================================================================
# Sliding-frame kernels (frames given as `[lo, hi)` per row)
# =============================================================================


def eval_sliding_sum(
    batch: RecordBatch, bounds: List[Int], col_name: String, lo_idx: List[Int], hi_idx: List[Int],
) raises -> Column[HeapRegion]:
    """SUM over a sliding frame, O(rows) per partition (two-pointer window).
    The non-NULL count rides the same window: a frame with no non-NULL value
    sums to NULL."""
    var n = batch.num_rows()
    var ends = _segment_ends(bounds, n)
    ref col = batch.column_at(batch.schema.column_index(col_name))
    var nulls = col.has_validity_buffer()

    if col.arrow_type == ArrowType.INT64:
        var arr = alloc_frame_out_i64(n, nulls, lo_idx, hi_idx)
        for p in range(len(bounds)):
            var cur_lo = bounds[p]
            var cur_hi = bounds[p]
            var total = I128(0)
            var cnt = 0
            for row in range(bounds[p], ends[p]):
                var new_lo = lo_idx[row]
                var new_hi = hi_idx[row]
                for r in range(cur_lo, new_lo):
                    if nulls and cell_is_null(col, r):
                        continue
                    total -= I128(_load_i64(col, r))
                    cnt -= 1
                for r in range(cur_hi, new_hi):
                    if nulls and cell_is_null(col, r):
                        continue
                    total += I128(_load_i64(col, r))
                    cnt += 1
                cur_lo = new_lo
                cur_hi = new_hi
                if cnt == 0:
                    store_i64_or_null(arr, row, Int64(0), 0)
                else:
                    store_i64_or_null(arr, row, i64_sum_result(total), cnt)
        return Column.from_primitive[DType.int64](arr)
    elif col.arrow_type == ArrowType.FLOAT64:
        var arr = alloc_frame_out_f64(n, nulls, lo_idx, hi_idx)
        var win = _F64Window()
        for p in range(len(bounds)):
            var cur_lo = bounds[p]
            var cur_hi = bounds[p]
            win.reset()
            for row in range(bounds[p], ends[p]):
                var new_lo = lo_idx[row]
                var new_hi = hi_idx[row]
                for r in range(cur_lo, new_lo):
                    if nulls and cell_is_null(col, r):
                        continue
                    win.remove(_load_f64(col, r))
                for r in range(cur_hi, new_hi):
                    if nulls and cell_is_null(col, r):
                        continue
                    win.add(_load_f64(col, r))
                cur_lo = new_lo
                cur_hi = new_hi
                store_f64_or_null(arr, row, win.sum(), win.cnt)
        return Column.from_primitive[DType.float64](arr)
    raise Error("partition_sliding_frame: SUM unsupported type " + String(col.arrow_type))


def eval_sliding_count(
    batch: RecordBatch, bounds: List[Int], col_name: String, lo_idx: List[Int], hi_idx: List[Int],
) raises -> Column[HeapRegion]:
    """COUNT over a sliding frame: `COUNT(*)` is the frame width,
    `COUNT(<col>)` the non-NULL cells in it (on the two-pointer window).
    Never NULL: an empty frame counts 0, so the output has no bitmap."""
    var n = batch.num_rows()
    var ends = _segment_ends(bounds, n)
    var arr = alloc_out_i64(n, False)

    if count_is_star(col_name):
        for row in range(n):
            var w = hi_idx[row] - lo_idx[row]
            arr.store[1](row, Int64(w if w > 0 else 0))
        return Column.from_primitive[DType.int64](arr)

    ref col = batch.column_at(batch.schema.column_index(col_name))
    var nulls = col.has_validity_buffer()
    for p in range(len(bounds)):
        var cur_lo = bounds[p]
        var cur_hi = bounds[p]
        var cnt: Int64 = 0
        for row in range(bounds[p], ends[p]):
            var new_lo = lo_idx[row]
            var new_hi = hi_idx[row]
            for r in range(cur_lo, new_lo):
                if not (nulls and cell_is_null(col, r)):
                    cnt -= 1
            for r in range(cur_hi, new_hi):
                if not (nulls and cell_is_null(col, r)):
                    cnt += 1
            cur_lo = new_lo
            cur_hi = new_hi
            arr.store[1](row, cnt)
    return Column.from_primitive[DType.int64](arr)


def eval_sliding_avg(
    batch: RecordBatch, bounds: List[Int], col_name: String, lo_idx: List[Int], hi_idx: List[Int],
) raises -> Column[HeapRegion]:
    """AVG over a sliding frame, always FLOAT64: the two-pointer SUM divided
    by the non-NULL count of the same window."""
    var n = batch.num_rows()
    var ends = _segment_ends(bounds, n)
    ref col = batch.column_at(batch.schema.column_index(col_name))
    var nulls = col.has_validity_buffer()
    var arr = alloc_frame_out_f64(n, nulls, lo_idx, hi_idx)

    if col.arrow_type == ArrowType.INT64:
        for p in range(len(bounds)):
            var cur_lo = bounds[p]
            var cur_hi = bounds[p]
            var total_i = I128(0)
            var cnt = 0
            for row in range(bounds[p], ends[p]):
                var new_lo = lo_idx[row]
                var new_hi = hi_idx[row]
                for r in range(cur_lo, new_lo):
                    if nulls and cell_is_null(col, r):
                        continue
                    total_i -= I128(_load_i64(col, r))
                    cnt -= 1
                for r in range(cur_hi, new_hi):
                    if nulls and cell_is_null(col, r):
                        continue
                    total_i += I128(_load_i64(col, r))
                    cnt += 1
                cur_lo = new_lo
                cur_hi = new_hi
                var mean: Float64 = 0.0
                if cnt > 0:
                    mean = i64_mean(total_i, cnt)
                store_f64_or_null(arr, row, mean, cnt)
    elif col.arrow_type == ArrowType.FLOAT64:
        var win = _F64Window()
        for p in range(len(bounds)):
            var cur_lo = bounds[p]
            var cur_hi = bounds[p]
            win.reset()
            for row in range(bounds[p], ends[p]):
                var new_lo = lo_idx[row]
                var new_hi = hi_idx[row]
                for r in range(cur_lo, new_lo):
                    if nulls and cell_is_null(col, r):
                        continue
                    win.remove(_load_f64(col, r))
                for r in range(cur_hi, new_hi):
                    if nulls and cell_is_null(col, r):
                        continue
                    win.add(_load_f64(col, r))
                cur_lo = new_lo
                cur_hi = new_hi
                var meanf: Float64 = 0.0
                if win.cnt > 0:
                    meanf = win.sum() / Float64(win.cnt)
                store_f64_or_null(arr, row, meanf, win.cnt)
    else:
        raise Error("partition_sliding_frame: AVG unsupported type " + String(col.arrow_type))
    return Column.from_primitive[DType.float64](arr)


def eval_sliding_extreme[
    is_min: Bool
](
    batch: RecordBatch, bounds: List[Int], col_name: String, lo_idx: List[Int], hi_idx: List[Int],
) raises -> Column[HeapRegion]:
    """MIN (`is_min`) or MAX over a sliding frame: a rescan of each row's
    frame. An empty frame and an all-NULL frame both answer NULL."""
    var n = batch.num_rows()
    ref col = batch.column_at(batch.schema.column_index(col_name))
    var nulls = col.has_validity_buffer()
    if col.arrow_type == ArrowType.INT64:
        var arr = alloc_frame_out_i64(n, nulls, lo_idx, hi_idx)
        for row in range(n):
            var ai = _frame_extreme_i64[is_min](col, lo_idx[row], hi_idx[row])
            store_i64_or_null(arr, row, ai.value, ai.count)
        return Column.from_primitive[DType.int64](arr)
    elif col.arrow_type == ArrowType.FLOAT64:
        var arr = alloc_frame_out_f64(n, nulls, lo_idx, hi_idx)
        for row in range(n):
            var af = _frame_extreme_f64[is_min](col, lo_idx[row], hi_idx[row])
            store_f64_or_null(arr, row, af.value, af.count)
        return Column.from_primitive[DType.float64](arr)
    raise Error(
        "partition_sliding_frame: MIN / MAX unsupported type "
        + String(col.arrow_type)
    )


# =============================================================================
# The whole partition
# =============================================================================


def eval_full_partition_agg(
    batch: RecordBatch, bounds: List[Int], expr: PartitionExpr,
) raises -> Column[HeapRegion]:
    """Aggregate over the whole partition, broadcast to every row of it.

    A partition is never empty, so `count == 0` here means every cell was
    NULL, which needs a bitmap on the input: the one-term `alloc_out_*`
    predicate is the whole answer.
    """
    var n = batch.num_rows()
    var ends = _segment_ends(bounds, n)

    if expr.func == PF_COUNT:
        var arr_c = alloc_out_i64(n, False)
        if count_is_star(expr.column):
            for p in range(len(bounds)):
                var w = Int64(ends[p] - bounds[p])
                for row in range(bounds[p], ends[p]):
                    arr_c.store[1](row, w)
            return Column.from_primitive[DType.int64](arr_c)
        ref cnt_col = batch.column_at(batch.schema.column_index(expr.column))
        var cnt_nulls = cnt_col.has_validity_buffer()
        for p in range(len(bounds)):
            var live: Int64 = 0
            for r in range(bounds[p], ends[p]):
                if not (cnt_nulls and cell_is_null(cnt_col, r)):
                    live += 1
            for row in range(bounds[p], ends[p]):
                arr_c.store[1](row, live)
        return Column.from_primitive[DType.int64](arr_c)

    ref col = batch.column_at(batch.schema.column_index(expr.column))
    var nulls = col.has_validity_buffer()

    if expr.func == PF_AVG:
        var arr_a = alloc_out_f64(n, nulls)
        for p in range(len(bounds)):
            var mean: Float64 = 0.0
            var live = 0
            if col.arrow_type == ArrowType.INT64:
                var ai = _frame_sum_i64(col, bounds[p], ends[p])
                live = ai.count
                if live > 0:
                    mean = i64_mean(ai.value, live)
            elif col.arrow_type == ArrowType.FLOAT64:
                var af = _frame_sum_f64(col, bounds[p], ends[p])
                live = af.count
                if live > 0:
                    mean = af.value / Float64(live)
            else:
                raise Error(
                    "partition_sliding_frame: AVG unsupported type "
                    + String(col.arrow_type)
                )
            for row in range(bounds[p], ends[p]):
                store_f64_or_null(arr_a, row, mean, live)
        return Column.from_primitive[DType.float64](arr_a)

    if col.arrow_type == ArrowType.INT64:
        var arr_i = alloc_out_i64(n, nulls)
        for p in range(len(bounds)):
            var agg: AggI64
            if expr.func == PF_SUM:
                var s = _frame_sum_i64(col, bounds[p], ends[p])
                var v = Int64(0)
                if s.count > 0:
                    v = i64_sum_result(s.value)
                agg = AggI64(v, s.count)
            elif expr.func == PF_MIN:
                agg = _frame_extreme_i64[True](col, bounds[p], ends[p])
            elif expr.func == PF_MAX:
                agg = _frame_extreme_i64[False](col, bounds[p], ends[p])
            else:
                raise Error(
                    "partition_sliding_frame: unsupported aggregate "
                    + String(Int(expr.func))
                )
            for row in range(bounds[p], ends[p]):
                store_i64_or_null(arr_i, row, agg.value, agg.count)
        return Column.from_primitive[DType.int64](arr_i)
    elif col.arrow_type == ArrowType.FLOAT64:
        var arr_f = alloc_out_f64(n, nulls)
        for p in range(len(bounds)):
            var aggf: AggF64
            if expr.func == PF_SUM:
                aggf = _frame_sum_f64(col, bounds[p], ends[p])
            elif expr.func == PF_MIN:
                aggf = _frame_extreme_f64[True](col, bounds[p], ends[p])
            elif expr.func == PF_MAX:
                aggf = _frame_extreme_f64[False](col, bounds[p], ends[p])
            else:
                raise Error(
                    "partition_sliding_frame: unsupported aggregate "
                    + String(Int(expr.func))
                )
            for row in range(bounds[p], ends[p]):
                store_f64_or_null(arr_f, row, aggf.value, aggf.count)
        return Column.from_primitive[DType.float64](arr_f)
    raise Error(
        "partition_sliding_frame: unsupported type " + String(col.arrow_type)
    )


# =============================================================================
# The dispatcher
# =============================================================================


def eval_sliding_agg(
    batch: RecordBatch,
    bounds: List[Int],
    order_keys: List[String],
    descending: List[Bool],
    expr: PartitionExpr,
) raises -> Column[HeapRegion]:
    """Evaluate an aggregate whose frame is not the running one.

    The whole partition is taken first and in either unit: neither of its
    bounds is relative to the current row. Every other frame goes through
    `frame_index`, which also needs the order keys and their directions (a
    RANGE bound is measured on the key's values).
    """
    if expr.frame.is_full_partition():
        return eval_full_partition_agg(batch, bounds, expr)
    var fidx = frame_index(batch, bounds, order_keys, descending, expr.frame)
    if expr.func == PF_SUM:
        return eval_sliding_sum(batch, bounds, expr.column, fidx.lo, fidx.hi)
    elif expr.func == PF_COUNT:
        return eval_sliding_count(batch, bounds, expr.column, fidx.lo, fidx.hi)
    elif expr.func == PF_AVG:
        return eval_sliding_avg(batch, bounds, expr.column, fidx.lo, fidx.hi)
    elif expr.func == PF_MIN:
        return eval_sliding_extreme[True](batch, bounds, expr.column, fidx.lo, fidx.hi)
    elif expr.func == PF_MAX:
        return eval_sliding_extreme[False](batch, bounds, expr.column, fidx.lo, fidx.hi)
    raise Error(
        "partition_sliding_frame: unsupported aggregate "
        + String(Int(expr.func))
    )
