# =============================================================================
# SINK_SORT on the runtime's threaded dispatcher
# =============================================================================
#
# A scan of a file of eight row groups, sorted by (s descending, b ascending
# NULLS FIRST), with four workers on threads that share the scan's claim
# cursors and the sink's slots, run after run; each run builds its source,
# operators and sink anew and drops them after. What they prove:
#
#   * The sorted rows equal the order computed by hand on every run, whatever
#     rows each worker held (tied rows follow file order, which the collect
#     step restores from the morsel positions).
#   * The segment pool holds nothing after any run, and the same holds when
#     the runtime itself is stopped and started again between runs.

from std.testing import TestSuite, assert_equal

from komira_async.ops.waker_sink import NoopSink
from komira_async.reactor.reactor import BACKEND_MOCK
from komira_async.runtime.runtime import PLACEMENT_FIXED, PerCoreAsyncRuntime
from komira_async_api.token import CancellationToken
from komira_parquet.runtime_footer_cache import ParquetMetadataCache
from komira_parquet_writer.record_batch_writer import (
    write_record_batch_to_parquet_bytes,
)
from komira_physical_plan.physical_plan import SegmentDescPod, SortSinkData
from komira_pipeline_exec.plan_harness import (
    b_is_null,
    int64_column,
    parquet_segment,
    sample_batch,
    with_sort_sink,
)
from komira_pipeline_exec.real_builder import RealBuilder
from komira_pipeline_exec.run_plan import run_plan
from komira_plan_expr.expr_pool import ExprPool
from komira_runtime_paths import test_tmpdir

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
        sample_batch(0, ROWS), max_rows_per_rg=50
    )
    var fh = open(path, "w")
    fh.write_bytes(Span(bytes))
    fh.close()
    return path^


def _want() -> List[Int]:
    var want = List[Int]()
    for g in range(3, -1, -1):
        for r in range(ROWS):
            if r % 4 == g and b_is_null(r):
                want.append(r)
        for r in range(ROWS):
            if r % 4 == g and not b_is_null(r):
                want.append(r)
    return want^


def _run_many(mut rt: PerCoreAsyncRuntime[NoopSink], path: String) raises:
    var want = _want()
    for _ in range(RUNS):
        var cache = ParquetMetadataCache()
        var pool = ExprPool()
        var nf = 0
        var builder = RealBuilder[
            origin_of(cache), origin_of(pool), origin_of(nf)
        ](cache, pool)
        var keys = List[String]()
        keys.append("s")
        keys.append("b")
        var desc = List[Bool]()
        desc.append(True)
        desc.append(False)
        var nulls_first = List[Bool]()
        nulls_first.append(False)
        nulls_first.append(True)
        var id = builder.add_sort_sink(
            SortSinkData(keys^, desc^, 0, nulls_first^)
        )
        var descs = List[SegmentDescPod]()
        descs.append(with_sort_sink(parquet_segment(0, path, None, None, morsel_rows=24), id))
        ref disp = rt.dispatcher()
        var out = run_plan(descs, builder, disp, WORKERS, CancellationToken.new())
        var got = int64_column(out.take(0), 0)
        assert_equal(len(got), len(want))
        for i in range(len(want)):
            assert_equal(got[i], want[i], "position " + String(i))
        assert_equal(builder.pool_granted(), 0)


def _on_runtime(path: String) raises:
    var rt = _started_runtime()
    var failure = String("")
    try:
        _run_many(rt, path)
    except e:
        failure = String(e)
    rt.shutdown()
    assert_equal(failure, "")


def test_the_sorted_rows_are_the_same_run_after_run() raises:
    _on_runtime(_write("sort_conc"))


def test_the_runtime_can_be_stopped_and_started_between_runs() raises:
    var path = _write("sort_conc_restart")
    for _ in range(4):
        _on_runtime(path)


def main() raises:
    var suite = TestSuite()
    suite.test[test_the_sorted_rows_are_the_same_run_after_run]()
    suite.test[test_the_runtime_can_be_stopped_and_started_between_runs]()
    suite^.run()
