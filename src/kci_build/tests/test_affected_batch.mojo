# =============================================================================
# src/kci_build/tests/test_affected_batch.mojo
#   Step 5 of the per-change check, `build_affected_units`, over
#   ScriptedRunner: one run per shared build_targets command (the argv, its
#   logs, its argv file), a target two units share given once, a unit alone
#   built as before, a failed batch retried unit by unit to name each failing
#   unit, the 3-failure cap, a timed-out or signal-killed batch attributed
#   to no unit (timed out: INDETERMINATE, time ran out; killed: FAILED;
#   komira#1153), a run that cannot be started stopping the step and
#   outranking a failed unit,
#   interference never a pass, the outcome's precedence, and BUILT only for
#   units an exit-0 run covered. One case runs a real fake build program
#   through SupervisorRunner.
# =============================================================================
#
# A ScriptedRunner that is asked for a run its script does not hold RAISES,
# and the step turns that into INDETERMINATE (KCI-E-CANNOT-TELL), not a
# crash. So every test asserts the outcome, the error id, len(runner.calls)
# and runner.remaining() == 0: an extra or a missing run shows in all four.
# =============================================================================

from std.ffi import external_call
from std.os import getenv, makedirs
from std.os.path import realpath
from std.pathlib import Path

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
from kci_artifact_proto.artifact import Artifacts
from kci_build import (
    MAX_FAILED_UNITS,
    BuildOutcome,
    BuildRequest,
    ScriptedRunner,
    ScriptedStep,
    SupervisorRunner,
    build_affected_units,
    write_text_file,
)

comptime _HEAD = "BUILD step: --affected-by 0123: AFFECTED"

# Three build systems: buck2 and pack share one build_targets command
# (`buck2 build`), other's is `buck2 build --keep-going`. Unit order:
# lib_a lib_b meta lib_c lib_d, then lints tests_cell shared.
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
  name: "pack"
  executable: "buck2"
  args: "run"
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
  name: "meta"
  build_system: "pack"
  args: "--out={out_dir}"
  targets: "//tools/pack:pack"
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
  targets: "//:shell_lint"
}
checks {
  name: "tests_cell"
  build_system: "buck2"
  targets: "tests//functional/..."
}
checks {
  name: "shared"
  build_system: "buck2"
  targets: "//src/lib_a:lib_a_conda"
  targets: "//:extra"
}
"""


def _fresh(tag: String) raises -> String:
    var base = getenv("TEST_TMPDIR")
    if base.byte_length() == 0:
        base = getenv("TMPDIR")
    if base.byte_length() == 0:
        raise Error("neither TEST_TMPDIR nor TMPDIR is set")
    var d = base + String("/kb_") + tag + String("_") + String(Int(external_call["getpid", Int32]()))
    makedirs(d + String("/repo"), exist_ok=True)
    return realpath(d)


def _request(root: String) raises -> BuildRequest:
    var r = BuildRequest(RunIdentity(String("gh-9"), 1))
    r.work_dir = root + String("/repo")
    r.log_dir = root + String("/logs")
    r.build_timeout_s = 77
    return r^


def _arts(text: String = String(_FILE)) raises -> Artifacts:
    return parse_artifacts(text, String("artifacts.textproto"))


def _argv(*xs: String) -> List[String]:
    var out = List[String]()
    for x in xs:
        out.append(String(x))
    return out^


def _build(var argv: List[String], exit_code: Int32 = Int32(0), timed_out: Bool = False, stderr: String = String("")) -> ScriptedStep:
    """A `buck2 build` run (the runner sees argv without argv[0])."""
    var a = _argv("build")
    for i in range(len(argv)):
        a.append(argv[i].copy())
    return ScriptedStep(a^, exit_code=exit_code, stderr_text=stderr, timed_out=timed_out)


def _keep(var argv: List[String], exit_code: Int32 = Int32(0), timed_out: Bool = False) -> ScriptedStep:
    """A `buck2 build --keep-going` run (build system `other`)."""
    var a = _argv("--keep-going")
    for i in range(len(argv)):
        a.append(argv[i].copy())
    return _build(a^, exit_code=exit_code, timed_out=timed_out)


def _go(req: BuildRequest, units: List[String], mut runner: ScriptedRunner) raises -> BuildOutcome:
    return build_affected_units(req, _arts(), units, String(_HEAD), List[String](), runner)


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


comptime _A = "//src/lib_a:lib_a_conda"
comptime _B = "//src/lib_b:lib_b_conda"
comptime _C = "//src/lib_c:lib_c_conda"
comptime _D = "//src/lib_d:lib_d_conda"
comptime _P = "//tools/pack:pack"
comptime _DOCS = "//:docs"
comptime _SHELL = "//:shell_lint"
comptime _TESTS = "tests//functional/..."


# ---- one run per shared command ---------------------------------------------


def test_t1_three_units_build_in_one_call() raises:
    var root = _fresh(String("t1"))
    var req = _request(root)
    var runner = ScriptedRunner()
    runner.expect(_build(_argv(_A, _B, _DOCS, _SHELL)))
    var o = _go(req, _argv("lib_a", "lib_b", "lints"), runner)
    assert_equal(o.outcome, String(OUTCOME_SUCCEEDED), o.message)
    assert_equal(o.error_id, String(""))
    assert_equal(len(runner.calls), 1)
    assert_equal(runner.remaining(), 0)
    ref call = runner.calls[0]
    assert_equal(call.path, String("buck2"))
    assert_equal(call.cwd, req.work_dir)
    assert_equal(call.timeout_s, 77)
    assert_equal(call.stdout_path, req.log_dir + String("/_batch_1.stdout"))
    assert_equal(call.stderr_path, req.log_dir + String("/_batch_1.stderr"))
    assert_equal(o.message, String(_HEAD) + String(": 3 unit(s) built"))
    assert_equal(_list(o.lines), String("[BUILT lib_a][BUILT lib_b][BUILT lints]"))


def test_t2_a_target_two_units_share_is_built_once() raises:
    var root = _fresh(String("t2"))
    var req = _request(root)
    var runner = ScriptedRunner()
    runner.expect(_build(_argv(_A, "//:extra")))
    var o = _go(req, _argv("lib_a", "shared"), runner)
    assert_equal(o.outcome, String(OUTCOME_SUCCEEDED), o.message)
    assert_equal(o.error_id, String(""))
    assert_equal(len(runner.calls), 1)
    assert_equal(runner.remaining(), 0)
    assert_equal(_list(o.lines), String("[BUILT lib_a][BUILT shared]"))


def test_t3_a_failing_unit_alone_runs_once() raises:
    var root = _fresh(String("t3"))
    var req = _request(root)
    var runner = ScriptedRunner()
    runner.expect(_build(_argv(_DOCS, _SHELL), exit_code=Int32(3), stderr=String("lint FAILED")))
    var o = _go(req, _argv("lints"), runner)
    assert_equal(o.outcome, String(OUTCOME_FAILED), o.message)
    assert_equal(o.error_id, String(ERROR_BUILD_FAILED))
    assert_equal(len(runner.calls), 1)
    assert_equal(runner.remaining(), 0)
    assert_equal(runner.calls[0].stderr_path, req.log_dir + String("/lints.stderr"))
    assert_equal(_first_line(o.message), String("BUILD step: 1 of 1 unit(s) failed: lints"))
    # the per-unit paragraph is the text a failed unit always had
    assert_true(
        o.message.find(
            String("\nunit 'lints': `buck2 build //:docs //:shell_lint` exit 3 (stderr: ") + req.log_dir
            + String("/lints.stderr)\nlint FAILED")
        ) >= 0,
        o.message,
    )
    assert_equal(len(o.lines), 0)


# ---- a failed batch names each failing unit ---------------------------------


def test_t4_a_failed_batch_names_each_failing_unit() raises:
    var root = _fresh(String("t4"))
    var req = _request(root)
    var runner = ScriptedRunner()
    runner.expect(_build(_argv(_A, _B, _DOCS, _SHELL), exit_code=Int32(1)))
    runner.expect(_build(_argv(_A), exit_code=Int32(1), stderr=String("test_a FAILED")))
    runner.expect(_build(_argv(_B)))
    runner.expect(_build(_argv(_DOCS, _SHELL), timed_out=True))
    var o = _go(req, _argv("lib_a", "lib_b", "lints"), runner)
    assert_equal(o.outcome, String(OUTCOME_FAILED), o.message)
    assert_equal(o.error_id, String(ERROR_BUILD_FAILED))
    assert_equal(len(runner.calls), 4)
    assert_equal(runner.remaining(), 0)
    assert_equal(_first_line(o.message), String("BUILD step: 2 of 3 unit(s) failed: lib_a, lints"))
    assert_true(o.message.find(String("unit 'lib_a': `buck2 build //src/lib_a:lib_a_conda` exit 1 (stderr: ")) >= 0, o.message)
    assert_true(o.message.find(String("test_a FAILED")) >= 0, o.message)
    # a retry that times out is a failed unit
    assert_true(o.message.find(String("unit 'lints': `buck2 build //:docs //:shell_lint` timed out (stderr: ")) >= 0, o.message)
    # the failed batch's note: its exit, stderr and argv file
    assert_true(
        o.message.find(
            String("batch 1 (3 unit(s)): `buck2 build //src/lib_a:lib_a_conda //src/lib_b:lib_b_conda //:docs //:shell_lint` exit 1 (stderr: ")
            + req.log_dir + String("/_batch_1.stderr; argv in ") + req.log_dir + String("/_batch_1.argv)")
        ) >= 0,
        o.message,
    )
    assert_false(o.message.find(String("interfere")) >= 0, o.message)
    assert_equal(runner.calls[1].stdout_path, req.log_dir + String("/lib_a.stdout"))
    assert_equal(_list(o.lines), String("[BUILT lib_b]"))


def test_t5_the_retries_stop_after_three_failed_units() raises:
    assert_equal(MAX_FAILED_UNITS, 3)
    var root = _fresh(String("t5"))
    var req = _request(root)
    var runner = ScriptedRunner()
    runner.expect(_build(_argv(_A, _B, _DOCS, _SHELL, _TESTS, "//:extra"), exit_code=Int32(1)))
    runner.expect(_build(_argv(_A), exit_code=Int32(1)))
    runner.expect(_build(_argv(_B), exit_code=Int32(1)))
    runner.expect(_build(_argv(_DOCS, _SHELL), exit_code=Int32(1)))
    var o = _go(req, _argv("lib_a", "lib_b", "lints", "tests_cell", "shared"), runner)
    assert_equal(o.outcome, String(OUTCOME_FAILED), o.message)
    assert_equal(o.error_id, String(ERROR_BUILD_FAILED))
    assert_equal(len(runner.calls), 1 + 3)
    assert_equal(runner.remaining(), 0)
    assert_equal(_first_line(o.message), String("BUILD step: 3 of 5 unit(s) failed: lib_a, lib_b, lints"))
    assert_true(o.message.find(String("\n2 unit(s) not tried after 3 failures: tests_cell, shared")) >= 0, o.message)
    # the note shows the command and its first 4 targets
    assert_true(
        o.message.find(
            String("batch 1 (5 unit(s)): `buck2 build //src/lib_a:lib_a_conda //src/lib_b:lib_b_conda //:docs //:shell_lint` exit 1")
        ) >= 0,
        o.message,
    )
    assert_equal(len(o.lines), 0)


def test_t6_a_passing_batch_retries_nothing() raises:
    var root = _fresh(String("t6"))
    var req = _request(root)
    var runner = ScriptedRunner()
    runner.expect(_build(_argv(_P, _TESTS)))
    var o = _go(req, _argv("meta", "tests_cell"), runner)
    assert_equal(o.outcome, String(OUTCOME_SUCCEEDED), o.message)
    assert_equal(o.error_id, String(""))
    assert_equal(len(runner.calls), 1)
    assert_equal(runner.remaining(), 0)
    assert_equal(_list(o.lines), String("[BUILT meta][BUILT tests_cell]"))


def test_t7_a_failed_batch_whose_units_all_build_alone_is_never_a_pass() raises:
    var root = _fresh(String("t7"))
    var req = _request(root)
    var runner = ScriptedRunner()
    runner.expect(_build(_argv(_A, _B), exit_code=Int32(2)))
    runner.expect(_build(_argv(_A)))
    runner.expect(_build(_argv(_B)))
    var o = _go(req, _argv("lib_a", "lib_b"), runner)
    assert_equal(o.outcome, String(OUTCOME_INDETERMINATE), o.message)
    assert_equal(o.error_id, String(ERROR_CANNOT_TELL))
    assert_equal(len(runner.calls), 3)
    assert_equal(runner.remaining(), 0)
    assert_equal(
        _first_line(o.message),
        String("BUILD step: batch 1 (`buck2 build //src/lib_a:lib_a_conda //src/lib_b:lib_b_conda` exit 2, stderr: ")
        + req.log_dir + String("/_batch_1.stderr) failed but each of its 2 unit(s) built alone: the units interfere")
        + String(" or the build is flaky; never a pass"),
    )
    assert_equal(_list(o.lines), String("[BUILT lib_a][BUILT lib_b]"))


def test_t8_a_timed_out_batch_is_not_split() raises:
    # no unit of it failed: time ran out, INDETERMINATE (komira#1153)
    var root = _fresh(String("t8"))
    var req = _request(root)
    var runner = ScriptedRunner()
    runner.expect(_build(_argv(_A, _B, _DOCS, _SHELL), timed_out=True))
    var o = _go(req, _argv("lib_a", "lib_b", "lints"), runner)
    assert_equal(o.outcome, String(OUTCOME_INDETERMINATE), o.message)
    assert_equal(o.error_id, String(ERROR_CANNOT_TELL))
    assert_equal(len(runner.calls), 1)
    assert_equal(runner.remaining(), 0)
    assert_equal(
        _first_line(o.message),
        String("BUILD step: batch 1 (3 unit(s): lib_a, lib_b, lints): `buck2 build //src/lib_a:lib_a_conda ")
        + String("//src/lib_b:lib_b_conda //:docs //:shell_lint` timed out (stderr: ") + req.log_dir
        + String("/_batch_1.stderr): no unit of it was attributed"),
    )
    assert_equal(len(o.lines), 0)


def test_t8_a_batch_killed_by_a_signal_is_not_split() raises:
    var root = _fresh(String("t8s"))
    var req = _request(root)
    var runner = ScriptedRunner()
    # exit 0 but killed by a signal: not a pass, not retried, no unit named
    var step = _build(_argv(_A, _B, _DOCS, _SHELL))
    step.result.signaled = True
    runner.expect(step^)
    var o = _go(req, _argv("lib_a", "lib_b", "lints"), runner)
    assert_equal(o.outcome, String(OUTCOME_FAILED), o.message)
    assert_equal(o.error_id, String(ERROR_BUILD_FAILED))
    assert_equal(len(runner.calls), 1)
    assert_equal(runner.remaining(), 0)
    var first = _first_line(o.message)
    assert_true(first.find(String("` killed by a signal (stderr: ")) >= 0, o.message)
    assert_true(first.find(String("no unit of it was attributed")) >= 0, o.message)
    assert_equal(len(o.lines), 0)


def test_t9_a_batch_that_cannot_start_names_every_unit() raises:
    var root = _fresh(String("t9"))
    var req = _request(root)
    var runner = ScriptedRunner()
    # lib_c alone (other's command) passes; then the batch cannot start
    runner.expect(_keep(_argv(_C)))
    var o = _go(req, _argv("lib_c", "lib_a", "lib_b", "lints"), runner)
    assert_equal(o.outcome, String(OUTCOME_INDETERMINATE), o.message)
    assert_equal(o.error_id, String(ERROR_CANNOT_TELL))
    assert_equal(len(runner.calls), 2)
    assert_equal(runner.remaining(), 0)
    assert_true(
        o.message.startswith(
            String("BUILD step: batch 1 (3 unit(s): lib_a, lib_b, lints): the build could not be started: ")
        ),
        o.message,
    )
    # the unit already proven keeps its line
    assert_equal(_list(o.lines), String("[BUILT lib_c]"))


def test_t9_a_batch_that_cannot_start_stops_the_step() raises:
    var root = _fresh(String("t9a"))
    var req = _request(root)
    var runner = ScriptedRunner()
    # the batch over lib_a, lib_b, lints cannot start; lib_c alone (a later
    # group, other's command) must never be started
    var o = _go(req, _argv("lib_a", "lib_b", "lints", "lib_c"), runner)
    assert_equal(o.outcome, String(OUTCOME_INDETERMINATE), o.message)
    assert_equal(o.error_id, String(ERROR_CANNOT_TELL))
    assert_equal(len(runner.calls), 1)
    assert_equal(runner.remaining(), 0)
    assert_true(
        o.message.startswith(
            String("BUILD step: batch 1 (3 unit(s): lib_a, lib_b, lints): the build could not be started: ")
        ),
        o.message,
    )
    assert_equal(len(o.lines), 0)


def test_t9_a_retry_that_cannot_start_stops_the_step() raises:
    var root = _fresh(String("t9b"))
    var req = _request(root)
    var runner = ScriptedRunner()
    # the batch fails, lib_a alone passes, lib_b alone cannot start: lints
    # must never be started
    runner.expect(_build(_argv(_A, _B, _DOCS, _SHELL), exit_code=Int32(1)))
    runner.expect(_build(_argv(_A)))
    var o = _go(req, _argv("lib_a", "lib_b", "lints"), runner)
    assert_equal(o.outcome, String(OUTCOME_INDETERMINATE), o.message)
    assert_equal(o.error_id, String(ERROR_CANNOT_TELL))
    assert_equal(len(runner.calls), 3)
    assert_equal(runner.remaining(), 0)
    assert_true(o.message.startswith(String("BUILD step: unit 'lib_b': the build could not be started: ")), o.message)
    assert_false(o.message.find(String("interfere")) >= 0, o.message)
    assert_equal(_list(o.lines), String("[BUILT lib_a]"))


def test_t9_a_run_that_cannot_start_outranks_a_failed_unit() raises:
    var root = _fresh(String("t9c"))
    var req = _request(root)
    var runner = ScriptedRunner()
    # the batch fails, lib_a alone fails (a failed unit is named), then
    # lib_b alone cannot start: the step cannot tell, it is not FAILED, and
    # lints is never started
    runner.expect(_build(_argv(_A, _B, _DOCS, _SHELL), exit_code=Int32(1)))
    runner.expect(_build(_argv(_A), exit_code=Int32(1), stderr=String("test_a FAILED")))
    var o = _go(req, _argv("lib_a", "lib_b", "lints"), runner)
    assert_equal(o.outcome, String(OUTCOME_INDETERMINATE), o.message)
    assert_equal(o.error_id, String(ERROR_CANNOT_TELL))
    assert_equal(len(runner.calls), 3)
    assert_equal(runner.remaining(), 0)
    assert_true(o.message.startswith(String("BUILD step: unit 'lib_b': the build could not be started: ")), o.message)
    # the failed unit's paragraph still follows
    assert_true(
        o.message.find(String("\nunit 'lib_a': `buck2 build //src/lib_a:lib_a_conda` exit 1 (stderr: ")) >= 0,
        o.message,
    )
    assert_true(o.message.find(String("test_a FAILED")) >= 0, o.message)
    assert_false(o.message.find(String("unit(s) failed:")) >= 0, o.message)
    assert_equal(len(o.lines), 0)


def test_t10_two_commands_two_batches_in_first_appearance_order() raises:
    var root = _fresh(String("t10"))
    var req = _request(root)
    var runner = ScriptedRunner()
    # buck2 and pack share `buck2 build`: one batch over lib_a, meta, lints
    runner.expect(_build(_argv(_A, _P, _DOCS, _SHELL), exit_code=Int32(1)))
    runner.expect(_build(_argv(_A), exit_code=Int32(1)))
    runner.expect(_build(_argv(_P)))
    runner.expect(_build(_argv(_DOCS, _SHELL)))
    runner.expect(_keep(_argv(_C, _D)))
    var o = _go(req, _argv("lib_a", "meta", "lib_c", "lib_d", "lints"), runner)
    assert_equal(o.outcome, String(OUTCOME_FAILED), o.message)
    assert_equal(o.error_id, String(ERROR_BUILD_FAILED))
    assert_equal(len(runner.calls), 5)
    assert_equal(runner.remaining(), 0)
    assert_equal(runner.calls[4].stdout_path, req.log_dir + String("/_batch_2.stdout"))
    assert_equal(_first_line(o.message), String("BUILD step: 1 of 5 unit(s) failed: lib_a"))
    assert_equal(_list(o.lines), String("[BUILT meta][BUILT lib_c][BUILT lib_d][BUILT lints]"))


def test_t11_after_the_cap_a_later_batch_is_not_retried() raises:
    for passes in range(2):
        var root = _fresh(String("t11_") + String(passes))
        var req = _request(root)
        var runner = ScriptedRunner()
        runner.expect(_build(_argv(_A, _B, _DOCS, _SHELL), exit_code=Int32(1)))
        runner.expect(_build(_argv(_A), exit_code=Int32(1)))
        runner.expect(_build(_argv(_B), exit_code=Int32(1)))
        runner.expect(_build(_argv(_DOCS, _SHELL), exit_code=Int32(1)))
        runner.expect(_keep(_argv(_C, _D), exit_code=Int32(0) if passes == 1 else Int32(2)))
        var o = _go(req, _argv("lib_a", "lib_b", "lints", "lib_c", "lib_d"), runner)
        assert_equal(o.outcome, String(OUTCOME_FAILED), o.message)
        assert_equal(o.error_id, String(ERROR_BUILD_FAILED))
        assert_equal(len(runner.calls), 5)
        assert_equal(runner.remaining(), 0)
        assert_equal(_first_line(o.message), String("BUILD step: 3 of 5 unit(s) failed: lib_a, lib_b, lints"))
        # every unit of batch 1 was tried and failed: no interference
        assert_false(o.message.find(String("interfere")) >= 0, o.message)
        if passes == 1:
            # a later batch that passes still proves its units
            assert_false(o.message.find(String("not attributed")) >= 0, o.message)
            assert_equal(_list(o.lines), String("[BUILT lib_c][BUILT lib_d]"))
        else:
            assert_true(
                o.message.find(String("\nbatch 2 (2 unit(s)): exit 2; not attributed: 3 failed units already named")) >= 0,
                o.message,
            )
            assert_true(o.message.find(String("\n2 unit(s) not tried after 3 failures: lib_c, lib_d")) >= 0, o.message)
            assert_equal(len(o.lines), 0)


def test_t12_the_batch_argv_file_holds_one_argument_per_line() raises:
    var root = _fresh(String("t12"))
    var req = _request(root)
    var runner = ScriptedRunner()
    runner.expect(_build(_argv(_A, _DOCS, _SHELL)))
    var o = _go(req, _argv("lib_a", "lints"), runner)
    assert_equal(o.outcome, String(OUTCOME_SUCCEEDED), o.message)
    assert_equal(o.error_id, String(""))
    assert_equal(len(runner.calls), 1)
    assert_equal(runner.remaining(), 0)
    assert_equal(
        Path(req.log_dir + String("/_batch_1.argv")).read_text(),
        String("buck2\nbuild\n//src/lib_a:lib_a_conda\n//:docs\n//:shell_lint\n"),
    )


def test_t14_a_timeout_and_interference_are_indeterminate_timeout_first() raises:
    # neither is a failure: INDETERMINATE, the timed-out batch's note first
    var root = _fresh(String("t14"))
    var req = _request(root)
    var runner = ScriptedRunner()
    runner.expect(_build(_argv(_A, _DOCS, _SHELL), exit_code=Int32(1)))
    runner.expect(_build(_argv(_A)))
    runner.expect(_build(_argv(_DOCS, _SHELL)))
    runner.expect(_keep(_argv(_C, _D), timed_out=True))
    var o = _go(req, _argv("lib_a", "lib_c", "lib_d", "lints"), runner)
    assert_equal(o.outcome, String(OUTCOME_INDETERMINATE), o.message)
    assert_equal(o.error_id, String(ERROR_CANNOT_TELL))
    assert_equal(len(runner.calls), 4)
    assert_equal(runner.remaining(), 0)
    assert_true(
        _first_line(o.message).startswith(String("BUILD step: batch 2 (2 unit(s): lib_c, lib_d): `buck2 build --keep-going ")),
        o.message,
    )
    assert_true(o.message.find(String("no unit of it was attributed")) >= 0, o.message)
    assert_true(o.message.find(String("the units interfere")) >= 0, o.message)
    assert_equal(_list(o.lines), String("[BUILT lib_a][BUILT lints]"))


def test_notices_come_before_the_built_lines() raises:
    var root = _fresh(String("notice"))
    var req = _request(root)
    var runner = ScriptedRunner()
    runner.expect(_build(_argv(_A)))
    var notices = _argv("NOTICE one")
    var o = build_affected_units(req, _arts(), _argv("lib_a"), String(_HEAD), notices, runner)
    assert_equal(o.outcome, String(OUTCOME_SUCCEEDED), o.message)
    assert_equal(o.error_id, String(""))
    assert_equal(len(runner.calls), 1)
    assert_equal(runner.remaining(), 0)
    assert_equal(runner.calls[0].stdout_path, req.log_dir + String("/lib_a.stdout"))
    assert_equal(_list(o.lines), String("[NOTICE one][BUILT lib_a]"))


# ---- a real fake build program ----------------------------------------------


def test_t13_a_real_build_program_failing_one_unit_of_a_batch() raises:
    var root = _fresh(String("t13"))
    var req = _request(root)
    write_text_file(
        root + String("/build.sh"),
        String("printf '%s\\n' \"$*\" >> ") + root + String("/built.log\n")
        + String("for a in \"$@\"; do\n  if [ \"$a\" = //src/lib_b:lint ]; then exit 1; fi\ndone\nexit 0\n"),
    )
    var text = (
        String("schema_version: 1\nbuild_systems {\n  name: \"buck2\"\n  executable: \"buck2\"\n  args: \"build\"\n")
        + String("  build_targets {\n    executable: \"/bin/sh\"\n    args: \"") + root + String("/build.sh\"\n  }\n}\n")
        + String("artifacts {\n  name: \"lib_b\"\n  build_system: \"buck2\"\n  args: \"{out_dir}\"\n")
        + String("  targets: \"//src/lib_b:lib_b_conda\"\n}\n")
        + String("checks {\n  name: \"lints\"\n  build_system: \"buck2\"\n  targets: \"//docs:docs\"\n")
        + String("  targets: \"//src/lib_b:lint\"\n}\n")
    )
    var runner = SupervisorRunner()
    var o = build_affected_units(req, _arts(text), _argv("lib_b", "lints"), String(_HEAD), List[String](), runner)
    assert_equal(o.outcome, String(OUTCOME_FAILED), o.message)
    assert_equal(o.error_id, String(ERROR_BUILD_FAILED))
    assert_equal(
        Path(root + String("/built.log")).read_text(),
        String("//src/lib_b:lib_b_conda //docs:docs //src/lib_b:lint\n//src/lib_b:lib_b_conda\n//docs:docs //src/lib_b:lint\n"),
    )
    assert_equal(_first_line(o.message), String("BUILD step: 1 of 2 unit(s) failed: lints"))
    assert_equal(_list(o.lines), String("[BUILT lib_b]"))


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
