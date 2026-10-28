# =============================================================================
# CountDistinctAggSink — the segment's filters and the source's pushed filter
# =============================================================================
#
# `consume` applies the segment's OP_FILTER operators and the source's pushed
# filter to a batch before folding it, so the counts are over the rows that
# pass. Each test drives the sink over three workers and compares every output
# group with a count computed in the test from the same generated rows.
#
# What each test asserts:
#   * a segment filter that keeps some rows of every batch counts only the
#     kept rows, grouped and ungrouped;
#   * a batch the filter rejects entirely adds nothing, and a group present
#     only in rejected batches is absent from the output;
#   * a pushed filter alone, and a pushed filter beside a segment filter,
#     count only the rows that pass both;
#   * when every row is rejected, the grouped result has no rows and the
#     ungrouped result is one row of 0.
# =============================================================================

from std.collections import Dict, Set
from std.memory import OwnedPointer, Pointer
from std.testing import TestSuite, assert_equal, assert_true

from komira_arrow.arrow_types import ArrowType
from komira_arrow.column import Column
from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.schema import (
    Field,
    RecordBatch,
    RecordBatchBuilder,
    SchemaBuilder,
)
from komira_collections.slab import Slab
from komira_async.cancellation.token import CancellationToken
from komira_async.ops.waker_sink import NoopSink
from komira_async.reactor.reactor import BACKEND_MOCK
from komira_async.runtime.runtime import PLACEMENT_FIXED, PerCoreAsyncRuntime
from komira_operator_api.memory_reservation import MemoryReservation
from komira_physical_plan.physical_plan import (
    AggSinkData,
    MorselOp,
    ParquetSourceData,
)
from komira_plan_expr.agg_expr import count_distinct
from komira_plan_expr.col_expr import col
from komira_plan_expr.expr import Expr
from komira_plan_ir.logical_plan import AggExprArray, ExprArray

from komira_op_agg_distinct.agg_sink_count_distinct import (
    CountDistinctAggLocal,
    CountDistinctAggSink,
)


comptime _WORKERS: Int = 3
comptime _BATCHES: Int = 6
comptime _ROWS: Int = 120
# Batch index whose values are all at or above this bound, so a `v < 25`
# filter rejects the whole batch.
comptime _BIG: Int64 = 1000


def _noop_sink_factory() -> NoopSink:
    return NoopSink(_placeholder=UInt8(0))


comptime _ONLY_IN_BIG: Int64 = 99


def _key(i: Int, b: Int, big_batch: Int) -> Int64:
    # In the big batch every tenth row is in a group that no other batch has.
    if b == big_batch and i % 10 == 0:
        return _ONLY_IN_BIG
    return Int64(i % 6)


def _val(i: Int, b: Int, big_batch: Int) -> Int64:
    var v = Int64((i * 7 + b * 13) % 50)
    if b == big_batch:
        v += _BIG
    return v


def _batch(b: Int, big_batch: Int) raises -> RecordBatch:
    var k = PrimitiveArray[DType.int64].allocate(_ROWS)
    var v = PrimitiveArray[DType.int64].allocate(_ROWS)
    for i in range(_ROWS):
        k.store[1](i, Scalar[DType.int64](_key(i, b, big_batch)))
        v.store[1](i, Scalar[DType.int64](_val(i, b, big_batch)))
    var sb = SchemaBuilder()
    sb.add_field(Field("k", ArrowType.INT64, False))
    sb.add_field(Field("v", ArrowType.INT64, False))
    var rb = RecordBatchBuilder()
    rb.add_column(Column.from_primitive[DType.int64](k^))
    rb.add_column(Column.from_primitive[DType.int64](v^))
    return rb.build(sb.build())


def _sink(
    grouped: Bool,
    seg_v_lt: Int,
    pushed_k_lt: Int,
) raises -> CountDistinctAggSink:
    var gb = ExprArray()
    if grouped:
        gb.append(col("k").copy_expr())
    var aggs = AggExprArray()
    aggs.append(count_distinct(col("v")).alias("dv"))
    var osb = SchemaBuilder()
    if grouped:
        osb.add_field(Field("k", ArrowType.INT64, False))
    osb.add_field(Field("dv", ArrowType.INT64, False))
    var ops = Slab[MorselOp]()
    if seg_v_lt >= 0:
        ops.append(MorselOp.filter(col("v") < seg_v_lt))
    var pq: ParquetSourceData
    if pushed_k_lt >= 0:
        pq = ParquetSourceData(
            String(""),
            Optional[List[String]](None),
            Optional[Expr](col("k") < pushed_k_lt),
        )
    else:
        pq = ParquetSourceData(
            String(""), Optional[List[String]](None), Optional[Expr](None)
        )
    return CountDistinctAggSink.new(
        AggSinkData(gb^, aggs^, osb.build()), pq^, ops^
    )


def _drive(
    var sink: CountDistinctAggSink, big_batch: Int
) raises -> RecordBatch:
    """Batches 0.._BATCHES-1 go to worker `b % _WORKERS`."""
    var sink_global = sink.init_global()
    var locals = Slab[OwnedPointer[CountDistinctAggLocal]].create(_WORKERS)
    for _ in range(_WORKERS):
        locals.append(OwnedPointer[CountDistinctAggLocal](sink.init_local()))
    for b in range(_BATCHES):
        var w = b % _WORKERS
        ref local = locals[w][]
        sink.consume(w, local, sink_global, _batch(b, big_batch))
    var reservation = MemoryReservation()
    sink.combine(sink_global, locals^, reservation)
    var rt = PerCoreAsyncRuntime[NoopSink](placement=PLACEMENT_FIXED)
    rt.attach_workers(_WORKERS, _noop_sink_factory, BACKEND_MOCK)
    rt.start()
    ref disp = rt.dispatcher()
    var out = sink.finalize(
        sink_global^, Pointer(to=disp), CancellationToken.new()
    )
    var popped = out.output.pop()
    _ = out^
    rt.shutdown()
    return popped.take()


def _expected(
    seg_v_lt: Int, pushed_k_lt: Int, big_batch: Int
) raises -> Dict[Int64, Set[Int64]]:
    var want = Dict[Int64, Set[Int64]]()
    for b in range(_BATCHES):
        for i in range(_ROWS):
            var k = _key(i, b, big_batch)
            var v = _val(i, b, big_batch)
            if seg_v_lt >= 0 and Int(v) >= seg_v_lt:
                continue
            if pushed_k_lt >= 0 and Int(k) >= pushed_k_lt:
                continue
            if k not in want:
                want[k] = Set[Int64]()
            want[k].add(v)
    return want^


def _check_grouped(
    got: RecordBatch, want: Dict[Int64, Set[Int64]]
) raises:
    assert_equal(got.num_rows(), len(want), "one row per surviving group")
    var ka = got.column_at(0).as_primitive[DType.int64]()
    var da = got.column_at(1).as_primitive[DType.int64]()
    for row in range(got.num_rows()):
        var key = ka.get(row)
        assert_true(key in want, "unexpected group " + String(key))
        assert_equal(
            Int(da.get(row)),
            len(want[key]),
            "count(DISTINCT v) of group " + String(key),
        )


def _ungrouped_want(want: Dict[Int64, Set[Int64]]) raises -> Int:
    var all = Set[Int64]()
    for entry in want.items():
        for v in entry.value:
            all.add(v)
    return len(all)


def test_segment_filter_keeps_some_rows_of_every_batch() raises:
    var want = _expected(25, -1, -1)
    var got = _drive(_sink(True, 25, -1), -1)
    _check_grouped(got, want)
    # The filter must have removed values: without it a group sees all 50.
    for entry in want.items():
        assert_true(len(entry.value) < 50, "fixture: the filter removes values")


def test_segment_filter_rejecting_a_whole_batch() raises:
    # Batch 2 has only values >= 1000, so `v < 25` rejects all of it.
    var want = _expected(25, -1, 2)
    var got = _drive(_sink(True, 25, -1), 2)
    _check_grouped(got, want)
    for entry in want.items():
        for v in entry.value:
            assert_true(v < _BIG, "a value from the rejected batch leaked")
    # Group 99 exists only in the rejected batch, so it is not emitted.
    assert_true(_ONLY_IN_BIG not in want, "fixture: group 99 is filtered out")
    assert_equal(got.num_rows(), 6, "the six groups of the other batches")


def test_segment_and_pushed_filter_with_a_rejected_batch() raises:
    # `k < 3` keeps groups 0..2; the segment filter rejects batch 2 whole. Both
    # filters together leave only groups 0..2, each counted over the rows that
    # pass both.
    var want = _expected(25, 3, 2)
    assert_equal(len(want), 3, "fixture: three groups survive")
    var got = _drive(_sink(True, 25, 3), 2)
    _check_grouped(got, want)


def test_pushed_filter_alone() raises:
    var want = _expected(-1, 4, -1)
    assert_equal(len(want), 4, "fixture: four groups pass the pushed filter")
    var got = _drive(_sink(True, -1, 4), -1)
    _check_grouped(got, want)


def test_every_row_rejected_grouped_is_empty() raises:
    # Every value is below 1000 + 50 but the filter keeps only v < 0.
    var got = _drive(_sink(True, 0, -1), -1)
    assert_equal(got.num_rows(), 0, "no row passes, no group is emitted")
    assert_equal(got.num_columns(), 2, "the declared columns are still there")


def test_ungrouped_segment_filter() raises:
    var want = _expected(25, -1, -1)
    var expect = _ungrouped_want(want)
    assert_true(expect > 0 and expect < 50, "fixture: the filter bites")
    var got = _drive(_sink(False, 25, -1), -1)
    assert_equal(got.num_rows(), 1, "ungrouped emits one row")
    var da = got.column_at(0).as_primitive[DType.int64]()
    assert_equal(Int(da.get(0)), expect, "count(DISTINCT v) over kept rows")


def test_ungrouped_pushed_filter_and_segment_filter() raises:
    var want = _expected(25, 2, 2)
    var expect = _ungrouped_want(want)
    var got = _drive(_sink(False, 25, 2), 2)
    var da = got.column_at(0).as_primitive[DType.int64]()
    assert_equal(Int(da.get(0)), expect, "count(DISTINCT v) over kept rows")


def test_every_row_rejected_ungrouped_is_zero() raises:
    var got = _drive(_sink(False, 0, -1), -1)
    assert_equal(got.num_rows(), 1, "ungrouped emits one row")
    var da = got.column_at(0).as_primitive[DType.int64]()
    assert_equal(Int(da.get(0)), 0, "no row passes: the count is 0")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
