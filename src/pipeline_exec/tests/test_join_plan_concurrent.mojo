# =============================================================================
# Inner joins on the runtime's threaded dispatcher
# =============================================================================
#
# Orders probing customers, with the probe side resident and again as a Parquet
# file of eight row groups, with four workers on threads that share the
# probe's index and the sink's slots, run after run; each run builds its
# sources, operators and sinks anew and drops them after. What they prove:
#
#   * The joined rows equal the nested-loop join of `join_harness` as a
#     multiset on every run, whichever worker probed which morsel.
#   * The segment pool holds nothing after any run, and the same holds when
#     the runtime itself is stopped and started again between runs.

from std.testing import TestSuite, assert_equal

from async_rt.ops.waker_sink import NoopSink
from async_rt.reactor.reactor import BACKEND_MOCK
from async_rt.runtime.runtime import PLACEMENT_FIXED, PerCoreAsyncRuntime
from async_api.token import CancellationToken
from parquet.runtime_footer_cache import ParquetMetadataCache
from parquet_writer.record_batch_writer import (
    write_record_batch_to_parquet_bytes,
)
from physical_plan.physical_plan import SegmentDescPod
from pipeline_exec.join_harness import (
    build_segment,
    customer_batch,
    expect_rows,
    expected_rows,
    key_names,
    orders_batch,
    probe_op,
    probe_segment,
    rows_of,
    with_build_dep,
)
from pipeline_exec.plan_harness import chain, parquet_segment
from pipeline_exec.real_builder import RealBuilder
from pipeline_exec.run_plan import run_plan
from plan_expr.expr_pool import ExprPool
from runtime_paths import test_tmpdir

comptime WORKERS = 4
comptime ROWS = 400
comptime RUNS = 20


def _make_noop_sink() -> NoopSink:
    return NoopSink(_placeholder=UInt8(0))


def _started_runtime() raises -> PerCoreAsyncRuntime[NoopSink]:
    var rt = PerCoreAsyncRuntime[NoopSink](placement=PLACEMENT_FIXED)
    rt.attach_workers(WORKERS, _make_noop_sink, BACKEND_MOCK)
    rt.start()
    return rt^


def _write(name: String) raises -> String:
    var path = test_tmpdir() + "/" + name + ".parquet"
    var bytes = write_record_batch_to_parquet_bytes(
        orders_batch(0, ROWS), max_rows_per_rg=50
    )
    var fh = open(path, "w")
    fh.write_bytes(Span(bytes))
    fh.close()
    return path^


def _want() raises -> List[String]:
    return expected_rows(
        orders_batch(0, ROWS),
        customer_batch(25),
        key_names("o_custkey"),
        key_names("c_custkey"),
    )


def _run_many(
    mut rt: PerCoreAsyncRuntime[NoopSink], path: String, scan: Bool
) raises:
    var want = _want()
    for _ in range(RUNS):
        var cache = ParquetMetadataCache()
        var pool = ExprPool()
        var nf = 0
        var builder = RealBuilder[
            origin_of(cache), origin_of(pool), origin_of(nf)
        ](cache, pool)
        var customers = builder.add_resident(customer_batch(25))
        var descs = List[SegmentDescPod]()
        descs.append(build_segment(0, customers, morsel_rows=8))
        if scan:
            descs.append(
                with_build_dep(
                    parquet_segment(
                        1,
                        path,
                        ops=chain(
                            probe_op(
                                0,
                                key_names("o_custkey"),
                                key_names("c_custkey"),
                            )
                        ),
                        morsel_rows=24,
                    ),
                    0,
                )
            )
        else:
            var orders = builder.add_resident(orders_batch(0, ROWS))
            descs.append(
                probe_segment(
                    1,
                    orders,
                    0,
                    key_names("o_custkey"),
                    key_names("c_custkey"),
                    24,
                )
            )
        ref disp = rt.dispatcher()
        var out = run_plan(
            descs, builder, disp, WORKERS, CancellationToken.new()
        )
        expect_rows(rows_of(out.take(1)), want, "joined rows")
        assert_equal(builder.pool_granted(), 0)


def _on_runtime(path: String, scan: Bool) raises:
    var rt = _started_runtime()
    var failure = String("")
    try:
        _run_many(rt, path, scan)
    except e:
        failure = String(e)
    rt.shutdown()
    assert_equal(failure, "")


def test_a_resident_join_gives_the_same_rows_run_after_run() raises:
    _on_runtime(String(""), False)


def test_a_parquet_probe_gives_the_same_rows_run_after_run() raises:
    _on_runtime(_write("join_conc"), True)


def test_the_runtime_can_be_stopped_and_started_between_runs() raises:
    var path = _write("join_conc_restart")
    for _ in range(4):
        _on_runtime(path, True)


def main() raises:
    var suite = TestSuite()
    suite.test[test_a_resident_join_gives_the_same_rows_run_after_run]()
    suite.test[test_a_parquet_probe_gives_the_same_rows_run_after_run]()
    suite.test[test_the_runtime_can_be_stopped_and_started_between_runs]()
    suite^.run()
