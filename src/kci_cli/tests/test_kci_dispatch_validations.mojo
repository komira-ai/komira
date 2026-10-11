# =============================================================================
# src/kci_cli/tests/test_kci_dispatch_validations.mojo -- `kci run --stage S`
#   over the recording fake (test_kci_dispatch.mojo): a step's validations
#   after it in a FULL run, none under `--only step:`, one alone under
#   `--only validation:`, a failed one VALIDATION_FAILED (exit 7), no network
#   INDETERMINATE (exit 5), one after a failed step NOT_REACHED; the NEW
#   NAMES of the stages after this one; and the `--summary-file` block.
# =============================================================================

from std.ffi import external_call
from std.os import makedirs
from std.pathlib import Path
from std.testing import TestSuite, assert_equal, assert_false, assert_true

from komira_libc.posix import _read_env

from kci_build import BuildRequest
from kci_cli import CliRecorder, SecretStoreChoice, StageSteps, StepEnd, kci_main_with, write_whole_file
from kci_api import (
    ERROR_PUBLISH_DIFFERENT_BYTES,
    OUTCOME_FAILED,
    OUTCOME_INDETERMINATE,
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
comptime _SET_HASH: String = "5e7a5e7a5e7a5e7a5e7a5e7a5e7a5e7a5e7a5e7a5e7a5e7a5e7a5e7a5e7a5e7a"


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

    def main_tip_past(mut self, revision: String) raises -> String:
        # no run here passes --admission (test_kci_staged_ordering.mojo does)
        raise Error(String("main_tip_past is not asked in this test"))

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


def _gamma(m: String, *extra: String) -> List[String]:
    var a = _run(m, String("gamma"))
    for s in ["--release-version", "rv", "--release-set-hash"]:
        a.append(String(s))
    a.append(String(_SET_HASH))
    for s in extra:
        a.append(String(s))
    return a^


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


def test_a_passed_validation_summary_states_each_check() raises:
    # The summary names what a passing validation found, not only what a
    # failing one did: each check's first row (the channel's says how long
    # the index was waited for, and over how many polls).
    var d = _root(String("valpass"))
    var m = _release_machine(d, True)
    var steps = FakeSteps()
    var rec = CliRecorder.memory(String(""))
    var summary = d + String("/summary.md")
    assert_equal(
        kci_main_with(_run(m, String("gamma"), "--only", "validation:install", "--scratch-dir", "/s", "--summary-file", summary), steps, rec),
        0,
    )
    var text = Path(summary).read_text()
    assert_true(text.find(String("| install | publish | SUCCEEDED |")) >= 0, text)
    assert_true(text.find(String("| | | ok: `channel: answered 200; waited 60 of 1800 s over 5 polls` |")) >= 0, text)
    assert_true(text.find(String("| | | ok: `program: ran 61 checks, all passed` |")) >= 0, text)
    # a second row of a check already shown is not repeated
    assert_equal(text.find(String("a second channel row")), -1, text)


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


comptime _PIXI_SHA: String = "807eabf195b13d6393b832ecccf93bf59bf784425674a60c7b50b1b84a58367f"


def test_an_env_validation_needs_the_pinned_pixi() raises:
    var m = _release_machine(_root(String("envflags")), False, True)
    var steps = FakeSteps()
    var rec = CliRecorder.memory(String(""))
    # without --pixi: a usage error naming the flag, nothing run
    assert_equal(
        kci_main_with(_run(m, String("gamma"), "--only", "validation:install-env", "--scratch-dir", "/s"), steps, rec),
        2,
    )
    assert_true(_last(rec).error.message.find(String("selects the CONDA_INSTALL_ENV validation 'install-env': kci run needs --pixi")) >= 0, _last(rec).error.message)
    assert_equal(len(steps.validated), 0)
    # with both, the request carries them
    var ok = FakeSteps()
    var rec2 = CliRecorder.memory(String(""))
    assert_equal(
        kci_main_with(
            _run(m, String("gamma"), "--only", "validation:install-env", "--scratch-dir", "/s", "--pixi", "/t/pixi", "--pixi-sha256", String(_PIXI_SHA)),
            ok, rec2,
        ),
        0,
    )
    assert_equal(len(ok.pixis), 1)
    assert_equal(ok.pixis[0], String("install-env pixi=/t/pixi sha=") + String(_PIXI_SHA))


def test_pixi_flags_are_refused_where_no_env_validation_runs() raises:
    var m = _release_machine(_root(String("envrefused")), True, True)
    var steps = FakeSteps()
    var rec = CliRecorder.memory(String(""))
    assert_equal(
        kci_main_with(
            _run(m, String("gamma"), "--only", "validation:install", "--scratch-dir", "/s", "--pixi", "/t/pixi", "--pixi-sha256", String(_PIXI_SHA)),
            steps, rec,
        ),
        2,
    )
    assert_true(_last(rec).error.message.find(String("--pixi is a CONDA_INSTALL_ENV validation's flag")) >= 0, _last(rec).error.message)
    assert_equal(len(steps.validated), 0)


def test_no_network_is_exit_5_never_a_pass() raises:
    var d = _root(String("envskip"))
    var m = _release_machine(d, False, True)
    var steps = FakeSteps()
    steps.validation_skips = True
    var rec = CliRecorder.memory(String(""))
    var summary = d + String("/summary.md")
    assert_equal(
        kci_main_with(
            _run(
                m, String("gamma"), "--only", "validation:install-env", "--scratch-dir", "/s", "--pixi", "/t/pixi",
                "--pixi-sha256", String(_PIXI_SHA), "--summary-file", summary,
            ),
            steps, rec,
        ),
        5,
    )
    var r = _last(rec)
    assert_equal(r.outcome, String(OUTCOME_INDETERMINATE))
    assert_equal(r.validations[0].outcome, String(OUTCOME_INDETERMINATE))
    assert_true(r.validations[0].skip_reason.startswith(String("no network")))
    assert_true(
        r.error.message.find(String("validation 'install-env' of step 'publish' could not run (INDETERMINATE, never a pass): no network")) >= 0,
        r.error.message,
    )
    # a run that could not tell reads no later stage's names
    assert_equal(len(steps.reads), 0)
    var text = Path(summary).read_text()
    assert_true(text.find(String("| install-env | publish | INDETERMINATE |")) >= 0, text)


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


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
