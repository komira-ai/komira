# =============================================================================
# test_cov_hash_agg_op_dt_grouped.mojo — `HashAggOpAgg[Op, col]` over a sliced,
# nullable, multi-group batch; the exact-SUM range check; the COUNT_DISTINCT
# move-combine runs; the band and MorselView folds
# =============================================================================
#
# Fixture: 12 physical rows sliced to [2, 11) (9 visible rows at a non-zero
# column offset). Columns: key (int64, no nulls), v (int32), f (float64),
# h (float32), the last three nullable. Rows 0, 1 and 11 are outside the
# slice and hold +-1000 / 500 / key 9, which change every answer if read.
#
#   slice row  key   v     f      h
#       0       1    5    2.5    0.5
#       1       2    N    1.0    N
#       2       1   -3    N      1.5
#       3       3    7    4.0   -2.5
#       4       2   10   -2.0    4.0
#       5       1    N    0.5    N
#       6       4    N    N      N
#       7       2    4    3.0    1.0
#       8       1    5    1.5   -0.75
#
# Groups in first-seen order: key 1 (rows 0, 2, 5, 8: NOT contiguous),
# key 2 (rows 1, 4, 7), key 3 (row 3), key 4 (row 6, every value NULL).
# The driver skips a NULL input (SQL: aggregates ignore NULL), except for
# COUNT(*), which counts rows. Oracle, by hand:
#
#   group    COUNT(*) SUM(v) COUNT(v) MIN(v) MAX(v) AVG(v) CD(v) MEDIAN(v)
#   key 1        4      7       3      -3      5     7/3     2      5.0
#   key 2        3     14       2       4     10     7.0     2      7.0
#   key 3        1      7       1       7      7     7.0     1      7.0
#   key 4        1      -       0       -      -      -      0       -
#
#   group    SUM(f) MIN(f) MAX(f) FIRST(f) LAST(f) VAR_SAMP(f) SUM(h) MIN(h) MAX(h)
#   key 1     4.5    0.5    2.5    2.5      1.5      1.0       1.25  -0.75   1.5
#   key 2     2.0   -2.0    3.0    1.0      3.0       -        5.0    1.0    4.0
#   key 3     4.0    4.0    4.0    4.0      4.0       -       -2.5   -2.5   -2.5
#
# "-" is SQL NULL (no non-null input, or VAR_SAMP of one row): the ops have no
# NULL output (SUM 0, AVG 0.0, MIN/MAX an identity, VAR/STDDEV/MEDIAN NaN),
# so those cells are not asserted. Every answer is also checked after two
# partials (slice rows [0, 4) and [4, 9), so key 1 and key 2 span both) are
# merged with `combine`.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_true, assert_false

from komira_arrow.batch_view import BatchView, batch_view_over
from komira_arrow.band_view import BandView
from komira_arrow.column_builder import ColumnBuilder
from komira_arrow.record_batch import RecordBatch
from komira_arrow.schema import Field, SchemaBuilder
from komira_buffer.byte_view import ByteView

from komira_agg.aggregator import Aggregator
from komira_agg.hash_agg_op_dt import (
    HashAggOpAgg,
    SumOp, CountOp, MinOp, MaxOp, AvgOp, VarSampOp, FirstOp, LastOp,
    CountDistinctOp, CountDistinctState, MedianOp,
)


comptime NG = 4  # groups


def _i64[dt: DType](v: Scalar[dt]) -> Int64:
    """The value as Int64; a compile error unless the result type IS int64
    (the documented SUM/MIN/MAX result type for an integer input)."""
    comptime assert dt == DType.int64, "result type is not int64"
    return rebind[Int64](v)


def _f64[dt: DType](v: Scalar[dt]) -> Float64:
    """The value as Float64; a compile error unless the result type IS
    float64."""
    comptime assert dt == DType.float64, "result type is not float64"
    return rebind[Float64](v)
comptime K = 0  # key column (int64)
comptime V = 1  # v (int32)
comptime F = 2  # f (float64)
comptime H = 3  # h (float32)


def _col[
    dt: DType
](vals: List[Scalar[dt]], nulls: List[Bool]) raises -> ColumnBuilder[dt]:
    var b = ColumnBuilder[dt].with_capacity(len(vals))
    for i in range(len(vals)):
        if nulls[i]:
            b.append_null()
        else:
            b.append(vals[i])
    return b^


def _batch() raises -> RecordBatch:
    var key: List[Int64] = [9, 9, 1, 2, 1, 3, 2, 1, 4, 2, 1, 9]
    var no: List[Bool] = [
        False, False, False, False, False, False, False, False, False, False, False, False
    ]
    var v: List[Int32] = [1000, -1000, 5, 0, -3, 7, 10, 0, 0, 4, 5, 500]
    var vn: List[Bool] = [
        False, False, False, True, False, False, False, True, True, False, False, False
    ]
    var f: List[Float64] = [
        1000.0, -1000.0, 2.5, 1.0, 0.0, 4.0, -2.0, 0.5, 0.0, 3.0, 1.5, 500.0
    ]
    var fn_: List[Bool] = [
        False, False, False, False, True, False, False, False, True, False, False, False
    ]
    var h: List[Float32] = [
        1000.0, -1000.0, 0.5, 0.0, 1.5, -2.5, 4.0, 0.0, 0.0, 1.0, -0.75, 500.0
    ]
    var hn: List[Bool] = [
        False, False, False, True, False, False, False, True, True, False, False, False
    ]
    var sb = SchemaBuilder()
    sb.add_field(Field("key", DType.int64, False))
    sb.add_field(Field("v", DType.int32, True))
    sb.add_field(Field("f", DType.float64, True))
    sb.add_field(Field("h", DType.float32, True))
    return RecordBatch.from_typed_columns_4(
        sb.build(),
        _col[DType.int64](key, no).materialize().slice(2, 9),
        _col[DType.int32](v, vn).materialize().slice(2, 9),
        _col[DType.float64](f, fn_).materialize().slice(2, 9),
        _col[DType.float32](h, hn).materialize().slice(2, 9),
    )


def _group_ids[o: Origin[mut=False]](bv: BatchView[o]) -> List[Int]:
    """Dense group ids in first-seen key order (the test's own grouping)."""
    var keys = List[Int64]()
    var ids = List[Int]()
    for i in range(bv.n_rows()):
        var k = bv.col_i64(K).load[1](i)[0]
        var g = -1
        for j in range(len(keys)):
            if keys[j] == k:
                g = j
        if g < 0:
            g = len(keys)
            keys.append(k)
        ids.append(g)
    return ids^


def _grouped[
    A: Aggregator, o: Origin[mut=False]
](bv: BatchView[o], ids: List[Int], col: Int, skip_nulls: Bool, lo: Int, hi: Int) -> List[A.StateTy]:
    var a = A.make()
    var states = List[A.StateTy]()
    for _ in range(NG):
        states.append(A.init())
    for i in range(lo, hi):
        if skip_nulls and bv.col_is_null(col, i):
            continue
        a.update_scalar(states[ids[i]], bv, i)
    return states^


def _grouped_split[
    A: Aggregator, o: Origin[mut=False]
](bv: BatchView[o], ids: List[Int], col: Int, skip_nulls: Bool) -> List[A.StateTy]:
    """Two partials, slice rows [0, 4) and [4, 9), merged per group."""
    var a = A.make()
    var left = _grouped[A, o](bv, ids, col, skip_nulls, 0, 4)
    var right = _grouped[A, o](bv, ids, col, skip_nulls, 4, bv.n_rows())
    for g in range(NG):
        a.combine(left[g], right[g].copy())
    return left^


def _check_groups[
    A: Aggregator, out_dt: DType, o: Origin[mut=False]
](
    name: String,
    bv: BatchView[o],
    ids: List[Int],
    col: Int,
    skip_nulls: Bool,
    want: List[Scalar[out_dt]],
) raises:
    """`want[g]` for the first len(want) groups, serial and two-partial. The
    aggregate's result type must be `out_dt` (a compile error otherwise)."""
    comptime assert A.OUT_DT == out_dt, "unexpected result type"
    var serial = _grouped[A, o](bv, ids, col, skip_nulls, 0, bv.n_rows())
    var split = _grouped_split[A, o](bv, ids, col, skip_nulls)
    for g in range(len(want)):
        var got = rebind[Scalar[out_dt]](A.finalize(serial[g]))
        var got_split = rebind[Scalar[out_dt]](A.finalize(split[g]))
        assert_equal(got, want[g], name + " group " + String(g))
        assert_equal(got_split, want[g], name + " split group " + String(g))


# =============================================================================
# Grouped answers
# =============================================================================


def test_group_ids_are_non_contiguous() raises:
    var batch = _batch()
    var bv = batch_view_over(batch)
    var ids = _group_ids(bv)
    var want: List[Int] = [0, 1, 0, 2, 1, 0, 3, 1, 0]
    assert_equal(len(ids), 9)
    for i in range(9):
        assert_equal(ids[i], want[i])


def test_grouped_int32_aggregates() raises:
    """SUM / COUNT / MIN / MAX / AVG / COUNT(*) over int32 v per group (the
    int32 read arm; SUM/MIN/MAX answer in int64, AVG in float64). The all-NULL
    group 4 answers COUNT(v) = 0 and COUNT(*) = 1."""
    var batch = _batch()
    var bv = batch_view_over(batch)
    var ids = _group_ids(bv)
    _check_groups[HashAggOpAgg[SumOp[DType.int32], V], DType.int64](
        "SUM(v)", bv, ids, V, True, [Int64(7), Int64(14), Int64(7)]
    )
    _check_groups[HashAggOpAgg[CountOp[DType.int32], V], DType.int64](
        "COUNT(v)", bv, ids, V, True, [Int64(3), Int64(2), Int64(1), Int64(0)]
    )
    _check_groups[HashAggOpAgg[CountOp[DType.int64], K], DType.int64](
        "COUNT(*)", bv, ids, K, False, [Int64(4), Int64(3), Int64(1), Int64(1)]
    )
    _check_groups[HashAggOpAgg[MinOp[DType.int32], V], DType.int64](
        "MIN(v)", bv, ids, V, True, [Int64(-3), Int64(4), Int64(7)]
    )
    _check_groups[HashAggOpAgg[MaxOp[DType.int32], V], DType.int64](
        "MAX(v)", bv, ids, V, True, [Int64(5), Int64(10), Int64(7)]
    )
    _check_groups[HashAggOpAgg[AvgOp[DType.int32], V], DType.float64](
        "AVG(v)", bv, ids, V, True,
        [Float64(7.0) / Float64(3.0), Float64(7.0), Float64(7.0)],
    )


def test_grouped_distinct_and_median() raises:
    """COUNT(DISTINCT v) per group {5,-3,5} -> 2, {10,4} -> 2, {7} -> 1, {} -> 0;
    MEDIAN(v) {-3,5,5} -> 5.0, {10,4} -> 7.0 (mean of the middle two), {7} -> 7.0."""
    var batch = _batch()
    var bv = batch_view_over(batch)
    var ids = _group_ids(bv)
    _check_groups[HashAggOpAgg[CountDistinctOp[DType.int32], V], DType.int64](
        "CD(v)", bv, ids, V, True, [Int64(2), Int64(2), Int64(1), Int64(0)]
    )
    _check_groups[HashAggOpAgg[MedianOp[DType.int32], V], DType.float64](
        "MEDIAN(v)", bv, ids, V, True, [Float64(5.0), Float64(7.0), Float64(7.0)]
    )


def test_grouped_float64_aggregates() raises:
    """SUM / MIN / MAX / FIRST / LAST / VAR_SAMP over float64 f per group (the
    float64 read arm). FIRST/LAST are the first/last non-null value in row
    order, and key 1's rows are spread over both partials."""
    var batch = _batch()
    var bv = batch_view_over(batch)
    var ids = _group_ids(bv)
    _check_groups[HashAggOpAgg[SumOp[DType.float64], F], DType.float64](
        "SUM(f)", bv, ids, F, True, [Float64(4.5), Float64(2.0), Float64(4.0)]
    )
    _check_groups[HashAggOpAgg[MinOp[DType.float64], F], DType.float64](
        "MIN(f)", bv, ids, F, True, [Float64(0.5), Float64(-2.0), Float64(4.0)]
    )
    _check_groups[HashAggOpAgg[MaxOp[DType.float64], F], DType.float64](
        "MAX(f)", bv, ids, F, True, [Float64(2.5), Float64(3.0), Float64(4.0)]
    )
    _check_groups[HashAggOpAgg[FirstOp[DType.float64], F], DType.float64](
        "FIRST(f)", bv, ids, F, True, [Float64(2.5), Float64(1.0), Float64(4.0)]
    )
    _check_groups[HashAggOpAgg[LastOp[DType.float64], F], DType.float64](
        "LAST(f)", bv, ids, F, True, [Float64(1.5), Float64(3.0), Float64(4.0)]
    )
    # {2.5, 0.5, 1.5}: mean 1.5, squared deviations 1 + 1 + 0 = 2, / (3 - 1).
    _check_groups[HashAggOpAgg[VarSampOp[DType.float64], F], DType.float64](
        "VAR_SAMP(f)", bv, ids, F, True, [Float64(1.0)]
    )


def test_grouped_float32_aggregates() raises:
    """SUM / MIN / MAX over float32 h per group (the float32 read arm; the
    answers are float64)."""
    var batch = _batch()
    var bv = batch_view_over(batch)
    var ids = _group_ids(bv)
    _check_groups[HashAggOpAgg[SumOp[DType.float32], H], DType.float64](
        "SUM(h)", bv, ids, H, True, [Float64(1.25), Float64(5.0), Float64(-2.5)]
    )
    _check_groups[HashAggOpAgg[MinOp[DType.float32], H], DType.float64](
        "MIN(h)", bv, ids, H, True, [Float64(-0.75), Float64(1.0), Float64(-2.5)]
    )
    _check_groups[HashAggOpAgg[MaxOp[DType.float32], H], DType.float64](
        "MAX(h)", bv, ids, H, True, [Float64(1.5), Float64(4.0), Float64(-2.5)]
    )


def test_five_aggregates_one_row_loop() raises:
    """SUM, COUNT, MIN, MAX over v and SUM over f folded in ONE row loop per
    group: each aggregate keeps its own state list and null filter."""
    var batch = _batch()
    var bv = batch_view_over(batch)
    var ids = _group_ids(bv)
    comptime ASum = HashAggOpAgg[SumOp[DType.int32], V]
    comptime ACnt = HashAggOpAgg[CountOp[DType.int32], V]
    comptime AMin = HashAggOpAgg[MinOp[DType.int32], V]
    comptime AMax = HashAggOpAgg[MaxOp[DType.int32], V]
    comptime AF = HashAggOpAgg[SumOp[DType.float64], F]
    var a1 = ASum()
    var a2 = ACnt()
    var a3 = AMin()
    var a4 = AMax()
    var a5 = AF()
    var s1 = List[ASum.StateTy]()
    var s2 = List[ACnt.StateTy]()
    var s3 = List[AMin.StateTy]()
    var s4 = List[AMax.StateTy]()
    var s5 = List[AF.StateTy]()
    for _ in range(NG):
        s1.append(ASum.init())
        s2.append(ACnt.init())
        s3.append(AMin.init())
        s4.append(AMax.init())
        s5.append(AF.init())
    for i in range(bv.n_rows()):
        var g = ids[i]
        if not bv.col_is_null(V, i):
            a1.update_scalar(s1[g], bv, i)
            a2.update_scalar(s2[g], bv, i)
            a3.update_scalar(s3[g], bv, i)
            a4.update_scalar(s4[g], bv, i)
        if not bv.col_is_null(F, i):
            a5.update_scalar(s5[g], bv, i)
    var sums: List[Int64] = [7, 14, 7]
    var cnts: List[Int64] = [3, 2, 1, 0]
    var mins: List[Int64] = [-3, 4, 7]
    var maxs: List[Int64] = [5, 10, 7]
    var fs: List[Float64] = [4.5, 2.0, 4.0]
    for g in range(3):
        assert_equal(_i64(ASum.finalize(s1[g])), sums[g])
        assert_equal(_i64(AMin.finalize(s3[g])), mins[g])
        assert_equal(_i64(AMax.finalize(s4[g])), maxs[g])
        assert_equal(_f64(AF.finalize(s5[g])), fs[g])
    for g in range(NG):
        assert_equal(ACnt.finalize(s2[g]), cnts[g])


# =============================================================================
# The MorselView and band folds
# =============================================================================


def test_morsel_view_fold() raises:
    """`update_scalar_mv[BatchView]` over the slice: SUM(key) = 17 (keys
    1,2,1,3,2,1,4,2,1; the outside key 9 rows excluded) and SUM(v) = 28."""
    var batch = _batch()
    var bv = batch_view_over(batch)
    comptime AK = HashAggOpAgg[SumOp[DType.int64], K]
    comptime AV = HashAggOpAgg[SumOp[DType.int32], V]
    var ak = AK()
    var av = AV()
    var sk = AK.init()
    var sv = AV.init()
    for i in range(bv.n_rows()):
        ak.update_scalar_mv(sk, bv, i)
        if not bv.col_is_null(V, i):
            av.update_scalar_mv(sv, bv, i)
    assert_equal(_i64(AK.finalize(sk)), Int64(17))
    assert_equal(_i64(AV.finalize(sv)), Int64(28))


def _i64_bytes(vals: List[Int64]) -> List[UInt8]:
    var out = List[UInt8]()
    for v in vals:
        var u = UInt64(v)
        for b in range(8):
            out.append(UInt8((u >> UInt64(8 * b)) & 0xFF))
    return out^


def _band_sum_count[
    o: Origin[mut=False]
](ref [o] raw: List[UInt8], n: Int) -> Tuple[Int64, Int64]:
    var band = BandView[o](n, 1)
    band.push_flat_col(ByteView[o](raw.unsafe_ptr(), len(raw)))
    comptime AS = HashAggOpAgg[SumOp[DType.int64], 0]
    comptime AC = HashAggOpAgg[CountOp[DType.int64], 0]
    var a_s = AS()
    var a_c = AC()
    var ss = AS.init()
    var sc = AC.init()
    for r in range(n):
        a_s.update_band(ss, band, r)
        a_c.update_band(sc, band, r)
    return (_i64(AS.finalize(ss)), AC.finalize(sc))


def test_band_fold_reads_value_or_skips_it() raises:
    """`update_band` over a 4-row int64 band [3, -1, 10, -20]: SUM reads each
    value (-8); COUNT (NEEDS_VALUE False) counts the rows without reading (4)."""
    var raw = _i64_bytes([Int64(3), Int64(-1), Int64(10), Int64(-20)])
    var got = _band_sum_count(raw, 4)
    assert_equal(got[0], Int64(-8))
    assert_equal(got[1], Int64(4))


# =============================================================================
# The exact integer SUM: in range or refused, never wrapped
# =============================================================================


def _sum_i64(vals: List[Int64]) -> SumOp[DType.int64].StateTy:
    var s = SumOp[DType.int64].init()
    for v in vals:
        SumOp[DType.int64].update_scalar(s, v)
    return s


def test_exact_sum_range_check() raises:
    """SQL SUM(bigint) is the exact total: [MAX, 1] has no INT64 answer
    (`total_fits_i64` False), nor [MIN, -1]; [MAX, 1, -7] does (MAX - 6) even
    though a partial left INT64; [MIN] and [MAX] sit on the bounds."""
    comptime A = HashAggOpAgg[SumOp[DType.int64], 0]
    assert_true(A.EXACT_INT_SUM)
    assert_false(A.total_fits_i64(_sum_i64([Int64.MAX, Int64(1)])))
    assert_false(A.total_fits_i64(_sum_i64([Int64.MIN, Int64(-1)])))
    var back = _sum_i64([Int64.MAX, Int64(1), Int64(-7)])
    assert_true(A.total_fits_i64(back))
    assert_equal(_i64(A.finalize(back)), Int64.MAX - 6)
    var lo = _sum_i64([Int64.MIN])
    assert_true(A.total_fits_i64(lo))
    assert_equal(_i64(A.finalize(lo)), Int64.MIN)
    var hi = _sum_i64([Int64.MAX])
    assert_true(A.total_fits_i64(hi))
    assert_equal(_i64(A.finalize(hi)), Int64.MAX)
    # Two partials, each past INT64, whose merged total is back inside it.
    var p = _sum_i64([Int64.MAX, Int64.MAX])
    var q = _sum_i64([Int64.MIN, Int64.MIN, Int64(5)])
    var a = A()
    a.combine(p, q)
    assert_true(A.total_fits_i64(p))
    assert_equal(_i64(A.finalize(p)), Int64(3))


def test_float_sum_is_not_an_exact_int_sum() raises:
    """A float SUM never narrows: EXACT_INT_SUM is False and `total_fits_i64`
    answers True whatever the total."""
    comptime A = HashAggOpAgg[SumOp[DType.float64], 0]
    assert_false(A.EXACT_INT_SUM)
    var s = SumOp[DType.float64].init()
    SumOp[DType.float64].update_scalar(s, 1.0e300)
    assert_true(A.total_fits_i64(s))
    assert_equal(_f64(A.finalize(s)), 1.0e300)


# =============================================================================
# COUNT_DISTINCT move-combine runs, and the defaults of a non-distinct op
# =============================================================================


def _cd(vals: List[Int64]) -> CountDistinctState[DType.int64]:
    var s = CountDistinctOp[DType.int64].init()
    for v in vals:
        CountDistinctOp[DType.int64].update_scalar(s, v)
    return s^


def test_count_distinct_runs() raises:
    """COUNT(DISTINCT) over the union of moved runs: [1,2] and [2,3] moved into
    an empty state count 3; moving THAT state (runs only, no values) into
    another, then feeding 9, gives runs [[9],[1,2],[2,3]], values 9,1,2,2,3,
    and 4 distinct; `combine` of it into a state holding [3] still counts 4."""
    comptime A = HashAggOpAgg[CountDistinctOp[DType.int64], 0]
    assert_true(A.IS_DISTINCT)
    assert_false(A.PARALLEL_SORT_FINALIZE)
    var a = A()
    var mid = A.init()
    var p = _cd([Int64(1), Int64(2)])
    var q = _cd([Int64(2), Int64(3)])
    a.take_distinct_into(mid, p)
    a.take_distinct_into(mid, q)
    assert_equal(len(p.values), 0)
    assert_equal(len(mid.runs), 2)
    assert_equal(A.finalize(mid), Int64(3))
    # Runs only, no per-row values: exactly the two moved runs.
    var mid_runs = a.distinct_runs(mid)
    assert_equal(len(mid_runs), 2)
    assert_equal(len(mid_runs[0]), 2)
    assert_equal(mid_runs[0][0], Int64(1))
    assert_equal(mid_runs[1][1], Int64(3))

    var top = A.init()
    a.take_distinct_into(top, mid)
    assert_equal(len(top.runs), 2)
    CountDistinctOp[DType.int64].update_scalar(top, Int64(9))
    assert_equal(A.finalize(top), Int64(4))

    var runs = a.distinct_runs(top)
    assert_equal(len(runs), 3)
    var want_runs: List[List[Int64]] = [[Int64(9)], [Int64(1), Int64(2)], [Int64(2), Int64(3)]]
    for r in range(3):
        assert_equal(len(runs[r]), len(want_runs[r]))
        for i in range(len(runs[r])):
            assert_equal(runs[r][i], want_runs[r][i])
    var flat = a.distinct_values(top)
    var want_flat: List[Int64] = [9, 1, 2, 2, 3]
    assert_equal(len(flat), 5)
    for i in range(5):
        assert_equal(flat[i], want_flat[i])

    var into = _cd([Int64(3)])
    a.combine(into, top^)
    assert_equal(len(into.runs), 0)
    assert_equal(A.finalize(into), Int64(4))


def test_count_distinct_float_is_not_radix() raises:
    """COUNT(DISTINCT) over float64 is not an integer value buffer
    (IS_DISTINCT False); its answer is still the distinct count."""
    comptime A = HashAggOpAgg[CountDistinctOp[DType.float64], 0]
    assert_false(A.IS_DISTINCT)
    var s = A.init()
    CountDistinctOp[DType.float64].update_scalar(s, 1.5)
    CountDistinctOp[DType.float64].update_scalar(s, 1.5)
    CountDistinctOp[DType.float64].update_scalar(s, -2.0)
    assert_equal(A.finalize(s), Int64(2))


def test_non_distinct_op_defaults() raises:
    """An op that is neither distinct nor exact-sum inherits the documented
    `HashAggOpDt` defaults through the adapter: `total_fits_i64` True, no
    values or runs, and `take_distinct_into` leaves both states alone.
    MEDIAN alone sets PARALLEL_SORT_FINALIZE."""
    comptime A = HashAggOpAgg[MinOp[DType.int64], 0]
    assert_false(A.EXACT_INT_SUM)
    assert_false(A.IS_DISTINCT)
    assert_false(A.PARALLEL_SORT_FINALIZE)
    assert_true(HashAggOpAgg[MedianOp[DType.int64], 0].PARALLEL_SORT_FINALIZE)
    var a = A.make()
    var dst = A.init()
    MinOp[DType.int64].update_scalar(dst, Int64(4))
    var src = A.init()
    MinOp[DType.int64].update_scalar(src, Int64(-4))
    assert_true(A.total_fits_i64(dst))
    assert_equal(len(a.distinct_values(dst)), 0)
    assert_equal(len(a.distinct_runs(dst)), 0)
    a.take_distinct_into(dst, src)
    assert_equal(_i64(A.finalize(dst)), Int64(4))
    assert_equal(_i64(A.finalize(src)), Int64(-4))


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
