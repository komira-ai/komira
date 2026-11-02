# =============================================================================
# A hand-built plan: scan, filter, grouped aggregation, through the driver
# =============================================================================
#
# `group_batch` rows 0 .. 2999 are written to Parquet in twelve row groups and
# the plan is
#
#   SELECT k1, k2, COUNT(*), SUM(v), SUM(d) FROM t WHERE id >= 100
#   GROUP BY k1, k2
#
# as one segment: SOURCE_PARQUET, OP_FILTER, and SINK_AGG with an INT64 key row
# (the keys are an INT64 and an INT32, both with NULLs). The expected groups
# are computed here, row by row, from the row number alone with a `Dict` from
# the key's text to a tally. What the tests prove:
#
#   * The plan's answer equals the oracle's on one, three and seven workers
#     and on morsels that do not divide the row groups: the same groups, the
#     same COUNT(*), SUM(v) and DECIMAL SUM(d), a NULL key in groups of its
#     own, and the pool whole again after each run.
#   * On the runtime's threaded dispatcher, four workers share the scan and
#     each fold into their own table, run after run, on a runtime stopped and
#     started again between rounds.
#   * With a memory budget the group tables outgrow (one group per row), the
#     run fails by name instead of allocating, and the pool is whole again.

from std.collections import Dict
from std.testing import TestSuite, assert_equal, assert_raises, assert_true

from komira_arrow.arrow_types import ArrowType
from komira_arrow.schema import Field, RecordBatch, Schema, SchemaBuilder
from komira_async.ops.waker_sink import NoopSink
from komira_async.reactor.reactor import BACKEND_MOCK
from komira_async.runtime.runtime import PLACEMENT_FIXED, PerCoreAsyncRuntime
from komira_async_api.token import CancellationToken
from komira_collections.slab import Slab
from komira_parquet.runtime_footer_cache import ParquetMetadataCache
from komira_parquet_writer.record_batch_writer import (
    write_record_batch_to_parquet_bytes,
)
from komira_physical_plan.physical_plan import (
    AggSinkData,
    KEY_DTYPE_I64,
    MorselOp,
    SegmentDescPod,
)
from komira_pipeline_exec.fake_dispatch import InlineDispatch
from komira_pipeline_exec.group_harness import (
    d_null,
    d_unscaled,
    group_batch,
    k1_null,
    k1_value,
    k2_null,
    k2_value,
    v_null,
    v_value,
)
from komira_pipeline_exec.plan_harness import (
    chain,
    grouped_agg_data,
    parquet_segment,
    with_group_sink,
)
from komira_pipeline_exec.real_builder import RealBuilder
from komira_pipeline_exec.run_plan import run_plan
from komira_plan_expr.agg_expr import AGG_COUNT, AGG_SUM, AggExpr
from komira_plan_expr.expr import BIN_GE, Expr
from komira_plan_expr.expr_pool import ExprPool
from komira_plan_expr.scalar_value import ScalarValue
from komira_runtime_paths import test_tmpdir
from komira_scalar_arithmetic.decimal_arith import I128

comptime ROWS = 3000
comptime FIRST = 100


def _write(name: String) raises -> String:
    var path = test_tmpdir() + "/" + name + ".parquet"
    var bytes = write_record_batch_to_parquet_bytes(
        group_batch(0, ROWS), max_rows_per_rg=250
    )
    var fh = open(path, "w")
    fh.write_bytes(Span(bytes))
    fh.close()
    return path^


def _sum(func: UInt8, col: String) -> AggExpr:
    return AggExpr(func, Optional(Expr.col_ref(col)), None)


def _data() raises -> AggSinkData:
    var keys = Slab[Expr]()
    keys.append(Expr.col_ref("k1"))
    keys.append(Expr.col_ref("k2"))
    var aggs = Slab[AggExpr]()
    aggs.append(AggExpr(AGG_COUNT, None, None))
    aggs.append(_sum(AGG_SUM, "v"))
    aggs.append(_sum(AGG_SUM, "d"))
    var sb = SchemaBuilder()
    sb.add_field(Field("k1", ArrowType.INT64, True))
    sb.add_field(Field("k2", ArrowType.INT32, True))
    sb.add_field(Field("n", ArrowType.INT64, False))
    sb.add_field(Field("sv", ArrowType.INT64, True))
    sb.add_field(Field.decimal128("sd", 38, 2, True))
    return grouped_agg_data(keys^, aggs^, sb.build())


def _ids_data() raises -> AggSinkData:
    var keys = Slab[Expr]()
    keys.append(Expr.col_ref("id"))
    var aggs = Slab[AggExpr]()
    aggs.append(AggExpr(AGG_COUNT, None, None))
    var sb = SchemaBuilder()
    sb.add_field(Field("id", ArrowType.INT64, False))
    sb.add_field(Field("n", ArrowType.INT64, False))
    return grouped_agg_data(keys^, aggs^, sb.build())


def _plan(path: String, sink_id: Int, morsel_rows: Int) -> List[SegmentDescPod]:
    var filter = Expr.binary(
        BIN_GE, Expr.col_ref("id"), Expr.literal(ScalarValue.from_int(FIRST))
    )
    var out = List[SegmentDescPod]()
    out.append(
        with_group_sink(
            parquet_segment(
                0, path, None, None, chain(MorselOp.filter(filter^)), morsel_rows
            ),
            sink_id,
            KEY_DTYPE_I64,
        )
    )
    return out^


struct _Tally(Copyable, Movable):
    var n: Int
    var sum_v: Int
    var cnt_v: Int
    var sum_d: Int
    var cnt_d: Int

    def __init__(out self):
        self.n = 0
        self.sum_v = 0
        self.cnt_v = 0
        self.sum_d = 0
        self.cnt_d = 0


def _check(ref out: RecordBatch) raises:
    var index = Dict[String, Int]()
    var tallies = List[_Tally]()
    for r in range(FIRST, ROWS):
        var key = (String("N") if k1_null(r) else String(k1_value(r))) + "|" + (
            String("N") if k2_null(r) else String(k2_value(r))
        )
        if key not in index:
            index[key] = len(tallies)
            tallies.append(_Tally())
        var at = index[key]
        tallies[at].n += 1
        if not v_null(r):
            tallies[at].sum_v += v_value(r)
            tallies[at].cnt_v += 1
        if not d_null(r):
            tallies[at].sum_d += d_unscaled(r)
            tallies[at].cnt_d += 1
    assert_equal(out.num_rows(), len(tallies), "number of groups")
    var seen = List[Bool](length=len(tallies), fill=False)
    var k1 = out.column_at(0).as_primitive[DType.int64]()
    var k2 = out.column_at(1).as_primitive[DType.int32]()
    var n = out.column_at(2).as_primitive[DType.int64]()
    var sv = out.column_at(3).as_primitive[DType.int64]()
    var sd = out.column_at(4).as_decimal128()
    for i in range(out.num_rows()):
        var key = (
            String("N") if out.column_at(0).is_null_at(i) else String(
                Int(k1.get(i))
            )
        ) + "|" + (
            String("N") if out.column_at(1).is_null_at(i) else String(
                Int(k2.get(i))
            )
        )
        assert_true(key in index, "unexpected group " + key)
        var at = index[key]
        assert_true(not seen[at], "group " + key + " twice")
        seen[at] = True
        assert_equal(Int(n.get(i)), tallies[at].n, "COUNT(*) of " + key)
        assert_equal(
            out.column_at(3).is_null_at(i), tallies[at].cnt_v == 0
        )
        if tallies[at].cnt_v > 0:
            assert_equal(Int(sv.get(i)), tallies[at].sum_v, "SUM(v) " + key)
        assert_equal(
            out.column_at(4).is_null_at(i), tallies[at].cnt_d == 0
        )
        if tallies[at].cnt_d > 0:
            assert_true(
                sd.get_i128(i) == I128(tallies[at].sum_d), "SUM(d) " + key
            )
    for at in range(len(seen)):
        assert_true(seen[at], "a group of the oracle is missing")


def _run_inline(path: String, workers: Int, morsel_rows: Int) raises:
    var cache = ParquetMetadataCache()
    var pool = ExprPool()
    var nf = 0
    var builder = RealBuilder[origin_of(cache), origin_of(pool), origin_of(nf)](
        cache, pool
    )
    var id = builder.add_agg_sink(_data())
    var dispatch = InlineDispatch()
    var out = run_plan(
        _plan(path, id, morsel_rows),
        builder,
        dispatch,
        workers,
        CancellationToken.new(),
    )
    assert_equal(builder.pool_granted(), 0)
    var batch = out.take(0)
    _check(batch)


def test_the_plan_matches_the_oracle_on_any_worker_count_and_morsel_size() raises:
    var path = _write("group_plan")
    _run_inline(path, 1, 0)
    _run_inline(path, 3, 64)
    _run_inline(path, 7, 100)
    _run_inline(path, 2, 333)


def test_a_budget_the_groups_outgrow_fails_the_run_by_name() raises:
    var path = _write("group_plan_budget")
    var cache = ParquetMetadataCache()
    var pool = ExprPool()
    var nf = 0
    var builder = RealBuilder[origin_of(cache), origin_of(pool), origin_of(nf)](
        cache, pool
    )
    builder.set_memory_budget(100_000)
    var id = builder.add_agg_sink(_ids_data())
    var dispatch = InlineDispatch()
    with assert_raises(contains="memory pool for its group table"):
        _ = run_plan(
            _plan(path, id, 64), builder, dispatch, 3, CancellationToken.new()
        )
    assert_equal(builder.pool_granted(), 0)
    # Without the bound the same plan returns one group per kept row.
    builder.set_memory_budget(-1)
    var out = run_plan(
        _plan(path, id, 64), builder, dispatch, 3, CancellationToken.new()
    )
    assert_equal(out.take(0).num_rows(), ROWS - FIRST)
    assert_equal(builder.pool_granted(), 0)


# --- threads ----------------------------------------------------------------

comptime WORKERS = 4
comptime RUNS = 15


def _make_noop_sink() -> NoopSink:
    return NoopSink(_placeholder=UInt8(0))


def _started_runtime() raises -> PerCoreAsyncRuntime[NoopSink]:
    var rt = PerCoreAsyncRuntime[NoopSink](placement=PLACEMENT_FIXED)
    rt.attach_workers(WORKERS, _make_noop_sink, BACKEND_MOCK)
    rt.start()
    return rt^


def _run_many(mut rt: PerCoreAsyncRuntime[NoopSink], path: String) raises:
    for _ in range(RUNS):
        var cache = ParquetMetadataCache()
        var pool = ExprPool()
        var nf = 0
        var builder = RealBuilder[
            origin_of(cache), origin_of(pool), origin_of(nf)
        ](cache, pool)
        var id = builder.add_agg_sink(_data())
        ref disp = rt.dispatcher()
        var out = run_plan(
            _plan(path, id, 50), builder, disp, WORKERS, CancellationToken.new()
        )
        assert_equal(builder.pool_granted(), 0)
        var batch = out.take(0)
        _check(batch)


def _on_runtime(path: String) raises:
    var rt = _started_runtime()
    var failure = String("")
    try:
        _run_many(rt, path)
    except e:
        failure = String(e)
    rt.shutdown()
    assert_equal(failure, "")


def test_threads_fold_into_their_own_tables_run_after_run() raises:
    _on_runtime(_write("group_plan_threads"))


def test_the_runtime_can_be_stopped_and_started_between_group_runs() raises:
    var path = _write("group_plan_restart")
    for _ in range(3):
        _on_runtime(path)


def main() raises:
    var suite = TestSuite()
    suite.test[test_the_plan_matches_the_oracle_on_any_worker_count_and_morsel_size]()
    suite.test[test_a_budget_the_groups_outgrow_fails_the_run_by_name]()
    suite.test[test_threads_fold_into_their_own_tables_run_after_run]()
    suite.test[test_the_runtime_can_be_stopped_and_started_between_group_runs]()
    suite^.run()
