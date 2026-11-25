# =============================================================================
# run_sql under a RunControl: cancel and progress
# =============================================================================
#
# What these tests prove:
#
#   * A fresh control is not cancelled and reads 0 of 0 segments.
#   * A query run under a control answers as without one and leaves its
#     progress at done == total, with total above 0.
#   * A control cancelled before the run refuses the run at step `execute`
#     with the cancelled error word for word, `pipeline_exec: the query was
#     cancelled: the caller cancelled the run`; the run counted its segments
#     and finished none (done 0, total above 0). The same context then
#     answers the next query.
#   * A statement refused before its plan runs (a bind error) is refused at its
#     own step under a cancelled control: the control does not hide it.
#   * Cancel is one-way and shared: a cancel through one handle is seen on
#     every handle `share()` made, before and after it; a second cancel does
#     nothing and keeps the reason; a later run given the control is refused
#     too.
#   * Two runs given one control sum into its progress: after the second,
#     done and total are twice what the first left.
#   * `run_sql_with` given a control is cancelled the same way.

from std.testing import TestSuite, assert_equal, assert_false, assert_true

from pipeline_exec.source_parquet import LocalOnlyScanFs
from sdk_exec.engine_context import EngineContext
from sdk_exec.engine_options import EngineOptions
from sdk_exec.engine_sql import STEP_BIND, STEP_EXECUTE, run_sql, run_sql_with
from sdk_exec.run_control import RUN_CANCEL_REASON, RunControl

comptime _CANCELLED = (
    "pipeline_exec: the query was cancelled: the caller cancelled the run"
)


def _new_context() raises -> EngineContext:
    return EngineContext(EngineOptions(worker_count=2))


def test_a_fresh_control_is_not_cancelled_and_counts_nothing() raises:
    var control = RunControl()
    assert_false(control.is_cancelled())
    var s = control.snapshot()
    assert_equal(s.done, 0)
    assert_equal(s.total, 0)


def test_a_run_under_a_control_finishes_every_segment() raises:
    var ctx = _new_context()
    var control = RunControl()
    var out = run_sql(ctx, "select 1 as n", control)
    assert_true(out.ok())
    assert_equal(len(out.batches), 1)
    assert_equal(out.batches[0].num_rows(), 1)
    var s = control.snapshot()
    assert_true(s.total > 0)
    assert_equal(s.done, s.total)


def test_a_cancelled_control_refuses_the_run_at_execute() raises:
    var ctx = _new_context()
    var control = RunControl()
    control.cancel()
    var out = run_sql(ctx, "select 1 as n", control)
    assert_false(out.ok())
    ref refusal = out.refusal.value()
    assert_equal(refusal.step, String(STEP_EXECUTE))
    assert_equal(refusal.reason, String(_CANCELLED))
    var s = control.snapshot()
    assert_true(s.total > 0)
    assert_equal(s.done, 0)
    # The context runs the next query, under a control nobody cancelled.
    var fresh = RunControl()
    var next = run_sql(ctx, "select 2 as n", fresh)
    assert_true(next.ok())
    assert_equal(next.batches[0].num_rows(), 1)


def test_a_bind_refusal_is_not_hidden_by_a_cancel() raises:
    var ctx = _new_context()
    var control = RunControl()
    control.cancel()
    var out = run_sql(ctx, "select * from nosuch", control)
    assert_false(out.ok())
    assert_equal(out.refusal.value().step, String(STEP_BIND))
    assert_equal(control.snapshot().total, 0)


def test_a_cancel_is_one_way_and_shared() raises:
    var control = RunControl()
    var before = control.share()
    control.cancel()
    var after = control.share()
    assert_true(control.is_cancelled())
    assert_true(before.is_cancelled())
    assert_true(after.is_cancelled())
    # A second cancel, through another handle, does nothing.
    before.cancel()
    assert_true(control.is_cancelled())
    assert_equal(control.token().reason(), String(RUN_CANCEL_REASON))
    # Every later run given the control is refused.
    var ctx = _new_context()
    for _ in range(2):
        var out = run_sql(ctx, "select 1 as n", after)
        assert_equal(out.refusal.value().reason, String(_CANCELLED))


def test_a_cancel_through_a_share_reaches_the_original() raises:
    var control = RunControl()
    var other = control.share()
    other.cancel()
    assert_true(control.is_cancelled())
    var ctx = _new_context()
    var out = run_sql(ctx, "select 1 as n", control)
    assert_equal(out.refusal.value().reason, String(_CANCELLED))


def test_runs_given_one_control_sum_into_its_progress() raises:
    var ctx = _new_context()
    var control = RunControl()
    assert_true(run_sql(ctx, "select 1 as n", control).ok())
    var first = control.snapshot()
    assert_true(first.total > 0)
    assert_true(run_sql(ctx, "select 1 as n", control.share()).ok())
    var second = control.snapshot()
    assert_equal(second.total, 2 * first.total)
    assert_equal(second.done, second.total)


def test_run_sql_with_is_cancelled_the_same_way() raises:
    var ctx = _new_context()
    var control = RunControl()
    control.cancel()
    var out = run_sql_with(ctx, "select 1 as n", LocalOnlyScanFs(), control)
    ref refusal = out.refusal.value()
    assert_equal(refusal.step, String(STEP_EXECUTE))
    assert_equal(refusal.reason, String(_CANCELLED))


def main() raises:
    var suite = TestSuite()
    suite.test[test_a_fresh_control_is_not_cancelled_and_counts_nothing]()
    suite.test[test_a_run_under_a_control_finishes_every_segment]()
    suite.test[test_a_cancelled_control_refuses_the_run_at_execute]()
    suite.test[test_a_bind_refusal_is_not_hidden_by_a_cancel]()
    suite.test[test_a_cancel_is_one_way_and_shared]()
    suite.test[test_a_cancel_through_a_share_reaches_the_original]()
    suite.test[test_runs_given_one_control_sum_into_its_progress]()
    suite.test[test_run_sql_with_is_cancelled_the_same_way]()
    suite^.run()
