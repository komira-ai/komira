# =============================================================================
# Hand-built plans over the real members on the runtime's threaded dispatcher
# =============================================================================
#
# The same members as `test_real_plan`, with four workers on threads that share
# the Parquet source's claim cursors, the limit's row budget and the sink's
# slots. They assert on rows only. What they prove:
#
#   * A scan, a filter and a projection over a file of eight row groups return
#     every row the plan keeps exactly once, on every one of many runs, each
#     run building its source, operators and sink anew and dropping them after.
#   * A limit returns exactly its row count of distinct rows that satisfy the
#     plan, run after run.
#   * The same holds when the runtime itself is stopped and started again
#     between runs.

from std.memory import Pointer
from std.testing import TestSuite, assert_equal, assert_false, assert_true

from komira_async.ops.waker_sink import NoopSink
from komira_async.reactor.reactor import BACKEND_MOCK
from komira_async.runtime.runtime import PLACEMENT_FIXED, PerCoreAsyncRuntime
from komira_async_api.token import CancellationToken
from komira_parquet.runtime_footer_cache import ParquetMetadataCache
from komira_parquet_writer.record_batch_writer import (
    write_record_batch_to_parquet_bytes,
)
from komira_physical_plan.physical_plan import MorselOp, SegmentDescPod
from komira_pipeline_exec.plan_harness import (
    b_is_null,
    chain,
    int64_column,
    parquet_segment,
    project_columns,
    sample_batch,
    string_column,
)
from komira_pipeline_exec.real_builder import RealBuilder
from komira_pipeline_exec.run_plan import run_plan
from komira_plan_expr.expr import BIN_GE, BIN_GT, Expr
from komira_plan_expr.expr_pool import ExprPool
from komira_plan_expr.scalar_value import ScalarValue
from komira_runtime_paths import test_tmpdir

comptime WORKERS = 4
comptime ROWS = 400
comptime RUNS = 20


def _lit(v: Int) -> Expr:
    return Expr.literal(ScalarValue.from_int(v))


def _cmp(op: UInt8, name: String, v: Int) -> Expr:
    return Expr.binary(op, Expr.col_ref(name), _lit(v))


def _names(a: String, b: String) -> List[String]:
    var out = List[String]()
    out.append(a)
    out.append(b)
    return out^


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


def _plan(path: String, limit: Int) -> List[SegmentDescPod]:
    """Scan with a pushed a >= 100; filter b > 2000; project (s, a); and, when
    `limit` is positive, limit."""
    var ops = chain(
        MorselOp.filter(_cmp(BIN_GT, "b", 2000)),
        project_columns(_names("s", "a")),
    )
    if limit > 0:
        ops = chain(
            MorselOp.filter(_cmp(BIN_GT, "b", 2000)),
            project_columns(_names("s", "a")),
            MorselOp.limit(limit),
        )
    var out = List[SegmentDescPod]()
    out.append(
        parquet_segment(0, path, None, Optional(_cmp(BIN_GE, "a", 100)), ops^, 24)
    )
    return out^


def _check(got_a: List[Int], got_s: List[String], limit: Int) raises:
    var kept = 0
    for r in range(ROWS):
        if r >= 100 and r * 10 > 2000 and not b_is_null(r):
            kept += 1
    var seen = List[Bool](length=ROWS, fill=False)
    for i in range(len(got_a)):
        var r = got_a[i]
        assert_true(r >= 100 and r < ROWS and r * 10 > 2000 and not b_is_null(r))
        assert_false(seen[r], "row " + String(r) + " twice")
        seen[r] = True
        assert_equal(got_s[i], "s" + String(r % 4))
    if limit > 0:
        assert_equal(len(got_a), limit)
    else:
        assert_equal(len(got_a), kept)


def _run_many(mut rt: PerCoreAsyncRuntime[NoopSink], path: String, limit: Int) raises:
    for _ in range(RUNS):
        var cache = ParquetMetadataCache()
        var pool = ExprPool()
        var nf = 0
        var builder = RealBuilder[
            origin_of(cache), origin_of(pool), origin_of(nf)
        ](Pointer(to=cache), Pointer(to=pool))
        ref disp = rt.dispatcher()
        var out = run_plan(
            _plan(path, limit), builder, disp, WORKERS, CancellationToken.new()
        )
        var batch = out.take(0)
        _check(int64_column(batch, 1), string_column(batch, 0), limit)


def _on_runtime(path: String, limit: Int) raises:
    var rt = _started_runtime()
    var failure = String("")
    try:
        _run_many(rt, path, limit)
    except e:
        failure = String(e)
    rt.shutdown()
    assert_equal(failure, "")


def test_every_kept_row_arrives_once_run_after_run() raises:
    _on_runtime(_write("conc_all"), 0)


def test_a_limit_returns_its_row_count_run_after_run() raises:
    _on_runtime(_write("conc_limit"), 37)


def test_the_runtime_can_be_stopped_and_started_between_runs() raises:
    var path = _write("conc_restart")
    for round in range(4):
        _on_runtime(path, 0 if round % 2 == 0 else 11)


def main() raises:
    var suite = TestSuite()
    suite.test[test_every_kept_row_arrives_once_run_after_run]()
    suite.test[test_a_limit_returns_its_row_count_run_after_run]()
    suite.test[test_the_runtime_can_be_stopped_and_started_between_runs]()
    suite^.run()
