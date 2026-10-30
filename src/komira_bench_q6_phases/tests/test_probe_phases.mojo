# The probe over a lineitem-shaped Parquet file, built with the phase timers on
# (test_defines of this target). The table is the generator of
# komira_pipeline_exec's Q6 test; the expected revenue is an integer computed
# here, row by row, never taken from the engine.
#
# What each test proves, and the defect it would catch:
# - test_every_stage_of_a_run_is_timed: one Q6 run on three workers leaves
#   the driver phases (parse, bind, optimize, lower, execute setup, run_plan)
#   with one interval each, the task phase with a multiple of three intervals
#   on three threads, the dispatch and combine phases timed, and the nested
#   phases consistent: the task time holds the claim time, the claim time holds
#   decode, filter and the sink time is inside the task. Catches a timer left
#   out of a stage, one that lands on the wrong thread, or one that is closed
#   in the wrong place.
# - test_the_json_is_valid_and_complete: `run_probe` for two thread counts
#   gives JSON a parser accepts, with the schema, the note that the numbers
#   are relative, both configurations, 5 runs each, a median and quartiles,
#   the phase shares, the page faults, the footer cost, the expected answer
#   matched, and phases.json and plan.txt written. Catches a malformed
#   document, a missing section, or an answer that is not checked.
# - test_the_plan_text_shows_the_pushdown: the rendered plans name the scan,
#   the filter and the lowered source and sink. Catches a render that leaves
#   out the lowered plan the pushdown question is answered from.
# - test_a_wrong_expected_answer_is_reported: a different expected revenue
#   makes `answers_match` False. Catches a check that cannot fail.

from std.os.path import exists
from std.testing import TestSuite, assert_equal, assert_false, assert_true

from komira_bench_corpus.catalog import find_query
from komira_bench_q6_phases.phase_snapshot import snapshot_phase
from komira_bench_q6_phases.plan_render import render_plans
from komira_bench_q6_phases.probe import ProbeSettings, run_probe
from komira_json.parse import parse_json_value
from komira_parquet_writer.record_batch_writer import (
    write_record_batch_to_parquet_bytes,
)
from komira_phase_timers.phase_timers import (
    PH_BIND,
    PH_CLAIM,
    PH_COMBINE,
    PH_DECODE_FILTER_COLS,
    PH_DISPATCH,
    PH_EXEC_SETUP,
    PH_FILTER,
    PH_LOWER,
    PH_OPTIMIZE,
    PH_PARSE,
    PH_RUN_PLAN,
    PH_SINK,
    PH_TASK,
    pt_enabled,
    pt_reset,
)
from komira_pipeline_exec.tpch_q6 import (
    LineitemTable,
    Q6_DATE_FROM,
    Q6_DATE_TO,
    lineitem_batch,
    q6_table,
)
from komira_runtime_paths import test_tmpdir
from komira_sdk_exec.engine_catalog import register_parquet
from komira_sdk_exec.engine_context import EngineContext
from komira_sdk_exec.engine_options import EngineOptions
from komira_sdk_exec.engine_sql import run_sql


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


def _write(name: String, ref t: LineitemTable) raises -> String:
    var path = test_tmpdir() + "/" + name + ".parquet"
    var bytes = write_record_batch_to_parquet_bytes(
        lineitem_batch(t, 0, t.rows()), max_rows_per_rg=250
    )
    var fh = open(path, "w")
    fh.write_bytes(Span(bytes))
    fh.close()
    return path^


def _q6() raises -> String:
    return find_query(String("tpch/q6")).text


def test_every_stage_of_a_run_is_timed() raises:
    assert_true(pt_enabled())
    var t = q6_table(3000)
    var ctx = EngineContext(EngineOptions(worker_count=3))
    register_parquet(ctx, "lineitem", _write("probe_stages", t))
    _ = run_sql(ctx, _q6())  # warm
    pt_reset()
    var outcome = run_sql(ctx, _q6())
    assert_false(outcome.refusal.__bool__(), "Q6 was refused")
    for p in [PH_PARSE, PH_BIND, PH_OPTIMIZE, PH_LOWER, PH_EXEC_SETUP, PH_RUN_PLAN]:
        var a = snapshot_phase(p)
        assert_equal(a.calls, 1)
        assert_equal(a.lanes, 1)
        assert_true(a.sum_ns > 0)
    var task = snapshot_phase(PH_TASK)
    assert_true(task.calls >= 3 and task.calls % 3 == 0)
    assert_equal(task.lanes, 3)
    var dispatch = snapshot_phase(PH_DISPATCH)
    assert_true(dispatch.calls >= 1)
    assert_true(snapshot_phase(PH_COMBINE).calls >= 1)
    var claim = snapshot_phase(PH_CLAIM)
    var sink = snapshot_phase(PH_SINK)
    var decode = snapshot_phase(PH_DECODE_FILTER_COLS)
    var filter = snapshot_phase(PH_FILTER)
    assert_true(claim.calls > 0 and sink.calls > 0)
    assert_true(decode.calls > 0 and filter.calls > 0)
    assert_true(task.sum_ns >= claim.sum_ns + sink.sum_ns)
    assert_true(claim.sum_ns >= decode.sum_ns + filter.sum_ns)
    assert_true(snapshot_phase(PH_RUN_PLAN).sum_ns >= dispatch.sum_ns)


def test_the_json_is_valid_and_complete() raises:
    var t = q6_table(3000)
    var path = _write("probe_json", t)
    var threads = List[Int]()
    threads.append(1)
    threads.append(3)
    var out_dir = test_tmpdir() + "/probe_json_out"
    var result = run_probe(
        ProbeSettings(path^, out_dir, threads^, 5, 1 << 30, _revenue(t))
    )
    assert_true(result.answers_match)
    var doc = parse_json_value(result.json)
    assert_equal(doc.get("schema").as_string(), "komira-q6-phase-probe/1")
    assert_true("RELATIVE" in doc.get("note").as_string())
    assert_true(doc.get("timers_compiled_in").as_bool())
    assert_true(doc.get("answers_match_expected").as_bool())
    assert_true(doc.has("footer_cost"))
    var cfgs = doc.get("configs")
    assert_equal(cfgs.array_len(), 2)
    for i in range(2):
        var c = cfgs.element_at(i)
        assert_equal(Int(c.get("runs").as_int64()), 5)
        assert_true(c.get("total_ms").get("median").as_float64() > 0.0)
        assert_true(c.get("total_ms").has("q1") and c.get("total_ms").has("q3"))
        assert_true(c.get("page_faults").get("minor").has("median"))
        var phases = c.get("phases")
        assert_true(phases.has("parse") and phases.has("task_busy"))
        assert_true(phases.has("dispatch_fork_join") and phases.has("agg_sum"))
        assert_true(phases.get("task_busy").has("share_of_total_pct"))
    assert_equal(Int(cfgs.element_at(0).get("threads_requested").as_int64()), 1)
    assert_equal(Int(cfgs.element_at(1).get("threads_requested").as_int64()), 3)
    assert_true(exists(out_dir + "/phases.json"))
    assert_true(exists(out_dir + "/plan.txt"))


def test_the_plan_text_shows_the_pushdown() raises:
    var t = q6_table(300)
    var ctx = EngineContext(EngineOptions(worker_count=2))
    register_parquet(ctx, "lineitem", _write("probe_plan", t))
    var text = render_plans(ctx, _q6())
    for needle in [
        "== bound plan",
        "== optimized plan",
        "== lowered plan",
        "Scan path=",
        "l_discount",
        "SOURCE_PARQUET",
        "sink:",
    ]:
        assert_true(String(needle) in text, "the plan text lacks '" + String(needle) + "'")


def test_a_wrong_expected_answer_is_reported() raises:
    var t = q6_table(1000)
    var path = _write("probe_wrong", t)
    var threads = List[Int]()
    threads.append(2)
    var result = run_probe(
        ProbeSettings(
            path^, test_tmpdir() + "/probe_wrong_out", threads^, 5, 1 << 30,
            _revenue(t) + 1,
        )
    )
    assert_false(result.answers_match)


def main() raises:
    var suite = TestSuite()
    suite.test[test_every_stage_of_a_run_is_timed]()
    suite.test[test_the_json_is_valid_and_complete]()
    suite.test[test_the_plan_text_shows_the_pushdown]()
    suite.test[test_a_wrong_expected_answer_is_reported]()
    suite^.run()
