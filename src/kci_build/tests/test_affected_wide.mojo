# =============================================================================
# src/kci_build/tests/test_affected_wide.mojo
#   A widened change (komira#1153): 70 units sharing one build_targets
#   command, built by `build_affected_units` over ScriptedRunner with the
#   default batch size (DEFAULT_MAX_BATCH_UNITS, 32), so this file uses no
#   name the fix added and runs against the code before it:
#   - the 70 units are 3 batches of 24, 23 and 23 (ceil(70 / 32)), each a
#     consecutive slice in unit order (the artifacts file's dependency
#     order), not one batch of 70;
#   - a batch that times out with no unit attributed, and units the budget
#     left no time for, are INDETERMINATE (KCI-E-CANNOT-TELL: time ran
#     out), not FAILED; the batches around it still run and keep their
#     BUILT lines;
#   - a unit that fails is still FAILED (KCI-E-BUILD-FAILED), and it
#     outranks a timed-out batch.
#   The batch sizes, the run order and every outcome are exact.
# =============================================================================
#
# Every test asserts the outcome, the error id, len(runner.calls) and
# runner.remaining() == 0: an extra or a missing run shows in all four.
# =============================================================================

from std.ffi import external_call
from std.os import getenv, makedirs
from std.os.path import realpath

from std.testing import TestSuite, assert_equal, assert_false, assert_true

from kci_api import (
    ERROR_BUILD_FAILED,
    ERROR_CANNOT_TELL,
    OUTCOME_FAILED,
    OUTCOME_INDETERMINATE,
    OUTCOME_SUCCEEDED,
    RunIdentity,
)
from kci_artifact import parse_artifacts
from kci_build import BuildOutcome, BuildRequest, ScriptedRunner, ScriptedStep, build_affected_units

comptime _HEAD = "BUILD step: --affected-by 0123: WIDENED"
comptime _N = 70
comptime _NS = 1_000_000_000


def _name(i: Int) -> String:
    var d = String(i)
    if i < 10:
        d = String("0") + d
    return String("lib_") + d


def _target(i: Int) -> String:
    var n = _name(i)
    return String("//src/") + n + String(":") + n + String("_conda")


def _file() -> String:
    """`_N` artifacts lib_00..lib_69, one build system, in that order."""
    var s = String(
        'schema_version: 1\nbuild_systems {\n  name: "buck2"\n  executable: "buck2"\n  args: "build"\n'
        '  build_targets {\n    executable: "buck2"\n    args: "build"\n  }\n}\n'
    )
    for i in range(_N):
        s += (
            String('artifacts {\n  name: "') + _name(i) + String('"\n  build_system: "buck2"\n')
            + String('  args: "--out={out_dir}"\n  targets: "') + _target(i) + String('"\n}\n')
        )
    return s^


def _units() -> List[String]:
    var out = List[String]()
    for i in range(_N):
        out.append(_name(i))
    return out^


def _fresh(tag: String) raises -> String:
    var base = getenv("TEST_TMPDIR")
    if base.byte_length() == 0:
        base = getenv("TMPDIR")
    if base.byte_length() == 0:
        raise Error("neither TEST_TMPDIR nor TMPDIR is set")
    var d = base + String("/kbw_") + tag + String("_") + String(Int(external_call["getpid", Int32]()))
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


def _batch(lo: Int, hi: Int, took_s: Int, exit_code: Int32 = Int32(0), timed_out: Bool = False) -> ScriptedStep:
    """`buck2 build` over the targets of units lo..hi-1 (argv without argv[0])."""
    var a = List[String]()
    a.append(String("build"))
    for i in range(lo, hi):
        a.append(_target(i))
    return ScriptedStep(a^, exit_code=exit_code, timed_out=timed_out, elapsed_s=took_s)


def _go(req: BuildRequest, mut runner: ScriptedRunner) raises -> BuildOutcome:
    var arts = parse_artifacts(_file(), String("artifacts.textproto"))
    return build_affected_units(req, arts, _units(), String(_HEAD), List[String](), runner)


def _built(lo: Int, hi: Int) -> String:
    var s = String("")
    for i in range(lo, hi):
        s += String("[BUILT ") + _name(i) + String("]")
    return s^


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


def test_w1_a_widened_set_is_ceil_n_over_max_batches_in_unit_order() raises:
    # 70 units, 32 at most a batch: 3 batches, 24 + 23 + 23, consecutive
    # slices in unit order; the old code ran ONE batch of 70 (no step holds it)
    var req = _request(String("w1"), 0)
    var runner = ScriptedRunner()
    runner.expect(_batch(0, 24, took_s=10))
    runner.expect(_batch(24, 47, took_s=10))
    runner.expect(_batch(47, 70, took_s=10))
    var o = _go(req, runner)
    assert_equal(o.outcome, String(OUTCOME_SUCCEEDED), o.message)
    assert_equal(o.error_id, String(""))
    assert_equal(len(runner.calls), 3)
    assert_equal(runner.remaining(), 0)
    for k in range(3):
        assert_equal(runner.calls[k].stderr_path, req.log_dir + String("/_batch_") + String(k + 1) + String(".stderr"))
        assert_equal(runner.calls[k].timeout_s, 77)
    assert_equal(o.message, String(_HEAD) + String(": 70 unit(s) built"))
    assert_equal(_list(o.lines), _built(0, 70))


def test_w2_a_timed_out_batch_with_nobody_attributed_is_indeterminate() raises:
    # batch 2 uses its whole --build-timeout-s and times out: no unit of it
    # failed, time ran out. INDETERMINATE, not FAILED; batch 3 still runs
    var req = _request(String("w2"), 0)
    var runner = ScriptedRunner()
    runner.expect(_batch(0, 24, took_s=10))
    runner.expect(_batch(24, 47, took_s=77, timed_out=True))
    runner.expect(_batch(47, 70, took_s=10))
    var o = _go(req, runner)
    assert_equal(o.outcome, String(OUTCOME_INDETERMINATE), o.message)
    assert_equal(o.error_id, String(ERROR_CANNOT_TELL))
    assert_equal(len(runner.calls), 3)
    assert_equal(runner.remaining(), 0)
    var first = _first_line(o.message)
    assert_true(first.startswith(String("BUILD step: batch 2 (23 unit(s): lib_24, lib_25, ")), o.message)
    assert_true(first.find(String("` timed out (stderr: ")) >= 0, o.message)
    assert_true(first.endswith(String("): no unit of it was attributed")), o.message)
    assert_false(o.message.find(String("failed")) >= 0, o.message)
    assert_equal(_list(o.lines), _built(0, 24) + _built(47, 70))


def test_w3_the_budget_running_out_is_indeterminate_and_names_what_was_not_built() raises:
    # budget 120 s: batch 1 takes 50; batch 2 gets the 70 left and times
    # out; batch 3 is not started. Time ran out, nothing failed
    var req = _request(String("w3"), 120)
    var runner = ScriptedRunner()
    runner.expect(_batch(0, 24, took_s=50))
    runner.expect(_batch(24, 47, took_s=70, timed_out=True))
    var o = _go(req, runner)
    assert_equal(o.outcome, String(OUTCOME_INDETERMINATE), o.message)
    assert_equal(o.error_id, String(ERROR_CANNOT_TELL))
    assert_equal(len(runner.calls), 2)
    assert_equal(runner.remaining(), 0)
    assert_equal(runner.calls[1].timeout_s, 70)
    assert_true(_first_line(o.message).startswith(String("BUILD step: batch 2 (23 unit(s): lib_24, ")), o.message)
    assert_true(
        o.message.find(String(" timed out after 70 s, what was left of the build budget (--build-budget-s 120)")) >= 0,
        o.message,
    )
    assert_true(
        o.message.find(
            String("\nBUILD step: 23 of 70 unit(s) not built: the build budget (--build-budget-s 120) was spent")
            + String(" before their run could start: lib_47, lib_48, ")
        ) >= 0,
        o.message,
    )
    assert_true(o.message.endswith(String(", lib_69")), o.message)
    assert_equal(_list(o.lines), _built(0, 24))


def test_w4_a_failed_unit_is_still_failed() raises:
    # batch 2 exits 1; its units run alone and lib_24..lib_26 fail (the
    # 3-failure cap, the rest not tried); batch 3 still builds
    var req = _request(String("w4"), 0)
    var runner = ScriptedRunner()
    runner.expect(_batch(0, 24, took_s=10))
    runner.expect(_batch(24, 47, took_s=10, exit_code=Int32(1)))
    runner.expect(_batch(24, 25, took_s=1, exit_code=Int32(1)))
    runner.expect(_batch(25, 26, took_s=1, exit_code=Int32(1)))
    runner.expect(_batch(26, 27, took_s=1, exit_code=Int32(1)))
    runner.expect(_batch(47, 70, took_s=10))
    var o = _go(req, runner)
    assert_equal(o.outcome, String(OUTCOME_FAILED), o.message)
    assert_equal(o.error_id, String(ERROR_BUILD_FAILED))
    assert_equal(len(runner.calls), 6)
    assert_equal(runner.remaining(), 0)
    assert_equal(_first_line(o.message), String("BUILD step: 3 of 70 unit(s) failed: lib_24, lib_25, lib_26"))
    assert_equal(_list(o.lines), _built(0, 24) + _built(47, 70))


def test_w5_a_failure_outranks_time_running_out() raises:
    # batch 1 exits 1 and lib_00..lib_02 fail alone (the cap); batch 2
    # times out; batch 3 builds. FAILED, and the timed-out batch is named
    var req = _request(String("w5"), 0)
    var runner = ScriptedRunner()
    runner.expect(_batch(0, 24, took_s=10, exit_code=Int32(2)))
    runner.expect(_batch(0, 1, took_s=1, exit_code=Int32(2)))
    runner.expect(_batch(1, 2, took_s=1, exit_code=Int32(2)))
    runner.expect(_batch(2, 3, took_s=1, exit_code=Int32(2)))
    runner.expect(_batch(24, 47, took_s=77, timed_out=True))
    runner.expect(_batch(47, 70, took_s=10))
    var o = _go(req, runner)
    assert_equal(o.outcome, String(OUTCOME_FAILED), o.message)
    assert_equal(o.error_id, String(ERROR_BUILD_FAILED))
    assert_equal(len(runner.calls), 6)
    assert_equal(runner.remaining(), 0)
    assert_equal(_first_line(o.message), String("BUILD step: 3 of 70 unit(s) failed: lib_00, lib_01, lib_02"))
    assert_true(
        o.message.find(String("\nbatch 2 (23 unit(s): lib_24, ")) >= 0
        and o.message.find(String("no unit of it was attributed")) >= 0,
        o.message,
    )
    assert_equal(_list(o.lines), _built(47, 70))


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
