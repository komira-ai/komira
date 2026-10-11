# =============================================================================
# src/kci_cli/tests/test_kci_ref_check.mojo -- continuous auto-promotion as
#   `kci run` holds it at start-up under GitHub Actions (dispatch.mojo's
#   header, 4a and 4b), over a recording fake of the seam:
#
#   (1) a stage without `break_glass` (prod) runs only on a PUSH to main:
#       off main, on a manual run of main, or on a ref that is main in
#       another case it is REFUSED KCI-E-NOT-ON-MAIN (exit 3) before any
#       history is read; on a push the revision is GITHUB_SHA itself and on
#       `refs/remotes/origin/main`'s history (the full refname: a tag named
#       `origin/main` cannot answer), else refused the same; history git
#       cannot read (a shallow clone, no origin/main) is exit 5;
#   (2) any other run of a break_glass stage (gamma) is BREAK-GLASS, a
#       manual run of main included: its revision is held to the run's own
#       commit (GITHUB_SHA; a dry run's to that commit's history), else
#       KCI-E-BREAK-GLASS-REVISION, exit 3; its reason is required (empty or
#       over 200 bytes: KCI-E-BREAK-GLASS-REASON, exit 3; over one line: the command
#       line's own refusal, exit 2), its summary starts with the BREAK-GLASS
#       line, and its PUBLISH step runs in the stage's
#       break_glass_environment as break-glass (kci_publish holds the
#       channel's second trusted publisher to it); a push to main publishes
#       from the stage's own environment;
#   (3) the set hash: a release that recomputes to another set is
#       KCI-E-SET-HASH (exit 3), one that cannot be recomputed too; under
#       GitHub Actions a publishing or validating run without the flag is a
#       usage error (exit 2); the recomputed hash is the result's;
#   (4) a stage without `break_glass` never goes backward (its PUBLISH
#       request says so; kci_publish refuses KCI-E-SUPERSEDED), a
#       break_glass one may;
#   (5) the prod line: `promoted to prod: <names> <build>`, `nothing new`,
#       `PLAN ONLY`, in the summary and on stderr; a break_glass stage says
#       none;
#   (6) not under GitHub Actions no ref is checked;
#   (1b) a push to main is never `--plan` (KCI-E-PLAN-ON-RELEASE, exit 3,
#       nothing run), whatever the workflow made DRY_RUN; a manual dry run
#       of main still is one;
#   (3b) the result's set hash is handed on only by a run that is not
#       `--plan` and whose every selected validation VALIDATED and
#       SUCCEEDED (validate's is what prod publishes).
# =============================================================================

from std.ffi import external_call
from std.os import makedirs
from std.pathlib import Path
from std.testing import TestSuite, assert_equal, assert_false, assert_true

from komira_libc.posix import _read_env

from kci_build import BuildRequest
from kci_cli import CliRecorder, SecretStoreChoice, StageSteps, StepEnd, kci_main_with, write_whole_file
from kci_api import (
    ARTIFACT_ALREADY_PRESENT,
    ARTIFACT_UPLOADED,
    OUTCOME_NOOP,
    OUTCOME_SUCCEEDED,
    OUTCOME_VALIDATION_FAILED,
    ResultArtifact,
    ResultStep,
    ResultValidation,
    ResultValidationCheck,
    parse_result,
)
from kci_api import RunResult as KciRunResult
from kci_publish import NewNamesReport, PublishRequest
from kci_validate import ValidateRequest

comptime _REV: String = "a1b2c3d4e5f60718293a4b5c6d7e8f9012345678"
comptime _SHA: String = "0123456789abcdef0123456789abcdef01234567"
comptime _HEAD: String = "fedcba9876543210fedcba9876543210fedcba98"
comptime _H: String = "5e7a5e7a5e7a5e7a5e7a5e7a5e7a5e7a5e7a5e7a5e7a5e7a5e7a5e7a5e7a5e7a"
comptime _OTHER_H: String = "0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b"


comptime _R19: String = "      - uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1\n        with:\n          ref: ${{ env.REVISION }}\n      - name: the revision this run releases\n        run: |\n          case \"$REVISION\" in\n            *[!0-9a-f]*) echo \"refused: REVISION '$REVISION' is not a full commit id\"; exit 1 ;;\n          esac\n          [ \"${#REVISION}\" = 40 ] || { echo \"refused: REVISION '$REVISION' is not a full commit id\"; exit 1; }\n          if [ \"$GITHUB_EVENT_NAME\" = workflow_dispatch ] && [ \"$DRY_RUN\" = true ]; then\n            git merge-base --is-ancestor \"$REVISION\" \"$GITHUB_SHA\" ||\n              { echo \"refused: $REVISION is not on the history of $GITHUB_SHA, the commit this run started on\"; exit 1; }\n          else\n            [ \"$REVISION\" = \"$GITHUB_SHA\" ] ||\n              { echo \"refused: a run that can publish releases the commit it started on ($GITHUB_SHA), not $REVISION (a revision input is for a dry run)\"; exit 1; }\n          fi\n"
"""R21: the first two steps of every release job (auto_promotion.mojo)."""
comptime _R19_MAIN: String = "      - name: only a push to main reaches this job\n        run: |\n          [ \"$GITHUB_EVENT_NAME\" = push ] && [ \"$GITHUB_REF\" = refs/heads/main ] ||\n            { echo \"refused: only a push to refs/heads/main reaches this job; this run is a $GITHUB_EVENT_NAME of $GITHUB_REF\"; exit 1; }\n"
"""R21: the third step of a main-only job."""


struct Fake(StageSteps, Movable):
    """Every step SUCCEEDED (a publish `publish_outcome`, with one artifact
    row per name in `names`). The platform variables from `env`, the
    committed workflow from `workflow`; `is_ancestor` answers `ancestor`
    (or raises with `history_unreadable`) and records each question; the
    release recomputes to `set_hash` (or raises with `release_refused`).
    Layout: owned values only. No pointer field."""

    var calls: List[String]
    var asked: List[String]
    var never_backward: List[Bool]
    var environments: List[String]
    var break_glass: List[Bool]
    var env_names: List[String]
    var env_values: List[String]
    var workflow: String
    var ancestor: Bool
    var history_unreadable: Bool
    var set_hash: String
    var release_refused: Bool
    var publish_outcome: String
    var names: List[String]
    var validation_outcome: String

    def __init__(out self):
        self.calls = List[String]()
        self.asked = List[String]()
        self.never_backward = List[Bool]()
        self.environments = List[String]()
        self.break_glass = List[Bool]()
        self.env_names = List[String]()
        self.env_values = List[String]()
        self.workflow = String("")
        self.ancestor = True
        self.history_unreadable = False
        self.set_hash = String(_H)
        self.release_refused = False
        self.publish_outcome = String(OUTCOME_SUCCEEDED)
        self.names = List[String]()
        self.names.append(String("komira_encoding"))
        self.names.append(String("komira_all"))
        self.validation_outcome = String(OUTCOME_SUCCEEDED)

    def set_env(mut self, name: String, value: String):
        for i in range(len(self.env_names)):
            if self.env_names[i] == name:
                self.env_values[i] = value.copy()
                return
        self.env_names.append(name.copy())
        self.env_values.append(value.copy())

    def build(mut self, req: BuildRequest, mut result: KciRunResult, mut recorder: CliRecorder) -> StepEnd:
        self.calls.append(String("build ") + req.step_name)
        result.steps.append(ResultStep(req.step_name.copy(), String("BUILD"), req.platform.copy(), String(OUTCOME_SUCCEEDED)))
        return StepEnd(String(OUTCOME_SUCCEEDED), String(""), String(""))

    def publish(
        mut self, req: PublishRequest, mut result: KciRunResult, mut recorder: CliRecorder, store: SecretStoreChoice
    ) -> StepEnd:
        self.calls.append(String("publish ") + req.stage)
        self.never_backward.append(req.never_backward)
        self.environments.append(req.environment.copy())
        self.break_glass.append(req.break_glass)
        result.steps.append(ResultStep(req.step_name.copy(), String("PUBLISH"), req.platform.copy(), self.publish_outcome.copy()))
        result.plan = req.plan
        for i in range(len(self.names)):
            var a = ResultArtifact()
            a.effect = String(ARTIFACT_UPLOADED) if self.publish_outcome == String(OUTCOME_SUCCEEDED) else String(ARTIFACT_ALREADY_PRESENT)
            a.artifact_type = String("CONDA")
            a.file = self.names[i] + String("-1.0.0-h01234567_3.conda")
            a.name = self.names[i].copy()
            a.platform = String("linux-x86_64")
            a.revision = req.revision_id.copy()
            a.sha256 = String(_H)
            a.state_before = String("absent")
            a.state_after = String("present-same")
            a.subdir = String("linux-64")
            a.version = String("1.0.0")
            result.artifacts.append(a^)
        return StepEnd(self.publish_outcome.copy(), String(""), String(""))

    def validate(mut self, req: ValidateRequest) -> ResultValidation:
        self.calls.append(String("validate ") + req.validation.name)
        if req.plan:
            return ResultValidation(
                req.validation.name.copy(), req.step_name.copy(), req.validation.kind.copy(), String("WOULD_VALIDATE"), String("")
            )
        var row = ResultValidation(
            req.validation.name.copy(), req.step_name.copy(), req.validation.kind.copy(), String("VALIDATED"),
            self.validation_outcome.copy(),
        )
        var ok = self.validation_outcome == String(OUTCOME_SUCCEEDED)
        row.checks.append(ResultValidationCheck(String("channel"), String("GET answers 200"), String("channel: answered"), ok))
        return row^

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
        return self.workflow.copy()

    def is_ancestor(mut self, commit: String, of: String) raises -> Bool:
        self.asked.append(commit + String(" on ") + of)
        if self.history_unreadable:
            raise Error(String("the checkout is shallow (or not a git repository): its history cannot tell"))
        return self.ancestor

    def main_tip_past(mut self, revision: String) raises -> String:
        # no run here passes --admission (test_kci_staged_ordering.mojo does)
        raise Error(String("main_tip_past is not asked in this test"))

    def release_set_hash(mut self, artifacts_file: String, platform_dir: String) raises -> String:
        if self.release_refused:
            raise Error(String("PUBLISH step: the release directory is refused: no release.json"))
        return self.set_hash.copy()


def _root(tag: String) raises -> String:
    var base = _read_env("TEST_TMPDIR")
    if base.byte_length() == 0:
        base = _read_env("TMPDIR")
    if base.byte_length() == 0:
        raise Error("neither TEST_TMPDIR nor TMPDIR is set")
    var d = base + String("/kci_ref_") + tag + String("_") + String(Int(external_call["getpid", Int32]()))
    makedirs(d, exist_ok=True)
    return d^


comptime _CHANNELS: String = (
    "schema_version: 1\n"
    "channel { name: \"gamma\" visibility: PUBLIC repository { artifact_type: CONDA"
    " location: \"https://prefix.dev/komira-ai/gamma\" push_identity: \"repo:komira-ai/komira:environment:gamma\""
    " break_glass_push_identity: \"repo:komira-ai/komira:environment:gamma-breakglass\""
    " credential { kind: OIDC_TRUSTED_PUBLISHING } } }\n"
    "channel { name: \"prod\" visibility: PUBLIC repository { artifact_type: CONDA"
    " location: \"https://prefix.dev/komira-ai/prod\" push_identity: \"repo:komira-ai/komira:environment:prod\""
    " credential { kind: OIDC_TRUSTED_PUBLISHING } } }\n"
)


def _machine(dir: String, validation: Bool = False) raises -> String:
    """build and gamma break_glass, prod main only: the repository's shape;
    `validation` declares the validation `install` on gamma's step."""
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
        + String("stage { name: \"gamma\" after: \"build\" break_glass: true break_glass_environment: \"gamma-breakglass\"")
        + String(" step { name: \"publish\" kind: PUBLISH")
        + String(" platform: \"linux-x86_64\" artifacts: \"d\" channels: \"") + c + String("\" channel: \"gamma\"") + v + String(" } }\n")
        + String("stage { name: \"prod\" after: \"gamma\" step { name: \"publish\" kind: PUBLISH")
        + String(" platform: \"linux-x86_64\" artifacts: \"d\" channels: \"") + c + String("\" channel: \"prod\" } }\n"),
    )
    return m^


def _workflow(machine: String) -> String:
    """The workflow that agrees with `_machine` (R1-R21)."""
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
        + String("  gamma:\n    needs: build\n    environment: ${{ github.event_name == 'push' && 'gamma' || 'gamma-breakglass' }}\n")
        + String("    permissions:\n      id-token: write\n")
        + String("    outputs:\n      set_hash: ${{ steps.k.outputs.set_hash }}\n")
        + String("    env:\n      RELEASE_SET_HASH: ${{ needs.build.outputs.set_hash }}\n")
        + String("    steps:\n") + String(_R19) + String("      - run: ") + run + String("gamma") + hash + String("\n") + line
        + String("  prod:\n    needs: gamma\n    if: github.event_name == 'push' && github.ref == 'refs/heads/main'\n    environment: prod\n")
        + String("    permissions:\n      id-token: write\n")
        + String("    env:\n      RELEASE_SET_HASH: ${{ needs.gamma.outputs.set_hash }}\n")
        + String("    steps:\n") + String(_R19) + String(_R19_MAIN) + String("      - run: ") + run + String("prod") + hash + String("\n") + line
    )


def _actions(mut f: Fake, machine: String, ref_value: String, event: String = String("push")):
    """Under GitHub Actions: a `event` of `ref_value` whose GITHUB_SHA is the
    revision (a test that wants another sets it: _HEAD)."""
    f.set_env(String("GITHUB_ACTIONS"), String("true"))
    f.set_env(String("GITHUB_REPOSITORY"), String("komira-ai/komira"))
    f.set_env(String("GITHUB_WORKFLOW_REF"), String("komira-ai/komira/.github/workflows/kci.yml@") + ref_value)
    f.set_env(String("GITHUB_WORKFLOW_SHA"), String(_SHA))
    f.set_env(String("GITHUB_REF"), ref_value)
    f.set_env(String("GITHUB_EVENT_NAME"), event)
    f.set_env(String("GITHUB_SHA"), String(_REV))
    f.set_env(String("GITHUB_ACTOR"), String("octocat"))
    f.workflow = _workflow(machine)


def _publish(m: String, stage: String, *extra: String) -> List[String]:
    var a = List[String]()
    for s in ["run", "--machine"]:
        a.append(String(s))
    a.append(m.copy())
    for s in ["--stage"]:
        a.append(String(s))
    a.append(stage.copy())
    a.append(String("--revision-id"))
    a.append(String(_REV))
    for s in ["--run-id", "gh-7", "--attempt", "1", "--release-dir", "/r"]:
        a.append(String(s))
    for s in ["--release-version", "rv"]:
        a.append(String(s))
    for s in extra:
        a.append(String(s))
    return a^


def _last(rec: CliRecorder) raises -> KciRunResult:
    return parse_result(rec.records[len(rec.records) - 1], String("record"))


# ---- (1) main only -------------------------------------------------------------------


def test_prod_off_main_is_not_on_main() raises:
    var m = _machine(_root(String("offmain")))
    var f = Fake()
    _actions(f, m, String("refs/heads/feature"), String("workflow_dispatch"))
    var rec = CliRecorder.memory(String(""))
    var a = _publish(m, String("prod"), "--release-set-hash", _H, "--context", "reason=hotfix")
    assert_equal(kci_main_with(a, f, rec), 3)
    assert_equal(len(f.calls), 0)
    assert_equal(len(f.asked), 0)
    var r = _last(rec)
    assert_equal(r.error.id, String("KCI-E-NOT-ON-MAIN"))
    assert_true(r.error.message.find(String("stage 'prod' runs only on a push to main")) >= 0, r.error.message)
    assert_true(r.error.message.find(String("refs/heads/feature")) >= 0, r.error.message)
    # a push to another branch (its own workflow can add the trigger) too
    var push = Fake()
    _actions(push, m, String("refs/heads/feature"))
    var rec2 = CliRecorder.memory(String(""))
    assert_equal(kci_main_with(_publish(m, String("prod"), "--release-set-hash", _H), push, rec2), 3)
    assert_equal(_last(rec2).error.id, String("KCI-E-NOT-ON-MAIN"))


def test_a_manual_run_of_main_never_reaches_prod() raises:
    var m = _machine(_root(String("dispatchmain")))
    var f = Fake()
    _actions(f, m, String("refs/heads/main"), String("workflow_dispatch"))
    var rec = CliRecorder.memory(String(""))
    var a = _publish(m, String("prod"), "--release-set-hash", _H, "--context", "reason=ship it")
    assert_equal(kci_main_with(a, f, rec), 3)
    assert_equal(len(f.calls), 0)
    assert_equal(len(f.asked), 0)
    var r = _last(rec)
    assert_equal(r.error.id, String("KCI-E-NOT-ON-MAIN"))
    assert_true(r.error.message.find(String("this run is a workflow_dispatch of refs/heads/main")) >= 0, r.error.message)


def test_main_in_another_case_is_refused_for_every_stage() raises:
    var m = _machine(_root(String("case")))
    for stage in [String("prod"), String("gamma")]:
        var f = Fake()
        _actions(f, m, String("refs/heads/MAIN"))
        var rec = CliRecorder.memory(String(""))
        assert_equal(kci_main_with(_publish(m, stage, "--release-set-hash", _H, "--context", "reason=x"), f, rec), 3)
        assert_equal(len(f.calls), 0)
        assert_equal(_last(rec).error.id, String("KCI-E-NOT-ON-MAIN"))
        assert_true(_last(rec).error.message.find(String("main in another case")) >= 0, _last(rec).error.message)


def test_on_main_the_revision_is_the_push_and_on_mains_history() raises:
    var m = _machine(_root(String("onmain")))
    var f = Fake()
    _actions(f, m, String("refs/heads/main"))
    var rec = CliRecorder.memory(String(""))
    assert_equal(kci_main_with(_publish(m, String("prod"), "--release-set-hash", _H), f, rec), 0)
    assert_equal(len(f.asked), 1)
    # the FULL refname: a tag named `origin/main` would answer `origin/main`
    assert_equal(f.asked[0], String(_REV) + String(" on refs/remotes/origin/main"))
    # a push to main publishes from the stage's own environment
    assert_equal(f.environments[0], String("prod"))
    assert_false(f.break_glass[0])
    # not on main's history: refused, nothing published
    var no = Fake()
    _actions(no, m, String("refs/heads/main"))
    no.ancestor = False
    var rec2 = CliRecorder.memory(String(""))
    assert_equal(kci_main_with(_publish(m, String("prod"), "--release-set-hash", _H), no, rec2), 3)
    assert_equal(len(no.calls), 0)
    assert_equal(_last(rec2).error.id, String("KCI-E-NOT-ON-MAIN"))
    assert_true(_last(rec2).error.message.find(String("is not on main's history")) >= 0, _last(rec2).error.message)
    # a push whose revision is not the pushed commit: refused before history
    var other = Fake()
    _actions(other, m, String("refs/heads/main"))
    other.set_env(String("GITHUB_SHA"), String(_HEAD))
    var rec3 = CliRecorder.memory(String(""))
    assert_equal(kci_main_with(_publish(m, String("prod"), "--release-set-hash", _H), other, rec3), 3)
    assert_equal(len(other.asked), 0)
    assert_equal(_last(rec3).error.id, String("KCI-E-NOT-ON-MAIN"))
    assert_true(_last(rec3).error.message.find(String("a push to main releases the commit it pushed")) >= 0, _last(rec3).error.message)
    # a break_glass stage on a push to main is held the same way, and
    # publishes from its own environment, not as break-glass
    var bg = Fake()
    _actions(bg, m, String("refs/heads/main"))
    bg.ancestor = False
    var rec4 = CliRecorder.memory(String(""))
    assert_equal(kci_main_with(_publish(m, String("gamma"), "--release-set-hash", _H), bg, rec4), 3)
    assert_equal(_last(rec4).error.id, String("KCI-E-NOT-ON-MAIN"))
    var g = Fake()
    _actions(g, m, String("refs/heads/main"))
    var rec5 = CliRecorder.memory(String(""))
    assert_equal(kci_main_with(_publish(m, String("gamma"), "--release-set-hash", _H), g, rec5), 0)
    assert_equal(g.environments[0], String("gamma"))
    assert_false(g.break_glass[0])


def test_unreadable_history_is_cannot_tell() raises:
    var m = _machine(_root(String("shallow")))
    var f = Fake()
    _actions(f, m, String("refs/heads/main"))
    f.history_unreadable = True
    var rec = CliRecorder.memory(String(""))
    assert_equal(kci_main_with(_publish(m, String("prod"), "--release-set-hash", _H), f, rec), 5)
    assert_equal(len(f.calls), 0)
    assert_equal(_last(rec).error.id, String("KCI-E-CANNOT-TELL"))
    assert_true(_last(rec).error.message.find(String("shallow")) >= 0, _last(rec).error.message)
    # GITHUB_REF or GITHUB_EVENT_NAME unset: cannot tell either
    for name in [String("GITHUB_REF"), String("GITHUB_EVENT_NAME")]:
        var unset = Fake()
        _actions(unset, m, String("refs/heads/main"))
        unset.set_env(name, String(""))
        var rec2 = CliRecorder.memory(String(""))
        assert_equal(kci_main_with(_publish(m, String("prod"), "--release-set-hash", _H), unset, rec2), 5)
        assert_equal(len(unset.calls), 0)


# ---- (2) break-glass ---------------------------------------------------------------------


def test_break_glass_needs_a_reason() raises:
    var m = _machine(_root(String("bgreason")))
    var long = String("")
    for _ in range(201):
        long += String("x")
    # empty, whitespace only (trimmed, it says nothing), too long
    for reason in [String(""), String("   "), String(" "), long]:
        var f = Fake()
        _actions(f, m, String("refs/heads/hotfix"), String("workflow_dispatch"))
        var rec = CliRecorder.memory(String(""))
        var a = _publish(m, String("gamma"), "--release-set-hash", _H)
        a.append(String("--context"))
        a.append(String("reason=") + reason)
        assert_equal(kci_main_with(a, f, rec), 3)
        assert_equal(len(f.calls), 0)
        assert_equal(_last(rec).error.id, String("KCI-E-BREAK-GLASS-REASON"))
    # no reason at all; a push to another branch has none either
    for event in [String("workflow_dispatch"), String("push")]:
        var none = Fake()
        _actions(none, m, String("refs/heads/hotfix"), event)
        var rec2 = CliRecorder.memory(String(""))
        assert_equal(kci_main_with(_publish(m, String("gamma"), "--release-set-hash", _H), none, rec2), 3)
        assert_equal(_last(rec2).error.id, String("KCI-E-BREAK-GLASS-REASON"))
    # over one line: the command line's own grammar refuses it (exit 2)
    var lines = Fake()
    _actions(lines, m, String("refs/heads/hotfix"), String("workflow_dispatch"))
    var rec3 = CliRecorder.memory(String(""))
    assert_equal(kci_main_with(_publish(m, String("gamma"), "--release-set-hash", _H, "--context", "reason=a\nb"), lines, rec3), 2)
    assert_equal(len(lines.calls), 0)


def test_break_glass_with_a_reason_publishes_to_gamma_and_says_so() raises:
    var d = _root(String("bgok"))
    var m = _machine(d)
    # a branch, and main itself: every manual run is break-glass
    for ref_value in [String("refs/heads/hotfix"), String("refs/heads/main")]:
        var f = Fake()
        _actions(f, m, ref_value, String("workflow_dispatch"))
        var rec = CliRecorder.memory(String(""))
        var summary = d + String("/summary_") + String(ref_value.byte_length()) + String(".md")
        var a = _publish(m, String("gamma"), "--release-set-hash", _H, "--context", "reason=prod is down", "--summary-file")
        a.append(summary.copy())
        assert_equal(kci_main_with(a, f, rec), 0)
        assert_equal(len(f.calls), 1)
        assert_equal(f.calls[0], String("publish gamma"))
        # the break-glass environment, as break-glass
        assert_equal(f.environments[0], String("gamma-breakglass"))
        assert_true(f.break_glass[0])
        # the revision is held to the run's own commit, not to main
        assert_equal(f.asked[0], String(_REV) + String(" on ") + String(_REV))
        var text = Path(summary).read_text()
        assert_true(
            text.startswith(String("### BREAK-GLASS: ") + ref_value + String(" a1b2c3d4 by octocat: prod is down\n")), text
        )
        # gamma is break_glass: it says nothing about promotion
        assert_true(text.find(String("promoted to")) < 0, text)
    # a dry run's revision that is not on the run's commit's history is refused
    var off = Fake()
    _actions(off, m, String("refs/heads/main"), String("workflow_dispatch"))
    off.set_env(String("GITHUB_SHA"), String(_HEAD))
    off.ancestor = False
    var rec2 = CliRecorder.memory(String(""))
    assert_equal(
        kci_main_with(_publish(m, String("gamma"), "--release-set-hash", _H, "--context", "reason=x", "--plan"), off, rec2), 3
    )
    assert_equal(len(off.calls), 0)
    # a revision refusal, not a reason refusal: the run has a reason
    assert_equal(_last(rec2).error.id, String("KCI-E-BREAK-GLASS-REVISION"))
    assert_true(_last(rec2).error.message.find(String("is not on the history of the commit the run was started on")) >= 0, _last(rec2).error.message)


def test_a_publishing_break_glass_run_releases_its_own_commit() raises:
    # a manual run that can publish names no other revision: the workflow's
    # revision step refuses it first; kci refuses it too, before history
    var m = _machine(_root(String("bgrev")))
    for ref_value in [String("refs/heads/hotfix"), String("refs/heads/main")]:
        var f = Fake()
        _actions(f, m, ref_value, String("workflow_dispatch"))
        f.set_env(String("GITHUB_SHA"), String(_HEAD))
        var rec = CliRecorder.memory(String(""))
        assert_equal(kci_main_with(_publish(m, String("gamma"), "--release-set-hash", _H, "--context", "reason=x"), f, rec), 3)
        assert_equal(len(f.calls), 0)
        assert_equal(len(f.asked), 0)
        # a revision refusal, not a reason refusal: the run has a reason
        assert_equal(_last(rec).error.id, String("KCI-E-BREAK-GLASS-REVISION"))
        assert_true(_last(rec).error.message.find(String("another revision is for a dry run")) >= 0, _last(rec).error.message)
        # the same revision as a dry run: held to the run's commit's history
        var plan = Fake()
        _actions(plan, m, ref_value, String("workflow_dispatch"))
        plan.set_env(String("GITHUB_SHA"), String(_HEAD))
        var rec2 = CliRecorder.memory(String(""))
        assert_equal(
            kci_main_with(_publish(m, String("gamma"), "--release-set-hash", _H, "--context", "reason=x", "--plan"), plan, rec2),
            0,
        )
        assert_equal(plan.asked[0], String(_REV) + String(" on ") + String(_HEAD))
        assert_true(_last(rec2).plan)


# ---- (3) the set hash ----------------------------------------------------------------------


def test_the_set_hash_is_held() raises:
    var m = _machine(_root(String("hash")))
    # another set
    var f = Fake()
    _actions(f, m, String("refs/heads/main"))
    f.set_hash = String(_OTHER_H)
    var rec = CliRecorder.memory(String(""))
    assert_equal(kci_main_with(_publish(m, String("prod"), "--release-set-hash", _H), f, rec), 3)
    assert_equal(len(f.calls), 0)
    assert_equal(_last(rec).error.id, String("KCI-E-SET-HASH"))
    assert_true(_last(rec).error.message.find(String("recomputes to set hash ") + String(_OTHER_H)) >= 0, _last(rec).error.message)
    # a release directory that cannot be recomputed
    var bad = Fake()
    _actions(bad, m, String("refs/heads/main"))
    bad.release_refused = True
    var rec2 = CliRecorder.memory(String(""))
    assert_equal(kci_main_with(_publish(m, String("prod"), "--release-set-hash", _H), bad, rec2), 3)
    assert_equal(_last(rec2).error.id, String("KCI-E-SET-HASH"))
    # under GitHub Actions the flag is required
    var missing = Fake()
    _actions(missing, m, String("refs/heads/main"))
    var rec3 = CliRecorder.memory(String(""))
    assert_equal(kci_main_with(_publish(m, String("prod")), missing, rec3), 2)
    assert_equal(len(missing.calls), 0)
    # the same set: the result carries the recomputed hash
    var ok = Fake()
    _actions(ok, m, String("refs/heads/main"))
    var rec4 = CliRecorder.memory(String(""))
    assert_equal(kci_main_with(_publish(m, String("prod"), "--release-set-hash", _H), ok, rec4), 0)
    assert_equal(_last(rec4).set_hash, String(_H))
    # not 64 hex: the command line refuses it; on a BUILD stage it holds nothing
    var rec5 = CliRecorder.memory(String(""))
    var f5 = Fake()
    assert_equal(kci_main_with(_publish(m, String("prod"), "--release-set-hash", "abc"), f5, rec5), 2)


# ---- (4) never backward, (5) the prod line, (6) not under Actions ---------------------------


def test_only_a_main_only_stage_never_goes_backward() raises:
    var m = _machine(_root(String("back")))
    var f = Fake()
    var rec = CliRecorder.memory(String(""))
    assert_equal(kci_main_with(_publish(m, String("gamma")), f, rec), 0)
    assert_equal(kci_main_with(_publish(m, String("prod")), f, rec), 0)
    assert_equal(len(f.never_backward), 2)
    assert_false(f.never_backward[0])
    assert_true(f.never_backward[1])


def test_the_prod_line() raises:
    var d = _root(String("line"))
    var m = _machine(d)
    var cases = List[String]()
    cases.append(String("published"))
    cases.append(String("noop"))
    cases.append(String("plan"))
    for i in range(len(cases)):
        var f = Fake()
        var a = _publish(m, String("prod"), "--summary-file")
        var summary = d + String("/s_") + cases[i] + String(".md")
        a.append(summary.copy())
        if cases[i] == String("noop"):
            f.publish_outcome = String(OUTCOME_NOOP)
        if cases[i] == String("plan"):
            a.append(String("--plan"))
        var rec = CliRecorder.memory(String(""))
        assert_equal(kci_main_with(a, f, rec), 0)
        var text = Path(summary).read_text()
        var want = String("### promoted to prod: komira_encoding komira_all h01234567_3\n")
        if cases[i] == String("noop"):
            want = String("### promoted to prod: nothing new (h01234567_3 already there)\n")
        if cases[i] == String("plan"):
            want = String("### prod: PLAN ONLY (dry run)\n")
        assert_true(text.find(want) >= 0, cases[i] + String(": ") + text)


def test_not_under_actions_no_ref_is_checked() raises:
    var m = _machine(_root(String("local")))
    var f = Fake()
    f.ancestor = False
    var rec = CliRecorder.memory(String(""))
    assert_equal(kci_main_with(_publish(m, String("prod")), f, rec), 0)
    assert_equal(len(f.asked), 0)
    assert_equal(len(f.calls), 1)


# ---- (1b) a release run is never a dry run; (3b) only a validated set is handed on ---------------


def test_a_push_to_main_is_never_a_dry_run() raises:
    # kci on a push is built from main, so no workflow edit (a GITHUB_ENV
    # write of DRY_RUN, a shell assignment) can make a release run --plan
    var m = _machine(_root(String("noplan")))
    for stage in ["prod", "gamma"]:
        var f = Fake()
        _actions(f, m, String("refs/heads/main"))
        var rec = CliRecorder.memory(String(""))
        assert_equal(kci_main_with(_publish(m, String(stage), "--release-set-hash", _H, "--plan"), f, rec), 3)
        assert_equal(len(f.calls), 0)
        assert_equal(len(f.asked), 0)
        var r = _last(rec)
        assert_equal(r.error.id, String("KCI-E-PLAN-ON-RELEASE"))
        assert_true(r.error.message.find(String("a push to main is a release, never a dry run")) >= 0, r.error.message)
        assert_equal(r.set_hash, String(""))
    # a manual dry run of main is still a dry run (break-glass, gamma only)
    var d = Fake()
    _actions(d, m, String("refs/heads/main"), String("workflow_dispatch"))
    var rec2 = CliRecorder.memory(String(""))
    assert_equal(
        kci_main_with(_publish(m, String("gamma"), "--release-set-hash", _H, "--plan", "--context", "reason=check"), d, rec2), 0
    )


def _validate_only(m: String, *extra: String) -> List[String]:
    var a = List[String]()
    for s in ["run", "--machine"]:
        a.append(String(s))
    a.append(m.copy())
    for s in ["--stage", "gamma", "--revision-id"]:
        a.append(String(s))
    a.append(String(_REV))
    for s in ["--run-id", "gh-7", "--attempt", "1", "--release-dir", "/r", "--only", "validation:install"]:
        a.append(String(s))
    for s in ["--scratch-dir", "/s", "--release-set-hash"]:
        a.append(String(s))
    a.append(String(_H))
    for s in extra:
        a.append(String(s))
    return a^


def test_only_a_validated_run_hands_on_its_set_hash() raises:
    # kci.yml hands validate's result `set_hash` on to prod: it is there only
    # when every selected validation ran (not --plan) and SUCCEEDED
    var m = _machine(_root(String("vhash")), True)
    var ok = Fake()
    var rec = CliRecorder.memory(String(""))
    assert_equal(kci_main_with(_validate_only(m), ok, rec), 0)
    assert_equal(_last(rec).set_hash, String(_H))
    # a dry run validates nothing: no set hash, so prod (given "") refuses
    var plan = Fake()
    var rec2 = CliRecorder.memory(String(""))
    assert_equal(kci_main_with(_validate_only(m, "--plan"), plan, rec2), 0)
    assert_true(_last(rec2).plan)
    assert_equal(_last(rec2).set_hash, String(""))
    # a failed validation hands on nothing
    var bad = Fake()
    bad.validation_outcome = String(OUTCOME_VALIDATION_FAILED)
    var rec3 = CliRecorder.memory(String(""))
    assert_equal(kci_main_with(_validate_only(m, "--summary-file", _root(String("vhash")) + String("/s.md")), bad, rec3), 7)
    assert_equal(_last(rec3).set_hash, String(""))
    # a --plan publish recomputes and checks the set, and hands on nothing
    var pp = Fake()
    var rec4 = CliRecorder.memory(String(""))
    assert_equal(kci_main_with(_publish(m, String("prod"), "--release-set-hash", _H, "--plan"), pp, rec4), 0)
    assert_equal(_last(rec4).set_hash, String(""))


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
