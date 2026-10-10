# =============================================================================
# src/kci_cli/tests/test_kci_pr_stage_and_probe.mojo -- two things `kci run`
#   says about itself, over a small recording fake of the seam:
#   (1) the start-up workflow check ACCEPTS the one workflow whose `pr` job
#       runs the machine file's PULL_REQUEST stage on a pull request
#       (`--affected-by` the pull request's base commit) while its release
#       job keeps pull requests out, and refuses one that drifts (exit 3);
#   (2) a dry run whose PUBLISH step recorded the credential probe
#       NOT_UNDER_CI says `credential probe NOT RUN (not under GitHub
#       Actions)` next to its outcome, on the evidence line and in the
#       summary (heading and step row), so a green dry run outside CI is
#       never read as covering the OIDC mint; a probe that ran says nothing.
# =============================================================================

from std.ffi import external_call
from std.os import makedirs
from std.pathlib import Path
from std.testing import TestSuite, assert_equal, assert_false, assert_true

from komira_libc.posix import _read_env

from kci_build import BuildRequest
from kci_cli import CliRecorder, SecretStoreChoice, StageSteps, StepEnd, evidence_line_of, kci_main_with, write_whole_file
from kci_api import OUTCOME_SUCCEEDED, ResultStep, ResultValidation, parse_result
from kci_api import RunResult as KciRunResult
from kci_publish import NewNamesReport, PublishRequest
from kci_validate import ValidateRequest

comptime _REV: String = "a1b2c3d4e5f60718293a4b5c6d7e8f9012345678"
comptime _BASE: String = "0123456789abcdef0123456789abcdef01234567"
comptime _SHA: String = "9f8e7d6c5b4a39281706f5e4d3c2b1a098765432"




struct Fake(StageSteps, Movable):
    """Every step SUCCEEDED; a PUBLISH step records `probe` as its
    credential probe. Platform variables from `env`, the committed workflow
    from `workflow`. Layout: owned values only. No pointer field."""

    var calls: List[String]
    var env_names: List[String]
    var env_values: List[String]
    var workflow: String
    var probe: String

    def __init__(out self):
        self.calls = List[String]()
        self.env_names = List[String]()
        self.env_values = List[String]()
        self.workflow = String("")
        self.probe = String("")

    def set_env(mut self, name: String, value: String):
        self.env_names.append(name.copy())
        self.env_values.append(value.copy())

    def build(mut self, req: BuildRequest, mut result: KciRunResult, mut recorder: CliRecorder) -> StepEnd:
        self.calls.append(String("build ") + req.step_name + String(" base=") + req.affected_by)
        result.steps.append(ResultStep(req.step_name.copy(), String("BUILD"), req.platform.copy(), String(OUTCOME_SUCCEEDED)))
        return StepEnd(String(OUTCOME_SUCCEEDED), String(""), String(""))

    def publish(
        mut self, req: PublishRequest, mut result: KciRunResult, mut recorder: CliRecorder, store: SecretStoreChoice
    ) -> StepEnd:
        self.calls.append(String("publish ") + req.step_name)
        var row = ResultStep(req.step_name.copy(), String("PUBLISH"), req.platform.copy(), String(OUTCOME_SUCCEEDED))
        row.credential_probe = self.probe.copy()
        result.steps.append(row^)
        return StepEnd(String(OUTCOME_SUCCEEDED), String(""), String(""))

    def validate(mut self, req: ValidateRequest) -> ResultValidation:
        return ResultValidation(req.validation.name.copy(), req.step_name.copy(), req.validation.kind.copy(), String("NOT_REACHED"), String(""))

    def lookahead(mut self, req: PublishRequest) -> NewNamesReport:
        var r = NewNamesReport(req.stage.copy(), req.step_name.copy(), req.channel.copy())
        r.read = True
        return r^

    def platform_env(mut self, name: String) -> String:
        for i in range(len(self.env_names)):
            if self.env_names[i] == name:
                return self.env_values[i].copy()
        return String("")

    def committed_file(mut self, commit: String, path: String) raises -> String:
        self.calls.append(String("git show ") + commit + String(":") + path)
        return self.workflow.copy()

    def is_ancestor(mut self, commit: String, of: String) raises -> Bool:
        # a pull request's check reads no ref history (the ref check is a
        # PUSH stage's)
        self.calls.append(String("is-ancestor ") + commit + String(" ") + of)
        return True

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
    var d = base + String("/kci_prp_") + tag + String("_") + String(Int(external_call["getpid", Int32]()))
    makedirs(d, exist_ok=True)
    return d^


def _args(*xs: String) -> List[String]:
    var l = List[String]()
    for x in xs:
        l.append(String(x))
    return l^


def _last(rec: CliRecorder) raises -> KciRunResult:
    return parse_result(rec.records[len(rec.records) - 1], String("record"))


# ---- (1) the start-up check accepts a pull request's check -----------------------


def _pr_machine(dir: String) raises -> String:
    var m = dir + String("/machine.textproto")
    write_whole_file(
        m,
        String("schema_version: 1\n")
        + String("stage { name: \"build\" break_glass: true step { name: \"b\" kind: BUILD platform: \"linux-x86_64\" artifacts: \"d\" } }\n")
        + String("stage { name: \"pr\" trigger: PULL_REQUEST farm_connected: true")
        + String(" step { name: \"check\" kind: BUILD platform: \"linux-x86_64\" artifacts: \"d\" } }\n"),
    )
    return m^


def _pr_workflow(machine: String) -> String:
    """pr.yml: the pull request's check `pr`, the one job `check`."""
    return (
        String("name: pr\non:\n  pull_request:\n    branches: [main]\npermissions: {}\njobs:\n")
        + String("  check:\n    if: github.event.pull_request.head.repo.full_name == github.repository\n")
        + String("    runs-on: ubuntu-24.04\n")
        + String("    permissions:\n      contents: read\n      id-token: write\n    steps:\n")
        + String("      - uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1\n")
        + String("        with:\n          fetch-depth: 0\n")
        + String("      - uses: ./.github/actions/farm-connect\n")
        + String("      - run: kci run --machine ") + machine
        + String(" --stage pr --affected-by ${{ github.event.pull_request.base.sha }} --summary-file \"$GITHUB_STEP_SUMMARY\"\n")
    )


def _release_workflow(machine: String) -> String:
    """kci.yml: the release stage `build`, and no pull_request trigger."""
    return (
        String("name: kci\non:\n  push:\n    branches: [main]\n  workflow_dispatch:\n    inputs:\n      revision:\n")
        + String("        type: string\npermissions: {}\njobs:\n")
        + String("  build:\n    environment: build\n    steps:\n")
        + String("      - run: kci run --machine ") + machine + String(" --stage build --summary-file \"$GITHUB_STEP_SUMMARY\"\n")
    )


def _under_pull_request(mut f: Fake, workflow: String):
    f.set_env(String("GITHUB_ACTIONS"), String("true"))
    f.set_env(String("GITHUB_REPOSITORY"), String("komira-ai/komira"))
    f.set_env(String("GITHUB_WORKFLOW_REF"), String("komira-ai/komira/.github/workflows/pr.yml@refs/pull/7/merge"))
    f.set_env(String("GITHUB_WORKFLOW_SHA"), String(_SHA))
    f.workflow = workflow.copy()


def _pr_run(m: String) -> List[String]:
    var a = _args("run", "--machine")
    a.append(m.copy())
    a.extend(_args("--stage", "pr", "--revision-id", _REV, "--affected-by", _BASE))
    a.extend(_args("--run-id", "gh-7", "--attempt", "1", "--work-dir", "/w", "--log-dir", "/l"))
    return a^


def test_under_actions_a_pull_request_check_runs() raises:
    var m = _pr_machine(_root(String("pr_ok")))
    var f = Fake()
    _under_pull_request(f, _pr_workflow(m))
    var rec = CliRecorder.memory(String(""))
    assert_equal(kci_main_with(_pr_run(m), f, rec), 0)
    assert_equal(f.calls[0], String("git show ") + String(_SHA) + String(":.github/workflows/pr.yml"))
    assert_equal(f.calls[1], String("build check base=") + String(_BASE))
    var r = _last(rec)
    assert_true(r.workflow_checked)
    assert_equal(r.workflow_path, String(".github/workflows/pr.yml"))
    assert_equal(r.scope, String("SELECTIVE"))


def test_under_actions_a_drifted_pull_request_workflow_is_exit_3() raises:
    var m = _pr_machine(_root(String("pr_drift")))
    # the base passed is not the pull request's base commit
    var f = Fake()
    _under_pull_request(f, _pr_workflow(m).replace(String("${{ github.event.pull_request.base.sha }}"), String("origin/main")))
    var rec = CliRecorder.memory(String(""))
    assert_equal(kci_main_with(_pr_run(m), f, rec), 3)
    assert_equal(len(f.calls), 1)
    var r = _last(rec)
    assert_equal(r.error.id, String("KCI-E-WORKFLOW-MISMATCH"))
    assert_true(r.error.message.find(String("R6: stage 'pr' is a PULL_REQUEST stage: `--affected-by origin/main`")) >= 0, r.error.message)
    # a fork's code on the farm-connected job
    var fork = Fake()
    _under_pull_request(
        fork, _pr_workflow(m).replace(String("    if: github.event.pull_request.head.repo.full_name == github.repository\n"), String(""))
    )
    var rec2 = CliRecorder.memory(String(""))
    assert_equal(kci_main_with(_pr_run(m), fork, rec2), 3)
    assert_true(_last(rec2).error.message.find(String("a pull request from a fork runs nothing")) >= 0, _last(rec2).error.message)
    # a second job in pr.yml: it runs the pull request's check and nothing else
    var extra = Fake()
    _under_pull_request(extra, _pr_workflow(m) + String("  gamma:\n    environment: gamma\n    steps:\n      - run: echo hi\n"))
    var rec3 = CliRecorder.memory(String(""))
    assert_equal(kci_main_with(_pr_run(m), extra, rec3), 3)
    assert_true(
        _last(rec3).error.message.find(String("R1: job 'gamma' is not the one job `check` of pr.yml")) >= 0,
        _last(rec3).error.message,
    )


def test_a_run_is_held_to_the_workflow_file_of_its_stage() raises:
    var m = _pr_machine(_root(String("pr_role")))
    # the pull request's stage run from the release workflow: refused
    var f = Fake()
    _under_pull_request(f, _release_workflow(m))
    var rec = CliRecorder.memory(String(""))
    assert_equal(kci_main_with(_pr_run(m), f, rec), 3)
    assert_equal(len(f.calls), 1)
    assert_equal(_last(rec).error.id, String("KCI-E-WORKFLOW-MISMATCH"))
    # a release stage run from pr.yml: refused
    var g = Fake()
    _under_pull_request(g, _pr_workflow(m))
    var a = _args("run", "--machine")
    a.append(m.copy())
    a.extend(_args("--stage", "build", "--revision-id", _REV, "--run-id", "gh-7", "--attempt", "1"))
    a.extend(_args("--work-dir", "/w", "--log-dir", "/l", "--release-dir", "/r"))
    var rec2 = CliRecorder.memory(String(""))
    assert_equal(kci_main_with(a, g, rec2), 3)
    assert_equal(_last(rec2).error.id, String("KCI-E-WORKFLOW-MISMATCH"))
    # a pull_request trigger in the release workflow: refused
    var h = Fake()
    _under_pull_request(h, _release_workflow(m).replace(String("  workflow_dispatch:\n"), String("  pull_request:\n  workflow_dispatch:\n")))
    var rec3 = CliRecorder.memory(String(""))
    assert_equal(kci_main_with(a, h, rec3), 3)
    assert_true(_last(rec3).error.message.find(String("R6: trigger 'pull_request'")) >= 0, _last(rec3).error.message)


# ---- (2) the credential probe that did not run is said -------------------------


def _publish_machine(dir: String) raises -> String:
    var m = dir + String("/machine.textproto")
    write_whole_file(
        m,
        String("schema_version: 1\n")
        + String("stage { name: \"gamma\" step { name: \"publish\" kind: PUBLISH platform: \"linux-x86_64\"")
        + String(" artifacts: \"d\" channels: \"c.textproto\" channel: \"gamma\" } }\n"),
    )
    return m^


def _dry_run(m: String, summary: String) -> List[String]:
    var a = _args("run", "--machine")
    a.append(m.copy())
    a.extend(_args("--stage", "gamma", "--revision-id", _REV, "--run-id", "gh-7", "--attempt", "1"))
    a.extend(_args("--release-dir", "/r", "--release-version", "rv", "--plan", "--summary-file"))
    a.append(summary.copy())
    return a^


def test_a_dry_run_outside_ci_says_the_probe_did_not_run() raises:
    var d = _root(String("probe"))
    var m = _publish_machine(d)
    var summary = d + String("/summary.md")
    var f = Fake()
    f.probe = String("NOT_UNDER_CI")
    var rec = CliRecorder.memory(String(""))
    assert_equal(kci_main_with(_dry_run(m, summary), f, rec), 0)
    var r = _last(rec)
    assert_equal(r.outcome, String("SUCCEEDED"))
    assert_equal(r.steps[0].credential_probe, String("NOT_UNDER_CI"))
    # the evidence line: next to SUCCEEDED
    assert_equal(
        evidence_line_of(r, r.outcome),
        String("kci: FULL run of stage gamma: SUCCEEDED, credential probe NOT RUN (not under GitHub Actions)"),
    )
    # the summary: the heading and the step's row
    var text = Path(summary).read_text()
    assert_true(
        text.find(String("## kci run --stage gamma: SUCCEEDED, credential probe NOT RUN (not under GitHub Actions) (exit 0)")) >= 0,
        text,
    )
    assert_true(
        text.find(String("| publish | PUBLISH | SUCCEEDED, credential probe NOT RUN (not under GitHub Actions) |")) >= 0, text
    )


def test_a_probe_that_ran_adds_nothing() raises:
    var d = _root(String("minted"))
    var m = _publish_machine(d)
    var summary = d + String("/summary.md")
    var f = Fake()
    f.probe = String("MINTED")
    var rec = CliRecorder.memory(String(""))
    assert_equal(kci_main_with(_dry_run(m, summary), f, rec), 0)
    var r = _last(rec)
    assert_equal(evidence_line_of(r, r.outcome), String("kci: FULL run of stage gamma: SUCCEEDED"))
    var text = Path(summary).read_text()
    assert_false(text.find(String("NOT RUN")) >= 0, text)
    assert_true(text.find(String("## kci run --stage gamma: SUCCEEDED (exit 0)")) >= 0, text)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
