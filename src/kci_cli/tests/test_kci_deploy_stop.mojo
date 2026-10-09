# =============================================================================
# src/kci_cli/tests/test_kci_deploy_stop.mojo -- a failed DEPLOY step stops
#   the run (D7 of deploy_step.md, "After a failed deploy"), end to end
#   through `kci_main_with`, on two `CloudDeploys[FakeCloud,
#   InMemoryStateStore]`, one per cell.
# =============================================================================
#
# The machine file is named `shop`. Its `build` stage holds the BUILD step
# whose release a DEPLOY step deploys; its `deploy` stage holds a PUBLISH
# step into cell `a`, then a DEPLOY step into cell `a`, then one into cell
# `b`, and is run with `--release-set-hash` and no validation. The PUBLISH
# step is there so the `set_hash` assertions can fail: the start checks set
# `set_hash` from it. The test's `Steps` answers it (it runs a PUBLISH step
# into a cell, `runs_publish_into_cell`) and pushes nothing. `TwoCells`
# hands each DEPLOY step to its cell's own fake and records which cells it
# was asked for.
#
#   1. No fault (the control): SUCCEEDED, `set_hash` is the given hash, both
#      cells applied. A second run, every step a NOOP: NOOP, exit 0, and
#      `set_hash` still the given hash.
#   2. A fault planted mid-graph in `a`: PARTIAL, exit 6; `a`'s fake records
#      no call after the faulting one and its live objects are exactly
#      `landed`; `b` is never asked for, its fake records zero calls and it
#      has no step row; `set_hash` is empty.
#   3. The same with the fault in `b`: `a` is SUCCEEDED and its objects
#      stand as its apply left them; `set_hash` is empty.
#   4. A DEPLOY step that ends FAILED (a raising `trust_check` in `a`) stops
#      the run the same way: exit 4, `b` never asked for, `set_hash` empty.
#   5. `--rollback-on-failure` given to the faulted run of case 2, with and
#      without `--plan`, and to a stage with no DEPLOY step: KCI-E-USAGE,
#      exit 2, the exact message naming the missing deployed-revision
#      record, zero calls on both fakes and on the steps, no RUNNING record.
#   6. A run refused at start AFTER the PUBLISH step's check set `set_hash`
#      (a DEPLOY step with no BUILD step to hold the release to): REFUSED,
#      exit 3, and `set_hash` empty (the emptying is on every exit path).
#
# The step reads `resources` relative to the directory kci runs in, so each
# case changes into its own directory first.
# =============================================================================

from std.ffi import external_call
from std.os import getenv, makedirs
from std.pathlib import Path
from std.testing import TestSuite, assert_equal, assert_false, assert_true

from kci_build import BuildRequest
from kci_reconciler import Creds, InMemoryStateStore
from kci_cloud_fake import FakeCloud
from kci_cli import (
    CellDeploys,
    CliRecorder,
    CloudDeploys,
    DeployRequest,
    SecretStoreChoice,
    StageSteps,
    StepEnd,
    kci_main_with,
    write_whole_file,
)
from kci_api import ResultStep, ResultValidation, parse_result
from kci_api import RunResult as KciRunResult
from kci_publish import NewNamesReport, PublishRequest
from kci_validate import ValidateRequest


comptime _REV: String = "a1b2c3d4e5f60718293a4b5c6d7e8f9012345678"
comptime _SET_HASH: String = "5e7a5e7a5e7a5e7a5e7a5e7a5e7a5e7a5e7a5e7a5e7a5e7a5e7a5e7a5e7a5e7a"
comptime _BUCKETS: String = '{"resource":[{"id":"media","bucket":{}},{"id":"logs","bucket":{}},{"id":"cache","bucket":{}}]}'
comptime _ROLLBACK_REFUSAL: String = (
    "--rollback-on-failure needs the per-cell deployed-revision record, which this kci does not have:"
    " without the flag a failed DEPLOY step stops the run and leaves its cell as the failed apply left it"
)


struct Steps(StageSteps, Movable):
    """Answers every BUILD and PUBLISH step with `outcome` and pushes
    nothing; records each call. Runs a PUBLISH step into a cell. Every run
    is handed `_SET_HASH`. Layout: owned values only."""

    var calls: List[String]
    var outcome: String

    def __init__(out self):
        self.calls = List[String]()
        self.outcome = String("SUCCEEDED")

    def _answer(mut self, call: String, name: String, kind: String, platform: String, mut result: KciRunResult) -> StepEnd:
        self.calls.append(call.copy())
        result.steps.append(ResultStep(name.copy(), kind.copy(), platform.copy(), self.outcome.copy()))
        return StepEnd(self.outcome.copy(), String(""), String(""))

    def build(mut self, req: BuildRequest, mut result: KciRunResult, mut recorder: CliRecorder) -> StepEnd:
        return self._answer(String("build ") + req.step_name, req.step_name, String("BUILD"), req.platform, result)

    def publish(
        mut self, req: PublishRequest, mut result: KciRunResult, mut recorder: CliRecorder, store: SecretStoreChoice
    ) -> StepEnd:
        # a PUBLISH into a cell names no channel
        return self._answer(
            String("publish ") + req.step_name + String(" channel=") + req.channel, req.step_name, String("PUBLISH"),
            req.platform, result,
        )

    def validate(mut self, req: ValidateRequest) -> ResultValidation:
        self.calls.append(String("validate ") + req.validation.name)
        return ResultValidation(req.validation.name.copy(), req.step_name.copy(), req.validation.kind.copy(), String("NOT_REACHED"), String(""))

    def lookahead(mut self, req: PublishRequest) -> NewNamesReport:
        return NewNamesReport(req.stage.copy(), req.step_name.copy(), req.channel.copy())

    def platform_env(mut self, name: String) -> String:
        return String("")

    def committed_file(mut self, commit: String, path: String) raises -> String:
        raise Error("not under GitHub Actions")

    def is_ancestor(mut self, commit: String, of: String) raises -> Bool:
        return True

    def release_set_hash(mut self, artifacts_file: String, platform_dir: String) raises -> String:
        return String(_SET_HASH)

    def runs_publish_into_cell(self) -> Bool:
        return True


struct TwoCells(CellDeploys, Movable):
    """Cell `a`'s fake cloud and store, cell `b`'s, and the cells each
    DEPLOY step was handed for, in order. Layout: owned values only."""

    var a: CloudDeploys[FakeCloud, InMemoryStateStore]
    var b: CloudDeploys[FakeCloud, InMemoryStateStore]
    var asked: List[String]

    def __init__(out self, var a: FakeCloud, var b: FakeCloud) raises:
        self.a = CloudDeploys[FakeCloud, InMemoryStateStore](a^, InMemoryStateStore(), Creds.none())
        self.b = CloudDeploys[FakeCloud, InMemoryStateStore](b^, InMemoryStateStore(), Creds.none())
        self.asked = List[String]()

    def deploy(mut self, req: DeployRequest, mut result: KciRunResult) -> StepEnd:
        self.asked.append(req.cell.copy())
        if req.cell == String("b"):
            return self.b.deploy(req, result)
        return self.a.deploy(req, result)


def _chdir(path: String) raises:
    var c = path.copy()
    # SAFETY: `c` is a local that outlives the call; chdir reads the
    # NUL-terminated string and keeps no pointer to it.
    var rc = external_call["chdir", Int32](c.as_c_string_slice().unsafe_ptr())
    if rc != 0:
        raise Error("chdir failed: " + path)


def _root(tag: String) raises -> String:
    """A fresh directory, made the working directory: the steps read their
    resource list relative to it."""
    var base = getenv("TEST_TMPDIR")
    if base.byte_length() == 0:
        base = getenv("TMPDIR")
    if base.byte_length() == 0:
        raise Error("neither TEST_TMPDIR nor TMPDIR is set")
    var d = base + String("/kci_deploy_stop_") + tag + String("_") + String(Int(external_call["getpid", Int32]()))
    makedirs(d, exist_ok=True)
    _chdir(d)
    return d^


def _machine(dir: String, build: Bool = True) raises -> String:
    """The machine file (file header) in `dir`, its cells file (cells `a`
    and `b`, both on the fake cloud) and the resource list both DEPLOY steps
    apply. `build` False leaves the BUILD stage out."""
    var cells = dir + String("/cells.textproto")
    write_whole_file(
        cells,
        String("schema_version: 1\n")
        + String("cell { name: \"a\" cloud: \"fake\" bootstrap_level: 1 }\n")
        + String("cell { name: \"b\" cloud: \"fake\" bootstrap_level: 1 }\n"),
    )
    write_whole_file(dir + String("/app.json"), String(_BUCKETS))
    var m = dir + String("/machine.textproto")
    var text = String("schema_version: 1\nname: \"shop\"\n")
    if build:
        text += String(
            "stage { name: \"build\" step { name: \"b\" kind: BUILD platform: \"linux-x86_64\" artifacts: \"a.textproto\" } }\n"
        )
    text += String("stage { name: \"deploy\"") + (String(" after: \"build\"") if build else String(""))
    text += String(" step { name: \"push-a\" kind: PUBLISH platform: \"linux-x86_64\" artifacts: \"a.textproto\" cells: \"")
    text += cells + String("\" cell: \"a\" }")
    text += String(" step { name: \"apply-a\" kind: DEPLOY cells: \"") + cells + String("\" cell: \"a\" resources: \"app.json\" }")
    text += String(" step { name: \"apply-b\" kind: DEPLOY cells: \"") + cells + String("\" cell: \"b\" resources: \"app.json\" }")
    text += String(" }\n")
    write_whole_file(m, text)
    return m^


def _run(machine: String, summary: String, plan: Bool = False, rollback: Bool = False) -> List[String]:
    """`kci run --stage deploy` with `--release-set-hash` and the PUBLISH
    step's `--release-version`."""
    var l = List[String]()
    for s in ["run", "--machine"]:
        l.append(String(s))
    l.append(machine.copy())
    for s in ["--stage", "deploy", "--revision-id"]:
        l.append(String(s))
    l.append(String(_REV))
    for s in ["--run-id", "gh-7", "--attempt", "2", "--release-dir", "/r", "--release-version", "rv", "--summary-file"]:
        l.append(String(s))
    l.append(summary.copy())
    l.append(String("--release-set-hash"))
    l.append(String(_SET_HASH))
    if plan:
        l.append(String("--plan"))
    if rollback:
        l.append(String("--rollback-on-failure"))
    return l^


def _last(rec: CliRecorder) raises -> KciRunResult:
    return parse_result(rec.records[len(rec.records) - 1], String("record"))


def _live(deploys: CloudDeploys[FakeCloud, InMemoryStateStore]) -> List[String]:
    return deploys.cloud.store[].ids.copy()


def _has(xs: List[String], x: String) -> Bool:
    for i in range(len(xs)):
        if xs[i] == x:
            return True
    return False


def _live_is_landed(deploys: CloudDeploys[FakeCloud, InMemoryStateStore], row: ResultStep) raises:
    """The cell's live objects are exactly the row's `landed` nodes."""
    var live = _live(deploys)
    assert_equal(len(live), len(row.deploy.landed), "as many live objects as landed nodes")
    for i in range(len(row.deploy.landed)):
        assert_true(_has(live, row.deploy.landed[i].node), row.deploy.landed[i].node)


def _no_row(r: KciRunResult, name: String) raises:
    for i in range(len(r.steps)):
        assert_true(r.steps[i].name != name, String("a row for ") + name)


def test_no_fault_hands_on_the_set() raises:
    """The control. Catches: the emptying applied to every run (`set_hash`
    empty here), and NOOP treated as a failure (the second run's
    `set_hash` empty)."""
    var d = _root(String("control"))
    var m = _machine(d)
    var steps = Steps()
    var deploys = TwoCells(FakeCloud(), FakeCloud())
    var rec = CliRecorder.memory(String(""))
    var rc = kci_main_with(_run(m, d + String("/summary.md")), steps, deploys, rec)
    var r = _last(rec)
    assert_equal(rc, 0, r.error.message)
    assert_equal(r.outcome, String("SUCCEEDED"))
    assert_equal(r.set_hash, String(_SET_HASH), "a run that passed hands its set on")
    assert_equal(len(r.steps), 3)
    assert_equal(len(steps.calls), 1)
    assert_equal(steps.calls[0], String("publish push-a channel="))
    assert_equal(len(deploys.asked), 2)
    assert_equal(deploys.asked[0], String("a"))
    assert_equal(deploys.asked[1], String("b"))
    assert_equal(deploys.a.cloud.mutations(), 3)
    assert_equal(deploys.b.cloud.mutations(), 3)
    # every step a NOOP: the run is NOOP and still hands its set on
    steps.outcome = String("NOOP")
    var rec2 = CliRecorder.memory(String(""))
    var rc2 = kci_main_with(_run(m, d + String("/summary2.md")), steps, deploys, rec2)
    var r2 = _last(rec2)
    assert_equal(rc2, 0, r2.error.message)
    assert_equal(r2.outcome, String("NOOP"))
    assert_equal(r2.steps[1].outcome, String("NOOP"))
    assert_equal(r2.steps[2].outcome, String("NOOP"))
    assert_equal(r2.set_hash, String(_SET_HASH), "a NOOP run passed: it hands its set on")


def test_a_fault_mid_graph_in_a_stops_the_run() raises:
    """Catches: the step loop going on after a failed DEPLOY step (`b` is
    asked for, its fake records calls, it has a row); the failed run
    keeping the set (`set_hash` not emptied); a's apply going on after the
    fault, or unwound (its live objects differ from `landed`)."""
    var d = _root(String("fault-a"))
    var m = _machine(d)
    var steps = Steps()
    var deploys = TwoCells(FakeCloud(fail_at_call=2), FakeCloud())
    var rec = CliRecorder.memory(String(""))
    assert_equal(kci_main_with(_run(m, d + String("/summary.md")), steps, deploys, rec), 6)
    var r = _last(rec)
    assert_equal(r.outcome, String("PARTIAL"))
    assert_equal(r.exit_code, 6)
    assert_equal(r.retry, String("UNSAFE"))
    assert_equal(r.set_hash, String(""), "a failed run hands on no set")
    assert_equal(len(r.steps), 2, "the PUBLISH step and a's DEPLOY step, nothing after")
    assert_equal(r.steps[0].outcome, String("SUCCEEDED"))
    ref row = r.steps[1]
    assert_equal(row.name, String("apply-a"))
    assert_equal(row.outcome, String("PARTIAL"))
    assert_equal(len(row.deploy.landed), 1)
    assert_equal(len(row.deploy.pending), 2)
    # the faulting call is not logged and fails once, so any call after it
    # would be logged: one call is the create that landed, and nothing after
    assert_equal(deploys.a.cloud.mutations(), 1, "a's fake records no call after the faulting one")
    _live_is_landed(deploys.a, row)
    # b: never handed to its cloud, no call, no object, no row
    assert_equal(len(deploys.asked), 1)
    assert_equal(deploys.asked[0], String("a"))
    assert_equal(deploys.b.cloud.mutations(), 0, "b's fake records zero calls")
    assert_equal(deploys.b.cloud.live_count(), 0)
    _no_row(r, String("apply-b"))
    assert_equal(len(steps.calls), 1)
    var summary = Path(d + String("/summary.md")).read_text()
    assert_true(summary.find(String("- set hash: `")) < 0, summary)


def test_a_fault_in_b_leaves_a_as_it_was() raises:
    """Catches: the failed run keeping the set when the fault is in the
    last step; anything done to `a` after `b` failed (a call on a's fake, an
    object of a's gone)."""
    var d = _root(String("fault-b"))
    var m = _machine(d)
    var steps = Steps()
    var deploys = TwoCells(FakeCloud(), FakeCloud(fail_at_call=2))
    var rec = CliRecorder.memory(String(""))
    assert_equal(kci_main_with(_run(m, d + String("/summary.md")), steps, deploys, rec), 6)
    var r = _last(rec)
    assert_equal(r.outcome, String("PARTIAL"))
    assert_equal(r.set_hash, String(""), "a failed run hands on no set")
    assert_equal(len(r.steps), 3)
    ref a = r.steps[1]
    assert_equal(a.name, String("apply-a"))
    assert_equal(a.outcome, String("SUCCEEDED"))
    assert_equal(len(a.deploy.landed), 3)
    assert_equal(deploys.a.cloud.mutations(), 3, "a's three creates and no call after b failed")
    _live_is_landed(deploys.a, a)
    ref b = r.steps[2]
    assert_equal(b.name, String("apply-b"))
    assert_equal(b.outcome, String("PARTIAL"))
    assert_equal(deploys.b.cloud.mutations(), 1)
    _live_is_landed(deploys.b, b)


def test_a_failed_deploy_step_stops_the_run_too() raises:
    """Catches: the stop applied to PARTIAL only (a FAILED DEPLOY step lets
    `b` run), and a FAILED run keeping the set."""
    var d = _root(String("failed-a"))
    var m = _machine(d)
    var steps = Steps()
    var deploys = TwoCells(FakeCloud(trust_check_raises=True), FakeCloud())
    var rec = CliRecorder.memory(String(""))
    assert_equal(kci_main_with(_run(m, d + String("/summary.md")), steps, deploys, rec), 4)
    var r = _last(rec)
    assert_equal(r.outcome, String("FAILED"))
    assert_equal(r.set_hash, String(""), "a failed run hands on no set")
    assert_equal(len(r.steps), 2)
    assert_equal(r.steps[1].outcome, String("FAILED"))
    assert_equal(len(deploys.asked), 1)
    assert_equal(deploys.a.cloud.mutations(), 0)
    assert_equal(deploys.b.cloud.mutations(), 0)
    _no_row(r, String("apply-b"))


def _refused_before_anything(
    args: List[String], mut steps: Steps, mut deploys: TwoCells
) raises:
    var rec = CliRecorder.memory(String(""))
    assert_equal(kci_main_with(args, steps, deploys, rec), 2)
    var r = _last(rec)
    assert_equal(r.outcome, String("REFUSED"))
    assert_equal(r.error.id, String("KCI-E-USAGE"))
    assert_equal(r.error.message, String(_ROLLBACK_REFUSAL))
    assert_equal(len(rec.statuses), 1, "no RUNNING record")
    assert_equal(rec.statuses[0], String("FINISHED"))
    assert_equal(len(r.steps), 0)
    assert_equal(len(steps.calls), 0)
    assert_equal(len(deploys.asked), 0)
    assert_equal(deploys.a.cloud.mutations(), 0)
    assert_equal(deploys.b.cloud.mutations(), 0)


def test_rollback_on_failure_is_refused_before_anything() raises:
    """Catches: the flag accepted and ignored (the faulted run starts and
    exits 6; with --plan it exits 0; the BUILD stage exits 0), and a
    refusal that waits for the start checks or the RUNNING record."""
    var d = _root(String("rollback"))
    var m = _machine(d)
    var steps = Steps()
    var deploys = TwoCells(FakeCloud(fail_at_call=2), FakeCloud())
    _refused_before_anything(_run(m, d + String("/summary.md"), rollback=True), steps, deploys)
    _refused_before_anything(_run(m, d + String("/summary.md"), plan=True, rollback=True), steps, deploys)
    # a stage with no DEPLOY step, its command line otherwise accepted
    var build = List[String]()
    for s in ["run", "--machine"]:
        build.append(String(s))
    build.append(m.copy())
    for s in ["--stage", "build", "--revision-id"]:
        build.append(String(s))
    build.append(String(_REV))
    for s in ["--run-id", "gh-7", "--attempt", "2", "--release-dir", "/r", "--work-dir", "/w", "--log-dir", "/l"]:
        build.append(String(s))
    var without = build.copy()
    build.append(String("--rollback-on-failure"))
    _refused_before_anything(build, steps, deploys)
    # the same command line without the flag runs the BUILD step
    var rec = CliRecorder.memory(String(""))
    assert_equal(kci_main_with(without, steps, deploys, rec), 0)
    assert_equal(len(steps.calls), 1)
    assert_equal(steps.calls[0], String("build b"))


def test_a_run_refused_at_start_hands_on_no_set() raises:
    """Catches: the emptying done only after the steps (here the PUBLISH
    step's start check set `set_hash`, then the DEPLOY step's refused the
    run before any step ran)."""
    var d = _root(String("refused"))
    var m = _machine(d, build=False)
    var steps = Steps()
    var deploys = TwoCells(FakeCloud(), FakeCloud())
    var rec = CliRecorder.memory(String(""))
    assert_equal(kci_main_with(_run(m, d + String("/summary.md")), steps, deploys, rec), 3)
    var r = _last(rec)
    assert_equal(r.outcome, String("REFUSED"))
    assert_equal(r.error.id, String("KCI-E-SET-HASH"))
    assert_equal(len(r.steps), 0)
    assert_equal(r.set_hash, String(""), "a refused run hands on no set")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
