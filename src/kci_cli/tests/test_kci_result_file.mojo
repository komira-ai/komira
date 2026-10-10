# =============================================================================
# src/kci_cli/tests/test_kci_result_file.mojo -- the result file
#   `--result-file` names: each record replaces it whole through a temporary
#   file and a rename; RUNNING before the first effect, FINISHED on every
#   exit path, a refused command line included; a file that cannot be
#   written stops a run before any step.
# =============================================================================

from std.ffi import external_call
from std.os import makedirs
from std.os.path import exists
from std.pathlib import Path
from std.testing import TestSuite, assert_equal, assert_false, assert_true

from komira_libc.posix import _read_env

from kci_build import BuildRequest
from kci_cli import TMP_SUFFIX, CliRecorder, SecretStoreChoice, StageSteps, StepEnd, kci_main_with, recorder_for, write_whole_file
from kci_api import OUTCOME_SUCCEEDED, parse_result
from kci_api import ResultValidation
from kci_api import RunResult as KciRunResult
from kci_publish import NewNamesReport, PublishRequest
from kci_validate import ValidateRequest

comptime _REV: String = "a1b2c3d4e5f60718293a4b5c6d7e8f9012345678"


struct SpySteps(StageSteps, Movable):
    """Each step reads the result file as it stands when the step starts: the
    RUNNING record must already be there. Layout: owned values only."""

    var path: String
    var seen_at_step: List[String]

    def __init__(out self, var path: String):
        self.path = path^
        self.seen_at_step = List[String]()

    def build(mut self, req: BuildRequest, mut result: KciRunResult, mut recorder: CliRecorder) -> StepEnd:
        try:
            self.seen_at_step.append(Path(self.path).read_text())
        except:
            self.seen_at_step.append(String("<no file>"))
        return StepEnd(String(OUTCOME_SUCCEEDED), String(""), String(""))

    def publish(
        mut self, req: PublishRequest, mut result: KciRunResult, mut recorder: CliRecorder, store: SecretStoreChoice
    ) -> StepEnd:
        return StepEnd(String(OUTCOME_SUCCEEDED), String(""), String(""))

    def validate(mut self, req: ValidateRequest) -> ResultValidation:
        # no machine file here declares a validation
        return ResultValidation(
            req.validation.name.copy(), req.step_name.copy(), req.validation.kind.copy(), String("NOT_REACHED"), String("")
        )

    def lookahead(mut self, req: PublishRequest) -> NewNamesReport:
        return NewNamesReport(req.stage.copy(), req.step_name.copy(), req.channel.copy())

    def platform_env(mut self, name: String) -> String:
        # not under GitHub Actions: the start-up workflow check is not made
        return String("")

    def committed_file(mut self, commit: String, path: String) raises -> String:
        raise Error(String("no workflow is read here"))

    def is_ancestor(mut self, commit: String, of: String) raises -> Bool:
        raise Error(String("no history is read here"))

    def main_tip_past(mut self, revision: String) raises -> String:
        # no run here passes --admission (test_kci_staged_ordering.mojo does)
        raise Error(String("main_tip_past is not asked in this test"))

    def release_set_hash(mut self, artifacts_file: String, platform_dir: String) raises -> String:
        raise Error(String("no release is read here"))


def _root(tag: String) raises -> String:
    var base = _read_env("TEST_TMPDIR")
    if base.byte_length() == 0:
        base = _read_env("TMPDIR")
    if base.byte_length() == 0:
        raise Error("neither TEST_TMPDIR nor TMPDIR is set")
    var d = base + String("/kci_result_") + tag + String("_") + String(Int(external_call["getpid", Int32]()))
    makedirs(d, exist_ok=True)
    return d^


def _args(dir: String, result_file: String) raises -> List[String]:
    var m = dir + String("/m.textproto")
    write_whole_file(
        m,
        String("schema_version: 1\nstage { name: \"build\" step { name: \"b\" kind: BUILD platform: \"linux-x86_64\" artifacts: \"d\" } }\n"),
    )
    var l = List[String]()
    for s in ["run", "--stage", "build", "--run-id", "gh-3", "--attempt", "1", "--release-dir", "/r", "--work-dir", "/w", "--log-dir", "/l"]:
        l.append(String(s))
    l.append(String("--revision-id"))
    l.append(String(_REV))
    l.append(String("--machine"))
    l.append(m)
    l.append(String("--result-file"))
    l.append(result_file.copy())
    return l^


def test_running_before_the_first_step_then_finished() raises:
    var d = _root(String("order"))
    var path = d + String("/result.json")
    var a = _args(d, path)
    var steps = SpySteps(path.copy())
    var rec = recorder_for(a)
    assert_equal(kci_main_with(a, steps, rec), 0)
    assert_equal(len(steps.seen_at_step), 1)
    var at_step = parse_result(steps.seen_at_step[0], String("at step"))
    assert_equal(at_step.status, String("RUNNING"))
    assert_equal(at_step.outcome, String("INTERRUPTED"))
    var end = parse_result(Path(path).read_text(), String("end"))
    assert_equal(end.status, String("FINISHED"))
    assert_equal(end.outcome, String("SUCCEEDED"))
    assert_equal(end.exit_code, 0)
    assert_equal(end.run_id, String("gh-3"))
    assert_true(end.finished_at_ms >= end.started_at_ms)
    assert_false(exists(path + String(TMP_SUFFIX)))


def test_a_refused_command_line_is_recorded() raises:
    var d = _root(String("usage"))
    var path = d + String("/result.json")
    var a = List[String]()
    for s in ["publish", "--stage", "prod", "--result-file"]:
        a.append(String(s))
    a.append(path.copy())
    var steps = SpySteps(path.copy())
    var rec = recorder_for(a)
    assert_equal(kci_main_with(a, steps, rec), 2)
    var end = parse_result(Path(path).read_text(), String("end"))
    assert_equal(end.status, String("FINISHED"))
    assert_equal(end.exit_code, 2)
    assert_equal(end.error.id, String("KCI-E-USAGE"))
    assert_equal(end.invoked_as, String("publish"))
    assert_true(end.error.message.find(String("unknown command 'publish'")) >= 0, end.error.message)
    assert_equal(len(steps.seen_at_step), 0)


def test_an_unwritable_result_file_stops_the_run_before_any_step() raises:
    var d = _root(String("unwritable"))
    # A path under a regular file: no open can create it.
    write_whole_file(d + String("/a-file"), String("x\n"))
    var path = d + String("/a-file/result.json")
    var raised = False
    try:
        write_whole_file(path, String("y\n"))
    except:
        raised = True
    assert_true(raised)
    var a = _args(d, path)
    var steps = SpySteps(path.copy())
    var rec = recorder_for(a)
    assert_equal(kci_main_with(a, steps, rec), 4)
    assert_equal(len(steps.seen_at_step), 0)


def test_each_record_replaces_the_file_whole() raises:
    var d = _root(String("whole"))
    var path = d + String("/r.json")
    write_whole_file(path, String("a much longer first text than the second\n"))
    write_whole_file(path, String("short\n"))
    assert_equal(Path(path).read_text(), String("short\n"))
    assert_false(exists(path + String(TMP_SUFFIX)))


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
