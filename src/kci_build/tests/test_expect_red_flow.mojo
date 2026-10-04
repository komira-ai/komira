# =============================================================================
# src/kci_build/tests/test_expect_red_flow.mojo
#   The expect_red unit kind in the per-change check (`--affected-by`): a
#   unit whose one target MUST fail to build. Both directions: a build that
#   fails printing the declared message PASSES (RED_AS_EXPECTED), and one
#   that builds, or fails without the message, FAILS (KCI-E-EXPECT-RED) and
#   stops the step; a killed or timed-out build proves nothing (FAILED
#   KCI-E-BUILD-FAILED). The message is found on stdout or stderr. A
#   WIDENED answer reaches the expect_red units too. Last, a real /bin/sh
#   build program through SupervisorRunner, so the verdict reads the files a
#   real build wrote.
# =============================================================================

from std.ffi import external_call
from std.os import getenv, makedirs
from std.os.path import realpath
from std.pathlib import Path

from std.testing import TestSuite, assert_equal, assert_false, assert_true

from kci_api import (
    ERROR_BUILD_FAILED,
    ERROR_EXPECT_RED,
    EXIT_FAILED,
    EXIT_OK,
    OUTCOME_FAILED,
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
}
artifacts {
  name: "lib_a"
  build_system: "buck2"
  args: "//src/lib_a:lib_a_conda[release]"
  args: "--out"
  args: "{out_dir}"
  targets: "//src/lib_a:lib_a_conda"
}
expect_red {
  name: "gate_red"
  build_system: "buck2"
  target: "tests//negative/libgate_bad:libgate_bad"
  message: "GATED TEST FAILED"
}
expect_red {
  name: "closure_refusal"
  build_system: "buck2"
  target: "tests//negative/closure_refusal:hello_incomplete_toolchain"
  message: "REFUSING: toolchain member"
}
"""


def _fresh(tag: String) raises -> String:
    var base = getenv("TEST_TMPDIR")
    if base.byte_length() == 0:
        base = getenv("TMPDIR")
    if base.byte_length() == 0:
        raise Error("neither TEST_TMPDIR nor TMPDIR is set")
    var d = base + String("/kr_") + tag + String("_") + String(Int(external_call["getpid", Int32]()))
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


def _git(path: String) -> ScriptedRunner:
    """A clean, full-history checkout of _REV whose change is `path`."""
    var g = ScriptedRunner()
    g.expect(ScriptedStep(_argv("rev-parse", "--is-shallow-repository"), stdout_text=String("false\n")))
    g.expect(ScriptedStep(_argv("rev-parse", "--verify", "HEAD"), stdout_text=String(_REV) + String("\n")))
    g.expect(ScriptedStep(_argv("status", "--porcelain", "--untracked-files=no")))
    g.expect(
        ScriptedStep(
            _argv("diff", "-z", "--name-only", "--no-renames", String(_BASE) + String("...") + String(_REV)),
            stdout_text=path + chr(0),
        )
    )
    return g^


def _ask(req: BuildRequest, answer: String) -> ScriptedStep:
    return ScriptedStep(
        _argv(req.log_dir + String("/_changed_files"), req.log_dir + String("/_units_buck2.tsv")),
        stdout_text=answer,
    )


def _red(
    target: String, exit_code: Int32, stdout_text: String = String(""), stderr_text: String = String(""), timed_out: Bool = False
) -> ScriptedStep:
    return ScriptedStep(_argv("build", target), exit_code=exit_code, stdout_text=stdout_text, stderr_text=stderr_text, timed_out=timed_out)


def _run(req: BuildRequest, mut runner: ScriptedRunner, mut git: ScriptedRunner, mut result: KciRunResult) -> BuildOutcome:
    var rec = MemoryRecorder()
    return run_build(req, result, rec, runner, git)


def _list(xs: List[String]) -> String:
    var s = String("")
    for i in range(len(xs)):
        s += String("[") + xs[i] + String("]")
    return s^


comptime _GATE = "tests//negative/libgate_bad:libgate_bad"
comptime _CLOSURE = "tests//negative/closure_refusal:hello_incomplete_toolchain"


# ---- PASS: red with the declared text -------------------------------------------


def test_a_red_with_its_message_passes() raises:
    var root = _fresh(String("pass"))
    var req = _request(root)
    var git = _git(String("tools/build/mojo/gate.bzl"))
    var runner = ScriptedRunner()
    runner.expect(_ask(req, String("UNIT lib_a\nUNIT gate_red\nUNIT closure_refusal\nAFFECTED 3\n")))
    runner.expect(ScriptedStep(_argv("build", "//src/lib_a:lib_a_conda")))
    # the message on stderr, then on stdout: either counts
    runner.expect(_red(String(_GATE), Int32(1), stderr_text=String("Action failed\nGATED TEST FAILED: x\n")))
    runner.expect(_red(String(_CLOSURE), Int32(3), stdout_text=String("REFUSING: toolchain member libNVPTX\n")))
    var result = KciRunResult(String("run"), String("run"))
    var o = _run(req, runner, git, result)
    assert_equal(o.outcome, String(OUTCOME_SUCCEEDED), o.message)
    assert_equal(o.exit_code(), EXIT_OK)
    assert_equal(runner.remaining(), 0)
    assert_equal(_list(o.lines), String("[BUILT lib_a][RED_AS_EXPECTED gate_red][RED_AS_EXPECTED closure_refusal]"))
    assert_true(o.message.find(String("1 unit(s) built, 2 expect_red unit(s) failed as expected")) >= 0, o.message)
    assert_equal(_list(result.affected_units), String("[lib_a][gate_red][closure_refusal]"))
    # each built with build_targets and its ONE target
    assert_equal(runner.calls[2].stderr_path, req.log_dir + String("/gate_red.stderr"))


def test_widened_reaches_the_expect_red_units() raises:
    var root = _fresh(String("wide"))
    var req = _request(root)
    var git = _git(String(".buckconfig"))
    var runner = ScriptedRunner()
    runner.expect(_ask(req, String("WIDENED .buckconfig is a build file\n")))
    runner.expect(ScriptedStep(_argv("build", "//src/lib_a:lib_a_conda")))
    runner.expect(_red(String(_GATE), Int32(1), stderr_text=String("GATED TEST FAILED")))
    runner.expect(_red(String(_CLOSURE), Int32(1), stderr_text=String("REFUSING: toolchain member")))
    var result = KciRunResult(String("run"), String("run"))
    var o = _run(req, runner, git, result)
    assert_equal(o.outcome, String(OUTCOME_SUCCEEDED), o.message)
    assert_equal(runner.remaining(), 0)
    assert_equal(result.affected_verdict, String("WIDENED"))


# ---- FAIL: green, or red for another reason -------------------------------------


def test_an_expect_red_unit_that_builds_fails_the_step() raises:
    var root = _fresh(String("green"))
    var req = _request(root)
    var git = _git(String("tests/negative/libgate_bad/BUCK"))
    var runner = ScriptedRunner()
    runner.expect(_ask(req, String("UNIT gate_red\nUNIT closure_refusal\nAFFECTED 2\n")))
    runner.expect(_red(String(_GATE), Int32(0), stderr_text=String("BUILD SUCCEEDED")))
    var result = KciRunResult(String("run"), String("run"))
    var o = _run(req, runner, git, result)
    assert_equal(o.outcome, String(OUTCOME_FAILED))
    assert_equal(o.error_id, String(ERROR_EXPECT_RED))
    assert_equal(o.exit_code(), EXIT_FAILED)
    assert_true(
        o.message.find(
            String("expect_red unit 'gate_red': `buck2 build ") + String(_GATE)
            + String("` built, but it must fail (printing 'GATED TEST FAILED')")
        ) >= 0,
        o.message,
    )
    # the step stops: closure_refusal is never built
    assert_equal(len(runner.calls), 2)
    assert_equal(result.error.id, String(ERROR_EXPECT_RED))


def test_an_expect_red_unit_red_for_another_reason_fails() raises:
    var root = _fresh(String("other"))
    var req = _request(root)
    var git = _git(String("tests/negative/libgate_bad/BUCK"))
    var runner = ScriptedRunner()
    runner.expect(_ask(req, String("UNIT gate_red\nAFFECTED 1\n")))
    runner.expect(_red(String(_GATE), Int32(1), stderr_text=String("error: No engine address\n")))
    var result = KciRunResult(String("run"), String("run"))
    var o = _run(req, runner, git, result)
    assert_equal(o.outcome, String(OUTCOME_FAILED))
    assert_equal(o.error_id, String(ERROR_EXPECT_RED))
    assert_true(
        o.message.find(String("exit 1 without printing 'GATED TEST FAILED': it failed for another reason")) >= 0,
        o.message,
    )
    assert_true(o.message.find(String("No engine address")) >= 0, o.message)


def test_a_timed_out_expect_red_build_proves_nothing() raises:
    var root = _fresh(String("timeout"))
    var req = _request(root)
    var git = _git(String("tests/negative/libgate_bad/BUCK"))
    var runner = ScriptedRunner()
    runner.expect(_ask(req, String("UNIT gate_red\nAFFECTED 1\n")))
    # it even printed the message before the timeout: still not a pass
    runner.expect(_red(String(_GATE), Int32(1), stderr_text=String("GATED TEST FAILED"), timed_out=True))
    var result = KciRunResult(String("run"), String("run"))
    var o = _run(req, runner, git, result)
    assert_equal(o.outcome, String(OUTCOME_FAILED))
    assert_equal(o.error_id, String(ERROR_BUILD_FAILED))
    assert_true(o.message.find(String("timed out")) >= 0, o.message)


# ---- a real build program ------------------------------------------------------


def _real_file(root: String, message: String) raises -> String:
    """One build system whose two commands are /bin/sh scripts under
    `root`: the affected tool answers every unit; the build program fails,
    printing a refusal, for a target under tests//negative/."""
    write_text_file(root + String("/affected.sh"), String("cut -f1 \"$2\" | sort -u | sed 's/^/UNIT /'\necho \"AFFECTED $(cut -f1 \"$2\" | sort -u | wc -l | tr -d ' ')\"\n"))
    write_text_file(
        root + String("/build.sh"),
        String("case \"$1\" in tests//negative/*) echo \"REFUSING: toolchain member libNVPTX\" >&2; exit 1 ;; esac\necho built\n"),
    )
    return (
        String("schema_version: 1\nbuild_systems {\n  name: \"buck2\"\n  executable: \"buck2\"\n  args: \"build\"\n")
        + String("  affected {\n    executable: \"/bin/sh\"\n    args: \"") + root + String("/affected.sh\"\n")
        + String("    args: \"{changed_files}\"\n    args: \"{units_file}\"\n  }\n")
        + String("  build_targets {\n    executable: \"/bin/sh\"\n    args: \"") + root + String("/build.sh\"\n  }\n}\n")
        + String("artifacts {\n  name: \"lib_a\"\n  build_system: \"buck2\"\n  args: \"{out_dir}\"\n")
        + String("  targets: \"//src/lib_a:lib_a_conda\"\n}\n")
        + String("expect_red {\n  name: \"closure_refusal\"\n  build_system: \"buck2\"\n")
        + String("  target: \"") + String(_CLOSURE) + String("\"\n  message: \"") + message + String("\"\n}\n")
    )


def test_a_real_build_program_both_directions() raises:
    var root = _fresh(String("real"))
    var req = _request(root, _real_file(root, String("REFUSING: toolchain member")))
    var git = _git(String("src/lib_a/a.mojo"))
    var runner = SupervisorRunner()
    var result = KciRunResult(String("run"), String("run"))
    var rec = MemoryRecorder()
    var o = run_build(req, result, rec, runner, git)
    assert_equal(o.outcome, String(OUTCOME_SUCCEEDED), o.message)
    assert_equal(_list(o.lines), String("[BUILT lib_a][RED_AS_EXPECTED closure_refusal]"))
    # the same red, declared with a text it does not print: FAIL
    var root2 = _fresh(String("real2"))
    var req2 = _request(root2, _real_file(root2, String("GATED TEST FAILED")))
    var git2 = _git(String("src/lib_a/a.mojo"))
    var runner2 = SupervisorRunner()
    var result2 = KciRunResult(String("run"), String("run"))
    var rec2 = MemoryRecorder()
    var o2 = run_build(req2, result2, rec2, runner2, git2)
    assert_equal(o2.outcome, String(OUTCOME_FAILED))
    assert_equal(o2.error_id, String(ERROR_EXPECT_RED))
    assert_true(o2.message.find(String("without printing 'GATED TEST FAILED'")) >= 0, o2.message)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
