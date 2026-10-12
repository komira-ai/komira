# =============================================================================
# CountDistinctAggSink — a MIXED aggregate through the sink, across workers
# =============================================================================
#
# `SELECT k, count(DISTINCT v), sum(v), count(*), min(f), max(f), avg(v)
#  GROUP BY k` over four workers, driven through `consume`, `combine` and
# `finalize`. Every output column is compared, row by row, with an oracle
# computed in this test from the raw arrays. What it kills:
#   * the fixed cells merged across workers onto the wrong global group (each
#     worker sees the groups in a different first-seen order here);
#   * an output column emitted out of the plan's order (the plan interleaves
#     the COUNT(DISTINCT) with the fixed aggregates);
#   * MIN / MAX that do not follow DuckDB's order, in which NaN is the
#     largest value: a group holding a NaN answers MAX = NaN and its MIN is
#     the smallest number, including when the NaN reaches the merge from one
#     worker and the numbers from another;
#   * a NULL key that is grouped with a real key (NULL rows form ONE group
#     whose key reads back as NULL);
#   * a NULL value counted by COUNT(DISTINCT) or folded into SUM / MIN / MAX.
# =============================================================================

from std.collections import Dict, List, Optional, Set
from std.math import isnan
from std.memory import OwnedPointer, Pointer
from std.testing import TestSuite, assert_equal, assert_true

from komira_arrow.arrow_types import ArrowType
from komira_arrow.column import Column
from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.schema import (
    Field, RecordBatch, RecordBatchBuilder, SchemaBuilder,
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
from komira_plan_expr.agg_expr import (
    count, count_distinct, max, mean, min, sum,
)
from komira_plan_expr.col_expr import col
from komira_plan_expr.expr import Expr
from komira_plan_ir.logical_plan import AggExprArray, ExprArray

from komira_op_agg_distinct.agg_sink_count_distinct import (
    CountDistinctAggLocal,
    CountDistinctAggSink,
)


comptime _WORKERS: Int = 4
comptime _BATCHES_PER_WORKER: Int = 3
comptime _ROWS: Int = 400
# The key that stands for NULL in the oracle; no real key equals it.
comptime _NULL_KEY: Int64 = -999_999


def _noop_sink_factory() -> NoopSink:
    return NoopSink(_placeholder=UInt8(0))


def _nan() -> Float64:
    return Float64(0) / Float64(0)


struct _Rows(Movable):
    var k: List[Int64]
    var k_null: List[Bool]
    var v: List[Int64]
    var v_null: List[Bool]
    var f: List[Float64]

    def __init__(out self):
        self.k = List[Int64]()
        self.k_null = List[Bool]()
        self.v = List[Int64]()
        self.v_null = List[Bool]()
        self.f = List[Float64]()


def _rows(w: Int, b: Int) -> _Rows:
    """Worker `w`'s batch `b`. Keys start at a different group per worker, so
    each worker numbers the groups in a different order. Group 3's NaN arrives
    only from worker 2; every 37th row has a NULL key, every 11th a NULL v."""
    var r = _Rows()
    for i in range(_ROWS):
        var g = (i + w * 3 + b) % 7
        r.k.append(Int64(g))
        r.k_null.append(i % 37 == 5)
        r.v.append(Int64((i * 13 + w * 101 + b * 7) % 50))
        r.v_null.append(i % 11 == 3)
        var fv = Float64(((i * 31 + w * 17) % 200) - 100) / 4.0
        if g == 3 and w == 2 and i % 50 == 1:
            fv = _nan()
        r.f.append(fv)
    return r^


def _batch(imm r: _Rows) raises -> RecordBatch:
    var n = len(r.k)
    var ka = PrimitiveArray[DType.int64].allocate_nullable(n)
    var va = PrimitiveArray[DType.int64].allocate_nullable(n)
    var fa = PrimitiveArray[DType.float64].allocate(n)
    for i in range(n):
        ka.store[1](i, Scalar[DType.int64](r.k[i]))
        va.store[1](i, Scalar[DType.int64](r.v[i]))
        fa.store[1](i, Scalar[DType.float64](r.f[i]))
    var kn = 0
    var vn = 0
    for i in range(n):
        if r.k_null[i]:
            ka._set_null(i)
            kn += 1
        if r.v_null[i]:
            va._set_null(i)
            vn += 1
    ka.null_count = kn
    va.null_count = vn
    var sb = SchemaBuilder()
    sb.add_field(Field("k", ArrowType.INT64, True))
    sb.add_field(Field("v", ArrowType.INT64, True))
    sb.add_field(Field("f", ArrowType.FLOAT64, False))
    var rb = RecordBatchBuilder()
    rb.add_column(Column.from_primitive[DType.int64](ka^))
    rb.add_column(Column.from_primitive[DType.int64](va^))
    rb.add_column(Column.from_primitive[DType.float64](fa^))
    return rb.build(sb.build())


def _sink() raises -> CountDistinctAggSink:
    var group_by = ExprArray()
    group_by.append(col("k").copy_expr())
    var aggs = AggExprArray()
    aggs.append(count_distinct(col("v")).alias("cd"))
    aggs.append(sum(col("v")).alias("s"))
    aggs.append(count().alias("c"))
    aggs.append(min(col("f")).alias("mn"))
    aggs.append(max(col("f")).alias("mx"))
    aggs.append(mean(col("v")).alias("av"))
    var osb = SchemaBuilder()
    osb.add_field(Field("k", ArrowType.INT64, True))
    osb.add_field(Field("cd", ArrowType.INT64, False))
    osb.add_field(Field("s", ArrowType.INT64, True))
    osb.add_field(Field("c", ArrowType.INT64, False))
    osb.add_field(Field("mn", ArrowType.FLOAT64, True))
    osb.add_field(Field("mx", ArrowType.FLOAT64, True))
    osb.add_field(Field("av", ArrowType.FLOAT64, True))
    var pq = ParquetSourceData(
        String(""), Optional[List[String]](None), Optional[Expr](None)
    )
    return CountDistinctAggSink(
        AggSinkData(group_by^, aggs^, osb.build()), pq^, Slab[MorselOp]()
    )


struct _Want(Copyable, Movable):
    var cd: Set[Int64]
    var s: Int64
    var nv: Int
    var c: Int
    var mn: Float64
    var mx: Float64
    var has_nan: Bool
    var nf: Int

    def __init__(out self):
        self.cd = Set[Int64]()
        self.s = 0
        self.nv = 0
        self.c = 0
        self.mn = 0
        self.mx = 0
        self.has_nan = False
        self.nf = 0


def _same_f(a: Float64, b: Float64) -> Bool:
    if isnan(a) or isnan(b):
        return isnan(a) and isnan(b)
    return a == b


def test_mixed_aggregate_matches_the_oracle_row_for_row() raises:
    var sink = _sink()
    var sink_global = sink.init_global()
    var locals = Slab[OwnedPointer[CountDistinctAggLocal]].create(_WORKERS)
    for _ in range(_WORKERS):
        locals.append(OwnedPointer[CountDistinctAggLocal](sink.init_local()))
    var want = Dict[Int64, _Want]()
    for w in range(_WORKERS):
        for b in range(_BATCHES_PER_WORKER):
            var r = _rows(w, b)
            for i in range(len(r.k)):
                var key = _NULL_KEY if r.k_null[i] else r.k[i]
                if key not in want:
                    want[key] = _Want()
                ref o = want[key]
                o.c += 1
                if not r.v_null[i]:
                    o.cd.add(r.v[i])
                    o.s += r.v[i]
                    o.nv += 1
                var fv = r.f[i]
                if isnan(fv):
                    o.has_nan = True
                else:
                    if o.nf == 0 or fv < o.mn:
                        o.mn = fv
                    if o.nf == 0 or fv > o.mx:
                        o.mx = fv
                    o.nf += 1
            ref local = locals[w][]
            sink.consume(w, local, sink_global, _batch(r))
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
    var got = popped.take()

    assert_equal(got.num_rows(), len(want), "one row per group, NULL included")
    assert_true(_NULL_KEY in want, "fixture: the NULL key group exists")
    assert_true(want[Int64(3)].has_nan, "fixture: group 3 holds a NaN")
    ref kc = got.column_at(0)
    var ka = kc.as_primitive[DType.int64]()
    var cda = got.column_at(1).as_primitive[DType.int64]()
    var sa = got.column_at(2).as_primitive[DType.int64]()
    var ca = got.column_at(3).as_primitive[DType.int64]()
    var mna = got.column_at(4).as_primitive[DType.float64]()
    var mxa = got.column_at(5).as_primitive[DType.float64]()
    var ava = got.column_at(6).as_primitive[DType.float64]()
    var seen = Set[Int64]()
    for row in range(got.num_rows()):
        var key = _NULL_KEY if kc.is_null_at(row) else ka.get(row)
        assert_true(key in want, "unknown group " + String(key))
        assert_true(key not in seen, "group emitted twice: " + String(key))
        seen.add(key)
        ref o = want[key]
        var tag = "group " + String(key) + ": "
        assert_equal(Int(cda.get(row)), len(o.cd), tag + "count(DISTINCT v)")
        assert_equal(sa.get(row), o.s, tag + "sum(v)")
        assert_equal(Int(ca.get(row)), o.c, tag + "count(*)")
        assert_true(_same_f(mna.get(row), o.mn), tag + "min(f)")
        var want_mx = _nan() if o.has_nan else o.mx
        assert_true(
            _same_f(mxa.get(row), want_mx),
            tag + "max(f) " + String(mxa.get(row)) + " want "
            + String(want_mx),
        )
        assert_true(
            _same_f(ava.get(row), Float64(o.s) / Float64(o.nv)),
            tag + "avg(v)",
        )
    rt.shutdown()


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
