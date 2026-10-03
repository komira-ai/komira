# =============================================================================
# src/kci_cli/tests/test_kci_dispatch.mojo -- `kci run --stage S` over a
#   recording fake of the steps, and `kci ci check`, through `kci_main_with`:
#   which steps run, in which order, with which request; where the run stops;
#   the run's outcome and exit number; the records the recorder got; and
#   `--only` (a SELECTIVE run, never reported as FULL) and `--plan`.
# =============================================================================

from std.ffi import external_call
from std.os import makedirs
from std.testing import TestSuite, assert_equal, assert_false, assert_true

from komira_libc.posix import _read_env

from kci_build import BuildRequest
from kci_cli import CliRecorder, SecretStoreChoice, StageSteps, StepEnd, kci_main_with, write_whole_file
from kci_contract import (
    ERROR_BUILD_FAILED,
    ERROR_PUBLISH_DIFFERENT_BYTES,
    OUTCOME_FAILED,
    OUTCOME_NOOP,
    OUTCOME_REFUSED,
    OUTCOME_SUCCEEDED,
    ResultStep,
    parse_result,
)
from kci_contract import RunResult as KciRunResult
from kci_publish import PublishRequest

comptime _REV: String = "a1b2c3d4e5f60718293a4b5c6d7e8f9012345678"


struct FakeSteps(StageSteps, Movable):
    """Answers each step from `ends`, in order, and records the call.
    Layout: owned values only. No pointer field."""

    var calls: List[String]
    var ends: List[StepEnd]

    def __init__(out self):
        self.calls = List[String]()
        self.ends = List[StepEnd]()

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
        self.calls.append(
            String("build ") + req.platform + String(" ") + req.declarations_file + String(" ") + req.revision_id
            + String(" ") + req.work_dir + String(" ") + req.run.run_id + String(" step=") + req.step_name
            + String(" plan=") + String(req.plan)
        )
        return self._next(req.step_name, String("BUILD"), req.platform, result)

    def publish(
        mut self, req: PublishRequest, mut result: KciRunResult, mut recorder: CliRecorder, store: SecretStoreChoice
    ) -> StepEnd:
        self.calls.append(
            String("publish ") + req.stage + String(" ") + req.channel + String(" ") + req.channels_file
            + String(" plan=") + String(req.plan) + String(" store=") + store.name()
        )
        return self._next(req.step_name, String("PUBLISH"), req.platform, result)


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
        + String("stage { name: \"build\" step { name: \"b\" kind: BUILD platform: \"linux-x86_64\" declarations: \"d.textproto\" } }\n")
        + String("stage { name: \"prod\" after: \"build\" step { name: \"p\" kind: PUBLISH platform: \"linux-x86_64\"")
        + String(" declarations: \"d.textproto\" channels: \"c.textproto\" channel: \"komira\" } }\n")
        + String("stage { name: \"all\" step { name: \"b\" kind: BUILD platform: \"linux-x86_64\" declarations: \"d.textproto\" }")
        + String(" step { name: \"p\" kind: PUBLISH platform: \"linux-x86_64\" declarations: \"d.textproto\" channels: \"c.textproto\" channel: \"komira\" } }\n")
        + String("stage { name: \"pub-then-build\" step { name: \"p\" kind: PUBLISH platform: \"linux-x86_64\" declarations: \"d.textproto\"")
        + String(" channels: \"c.textproto\" channel: \"komira\" } step { name: \"b\" kind: BUILD platform: \"linux-x86_64\" declarations: \"d.textproto\" } }\n"),
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
    for s in ["--expect-set-hash", "h", "--release-version", "rv", "--plan"]:
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
    write_whole_file(bad, String("schema_version: 1\nstage { name: \"x\" step { name: \"d\" kind: DEPLOY platform: \"linux-x86_64\" declarations: \"d\" } }\n"))
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


comptime _WF: String = (
    "name: kci\n"
    "on:\n"
    "  workflow_dispatch:\n"
    "    inputs:\n"
    "      revision:\n"
    "        type: string\n"
    "permissions: {}\n"
    "jobs:\n"
    "  build:\n"
    "    environment: build\n"
    "    steps:\n"
    "      - run: kci run --stage build\n"
    "  prod:\n"
    "    needs: build\n"
    "    environment: prod\n"
    "    permissions:\n"
    "      id-token: write\n"
    "    steps:\n"
    "      - run: kci run --stage prod\n"
)

comptime _CHANNELS: String = (
    "schema_version: 1\n"
    "channel { name: \"komira\" visibility: PUBLIC repository { artifact_type: CONDA"
    " location: \"https://prefix.dev/komira\" push_identity: \"repo:o/r:environment:prod\""
    " credential { kind: OIDC_TRUSTED_PUBLISHING } } }\n"
)


def _ci(dir: String, workflow_text: String) raises -> Int:
    var m = dir + String("/m.textproto")
    write_whole_file(
        m,
        String("schema_version: 1\n")
        + String("stage { name: \"build\" step { name: \"b\" kind: BUILD platform: \"linux-x86_64\" declarations: \"d\" } }\n")
        + String("stage { name: \"prod\" after: \"build\" step { name: \"p\" kind: PUBLISH platform: \"linux-x86_64\"")
        + String(" declarations: \"d\" channels: \"") + dir + String("/c.textproto\" channel: \"komira\" } }\n"),
    )
    write_whole_file(dir + String("/c.textproto"), String(_CHANNELS))
    # every `kci run` in the fixture reads the machine file being checked (R10)
    write_whole_file(dir + String("/kci.yml"), workflow_text.replace(String("kci run "), String("kci run --machine ") + m + String(" ")))
    var a = List[String]()
    for s in ["ci", "check", "--machine"]:
        a.append(String(s))
    a.append(m)
    a.append(String("--workflow"))
    a.append(dir + String("/kci.yml"))
    var steps = FakeSteps()
    var rec = CliRecorder.memory(String(""))
    var rc = kci_main_with(a, steps, rec)
    assert_equal(len(steps.calls), 0)
    assert_equal(_last(rec).verb, String("ci-check"))
    return rc


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
    assert_true(_last(v).error.message.find(String("declares no validations")) >= 0, _last(v).error.message)
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


def test_ci_check() raises:
    var d = _root(String("ci"))
    assert_equal(_ci(d, String(_WF)), 0)
    assert_equal(_ci(d, String(_WF).replace(String("environment: prod"), String("environment: production"))), 3)
    assert_equal(_ci(d, String(_WF).replace(String("environment: prod"), String("environment: &p prod"))), 5)
    # R9: a release job never runs selectively
    assert_equal(_ci(d, String(_WF).replace(String("--stage prod"), String("--stage prod --only step:p"))), 3)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
