# =============================================================================
# TPC-H Q1 on the runtime's threaded dispatcher, run after run
# =============================================================================
#
# The plan of `test_tpch_q1` with four workers on threads that share the
# scan's claim cursors, the filter's predicate, the projection and the sink's
# slots and segment pool: the DICT_ENCODED sink over the dictionary file and the
# COLUMNAR sink over the plain one. Each run builds its source, operators and
# sinks anew and drops them after, and a second test stops and starts the
# runtime between rounds. What they prove, on every one of the runs:
#
#   * The answer is the oracle's exactly (the unscaled DECIMAL sums, the
#     averages bit for bit, the counts and the order of the groups), whichever
#     worker took which morsel and whichever order the workers' string tables
#     numbered their strings in.
#   * The segment pool is whole again after the run.
#
# A merge that depended on the schedule or on a worker's own string ids, a slot
# shared by two workers or a reservation that was not returned shows here as a
# wrong group or a non-zero count of granted bytes on some run.

from std.testing import TestSuite, assert_equal, assert_true

from komira_async.ops.waker_sink import NoopSink
from komira_async.reactor.reactor import BACKEND_MOCK
from komira_async.runtime.runtime import PLACEMENT_FIXED, PerCoreAsyncRuntime
from komira_async_api.token import CancellationToken
from komira_parquet.runtime_footer_cache import ParquetMetadataCache
from komira_parquet_writer.record_batch_writer import (
    write_record_batch_to_parquet_bytes,
)
from komira_pipeline_exec.real_builder import RealBuilder
from komira_pipeline_exec.run_plan import run_plan
from komira_pipeline_exec.tpch_q1 import (
    Q1_CUTOFF,
    Q1Table,
    q1_batch,
    q1_plan,
    q1_sink_data,
    q1_sort_data,
    q1_table,
)
from komira_plan_expr.expr_pool import ExprPool
from komira_runtime_paths import test_tmpdir
from komira_scalar_arithmetic.decimal_arith import I128

comptime WORKERS = 4
comptime RUNS = 12


def _w(v: Int) -> I128:
    return Scalar[DType.int64](v).cast[DType.int128]()


def _make_noop_sink() -> NoopSink:
    return NoopSink(_placeholder=UInt8(0))


def _started_runtime() raises -> PerCoreAsyncRuntime[NoopSink]:
    var rt = PerCoreAsyncRuntime[NoopSink](placement=PLACEMENT_FIXED)
    rt.attach_workers(WORKERS, _make_noop_sink, BACKEND_MOCK)
    rt.start()
    return rt^


def _write(name: String, ref t: Q1Table, rows_per_group: Int) raises -> String:
    var path = test_tmpdir() + "/" + name + ".parquet"
    var bytes = write_record_batch_to_parquet_bytes(
        q1_batch(t, 0, t.rows()), max_rows_per_rg=rows_per_group
    )
    var fh = open(path, "w")
    fh.write_bytes(Span(bytes))
    fh.close()
    return path^


struct _Want(Copyable, Movable):
    """What one group of Q1 holds, in cents and counts."""

    var key: String
    var count: Int
    var qty: Int
    var price: Int
    var disc_price: Int
    var charge: Int

    def __init__(out self, key: String):
        self.key = key
        self.count = 0
        self.qty = 0
        self.price = 0
        self.disc_price = 0
        self.charge = 0


def _wanted(ref t: Q1Table) -> List[_Want]:
    """The four groups in order A F, N F, N O, R F."""
    var keys = List[String]()
    for k in ["AF", "NF", "NO", "RF"]:
        keys.append(String(k))
    var out = List[_Want]()
    for k in range(4):
        out.append(_Want(keys[k]))
    for r in range(t.rows()):
        if t.shipdate[r] > Q1_CUTOFF:
            continue
        var key = t.flag[r] + t.status[r]
        for k in range(4):
            if keys[k] == key:
                var dp = t.price[r] * (100 - t.discount[r])
                out[k].count += 1
                out[k].qty += t.quantity[r]
                out[k].price += t.price[r]
                out[k].disc_price += dp
                out[k].charge += dp * (100 + t.tax[r])
    return out^


def _run_many(
    mut rt: PerCoreAsyncRuntime[NoopSink],
    path: String,
    ref want: List[_Want],
    dict_encoded: Bool,
) raises:
    for _ in range(RUNS):
        var cache = ParquetMetadataCache()
        var pool = ExprPool()
        var nf = 0
        var builder = RealBuilder[
            origin_of(cache), origin_of(pool), origin_of(nf)
        ](cache, pool)
        var agg = builder.add_agg_sink(q1_sink_data())
        var sort = builder.add_sort_sink(q1_sort_data())
        var descs = q1_plan(path, agg, sort, dict_encoded, 64)
        ref disp = rt.dispatcher()
        var out = run_plan(
            descs, builder, disp, WORKERS, CancellationToken.new()
        )
        var batch = out.take(1)
        assert_equal(batch.num_rows(), 4)
        var flags = batch.column_at(0).as_string()
        var statuses = batch.column_at(1).as_string()
        for i in range(4):
            assert_equal(flags.get(i) + statuses.get(i), want[i].key)
            assert_true(
                batch.column_at(2).as_decimal128().get_i128(i)
                == _w(want[i].qty),
                "sum_qty differs on a run",
            )
            assert_true(
                batch.column_at(4).as_decimal128().get_i128(i)
                == _w(want[i].disc_price),
                "sum_disc_price differs on a run",
            )
            assert_true(
                batch.column_at(5).as_decimal128().get_i128(i)
                == _w(want[i].charge),
                "sum_charge differs on a run",
            )
            assert_equal(
                batch.column_at(7).as_primitive[DType.float64]().get(i),
                Float64(want[i].price) / 100.0 / Float64(want[i].count),
            )
            assert_equal(
                Int(batch.column_at(9).as_primitive[DType.int64]().get(i)),
                want[i].count,
            )
        assert_equal(builder.pool_granted(), 0)


def _on_runtime(
    path: String, ref want: List[_Want], dict_encoded: Bool
) raises:
    var rt = _started_runtime()
    var failure = String("")
    try:
        _run_many(rt, path, want, dict_encoded)
    except e:
        failure = String(e)
    rt.shutdown()
    assert_equal(failure, "")


def test_q1_is_exact_on_every_run_with_both_sinks() raises:
    var t = q1_table(2000)
    var want = _wanted(t)
    assert_true(want[0].count > 100)
    _on_runtime(_write("q1_conc_dict", t, 256), want, True)
    _on_runtime(_write("q1_conc_plain", t, 4), want, False)


def test_the_runtime_can_be_stopped_and_started_between_runs() raises:
    var t = q1_table(1200)
    var want = _wanted(t)
    var dict_path = _write("q1_conc_restart_dict", t, 256)
    var plain_path = _write("q1_conc_restart_plain", t, 4)
    for _ in range(3):
        _on_runtime(dict_path, want, True)
        _on_runtime(plain_path, want, False)


def main() raises:
    var suite = TestSuite()
    suite.test[test_q1_is_exact_on_every_run_with_both_sinks]()
    suite.test[test_the_runtime_can_be_stopped_and_started_between_runs]()
    suite^.run()
