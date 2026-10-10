# =============================================================================
# src/kci_cli/tests/test_kci_dispatch.mojo -- `kci run --stage S`, kci's
#   one command, over a recording fake of the seam, through `kci_main_with`:
#   which steps run, in which order, with which request; where the run stops;
#   the run's outcome and exit number; the records the recorder got; `--only`
#   (a SELECTIVE run, never reported as FULL) and `--plan`; `--affected-by`
#   (a pull request's BUILD: the base reaches the step, the run is SELECTIVE,
#   a publishing stage refuses it).
#
# The same run over the same fake, split by subject (each file is one gated
# test built from its one file, so each carries its own copy of `FakeSteps`
# and of the helpers it uses):
#   test_kci_dispatch_workflow.mojo     the start-up workflow check and the
#                                       `--channel` refusals
#   test_kci_dispatch_validations.mojo  validations, NEW NAMES, the summary
# =============================================================================

from std.ffi import external_call
from std.os import makedirs
from std.pathlib import Path
from std.time import perf_counter_ns
from std.testing import TestSuite, assert_equal, assert_false, assert_true

from komira_libc.posix import _read_env

from kci_build import BuildRequest
from kci_cli import CliRecorder, SecretStoreChoice, StageSteps, StepEnd, kci_main_with, write_whole_file
from kci_api import (
    ERROR_BUILD_FAILED,
    ERROR_PUBLISH_DIFFERENT_BYTES,
    OUTCOME_FAILED,
    OUTCOME_INDETERMINATE,
    OUTCOME_NOOP,
    OUTCOME_REFUSED,
    OUTCOME_SUCCEEDED,
    OUTCOME_SUPERSEDED,
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
    var budgets: List[Int]
    var deadlines: List[Int]

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
        self.budgets = List[Int]()
        self.deadlines = List[Int]()

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
        self.budgets.append(req.build_budget_s)
        self.deadlines.append(req.build_deadline_ns)
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
        + String(" channels: \"c.textproto\" channel: \"komira\" } step { name: \"b\" kind: BUILD platform: \"linux-x86_64\" artifacts: \"d.textproto\" } }\n")
        + String("stage { name: \"pub-twice\" step { name: \"p\" kind: PUBLISH platform: \"linux-x86_64\" artifacts: \"d.textproto\"")
        + String(" channels: \"c.textproto\" channel: \"komira\" } step { name: \"p2\" kind: PUBLISH platform: \"linux-x86_64\"")
        + String(" artifacts: \"d.textproto\" channels: \"c.textproto\" channel: \"komira\" } }\n"),
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


def test_superseded_after_a_publish_changed_the_channel_is_partial() raises:
    # the first PUBLISH step landed an upload; the second ends SUPERSEDED
    # (its channel already holds a descendant): the upload stands, so the
    # stage is PARTIAL, exit 6, never SUPERSEDED exit 0. Mutant: "drop
    # SUPERSEDED from the PARTIAL guard"
    var m = _machine(_root(String("suppartial")))
    var steps = FakeSteps()
    var landed = StepEnd(String(OUTCOME_SUCCEEDED), String(""), String(""))
    landed.changed_outside = True
    steps.ends.append(landed^)
    steps.ends.append(StepEnd(String(OUTCOME_SUPERSEDED), String(""), String("")))
    var rec = CliRecorder.memory(String(""))
    var a = _run(m, String("pub-twice"))
    a.extend(_publish_flags())
    assert_equal(kci_main_with(a, steps, rec), 6)
    assert_equal(len(steps.calls), 2)
    var r = _last(rec)
    assert_equal(r.outcome, String("PARTIAL"))
    assert_equal(r.retry, String("UNSAFE"))
    # nothing landed before it: SUPERSEDED, exit 0
    var none = FakeSteps()
    none.ends.append(StepEnd(String(OUTCOME_SUPERSEDED), String(""), String("")))
    var rec2 = CliRecorder.memory(String(""))
    var a2 = _run(m, String("pub-twice"))
    a2.extend(_publish_flags())
    assert_equal(kci_main_with(a2, none, rec2), 0)
    assert_equal(len(none.calls), 1)
    assert_equal(_last(rec2).outcome, String("SUPERSEDED"))


def test_unknown_stage_is_refused_listing_the_stages() raises:
    var m = _machine(_root(String("unknown")))
    var steps = FakeSteps()
    var rec = CliRecorder.memory(String(""))
    assert_equal(kci_main_with(_run(m, String("staging")), steps, rec), 3)
    assert_equal(len(steps.calls), 0)
    assert_equal(len(rec.statuses), 1)
    var r = _last(rec)
    assert_equal(r.error.id, String("KCI-E-STAGE-UNKNOWN"))
    assert_true(r.error.message.find(String("its stages: build, prod, all, pub-then-build, pub-twice")) >= 0, r.error.message)


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
    write_whole_file(bad, String("schema_version: 1\nstage { name: \"x\" step { name: \"d\" kind: VALIDATE platform: \"linux-x86_64\" artifacts: \"d\" } }\n"))
    assert_equal(kci_main_with(_run(bad, String("x")), steps, rec), 3)
    assert_equal(_last(rec).error.id, String("KCI-E-FORMAT"))
    # a valid DEPLOY step, and a valid PUBLISH into a cell: parsed, never run
    var cell_steps = List[String]()
    cell_steps.append(String("kind: DEPLOY cells: \"c\" cell: \"s\" resources: \"r.json\""))
    cell_steps.append(String("kind: PUBLISH platform: \"linux-x86_64\" artifacts: \"a\" cells: \"c\" cell: \"s\""))
    for i in range(len(cell_steps)):
        write_whole_file(bad, String("schema_version: 1\nname: \"m\"\nstage { name: \"x\" step { name: \"d\" ") + cell_steps[i] + String(" } }\n"))
        var a = _run(bad, String("x"))
        a.extend(_publish_flags())
        assert_equal(kci_main_with(a, steps, rec), 3)
        assert_equal(_last(rec).error.id, String("KCI-E-FORMAT"))
        assert_true(_last(rec).error.message.find(String("writes into cell 's': that needs a newer kci")) >= 0)
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


def test_the_build_budget_reaches_the_per_change_check() raises:
    # --build-budget-s is handed to the BUILD step as is; without it the
    # step has no budget (kci_build NO_BUILD_BUDGET, 0)
    var m = _machine(_root(String("budget")))
    var steps = FakeSteps()
    var rec = CliRecorder.memory(String(""))
    var a = _pr_run(m, String("build"), "--build-budget-s", "6543")
    a.extend(_build_flags())
    var t0 = Int(perf_counter_ns())
    assert_equal(kci_main_with(a, steps, rec), 0)
    var t1 = Int(perf_counter_ns())
    assert_equal(len(steps.budgets), 1)
    assert_equal(steps.budgets[0], 6543)
    # the deadline is kci's start (inside the call) plus the budget, on the
    # monotonic clock the runner reads
    var start = steps.deadlines[0] - 6543 * 1_000_000_000
    assert_true(start >= t0 and start <= t1, String(t0) + String(" ") + String(start) + String(" ") + String(t1))
    var none = FakeSteps()
    var rec2 = CliRecorder.memory(String(""))
    var b = _pr_run(m, String("build"))
    b.extend(_build_flags())
    assert_equal(kci_main_with(b, none, rec2), 0)
    assert_equal(none.budgets[0], 0)
    assert_equal(none.deadlines[0], 0)


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
