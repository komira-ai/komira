# =============================================================================
# src/kci_cli/tests/test_kci_dispatch_workflow.mojo -- `kci run --stage S`
#   over the recording fake (test_kci_dispatch.mojo), at start-up: the
#   workflow check under GitHub Actions (match, mismatch exit 3, unreadable
#   exit 5, not under CI), and a local `--channel` (reaches the
#   CONDA_INSTALL_ENV validation of a validation-only run; refused, with its
#   exact text, when a step is selected, for a container validation and under
#   GitHub Actions).
# =============================================================================

from std.ffi import external_call
from std.os import makedirs
from std.testing import TestSuite, assert_equal, assert_false, assert_true

from komira_libc.posix import _read_env

from kci_build import BuildRequest
from kci_cli import CliRecorder, SecretStoreChoice, StageSteps, StepEnd, kci_main_with, write_whole_file
from kci_api import (
    OUTCOME_INDETERMINATE,
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
comptime _SET_HASH: String = "5e7a5e7a5e7a5e7a5e7a5e7a5e7a5e7a5e7a5e7a5e7a5e7a5e7a5e7a5e7a5e7a"
comptime _R19: String = "      - uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1\n        with:\n          ref: ${{ env.REVISION }}\n      - name: the revision this run releases\n        run: |\n          case \"$REVISION\" in\n            *[!0-9a-f]*) echo \"refused: REVISION '$REVISION' is not a full commit id\"; exit 1 ;;\n          esac\n          [ \"${#REVISION}\" = 40 ] || { echo \"refused: REVISION '$REVISION' is not a full commit id\"; exit 1; }\n          if [ \"$GITHUB_EVENT_NAME\" = workflow_dispatch ] && [ \"$DRY_RUN\" = true ]; then\n            git merge-base --is-ancestor \"$REVISION\" \"$GITHUB_SHA\" ||\n              { echo \"refused: $REVISION is not on the history of $GITHUB_SHA, the commit this run started on\"; exit 1; }\n          else\n            [ \"$REVISION\" = \"$GITHUB_SHA\" ] ||\n              { echo \"refused: a run that can publish releases the commit it started on ($GITHUB_SHA), not $REVISION (a revision input is for a dry run)\"; exit 1; }\n          fi\n"
"""R21: the first two steps of every release job (auto_promotion.mojo)."""


comptime _R19_MAIN: String = "      - name: only a push to main reaches this job\n        run: |\n          [ \"$GITHUB_EVENT_NAME\" = push ] && [ \"$GITHUB_REF\" = refs/heads/main ] ||\n            { echo \"refused: only a push to refs/heads/main reaches this job; this run is a $GITHUB_EVENT_NAME of $GITHUB_REF\"; exit 1; }\n"
"""R21: the third step of a main-only job."""


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
    var validation_skips: Bool
    var pixis: List[String]
    var channels: List[String]
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
        self.validation_skips = False
        self.pixis = List[String]()
        self.channels = List[String]()
        self.bases = List[String]()

    def validate(mut self, req: ValidateRequest) -> ResultValidation:
        self.order.append(String("validate ") + req.validation.name)
        self.validated.append(
            String("validate ") + req.stage + String(" ") + req.step_name + String(" ") + req.validation.name
            + String(" channel=") + req.channel + String(" release=") + req.release_dir + String(" ")
            + req.platform + String(" ") + req.revision_id + String(" scratch=") + req.scratch_dir
            + String(" plan=") + String(req.plan)
        )
        self.pixis.append(req.validation.name + String(" pixi=") + req.pixi + String(" sha=") + req.pixi_sha256)
        self.channels.append(req.validation.name + String(" local=") + req.channel_override)
        if req.plan:
            return ResultValidation(
                req.validation.name.copy(), req.step_name.copy(), req.validation.kind.copy(),
                String(VALIDATION_WOULD_VALIDATE), String(""),
            )
        var row = ResultValidation(
            req.validation.name.copy(), req.step_name.copy(), req.validation.kind.copy(),
            String(VALIDATION_VALIDATED), String(OUTCOME_SUCCEEDED),
        )
        if self.validation_skips:
            row.outcome = String(OUTCOME_INDETERMINATE)
            row.environment = String("ENV")
            row.skip_reason = String("no network: none of the declared hosts answered (prefix.dev did not answer)")
            row.checks.append(
                ResultValidationCheck(
                    String("network"), String("every declared host answers"),
                    String("network: no declared host answered: prefix.dev did not answer (dns error)"), False,
                )
            )
            return row^
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
                ResultValidationCheck(
                    String("channel"), String("GET answers 200"), String("channel: answered 200; waited 60 of 1800 s over 5 polls"), True
                )
            )
            row.checks.append(ResultValidationCheck(String("channel"), String("listed"), String("a second channel row"), True))
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

    def is_ancestor(mut self, commit: String, of: String) raises -> Bool:
        # every revision is on every history here (test_kci_ref_check holds
        # the ref check)
        self.reads.append(String("is-ancestor ") + commit + String(" ") + of)
        return True

    def release_set_hash(mut self, artifacts_file: String, platform_dir: String) raises -> String:
        # the release every gamma run here is handed (`_gamma`)
        return String(_SET_HASH)

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


def _last(rec: CliRecorder) raises -> KciRunResult:
    return parse_result(rec.records[len(rec.records) - 1], String("record"))


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


def _release_machine(dir: String, validation: Bool = False, env_validation: Bool = False) raises -> String:
    """build -> gamma (environment gamma) -> prod (environment prod), the
    channels file beside it; `validation` declares one on gamma's step,
    `env_validation` one of kind CONDA_INSTALL_ENV (`install-env`)."""
    var c = dir + String("/c.textproto")
    write_whole_file(c, String(_CHANNELS))
    var v = String("")
    if validation:
        v = String(
            " validation { name: \"install\" kind: CONDA_INSTALL_SMOKE install: \"komira_all\""
            " image: \"registry.example.invalid/pixi:1@sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef\""
            " compiler_channel: \"https://conda.modular.com/max\" program: \"release/smoke/smoke.mojo\" }"
        )
    if env_validation:
        v += String(
            " validation { name: \"install-env\" kind: CONDA_INSTALL_ENV install: \"komira_encoding\""
            " compiler_channel: \"https://conda.modular.com/max\" extra_channel: \"conda-forge\" }"
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
    (R1-R21): build and gamma break-glass, prod main only."""
    var run = String("kci run --machine ") + machine + String(" --summary-file \"$GITHUB_STEP_SUMMARY\" --stage ")
    var hash = String(" --release-set-hash \"$RELEASE_SET_HASH\"")
    var line = String("      - name: the prod line\n        if: always()\n        run: echo prod line\n")
    return (
        String("name: kci\non:\n  push:\n    branches: [main]\n    paths-ignore:\n      - 'docs/**'\n      - '**.md'\n")
        + String("  workflow_dispatch:\n    inputs:\n      revision:\n        type: string\n")
        + String("      reason:\n        type: string\n        required: true\n")
        + String("      dry_run:\n        type: boolean\n        default: false\n")
        + String("permissions: {}\n")
        + String("concurrency:\n  group: kci-${{ github.event_name == 'push' && github.ref == 'refs/heads/main' && 'release-main' || inputs.dry_run && format('plan-{0}', github.run_id) || format('ref-{0}', github.ref_name) }}\n")
        + String("  cancel-in-progress: false\n")
        + String("env:\n  DRY_RUN: ${{ github.event_name == 'workflow_dispatch' && inputs.dry_run }}\n")
        + String("jobs:\n")
        + String("  build:\n    environment: build\n    outputs:\n      set_hash: ${{ steps.k.outputs.set_hash }}\n")
        + String("    steps:\n") + String(_R19) + String("      - run: ") + run + String("build\n") + line
        + String("  gamma:\n    needs: build\n    environment: gamma\n    permissions:\n      id-token: write\n")
        + String("    outputs:\n      set_hash: ${{ steps.k.outputs.set_hash }}\n")
        + String("    env:\n      RELEASE_SET_HASH: ${{ needs.build.outputs.set_hash }}\n")
        + String("    steps:\n") + String(_R19) + String("      - run: ") + run + String("gamma") + hash + String("\n") + line
        + String("  prod:\n    needs: gamma\n    if: github.event_name == 'push' && github.ref == 'refs/heads/main'\n    environment: prod\n")
        + String("    permissions:\n      id-token: write\n")
        + String("    env:\n      RELEASE_SET_HASH: ${{ needs.gamma.outputs.set_hash }}\n")
        + String("    steps:\n") + String(_R19) + String(_R19_MAIN) + String("      - run: ") + run + String("prod") + hash + String("\n") + line
    )


def _under_actions(mut steps: FakeSteps, workflow: String):
    steps.set_env(String("GITHUB_ACTIONS"), String("true"))
    steps.set_env(String("GITHUB_REPOSITORY"), String("komira-ai/komira"))
    steps.set_env(String("GITHUB_WORKFLOW_REF"), String("komira-ai/komira/.github/workflows/kci.yml@refs/heads/main"))
    steps.set_env(String("GITHUB_WORKFLOW_SHA"), String(_SHA))
    # a push to main of the revision (the ref check, test_kci_ref_check)
    steps.set_env(String("GITHUB_REF"), String("refs/heads/main"))
    steps.set_env(String("GITHUB_EVENT_NAME"), String("push"))
    steps.set_env(String("GITHUB_SHA"), String(_REV))
    steps.workflow = workflow.copy()


def _gamma(m: String, *extra: String) -> List[String]:
    var a = _run(m, String("gamma"))
    for s in ["--release-version", "rv", "--release-set-hash"]:
        a.append(String(s))
    a.append(String(_SET_HASH))
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


comptime _PIXI_SHA: String = "807eabf195b13d6393b832ecccf93bf59bf784425674a60c7b50b1b84a58367f"


def _local(m: String, *extra: String) -> List[String]:
    """A validation-only gamma run of install-env against a local channel."""
    var a = _run(m, String("gamma"))
    for s in ["--scratch-dir", "/s", "--pixi", "/t/pixi", "--pixi-sha256"]:
        a.append(String(s))
    a.append(String(_PIXI_SHA))
    for s in ["--channel", "file:///w/channel"]:
        a.append(String(s))
    for s in extra:
        a.append(String(s))
    return a^


def test_a_local_channel_reaches_the_env_validation_of_a_validation_only_run() raises:
    var m = _release_machine(_root(String("localok")), False, True)
    var steps = FakeSteps()
    var rec = CliRecorder.memory(String(""))
    assert_equal(kci_main_with(_local(m, "--only", "validation:install-env"), steps, rec), 0)
    assert_equal(len(steps.channels), 1)
    assert_equal(steps.channels[0], String("install-env local=file:///w/channel"))
    assert_equal(len(steps.calls), 0)
    # without --channel the request names none: the step's channel is read
    var plain = FakeSteps()
    var rec2 = CliRecorder.memory(String(""))
    assert_equal(
        kci_main_with(
            _run(m, String("gamma"), "--only", "validation:install-env", "--scratch-dir", "/s", "--pixi", "/t/pixi", "--pixi-sha256", String(_PIXI_SHA)),
            plain, rec2,
        ),
        0,
    )
    assert_equal(plain.channels[0], String("install-env local="))


def test_a_local_channel_is_refused_when_a_step_is_selected() raises:
    var m = _release_machine(_root(String("localpub")), False, True)
    # the PUBLISH step selected, alone or with the validation, or the full stage
    for which in [0, 1, 2]:
        var steps = FakeSteps()
        var rec = CliRecorder.memory(String(""))
        var a = _local(m, "--release-version", "rv")
        if which == 0:
            for s in ["--only", "step:publish"]:
                a.append(String(s))
        elif which == 1:
            for s in ["--only", "step:publish", "--only", "validation:install-env"]:
                a.append(String(s))
        assert_equal(kci_main_with(a, steps, rec), 2)
        # exactly (args.mojo `usage_error` adds no `kci: `; `_stop` prints one)
        assert_equal(
            _last(rec).error.message,
            String(
                "--channel names a local channel, which only a validation-only run reads, and the run selects the"
                " PUBLISH step of stage 'gamma': select the validations with --only validation:<name>"
            ),
        )
        assert_equal(len(steps.calls), 0)
        assert_equal(len(steps.validated), 0)


def test_a_local_channel_is_refused_for_a_container_validation() raises:
    var m = _release_machine(_root(String("localcontainer")), True, True)
    var steps = FakeSteps()
    var rec = CliRecorder.memory(String(""))
    assert_equal(
        kci_main_with(_local(m, "--only", "validation:install-env", "--only", "validation:install"), steps, rec), 2
    )
    # exactly (args.mojo `usage_error` adds no `kci: `; `_stop` prints one)
    assert_equal(
        _last(rec).error.message,
        String(
            "--channel names a local channel, which only a validation-only run reads, and the selected validation"
            " 'install' is CONDA_INSTALL_SMOKE, not CONDA_INSTALL_ENV: a container cannot read this machine's"
            " directory"
        ),
    )
    assert_equal(len(steps.validated), 0)


def test_a_local_channel_is_refused_under_github_actions() raises:
    var m = _release_machine(_root(String("localgha")), False, True)
    var steps = FakeSteps()
    _under_actions(steps, _workflow(m))
    var rec = CliRecorder.memory(String(""))
    assert_equal(kci_main_with(_local(m, "--only", "validation:install-env"), steps, rec), 2)
    # exactly: `_stop` prints it after its one `kci: `
    assert_equal(
        _last(rec).error.message,
        String(
            "--channel names a local channel, and GITHUB_ACTIONS is true: a workflow validates only what was"
            " published, from the step's channel"
        ),
    )
    assert_equal(len(steps.validated), 0)
    # refused before the workflow is read
    assert_equal(len(steps.reads), 0)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
