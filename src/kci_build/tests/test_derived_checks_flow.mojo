# =============================================================================
# src/kci_build/tests/test_derived_checks_flow.mojo
#   The per-change check's DERIVED checks over ScriptedRunner: the
#   derive_checks command runs before any affected command, with every
#   declared unit in its units file; the checks it answers join the units
#   (the affected command sees them, their targets follow the declared
#   units' in the one batch run);
#   a declared check target matching nothing is a NOTICE, never a stop; an
#   artifact target matching nothing, and a derived name a declared unit
#   has, are REFUSED; a failing or garbled tool is INDETERMINATE; a tool
#   answering BROKEN (its query of the build graph failed) FAILS the check.
# =============================================================================

from std.ffi import external_call
from std.os import getenv, makedirs
from std.os.path import realpath
from std.pathlib import Path

from std.testing import TestSuite, assert_equal, assert_true

from kci_api import (
    ERROR_AFFECTED,
    ERROR_ARTIFACT,
    ERROR_BUILD_FAILED,
    OUTCOME_FAILED,
    OUTCOME_INDETERMINATE,
    OUTCOME_REFUSED,
    OUTCOME_SUCCEEDED,
    MemoryRecorder,
    RunIdentity,
)
from kci_api import RunResult as KciRunResult
from kci_build import BuildOutcome, BuildRequest, ScriptedRunner, ScriptedStep, run_build, write_text_file

comptime _REV = "a1b2c3d4e5f60718293a4b5c6d7e8f9012345678"
comptime _BASE = "0123456789abcdef0123456789abcdef01234567"

comptime _FILE = """schema_version: 1
build_systems {
  name: "buck2"
  executable: "buck2"
  args: "build"
  affected {
    executable: "/opt/fake/affected"
    args: "{changed_files}"
    args: "{units_file}"
  }
  build_targets {
    executable: "buck2"
    args: "build"
  }
  derive_checks {
    executable: "/opt/fake/derive"
    args: "{units_file}"
  }
}
artifacts {
  name: "lib_a"
  build_system: "buck2"
  args: "//src/lib_a:lib_a_conda[release]"
  args: "--out"
  args: "{out_dir}"
  targets: "//src/lib_a:lib_a_conda"
}
checks {
  name: "lints"
  build_system: "buck2"
  targets: "//:docs"
  targets: "//gone/..."
}
"""


def _fresh(tag: String) raises -> String:
    var base = getenv("TEST_TMPDIR")
    if base.byte_length() == 0:
        base = getenv("TMPDIR")
    if base.byte_length() == 0:
        raise Error("neither TEST_TMPDIR nor TMPDIR is set")
    var d = base + String("/kd_") + tag + String("_") + String(Int(external_call["getpid", Int32]()))
    makedirs(d + String("/repo"), exist_ok=True)
    return realpath(d)


def _request(root: String, plan: Bool = False) raises -> BuildRequest:
    var r = BuildRequest(RunIdentity(String("gh-9"), 1))
    r.artifacts_file = root + String("/artifacts.textproto")
    write_text_file(r.artifacts_file, String(_FILE))
    r.work_dir = root + String("/repo")
    r.release_dir = root + String("/release")
    r.log_dir = root + String("/logs")
    r.revision_id = String(_REV)
    r.affected_by = String(_BASE)
    r.platform = String("linux-x86_64")
    r.build_timeout_s = 77
    r.step_name = String("check")
    r.plan = plan
    return r^


def _argv(*xs: String) -> List[String]:
    var out = List[String]()
    for x in xs:
        out.append(String(x))
    return out^


def _git() -> ScriptedRunner:
    var g = ScriptedRunner()
    g.expect(ScriptedStep(_argv("rev-parse", "--is-shallow-repository"), stdout_text=String("false\n")))
    g.expect(ScriptedStep(_argv("rev-parse", "--verify", "HEAD"), stdout_text=String(_REV) + String("\n")))
    g.expect(ScriptedStep(_argv("status", "--porcelain", "--untracked-files=no")))
    g.expect(
        ScriptedStep(
            _argv("diff", "-z", "--name-only", "--no-renames", String(_BASE) + String("...") + String(_REV)),
            stdout_text=String("src/new_pkg/x.mojo") + chr(0),
        )
    )
    return g^


def _derive(req: BuildRequest, answer: String, exit_code: Int32 = Int32(0)) -> ScriptedStep:
    return ScriptedStep(_argv(req.log_dir + String("/_declared_units.tsv")), exit_code=exit_code, stdout_text=answer)


def _ask(req: BuildRequest, answer: String) -> ScriptedStep:
    return ScriptedStep(
        _argv(req.log_dir + String("/_changed_files"), req.log_dir + String("/_units_buck2.tsv")), stdout_text=answer
    )


def _build(*targets: String) -> ScriptedStep:
    var a = _argv("build")
    for t in targets:
        a.append(String(t))
    return ScriptedStep(a^)


def _run(req: BuildRequest, mut runner: ScriptedRunner, mut result: KciRunResult) -> BuildOutcome:
    var rec = MemoryRecorder()
    var git = _git()
    return run_build(req, result, rec, runner, git)


def _list(xs: List[String]) -> String:
    var s = String("")
    for i in range(len(xs)):
        s += String("[") + xs[i] + String("]")
    return s^


comptime _DERIVED = "CHECK new_pkg //src/new_pkg/...\nCHECK repo_root //:\nCHECK new_pkg //src/new_pkg:\nDERIVED 2\n"


def test_the_derived_checks_are_selected_and_built_after_the_declared_units() raises:
    var root = _fresh(String("built"))
    var req = _request(root)
    var runner = ScriptedRunner()
    runner.expect(_derive(req, String(_DERIVED)))
    runner.expect(_ask(req, String("WIDENED every unit\n")))
    # the declared units, then the derived checks, in one batch
    runner.expect(_build("//src/lib_a:lib_a_conda", "//:docs", "//gone/...", "//src/new_pkg/...", "//src/new_pkg:", "//:"))
    var result = KciRunResult(String("run"), String("run"))
    var o = _run(req, runner, result)
    assert_equal(o.outcome, String(OUTCOME_SUCCEEDED), o.message)
    assert_equal(runner.remaining(), 0)
    assert_equal(len(runner.calls), 3)
    # the derive command ran first, from the work dir, with the declared units
    assert_equal(runner.calls[0].path, String("/opt/fake/derive"))
    assert_equal(runner.calls[0].cwd, req.work_dir)
    assert_equal(
        Path(req.log_dir + String("/_declared_units.tsv")).read_text(),
        String("lib_a\t//src/lib_a:lib_a_conda\nlints\t//:docs\nlints\t//gone/...\n"),
    )
    # the affected command sees the derived checks as units of buck2
    assert_equal(
        Path(req.log_dir + String("/_units_buck2.tsv")).read_text(),
        String("lib_a\t//src/lib_a:lib_a_conda\nlints\t//:docs\nlints\t//gone/...\n")
        + String("new_pkg\t//src/new_pkg/...\nnew_pkg\t//src/new_pkg:\nrepo_root\t//:\n"),
    )
    assert_equal(_list(result.affected_units), String("[lib_a][lints][new_pkg][repo_root]"))
    assert_equal(_list(o.lines), String("[BUILT lib_a][BUILT lints][BUILT new_pkg][BUILT repo_root]"))


def test_an_affected_answer_may_name_a_derived_check() raises:
    var root = _fresh(String("named"))
    var req = _request(root)
    var runner = ScriptedRunner()
    runner.expect(_derive(req, String(_DERIVED)))
    runner.expect(_ask(req, String("UNIT new_pkg\nAFFECTED 1\n")))
    runner.expect(_build("//src/new_pkg/...", "//src/new_pkg:"))
    var result = KciRunResult(String("run"), String("run"))
    var o = _run(req, runner, result)
    assert_equal(o.outcome, String(OUTCOME_SUCCEEDED), o.message)
    assert_equal(runner.remaining(), 0)
    assert_equal(len(runner.calls), 3)
    assert_equal(runner.calls[2].stdout_path, req.log_dir + String("/new_pkg.stdout"))
    assert_equal(_list(o.lines), String("[BUILT new_pkg]"))


def test_a_check_target_matching_nothing_is_a_notice() raises:
    var root = _fresh(String("notice"))
    var req = _request(root, plan=True)
    var runner = ScriptedRunner()
    runner.expect(_derive(req, String("UNMATCHED lints //gone/...\n") + String(_DERIVED)))
    runner.expect(_ask(req, String("WIDENED every unit\n")))
    var result = KciRunResult(String("run"), String("run"))
    var o = _run(req, runner, result)
    assert_equal(o.outcome, String(OUTCOME_SUCCEEDED), o.message)
    assert_equal(len(runner.calls), 2)
    assert_equal(
        _list(o.lines),
        String("[NOTICE check 'lints' names `//gone/...`, which matches nothing in the build graph]")
        + String("[WOULD_BUILD lib_a][WOULD_BUILD lints][WOULD_BUILD new_pkg][WOULD_BUILD repo_root]"),
    )


def test_an_artifact_target_matching_nothing_is_refused() raises:
    var root = _fresh(String("artifact"))
    var req = _request(root)
    var runner = ScriptedRunner()
    runner.expect(_derive(req, String("UNMATCHED lib_a //src/lib_a:lib_a_conda\nDERIVED 0\n")))
    var result = KciRunResult(String("run"), String("run"))
    var o = _run(req, runner, result)
    assert_equal(o.outcome, String(OUTCOME_REFUSED), o.message)
    assert_equal(o.error_id, String(ERROR_ARTIFACT))
    assert_true(o.message.find(String("the build graph holds no target an artifact names: `lib_a //src/lib_a:lib_a_conda`")) >= 0, o.message)
    assert_equal(len(runner.calls), 1)


def test_a_derived_name_a_declared_unit_has_is_refused() raises:
    var root = _fresh(String("clash"))
    var req = _request(root)
    var runner = ScriptedRunner()
    runner.expect(_derive(req, String("CHECK lints //src/x/...\nDERIVED 1\n")))
    var result = KciRunResult(String("run"), String("run"))
    var o = _run(req, runner, result)
    assert_equal(o.outcome, String(OUTCOME_REFUSED), o.message)
    assert_equal(o.error_id, String(ERROR_ARTIFACT))
    assert_true(o.message.find(String("check 'lints' is declared twice")) >= 0, o.message)
    assert_equal(len(runner.calls), 1)


def test_a_failing_or_garbled_derive_tool_is_cannot_tell() raises:
    for k in range(2):
        var root = _fresh(String("fail") + String(k))
        var req = _request(root)
        var runner = ScriptedRunner()
        if k == 0:
            runner.expect(_derive(req, String(""), exit_code=Int32(3)))
        else:
            runner.expect(_derive(req, String("CHECK a //x/...\n")))
        var result = KciRunResult(String("run"), String("run"))
        var o = _run(req, runner, result)
        assert_equal(o.outcome, String(OUTCOME_INDETERMINATE), o.message)
        assert_equal(o.error_id, String(ERROR_AFFECTED))
        assert_true(o.message.find(String("kci cannot tell which checks the build graph holds")) >= 0, o.message)
        assert_equal(len(runner.calls), 1)


def test_a_broken_derive_answer_fails_the_check() raises:
    # release/ci/derive_checks.py answers BROKEN when its universe query
    # fails (a target with an unknown dependency, here buck2's own text):
    # the check is FAILED naming the reason, not "cannot tell" and never a
    # widening; no affected command runs and nothing is built. A kci that
    # read BROKEN as outside the grammar would answer INDETERMINATE.
    var root = _fresh(String("broken"))
    var req = _request(root)
    var runner = ScriptedRunner()
    var why = String("the universe query `buck2 cquery //... + tests//functional/...` failed, naming ")
    why += String("komira//tools/build/ci:planted_unknown: Unknown target `no_such_target_here`")
    runner.expect(_derive(req, String("BROKEN ") + why + String("\n")))
    var result = KciRunResult(String("run"), String("run"))
    var o = _run(req, runner, result)
    assert_equal(o.outcome, String(OUTCOME_FAILED), o.message)
    assert_equal(o.error_id, String(ERROR_BUILD_FAILED), o.message)
    assert_equal(len(runner.calls), 1)
    assert_true(o.message.find(String("answered BROKEN: ") + why) >= 0, o.message)


def test_the_derive_command_is_held_to_the_build_budget() raises:
    # with 40 s left of --build-budget-s the derive command gets 40, not its
    # --build-timeout-s; with none left it is not started (cannot tell)
    var root = _fresh(String("budget"))
    var req = _request(root)
    req.build_budget_s = 100
    req.build_deadline_ns = 40 * 1_000_000_000
    var runner = ScriptedRunner()
    runner.expect(_derive(req, String(""), exit_code=Int32(3)))
    var result = KciRunResult(String("run"), String("run"))
    var o = _run(req, runner, result)
    assert_equal(len(runner.calls), 1)
    assert_equal(runner.calls[0].timeout_s, 40)
    assert_equal(o.error_id, String(ERROR_AFFECTED))
    var root2 = _fresh(String("nobudget"))
    var req2 = _request(root2)
    req2.build_budget_s = 100
    req2.build_deadline_ns = 0
    var none = ScriptedRunner()
    var result2 = KciRunResult(String("run"), String("run"))
    var o2 = _run(req2, none, result2)
    assert_equal(o2.outcome, String(OUTCOME_INDETERMINATE), o2.message)
    assert_equal(o2.error_id, String(ERROR_AFFECTED))
    assert_equal(len(none.calls), 0)
    assert_true(
        o2.message.find(String("was not started: the build budget (--build-budget-s 100) was spent")) >= 0, o2.message
    )
    assert_true(o2.message.find(String("kci cannot tell which checks the build graph holds")) >= 0, o2.message)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
