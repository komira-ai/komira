# =============================================================================
# src/kci_build/tests/test_affected_flow.mojo
#   The per-change check (`--affected-by`) over ScriptedRunner: the change
#   read through git (argv, no shell), each build system's affected command
#   run with a golden argv and fed the changed-files and units files, exactly
#   the reached units built in unit order (welded tests ride in each build;
#   one batch run, both build systems sharing one build_targets command),
#   every unit built when an answer is WIDENED (a build file, the buckconfig,
#   a toolchain, a tools/build file, an unmapped file), and each stop: an
#   empty change and a change reaching nothing REFUSED, a failing or
#   garbled tool INDETERMINATE (never a widening), a BROKEN answer (a target
#   the build system cannot configure) FAILED, a failed batch FAILED
#   naming the failed unit (affected_batch.mojo; test_affected_batch.mojo
#   holds every batch case), a
#   file without what the check needs refused before anything runs; --plan
#   builds nothing; a release build of the same file ignores the checks; and
#   the affected commands are charged to --build-budget-s and not started
#   when none is left.
# =============================================================================
#
# The fake affected command is a ScriptedStep: kci's half of the protocol is
# what this file proves (what it hands the tool, how it reads the answer,
# what it builds). Which files widen is the tool's, so each WIDENED case
# hands the tool a different changed file and asserts the tool SAW it. Two
# more cases run a REAL fake executable (a /bin/sh script reading the two
# files kci hands it) through SupervisorRunner, and a fake build program that
# records the targets it was asked to build.
# =============================================================================

from std.ffi import external_call
from std.os import getenv, listdir, makedirs
from std.os.path import exists, realpath
from std.pathlib import Path

from std.testing import TestSuite, assert_equal, assert_false, assert_true

from kci_api import (
    ERROR_AFFECTED,
    ERROR_AFFECTED_VACUOUS,
    ERROR_ARTIFACT,
    ERROR_BUILD_FAILED,
    ERROR_REVISION,
    EXIT_CANNOT_TELL,
    EXIT_FAILED,
    EXIT_OK,
    EXIT_REFUSED,
    OUTCOME_FAILED,
    OUTCOME_INDETERMINATE,
    OUTCOME_REFUSED,
    OUTCOME_SUCCEEDED,
    MemoryRecorder,
    RunIdentity,
)
from kci_api import RunResult as KciRunResult
from kci_build import (
    BuildOutcome,
    BuildRequest,
    ScriptedRunner,
    ScriptedStep,
    SupervisorRunner,
    run_build,
    write_text_file,
)

comptime _REV = "a1b2c3d4e5f60718293a4b5c6d7e8f9012345678"
comptime _BASE = "0123456789abcdef0123456789abcdef01234567"
comptime _SRC = "f0e1d2c3b4a5968778695a4b3c2d1e0f12345678"
comptime _TOOL = "/opt/fake/affected"

# Two build systems owning five units: three artifacts (two libraries and a
# metapackage by the packer) and two checks.
comptime _FILE = """schema_version: 1
build_systems {
  name: "buck2"
  executable: "buck2"
  args: "build"
  args: "-c"
  args: "komira.package_stamp={build_number}"
  affected {
    executable: "/opt/fake/affected"
    args: "--changed-files={changed_files}"
    args: "--units-file={units_file}"
    args: "--base={base_commit}"
    args: "--head={revision_id}"
  }
  build_targets {
    executable: "buck2"
    args: "build"
  }
}
build_systems {
  name: "pack"
  executable: "buck2"
  args: "run"
  args: "//tools/pack:pack"
  args: "--"
  affected {
    executable: "/opt/fake/affected"
    args: "--changed-files={changed_files}"
    args: "--units-file={units_file}"
  }
  build_targets {
    executable: "buck2"
    args: "build"
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
artifacts {
  name: "lib_b"
  build_system: "buck2"
  args: "//src/lib_b:lib_b_conda[release]"
  args: "--out"
  args: "{out_dir}"
  targets: "//src/lib_b:lib_b_conda"
}
artifacts {
  name: "meta"
  build_system: "pack"
  args: "--out-dir={out_dir}"
  targets: "//tools/pack:pack"
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
"""


def _fresh(tag: String) raises -> String:
    var base = getenv("TEST_TMPDIR")
    if base.byte_length() == 0:
        base = getenv("TMPDIR")
    if base.byte_length() == 0:
        raise Error("neither TEST_TMPDIR nor TMPDIR is set")
    var d = base + String("/ka_") + tag + String("_") + String(Int(external_call["getpid", Int32]()))
    makedirs(d + String("/repo"), exist_ok=True)
    return realpath(d)


def _request(root: String, text: String = String(_FILE)) raises -> BuildRequest:
    var r = BuildRequest(RunIdentity(String("gh-9"), 1))
    r.artifacts_file = root + String("/artifacts.textproto")
    write_text_file(r.artifacts_file, text)
    r.work_dir = root + String("/repo")
    r.release_dir = root + String("/release")
    r.log_dir = root + String("/logs")
    r.revision_id = String(_REV)
    r.affected_by = String(_BASE)
    r.platform = String("linux-x86_64")
    r.build_timeout_s = 77
    r.step_name = String("check")
    return r^


def _argv(*xs: String) -> List[String]:
    var out = List[String]()
    for x in xs:
        out.append(String(x))
    return out^


def _z(*paths: String) -> String:
    """Paths as `git diff -z` prints them: each followed by a NUL."""
    var s = String("")
    for p in paths:
        s += String(p) + chr(0)
    return s^


def _git(diff: String, diff_exit: Int32 = Int32(0), diff_stderr: String = String("")) -> ScriptedRunner:
    """A clean, full-history checkout of _REV, then the diff."""
    var g = ScriptedRunner()
    g.expect(ScriptedStep(_argv("rev-parse", "--is-shallow-repository"), stdout_text=String("false\n")))
    g.expect(ScriptedStep(_argv("rev-parse", "--verify", "HEAD"), stdout_text=String(_REV) + String("\n")))
    g.expect(ScriptedStep(_argv("status", "--porcelain", "--untracked-files=no")))
    g.expect(
        ScriptedStep(
            _argv("diff", "-z", "--name-only", "--no-renames", String(_BASE) + String("...") + String(_REV)),
            exit_code=diff_exit,
            stdout_text=diff,
            stderr_text=diff_stderr,
        )
    )
    return g^


def _ask_buck2(
    req: BuildRequest, answer: String, exit_code: Int32 = Int32(0), timed_out: Bool = False, took_s: Int = 0
) -> ScriptedStep:
    return ScriptedStep(
        _argv(
            String("--changed-files=") + req.log_dir + String("/_changed_files"),
            String("--units-file=") + req.log_dir + String("/_units_buck2.tsv"),
            String("--base=") + String(_BASE),
            String("--head=") + String(_REV),
        ),
        exit_code=exit_code,
        stdout_text=answer,
        timed_out=timed_out,
        elapsed_s=took_s,
    )


def _ask_pack(req: BuildRequest, answer: String, took_s: Int = 0) -> ScriptedStep:
    return ScriptedStep(
        _argv(
            String("--changed-files=") + req.log_dir + String("/_changed_files"),
            String("--units-file=") + req.log_dir + String("/_units_pack.tsv"),
        ),
        stdout_text=answer,
        elapsed_s=took_s,
    )


def _build(*targets: String) -> ScriptedStep:
    var a = _argv("build")
    for t in targets:
        a.append(String(t))
    return ScriptedStep(a^)


def _run(req: BuildRequest, mut runner: ScriptedRunner, mut git: ScriptedRunner, mut result: KciRunResult) -> BuildOutcome:
    var rec = MemoryRecorder()
    return run_build(req, result, rec, runner, git)


def _fresh_result() -> KciRunResult:
    return KciRunResult(String("run"), String("run"))


def _list(xs: List[String]) -> String:
    var s = String("")
    for i in range(len(xs)):
        s += String("[") + xs[i] + String("]")
    return s^


# ---- the build budget reaches the affected commands -------------------------


def test_the_affected_commands_are_charged_to_the_budget() raises:
    # --build-budget-s 100 (deadline at clock 100 s): the buck2 answer gets
    # all 100 (--build-timeout-s 77 caps nothing under a budget) and takes
    # 30 s, so the pack command gets the 70 left and, after its 40 s, the
    # build gets the 30 s left
    var root = _fresh(String("budget"))
    var req = _request(root)
    req.build_budget_s = 100
    req.build_deadline_ns = 100 * 1_000_000_000
    var git = _git(_z("src/lib_a/a.mojo"))
    var runner = ScriptedRunner()
    runner.expect(_ask_buck2(req, String("UNIT lib_a\nAFFECTED 1\n"), took_s=30))
    runner.expect(_ask_pack(req, String("AFFECTED 0\n"), took_s=40))
    runner.expect(_build("//src/lib_a:lib_a_conda"))
    var result = _fresh_result()
    var o = _run(req, runner, git, result)
    assert_equal(o.outcome, String(OUTCOME_SUCCEEDED), o.message)
    assert_equal(len(runner.calls), 3)
    assert_equal(runner.remaining(), 0)
    assert_equal(runner.calls[0].timeout_s, 100)
    assert_equal(runner.calls[1].timeout_s, 70)
    assert_equal(runner.calls[2].timeout_s, 30)


def test_an_affected_command_with_no_budget_left_is_not_started() raises:
    # the buck2 answer spends the whole budget: the pack command is not
    # started, and kci cannot tell what the change reaches (never a pass)
    var root = _fresh(String("nobudget"))
    var req = _request(root)
    req.build_budget_s = 100
    req.build_deadline_ns = 100 * 1_000_000_000
    var git = _git(_z("src/lib_a/a.mojo"))
    var runner = ScriptedRunner()
    runner.expect(_ask_buck2(req, String("UNIT lib_a\nAFFECTED 1\n"), took_s=100))
    var result = _fresh_result()
    var o = _run(req, runner, git, result)
    assert_equal(o.outcome, String(OUTCOME_INDETERMINATE), o.message)
    assert_equal(o.error_id, String(ERROR_AFFECTED))
    assert_equal(len(runner.calls), 1)
    assert_equal(runner.remaining(), 0)
    assert_true(
        o.message.find(String("was not started: the build budget (--build-budget-s 100) was spent")) >= 0, o.message
    )


# ---- exactly the reached units ----------------------------------------------


def test_affected_selection_builds_exactly_the_reached_units() raises:
    var root = _fresh(String("select"))
    var req = _request(root)
    var git = _git(_z("src/lib_a/a.mojo", "docs/guide.md"))
    var runner = ScriptedRunner()
    # the tool answers in its own order; kci builds in unit order
    runner.expect(_ask_buck2(req, String("UNIT lints\nUNIT lib_a\nAFFECTED 2\n")))
    runner.expect(_ask_pack(req, String("AFFECTED 0\n")))
    runner.expect(_build("//src/lib_a:lib_a_conda", "//:docs", "//:shell_lint"))
    var result = _fresh_result()
    var o = _run(req, runner, git, result)
    assert_equal(o.outcome, String(OUTCOME_SUCCEEDED), o.message)
    assert_equal(o.exit_code(), EXIT_OK)
    assert_equal(runner.remaining(), 0)
    assert_equal(len(runner.calls), 3)
    assert_equal(git.remaining(), 0)
    # the affected command: golden program, cwd, timeout, files it was handed
    ref ask = runner.calls[0]
    assert_equal(ask.path, String(_TOOL))
    assert_equal(ask.cwd, req.work_dir)
    assert_equal(ask.timeout_s, 77)
    assert_equal(Path(req.log_dir + String("/_changed_files")).read_text(), _z("src/lib_a/a.mojo", "docs/guide.md"))
    assert_equal(
        Path(req.log_dir + String("/_units_buck2.tsv")).read_text(),
        String("lib_a\t//src/lib_a:lib_a_conda\nlib_b\t//src/lib_b:lib_b_conda\nlints\t//:docs\n")
        + String("lints\t//:shell_lint\ntests_cell\ttests//functional/...\n"),
    )
    assert_equal(Path(req.log_dir + String("/_units_pack.tsv")).read_text(), String("meta\t//tools/pack:pack\n"))
    # the build: build_targets + the units' targets in one batch, never the
    # release argv
    assert_equal(runner.calls[2].path, String("buck2"))
    assert_equal(runner.calls[2].stdout_path, req.log_dir + String("/_batch_1.stdout"))
    assert_equal(runner.calls[2].stderr_path, req.log_dir + String("/_batch_1.stderr"))
    # the git commands are argv, never a shell
    assert_equal(git.calls[3].path, String("git"))
    # nothing ships: no release directory, no release.json
    assert_false(exists(req.release_dir))
    assert_equal(_list(o.lines), String("[BUILT lib_a][BUILT lints]"))
    assert_true(result.has_affected_by)
    assert_equal(result.affected_base, String(_BASE))
    assert_equal(result.affected_verdict, String("AFFECTED"))
    assert_equal(result.affected_reason, String(""))
    assert_equal(_list(result.affected_units), String("[lib_a][lints]"))
    assert_equal(len(result.steps), 1)
    assert_equal(result.steps[0].outcome, String(OUTCOME_SUCCEEDED))
    assert_equal(len(result.artifacts), 0)


def test_two_build_systems_answers_are_united() raises:
    var root = _fresh(String("unite"))
    var req = _request(root)
    var git = _git(_z("tools/pack/pack.mojo", "src/lib_b/b.mojo"))
    var runner = ScriptedRunner()
    runner.expect(_ask_buck2(req, String("UNIT lib_b\nAFFECTED 1\n")))
    runner.expect(_ask_pack(req, String("UNIT meta\nAFFECTED 1\n")))
    # two build systems, one build_targets command: one batch
    runner.expect(_build("//src/lib_b:lib_b_conda", "//tools/pack:pack"))
    var result = _fresh_result()
    var o = _run(req, runner, git, result)
    assert_equal(o.outcome, String(OUTCOME_SUCCEEDED), o.message)
    assert_equal(runner.remaining(), 0)
    assert_equal(len(runner.calls), 3)
    assert_equal(_list(o.lines), String("[BUILT lib_b][BUILT meta]"))
    assert_equal(_list(result.affected_units), String("[lib_b][meta]"))


# ---- widening ----------------------------------------------------------------


def _widened_case(tag: String, changed: String, reason: String) raises:
    var root = _fresh(tag)
    var req = _request(root)
    var git = _git(_z(changed))
    var runner = ScriptedRunner()
    runner.expect(_ask_buck2(req, String("WIDENED ") + reason + String("\n")))
    runner.expect(_ask_pack(req, String("AFFECTED 0\n")))
    runner.expect(
        _build(
            "//src/lib_a:lib_a_conda", "//src/lib_b:lib_b_conda", "//tools/pack:pack", "//:docs", "//:shell_lint",
            "tests//functional/...",
        )
    )
    var result = _fresh_result()
    var o = _run(req, runner, git, result)
    assert_equal(o.outcome, String(OUTCOME_SUCCEEDED), o.message)
    assert_equal(runner.remaining(), 0, tag)
    assert_equal(len(runner.calls), 3, tag)
    # the tool saw exactly the changed file
    assert_equal(Path(req.log_dir + String("/_changed_files")).read_text(), _z(changed))
    assert_equal(result.affected_verdict, String("WIDENED"))
    assert_equal(result.affected_reason, String("buck2: ") + reason)
    assert_equal(_list(result.affected_units), String("[lib_a][lib_b][meta][lints][tests_cell]"))
    assert_equal(
        _list(o.lines), String("[BUILT lib_a][BUILT lib_b][BUILT meta][BUILT lints][BUILT tests_cell]")
    )


def test_a_build_file_change_widens_to_every_unit() raises:
    _widened_case(String("bzl"), String("tools/build/mojo/defs.bzl"), String("tools/build/mojo/defs.bzl is a build file"))


def test_a_buckconfig_change_widens_to_every_unit() raises:
    _widened_case(String("bcfg"), String(".buckconfig"), String(".buckconfig configures every target"))


def test_a_toolchain_change_widens_to_every_unit() raises:
    _widened_case(
        String("tc"), String("tools/build/cells/toolchains/BUCK"), String("a toolchain changed")
    )


def test_a_tools_build_change_widens_to_every_unit() raises:
    _widened_case(String("tb"), String("tools/build/package/release_version.sh"), String("tools/build changed"))


def test_an_unmapped_file_widens_to_every_unit() raises:
    _widened_case(String("unmapped"), String("third_party/zlib/LICENSE"), String("no target owns third_party/zlib/LICENSE"))


# ---- refusals ----------------------------------------------------------------


def test_a_change_reaching_no_unit_is_refused() raises:
    var root = _fresh(String("vacuous"))
    var req = _request(root)
    var git = _git(_z("README.md"))
    var runner = ScriptedRunner()
    runner.expect(_ask_buck2(req, String("AFFECTED 0\n")))
    runner.expect(_ask_pack(req, String("AFFECTED 0\n")))
    var result = _fresh_result()
    var o = _run(req, runner, git, result)
    assert_equal(o.outcome, String(OUTCOME_REFUSED))
    assert_equal(o.error_id, String(ERROR_AFFECTED_VACUOUS))
    assert_equal(o.exit_code(), EXIT_REFUSED)
    assert_equal(runner.remaining(), 0)
    assert_equal(len(runner.calls), 2)
    assert_true(o.message.find(String("touches 1 file(s) and reaches no declared unit")) >= 0, o.message)
    assert_equal(result.error.id, String(ERROR_AFFECTED_VACUOUS))
    assert_equal(result.affected_verdict, String("AFFECTED"))
    assert_equal(len(result.affected_units), 0)


def test_an_empty_change_is_refused_before_any_tool_runs() raises:
    var root = _fresh(String("empty"))
    var req = _request(root)
    var git = _git(String(""))
    var runner = ScriptedRunner()
    var result = _fresh_result()
    var o = _run(req, runner, git, result)
    assert_equal(o.error_id, String(ERROR_AFFECTED_VACUOUS))
    assert_equal(o.exit_code(), EXIT_REFUSED)
    assert_equal(len(runner.calls), 0)
    assert_equal(
        o.message,
        String("BUILD step: --affected-by: the change ") + String(_BASE) + String("...") + String(_REV)
        + String(" touches no file: a check over nothing is never a pass"),
    )


def _cannot_tell_case(tag: String, answer: String, want: String, exit_code: Int32 = Int32(0), timed_out: Bool = False) raises:
    var root = _fresh(tag)
    var req = _request(root)
    var git = _git(_z("src/lib_a/a.mojo"))
    var runner = ScriptedRunner()
    runner.expect(_ask_buck2(req, answer, exit_code=exit_code, timed_out=timed_out))
    var result = _fresh_result()
    var o = _run(req, runner, git, result)
    assert_equal(o.outcome, String(OUTCOME_INDETERMINATE), tag)
    assert_equal(o.error_id, String(ERROR_AFFECTED), tag)
    assert_equal(o.exit_code(), EXIT_CANNOT_TELL, tag)
    # never a widening: nothing was built, no verdict recorded
    assert_equal(len(runner.calls), 1, tag)
    assert_equal(runner.remaining(), 0, tag)
    assert_equal(result.affected_verdict, String(""), tag)
    assert_true(o.message.find(want) >= 0, o.message)
    assert_true(o.message.find(String("does not widen instead")) >= 0, o.message)


def test_a_failing_tool_is_cannot_tell_never_a_widening() raises:
    _cannot_tell_case(String("exit"), String("WIDENED x\n"), String("`, exit 1 (stderr: "), exit_code=Int32(1))
    _cannot_tell_case(String("timeout"), String(""), String("`, timed out (stderr: "), timed_out=True)
    _cannot_tell_case(String("garbled"), String("lib_a\n"), String("answered outside the protocol: line 1 'lib_a'"))
    _cannot_tell_case(
        String("foreign"), String("UNIT meta\nAFFECTED 1\n"), String("'meta' is not a unit this build system owns")
    )


def test_a_broken_answer_fails_the_check_and_builds_nothing() raises:
    # BROKEN: the build system cannot configure a target of its graph (an
    # unknown or invisible dependency). The check is FAILED, naming what the
    # tool said, never a widening and never "cannot tell"; nothing is built
    # and the next build system is not asked.
    var root = _fresh(String("broken"))
    var req = _request(root)
    var git = _git(_z("src/lib_a/a.mojo"))
    var runner = ScriptedRunner()
    var why = String("the universe holds a target buck2 cannot configure: tests//p:t: `x` is not visible to `tests//p:t`")
    runner.expect(_ask_buck2(req, String("BROKEN ") + why + String("\n")))
    var result = _fresh_result()
    var o = _run(req, runner, git, result)
    assert_equal(o.outcome, String(OUTCOME_FAILED), o.message)
    assert_equal(o.error_id, String(ERROR_BUILD_FAILED), o.message)
    assert_equal(o.exit_code(), EXIT_FAILED, o.message)
    assert_equal(len(runner.calls), 1)
    assert_equal(runner.remaining(), 0)
    assert_equal(result.affected_verdict, String(""))
    assert_true(o.message.find(String("build system 'buck2' answered BROKEN: ") + why) >= 0, o.message)


def test_a_failed_batch_names_the_failed_unit() raises:
    var root = _fresh(String("fail"))
    var req = _request(root)
    var git = _git(_z("src/lib_a/a.mojo"))
    var runner = ScriptedRunner()
    runner.expect(_ask_buck2(req, String("UNIT lib_a\nUNIT lints\nAFFECTED 2\n")))
    runner.expect(_ask_pack(req, String("AFFECTED 0\n")))
    # the batch fails; each unit alone names the failing one
    runner.expect(
        ScriptedStep(
            _argv("build", "//src/lib_a:lib_a_conda", "//:docs", "//:shell_lint"),
            exit_code=Int32(3),
            stderr_text=String("test_a FAILED"),
        )
    )
    runner.expect(ScriptedStep(_argv("build", "//src/lib_a:lib_a_conda"), exit_code=Int32(3), stderr_text=String("test_a FAILED")))
    runner.expect(_build("//:docs", "//:shell_lint"))
    var result = _fresh_result()
    var o = _run(req, runner, git, result)
    assert_equal(o.outcome, String(OUTCOME_FAILED))
    assert_equal(o.error_id, String(ERROR_BUILD_FAILED))
    assert_equal(o.exit_code(), EXIT_FAILED)
    assert_equal(runner.remaining(), 0)
    assert_equal(len(runner.calls), 5)
    assert_equal(_list(o.lines), String("[BUILT lints]"))
    assert_true(o.message.find(String("unit 'lib_a': `buck2 build //src/lib_a:lib_a_conda` exit 3")) >= 0, o.message)
    assert_true(o.message.find(String("test_a FAILED")) >= 0, o.message)
    # the decision is still recorded: what the change reached
    assert_equal(_list(result.affected_units), String("[lib_a][lints]"))


def test_a_file_without_the_affected_command_is_refused_before_anything() raises:
    var root = _fresh(String("notready"))
    var text = String(_FILE).replace(
        String("  affected {\n    executable: \"/opt/fake/affected\"\n    args: \"--changed-files={changed_files}\"\n    args: \"--units-file={units_file}\"\n  }\n"),
        String(""),
    )
    var req = _request(root, text)
    var git = ScriptedRunner()
    var runner = ScriptedRunner()
    var result = _fresh_result()
    var rec = MemoryRecorder()
    var o = run_build(req, result, rec, runner, git)
    assert_equal(o.error_id, String(ERROR_ARTIFACT))
    assert_equal(o.exit_code(), EXIT_REFUSED)
    assert_equal(len(git.calls), 0)
    assert_equal(len(runner.calls), 0)
    assert_equal(len(rec.records), 0)
    assert_true(o.message.find(String("build system 'pack' owns a unit and declares no affected command")) >= 0, o.message)


def test_an_abbreviated_base_is_refused() raises:
    var req = _request(_fresh(String("short")))
    req.affected_by = String("0123456")
    var git = ScriptedRunner()
    var runner = ScriptedRunner()
    var result = _fresh_result()
    var o = _run(req, runner, git, result)
    assert_equal(o.error_id, String(ERROR_REVISION))
    assert_equal(len(git.calls), 0)
    assert_true(o.message.find(String("--affected-by '0123456' is not a full commit id")) >= 0, o.message)


def test_a_diff_git_refuses_is_refused() raises:
    var root = _fresh(String("nobase"))
    var req = _request(root)
    var git = _git(String(""), diff_exit=Int32(128), diff_stderr=String("fatal: no merge base\n"))
    var runner = ScriptedRunner()
    var result = _fresh_result()
    var o = _run(req, runner, git, result)
    assert_equal(o.outcome, String(OUTCOME_REFUSED))
    assert_equal(o.error_id, String(ERROR_REVISION))
    assert_equal(len(runner.calls), 0)
    assert_true(o.message.startswith(String("BUILD step: --affected-by: `git diff -z --name-only --no-renames ")), o.message)
    assert_true(o.message.find(String("fatal: no merge base")) >= 0, o.message)


def test_a_shallow_clone_is_refused() raises:
    var root = _fresh(String("shallow"))
    var req = _request(root)
    var git = ScriptedRunner()
    git.expect(ScriptedStep(_argv("rev-parse", "--is-shallow-repository"), stdout_text=String("true\n")))
    var runner = ScriptedRunner()
    var result = _fresh_result()
    var o = _run(req, runner, git, result)
    assert_equal(o.error_id, String(ERROR_REVISION))
    assert_true(o.message.find(String("SHALLOW clone: the merge base")) >= 0, o.message)


# ---- plan, and the release build ignoring the check ---------------------------


def test_plan_builds_nothing() raises:
    var root = _fresh(String("plan"))
    var req = _request(root)
    req.plan = True
    var git = _git(_z("src/lib_b/b.mojo"))
    var runner = ScriptedRunner()
    runner.expect(_ask_buck2(req, String("UNIT lib_b\nUNIT tests_cell\nAFFECTED 2\n")))
    runner.expect(_ask_pack(req, String("AFFECTED 0\n")))
    var result = _fresh_result()
    var o = _run(req, runner, git, result)
    assert_equal(o.outcome, String(OUTCOME_SUCCEEDED), o.message)
    assert_equal(len(runner.calls), 2)
    assert_equal(_list(o.lines), String("[WOULD_BUILD lib_b][WOULD_BUILD tests_cell]"))
    assert_equal(_list(result.affected_units), String("[lib_b][tests_cell]"))


def test_a_release_plan_of_the_same_file_ignores_the_checks() raises:
    var root = _fresh(String("release"))
    var req = _request(root)
    req.affected_by = String("")
    req.plan = True
    var git = ScriptedRunner()
    git.expect(ScriptedStep(_argv("rev-parse", "--is-shallow-repository"), stdout_text=String("false\n")))
    git.expect(ScriptedStep(_argv("rev-parse", "--verify", "HEAD"), stdout_text=String(_REV) + String("\n")))
    git.expect(ScriptedStep(_argv("status", "--porcelain", "--untracked-files=no")))
    git.expect(
        ScriptedStep(
            _argv(
                "log", "-1", "--first-parent", "--format=%H", _REV, "--", ".",
                ":(exclude)docs", ":(exclude)*.md", ":(exclude).github",
            ),
            stdout_text=String(_SRC) + String("\n"),
        )
    )
    git.expect(ScriptedStep(_argv("rev-list", "--count", "--first-parent", _SRC), stdout_text=String("154\n")))
    git.expect(ScriptedStep(_argv("log", "-1", "--format=%ct", _SRC), stdout_text=String("1790994309\n")))
    var runner = ScriptedRunner()
    var result = _fresh_result()
    var o = _run(req, runner, git, result)
    assert_equal(o.outcome, String(OUTCOME_SUCCEEDED), o.message)
    assert_equal(_list(o.lines), String("[WOULD_BUILD lib_a][WOULD_BUILD lib_b][WOULD_BUILD meta]"))
    assert_false(result.has_affected_by)
    assert_equal(len(runner.calls), 0)


# ---- a real fake executable --------------------------------------------------

comptime _FAKE_AFFECTED = """changed="$1"; units="$2"
files=$(tr '\\000' ' ' < "$changed")
for f in $files; do
  case "$f" in *.bzl|.buckconfig) echo "WIDENED $f is a build file"; exit 0 ;; esac
done
tab=$(printf '\\t')
seen=" "
n=0
while IFS="$tab" read -r unit target; do
  case "$seen" in *" $unit "*) continue ;; esac
  pkg=${target#//}
  pkg=${pkg%%:*}
  for f in $files; do
    case "$f" in "$pkg"/*) echo "UNIT $unit"; seen="$seen$unit "; n=$((n+1)); break ;; esac
  done
done < "$units"
echo "AFFECTED $n"
"""


def _real_file(root: String) raises -> String:
    """`_FILE` with both build systems' commands pointing at the two
    scripts under `root`: one build system, so the scripts see every unit."""
    write_text_file(root + String("/affected.sh"), String(_FAKE_AFFECTED))
    write_text_file(
        root + String("/build.sh"),
        String("printf '%s\\n' \"$*\" >> ") + root + String("/built.log\n"),
    )
    return (
        String("schema_version: 1\nbuild_systems {\n  name: \"buck2\"\n  executable: \"buck2\"\n  args: \"build\"\n")
        + String("  affected {\n    executable: \"/bin/sh\"\n    args: \"") + root + String("/affected.sh\"\n")
        + String("    args: \"{changed_files}\"\n    args: \"{units_file}\"\n  }\n")
        + String("  build_targets {\n    executable: \"/bin/sh\"\n    args: \"") + root + String("/build.sh\"\n  }\n}\n")
        + String("artifacts {\n  name: \"lib_a\"\n  build_system: \"buck2\"\n  args: \"{out_dir}\"\n")
        + String("  targets: \"//src/lib_a:lib_a_conda\"\n}\n")
        + String("artifacts {\n  name: \"lib_b\"\n  build_system: \"buck2\"\n  args: \"{out_dir}\"\n")
        + String("  targets: \"//src/lib_b:lib_b_conda\"\n}\n")
        + String("checks {\n  name: \"lints\"\n  build_system: \"buck2\"\n  targets: \"//docs:docs\"\n")
        + String("  targets: \"//src/lib_b:lint\"\n}\n")
    )


def test_a_real_fake_affected_executable_selects_exactly_the_reached_units() raises:
    var root = _fresh(String("real"))
    var req = _request(root, _real_file(root))
    var git = _git(_z("src/lib_b/b.mojo", "README.md"))
    var runner = SupervisorRunner()
    var result = _fresh_result()
    var rec = MemoryRecorder()
    var o = run_build(req, result, rec, runner, git)
    assert_equal(o.outcome, String(OUTCOME_SUCCEEDED), o.message)
    assert_equal(Path(req.log_dir + String("/_affected_buck2.stdout")).read_text(), String("UNIT lib_b\nUNIT lints\nAFFECTED 2\n"))
    # one batch run over both units' targets
    assert_equal(Path(root + String("/built.log")).read_text(), String("//src/lib_b:lib_b_conda //docs:docs //src/lib_b:lint\n"))
    assert_equal(_list(result.affected_units), String("[lib_b][lints]"))


def test_a_real_fake_affected_executable_widening_builds_every_unit() raises:
    var root = _fresh(String("realwide"))
    var req = _request(root, _real_file(root))
    var git = _git(_z("tools/build/mojo/defs.bzl"))
    var runner = SupervisorRunner()
    var result = _fresh_result()
    var rec = MemoryRecorder()
    var o = run_build(req, result, rec, runner, git)
    assert_equal(o.outcome, String(OUTCOME_SUCCEEDED), o.message)
    assert_equal(result.affected_verdict, String("WIDENED"))
    assert_equal(result.affected_reason, String("buck2: tools/build/mojo/defs.bzl is a build file"))
    assert_equal(
        Path(root + String("/built.log")).read_text(),
        String("//src/lib_a:lib_a_conda //src/lib_b:lib_b_conda //docs:docs //src/lib_b:lint\n"),
    )


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
