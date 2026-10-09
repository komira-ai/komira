# =============================================================================
# src/kci_build/tests/test_affected_budget.mojo
#   The per-change check's build budget (`--build-budget-s`,
#   affected_batch.mojo THE BUDGET) over ScriptedRunner, whose steps say how
#   long each run "takes" (`elapsed_s` advances the runner's clock, whatever
#   the run's result), so every number here is exact. The deadline is the
#   budget after clock 0 (dispatch sets kci's start plus the budget):
#   `run_timeout_s` itself; no budget leaves every run its
#   --build-timeout-s; with one, each run gets what is left until the
#   deadline (at most --build-timeout-s), after a run that passed, failed or
#   timed out alike; a run with nothing left is not started and
#   its units are named as not built (FAILED, never a pass) while the units
#   an earlier run built keep their BUILT lines; a batch the budget cut short
#   says so when it times out; retries share the same budget and a batch
#   whose retries ran out of budget is not called interference.
# =============================================================================
#
# Every test asserts the outcome, the error id, len(runner.calls) and
# runner.remaining() == 0: an extra or a missing run shows in all four.
# =============================================================================

from std.ffi import external_call
from std.os import getenv, makedirs
from std.os.path import realpath

from std.testing import TestSuite, assert_equal, assert_false, assert_true

from kci_api import ERROR_BUILD_FAILED, OUTCOME_FAILED, OUTCOME_SUCCEEDED, RunIdentity
from kci_artifact import parse_artifacts
from kci_artifact_proto.artifact import Artifacts
from kci_build import (
    NO_BUILD_BUDGET,
    BuildOutcome,
    BuildRequest,
    ScriptedRunner,
    ScriptedStep,
    build_affected_units,
    run_timeout_s,
)

comptime _HEAD = "BUILD step: --affected-by 0123: AFFECTED"

# Two build_targets commands: `buck2 build` (lib_a, lib_b, lints) and
# `buck2 build --keep-going` (lib_c, lib_d).
comptime _FILE = """schema_version: 1
build_systems {
  name: "buck2"
  executable: "buck2"
  args: "build"
  build_targets {
    executable: "buck2"
    args: "build"
  }
}
build_systems {
  name: "other"
  executable: "buck2"
  args: "build"
  build_targets {
    executable: "buck2"
    args: "build"
    args: "--keep-going"
  }
}
artifacts {
  name: "lib_a"
  build_system: "buck2"
  args: "--out={out_dir}"
  targets: "//src/lib_a:lib_a_conda"
}
artifacts {
  name: "lib_b"
  build_system: "buck2"
  args: "--out={out_dir}"
  targets: "//src/lib_b:lib_b_conda"
}
artifacts {
  name: "lib_c"
  build_system: "other"
  args: "--out={out_dir}"
  targets: "//src/lib_c:lib_c_conda"
}
artifacts {
  name: "lib_d"
  build_system: "other"
  args: "--out={out_dir}"
  targets: "//src/lib_d:lib_d_conda"
}
checks {
  name: "lints"
  build_system: "buck2"
  targets: "//:docs"
}
"""

comptime _A = "//src/lib_a:lib_a_conda"
comptime _B = "//src/lib_b:lib_b_conda"
comptime _C = "//src/lib_c:lib_c_conda"
comptime _D = "//src/lib_d:lib_d_conda"
comptime _DOCS = "//:docs"
comptime _NS = 1_000_000_000


def _fresh(tag: String) raises -> String:
    var base = getenv("TEST_TMPDIR")
    if base.byte_length() == 0:
        base = getenv("TMPDIR")
    if base.byte_length() == 0:
        raise Error("neither TEST_TMPDIR nor TMPDIR is set")
    var d = base + String("/kbb_") + tag + String("_") + String(Int(external_call["getpid", Int32]()))
    makedirs(d + String("/repo"), exist_ok=True)
    return realpath(d)


def _request(tag: String, budget_s: Int) raises -> BuildRequest:
    var root = _fresh(tag)
    var r = BuildRequest(RunIdentity(String("gh-9"), 1))
    r.work_dir = root + String("/repo")
    r.log_dir = root + String("/logs")
    r.build_timeout_s = 77
    r.build_budget_s = budget_s
    r.build_deadline_ns = budget_s * _NS
    return r^


def _argv(*xs: String) -> List[String]:
    var out = List[String]()
    for x in xs:
        out.append(String(x))
    return out^


def _build(
    var argv: List[String], took_s: Int, exit_code: Int32 = Int32(0), timed_out: Bool = False
) -> ScriptedStep:
    """A `buck2 build` run that took `took_s` seconds."""
    var a = _argv("build")
    for i in range(len(argv)):
        a.append(argv[i].copy())
    return ScriptedStep(a^, exit_code=exit_code, timed_out=timed_out, elapsed_s=took_s)


def _keep(
    var argv: List[String], took_s: Int, exit_code: Int32 = Int32(0), timed_out: Bool = False
) -> ScriptedStep:
    """A `buck2 build --keep-going` run (build system `other`)."""
    var a = _argv("--keep-going")
    for i in range(len(argv)):
        a.append(argv[i].copy())
    return _build(a^, took_s, exit_code=exit_code, timed_out=timed_out)


def _go(req: BuildRequest, units: List[String], mut runner: ScriptedRunner) raises -> BuildOutcome:
    var arts = parse_artifacts(String(_FILE), String("artifacts.textproto"))
    return build_affected_units(req, arts, units, String(_HEAD), List[String](), runner)


def _list(xs: List[String]) -> String:
    var s = String("")
    for i in range(len(xs)):
        s += String("[") + xs[i] + String("]")
    return s^


def _first_line(text: String) -> String:
    var nl = text.find(String("\n"))
    if nl < 0:
        return text.copy()
    return String(text[byte = 0:nl])


def test_b1_run_timeout_s() raises:
    # run_timeout_s(--build-timeout-s, --build-budget-s, deadline, now);
    # the deadline 1000 s after a clock reading of 900 s
    comptime D = 1000 * _NS
    # no budget: --build-timeout-s, whatever the clock says
    assert_equal(NO_BUILD_BUDGET, 0)
    assert_equal(run_timeout_s(77, NO_BUILD_BUDGET, 0, 0), 77)
    assert_equal(run_timeout_s(77, NO_BUILD_BUDGET, D, 10_000 * _NS), 77)
    # more left than --build-timeout-s: it caps the run
    assert_equal(run_timeout_s(77, 100, D, 900 * _NS), 77)
    assert_equal(run_timeout_s(77, 100, D, 923 * _NS), 77)
    # otherwise the whole seconds left, rounded down
    assert_equal(run_timeout_s(77, 100, D, 924 * _NS), 76)
    assert_equal(run_timeout_s(77, 100, D, 930 * _NS), 70)
    assert_equal(run_timeout_s(77, 100, D, 930 * _NS + 1), 69)
    assert_equal(run_timeout_s(77, 100, D, 999 * _NS), 1)
    # less than one second left, none, or past the deadline: not started
    assert_equal(run_timeout_s(77, 100, D, 999 * _NS + 1), 0)
    assert_equal(run_timeout_s(77, 100, D, D), 0)
    assert_equal(run_timeout_s(77, 100, D, 1030 * _NS), 0)


def test_b1_time_before_the_step_is_charged() raises:
    # the deadline counts from kci's start: with 70 of the 100 s already
    # gone before the step (the clock at 30 s left), the first run gets 30
    var req = _request(String("b1b"), 100)
    req.build_deadline_ns = 30 * _NS
    var runner = ScriptedRunner()
    runner.expect(_build(_argv(_A, _B, _DOCS), took_s=5))
    var o = _go(req, _argv("lib_a", "lib_b", "lints"), runner)
    assert_equal(o.outcome, String(OUTCOME_SUCCEEDED), o.message)
    assert_equal(len(runner.calls), 1)
    assert_equal(runner.remaining(), 0)
    assert_equal(runner.calls[0].timeout_s, 30)


def test_b2_without_a_budget_every_run_has_its_build_timeout() raises:
    var req = _request(String("b2"), NO_BUILD_BUDGET)
    var runner = ScriptedRunner()
    runner.expect(_build(_argv(_A, _B, _DOCS), took_s=5000))
    runner.expect(_keep(_argv(_C, _D), took_s=5000))
    var o = _go(req, _argv("lib_a", "lib_b", "lints", "lib_c", "lib_d"), runner)
    assert_equal(o.outcome, String(OUTCOME_SUCCEEDED), o.message)
    assert_equal(len(runner.calls), 2)
    assert_equal(runner.remaining(), 0)
    assert_equal(runner.calls[0].timeout_s, 77)
    assert_equal(runner.calls[1].timeout_s, 77)


def test_b3_each_run_gets_what_the_earlier_runs_left() raises:
    # budget 100 s: batch 1 may take 77 (its --build-timeout-s) and takes
    # 40; batch 2 then has 60 left
    var req = _request(String("b3"), 100)
    var runner = ScriptedRunner()
    runner.expect(_build(_argv(_A, _B, _DOCS), took_s=40))
    runner.expect(_keep(_argv(_C, _D), took_s=59))
    var o = _go(req, _argv("lib_a", "lib_b", "lints", "lib_c", "lib_d"), runner)
    assert_equal(o.outcome, String(OUTCOME_SUCCEEDED), o.message)
    assert_equal(o.error_id, String(""))
    assert_equal(len(runner.calls), 2)
    assert_equal(runner.remaining(), 0)
    assert_equal(runner.calls[0].timeout_s, 77)
    assert_equal(runner.calls[1].timeout_s, 60)
    assert_equal(o.message, String(_HEAD) + String(": 5 unit(s) built"))
    assert_equal(_list(o.lines), String("[BUILT lib_a][BUILT lib_b][BUILT lints][BUILT lib_c][BUILT lib_d]"))


def test_b4_a_run_with_no_budget_left_is_not_started_and_its_units_are_named() raises:
    # batch 1 spends the whole budget and passes: its units are BUILT;
    # batch 2 is never started, and its units are named as not built
    var req = _request(String("b4"), 100)
    var runner = ScriptedRunner()
    runner.expect(_build(_argv(_A, _B, _DOCS), took_s=100))
    var o = _go(req, _argv("lib_a", "lib_b", "lints", "lib_c", "lib_d"), runner)
    assert_equal(o.outcome, String(OUTCOME_FAILED), o.message)
    assert_equal(o.error_id, String(ERROR_BUILD_FAILED))
    assert_equal(len(runner.calls), 1)
    assert_equal(runner.remaining(), 0)
    assert_equal(
        o.message,
        String(
            "BUILD step: 2 of 5 unit(s) not built: the build budget (--build-budget-s 100) was spent before"
            " their run could start: lib_c, lib_d"
        ),
    )
    assert_equal(_list(o.lines), String("[BUILT lib_a][BUILT lib_b][BUILT lints]"))


def test_b5_a_batch_the_budget_cut_short_says_so() raises:
    # lib_c alone takes 50 of 100 s; the batch gets the 50 left (not 77),
    # times out, and is attributed to no unit; lib_c keeps its BUILT line
    var req = _request(String("b5"), 100)
    var runner = ScriptedRunner()
    runner.expect(_keep(_argv(_C), took_s=50))
    runner.expect(_build(_argv(_A, _B, _DOCS), took_s=50, timed_out=True))
    var o = _go(req, _argv("lib_c", "lib_a", "lib_b", "lints"), runner)
    assert_equal(o.outcome, String(OUTCOME_FAILED), o.message)
    assert_equal(o.error_id, String(ERROR_BUILD_FAILED))
    assert_equal(len(runner.calls), 2)
    assert_equal(runner.remaining(), 0)
    assert_equal(runner.calls[1].timeout_s, 50)
    assert_true(
        _first_line(o.message).startswith(
            String("BUILD step: batch 1 (3 unit(s): lib_a, lib_b, lints): `buck2 build ") + String(_A)
        ),
        o.message,
    )
    assert_true(
        o.message.find(
            String(" timed out after 50 s, what was left of the build budget (--build-budget-s 100) (stderr: ")
        ) >= 0,
        o.message,
    )
    assert_true(o.message.find(String("no unit of it was attributed")) >= 0, o.message)
    assert_equal(_list(o.lines), String("[BUILT lib_c]"))


def test_b5_a_timed_out_batch_is_charged_before_the_next_group() raises:
    # batch 1 times out after its 77 s; batch 2 (another command) gets the
    # 23 s left, not 77 nor 100: a timed-out run's time counts like any other
    var req = _request(String("b5c"), 100)
    var runner = ScriptedRunner()
    runner.expect(_build(_argv(_A, _B, _DOCS), took_s=77, timed_out=True))
    runner.expect(_keep(_argv(_C, _D), took_s=23))
    var o = _go(req, _argv("lib_a", "lib_b", "lints", "lib_c", "lib_d"), runner)
    assert_equal(o.outcome, String(OUTCOME_FAILED), o.message)
    assert_equal(o.error_id, String(ERROR_BUILD_FAILED))
    assert_equal(len(runner.calls), 2)
    assert_equal(runner.remaining(), 0)
    assert_equal(runner.calls[0].timeout_s, 77)
    assert_equal(runner.calls[1].timeout_s, 23)
    assert_true(o.message.find(String("no unit of it was attributed")) >= 0, o.message)
    # the later group still reports
    assert_equal(_list(o.lines), String("[BUILT lib_c][BUILT lib_d]"))


def test_b5_a_failed_unit_is_charged_before_the_next_run() raises:
    # lib_c alone fails (exit 1) after 30 s; the batch after it gets the 70
    # left: a failed run's time counts like any other
    var req = _request(String("b5d"), 100)
    var runner = ScriptedRunner()
    runner.expect(_keep(_argv(_C), took_s=30, exit_code=Int32(1)))
    runner.expect(_build(_argv(_A, _B, _DOCS), took_s=10))
    var o = _go(req, _argv("lib_c", "lib_a", "lib_b", "lints"), runner)
    assert_equal(o.outcome, String(OUTCOME_FAILED), o.message)
    assert_equal(o.error_id, String(ERROR_BUILD_FAILED))
    assert_equal(len(runner.calls), 2)
    assert_equal(runner.remaining(), 0)
    assert_equal(runner.calls[0].timeout_s, 77)
    assert_equal(runner.calls[1].timeout_s, 70)
    assert_equal(_first_line(o.message), String("BUILD step: 1 of 4 unit(s) failed: lib_c"))
    assert_equal(_list(o.lines), String("[BUILT lib_a][BUILT lib_b][BUILT lints]"))


def test_b5_a_timeout_the_budget_did_not_shorten_reads_as_before() raises:
    # 100 s left and --build-timeout-s 77: the batch had its own timeout,
    # not the budget's, and its note does not blame the budget
    var req = _request(String("b5b"), 1000)
    var runner = ScriptedRunner()
    runner.expect(_build(_argv(_A, _B, _DOCS), took_s=77, timed_out=True))
    var o = _go(req, _argv("lib_a", "lib_b", "lints"), runner)
    assert_equal(o.outcome, String(OUTCOME_FAILED), o.message)
    assert_equal(len(runner.calls), 1)
    assert_equal(runner.remaining(), 0)
    assert_equal(runner.calls[0].timeout_s, 77)
    assert_true(o.message.find(String("` timed out (stderr: ")) >= 0, o.message)
    assert_false(o.message.find(String("build budget")) >= 0, o.message)


def test_b6_retries_share_the_budget_and_running_out_is_not_interference() raises:
    # the batch fails after 60 of 100 s; lib_a alone gets the 40 left and
    # passes using all of it; lib_b and lints are not started. That is
    # FAILED (not INDETERMINATE interference: not every unit was tried)
    var req = _request(String("b6"), 100)
    var runner = ScriptedRunner()
    runner.expect(_build(_argv(_A, _B, _DOCS), took_s=60, exit_code=Int32(1)))
    runner.expect(_build(_argv(_A), took_s=40))
    var o = _go(req, _argv("lib_a", "lib_b", "lints"), runner)
    assert_equal(o.outcome, String(OUTCOME_FAILED), o.message)
    assert_equal(o.error_id, String(ERROR_BUILD_FAILED))
    assert_equal(len(runner.calls), 2)
    assert_equal(runner.remaining(), 0)
    assert_equal(runner.calls[1].timeout_s, 40)
    assert_equal(
        _first_line(o.message),
        String(
            "BUILD step: 2 of 3 unit(s) not built: the build budget (--build-budget-s 100) was spent before"
            " their run could start: lib_b, lints"
        ),
    )
    # the failed batch's note still follows
    assert_true(o.message.find(String("\nbatch 1 (3 unit(s)): `buck2 build ")) >= 0, o.message)
    assert_false(o.message.find(String("interfere")) >= 0, o.message)
    assert_equal(_list(o.lines), String("[BUILT lib_a]"))


def test_b7_a_retry_the_budget_cut_short_is_a_failed_unit_that_says_so() raises:
    # the batch fails after 70 of 100 s; lib_a alone gets 30, times out:
    # a failed unit, whose paragraph names the budget; the rest not started
    var req = _request(String("b7"), 100)
    var runner = ScriptedRunner()
    runner.expect(_build(_argv(_A, _B, _DOCS), took_s=70, exit_code=Int32(1)))
    runner.expect(_build(_argv(_A), took_s=30, timed_out=True))
    var o = _go(req, _argv("lib_a", "lib_b", "lints"), runner)
    assert_equal(o.outcome, String(OUTCOME_FAILED), o.message)
    assert_equal(len(runner.calls), 2)
    assert_equal(runner.remaining(), 0)
    assert_equal(runner.calls[1].timeout_s, 30)
    assert_equal(_first_line(o.message), String("BUILD step: 1 of 3 unit(s) failed: lib_a"))
    assert_true(
        o.message.find(
            String("\nunit 'lib_a': `buck2 build ") + String(_A)
            + String("` timed out after 30 s, what was left of the build budget (--build-budget-s 100) (stderr: ")
        ) >= 0,
        o.message,
    )
    assert_true(
        o.message.find(
            String("\nBUILD step: 2 of 3 unit(s) not built: the build budget (--build-budget-s 100) was spent")
            + String(" before their run could start: lib_b, lints")
        ) >= 0,
        o.message,
    )
    assert_equal(len(o.lines), 0)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
