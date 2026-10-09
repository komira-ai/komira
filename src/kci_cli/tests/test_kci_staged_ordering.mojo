# =============================================================================
# src/kci_cli/tests/test_kci_staged_ordering.mojo -- ordering safety of the
#   staged pipeline (design P1) as `kci run` holds it, over a recording fake
#   of the seam and, for the git reads, a scripted git. Rows of the design's
#   table c; each names the mutant that turns it red.
#
#   (c1) never backward is the RUN's: a push to main never goes backward at
#        gamma (a break_glass stage, so its rule counts main-line builds
#        only) nor at prod; a break-glass run of gamma may. Mutant: "restore
#        `not stage.break_glass`" (gamma's push request says false);
#   (s)  a PUBLISH step that ends SUPERSEDED stops the run SUPERSEDED, exit
#        0: its validation NOT_REACHED and never run, no set hash handed on,
#        and the summary says `superseded: gamma did nothing for ...`;
#   (c7) THE ADMISSION CHECK (`--admission`, R24): a push re-run (attempt 2)
#        of a revision main has moved past stops SUPERSEDED at EVERY stage
#        before any step runs. Mutant: "drop R24's check";
#   (c8) the same re-run of main's releasable tip proceeds (the seam says
#        ""; the git read counts only commits a push releases, so main
#        moved by docs alone is still the tip: (g1) below). Mutant:
#        "compare to the raw tip" (g1);
#   (c9) a push FIRST attempt of build (the first stage) of such a revision
#        stops SUPERSEDED. Mutant: "check re-runs only";
#   (c10) a push first attempt of gamma of such a revision proceeds, and
#        main is not even asked. Mutant: "check every first attempt";
#   (a)  an attempt that cannot be read, or a main git cannot read, is exit
#        5 (KCI-E-CANNOT-TELL), nothing run; without `--admission`, or on a
#        break-glass run, nothing is asked;
#   (g1) `git_main_tip_past` over a scripted git: shallow check, the fetch
#        of main, main's tip, then the first-parent commits after the
#        revision that touch anything but docs/** and *.md: none -> "";
#        one -> the tip; the tip itself -> "" without the count; a shallow
#        clone or a failed fetch raises;
#   (g2) `git_commit_of` (the split's rev-parse --verify): one id; an
#        unknown or ambiguous prefix (git exits 1) or a shallow clone
#        raises (design row c6, git half); `git_main_line`: the fetch, then
#        main's history.
# =============================================================================

from std.ffi import external_call
from std.os import makedirs
from std.pathlib import Path
from std.testing import TestSuite, assert_equal, assert_false, assert_true

from komira_libc.posix import _read_env

from kci_build import BuildRequest, ScriptedRunner, ScriptedStep
from kci_cli import (
    CliRecorder,
    SecretStoreChoice,
    StageSteps,
    StepEnd,
    git_commit_of,
    git_main_line,
    git_main_tip_past,
    kci_main_with,
    write_whole_file,
)
from kci_api import (
    OUTCOME_SUCCEEDED,
    OUTCOME_SUPERSEDED,
    VALIDATION_NOT_REACHED,
    ResultStep,
    ResultValidation,
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
    """Every step SUCCEEDED (a publish `publish_outcome`); the platform
    variables from `env`, the committed workflow from `workflow`;
    `is_ancestor` answers True; `main_tip_past` answers `tip` (or raises
    when `tip_unreadable`) and records each question in `tip_asked`; each
    publish request's never_backward and main_line_only are recorded.
    Layout: owned values only. No pointer field."""

    var calls: List[String]
    var tip_asked: List[String]
    var never_backward: List[Bool]
    var main_line_only: List[Bool]
    var env_names: List[String]
    var env_values: List[String]
    var workflow: String
    var tip: String
    var tip_unreadable: Bool
    var publish_outcome: String

    def __init__(out self):
        self.calls = List[String]()
        self.tip_asked = List[String]()
        self.never_backward = List[Bool]()
        self.main_line_only = List[Bool]()
        self.env_names = List[String]()
        self.env_values = List[String]()
        self.workflow = String("")
        self.tip = String("")
        self.tip_unreadable = False
        self.publish_outcome = String(OUTCOME_SUCCEEDED)

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
        self.main_line_only.append(req.main_line_only)
        result.steps.append(ResultStep(req.step_name.copy(), String("PUBLISH"), req.platform.copy(), self.publish_outcome.copy()))
        return StepEnd(self.publish_outcome.copy(), String(""), String(""))

    def validate(mut self, req: ValidateRequest) -> ResultValidation:
        self.calls.append(String("validate ") + req.validation.name)
        return ResultValidation(
            req.validation.name.copy(), req.step_name.copy(), req.validation.kind.copy(), String("VALIDATED"),
            String(OUTCOME_SUCCEEDED),
        )

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
        return True

    def main_tip_past(mut self, revision: String) raises -> String:
        self.tip_asked.append(revision.copy())
        if self.tip_unreadable:
            raise Error(String("`git fetch origin main` exited 128"))
        return self.tip.copy()

    def release_set_hash(mut self, artifacts_file: String, platform_dir: String) raises -> String:
        return String(_H)


def _root(tag: String) raises -> String:
    var base = _read_env("TEST_TMPDIR")
    if base.byte_length() == 0:
        base = _read_env("TMPDIR")
    if base.byte_length() == 0:
        raise Error("neither TEST_TMPDIR nor TMPDIR is set")
    var d = base + String("/kci_ord_") + tag + String("_") + String(Int(external_call["getpid", Int32]()))
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


def _args(m: String, stage: String, attempt: String, *extra: String) -> List[String]:
    """`kci run` of `stage` with the flags its steps take."""
    var a = List[String]()
    for s in ["run", "--machine"]:
        a.append(String(s))
    a.append(m.copy())
    a.append(String("--stage"))
    a.append(stage.copy())
    a.append(String("--revision-id"))
    a.append(String(_REV))
    for s in ["--run-id", "gh-7", "--attempt"]:
        a.append(String(s))
    a.append(attempt.copy())
    for s in ["--release-dir", "/r"]:
        a.append(String(s))
    if stage == String("build"):
        for s in ["--work-dir", "/w", "--log-dir", "/l"]:
            a.append(String(s))
    else:
        for s in ["--release-version", "rv", "--release-set-hash"]:
            a.append(String(s))
        a.append(String(_H))
    for s in extra:
        a.append(String(s))
    return a^


def _push(mut f: Fake, m: String, attempt: String):
    """A push to main, attempt `attempt` (the platform-set variable)."""
    _actions(f, m, String("refs/heads/main"))
    f.set_env(String("GITHUB_RUN_ATTEMPT"), attempt)


def _last(rec: CliRecorder) raises -> KciRunResult:
    return parse_result(rec.records[len(rec.records) - 1], String("record"))


# ---- (c1) never backward is the run's -----------------------------------------------


def test_c1_a_push_never_goes_backward_at_gamma_and_prod() raises:
    var m = _machine(_root(String("c1")))
    var f = Fake()
    _push(f, m, String("1"))
    var rec = CliRecorder.memory(String(""))
    assert_equal(kci_main_with(_args(m, String("gamma"), String("1")), f, rec), 0)
    assert_equal(kci_main_with(_args(m, String("prod"), String("1")), f, rec), 0)
    assert_equal(len(f.never_backward), 2)
    assert_true(f.never_backward[0], String("a push to gamma must never go backward"))
    assert_true(f.never_backward[1])
    # gamma's channel also takes break-glass builds: its rule counts main's only
    assert_true(f.main_line_only[0])
    assert_false(f.main_line_only[1])
    # a break-glass run of gamma may go backward
    var bg = Fake()
    _actions(bg, m, String("refs/heads/feature"), String("workflow_dispatch"))
    var rec2 = CliRecorder.memory(String(""))
    assert_equal(kci_main_with(_args(m, String("gamma"), String("1"), "--context", "reason=hotfix"), bg, rec2), 0)
    assert_equal(len(bg.never_backward), 1)
    assert_false(bg.never_backward[0])


# ---- (s) a superseded publish stops the run green ------------------------------------


def test_a_superseded_publish_stops_the_run_with_exit_0() raises:
    var d = _root(String("sup"))
    var m = _machine(d, True)
    # not under GitHub Actions: what the run does after the step is the
    # dispatcher's, whoever asked the step to stop (a push's gamma job runs
    # its validations in a job of their own)
    var f = Fake()
    f.publish_outcome = String(OUTCOME_SUPERSEDED)
    var rec = CliRecorder.memory(String(""))
    var summary = d + String("/s.md")
    var a = _args(m, String("gamma"), String("1"), "--scratch-dir", "/s", "--summary-file")
    a.append(summary.copy())
    assert_equal(kci_main_with(a, f, rec), 0)
    var r = _last(rec)
    assert_equal(r.outcome, String(OUTCOME_SUPERSEDED))
    assert_equal(r.exit_code, 0)
    # nothing after the step ran, and nothing is handed on
    assert_equal(len(f.calls), 1)
    assert_equal(f.calls[0], String("publish gamma"))
    assert_equal(len(r.validations), 1)
    assert_equal(r.validations[0].effect, String(VALIDATION_NOT_REACHED))
    assert_equal(r.set_hash, String(""))
    var text = Path(summary).read_text()
    assert_true(text.find(String("### superseded: gamma did nothing for a1b2c3d4: step 'publish'")) >= 0, text)
    # a stage with no validation (prod): the set its start-up check recomputed
    # is not handed on either
    var p = Fake()
    p.publish_outcome = String(OUTCOME_SUPERSEDED)
    var rec2 = CliRecorder.memory(String(""))
    assert_equal(kci_main_with(_args(m, String("prod"), String("1")), p, rec2), 0)
    assert_equal(_last(rec2).outcome, String(OUTCOME_SUPERSEDED))
    assert_equal(_last(rec2).set_hash, String(""))


# ---- (c7) to (c10), (a) the admission check -------------------------------------------


def test_c7_a_rerun_of_a_superseded_revision_stops_at_every_stage() raises:
    var d = _root(String("c7"))
    var m = _machine(d)
    for stage in ["build", "gamma", "prod"]:
        var f = Fake()
        _push(f, m, String("2"))
        f.tip = String(_HEAD)
        var rec = CliRecorder.memory(String(""))
        var summary = d + String("/c7_") + String(stage) + String(".md")
        var a = _args(m, String(stage), String("2"), "--admission", "--summary-file")
        a.append(summary.copy())
        assert_equal(kci_main_with(a, f, rec), 0, String(stage))
        assert_equal(len(f.calls), 0, String(stage) + String(": a step ran"))
        assert_equal(len(f.tip_asked), 1, String(stage))
        assert_equal(f.tip_asked[0], String(_REV))
        var r = _last(rec)
        assert_equal(r.outcome, String(OUTCOME_SUPERSEDED), String(stage))
        assert_equal(len(r.steps), 0, String(stage))
        assert_equal(r.set_hash, String(""))
        var text = Path(summary).read_text()
        assert_true(text.find(String("### superseded: ") + String(stage) + String(" did nothing for a1b2c3d4")) >= 0, text)
        assert_true(text.find(String("main is at ") + String(_HEAD)) >= 0, text)


def test_c8_a_rerun_of_mains_releasable_tip_proceeds() raises:
    var m = _machine(_root(String("c8")))
    for stage in ["build", "gamma", "prod"]:
        var f = Fake()
        _push(f, m, String("2"))
        f.tip = String("")
        var rec = CliRecorder.memory(String(""))
        assert_equal(kci_main_with(_args(m, String(stage), String("2"), "--admission"), f, rec), 0, String(stage))
        assert_equal(len(f.tip_asked), 1, String(stage))
        assert_equal(len(f.calls), 1, String(stage))
        assert_equal(_last(rec).outcome, String(OUTCOME_SUCCEEDED), String(stage))


def test_c9_a_first_build_of_a_superseded_revision_stops() raises:
    var m = _machine(_root(String("c9")))
    var f = Fake()
    _push(f, m, String("1"))
    f.tip = String(_HEAD)
    var rec = CliRecorder.memory(String(""))
    assert_equal(kci_main_with(_args(m, String("build"), String("1"), "--admission"), f, rec), 0)
    assert_equal(len(f.calls), 0, String("the build ran"))
    assert_equal(len(f.tip_asked), 1)
    assert_equal(_last(rec).outcome, String(OUTCOME_SUPERSEDED))


def test_c10_a_first_attempt_after_build_proceeds_unasked() raises:
    var m = _machine(_root(String("c10")))
    for stage in ["gamma", "prod"]:
        var f = Fake()
        _push(f, m, String("1"))
        f.tip = String(_HEAD)
        var rec = CliRecorder.memory(String(""))
        assert_equal(kci_main_with(_args(m, String(stage), String("1"), "--admission"), f, rec), 0, String(stage))
        assert_equal(len(f.tip_asked), 0, String(stage) + String(": main was asked"))
        assert_equal(len(f.calls), 1, String(stage))
        assert_equal(_last(rec).outcome, String(OUTCOME_SUCCEEDED), String(stage))


def test_a_admission_that_cannot_tell_is_exit_5() raises:
    var m = _machine(_root(String("acannot")))
    # git cannot read main
    var f = Fake()
    _push(f, m, String("2"))
    f.tip_unreadable = True
    var rec = CliRecorder.memory(String(""))
    assert_equal(kci_main_with(_args(m, String("gamma"), String("2"), "--admission"), f, rec), 5)
    assert_equal(len(f.calls), 0)
    var r = _last(rec)
    assert_equal(r.error.id, String("KCI-E-CANNOT-TELL"))
    assert_true(r.error.message.find(String("exited 128")) >= 0, r.error.message)
    # no attempt to read
    var n = Fake()
    _push(n, m, String(""))
    var rec2 = CliRecorder.memory(String(""))
    assert_equal(kci_main_with(_args(m, String("build"), String("1"), "--admission"), n, rec2), 5)
    assert_equal(len(n.calls), 0)
    assert_equal(len(n.tip_asked), 0)
    assert_equal(_last(rec2).error.id, String("KCI-E-CANNOT-TELL"))


def test_a_admission_is_asked_only_when_given_on_a_push() raises:
    var m = _machine(_root(String("aonly")))
    # without --admission: a re-run of a superseded revision runs (today's kci.yml)
    var f = Fake()
    _push(f, m, String("2"))
    f.tip = String(_HEAD)
    var rec = CliRecorder.memory(String(""))
    assert_equal(kci_main_with(_args(m, String("gamma"), String("2")), f, rec), 0)
    assert_equal(len(f.tip_asked), 0)
    assert_equal(len(f.calls), 1)
    # a break-glass run is not a push run: nothing to admit
    var bg = Fake()
    _actions(bg, m, String("refs/heads/feature"), String("workflow_dispatch"))
    bg.set_env(String("GITHUB_RUN_ATTEMPT"), String("2"))
    bg.tip = String(_HEAD)
    var rec2 = CliRecorder.memory(String(""))
    assert_equal(
        kci_main_with(_args(m, String("gamma"), String("2"), "--admission", "--context", "reason=hotfix"), bg, rec2), 0
    )
    assert_equal(len(bg.tip_asked), 0)
    assert_equal(len(bg.calls), 1)


# ---- (g1), (g2) the git reads ---------------------------------------------------------


def _argv(*xs: String) -> List[String]:
    var l = List[String]()
    for x in xs:
        l.append(String(x))
    return l^


def _shallow(answer: String) -> ScriptedStep:
    return ScriptedStep(_argv("rev-parse", "--is-shallow-repository"), stdout_text=answer)


def _fetch(code: Int) -> ScriptedStep:
    return ScriptedStep(
        _argv("fetch", "--quiet", "--no-tags", "origin", "+refs/heads/main:refs/remotes/origin/main"), exit_code=Int32(code)
    )


def _tip(commit: String) -> ScriptedStep:
    return ScriptedStep(
        _argv("rev-parse", "--verify", "--quiet", "refs/remotes/origin/main^{commit}"), stdout_text=commit + String("\n")
    )


def _count(printed: String) -> ScriptedStep:
    return ScriptedStep(
        _argv(
            "rev-list", "--first-parent", "--max-count=1", String(_REV) + String("..") + String(_HEAD), "--", ".",
            ":(exclude)docs", ":(exclude)*.md",
        ),
        stdout_text=printed,
    )


def test_g1_main_tip_past_counts_only_what_a_push_releases() raises:
    var d = _root(String("g1"))
    # main moved past the revision by docs only: still the releasable tip
    var docs = ScriptedRunner()
    docs.expect(_shallow(String("false\n")))
    docs.expect(_fetch(0))
    docs.expect(_tip(String(_HEAD)))
    docs.expect(_count(String("")))
    assert_equal(git_main_tip_past(docs, d, String(_REV)), String(""))
    assert_equal(docs.remaining(), 0)
    # a commit a push releases lies after it: main's tip
    var code = ScriptedRunner()
    code.expect(_shallow(String("false\n")))
    code.expect(_fetch(0))
    code.expect(_tip(String(_HEAD)))
    code.expect(_count(String(_HEAD) + String("\n")))
    assert_equal(git_main_tip_past(code, d, String(_REV)), String(_HEAD))
    # the revision is main's tip: nothing to count
    var same = ScriptedRunner()
    same.expect(_shallow(String("false\n")))
    same.expect(_fetch(0))
    same.expect(_tip(String(_REV)))
    assert_equal(git_main_tip_past(same, d, String(_REV)), String(""))
    assert_equal(same.remaining(), 0)
    # a shallow clone, or a fetch that fails: raised, never ""
    var shallow = ScriptedRunner()
    shallow.expect(_shallow(String("true\n")))
    var why = String("<answered>")
    try:
        _ = git_main_tip_past(shallow, d, String(_REV))
    except e:
        why = String(e)
    assert_true(why.find(String("shallow")) >= 0, why)
    for c in [1, 128]:
        var nofetch = ScriptedRunner()
        nofetch.expect(_shallow(String("false\n")))
        nofetch.expect(_fetch(c))
        var why2 = String("<answered>")
        try:
            _ = git_main_tip_past(nofetch, d, String(_REV))
        except e:
            why2 = String(e)
        assert_true(why2 != String("<answered>"), String("a failed fetch answered"))


def test_g2_commit_of_and_main_line() raises:
    var d = _root(String("g2"))
    var verify = _argv("rev-parse", "--verify", "--quiet", "89abcdef^{commit}")
    var full = String("89abcdef00000000000000000000000000000000")
    var ok = ScriptedRunner()
    ok.expect(_shallow(String("false\n")))
    ok.expect(ScriptedStep(verify.copy(), stdout_text=full + String("\n")))
    assert_equal(git_commit_of(ok, d, String("89abcdef")), full)
    # unknown or ambiguous: git exits 1 under --quiet; raised, never an id
    var amb = ScriptedRunner()
    amb.expect(_shallow(String("false\n")))
    amb.expect(ScriptedStep(verify.copy(), exit_code=Int32(1), stderr_text=String("error: short object ID 89abcdef is ambiguous")))
    var why = String("<answered>")
    try:
        _ = git_commit_of(amb, d, String("89abcdef"))
    except e:
        why = String(e)
    assert_true(why.find(String("names no commit of this checkout, or more than one")) >= 0, why)
    var shallow = ScriptedRunner()
    shallow.expect(_shallow(String("true\n")))
    var why2 = String("<answered>")
    try:
        _ = git_commit_of(shallow, d, String("89abcdef"))
    except e:
        why2 = String(e)
    assert_true(why2.find(String("shallow")) >= 0, why2)
    # main's history, after the fetch
    var mainr = ScriptedRunner()
    mainr.expect(_shallow(String("false\n")))
    mainr.expect(_fetch(0))
    mainr.expect(ScriptedStep(_argv("rev-list", "refs/remotes/origin/main"), stdout_text=String(_HEAD) + String("\n") + String(_REV) + String("\n")))
    var history = git_main_line(mainr, d)
    assert_equal(len(history), 2)
    assert_equal(history[0], String(_HEAD))
    assert_equal(mainr.remaining(), 0)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
