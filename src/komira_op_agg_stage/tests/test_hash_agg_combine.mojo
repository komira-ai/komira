# test_hash_agg_combine.mojo — the merges and the parallel drain.
#
# COUNT(DISTINCT): `combine_move_distinct` + `drain_to_record_batch_parallel`
# (value buffers moved, counted together by the radix drain) equals `combine`
# + the serial drain, over workers whose values overlap, are all equal, or one
# of which is empty; NULL values are not counted. The partitioned combine
# (`combine_partition_from` over every partition) equals the serial `combine`.
# MEDIAN: the parallel drain equals the serial one, and a group of only NULLs
# is NULL on both.

from std.collections import List
from std.math import isnan
from std.memory import Pointer
from std.testing import TestSuite, assert_equal, assert_false, assert_true

from komira_arrow.arrow_types import ArrowType
from komira_arrow.batch_view import BatchView
from komira_arrow.column import Column
from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.schema import Field, RecordBatch, RecordBatchBuilder, SchemaBuilder

from komira_async.cancellation.token import CancellationToken
from komira_async.ops.waker_sink import NoopSink
from komira_async.reactor.reactor import BACKEND_MOCK
from komira_async.runtime.runtime import PLACEMENT_FIXED, PerCoreAsyncRuntime

from komira_agg.hash_agg_op_dt import (
    CountDistinctOp,
    HashAggOpAgg,
    MedianOp,
    SumOp,
)

from komira_op_agg_stage.agg_column import AggBlock, AggSlot
from komira_op_agg_stage.hash_agg import HashAggTable
from komira_op_agg_stage.key_block import KeyTuple1, KeyTupleScalar

comptime I64 = DType.int64
comptime _CD = AggSlot[HashAggOpAgg[CountDistinctOp[I64], 1]]
comptime _Scalar = HashAggTable[KeyTupleScalar, _CD]
comptime _Grouped = HashAggTable[KeyTuple1[I64, 0], _CD]


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


def _noop_sink() -> NoopSink:
    return NoopSink(_placeholder=UInt8(0))


def _batch(
    imm keys: List[Int64], imm vals: List[Int64], null_every: Int = 0
) raises -> RecordBatch:
    """k, v; when `null_every > 0`, every `null_every`-th v is NULL with
    999,999 under it."""
    var v = PrimitiveArray[I64].allocate_nullable(len(vals))
    for i in range(len(vals)):
        v.set(i, vals[i])
    if null_every > 0:
        for i in range(len(vals)):
            if i % null_every == null_every - 1:
                v.set(i, Int64(999_999))
                v._set_null(i)
    var rb = RecordBatchBuilder()
    rb.add_column(Column.from_primitive[I64](PrimitiveArray[I64].from_list(keys)))
    rb.add_column(Column.from_primitive[I64](v^))
    var sb = SchemaBuilder()
    sb.add_field(Field("k", ArrowType.INT64, False))
    sb.add_field(Field("v", ArrowType.INT64, True))
    return rb.build(sb.build())


def _zeros(n: Int) -> List[Int64]:
    var out = List[Int64](capacity=n)
    for _ in range(n):
        out.append(0)
    return out^


def _scalar(imm vals: List[Int64], null_every: Int = 0) raises -> _Scalar:
    var t = _Scalar(AggBlock[_CD](_CD()))
    var b = _batch(_zeros(len(vals)), vals, null_every)
    var bv = BatchView(b)
    for r in range(len(vals)):
        t.feed_row(bv, r)
    return t^


def _serial_count(imm w0: List[Int64], imm w1: List[Int64], null_every: Int = 0) raises -> Int64:
    var merged = _Scalar(AggBlock[_CD](_CD()))
    merged.combine(_scalar(w0, null_every))
    merged.combine(_scalar(w1, null_every))
    var res = merged.drain_to_record_batch()
    return res.value().column_at(0).as_primitive[I64]().get(0)


def _moved_count(imm w0: List[Int64], imm w1: List[Int64], null_every: Int = 0) raises -> Int64:
    var rt = PerCoreAsyncRuntime[NoopSink](placement=PLACEMENT_FIXED)
    rt.attach_workers(4, _noop_sink, BACKEND_MOCK)
    rt.start()
    ref disp = rt.dispatcher()
    var merged = _Scalar(AggBlock[_CD](_CD()))
    merged.combine_move_distinct(_scalar(w0, null_every))
    merged.combine_move_distinct(_scalar(w1, null_every))
    var res = merged.drain_to_record_batch_parallel(
        Pointer(to=disp), CancellationToken.never()
    )
    var got = res.value().column_at(0).as_primitive[I64]().get(0)
    rt.shutdown()
    return got


def test_scalar_count_distinct_move_equals_serial_overlapping() raises:
    var w0 = _li(1, 2, 7, 8, 2, 7)
    var w1 = _li(7, 8, 9, 8, 3)
    assert_equal(_serial_count(w0, w1), Int64(6), "{1,2,3,7,8,9}")
    assert_equal(_moved_count(w0, w1), Int64(6), "moved runs dedup together")


def test_scalar_count_distinct_all_same_across_workers() raises:
    var w0 = _li(42, 42, 42, 42)
    var w1 = _li(42, 42, 42)
    assert_equal(_moved_count(w0, w1), Int64(1), "moved")
    assert_equal(_serial_count(w0, w1), Int64(1), "serial")


def test_scalar_count_distinct_one_empty_worker() raises:
    var w0 = _li(5, 6, 7, 5, 6)
    var w1 = List[Int64]()
    assert_equal(_moved_count(w0, w1), Int64(3), "moved")
    assert_equal(_serial_count(w0, w1), Int64(3), "serial")


def test_count_distinct_does_not_count_nulls() raises:
    # Every 3rd value is NULL (999,999 under it): w0 keeps {1, 2, 4},
    # w1 keeps {1, 7}.
    var w0 = _li(1, 2, 3, 4, 2, 6)
    var w1 = _li(1, 7, 9)
    assert_equal(_serial_count(w0, w1, 3), Int64(4), "serial: {1,2,4,7}")
    assert_equal(_moved_count(w0, w1, 3), Int64(4), "moved: {1,2,4,7}")


def _count_for_key(imm rb: RecordBatch, key: Int64) raises -> Int64:
    var kc = rb.column_at(0).as_primitive[I64]()
    var vc = rb.column_at(1).as_primitive[I64]()
    for r in range(rb.num_rows()):
        if kc.get(r) == key:
            return vc.get(r)
    raise Error("no group " + String(key))


def _grouped(imm keys: List[Int64], imm vals: List[Int64]) raises -> _Grouped:
    var t = _Grouped(AggBlock[_CD](_CD()))
    var b = _batch(keys, vals)
    var bv = BatchView(b)
    for r in range(len(vals)):
        t.feed_row(bv, r)
    return t^


def test_grouped_count_distinct_move_equals_serial() raises:
    # k=10: {100,200} + {100,300} -> 3; k=20: {5,6} -> 2; k=30: {9} -> 1.
    var k0 = _li(10, 10, 10, 20, 20)
    var v0 = _li(100, 200, 100, 5, 6)
    var k1 = _li(10, 10, 30)
    var v1 = _li(100, 300, 9)
    var s = _Grouped(AggBlock[_CD](_CD()))
    s.combine(_grouped(k0, v0))
    s.combine(_grouped(k1, v1))
    var sres = s.drain_to_record_batch()
    assert_equal(_count_for_key(sres.value(), 10), Int64(3), "serial 10")
    assert_equal(_count_for_key(sres.value(), 20), Int64(2), "serial 20")
    assert_equal(_count_for_key(sres.value(), 30), Int64(1), "serial 30")

    var rt = PerCoreAsyncRuntime[NoopSink](placement=PLACEMENT_FIXED)
    rt.attach_workers(4, _noop_sink, BACKEND_MOCK)
    rt.start()
    ref disp = rt.dispatcher()
    var m = _Grouped(AggBlock[_CD](_CD()))
    m.combine_move_distinct(_grouped(k0, v0))
    m.combine_move_distinct(_grouped(k1, v1))
    var mres = m.drain_to_record_batch_parallel(
        Pointer(to=disp), CancellationToken.never()
    )
    assert_equal(mres.value().num_rows(), 3, "three groups")
    assert_equal(_count_for_key(mres.value(), 10), Int64(3), "moved 10")
    assert_equal(_count_for_key(mres.value(), 20), Int64(2), "moved 20")
    assert_equal(_count_for_key(mres.value(), 30), Int64(1), "moved 30")
    rt.shutdown()


comptime _Sum = AggSlot[HashAggOpAgg[SumOp[I64], 1]]
comptime _SumT = HashAggTable[KeyTuple1[I64, 0], _Sum]


def _sum_table(base: Int, n: Int) raises -> _SumT:
    # Keys base..base+n-1 (mod 3000), value = key + 1.
    var keys = List[Int64]()
    var vals = List[Int64]()
    for r in range(n):
        var k = Int64((base + r) % 3_000)
        keys.append(k)
        vals.append(k + 1)
    var t = _SumT(AggBlock[_Sum](_Sum()))
    var b = _batch(keys, vals)
    var bv = BatchView(b)
    for r in range(n):
        t.feed_row(bv, r)
    return t^


def test_partitioned_combine_equals_serial_combine() raises:
    var w0 = _sum_table(0, 2_000)
    var w1 = _sum_table(1_500, 2_000)
    assert_equal(w0.n_combine_partitions(), 1, "below 4,096 groups: serial")
    w0.with_radix_min_groups(2)
    var parts = w0.n_combine_partitions()
    assert_equal(parts, 2, "2,000 groups / 1,024 -> 2 partitions")
    var serial = _SumT(AggBlock[_Sum](_Sum()))
    serial.combine(_sum_table(0, 2_000))
    serial.combine(_sum_table(1_500, 2_000))
    var total_groups = 0
    var seen = List[Int64](capacity=3_000)
    for _ in range(3_000):
        seen.append(0)
    for p in range(parts):
        var acc = _SumT(AggBlock[_Sum](_Sum()))
        acc.combine_partition_from(w0, p, parts)
        acc.combine_partition_from(w1, p, parts)
        total_groups += acc.size()
        var res = acc.drain_to_record_batch()
        var kc = res.value().column_at(0).as_primitive[I64]()
        var vc = res.value().column_at(1).as_primitive[I64]()
        for r in range(res.value().num_rows()):
            seen[Int(kc.get(r))] += vc.get(r)
    assert_equal(total_groups, serial.size(), "partitions are disjoint")
    var sres = serial.drain_to_record_batch()
    var skc = sres.value().column_at(0).as_primitive[I64]()
    var svc = sres.value().column_at(1).as_primitive[I64]()
    for r in range(sres.value().num_rows()):
        assert_equal(seen[Int(skc.get(r))], svc.get(r), "group sum")


def test_partition_count_scales_with_groups() raises:
    var t = _sum_table(0, 3_000)
    t.with_radix_min_groups(2)
    assert_equal(t.n_combine_partitions(), 2, "3,000 groups")
    var s = HashAggTable[KeyTupleScalar, _Sum](AggBlock[_Sum](_Sum()))
    s.with_radix_min_groups(0)
    assert_equal(s.n_combine_partitions(), 1, "ungrouped: one partition")


comptime _Med = AggSlot[HashAggOpAgg[MedianOp[I64], 1]]
comptime _MedT = HashAggTable[KeyTuple1[I64, 0], _Med]


def _median_table(null_group: Bool) raises -> _MedT:
    # 600 groups (above the 256-group parallel gate), 1 + k % 5 values each.
    # With `null_group`, group 0's only values are NULL.
    var keys = List[Int64]()
    var vals = List[Int64]()
    var nulls = List[Bool]()
    for k in range(600):
        for i in range(1 + k % 5):
            keys.append(Int64(k))
            vals.append(Int64((k * 31 + i * 17) % 101))
            nulls.append(null_group and k == 0)
    var v = PrimitiveArray[I64].allocate_nullable(len(vals))
    for i in range(len(vals)):
        v.set(i, vals[i])
    for i in range(len(vals)):
        if nulls[i]:
            v._set_null(i)
    var rb = RecordBatchBuilder()
    rb.add_column(Column.from_primitive[I64](PrimitiveArray[I64].from_list(keys)))
    rb.add_column(Column.from_primitive[I64](v^))
    var sb = SchemaBuilder()
    sb.add_field(Field("k", ArrowType.INT64, False))
    sb.add_field(Field("v", ArrowType.INT64, True))
    var b = rb.build(sb.build())
    var t = _MedT(AggBlock[_Med](_Med()))
    var bv = BatchView(b)
    for r in range(bv.n_rows()):
        t.feed_row(bv, r)
    return t^


def _check_median_parallel_equals_serial(null_group: Bool) raises:
    var t = _median_table(null_group)
    var sres = t.drain_to_record_batch()
    var rt = PerCoreAsyncRuntime[NoopSink](placement=PLACEMENT_FIXED)
    rt.attach_workers(4, _noop_sink, BACKEND_MOCK)
    rt.start()
    ref disp = rt.dispatcher()
    var pres = t.drain_to_record_batch_parallel(
        Pointer(to=disp), CancellationToken.never()
    )
    rt.shutdown()
    ref s = sres.value()
    ref p = pres.value()
    assert_equal(p.num_rows(), s.num_rows(), "rows")
    var sc = s.column_at(1).as_primitive[DType.float64]()
    var pc = p.column_at(1).as_primitive[DType.float64]()
    for r in range(s.num_rows()):
        assert_equal(
            p.column_at(1).is_null_at(r), s.column_at(1).is_null_at(r), "null"
        )
        if not s.column_at(1).is_null_at(r):
            assert_equal(pc.get(r), sc.get(r), "median of group " + String(r))
    if null_group:
        assert_true(s.column_at(1).is_null_at(0), "MEDIAN of only NULLs")
    # Group 3 holds 4 values: (3*31 + 17i) % 101 for i in 0..3 = 93, 9, 26, 43;
    # the median of {9, 26, 43, 93} is 34.5.
    assert_equal(sc.get(3), Float64(34.5), "group 3")


def test_median_parallel_drain_equals_serial() raises:
    _check_median_parallel_equals_serial(False)


def test_median_with_a_null_group_is_null_on_both_drains() raises:
    _check_median_parallel_equals_serial(True)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
