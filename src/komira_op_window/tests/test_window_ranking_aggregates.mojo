# =============================================================================
# test_window_ranking_aggregates -- ranking ties, frames, NULLs, NaN, infinity
# =============================================================================
#
# Through `_execute_partition_by_sink`. Expected values are derived by hand
# from docs/design/query_semantics.md §9.2 (peers tie in RANK / DENSE_RANK /
# PERCENT_RANK / CUME_DIST, whatever the key type), §2.7 (MAX over a NaN is
# NaN, MIN is NaN only if every value is), §2.1 / §2.2 (aggregates skip NULLs;
# no surviving value is NULL, COUNT is 0) and §9.1 / §9.8 (ROWS and RANGE
# frames).
# =============================================================================

from std.math import inf, isnan
from std.testing import TestSuite, assert_equal, assert_false, assert_true

from komira_arrow.column import Column
from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.record_batch import RecordBatch, RecordBatchBuilder
from komira_arrow.schema import Field, SchemaBuilder
from komira_arrow.string_array import StringArray
from komira_buffer.heap_region import HeapRegion
from komira_physical_plan.physical_plan import PartitionBySinkData
from komira_plan_expr.partition_expr import (
    FRAME_BOUND_CURRENT_ROW,
    FRAME_BOUND_FOLLOWING,
    FRAME_BOUND_PRECEDING,
    FRAME_BOUND_UNBOUNDED_FOLLOWING,
    FRAME_BOUND_UNBOUNDED_PRECEDING,
    FRAME_UNITS_RANGE,
    FRAME_UNITS_ROWS,
    PF_AVG,
    PF_COUNT,
    PF_MAX,
    PF_MIN,
    PF_SUM,
    PartitionExpr,
    PartitionFrame,
    partition_expr_output_field,
)

from komira_op_window.partition_scan_sink import _execute_partition_by_sink

def _i64(vals: List[Int64], valid: List[Bool]) -> Column[HeapRegion]:
    var arr = PrimitiveArray[DType.int64].allocate_nullable(len(vals))
    for i in range(len(vals)):
        arr.store[1](i, vals[i])
        if not valid[i]:
            arr._set_null(i)
    return Column.from_primitive[DType.int64](arr)

def _plain_i64(vals: List[Int64]) -> Column[HeapRegion]:
    var l = List[Scalar[DType.int64]]()
    for v in vals:
        l.append(v)
    return Column.from_primitive[DType.int64](PrimitiveArray[DType.int64].from_list(l))

def _i32(vals: List[Int32]) -> Column[HeapRegion]:
    var l = List[Scalar[DType.int32]]()
    for v in vals:
        l.append(v)
    return Column.from_primitive[DType.int32](PrimitiveArray[DType.int32].from_list(l))

def _f64(vals: List[Float64]) -> Column[HeapRegion]:
    var l = List[Scalar[DType.float64]]()
    for v in vals:
        l.append(v)
    return Column.from_primitive[DType.float64](PrimitiveArray[DType.float64].from_list(l))

def _batch(names: List[String], var cols: List[Column[HeapRegion]]) raises -> RecordBatch:
    var sb = SchemaBuilder()
    var bb = RecordBatchBuilder()
    for i in range(len(names)):
        sb.add_field(Field(names[i], cols[i].arrow_type, True))
    for i in range(len(cols)):
        bb.add_column(cols[i].share())
    return bb.build(sb.build())

def _run(
    var batch: RecordBatch,
    pkeys: List[String],
    okeys: List[String],
    var exprs: List[PartitionExpr],
) raises -> RecordBatch:
    var sb = SchemaBuilder()
    for i in range(batch.schema.num_columns()):
        sb.add_field(batch.schema.field_at(i))
    for i in range(len(exprs)):
        sb.add_field(partition_expr_output_field(exprs[i], batch.schema, i))
    var desc = List[Bool]()
    for _ in range(len(okeys)):
        desc.append(False)
    var spec = PartitionBySinkData(pkeys.copy(), okeys.copy(), desc^, exprs^, sb.build())
    return _execute_partition_by_sink(batch^, spec)

def _get(rb: RecordBatch, col: Int, row: Int) -> Int64:
    ref c = rb.column_at(col)
    return c._data.get_typed[Scalar[DType.int64]](c._offset + row)

def _getf(rb: RecordBatch, col: Int, row: Int) -> Float64:
    ref c = rb.column_at(col)
    return c._data.get_typed[Scalar[DType.float64]](c._offset + row)

def _null(rb: RecordBatch, col: Int, row: Int) -> Bool:
    return rb.column_at(col).is_null_at(row)

def _rows(start_tag: UInt8, start: Int64, end_tag: UInt8, end: Int64) -> PartitionFrame:
    return PartitionFrame(FRAME_UNITS_ROWS, start_tag, start, end_tag, end)

# =============================================================================
# Ranking over key types other than INT64 / FLOAT64
# =============================================================================

def test_rank_ties_on_int32_and_string_keys() raises:
    # o32 = 5, 3, 5, 1 ; RANK: 1 -> 1, 3 -> 2, 5, 5 -> 3, 3; DENSE_RANK 1,2,3,3;
    # PERCENT_RANK (rank-1)/3: 0, 1/3, 2/3, 2/3; CUME_DIST: 1/4, 2/4, 1, 1.
    var o: List[Int32] = [5, 3, 5, 1]
    var cols = List[Column[HeapRegion]]()
    cols.append(_i32(o))
    var names: List[String] = ["o"]
    var exprs = List[PartitionExpr]()
    exprs.append(PartitionExpr.rank())
    exprs.append(PartitionExpr.dense_rank())
    exprs.append(PartitionExpr.percent_rank())
    exprs.append(PartitionExpr.cume_dist())
    var ok: List[String] = ["o"]
    var out = _run(_batch(names, cols^), List[String](), ok, exprs^)
    var want_rank: List[Int64] = [1, 2, 3, 3]
    var want_dense: List[Int64] = [1, 2, 3, 3]
    var want_pr: List[Float64] = [0.0, 1.0 / 3.0, 2.0 / 3.0, 2.0 / 3.0]
    var want_cd: List[Float64] = [0.25, 0.5, 1.0, 1.0]
    for r in range(4):
        assert_equal(_get(out, 1, r), want_rank[r])
        assert_equal(_get(out, 2, r), want_dense[r])
        assert_equal(_getf(out, 3, r), want_pr[r])
        assert_equal(_getf(out, 4, r), want_cd[r])

    # A STRING key: "b", "a", "b" -> RANK 1 ("a"), 2, 2.
    var s = List[String]()
    s.append("b")
    s.append("a")
    s.append("b")
    var cols2 = List[Column[HeapRegion]]()
    cols2.append(Column.from_string(StringArray.from_strings(s)))
    var names2: List[String] = ["s"]
    var exprs2 = List[PartitionExpr]()
    exprs2.append(PartitionExpr.rank())
    var ok2: List[String] = ["s"]
    var out2 = _run(_batch(names2, cols2^), List[String](), ok2, exprs2^)
    var want2: List[Int64] = [1, 2, 2]
    for r in range(3):
        assert_equal(_get(out2, 1, r), want2[r])

def test_running_and_whole_partition_min_max_over_nan() raises:
    # v = NaN, 2.0, 5.0 in order o. Running (ROWS) MIN: NaN, 2, 2 (NaN is the
    # largest value, so it is the minimum only while it is the only value);
    # running MAX: NaN, NaN, NaN. Whole-partition MIN 2, MAX NaN.
    var o: List[Int64] = [1, 2, 3]
    var v: List[Float64] = [Float64(0.0) / Float64(0.0), 2.0, 5.0]
    var cols = List[Column[HeapRegion]]()
    cols.append(_plain_i64(o))
    cols.append(_f64(v))
    var names: List[String] = ["o", "v"]
    var running = _rows(FRAME_BOUND_UNBOUNDED_PRECEDING, 0, FRAME_BOUND_CURRENT_ROW, 0)
    var whole = _rows(FRAME_BOUND_UNBOUNDED_PRECEDING, 0, FRAME_BOUND_UNBOUNDED_FOLLOWING, 0)
    var exprs = List[PartitionExpr]()
    exprs.append(PartitionExpr.agg_with_frame(PF_MIN, "v", running.copy()))
    exprs.append(PartitionExpr.agg_with_frame(PF_MAX, "v", running.copy()))
    exprs.append(PartitionExpr.agg_with_frame(PF_MIN, "v", whole.copy()))
    exprs.append(PartitionExpr.agg_with_frame(PF_MAX, "v", whole.copy()))
    exprs.append(
        PartitionExpr.agg_with_frame(
            PF_MAX, "v", _rows(FRAME_BOUND_PRECEDING, 1, FRAME_BOUND_CURRENT_ROW, 0)
        )
    )
    var ok: List[String] = ["o"]
    var out = _run(_batch(names, cols^), List[String](), ok, exprs^)
    assert_true(isnan(_getf(out, 2, 0)))
    assert_equal(_getf(out, 2, 1), 2.0)
    assert_equal(_getf(out, 2, 2), 2.0)
    for r in range(3):
        assert_true(isnan(_getf(out, 3, r)))
        assert_equal(_getf(out, 4, r), 2.0)
        assert_true(isnan(_getf(out, 5, r)))
    # Sliding MAX over (1 PRECEDING, CURRENT ROW): NaN, NaN, 5.
    assert_true(isnan(_getf(out, 6, 0)))
    assert_true(isnan(_getf(out, 6, 1)))
    assert_equal(_getf(out, 6, 2), 5.0)

def test_running_max_after_a_nan_arrives() raises:
    # v = 2.0, NaN, 1.0: running MAX 2, NaN, NaN (a NaN arriving after a
    # number is the new maximum); running MIN 2, 2, 1; whole-partition MAX
    # NaN, MIN 1.
    var o: List[Int64] = [1, 2, 3]
    var v: List[Float64] = [2.0, Float64(0.0) / Float64(0.0), 1.0]
    var cols = List[Column[HeapRegion]]()
    cols.append(_plain_i64(o))
    cols.append(_f64(v))
    var names: List[String] = ["o", "v"]
    var running = _rows(FRAME_BOUND_UNBOUNDED_PRECEDING, 0, FRAME_BOUND_CURRENT_ROW, 0)
    var whole = _rows(FRAME_BOUND_UNBOUNDED_PRECEDING, 0, FRAME_BOUND_UNBOUNDED_FOLLOWING, 0)
    var exprs = List[PartitionExpr]()
    exprs.append(PartitionExpr.agg_with_frame(PF_MAX, "v", running.copy()))
    exprs.append(PartitionExpr.agg_with_frame(PF_MIN, "v", running.copy()))
    exprs.append(PartitionExpr.agg_with_frame(PF_MAX, "v", whole.copy()))
    exprs.append(PartitionExpr.agg_with_frame(PF_MIN, "v", whole.copy()))
    var ok: List[String] = ["o"]
    var out = _run(_batch(names, cols^), List[String](), ok, exprs^)
    assert_equal(_getf(out, 2, 0), 2.0)
    assert_true(isnan(_getf(out, 2, 1)))
    assert_true(isnan(_getf(out, 2, 2)))
    assert_equal(_getf(out, 3, 0), 2.0)
    assert_equal(_getf(out, 3, 1), 2.0)
    assert_equal(_getf(out, 3, 2), 1.0)
    for r in range(3):
        assert_true(isnan(_getf(out, 4, r)))
        assert_equal(_getf(out, 5, r), 1.0)

# =============================================================================
# Sliding frames
# =============================================================================

def test_following_frame_sums_only_rows_it_holds() raises:
    # SUM / COUNT / AVG over ROWS BETWEEN 1 FOLLOWING AND 2 FOLLOWING,
    # v = 1, 2, 4, 8, 16: frames [1,3) [2,4) [3,5) [4,5) [5,5) give
    # SUM 6, 12, 24, 16, NULL; COUNT(v) 2, 2, 2, 1, 0; AVG 3, 6, 12, 16, NULL.
    var o: List[Int64] = [1, 2, 3, 4, 5]
    var v: List[Int64] = [1, 2, 4, 8, 16]
    var cols = List[Column[HeapRegion]]()
    cols.append(_plain_i64(o))
    cols.append(_plain_i64(v))
    var names: List[String] = ["o", "v"]
    var fr = _rows(FRAME_BOUND_FOLLOWING, 1, FRAME_BOUND_FOLLOWING, 2)
    var exprs = List[PartitionExpr]()
    exprs.append(PartitionExpr.agg_with_frame(PF_SUM, "v", fr.copy()))
    exprs.append(PartitionExpr.agg_with_frame(PF_COUNT, "v", fr.copy()))
    exprs.append(PartitionExpr.agg_with_frame(PF_AVG, "v", fr.copy()))
    var ok: List[String] = ["o"]
    var out = _run(_batch(names, cols^), List[String](), ok, exprs^)
    var want_sum: List[Int64] = [6, 12, 24, 16, 0]
    var want_cnt: List[Int64] = [2, 2, 2, 1, 0]
    var want_avg: List[Float64] = [3.0, 6.0, 12.0, 16.0, 0.0]
    for r in range(4):
        assert_false(_null(out, 2, r))
        assert_equal(_get(out, 2, r), want_sum[r])
        assert_equal(_getf(out, 4, r), want_avg[r])
    assert_true(_null(out, 2, 4))
    assert_true(_null(out, 4, 4))
    for r in range(5):
        assert_equal(_get(out, 3, r), want_cnt[r])

def test_sliding_float_sum_after_infinity_leaves() raises:
    # SUM(v) over ROWS BETWEEN 1 PRECEDING AND CURRENT ROW, v = +inf, 1, 2, 3:
    # +inf, +inf, 3, 5. Once the infinity has left the frame the sum is
    # finite again; a subtraction of +inf would leave NaN behind.
    var o: List[Int64] = [1, 2, 3, 4]
    var v: List[Float64] = [inf[DType.float64](), 1.0, 2.0, 3.0]
    var cols = List[Column[HeapRegion]]()
    cols.append(_plain_i64(o))
    cols.append(_f64(v))
    var names: List[String] = ["o", "v"]
    var exprs = List[PartitionExpr]()
    exprs.append(
        PartitionExpr.agg_with_frame(
            PF_SUM, "v", _rows(FRAME_BOUND_PRECEDING, 1, FRAME_BOUND_CURRENT_ROW, 0)
        )
    )
    var ok: List[String] = ["o"]
    var out = _run(_batch(names, cols^), List[String](), ok, exprs^)
    assert_equal(_getf(out, 2, 0), inf[DType.float64]())
    assert_equal(_getf(out, 2, 1), inf[DType.float64]())
    assert_equal(_getf(out, 2, 2), 3.0)
    assert_equal(_getf(out, 2, 3), 5.0)

# =============================================================================
# Several partitions, NTILE sizing and frames that are empty or hold NULLs
# =============================================================================

def test_ranking_and_running_aggregates_restart_per_partition() raises:
    var g: List[Int64] = [1, 1, 1, 2, 2]
    var o: List[Int64] = [1, 1, 2, 1, 2]
    var v: List[Int64] = [10, 99, 30, 5, 5]
    var vv: List[Bool] = [True, False, True, True, True]
    var cols = List[Column[HeapRegion]]()
    cols.append(_plain_i64(g))
    cols.append(_plain_i64(o))
    cols.append(_i64(v, vv))
    var names: List[String] = ["g", "o", "v"]
    var exprs = List[PartitionExpr]()
    exprs.append(PartitionExpr.row_number())
    exprs.append(PartitionExpr.rank())
    exprs.append(PartitionExpr.dense_rank())
    exprs.append(PartitionExpr.cume_dist())
    exprs.append(PartitionExpr.ntile(2))
    exprs.append(PartitionExpr.running_sum("v"))
    exprs.append(PartitionExpr.running_count("v"))
    exprs.append(PartitionExpr.running_avg("v"))
    exprs.append(PartitionExpr.running_count())
    var pk: List[String] = ["g"]
    var ok: List[String] = ["o"]
    var out = _run(_batch(names, cols^), pk, ok, exprs^)
    var row_number: List[Int64] = [1, 2, 3, 1, 2]
    var rank: List[Int64] = [1, 1, 3, 1, 2]
    var dense: List[Int64] = [1, 1, 2, 1, 2]
    var cume: List[Float64] = [2.0 / 3.0, 2.0 / 3.0, 1.0, 0.5, 1.0]
    var ntile: List[Int64] = [1, 1, 2, 1, 2]
    var sum: List[Int64] = [10, 10, 40, 5, 10]
    var count: List[Int64] = [1, 1, 2, 1, 2]
    var avg: List[Float64] = [10.0, 10.0, 20.0, 5.0, 5.0]
    var count_star: List[Int64] = [1, 2, 3, 1, 2]
    for r in range(5):
        assert_equal(_get(out, 3, r), row_number[r])
        assert_equal(_get(out, 4, r), rank[r])
        assert_equal(_get(out, 5, r), dense[r])
        assert_equal(_getf(out, 6, r), cume[r])
        assert_equal(_get(out, 7, r), ntile[r])
        assert_equal(_get(out, 8, r), sum[r])
        assert_equal(_get(out, 9, r), count[r])
        assert_equal(_getf(out, 10, r), avg[r])
        assert_equal(_get(out, 11, r), count_star[r])

def test_ntile_bucket_sizes_and_more_buckets_than_rows() raises:
    # 7 rows: 3 buckets are 3, 2, 2 rows; 10 buckets give one row each; 1 bucket holds all.
    var o: List[Int64] = [1, 2, 3, 4, 5, 6, 7]
    var cols = List[Column[HeapRegion]]()
    cols.append(_plain_i64(o))
    var names: List[String] = ["o"]
    var exprs = List[PartitionExpr]()
    exprs.append(PartitionExpr.ntile(3))
    exprs.append(PartitionExpr.ntile(10))
    exprs.append(PartitionExpr.ntile(1))
    var ok: List[String] = ["o"]
    var out = _run(_batch(names, cols^), List[String](), ok, exprs^)
    var want3: List[Int64] = [1, 1, 1, 2, 2, 3, 3]
    for r in range(7):
        assert_equal(_get(out, 1, r), want3[r])
        assert_equal(_get(out, 2, r), Int64(r + 1))
        assert_equal(_get(out, 3, r), 1)

def test_sliding_int_sum_over_empty_and_null_frames() raises:
    # ROWS 2 PRECEDING .. 1 PRECEDING over v = 10, NULL, 30, 40: the first
    # frame is empty (SUM NULL, COUNT 0); a frame holding only NULLs also
    # has no SUM.
    var o: List[Int64] = [1, 2, 3, 4]
    var v: List[Int64] = [10, 0, 30, 40]
    var vv: List[Bool] = [True, False, True, True]
    var cols = List[Column[HeapRegion]]()
    cols.append(_plain_i64(o))
    cols.append(_i64(v, vv))
    var names: List[String] = ["o", "v"]
    var exprs = List[PartitionExpr]()
    exprs.append(
        PartitionExpr.agg_with_frame(PF_SUM, "v", _rows(FRAME_BOUND_PRECEDING, 2, FRAME_BOUND_PRECEDING, 1))
    )
    exprs.append(
        PartitionExpr.agg_with_frame(PF_COUNT, "v", _rows(FRAME_BOUND_PRECEDING, 2, FRAME_BOUND_PRECEDING, 1))
    )
    var ok: List[String] = ["o"]
    var out = _run(_batch(names, cols^), List[String](), ok, exprs^)
    assert_true(_null(out, 2, 0))
    assert_equal(_get(out, 3, 0), 0)
    var want_sum: List[Int64] = [0, 10, 10, 30]
    var want_count: List[Int64] = [0, 1, 1, 1]
    for r in range(1, 4):
        assert_false(_null(out, 2, r))
        assert_equal(_get(out, 2, r), want_sum[r])
        assert_equal(_get(out, 3, r), want_count[r])

def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
