# =============================================================================
# partition_scan_kernels -- ranking functions and running aggregates
# =============================================================================
#
# The per-function kernels `partition_scan_sink._eval_partition_expr` fans out
# to. Every kernel takes the batch sorted by (partition keys ++ order keys) and
# `bounds`, the partition start rows.
#
# Ranking (§9.2): peers are the rows of a partition equal on every order key
# under `partition_keys.key_cells_equal` (NULLs are peers of each other, NaNs
# too). RANK is the row number of the first peer, DENSE_RANK counts peer
# groups, PERCENT_RANK is `(rank - 1) / (rows - 1)` (0 for a one-row
# partition) and CUME_DIST is `(rows up to the last peer) / rows`. With no
# ORDER BY every row is a peer of every other. ROW_NUMBER and NTILE number
# physical rows.
#
# Running aggregates are the frame `ROWS BETWEEN UNBOUNDED PRECEDING AND
# CURRENT ROW`, folded once per partition; `partition_scan_sink` turns them
# into the RANGE spelling by its peer closure. An INT64 SUM / AVG sums
# exactly (128 bits; a SUM outside INT64 raises). NULLs follow
# `partition_null_policy`. MIN and MAX over floats use DuckDB's order (§2.7):
# NaN is greater than every number, so MAX is NaN once a NaN has been seen and
# MIN is NaN only while every value seen is NaN.
# =============================================================================

from komira_arrow.arrow_types import ArrowType
from komira_arrow.column import Column
from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.record_batch import RecordBatch
from komira_buffer.heap_region import HeapRegion
from komira_op_sort.sort import sort_key_lt

from .partition_keys import _peer_bounds, _segment_ends
from .partition_null_policy import (
    I128,
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
# Typed accessors
# =============================================================================


@always_inline
def _col_i64(col: Column[HeapRegion], row: Int) -> Int64:
    return Int64(col._data.get_typed[Scalar[DType.int64]](col._offset + row))


@always_inline
def _col_f64(col: Column[HeapRegion], row: Int) -> Float64:
    return Float64(col._data.get_typed[Scalar[DType.float64]](col._offset + row))


def _col_as_f64(col: Column[HeapRegion], row: Int) -> Float64:
    if col.arrow_type == ArrowType.INT64:
        return Float64(Int(_col_i64(col, row)))
    elif col.arrow_type == ArrowType.FLOAT64:
        return _col_f64(col, row)
    return 0.0


# =============================================================================
# Ranking
# =============================================================================


def _eval_row_number(batch: RecordBatch, bounds: List[Int]) raises -> Column[HeapRegion]:
    var n = batch.num_rows()
    var arr = PrimitiveArray[DType.int64].allocate(n)
    var b_idx = 0
    var rownum: Int64 = 0
    for row in range(n):
        if b_idx < len(bounds) and bounds[b_idx] == row:
            rownum = 0
            b_idx += 1
        rownum += 1
        arr.store[1](row, rownum)
    return Column.from_primitive[DType.int64](arr)


struct _PeerWalk(Movable):
    """Per row: the start of its partition, the start and end of its peer
    group, the end of its partition, and the 0-based index of its peer group
    inside the partition."""

    var part_start: List[Int]
    var part_end: List[Int]
    var peer_start: List[Int]
    var peer_end: List[Int]
    var group_idx: List[Int]

    def __init__(
        out self,
        batch: RecordBatch,
        bounds: List[Int],
        order_keys: List[String],
    ) raises:
        var n = batch.num_rows()
        var ends = _segment_ends(bounds, n)
        var peers = _peer_bounds(batch, bounds, order_keys)
        var peer_ends = _segment_ends(peers, n)
        self.part_start = List[Int](capacity=n)
        self.part_end = List[Int](capacity=n)
        self.peer_start = List[Int](capacity=n)
        self.peer_end = List[Int](capacity=n)
        self.group_idx = List[Int](capacity=n)
        var g = 0
        for p in range(len(bounds)):
            var s = bounds[p]
            var e = ends[p]
            var gi = -1
            for row in range(s, e):
                while g + 1 < len(peers) and peers[g + 1] <= row:
                    g += 1
                if peers[g] == row:
                    gi += 1
                self.part_start.append(s)
                self.part_end.append(e)
                self.peer_start.append(peers[g])
                self.peer_end.append(peer_ends[g])
                self.group_idx.append(gi)


def _eval_rank(
    batch: RecordBatch, bounds: List[Int], order_keys: List[String]
) raises -> Column[HeapRegion]:
    var n = batch.num_rows()
    var w = _PeerWalk(batch, bounds, order_keys)
    var arr = PrimitiveArray[DType.int64].allocate(n)
    for row in range(n):
        arr.store[1](row, Int64(w.peer_start[row] - w.part_start[row] + 1))
    return Column.from_primitive[DType.int64](arr)


def _eval_dense_rank(
    batch: RecordBatch, bounds: List[Int], order_keys: List[String]
) raises -> Column[HeapRegion]:
    var n = batch.num_rows()
    var w = _PeerWalk(batch, bounds, order_keys)
    var arr = PrimitiveArray[DType.int64].allocate(n)
    for row in range(n):
        arr.store[1](row, Int64(w.group_idx[row] + 1))
    return Column.from_primitive[DType.int64](arr)


def _eval_percent_rank(
    batch: RecordBatch, bounds: List[Int], order_keys: List[String]
) raises -> Column[HeapRegion]:
    var n = batch.num_rows()
    var w = _PeerWalk(batch, bounds, order_keys)
    var arr = PrimitiveArray[DType.float64].allocate(n)
    for row in range(n):
        var plen = w.part_end[row] - w.part_start[row]
        var pr: Float64 = 0.0
        if plen > 1:
            pr = Float64(w.peer_start[row] - w.part_start[row]) / Float64(plen - 1)
        arr.store[1](row, pr)
    return Column.from_primitive[DType.float64](arr)


def _eval_cume_dist(
    batch: RecordBatch, bounds: List[Int], order_keys: List[String]
) raises -> Column[HeapRegion]:
    """CUME_DIST: (rows of the partition up to and including the current
    row's last peer) / (rows of the partition)."""
    var n = batch.num_rows()
    var w = _PeerWalk(batch, bounds, order_keys)
    var arr = PrimitiveArray[DType.float64].allocate(n)
    for row in range(n):
        var plen = w.part_end[row] - w.part_start[row]
        arr.store[1](
            row, Float64(w.peer_end[row] - w.part_start[row]) / Float64(plen)
        )
    return Column.from_primitive[DType.float64](arr)


def _eval_ntile(
    batch: RecordBatch, bounds: List[Int], num_buckets: Int
) raises -> Column[HeapRegion]:
    """NTILE(n): bucket numbers 1..n over the partition's rows, the first
    `rows % n` buckets one row larger. `n` must be positive (DuckDB raises
    otherwise)."""
    if num_buckets <= 0:
        raise Error(
            "partition_scan_kernels: NTILE needs a positive bucket count, got "
            + String(num_buckets)
        )
    var n = batch.num_rows()
    var arr = PrimitiveArray[DType.int64].allocate(n)
    var ends = _segment_ends(bounds, n)
    for p in range(len(bounds)):
        var start = bounds[p]
        var end = ends[p]
        var plen = end - start
        var base_size = plen // num_buckets
        var extra = plen % num_buckets
        var bucket: Int = 1
        var in_bucket: Int = 0
        var cur_size = base_size + 1 if 1 <= extra else base_size
        for row in range(start, end):
            arr.store[1](row, Int64(bucket))
            in_bucket += 1
            if in_bucket >= cur_size and bucket < num_buckets:
                bucket += 1
                in_bucket = 0
                cur_size = base_size + 1 if bucket <= extra else base_size
    return Column.from_primitive[DType.int64](arr)


# =============================================================================
# Running aggregates -- ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
# =============================================================================
#
# The frame always holds the current row, so `count == 0` can only mean "every
# value so far was NULL", which needs a bitmap on the input: the one-term
# `alloc_out_*` predicate is the whole answer here.


def _eval_running_sum_i64(batch: RecordBatch, bounds: List[Int], col_name: String) raises -> Column[HeapRegion]:
    var n = batch.num_rows()
    ref col = batch.column_at(batch.schema.column_index(col_name))
    var nulls = col.has_validity_buffer()
    var arr = alloc_out_i64(n, nulls)
    # NOT-VECTORIZABLE: each output depends on the previous one.
    var b_idx = 0
    var total = I128(0)
    var cnt = 0
    for row in range(n):
        if b_idx < len(bounds) and bounds[b_idx] == row:
            total = I128(0)
            cnt = 0
            b_idx += 1
        if not (nulls and cell_is_null(col, row)):
            total += I128(_col_i64(col, row))
            cnt += 1
        if cnt == 0:
            store_i64_or_null(arr, row, Int64(0), 0)
        else:
            store_i64_or_null(arr, row, i64_sum_result(total), cnt)
    return Column.from_primitive[DType.int64](arr)


def _eval_running_sum_f64(batch: RecordBatch, bounds: List[Int], col_name: String) raises -> Column[HeapRegion]:
    var n = batch.num_rows()
    ref col = batch.column_at(batch.schema.column_index(col_name))
    var nulls = col.has_validity_buffer()
    var arr = alloc_out_f64(n, nulls)
    var b_idx = 0
    var total: Float64 = 0.0
    var cnt = 0
    for row in range(n):
        if b_idx < len(bounds) and bounds[b_idx] == row:
            total = 0.0
            cnt = 0
            b_idx += 1
        if not (nulls and cell_is_null(col, row)):
            total += _col_f64(col, row)
            cnt += 1
        store_f64_or_null(arr, row, total, cnt)
    return Column.from_primitive[DType.float64](arr)


def _eval_running_count(
    batch: RecordBatch, bounds: List[Int], col_name: String
) raises -> Column[HeapRegion]:
    """Running COUNT: `COUNT(*)` (empty `col_name`) counts rows,
    `COUNT(<col>)` counts non-NULL values. Never NULL."""
    var n = batch.num_rows()
    var arr = alloc_out_i64(n, False)
    var b_idx = 0
    var cnt: Int64 = 0
    if count_is_star(col_name):
        for row in range(n):
            if b_idx < len(bounds) and bounds[b_idx] == row:
                cnt = 0
                b_idx += 1
            cnt += 1
            arr.store[1](row, cnt)
        return Column.from_primitive[DType.int64](arr)

    ref col = batch.column_at(batch.schema.column_index(col_name))
    var nulls = col.has_validity_buffer()
    for row in range(n):
        if b_idx < len(bounds) and bounds[b_idx] == row:
            cnt = 0
            b_idx += 1
        if not (nulls and cell_is_null(col, row)):
            cnt += 1
        arr.store[1](row, cnt)
    return Column.from_primitive[DType.int64](arr)


def _eval_running_avg(batch: RecordBatch, bounds: List[Int], col_name: String) raises -> Column[HeapRegion]:
    """Running AVG, always FLOAT64; the denominator is the non-NULL count.
    An INT64 column sums exactly (128 bits) and divides once (§2.12): a
    DOUBLE running sum would drop digits past 2^53."""
    var n = batch.num_rows()
    ref col = batch.column_at(batch.schema.column_index(col_name))
    var nulls = col.has_validity_buffer()
    var arr = alloc_out_f64(n, nulls)
    var is_i64 = col.arrow_type == ArrowType.INT64
    var b_idx = 0
    var total: Float64 = 0.0
    var total_i = I128(0)
    var cnt = 0
    for row in range(n):
        if b_idx < len(bounds) and bounds[b_idx] == row:
            total = 0.0
            total_i = I128(0)
            cnt = 0
            b_idx += 1
        if not (nulls and cell_is_null(col, row)):
            if is_i64:
                total_i += I128(_col_i64(col, row))
            else:
                total += _col_as_f64(col, row)
            cnt += 1
        var mean: Float64 = 0.0
        if cnt > 0:
            if is_i64:
                mean = i64_mean(total_i, cnt)
            else:
                mean = total / Float64(cnt)
        store_f64_or_null(arr, row, mean, cnt)
    return Column.from_primitive[DType.float64](arr)


def _eval_running_extreme_i64[
    is_min: Bool
](batch: RecordBatch, bounds: List[Int], col_name: String) raises -> Column[HeapRegion]:
    var n = batch.num_rows()
    ref col = batch.column_at(batch.schema.column_index(col_name))
    var nulls = col.has_validity_buffer()
    var arr = alloc_out_i64(n, nulls)
    var b_idx = 0
    var cur: Int64 = 0
    var cnt = 0
    for row in range(n):
        if b_idx < len(bounds) and bounds[b_idx] == row:
            cnt = 0
            b_idx += 1
        if not (nulls and cell_is_null(col, row)):
            var v = _col_i64(col, row)
            comptime if is_min:
                if cnt == 0 or v < cur:
                    cur = v
            else:
                if cnt == 0 or v > cur:
                    cur = v
            cnt += 1
        store_i64_or_null(arr, row, cur, cnt)
    return Column.from_primitive[DType.int64](arr)


def _eval_running_extreme_f64[
    is_min: Bool
](batch: RecordBatch, bounds: List[Int], col_name: String) raises -> Column[HeapRegion]:
    """Running MIN / MAX of a FLOAT64 column in DuckDB's order (NaN above
    every number), so a NaN does not get stuck in, or skipped by, the
    running value as it would under IEEE `<` / `>`."""
    var n = batch.num_rows()
    ref col = batch.column_at(batch.schema.column_index(col_name))
    var nulls = col.has_validity_buffer()
    var arr = alloc_out_f64(n, nulls)
    var b_idx = 0
    var cur: Float64 = 0.0
    var cnt = 0
    for row in range(n):
        if b_idx < len(bounds) and bounds[b_idx] == row:
            cnt = 0
            b_idx += 1
        if not (nulls and cell_is_null(col, row)):
            var v = _col_f64(col, row)
            comptime if is_min:
                if cnt == 0 or sort_key_lt[DType.float64](v, cur):
                    cur = v
            else:
                if cnt == 0 or sort_key_lt[DType.float64](cur, v):
                    cur = v
            cnt += 1
        store_f64_or_null(arr, row, cur, cnt)
    return Column.from_primitive[DType.float64](arr)


def _eval_running_min_i64(batch: RecordBatch, bounds: List[Int], col_name: String) raises -> Column[HeapRegion]:
    return _eval_running_extreme_i64[True](batch, bounds, col_name)


def _eval_running_max_i64(batch: RecordBatch, bounds: List[Int], col_name: String) raises -> Column[HeapRegion]:
    return _eval_running_extreme_i64[False](batch, bounds, col_name)


def _eval_running_min_f64(batch: RecordBatch, bounds: List[Int], col_name: String) raises -> Column[HeapRegion]:
    return _eval_running_extreme_f64[True](batch, bounds, col_name)


def _eval_running_max_f64(batch: RecordBatch, bounds: List[Int], col_name: String) raises -> Column[HeapRegion]:
    return _eval_running_extreme_f64[False](batch, bounds, col_name)
