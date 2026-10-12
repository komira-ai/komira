# test_hash_agg_sql_semantics.mojo — HashAggTable answers what DuckDB answers.
#
# Every test drains through `drain_to_record_batch` (the column the query
# returns) over the engine's `HashAggOpAgg` aggregators, and pins one rule:
# NULL inputs skipped, all-NULL groups NULL (COUNT 0), an ungrouped aggregate
# over no rows is one row, an integer SUM outside INT64 refuses by name, MIN /
# MAX put NaN above +inf, NULL keys form one group that reads back NULL, and
# FIRST / LAST return the NULL they pick. The data word under every NULL is a
# large value, so folding it as a value changes the answer.

from std.math import inf, isinf, isnan
from std.testing import TestSuite, assert_equal, assert_false, assert_true

from komira_arrow.arrow_types import ArrowType
from komira_arrow.batch_view import BatchView
from komira_arrow.column import Column
from komira_buffer.heap_region import HeapRegion
from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.schema import Field, RecordBatch, RecordBatchBuilder, SchemaBuilder

from komira_agg.count_star_op import CountStarOp
from komira_agg.hash_agg_op_dt import (
    AvgOp,
    CountOp,
    FirstOp,
    HashAggOpAgg,
    LastOp,
    MaxOp,
    MinOp,
    SumOp,
)

from komira_op_agg_stage.agg_column import AggBlock, AggSlot
from komira_op_agg_stage.hash_agg import HashAggTable
from komira_op_agg_stage.key_block import KeyTuple1, KeyTupleScalar

comptime I64 = DType.int64
comptime F64 = DType.float64
comptime _UNDER_NULL: Int64 = 1_000_000


def _li(*vals: Int64) -> List[Int64]:
    var out = List[Int64](capacity=len(vals))
    for i in range(len(vals)):
        out.append(vals[i])
    return out^


def _lb(*vals: Bool) -> List[Bool]:
    var out = List[Bool](capacity=len(vals))
    for i in range(len(vals)):
        out.append(vals[i])
    return out^


def _lf(*vals: Float64) -> List[Float64]:
    var out = List[Float64](capacity=len(vals))
    for i in range(len(vals)):
        out.append(vals[i])
    return out^


def _ls(*vals: StaticString) -> List[String]:
    var out = List[String](capacity=len(vals))
    for i in range(len(vals)):
        out.append(String(vals[i]))
    return out^


def _i64_col(imm vals: List[Int64], imm nulls: List[Bool]) raises -> Column[HeapRegion]:
    var arr = PrimitiveArray[I64].allocate_nullable(len(vals))
    for i in range(len(vals)):
        arr.set(i, vals[i])
    for i in range(len(vals)):
        if nulls[i]:
            arr._set_null(i)
    return Column.from_primitive[I64](arr^)


def _f64_col(imm vals: List[Float64]) raises -> Column[HeapRegion]:
    return Column.from_primitive[F64](PrimitiveArray[F64].from_list(vals))


def _kv(
    imm keys: List[Int64],
    imm knull: List[Bool],
    imm vals: List[Int64],
    imm vnull: List[Bool],
) raises -> RecordBatch:
    var sb = SchemaBuilder()
    sb.add_field(Field("k", ArrowType.INT64, True))
    sb.add_field(Field("v", ArrowType.INT64, True))
    var rb = RecordBatchBuilder()
    rb.add_column(_i64_col(keys, knull))
    rb.add_column(_i64_col(vals, vnull))
    return rb.build(sb.build())


def _none(n: Int) -> List[Bool]:
    var out = List[Bool](capacity=n)
    for _ in range(n):
        out.append(False)
    return out^


comptime _Sum = AggSlot[HashAggOpAgg[SumOp[I64], 1]]
comptime _Cnt = AggSlot[HashAggOpAgg[CountOp[I64], 1]]
comptime _Star = AggSlot[HashAggOpAgg[CountStarOp[I64], 1]]
comptime _Min = AggSlot[HashAggOpAgg[MinOp[I64], 1]]
comptime _Max = AggSlot[HashAggOpAgg[MaxOp[I64], 1]]
comptime _Avg = AggSlot[HashAggOpAgg[AvgOp[I64], 1]]
comptime _Keyed = HashAggTable[
    KeyTuple1[I64, 0], _Sum, _Cnt, _Star, _Min, _Max, _Avg
]


def _keyed_table() -> _Keyed:
    return _Keyed(AggBlock[_Sum, _Cnt, _Star, _Min, _Max, _Avg](
        _Sum(), _Cnt(), _Star(), _Min(), _Max(), _Avg()
    ))


def _fill(mut t: _Keyed, batch: RecordBatch) raises:
    var bv = BatchView(batch)
    for r in range(bv.n_rows()):
        t.feed_row(bv, r)


def test_null_inputs_are_skipped_and_all_null_groups_are_null() raises:
    # Group 1: v = 1, NULL, 3. Group 2: v = NULL, NULL.
    var keys = _li(1, 1, 2, 1, 2)
    var vals = _li(1, _UNDER_NULL, _UNDER_NULL, 3, _UNDER_NULL)
    var vnull = _lb(False, True, True, False, True)
    var t = _keyed_table()
    _fill(t, _kv(keys, _none(5), vals, vnull))
    var res = t.drain_to_record_batch()
    ref out = res.value()
    assert_equal(out.num_rows(), 2, "two groups")
    # Columns: k, sum, count(v), count(*), min, max, avg.
    var s = out.column_at(1).as_primitive[I64]()
    assert_equal(s.get(0), Int64(4), "SUM skips the NULL")
    assert_true(out.column_at(1).is_null_at(1), "SUM of an all-NULL group")
    var c = out.column_at(2).as_primitive[I64]()
    assert_equal(c.get(0), Int64(2), "COUNT(v) skips the NULL")
    assert_equal(c.get(1), Int64(0), "COUNT(v) of an all-NULL group is 0")
    assert_false(out.column_at(2).is_null_at(1), "COUNT is never NULL")
    var st = out.column_at(3).as_primitive[I64]()
    assert_equal(st.get(0), Int64(3), "COUNT(*) counts the NULL row")
    assert_equal(st.get(1), Int64(2), "COUNT(*) of the all-NULL group")
    assert_equal(out.column_at(4).as_primitive[I64]().get(0), Int64(1), "MIN")
    assert_equal(out.column_at(5).as_primitive[I64]().get(0), Int64(3), "MAX")
    assert_true(out.column_at(4).is_null_at(1), "MIN of all-NULL")
    assert_true(out.column_at(5).is_null_at(1), "MAX of all-NULL")
    assert_equal(
        out.column_at(6).as_primitive[F64]().get(0), Float64(2.0), "AVG"
    )
    assert_true(out.column_at(6).is_null_at(1), "AVG of all-NULL")


def test_combined_partials_keep_a_group_with_values_non_null() raises:
    # Worker A sees only NULLs for key 1, worker B a value: the merged group
    # folded a value, so it is not NULL.
    var a = _keyed_table()
    _fill(a, _kv(_li(1), _none(1), _li(_UNDER_NULL), _lb(True)))
    var b = _keyed_table()
    _fill(b, _kv(_li(1), _none(1), _li(5), _none(1)))
    a.combine(b^)
    var res = a.drain_to_record_batch()
    ref out = res.value()
    assert_false(out.column_at(1).is_null_at(0), "SUM after the merge")
    assert_equal(out.column_at(1).as_primitive[I64]().get(0), Int64(5), "SUM")
    assert_equal(out.column_at(3).as_primitive[I64]().get(0), Int64(2), "COUNT(*)")


def test_ungrouped_aggregate_over_no_rows_is_one_row() raises:
    comptime T = HashAggTable[KeyTupleScalar, _Sum, _Star, _Max]
    var t = T(AggBlock[_Sum, _Star, _Max](_Sum(), _Star(), _Max()))
    var res = t.drain_to_record_batch()
    ref out = res.value()
    assert_equal(out.num_rows(), 1, "DuckDB returns one row")
    assert_true(out.column_at(0).is_null_at(0), "SUM over no rows is NULL")
    assert_equal(out.column_at(1).as_primitive[I64]().get(0), Int64(0), "COUNT(*) 0")
    assert_false(out.column_at(1).is_null_at(0), "COUNT(*) is not NULL")
    assert_true(out.column_at(2).is_null_at(0), "MAX over no rows is NULL")


def test_grouped_aggregate_over_no_rows_is_no_row() raises:
    var t = _keyed_table()
    var res = t.drain_to_record_batch()
    ref out = res.value()
    assert_equal(out.num_rows(), 0, "no group, no row")


def test_int_sum_outside_int64_refuses_and_inside_answers() raises:
    # [MAX, 1, -7]: a partial leaves INT64, the total does not; DuckDB
    # answers MAX - 6, and so does the exact total.
    var t = _keyed_table()
    _fill(t, _kv(_li(1, 1, 1), _none(3), _li(Int64.MAX, 1, -7), _none(3)))
    var res = t.drain_to_record_batch()
    ref out = res.value()
    assert_equal(
        out.column_at(1).as_primitive[I64]().get(0), Int64.MAX - 6, "exact"
    )
    # [MAX, 1]: the total is outside INT64. The engine's rule refuses.
    var u = _keyed_table()
    _fill(u, _kv(_li(1, 1), _none(2), _li(Int64.MAX, 1), _none(2)))
    var raised = False
    try:
        _ = u.drain_to_record_batch()
    except e:
        raised = True
        assert_true(
            String(e).find("integer sum() overflowed INT64") >= 0,
            "the shared refusal: " + String(e),
        )
        assert_true(String(e).find("agg0") >= 0, "names the column")
    assert_true(raised, "SUM past INT64 must refuse, not wrap")


def test_float_min_max_put_nan_above_infinity() raises:
    comptime FMin = AggSlot[HashAggOpAgg[MinOp[F64], 1]]
    comptime FMax = AggSlot[HashAggOpAgg[MaxOp[F64], 1]]
    comptime T = HashAggTable[KeyTuple1[I64, 0], FMin, FMax]
    var t = T(AggBlock[FMin, FMax](FMin(), FMax()))
    var nan = Float64(0.0) / Float64(0.0)
    var sb = SchemaBuilder()
    sb.add_field(Field("k", ArrowType.INT64, True))
    sb.add_field(Field("v", ArrowType.FLOAT64, True))
    var rb = RecordBatchBuilder()
    rb.add_column(_i64_col(_li(1, 1, 1, 2, 2), _none(5)))
    rb.add_column(_f64_col(_lf(nan, 1.0, -inf[F64](), nan, inf[F64]())))
    var batch = rb.build(sb.build())
    var bv = BatchView(batch)
    for r in range(5):
        t.feed_row(bv, r)
    var res = t.drain_to_record_batch()
    ref out = res.value()
    var mn = out.column_at(1).as_primitive[F64]()
    var mx = out.column_at(2).as_primitive[F64]()
    assert_true(isinf(mn.get(0)) and mn.get(0) < 0, "MIN(NaN, 1, -inf) = -inf")
    assert_true(isnan(mx.get(0)), "MAX(NaN, 1, -inf) = NaN")
    assert_true(isinf(mn.get(1)) and mn.get(1) > 0, "MIN(NaN, inf) = inf")
    assert_true(isnan(mx.get(1)), "MAX(NaN, inf) = NaN")


def test_null_keys_are_one_group_that_reads_back_null() raises:
    # Keys: NULL (word 5), 5, NULL (word 9), 5, NULL (word 0), 0.
    var keys = _li(5, 5, 9, 5, 0, 0)
    var knull = _lb(True, False, True, False, True, False)
    var vals = _li(1, 10, 2, 20, 4, 100)
    var t = _keyed_table()
    _fill(t, _kv(keys, knull, vals, _none(6)))
    var res = t.drain_to_record_batch()
    ref out = res.value()
    assert_equal(out.num_rows(), 3, "NULL, 5 and 0")
    assert_true(out.column_at(0).is_null_at(0), "the NULL group's key")
    assert_equal(out.column_at(1).as_primitive[I64]().get(0), Int64(7), "NULL group")
    assert_equal(out.column_at(0).as_primitive[I64]().get(1), Int64(5), "key 5")
    assert_equal(out.column_at(1).as_primitive[I64]().get(1), Int64(30), "key 5")
    assert_equal(out.column_at(0).as_primitive[I64]().get(2), Int64(0), "key 0")
    assert_false(out.column_at(0).is_null_at(2), "key 0 is not NULL")
    assert_equal(out.column_at(1).as_primitive[I64]().get(2), Int64(100), "key 0")


def test_null_key_groups_merge_by_key_across_workers() raises:
    var a = _keyed_table()
    _fill(a, _kv(_li(0, 3), _lb(True, False), _li(1, 2), _none(2)))
    var b = _keyed_table()
    _fill(b, _kv(_li(0, 77), _lb(False, True), _li(10, 20), _none(2)))
    a.combine(b^)
    var res = a.drain_to_record_batch()
    ref out = res.value()
    assert_equal(out.num_rows(), 3, "NULL, 3 and 0")
    assert_true(out.column_at(0).is_null_at(0), "the NULL group first")
    assert_equal(out.column_at(1).as_primitive[I64]().get(0), Int64(21), "NULL: 1 + 20")
    assert_equal(out.column_at(0).as_primitive[I64]().get(2), Int64(0), "key 0 apart")
    assert_equal(out.column_at(1).as_primitive[I64]().get(2), Int64(10), "key 0")


def test_first_and_last_return_the_null_they_pick() raises:
    comptime Fst = AggSlot[HashAggOpAgg[FirstOp[I64], 1]]
    comptime Lst = AggSlot[HashAggOpAgg[LastOp[I64], 1]]
    comptime T = HashAggTable[KeyTuple1[I64, 0], Fst, Lst]
    var t = T(AggBlock[Fst, Lst](Fst(), Lst()))
    # Group 1: NULL, 1 -> first NULL, last 1. Group 2: 2, NULL -> first 2,
    # last NULL.
    var batch = _kv(
        _li(1, 1, 2, 2),
        _none(4),
        _li(_UNDER_NULL, 1, 2, _UNDER_NULL),
        _lb(True, False, False, True),
    )
    var bv = BatchView(batch)
    for r in range(4):
        t.feed_row(bv, r)
    var res = t.drain_to_record_batch()
    ref out = res.value()
    assert_true(out.column_at(1).is_null_at(0), "first() picks the NULL")
    assert_equal(out.column_at(2).as_primitive[I64]().get(0), Int64(1), "last()")
    assert_equal(out.column_at(1).as_primitive[I64]().get(1), Int64(2), "first()")
    assert_true(out.column_at(2).is_null_at(1), "last() picks the NULL")


def test_masked_chunk_fold_skips_null_lanes() raises:
    # The ungrouped SIMD fold: lanes 1 and 6 are NULL, lane 3 masked out.
    comptime T = HashAggTable[KeyTupleScalar, _Sum, _Star]
    var t = T(AggBlock[_Sum, _Star](_Sum(), _Star()))
    var vals = _li(1, _UNDER_NULL, 3, 4, 5, 6, _UNDER_NULL, 8)
    var vnull = _lb(False, True, False, False, False, False, True, False)
    var batch = _kv(_li(0, 0, 0, 0, 0, 0, 0, 0), _none(8), vals, vnull)
    var bv = BatchView(batch)
    t.feed_chunk_global[4](bv, 0, SIMD[DType.bool, 4](True, True, True, False))
    t.feed_chunk_global[4](bv, 4, SIMD[DType.bool, 4](True, True, True, True))
    var res = t.drain_to_record_batch()
    ref out = res.value()
    assert_equal(out.column_at(0).as_primitive[I64]().get(0), Int64(23), "1+3+5+6+8")
    assert_equal(out.column_at(1).as_primitive[I64]().get(0), Int64(7), "7 live rows")


def test_fold_scalar_view_skips_nulls_in_chunks_and_tail() raises:
    # 10 rows: two 4-wide chunks and a 2-row tail; rows 2 and 9 NULL.
    comptime T = HashAggTable[KeyTupleScalar, _Sum, _Cnt, _Star, _Max]
    var t = T(AggBlock[_Sum, _Cnt, _Star, _Max](_Sum(), _Cnt(), _Star(), _Max()))
    var vals = List[Int64]()
    var vnull = List[Bool]()
    for r in range(10):
        vals.append(Int64(r + 1) if r != 2 and r != 9 else _UNDER_NULL)
        vnull.append(r == 2 or r == 9)
    var batch = _kv(_li(0, 0, 0, 0, 0, 0, 0, 0, 0, 0), _none(10), vals, vnull)
    t.fold_scalar_view(BatchView(batch))
    var res = t.drain_to_record_batch()
    ref out = res.value()
    assert_equal(out.column_at(0).as_primitive[I64]().get(0), Int64(42), "55 - 3 - 10")
    assert_equal(out.column_at(1).as_primitive[I64]().get(0), Int64(8), "COUNT(v)")
    assert_equal(out.column_at(2).as_primitive[I64]().get(0), Int64(10), "COUNT(*)")
    assert_equal(out.column_at(3).as_primitive[I64]().get(0), Int64(9), "MAX skips row 9")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
