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
# COUNT and the INT64 SUM / AVG are invertible (an exact count, an exact
# 128-bit sum), so the frame is a two-pointer window over the partition: as
# `[lo, hi)` advances, the rows leaving at the back are removed and the rows
# entering at the front are added, O(rows) per partition.
# When the frame jumps past everything it held (`1 FOLLOWING .. 2 FOLLOWING`
# on a partition's first row), the rows it removes and never added are the
# rows it adds again, so the two cancel.
#
# A FLOAT64 sum is not invertible: subtracting a value that leaves the frame
# does not undo adding it. `inf - inf` is NaN, and a 1 added to 1e20 is
# lost, so removing 1e20 takes it too: over v = 1e20, 1, 1 with `1 PRECEDING
# .. CURRENT ROW` the last frame {1, 1} would sum to 1, not 2, a whole-value
# error, not a last-bits one. DuckDB answers each frame from its own values
# (a segment tree), so FLOAT64 SUM / AVG do the same: a sum tree over the
# partition (`_F64SumTree`) sums each frame from the O(log rows) nodes that
# tile it, O(rows x log rows) per partition.
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


# -0.0 is the identity of float addition (`-0.0 + x` is `x`, +0.0 included);
# +0.0 is not (`0.0 + -0.0` is +0.0).
comptime _NEG_ZERO: Float64 = -Float64(0.0)

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


def _live_prefix(col: Column[HeapRegion], nulls: Bool, n: Int) -> List[Int]:
    """`out[r]` is the number of non-NULL cells in rows `[0, r)`, so a
    frame `[lo, hi)` holds `out[hi] - out[lo]` of them."""
    var out = List[Int](capacity=n + 1)
    out.append(0)
    var live = 0
    for r in range(n):
        if not (nulls and cell_is_null(col, r)):
            live += 1
        out.append(live)
    return out^


struct _F64SumTree(Movable):
    """A sum tree over one partition's FLOAT64 cells, for a frame sum that
    only ever adds the values the frame holds.

    Leaves are the partition's cells, a NULL cell holding -0.0 (the identity
    of float addition: `-0.0 + x` is `x` for every `x`, +0.0 and NaN
    included); node `i` below `m` is the sum of nodes `2i` and `2i + 1`. A
    query combines the O(log m) nodes that tile `[lo, hi)` exactly, so no
    value outside the frame enters its sum: an infinity, a NaN or a large
    value that has left the frame cannot change the sum of the values still
    in it, as subtracting it back out would. NULL cells are not counted
    here; the caller keeps the count."""

    var node: List[Float64]
    var m: Int

    def __init__(out self):
        self.node = List[Float64]()
        self.m = 0

    def build(mut self, col: Column[HeapRegion], s: Int, e: Int, nulls: Bool):
        """Load the partition `[s, e)` of `col` and sum the inner nodes."""
        self.m = e - s
        self.node = List[Float64](length=2 * self.m, fill=_NEG_ZERO)
        for i in range(self.m):
            if not (nulls and cell_is_null(col, s + i)):
                self.node[self.m + i] = _load_f64(col, s + i)
        var i = self.m - 1
        while i >= 1:
            self.node[i] = self.node[2 * i] + self.node[2 * i + 1]
            i -= 1

    @always_inline
    def query(self, lo: Int, hi: Int) -> Float64:
        """The sum of the cells `[lo, hi)`, relative to the partition start.
        An empty range sums to +0.0, as the whole-partition sum starts."""
        # PERF-CRITICAL: one call per row of every framed FLOAT64 SUM / AVG;
        # O(log m) node reads, no allocation.
        var l = lo + self.m
        var h = hi + self.m
        var acc_l = _NEG_ZERO
        var acc_r = _NEG_ZERO
        while l < h:
            if l & 1:
                acc_l = acc_l + self.node[l]
                l += 1
            if h & 1:
                h -= 1
                acc_r = self.node[h] + acc_r
            l >>= 1
            h >>= 1
        return Float64(0.0) + (acc_l + acc_r)


# =============================================================================
# Sliding-frame kernels (frames given as `[lo, hi)` per row)
# =============================================================================


def eval_sliding_sum(
    batch: RecordBatch, bounds: List[Int], col_name: String, lo_idx: List[Int], hi_idx: List[Int],
) raises -> Column[HeapRegion]:
    """SUM over a sliding frame. INT64 on a two-pointer window, O(rows) per
    partition: its 128-bit sum is exact, so removing a row undoes adding it.
    FLOAT64 on `_F64SumTree`, O(rows x log rows): each frame sums only its
    own values. A frame with no non-NULL value sums to NULL."""
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
        var tree = _F64SumTree()
        var live = _live_prefix(col, nulls, n)
        for p in range(len(bounds)):
            var s = bounds[p]
            tree.build(col, s, ends[p], nulls)
            for row in range(s, ends[p]):
                var lo = lo_idx[row]
                var hi = hi_idx[row]
                if hi < lo:
                    hi = lo
                var cnt = live[hi] - live[lo]
                store_f64_or_null(arr, row, tree.query(lo - s, hi - s), cnt)
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
    """AVG over a sliding frame, always FLOAT64: the frame's SUM (as
    `eval_sliding_sum` computes it) divided by its non-NULL count."""
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
        var tree = _F64SumTree()
        var live = _live_prefix(col, nulls, n)
        for p in range(len(bounds)):
            var s = bounds[p]
            tree.build(col, s, ends[p], nulls)
            for row in range(s, ends[p]):
                var lo = lo_idx[row]
                var hi = hi_idx[row]
                if hi < lo:
                    hi = lo
                var cnt = live[hi] - live[lo]
                var meanf: Float64 = 0.0
                if cnt > 0:
                    meanf = tree.query(lo - s, hi - s) / Float64(cnt)
                store_f64_or_null(arr, row, meanf, cnt)
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
