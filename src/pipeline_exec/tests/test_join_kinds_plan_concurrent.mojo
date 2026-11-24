# =============================================================================
# LEFT, RIGHT, FULL and SEMI joins on the runtime's threaded dispatcher
# =============================================================================
#
# Orders probing customers, with the probe side a Parquet file of eight row
# groups and again resident, with four workers on threads that share the
# probe's index, the marks of matched build rows and the sink's slots, run
# after run; each run builds its sources, operators and sinks anew and drops
# them after. What they prove:
#
#   test_a_right_join_gives_the_same_rows_run_after_run
#   test_a_full_join_gives_the_same_rows_run_after_run
#       The marks the workers set from several threads leave the tail the same
#       build rows every run: the rows equal the nested-loop join of
#       `join_harness` as a multiset, no unmatched build row twice or missing,
#       with a Parquet probe side (a small orders file, so that most customers
#       go unmatched) and with a resident one.
#   test_a_left_join_gives_the_same_rows_run_after_run
#   test_a_semi_join_gives_the_same_rows_run_after_run
#       The kinds with no tail give the oracle's rows on every run.
#
# The segment pool holds nothing after any run of any kind.

from std.testing import TestSuite, assert_equal

from async_rt.ops.waker_sink import NoopSink
from async_rt.reactor.reactor import BACKEND_MOCK
from async_rt.runtime.runtime import PLACEMENT_FIXED, PerCoreAsyncRuntime
from async_api.token import CancellationToken
from parquet.runtime_footer_cache import ParquetMetadataCache
from parquet_writer.record_batch_writer import (
    write_record_batch_to_parquet_bytes,
)
from physical_plan.physical_plan import MorselOp, SegmentDescPod
from pipeline_exec.join_harness import (
    build_segment,
    customer_batch,
    expect_rows,
    key_names,
    oracle_join_kind,
    orders_batch,
    rows_of,
    sorted_rows,
    table_of,
    with_build_dep,
)
from pipeline_exec.plan_harness import batch_segment, chain, parquet_segment
from pipeline_exec.real_builder import RealBuilder
from pipeline_exec.run_plan import run_plan
from plan_expr.expr_pool import ExprPool
from plan_ir.logical_plan import (
    JOIN_FULL,
    JOIN_LEFT,
    JOIN_RIGHT,
    JOIN_SEMI,
)
from runtime_paths import test_tmpdir

comptime WORKERS = 4
comptime RUNS = 12


def _make_noop_sink() -> NoopSink:
    return NoopSink(_placeholder=UInt8(0))


def _started_runtime() raises -> PerCoreAsyncRuntime[NoopSink]:
    var rt = PerCoreAsyncRuntime[NoopSink](placement=PLACEMENT_FIXED)
    rt.attach_workers(WORKERS, _make_noop_sink, BACKEND_MOCK)
    rt.start()
    return rt^


def _write(name: String, rows: Int) raises -> String:
    var path = test_tmpdir() + "/" + name + ".parquet"
    var bytes = write_record_batch_to_parquet_bytes(
        orders_batch(0, rows), max_rows_per_rg=rows // 8
    )
    var fh = open(path, "w")
    fh.write_bytes(Span(bytes))
    fh.close()
    return path^


def _want(kind: UInt8, rows: Int) raises -> List[String]:
    return sorted_rows(
        oracle_join_kind(
            kind,
            table_of(orders_batch(0, rows)),
            table_of(customer_batch(25)),
            key_names("o_custkey"),
            key_names("c_custkey"),
        )
    )


def _run_many(
    mut rt: PerCoreAsyncRuntime[NoopSink],
    kind: UInt8,
    path: String,
    rows: Int,
    scan: Bool,
) raises:
    var want = _want(kind, rows)
    for _ in range(RUNS):
        var cache = ParquetMetadataCache()
        var pool = ExprPool()
        var nf = 0
        var builder = RealBuilder[
            origin_of(cache), origin_of(pool), origin_of(nf)
        ](cache, pool)
        var customers = builder.add_resident(customer_batch(25))
        var ops = chain(
            MorselOp.join_probe(
                0, key_names("o_custkey"), key_names("c_custkey"), kind
            )
        )
        var descs = List[SegmentDescPod]()
        descs.append(build_segment(0, customers, morsel_rows=8))
        if scan:
            descs.append(
                with_build_dep(
                    parquet_segment(1, path, ops=ops^, morsel_rows=6), 0
                )
            )
        else:
            var orders = builder.add_resident(orders_batch(0, rows))
            descs.append(
                with_build_dep(batch_segment(1, orders, ops^, 6), 0)
            )
        ref disp = rt.dispatcher()
        var out = run_plan(
            descs, builder, disp, WORKERS, CancellationToken.new()
        )
        expect_rows(
            rows_of(out.take(1)), want, "kind " + String(Int(kind))
        )
        assert_equal(builder.pool_granted(), 0)


def _on_runtime(kind: UInt8, path: String, rows: Int, scan: Bool) raises:
    var rt = _started_runtime()
    var failure = String("")
    try:
        _run_many(rt, kind, path, rows, scan)
    except e:
        failure = String(e)
    rt.shutdown()
    assert_equal(failure, "")


def test_a_right_join_gives_the_same_rows_run_after_run() raises:
    # 48 orders leave most customers unmatched; 400 match nearly all.
    _on_runtime(JOIN_RIGHT, _write("join_kinds_conc_right_small", 48), 48, True)
    _on_runtime(JOIN_RIGHT, _write("join_kinds_conc_right", 400), 400, True)
    _on_runtime(JOIN_RIGHT, String(""), 48, False)


def test_a_full_join_gives_the_same_rows_run_after_run() raises:
    _on_runtime(JOIN_FULL, _write("join_kinds_conc_full_small", 48), 48, True)
    _on_runtime(JOIN_FULL, _write("join_kinds_conc_full", 400), 400, True)
    _on_runtime(JOIN_FULL, String(""), 48, False)


def test_a_left_join_gives_the_same_rows_run_after_run() raises:
    _on_runtime(JOIN_LEFT, _write("join_kinds_conc_left", 400), 400, True)
    _on_runtime(JOIN_LEFT, String(""), 400, False)


def test_a_semi_join_gives_the_same_rows_run_after_run() raises:
    _on_runtime(JOIN_SEMI, _write("join_kinds_conc_semi", 400), 400, True)
    _on_runtime(JOIN_SEMI, String(""), 400, False)


def main() raises:
    var suite = TestSuite()
    suite.test[test_a_right_join_gives_the_same_rows_run_after_run]()
    suite.test[test_a_full_join_gives_the_same_rows_run_after_run]()
    suite.test[test_a_left_join_gives_the_same_rows_run_after_run]()
    suite.test[test_a_semi_join_gives_the_same_rows_run_after_run]()
    suite^.run()
