# =============================================================================
# test_cd_parallel_agrees_with_sink -- one grouped COUNT(DISTINCT) input gives
# the same per-group counts through the hash-partitioned driver and through the
# `CountDistinctAggSink` morsel sink
# =============================================================================
#
# Two implementations answer `SELECT k, COUNT(DISTINCT v) GROUP BY k`; nothing
# else keeps them agreeing. The same 70,000 rows go through both (the sink fed
# as four morsels on one worker, then combined and finalized as an executor
# does) and the per-group counts are compared as maps, since GROUP BY promises
# no row order. A fixture with few groups and one with many groups, because the
# sink counts a few groups and many groups on different arms.
# =============================================================================

from std.collections import Dict
from std.memory import OwnedPointer, Pointer
from std.testing import TestSuite, assert_equal

from komira_arrow.arrow_types import ArrowType
from komira_arrow.column import Column
from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.schema import Field, RecordBatch, RecordBatchBuilder, SchemaBuilder
from komira_async.cancellation.token import CancellationToken
from komira_async.ops.waker_sink import NoopSink
from komira_async.reactor.reactor import BACKEND_MOCK
from komira_async.runtime.runtime import PLACEMENT_FIXED, PerCoreAsyncRuntime
from komira_collections.slab import Slab
from komira_column_kernels.compiler_helpers import copy_batch
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

from komira_op_agg_distinct.agg_count_distinct_parallel import (
    _execute_count_distinct_agg_parallel,
)
from komira_op_agg_distinct.agg_sink_count_distinct import (
    CountDistinctAggLocal,
    CountDistinctAggSink,
)

comptime _ROWS: Int = 70_000
comptime _WORKERS: Int = 4


def _noop_sink_factory() -> NoopSink:
    return NoopSink(_placeholder=UInt8(0))


def _batch(num_keys: Int, distinct: Int, lo: Int, hi: Int) raises -> RecordBatch:
    """Rows `[lo, hi)` of the fixture: key `r % num_keys`, value
    `(r // num_keys) % distinct` (values repeat across morsels)."""
    var n = hi - lo
    var ks = PrimitiveArray[DType.int64].allocate(n)
    var vs = PrimitiveArray[DType.int64].allocate(n)
    for i in range(n):
        var r = lo + i
        ks.set(i, Int64(r % num_keys))
        vs.set(i, Int64((r // num_keys) % distinct))
    var sb = SchemaBuilder()
    sb.add_field(Field("k", ArrowType.INT64, False))
    sb.add_field(Field("v", ArrowType.INT64, False))
    var b = RecordBatchBuilder.with_capacity(2)
    b.add_column(Column.from_primitive[DType.int64](ks))
    b.add_column(Column.from_primitive[DType.int64](vs))
    return b.build(sb.build())


def _agg_data() raises -> AggSinkData:
    var group_by = ExprArray()
    group_by.append(col("k").copy_expr())
    var aggs = AggExprArray()
    aggs.append(count_distinct(col("v")).alias("dv"))
    var osb = SchemaBuilder()
    osb.add_field(Field("k", ArrowType.INT64, False))
    osb.add_field(Field("dv", ArrowType.INT64, False))
    return AggSinkData(group_by^, aggs^, osb.build())


def _group_map(imm rb: RecordBatch) raises -> Dict[Int, Int]:
    var keys = rb.column_at(0).as_primitive[DType.int64]()
    var cnts = rb.column_at(1).as_primitive[DType.int64]()
    var out = Dict[Int, Int]()
    for r in range(rb.num_rows()):
        var k = Int(keys.get(r))
        if k in out:
            raise Error("key " + String(k) + " emitted twice")
        out[k] = Int(cnts.get(r))
    return out^


def _through_driver(num_keys: Int, distinct: Int) raises -> Dict[Int, Int]:
    var batch = _batch(num_keys, distinct, 0, _ROWS)
    var sink = _agg_data()
    var rt = PerCoreAsyncRuntime[NoopSink](placement=PLACEMENT_FIXED)
    rt.attach_workers(_WORKERS, _noop_sink_factory, BACKEND_MOCK)
    rt.start()
    ref disp = rt.dispatcher()
    var ct = CancellationToken.new()
    var rb = _execute_count_distinct_agg_parallel(
        disp, ct.clone(), batch, sink, 1, 1, _ROWS
    )
    return _group_map(rb)


def _through_sink(num_keys: Int, distinct: Int) raises -> Dict[Int, Int]:
    var sink = CountDistinctAggSink.new(
        _agg_data(),
        ParquetSourceData(String(""), Optional[List[String]](None), Optional[Expr](None)),
        Slab[MorselOp](),
    )
    var rt = PerCoreAsyncRuntime[NoopSink](
        num_workers=1,
        sink_factory=_noop_sink_factory,
        backend=BACKEND_MOCK,
        placement=PLACEMENT_FIXED,
    )
    var sink_global = sink.init_global()
    var locals = Slab[OwnedPointer[CountDistinctAggLocal]].create(1)
    locals.append(OwnedPointer[CountDistinctAggLocal](sink.init_local()))
    var step = _ROWS // 4
    for m in range(4):
        sink.consume(0, locals[0][], sink_global, _batch(num_keys, distinct, m * step, (m + 1) * step))
    var reservation = MemoryReservation()
    sink.combine(sink_global, locals^, reservation)
    ref disp = rt.dispatcher()
    var out = sink.finalize(sink_global^, Pointer(to=disp), CancellationToken.new())
    assert_equal(len(out.output), 1, "finalize emits one batch")
    var batch = out.output.pop()
    var rb = batch.take()
    _ = out^
    return _group_map(rb)


def _assert_agree(num_keys: Int, distinct: Int) raises:
    var a = _through_driver(num_keys, distinct)
    var b = _through_sink(num_keys, distinct)
    assert_equal(len(a), num_keys, "the driver emits one row per key")
    assert_equal(len(a), len(b), "group count")
    for e in b.items():
        assert_equal(a[e.key], e.value, "key " + String(e.key))


def test_few_groups_agree() raises:
    _assert_agree(7, 40)


def test_many_groups_agree() raises:
    _assert_agree(997, 13)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
