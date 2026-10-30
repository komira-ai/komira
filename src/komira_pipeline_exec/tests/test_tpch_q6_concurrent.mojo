# =============================================================================
# TPC-H Q6 on the runtime's threaded dispatcher, run after run
# =============================================================================
#
# The plan of `test_tpch_q6` with four workers on threads that share the scan's
# claim cursors, the filter's predicate and the sink's slots and segment pool.
# Each run builds its source, operators and sink anew and drops them after,
# and a second test stops and starts the runtime between rounds. What they
# prove, on every one of the runs:
#
#   * The revenue is the oracle's exactly (the unscaled DECIMAL(38,4)
#     integer), whichever worker took which morsel.
#   * The segment pool is whole again after the run.
#
# A merge that depended on the schedule, a worker slot shared by two workers,
# or a reservation that was not returned shows here as a wrong sum or a
# non-zero count of granted bytes on some run.

from std.testing import TestSuite, assert_equal, assert_true

from komira_async.ops.waker_sink import NoopSink
from komira_async.reactor.reactor import BACKEND_MOCK
from komira_async.runtime.runtime import PLACEMENT_FIXED, PerCoreAsyncRuntime
from komira_async_api.token import CancellationToken
from komira_parquet.runtime_footer_cache import ParquetMetadataCache
from komira_parquet_writer.record_batch_writer import (
    write_record_batch_to_parquet_bytes,
)
from komira_physical_plan.physical_plan import SegmentDescPod
from komira_pipeline_exec.real_builder import RealBuilder
from komira_pipeline_exec.run_plan import run_plan
from komira_pipeline_exec.tpch_q6 import (
    Q6_DATE_FROM,
    Q6_DATE_TO,
    LineitemTable,
    lineitem_batch,
    q6_segment,
    q6_sink_data,
    q6_table,
)
from komira_plan_expr.expr_pool import ExprPool
from komira_runtime_paths import test_tmpdir
from komira_scalar_arithmetic.decimal_arith import I128

comptime WORKERS = 4
comptime RUNS = 20


def _w(v: Int) -> I128:
    return Scalar[DType.int64](v).cast[DType.int128]()


def _make_noop_sink() -> NoopSink:
    return NoopSink(_placeholder=UInt8(0))


def _started_runtime() raises -> PerCoreAsyncRuntime[NoopSink]:
    var rt = PerCoreAsyncRuntime[NoopSink](placement=PLACEMENT_FIXED)
    rt.attach_workers(WORKERS, _make_noop_sink, BACKEND_MOCK)
    rt.start()
    return rt^


def _write(name: String, ref t: LineitemTable) raises -> String:
    var path = test_tmpdir() + "/" + name + ".parquet"
    var bytes = write_record_batch_to_parquet_bytes(
        lineitem_batch(t, 0, t.rows()), max_rows_per_rg=200
    )
    var fh = open(path, "w")
    fh.write_bytes(Span(bytes))
    fh.close()
    return path^


def _revenue(ref t: LineitemTable) -> Int:
    var sum = 0
    for r in range(t.rows()):
        if t.discount_null[r] or t.price_null[r]:
            continue
        if (
            t.shipdate[r] >= Q6_DATE_FROM
            and t.shipdate[r] < Q6_DATE_TO
            and t.discount[r] >= 5
            and t.discount[r] <= 7
            and t.quantity[r] < 2400
        ):
            sum += t.price[r] * t.discount[r]
    return sum


def _run_many(mut rt: PerCoreAsyncRuntime[NoopSink], path: String, want: Int) raises:
    for _ in range(RUNS):
        var cache = ParquetMetadataCache()
        var pool = ExprPool()
        var nf = 0
        var builder = RealBuilder[
            origin_of(cache), origin_of(pool), origin_of(nf)
        ](cache, pool)
        var id = builder.add_agg_sink(q6_sink_data())
        var descs = List[SegmentDescPod]()
        descs.append(q6_segment(0, path, id, 64))
        ref disp = rt.dispatcher()
        var out = run_plan(
            descs, builder, disp, WORKERS, CancellationToken.new()
        )
        var batch = out.take(0)
        assert_equal(batch.num_rows(), 1)
        var got = batch.column_at(0).as_decimal128().get_i128(0)
        assert_true(got == _w(want), "revenue differs on a run")
        assert_equal(builder.pool_granted(), 0)


def _on_runtime(path: String, want: Int) raises:
    var rt = _started_runtime()
    var failure = String("")
    try:
        _run_many(rt, path, want)
    except e:
        failure = String(e)
    rt.shutdown()
    assert_equal(failure, "")


def test_the_revenue_is_exact_on_every_run() raises:
    var t = q6_table(2000)
    var want = _revenue(t)
    assert_true(want > 0)
    _on_runtime(_write("q6_conc", t), want)


def test_the_runtime_can_be_stopped_and_started_between_runs() raises:
    var t = q6_table(1500)
    var want = _revenue(t)
    var path = _write("q6_conc_restart", t)
    for _ in range(4):
        _on_runtime(path, want)


def main() raises:
    var suite = TestSuite()
    suite.test[test_the_revenue_is_exact_on_every_run]()
    suite.test[test_the_runtime_can_be_stopped_and_started_between_runs]()
    suite^.run()
