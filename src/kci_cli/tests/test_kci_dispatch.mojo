# =============================================================================
# src/kci_cli/tests/test_kci_dispatch.mojo -- `kci run --stage S`, kci's
#   one command, over a recording fake of the seam, through `kci_main_with`:
#   which steps run, in which order, with which request; where the run stops;
#   the run's outcome and exit number; the records the recorder got; `--only`
#   (a SELECTIVE run, never reported as FULL) and `--plan`; the start-up
#   workflow check under GitHub Actions (match, mismatch exit 3, unreadable
#   exit 5, not under CI); a step's validations after it in a FULL run, none
#   under `--only step:`, one alone under `--only validation:`, a failed one
#   VALIDATION_FAILED (exit 7) and one after a failed step NOT_REACHED; the
#   NEW NAMES of the stages after this one; and the `--summary-file` block.
# =============================================================================

from std.ffi import external_call
from std.os import makedirs
from std.pathlib import Path
from std.testing import TestSuite, assert_equal, assert_false, assert_true

from komira_libc.posix import _read_env

from kci_build import BuildRequest
from kci_cli import CliRecorder, SecretStoreChoice, StageSteps, StepEnd, kci_main_with, write_whole_file
from kci_api import (
    ERROR_BUILD_FAILED,
    ERROR_PUBLISH_DIFFERENT_BYTES,
    OUTCOME_FAILED,
    OUTCOME_NOOP,
    OUTCOME_REFUSED,
    OUTCOME_SUCCEEDED,
    OUTCOME_VALIDATION_FAILED,
    VALIDATION_VALIDATED,
    VALIDATION_WOULD_VALIDATE,
    ResultStep,
    ResultValidation,
    ResultValidationCheck,
    parse_result,
)
from kci_api import RunResult as KciRunResult
from kci_publish import NewNamesReport, PublishRequest
from kci_validate import ValidateRequest

comptime _REV: String = "a1b2c3d4e5f60718293a4b5c6d7e8f9012345678"


struct FakeSteps(StageSteps, Movable):
    """Answers each step from `ends`, in order, and records the call. The
    platform-set variables come from `env_names`/`env_values`, the committed
    workflow from `workflow` (`workflow_fails` makes `git show` fail), and
    every lookahead answers `ahead_names` (read) or, with `ahead_unread`,
    not read. Lookaheads and `git show`s are recorded in `reads`.
    Layout: owned values only. No pointer field."""

    var calls: List[String]
    var ends: List[StepEnd]
    var reads: List[String]
    var env_names: List[String]
    var env_values: List[String]
    var workflow: String
    var workflow_fails: Bool
    var ahead_names: List[String]
    var ahead_unread: Bool
    var publish_records_no_plan: Bool
    var order: List[String]
    var validated: List[String]
    var validation_fails: Bool
    var bases: List[String]

    def __init__(out self):
        self.calls = List[String]()
        self.ends = List[StepEnd]()
        self.reads = List[String]()
        self.env_names = List[String]()
        self.env_values = List[String]()
        self.workflow = String("")
        self.workflow_fails = False
        self.ahead_names = List[String]()
        self.ahead_unread = False
        self.publish_records_no_plan = False
        self.order = List[String]()
        self.validated = List[String]()
        self.validation_fails = False
        self.bases = List[String]()

    def validate(mut self, req: ValidateRequest) -> ResultValidation:
        self.order.append(String("validate ") + req.validation.name)
        self.validated.append(
            String("validate ") + req.stage + String(" ") + req.step_name + String(" ") + req.validation.name
            + String(" channel=") + req.channel + String(" release=") + req.release_dir + String(" ")
            + req.platform + String(" ") + req.revision_id + String(" scratch=") + req.scratch_dir
            + String(" plan=") + String(req.plan)
        )
        if req.plan:
            return ResultValidation(
                req.validation.name.copy(), req.step_name.copy(), req.validation.kind.copy(),
                String(VALIDATION_WOULD_VALIDATE), String(""),
            )
        var row = ResultValidation(
            req.validation.name.copy(), req.step_name.copy(), req.validation.kind.copy(),
            String(VALIDATION_VALIDATED), String(OUTCOME_SUCCEEDED),
        )
        if self.validation_fails:
            row.outcome = String(OUTCOME_VALIDATION_FAILED)
            row.checks.append(
                ResultValidationCheck(
                    String("channel"), String("GET answers 200"),
                    String("channel: https://prefix.dev/komira-ai/gamma/linux-64/repodata.json answered 401"), False,
                )
            )
        else:
            row.checks.append(
                ResultValidationCheck(String("program"), String("N of N"), String("program: ran 61 checks, all passed"), True)
            )
        return row^

    def set_env(mut self, name: String, value: String):
        self.env_names.append(name.copy())
        self.env_values.append(value.copy())

    def lookahead(mut self, req: PublishRequest) -> NewNamesReport:
        self.reads.append(
            String("lookahead ") + req.stage + String(" env=") + req.environment + String(" ") + req.channel
            + String(" plan=") + String(req.plan)
        )
        var r = NewNamesReport(req.stage.copy(), req.step_name.copy(), req.channel.copy())
        r.channel_path = String("komira-ai/") + req.channel
        if self.ahead_unread:
            r.detail = String("not read: cannot tell which names the channel holds")
            return r^
        r.read = True
        r.names = self.ahead_names.copy()
        return r^

    def platform_env(mut self, name: String) -> String:
        for i in range(len(self.env_names)):
            if self.env_names[i] == name:
                return self.env_values[i].copy()
        return String("")

    def committed_file(mut self, commit: String, path: String) raises -> String:
        self.reads.append(String("git show ") + commit + String(":") + path)
        if self.workflow_fails:
            raise Error(String("fatal: path does not exist"))
        return self.workflow.copy()

    def _next(mut self, name: String, kind: String, platform: String, mut result: KciRunResult) -> StepEnd:
        var end = StepEnd(String(OUTCOME_SUCCEEDED), String(""), String(""))
        if len(self.calls) <= len(self.ends):
            end = self.ends[len(self.calls) - 1].copy()
        result.steps.append(ResultStep(name.copy(), kind.copy(), platform.copy(), end.outcome.copy()))
        if end.error_id.byte_length() > 0:
            try:
                result.set_error(end.error_id.copy(), end.message.copy())
            except:
                pass
        return end^

    def build(mut self, req: BuildRequest, mut result: KciRunResult, mut recorder: CliRecorder) -> StepEnd:
        self.order.append(String("build ") + req.step_name)
        self.bases.append(req.affected_by.copy())
        self.calls.append(
            String("build ") + req.platform + String(" ") + req.artifacts_file + String(" ") + req.revision_id
            + String(" ") + req.work_dir + String(" ") + req.run.run_id + String(" step=") + req.step_name
            + String(" plan=") + String(req.plan)
        )
        return self._next(req.step_name, String("BUILD"), req.platform, result)

    def publish(
        mut self, req: PublishRequest, mut result: KciRunResult, mut recorder: CliRecorder, store: SecretStoreChoice
    ) -> StepEnd:
        self.order.append(String("publish ") + req.step_name)
        self.calls.append(
            String("publish ") + req.stage + String(" ") + req.channel + String(" ") + req.channels_file
            + String(" plan=") + String(req.plan) + String(" store=") + store.name()
        )
        var end = self._next(req.step_name, String("PUBLISH"), req.platform, result)
        if self.publish_records_no_plan:
            # as kci_publish's report does for a step refused before it read
            # its request
            result.plan = False
        end.summary = String("### NEW NAMES on komira-ai/") + req.channel + String("\n\nnone\n\n")
        return end^


def _root(tag: String) raises -> String:
    var base = _read_env("TEST_TMPDIR")
    if base.byte_length() == 0:
        base = _read_env("TMPDIR")
    if base.byte_length() == 0:
        raise Error("neither TEST_TMPDIR nor TMPDIR is set")
    var d = base + String("/kci_dispatch_") + tag + String("_") + String(Int(external_call["getpid", Int32]()))
    makedirs(d, exist_ok=True)
    return d^


def _machine(dir: String) raises -> String:
    var p = dir + String("/machine.textproto")
    write_whole_file(
        p,
        String("schema_version: 1\n")
        + String("stage { name: \"build\" step { name: \"b\" kind: BUILD platform: \"linux-x86_64\" artifacts: \"d.textproto\" } }\n")
        + String("stage { name: \"prod\" after: \"build\" step { name: \"p\" kind: PUBLISH platform: \"linux-x86_64\"")
        + String(" artifacts: \"d.textproto\" channels: \"c.textproto\" channel: \"komira\" } }\n")
        + String("stage { name: \"all\" step { name: \"b\" kind: BUILD platform: \"linux-x86_64\" artifacts: \"d.textproto\" }")
        + String(" step { name: \"p\" kind: PUBLISH platform: \"linux-x86_64\" artifacts: \"d.textproto\" channels: \"c.textproto\" channel: \"komira\" } }\n")
        + String("stage { name: \"pub-then-build\" step { name: \"p\" kind: PUBLISH platform: \"linux-x86_64\" artifacts: \"d.textproto\"")
        + String(" channels: \"c.textproto\" channel: \"komira\" } step { name: \"b\" kind: BUILD platform: \"linux-x86_64\" artifacts: \"d.textproto\" } }\n"),
    )
    return p^


def _run(machine: String, stage: String, *extra: String) -> List[String]:
    var l = List[String]()
    for s in ["run", "--machine"]:
        l.append(String(s))
    l.append(machine.copy())
    l.append(String("--stage"))
    l.append(stage.copy())
    l.append(String("--revision-id"))
    l.append(String(_REV))
    for s in ["--run-id", "gh-7", "--attempt", "2", "--release-dir", "/r"]:
        l.append(String(s))
    for s in extra:
        l.append(String(s))
    return l^


def _build_flags() -> List[String]:
    var l = List[String]()
    for s in ["--work-dir", "/w", "--log-dir", "/l"]:
        l.append(String(s))
    return l^


def _publish_flags() -> List[String]:
    var l = List[String]()
    for s in ["--release-version", "rv", "--plan"]:
        l.append(String(s))
    return l^


def _last(rec: CliRecorder) raises -> KciRunResult:
    return parse_result(rec.records[len(rec.records) - 1], String("record"))


def test_a_build_stage_runs_its_build_step() raises:
    var m = _machine(_root(String("b")))
    var steps = FakeSteps()
    var rec = CliRecorder.memory(String(""))
    var a = _run(m, String("build"))
    a.extend(_build_flags())
    assert_equal(kci_main_with(a, steps, rec), 0)
    assert_equal(len(steps.calls), 1)
    assert_equal(
        steps.calls[0], String("build linux-x86_64 d.textproto ") + String(_REV) + String(" /w gh-7 step=b plan=False")
    )
    assert_equal(len(rec.statuses), 2)
    assert_equal(rec.statuses[0], String("RUNNING"))
    assert_equal(rec.statuses[1], String("FINISHED"))
    var r = _last(rec)
    assert_equal(r.outcome, String("SUCCEEDED"))
    assert_equal(r.stage, String("build"))
    assert_equal(r.verb, String("run"))
    assert_equal(r.run_id, String("gh-7"))
    assert_equal(r.attempt, 2)
    assert_equal(r.platform, String("linux-x86_64"))
    assert_equal(r.machine_sha256.byte_length(), 64)
    assert_equal(len(r.stage_step_kinds), 1)
    assert_equal(r.scope, String("FULL"))
    assert_equal(len(r.only), 0)
    assert_equal(r.steps[0].name, String("b"))
    assert_true(r.steps[0].selected)


def test_a_mixed_stage_runs_every_step_in_order() raises:
    var m = _machine(_root(String("all")))
    var steps = FakeSteps()
    var rec = CliRecorder.memory(String(""))
    var a = _run(m, String("all"))
    a.extend(_build_flags())
    a.extend(_publish_flags())
    assert_equal(kci_main_with(a, steps, rec), 0)
    assert_equal(len(steps.calls), 2)
    assert_true(steps.calls[0].startswith(String("build ")))
    assert_equal(steps.calls[1], String("publish all komira c.textproto plan=True store=none"))
    var r = _last(rec)
    assert_equal(len(r.steps), 2)
    assert_equal(r.steps[0].kind, String("BUILD"))
    assert_equal(r.steps[1].kind, String("PUBLISH"))
    assert_true(r.plan)
    assert_equal(r.channel, String("komira"))
    assert_equal(r.scope, String("FULL"))


def test_the_run_stops_at_the_first_failure() raises:
    var m = _machine(_root(String("stop")))
    var steps = FakeSteps()
    steps.ends.append(StepEnd(String(OUTCOME_FAILED), String(ERROR_BUILD_FAILED), String("the build failed")))
    var rec = CliRecorder.memory(String(""))
    var a = _run(m, String("all"))
    a.extend(_build_flags())
    a.extend(_publish_flags())
    assert_equal(kci_main_with(a, steps, rec), 4)
    assert_equal(len(steps.calls), 1)
    var r = _last(rec)
    assert_equal(r.outcome, String("FAILED"))
    assert_equal(r.error.id, String(ERROR_BUILD_FAILED))
    assert_equal(r.retry, String("SAFE"))


def test_already_published_is_exit_0() raises:
    var m = _machine(_root(String("noop")))
    var steps = FakeSteps()
    steps.ends.append(StepEnd(String(OUTCOME_NOOP), String(""), String("")))
    var rec = CliRecorder.memory(String(""))
    var a = _run(m, String("prod"))
    a.extend(_publish_flags())
    assert_equal(kci_main_with(a, steps, rec), 0)
    assert_equal(_last(rec).outcome, String("NOOP"))


def test_a_failure_after_a_publish_changed_the_channel_is_partial() raises:
    var m = _machine(_root(String("partial")))
    var steps = FakeSteps()
    var landed = StepEnd(String(OUTCOME_SUCCEEDED), String(""), String(""))
    landed.changed_outside = True
    steps.ends.append(landed^)
    steps.ends.append(StepEnd(String(OUTCOME_REFUSED), String(ERROR_PUBLISH_DIFFERENT_BYTES), String("refused")))
    var rec = CliRecorder.memory(String(""))
    var a = _run(m, String("pub-then-build"))
    a.extend(_build_flags())
    a.extend(_publish_flags())
    assert_equal(kci_main_with(a, steps, rec), 6)
    var r = _last(rec)
    assert_equal(r.outcome, String("PARTIAL"))
    assert_equal(r.retry, String("UNSAFE"))


def test_unknown_stage_is_refused_listing_the_stages() raises:
    var m = _machine(_root(String("unknown")))
    var steps = FakeSteps()
    var rec = CliRecorder.memory(String(""))
    assert_equal(kci_main_with(_run(m, String("staging")), steps, rec), 3)
    assert_equal(len(steps.calls), 0)
    assert_equal(len(rec.statuses), 1)
    var r = _last(rec)
    assert_equal(r.error.id, String("KCI-E-STAGE-UNKNOWN"))
    assert_true(r.error.message.find(String("its stages: build, prod, all, pub-then-build")) >= 0, r.error.message)


def test_the_stage_s_flags() raises:
    var m = _machine(_root(String("flags")))
    var steps = FakeSteps()
    var rec = CliRecorder.memory(String(""))
    var a = _run(m, String("build"))
    a.extend(_build_flags())
    a.extend(_publish_flags())
    assert_equal(kci_main_with(a, steps, rec), 2)
    assert_equal(len(steps.calls), 0)
    assert_equal(_last(rec).error.id, String("KCI-E-USAGE"))


def test_the_machine_file() raises:
    var d = _root(String("machine"))
    var steps = FakeSteps()
    var rec = CliRecorder.memory(String(""))
    assert_equal(kci_main_with(_run(d + String("/absent.textproto"), String("build")), steps, rec), 2)
    var newer = d + String("/newer.textproto")
    write_whole_file(newer, String("schema_version: 2\nstage { name: \"x\" }\n"))
    assert_equal(kci_main_with(_run(newer, String("build")), steps, rec), 3)
    assert_equal(_last(rec).error.id, String("KCI-E-FORMAT-VERSION"))
    var bad = d + String("/bad.textproto")
    write_whole_file(bad, String("schema_version: 1\nstage { name: \"x\" step { name: \"d\" kind: DEPLOY platform: \"linux-x86_64\" artifacts: \"d\" } }\n"))
    assert_equal(kci_main_with(_run(bad, String("x")), steps, rec), 3)
    assert_equal(_last(rec).error.id, String("KCI-E-FORMAT"))
    assert_equal(len(steps.calls), 0)


def test_no_build_or_publish_verb() raises:
    var steps = FakeSteps()
    var rec = CliRecorder.memory(String(""))
    var a = List[String]()
    for s in ["build", "--stage", "build"]:
        a.append(String(s))
    assert_equal(kci_main_with(a, steps, rec), 2)
    var r = _last(rec)
    assert_equal(r.invoked_as, String("build"))
    assert_equal(r.error.id, String("KCI-E-USAGE"))
    assert_equal(len(steps.calls), 0)


def test_only_one_step_is_selective() raises:
    var m = _machine(_root(String("only")))
    var steps = FakeSteps()
    var rec = CliRecorder.memory(String(""))
    var a = _run(m, String("all"), "--only", "step:p")
    a.extend(_publish_flags())
    assert_equal(kci_main_with(a, steps, rec), 0)
    # only the PUBLISH step ran
    assert_equal(len(steps.calls), 1)
    assert_true(steps.calls[0].startswith(String("publish all komira")))
    var r = _last(rec)
    assert_equal(r.outcome, String("SUCCEEDED"))
    assert_equal(r.scope, String("SELECTIVE"))
    assert_equal(len(r.only), 1)
    assert_equal(r.only[0], String("step:p"))
    # every step has a row, in file order; the unselected one has no outcome
    assert_equal(len(r.steps), 2)
    assert_equal(r.steps[0].name, String("b"))
    assert_false(r.steps[0].selected)
    assert_equal(r.steps[0].outcome, String(""))
    assert_equal(r.steps[1].name, String("p"))
    assert_true(r.steps[1].selected)
    # the RUNNING record already says SELECTIVE
    assert_true(rec.records[0].find(String('"scope":"SELECTIVE"')) >= 0, rec.records[0])


def test_every_step_selected_is_still_selective() raises:
    var m = _machine(_root(String("every")))
    var steps = FakeSteps()
    var rec = CliRecorder.memory(String(""))
    var a = _run(m, String("all"), "--only", "step:p", "--only", "step:b")
    a.extend(_build_flags())
    a.extend(_publish_flags())
    assert_equal(kci_main_with(a, steps, rec), 0)
    # file order, whatever the order on the command line
    assert_equal(len(steps.calls), 2)
    assert_true(steps.calls[0].startswith(String("build ")))
    var r = _last(rec)
    assert_equal(r.scope, String("SELECTIVE"))
    assert_equal(r.only[0], String("step:p"))
    assert_equal(r.only[1], String("step:b"))


def test_a_selector_that_matches_nothing_is_refused() raises:
    var m = _machine(_root(String("nomatch")))
    var steps = FakeSteps()
    var rec = CliRecorder.memory(String(""))
    assert_equal(kci_main_with(_run(m, String("build"), "--only", "step:p", "--work-dir", "/w", "--log-dir", "/l"), steps, rec), 3)
    assert_equal(len(steps.calls), 0)
    var r = _last(rec)
    assert_equal(r.error.id, String("KCI-E-SELECTOR-NO-MATCH"))
    assert_true(r.error.message.find(String("its steps: b;")) >= 0, r.error.message)
    assert_equal(r.scope, String("SELECTIVE"))
    var v = CliRecorder.memory(String(""))
    assert_equal(kci_main_with(_run(m, String("build"), "--only", "validation:smoke"), steps, v), 3)
    assert_true(_last(v).error.message.find(String("its validations: (none)")) >= 0, _last(v).error.message)
    assert_equal(len(steps.calls), 0)


def test_a_malformed_selector_is_exit_2_before_anything_is_read() raises:
    var steps = FakeSteps()
    var rec = CliRecorder.memory(String(""))
    # the machine file does not exist: the selector is refused first
    assert_equal(kci_main_with(_run(String("/nonexistent/m.textproto"), String("build"), "--only", "build"), steps, rec), 2)
    var r = _last(rec)
    assert_equal(r.error.id, String("KCI-E-SELECTOR"))
    assert_equal(r.machine_path, String(""))
    var dup = CliRecorder.memory(String(""))
    assert_equal(
        kci_main_with(_run(String("/nonexistent/m.textproto"), String("build"), "--only", "step:b", "--only", "step:b"), steps, dup), 2
    )
    assert_equal(_last(dup).error.id, String("KCI-E-SELECTOR"))
    assert_equal(len(steps.calls), 0)


def test_plan_reaches_a_build_step() raises:
    var m = _machine(_root(String("plan")))
    var steps = FakeSteps()
    var rec = CliRecorder.memory(String(""))
    var a = _run(m, String("build"), "--plan")
    a.extend(_build_flags())
    assert_equal(kci_main_with(a, steps, rec), 0)
    assert_true(steps.calls[0].endswith(String("step=b plan=True")), steps.calls[0])
    assert_true(_last(rec).plan)


comptime _SHA: String = "0123456789abcdef0123456789abcdef01234567"

comptime _CHANNELS: String = (
    "schema_version: 1\n"
    "channel { name: \"gamma\" visibility: PUBLIC repository { artifact_type: CONDA"
    " location: \"https://prefix.dev/komira-ai/gamma\" push_identity: \"repo:komira-ai/komira:environment:gamma\""
    " credential { kind: OIDC_TRUSTED_PUBLISHING } } }\n"
    "channel { name: \"prod\" visibility: PUBLIC repository { artifact_type: CONDA"
    " location: \"https://prefix.dev/komira-ai/prod\" push_identity: \"repo:komira-ai/komira:environment:prod\""
    " credential { kind: OIDC_TRUSTED_PUBLISHING } } }\n"
)


def _release_machine(dir: String, validation: Bool = False) raises -> String:
    """build -> gamma (environment gamma) -> prod (environment prod), the
    channels file beside it; `validation` declares one on gamma's step."""
    var c = dir + String("/c.textproto")
    write_whole_file(c, String(_CHANNELS))
    var v = String("")
    if validation:
        v = String(
            " validation { name: \"install\" kind: CONDA_INSTALL_SMOKE install: \"komira_all\""
            " image: \"registry.example.invalid/pixi:1@sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef\""
            " compiler_channel: \"https://conda.modular.com/max\" program: \"release/smoke/smoke.mojo\" }"
        )
    var m = dir + String("/machine.textproto")
    write_whole_file(
        m,
        String("schema_version: 1\n")
        + String("stage { name: \"build\" break_glass: true step { name: \"build\" kind: BUILD platform: \"linux-x86_64\" artifacts: \"d\" } }\n")
        + String("stage { name: \"gamma\" environment: \"gamma\" after: \"build\" break_glass: true step { name: \"publish\" kind: PUBLISH")
        + String(" platform: \"linux-x86_64\" artifacts: \"d\" channels: \"") + c + String("\" channel: \"gamma\"")
        + v + String(" } }\n")
        + String("stage { name: \"prod\" environment: \"prod\" after: \"gamma\" step { name: \"publish\" kind: PUBLISH")
        + String(" platform: \"linux-x86_64\" artifacts: \"d\" channels: \"") + c + String("\" channel: \"prod\" } }\n"),
    )
    return m^


def _workflow(machine: String) -> String:
    """A workflow that agrees with `_release_machine` without a validation
    (R1-R18): build and gamma break-glass, prod main only."""
    var run = String("kci run --machine ") + machine + String(" --summary-file \"$GITHUB_STEP_SUMMARY\" --stage ")
    var hash = String(" --release-set-hash \"$RELEASE_SET_HASH\"")
    var line = String("      - name: the prod line\n        if: always()\n        run: echo prod line\n")
    return (
        String("name: kci\non:\n  push:\n    branches: [main]\n    paths-ignore:\n      - 'docs/**'\n      - '**.md'\n")
        + String("  workflow_dispatch:\n    inputs:\n      revision:\n        type: string\n")
        + String("      reason:\n        type: string\n        required: true\n")
        + String("      dry_run:\n        type: boolean\n        default: false\n")
        + String("permissions: {}\n")
        + String("concurrency:\n  group: kci-${{ github.event_name == 'pull_request' && format('pr-{0}', github.event.pull_request.number)")
        + String(" || github.ref == 'refs/heads/main' && 'release-main' || format('breakglass-{0}', github.ref_name) }}\n")
        + String("  cancel-in-progress: ${{ github.event_name == 'pull_request' }}\n")
        + String("jobs:\n")
        + String("  build:\n    environment: build\n    outputs:\n      set_hash: ${{ steps.k.outputs.set_hash }}\n")
        + String("    steps:\n      - run: ") + run + String("build\n") + line
        + String("  gamma:\n    needs: build\n    environment: gamma\n    permissions:\n      id-token: write\n")
        + String("    outputs:\n      set_hash: ${{ steps.k.outputs.set_hash }}\n")
        + String("    env:\n      RELEASE_SET_HASH: ${{ needs.build.outputs.set_hash }}\n")
        + String("    steps:\n      - run: ") + run + String("gamma") + hash + String("\n") + line
        + String("  prod:\n    needs: gamma\n    if: github.ref == 'refs/heads/main'\n    environment: prod\n")
        + String("    permissions:\n      id-token: write\n")
        + String("    env:\n      RELEASE_SET_HASH: ${{ needs.gamma.outputs.set_hash }}\n")
        + String("    steps:\n      - run: ") + run + String("prod") + hash + String("\n") + line
    )


def _under_actions(mut steps: FakeSteps, workflow: String):
    steps.set_env(String("GITHUB_ACTIONS"), String("true"))
    steps.set_env(String("GITHUB_REPOSITORY"), String("komira-ai/komira"))
    steps.set_env(String("GITHUB_WORKFLOW_REF"), String("komira-ai/komira/.github/workflows/kci.yml@refs/heads/main"))
    steps.set_env(String("GITHUB_WORKFLOW_SHA"), String(_SHA))
    steps.workflow = workflow.copy()


def _gamma(m: String, *extra: String) -> List[String]:
    var a = _run(m, String("gamma"))
    for s in ["--release-version", "rv"]:
        a.append(String(s))
    for s in extra:
        a.append(String(s))
    return a^


def test_under_actions_a_matching_workflow_runs() raises:
    var m = _release_machine(_root(String("wf_ok")))
    var steps = FakeSteps()
    _under_actions(steps, _workflow(m))
    var rec = CliRecorder.memory(String(""))
    assert_equal(kci_main_with(_gamma(m), steps, rec), 0)
    assert_equal(len(steps.calls), 1)
    # the workflow read is the COMMITTED one, at GITHUB_WORKFLOW_SHA
    assert_equal(steps.reads[0], String("git show ") + String(_SHA) + String(":.github/workflows/kci.yml"))
    var r = _last(rec)
    assert_true(r.workflow_checked)
    assert_equal(r.workflow_path, String(".github/workflows/kci.yml"))
    assert_equal(r.workflow_sha, String(_SHA))
    # the RUNNING record already carries the check
    assert_true(rec.records[0].find(String('"checked":true')) >= 0, rec.records[0])


def test_under_actions_a_mismatching_workflow_is_exit_3_and_runs_nothing() raises:
    var m = _release_machine(_root(String("wf_drift")))
    var steps = FakeSteps()
    # R1 drift: the workflow's job is `publish-gamma`, the machine file's stage `gamma`
    _under_actions(steps, _workflow(m).replace(String("  gamma:\n"), String("  publish-gamma:\n")))
    var rec = CliRecorder.memory(String(""))
    assert_equal(kci_main_with(_gamma(m), steps, rec), 3)
    assert_equal(len(steps.calls), 0)
    # no RUNNING record: refused before the first effect; the FINISHED one is written
    assert_equal(len(rec.statuses), 1)
    assert_equal(rec.statuses[0], String("FINISHED"))
    var r = _last(rec)
    assert_equal(r.outcome, String("REFUSED"))
    assert_equal(r.error.id, String("KCI-E-WORKFLOW-MISMATCH"))
    assert_true(r.error.message.find(String("R1: job 'publish-gamma' is no stage")) >= 0, r.error.message)
    assert_false(r.workflow_checked)


def test_under_actions_an_unreadable_workflow_is_exit_5() raises:
    var m = _release_machine(_root(String("wf_unread")))
    # GITHUB_WORKFLOW_SHA unset
    var unset = FakeSteps()
    unset.set_env(String("GITHUB_ACTIONS"), String("true"))
    unset.set_env(String("GITHUB_REPOSITORY"), String("komira-ai/komira"))
    unset.set_env(String("GITHUB_WORKFLOW_REF"), String("komira-ai/komira/.github/workflows/kci.yml@refs/heads/main"))
    unset.workflow = _workflow(m)
    var rec = CliRecorder.memory(String(""))
    assert_equal(kci_main_with(_gamma(m), unset, rec), 5)
    assert_equal(len(unset.calls), 0)
    assert_equal(len(unset.reads), 0)
    var r = _last(rec)
    assert_equal(r.outcome, String("INDETERMINATE"))
    assert_equal(r.error.id, String("KCI-E-CANNOT-TELL"))
    assert_true(r.error.message.find(String("GITHUB_WORKFLOW_SHA is not set")) >= 0, r.error.message)
    # `git show` fails
    var fails = FakeSteps()
    _under_actions(fails, _workflow(m))
    fails.workflow_fails = True
    var rec2 = CliRecorder.memory(String(""))
    assert_equal(kci_main_with(_gamma(m), fails, rec2), 5)
    assert_equal(len(fails.calls), 0)
    assert_true(_last(rec2).error.message.find(String("fatal: path does not exist")) >= 0, _last(rec2).error.message)
    # a workflow the restricted reader cannot read
    var anchors = FakeSteps()
    _under_actions(anchors, _workflow(m).replace(String("environment: prod"), String("environment: &p prod")))
    var rec3 = CliRecorder.memory(String(""))
    assert_equal(kci_main_with(_gamma(m), anchors, rec3), 5)
    assert_equal(len(anchors.calls), 0)
    # a workflow ref outside .github/workflows/
    var rec4 = CliRecorder.memory(String(""))
    var outside2 = FakeSteps()
    outside2.set_env(String("GITHUB_ACTIONS"), String("true"))
    outside2.set_env(String("GITHUB_REPOSITORY"), String("komira-ai/komira"))
    outside2.set_env(String("GITHUB_WORKFLOW_REF"), String("komira-ai/komira/ci/kci.yml@refs/heads/main"))
    outside2.set_env(String("GITHUB_WORKFLOW_SHA"), String(_SHA))
    outside2.workflow = _workflow(m)
    assert_equal(kci_main_with(_gamma(m), outside2, rec4), 5)
    assert_equal(len(outside2.reads), 0)


def test_not_under_actions_nothing_is_checked_and_the_result_says_so() raises:
    var m = _release_machine(_root(String("wf_local")))
    var steps = FakeSteps()
    steps.workflow = String("not: [a workflow")
    var rec = CliRecorder.memory(String(""))
    assert_equal(kci_main_with(_gamma(m), steps, rec), 0)
    assert_equal(len(steps.calls), 1)
    for i in range(len(steps.reads)):
        assert_false(steps.reads[i].startswith(String("git show")), steps.reads[i])
    var r = _last(rec)
    assert_false(r.workflow_checked)
    assert_equal(r.workflow_reason, String("not under GitHub Actions"))


def test_a_full_run_validates_after_its_step() raises:
    var m = _release_machine(_root(String("val")), True)
    for plan in [False, True]:
        var steps = FakeSteps()
        var rec = CliRecorder.memory(String(""))
        var a = _gamma(m, "--scratch-dir", "/s")
        if plan:
            a.append(String("--plan"))
        assert_equal(kci_main_with(a, steps, rec), 0)
        # the step, then its validation
        assert_equal(len(steps.order), 2)
        assert_equal(steps.order[0], String("publish publish"))
        assert_equal(steps.order[1], String("validate install"))
        assert_equal(
            steps.validated[0],
            String("validate gamma publish install channel=gamma release=/r linux-x86_64 ") + String(_REV)
            + String(" scratch=/s plan=") + String(plan),
        )
        var r = _last(rec)
        assert_equal(r.scope, String("FULL"))
        assert_equal(len(r.validations), 1)
        assert_equal(r.validations[0].name, String("install"))
        assert_equal(r.validations[0].step, String("publish"))
        if plan:
            assert_equal(r.validations[0].effect, String(VALIDATION_WOULD_VALIDATE))
            assert_equal(r.validations[0].outcome, String(""))
        else:
            assert_equal(r.validations[0].effect, String(VALIDATION_VALIDATED))
            assert_equal(r.validations[0].outcome, String(OUTCOME_SUCCEEDED))
            assert_equal(r.outcome, String(OUTCOME_SUCCEEDED))


def test_a_selected_validation_needs_scratch_dir_and_only_then() raises:
    var m = _release_machine(_root(String("valflags")), True)
    var steps = FakeSteps()
    var rec = CliRecorder.memory(String(""))
    # a FULL run selects the validation: no --scratch-dir is a usage error
    assert_equal(kci_main_with(_gamma(m), steps, rec), 2)
    assert_true(_last(rec).error.message.find(String("selects a validation: kci run needs --scratch-dir")) >= 0, _last(rec).error.message)
    # --only step:publish selects none: --scratch-dir is refused
    var rec2 = CliRecorder.memory(String(""))
    assert_equal(kci_main_with(_gamma(m, "--only", "step:publish", "--scratch-dir", "/s"), steps, rec2), 2)
    assert_true(_last(rec2).error.message.find(String("--scratch-dir is a validation's flag")) >= 0, _last(rec2).error.message)
    # a relative scratch directory is refused as the command line is read
    var rec3 = CliRecorder.memory(String(""))
    assert_equal(kci_main_with(_gamma(m, "--scratch-dir", "s"), steps, rec3), 2)
    assert_equal(len(steps.order), 0)


def test_only_step_runs_the_step_without_its_validations() raises:
    var m = _release_machine(_root(String("valstep")), True)
    var steps = FakeSteps()
    var rec = CliRecorder.memory(String(""))
    assert_equal(kci_main_with(_gamma(m, "--only", "step:publish"), steps, rec), 0)
    assert_equal(len(steps.order), 1)
    assert_equal(steps.order[0], String("publish publish"))
    var r = _last(rec)
    assert_equal(r.scope, String("SELECTIVE"))
    assert_equal(len(r.validations), 0)


def test_only_validation_checks_what_is_published() raises:
    var m = _release_machine(_root(String("valonly")), True)
    var steps = FakeSteps()
    var rec = CliRecorder.memory(String(""))
    # no step is selected, so no PUBLISH flag is taken
    assert_equal(
        kci_main_with(_run(m, String("gamma"), "--only", "validation:install", "--scratch-dir", "/s"), steps, rec), 0
    )
    assert_equal(len(steps.order), 1)
    assert_equal(steps.order[0], String("validate install"))
    assert_equal(len(steps.calls), 0)
    var r = _last(rec)
    assert_equal(r.scope, String("SELECTIVE"))
    assert_equal(r.only[0], String("validation:install"))
    assert_equal(len(r.steps), 1)
    assert_false(r.steps[0].selected)
    assert_equal(r.validations[0].outcome, String(OUTCOME_SUCCEEDED))
    assert_equal(r.channel, String("gamma"))
    # --release-version is still a PUBLISH step's flag
    var rec2 = CliRecorder.memory(String(""))
    assert_equal(kci_main_with(_gamma(m, "--only", "validation:install", "--scratch-dir", "/s"), steps, rec2), 2)


def test_a_failed_validation_is_exit_7_and_names_its_finding() raises:
    var d = _root(String("valfail"))
    var m = _release_machine(d, True)
    var steps = FakeSteps()
    steps.validation_fails = True
    var rec = CliRecorder.memory(String(""))
    var summary = d + String("/summary.md")
    assert_equal(
        kci_main_with(_run(m, String("gamma"), "--only", "validation:install", "--scratch-dir", "/s", "--summary-file", summary), steps, rec),
        7,
    )
    var r = _last(rec)
    assert_equal(r.outcome, String(OUTCOME_VALIDATION_FAILED))
    assert_equal(r.error.id, String("KCI-E-VALIDATION"))
    assert_true(r.error.message.find(String("validation 'install' of step 'publish' failed:")) >= 0, r.error.message)
    assert_true(r.error.message.find(String("answered 401")) >= 0, r.error.message)
    # a failed run reads no later stage's names
    assert_equal(len(steps.reads), 0)
    var text = Path(summary).read_text()
    assert_true(text.find(String("| install | publish | VALIDATION_FAILED |")) >= 0, text)
    assert_true(text.find(String("answered 401")) >= 0, text)


def test_a_failed_step_leaves_its_validation_not_reached() raises:
    var m = _release_machine(_root(String("valnotreached")), True)
    var steps = FakeSteps()
    steps.ends.append(StepEnd(String(OUTCOME_FAILED), String(ERROR_PUBLISH_DIFFERENT_BYTES), String("other bytes")))
    var rec = CliRecorder.memory(String(""))
    var rc = kci_main_with(_gamma(m, "--scratch-dir", "/s"), steps, rec)
    assert_true(rc != 0)
    assert_equal(len(steps.validated), 0)
    var r = _last(rec)
    assert_equal(r.outcome, String(OUTCOME_FAILED))
    assert_equal(len(r.validations), 1)
    assert_equal(r.validations[0].effect, String("NOT_REACHED"))
    assert_equal(r.validations[0].outcome, String(""))


def test_a_stage_without_validations_needs_no_scratch_dir() raises:
    var m = _release_machine(_root(String("noval")), True)
    var steps = FakeSteps()
    var rec = CliRecorder.memory(String(""))
    var b = _run(m, String("prod"))
    for x in ["--release-version", "rv"]:
        b.append(String(x))
    assert_equal(kci_main_with(b, steps, rec), 0)
    assert_equal(len(steps.calls), 1)
    assert_equal(len(_last(rec).validations), 0)


def test_gamma_reports_the_new_names_of_prod() raises:
    var d = _root(String("ahead"))
    var m = _release_machine(d)
    var steps = FakeSteps()
    steps.ahead_names.append(String("komira_all"))
    var rec = CliRecorder.memory(String(""))
    var summary = d + String("/summary.md")
    write_whole_file(summary, String("earlier step's text\n"))
    assert_equal(kci_main_with(_gamma(m, "--plan", "--summary-file", summary), steps, rec), 0)
    # the lookahead read prod's PUBLISH step, as prod's own run would (its environment, a plan)
    assert_equal(len(steps.reads), 1)
    assert_equal(steps.reads[0], String("lookahead prod env=prod prod plan=True"))
    var r = _last(rec)
    assert_equal(len(r.new_names), 1)
    assert_equal(r.new_names[0].stage, String("prod"))
    assert_equal(r.new_names[0].step, String("publish"))
    assert_equal(r.new_names[0].channel, String("prod"))
    assert_equal(r.new_names[0].name, String("komira_all"))
    var text = Path(summary).read_text()
    # appended, never truncated
    assert_true(text.startswith(String("earlier step's text\n")), text)
    assert_true(text.find(String("## kci run --stage gamma: SUCCEEDED (exit 0)")) >= 0, text)
    assert_true(text.find(String("FULL run. Dry run (--plan)")) >= 0, text)
    assert_true(text.find(String("| publish | PUBLISH | SUCCEEDED |")) >= 0, text)
    assert_true(text.find(String("### NEW NAMES on komira-ai/gamma")) >= 0, text)
    assert_true(text.find(String("### NEW NAMES on komira-ai/prod")) >= 0, text)
    assert_true(text.find(String("- `komira_all`")) >= 0, text)
    assert_true(text.find(String("workflow: not checked (not under GitHub Actions)")) >= 0, text)


def test_an_unread_later_channel_is_not_none() raises:
    var d = _root(String("ahead_unread"))
    var m = _release_machine(d)
    var steps = FakeSteps()
    steps.ahead_unread = True
    var rec = CliRecorder.memory(String(""))
    var summary = d + String("/summary.md")
    assert_equal(kci_main_with(_gamma(m, "--summary-file", summary), steps, rec), 0)
    assert_equal(len(_last(rec).new_names), 0)
    var text = Path(summary).read_text()
    var at = text.find(String("### NEW NAMES on komira-ai/prod"))
    assert_true(at >= 0, text)
    var tail = String(text[byte = at:])
    assert_true(tail.find(String("not read: cannot tell")) >= 0, tail)
    assert_true(tail.find(String("\nnone\n")) < 0, tail)


def test_a_run_without_a_release_version_skips_the_lookahead() raises:
    # the validate job: `--only validation:install`, no --release-version. A
    # later stage's names cannot be computed without the release version, so
    # the lookahead is skipped and says so, never "cannot be read" of an
    # empty path, and never "none"
    var d = _root(String("ahead_norv"))
    var m = _release_machine(d, True)
    var steps = FakeSteps()
    steps.ahead_names.append(String("komira_all"))
    var rec = CliRecorder.memory(String(""))
    var summary = d + String("/summary.md")
    assert_equal(
        kci_main_with(_run(m, String("gamma"), "--only", "validation:install", "--scratch-dir", "/s", "--summary-file", summary), steps, rec),
        0,
    )
    for i in range(len(steps.reads)):
        assert_true(not steps.reads[i].startswith(String("lookahead")), steps.reads[i])
    assert_equal(len(_last(rec).new_names), 0)
    var text = Path(summary).read_text()
    var at = text.find(String("### NEW NAMES on prod"))
    assert_true(at >= 0, text)
    var tail = String(text[byte = at:])
    assert_true(tail.find(String("lookahead skipped: no release version (plan-only or validation-only run)")) >= 0, tail)
    assert_true(tail.find(String("cannot be read")) < 0, tail)
    assert_true(tail.find(String("\nnone\n")) < 0, tail)
    # a plan WITH a release version still reads prod's names
    var steps2 = FakeSteps()
    var rec2 = CliRecorder.memory(String(""))
    assert_equal(kci_main_with(_gamma(m, "--plan", "--scratch-dir", "/s"), steps2, rec2), 0)
    assert_equal(len(steps2.reads), 1)
    assert_equal(steps2.reads[0], String("lookahead prod env=prod prod plan=True"))


def test_no_lookahead_after_a_failure_and_the_last_stage_has_none() raises:
    var d = _root(String("ahead_none"))
    var m = _release_machine(d)
    var failed = FakeSteps()
    failed.ends.append(StepEnd(String(OUTCOME_FAILED), String("KCI-E-CREDENTIAL"), String("mint refused")))
    var rec = CliRecorder.memory(String(""))
    var summary = d + String("/failed.md")
    assert_equal(kci_main_with(_gamma(m, "--summary-file", summary), failed, rec), 4)
    assert_equal(len(failed.reads), 0)
    var text = Path(summary).read_text()
    assert_true(text.find(String("## kci run --stage gamma: FAILED (exit 4)")) >= 0, text)
    assert_true(text.find(String("- error: `KCI-E-CREDENTIAL`: mint refused")) >= 0, text)
    # prod is the last stage: no lookahead
    var last = FakeSteps()
    var rec2 = CliRecorder.memory(String(""))
    var b = _run(m, String("prod"))
    for x in ["--release-version", "rv"]:
        b.append(String(x))
    assert_equal(kci_main_with(b, last, rec2), 0)
    assert_equal(len(last.reads), 0)


def test_a_plan_stays_a_plan_whatever_the_step_records() raises:
    var d = _root(String("plan_kept"))
    var m = _release_machine(d)
    var steps = FakeSteps()
    steps.publish_records_no_plan = True
    steps.ends.append(StepEnd(String(OUTCOME_REFUSED), String("KCI-E-MEMBER"), String("no release directory")))
    var rec = CliRecorder.memory(String(""))
    var summary = d + String("/plan.md")
    assert_equal(kci_main_with(_gamma(m, "--plan", "--summary-file", summary), steps, rec), 3)
    assert_true(_last(rec).plan)
    var text = Path(summary).read_text()
    assert_true(text.find(String("Dry run (--plan)")) >= 0, text)


def test_a_refused_command_line_reaches_the_summary() raises:
    var d = _root(String("summary_usage"))
    var summary = d + String("/usage.md")
    var steps = FakeSteps()
    var rec = CliRecorder.memory(String(""))
    var a = List[String]()
    for s in ["ci", "check", "--summary-file"]:
        a.append(String(s))
    a.append(summary)
    assert_equal(kci_main_with(a, steps, rec), 2)
    var text = Path(summary).read_text()
    assert_true(text.find(String("## kci: REFUSED (exit 2)")) >= 0, text)
    assert_true(text.find(String("there is one command: kci run")) >= 0, text)
    assert_equal(_last(rec).invoked_as, String("ci"))


comptime _BASE: String = "0123456789abcdef0123456789abcdef01234567"


def _pr_run(machine: String, stage: String, *extra: String) -> List[String]:
    """`kci run --affected-by _BASE`: no --release-dir."""
    var l = List[String]()
    for s in ["run", "--machine"]:
        l.append(String(s))
    l.append(machine.copy())
    for s in ["--stage"]:
        l.append(String(s))
    l.append(stage.copy())
    for s in ["--revision-id", _REV, "--affected-by", _BASE, "--run-id", "gh-7", "--attempt", "2"]:
        l.append(String(s))
    for s in extra:
        l.append(String(s))
    return l^


def test_affected_by_reaches_the_build_step_and_is_selective() raises:
    var d = _root(String("pr"))
    var m = _machine(d)
    var steps = FakeSteps()
    var rec = CliRecorder.memory(String(""))
    var summary = d + String("/summary.md")
    var a = _pr_run(m, String("build"), "--summary-file", summary)
    a.extend(_build_flags())
    assert_equal(kci_main_with(a, steps, rec), 0)
    assert_equal(len(steps.bases), 1)
    assert_equal(steps.bases[0], String(_BASE))
    # the RUNNING record already says SELECTIVE and names the base
    var first = parse_result(rec.records[0], String("running"))
    assert_equal(first.status, String("RUNNING"))
    assert_equal(first.scope, String("SELECTIVE"))
    assert_true(first.has_affected_by)
    assert_equal(first.affected_base, String(_BASE))
    var r = _last(rec)
    assert_equal(r.outcome, String("SUCCEEDED"))
    assert_equal(r.scope, String("SELECTIVE"))
    assert_equal(len(r.only), 0)
    assert_true(r.has_affected_by)
    assert_true(r.steps[0].selected)
    var text = Path(summary).read_text()
    assert_true(
        text.find(String("SELECTIVE run (affected-by ") + String(_BASE) + String("): not a full run.")) >= 0, text
    )
    assert_true(text.find(String("- affected: no answer")) >= 0, text)


def test_a_release_build_carries_no_base() raises:
    var m = _machine(_root(String("nobase")))
    var steps = FakeSteps()
    var rec = CliRecorder.memory(String(""))
    var a = _run(m, String("build"))
    a.extend(_build_flags())
    assert_equal(kci_main_with(a, steps, rec), 0)
    assert_equal(steps.bases[0], String(""))
    assert_false(_last(rec).has_affected_by)


def test_affected_by_on_a_publishing_stage_is_a_usage_error() raises:
    var m = _machine(_root(String("prpub")))
    var steps = FakeSteps()
    var rec = CliRecorder.memory(String(""))
    assert_equal(kci_main_with(_pr_run(m, String("prod"), "--release-version", "rv"), steps, rec), 2)
    assert_equal(len(steps.calls), 0)
    var r = _last(rec)
    assert_equal(r.error.id, String("KCI-E-USAGE"))
    assert_true(r.error.message.find(String("stage 'prod' has the PUBLISH step 'p'")) >= 0, r.error.message)
    assert_equal(r.scope, String("SELECTIVE"))


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
