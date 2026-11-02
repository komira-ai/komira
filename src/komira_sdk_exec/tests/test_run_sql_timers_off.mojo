# =============================================================================
# run_sql with the phase timers compiled out (the default build)
# =============================================================================
#
# The engine's parse, bind, optimize, lower, execute, scan, filter and sink
# code carries phase-timer calls (komira_phase_timers) that exist only in a
# build with -D KOMIRA_PHASE_TIMERS=1. This test runs TPC-H Q6 through
# `run_sql` on four workers in the default build and proves the calls are
# inert there:
#   * test_q6_is_exact_and_no_timer_records: the revenue is the integer
#     oracle's, and afterwards no thread has registered a timer lane and every
#     counter of every phase reads 0. Catches a timer call in the engine whose
#     body is not behind the compile-time flag (it would register a thread or
#     write a counter in a production build), and a timer call that changes
#     the answer.

from std.testing import TestSuite, assert_equal, assert_false, assert_true

from komira_bench_corpus.catalog import find_query
from komira_parquet_writer.record_batch_writer import (
    write_record_batch_to_parquet_bytes,
)
from komira_phase_timers.phase_timers import (
    FIELD_CALLS,
    PH_COUNT,
    pt_enabled,
    pt_get,
    pt_lane_count,
)
from komira_pipeline_exec.tpch_q6 import (
    LineitemTable,
    Q6_DATE_FROM,
    Q6_DATE_TO,
    lineitem_batch,
    q6_table,
)
from komira_runtime_paths import test_tmpdir
from komira_scalar_arithmetic.decimal_arith import I128
from komira_sdk_exec.engine_catalog import register_parquet
from komira_sdk_exec.engine_context import EngineContext
from komira_sdk_exec.engine_options import EngineOptions
from komira_sdk_exec.engine_sql import run_sql


def _w(v: Int) -> I128:
    return Scalar[DType.int64](v).cast[DType.int128]()


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


def test_q6_is_exact_and_no_timer_records() raises:
    assert_false(pt_enabled())
    var t = q6_table(1500)
    var want = _revenue(t)
    assert_true(want > 0)
    var path = test_tmpdir() + "/timers_off_q6.parquet"
    var bytes = write_record_batch_to_parquet_bytes(
        lineitem_batch(t, 0, t.rows()), max_rows_per_rg=100
    )
    var fh = open(path, "w")
    fh.write_bytes(Span(bytes))
    fh.close()
    var ctx = EngineContext(EngineOptions(worker_count=4))
    register_parquet(ctx, "lineitem", path)
    var outcome = run_sql(ctx, find_query(String("tpch/q6")).text)
    assert_false(outcome.refusal.__bool__(), "Q6 was refused")
    assert_equal(len(outcome.batches), 1)
    var got = outcome.batches[0].column_at(0).as_decimal128().get_i128(0)
    assert_true(got == _w(want), "revenue differs from the integer oracle")
    assert_equal(pt_lane_count(), 0)
    for lane in range(4):
        for phase in range(PH_COUNT):
            assert_equal(pt_get(lane, phase, FIELD_CALLS), 0)


def main() raises:
    var suite = TestSuite()
    suite.test[test_q6_is_exact_and_no_timer_records]()
    suite^.run()
