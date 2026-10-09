# =============================================================================
# src/kci_cli/tests/test_kci_deploy_faults.mojo -- a DEPLOY step through
#   `kci_main_with` on a FAULTY FakeCloud (each fault a constructor
#   argument), and the outcome, exit and retry each one gets.
# =============================================================================
#
# The machine file, cells file and resource list are test_kci_deploy_step's
# (each gated test is built from its one file, so each carries its own copy
# of the helpers):
#
#   1. `trust_check` raises: FAILED, exit 4, retry SAFE, no call. A read
#      failed before anything was written; it is not a trust finding.
#   2. `--plan`, and a presence read raises: FAILED, exit 4, retry SAFE (a
#      plan writes nothing, so nothing landed). The same read under an apply
#      raises inside the engine, before any change, yet is PARTIAL, exit 6,
#      UNSAFE: an engine error is never told apart from a create whose wait
#      timed out.
#   3. `lower` returns a node owned by another resource (a lowering-contract
#      break in `lower_data`): FAILED, exit 4, NEEDS_HUMAN, under the plan and
#      the apply both, no call.
#   4. `realize` raises: FAILED, exit 4, NEEDS_HUMAN, under the plan and the
#      apply both, no call.
# =============================================================================

from std.ffi import external_call
from std.os import getenv, makedirs
from std.testing import TestSuite, assert_equal, assert_false, assert_true

from kci_build import BuildRequest
from kci_reconciler import Creds, InMemoryStateStore
from kci_cloud_fake import FakeCloud
from kci_cli import CliRecorder, CloudDeploys, SecretStoreChoice, StageSteps, StepEnd, kci_main_with, write_whole_file
from kci_api import ResultValidation, parse_result
from kci_api import RunResult as KciRunResult
from kci_publish import NewNamesReport, PublishRequest
from kci_validate import ValidateRequest


comptime _REV: String = "a1b2c3d4e5f60718293a4b5c6d7e8f9012345678"
comptime _SET_HASH: String = "5e7a5e7a5e7a5e7a5e7a5e7a5e7a5e7a5e7a5e7a5e7a5e7a5e7a5e7a5e7a5e7a"
comptime _BUCKETS: String = '{"resource":[{"id":"media","bucket":{}},{"id":"logs","bucket":{}},{"id":"cache","bucket":{}}]}'


struct Steps(StageSteps, Movable):
    """The seam's other steps, never reached here, and the release set every
    run is handed (`_SET_HASH`). Layout: owned values only."""

    def __init__(out self):
        pass

    def build(mut self, req: BuildRequest, mut result: KciRunResult, mut recorder: CliRecorder) -> StepEnd:
        return StepEnd(String("FAILED"), String("KCI-E-INTERNAL"), String("no BUILD step runs here"))

    def publish(
        mut self, req: PublishRequest, mut result: KciRunResult, mut recorder: CliRecorder, store: SecretStoreChoice
    ) -> StepEnd:
        return StepEnd(String("FAILED"), String("KCI-E-INTERNAL"), String("no PUBLISH step runs here"))

    def validate(mut self, req: ValidateRequest) -> ResultValidation:
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


def _chdir(path: String) raises:
    var c = path.copy()
    # SAFETY: `c` is a local that outlives the call; chdir reads the
    # NUL-terminated string and keeps no pointer to it.
    var rc = external_call["chdir", Int32](c.as_c_string_slice().unsafe_ptr())
    if rc != 0:
        raise Error("chdir failed: " + path)


def _root(tag: String) raises -> String:
    var base = getenv("TEST_TMPDIR")
    if base.byte_length() == 0:
        base = getenv("TMPDIR")
    if base.byte_length() == 0:
        raise Error("neither TEST_TMPDIR nor TMPDIR is set")
    var d = base + String("/kci_deploy_fault_") + tag + String("_") + String(Int(external_call["getpid", Int32]()))
    makedirs(d, exist_ok=True)
    _chdir(d)
    return d^


def _machine(dir: String) raises -> String:
    write_whole_file(dir + String("/cells.textproto"), String("schema_version: 1\ncell { name: \"blue\" cloud: \"fake\" bootstrap_level: 1 }\n"))
    write_whole_file(dir + String("/app.json"), String(_BUCKETS))
    var m = dir + String("/machine.textproto")
    write_whole_file(
        m,
        String("schema_version: 1\nname: \"shop\"\n")
        + String("stage { name: \"build\" step { name: \"b\" kind: BUILD platform: \"linux-x86_64\" artifacts: \"a.textproto\" } }\n")
        + String("stage { name: \"deploy\" after: \"build\" step { name: \"apply\" kind: DEPLOY cells: \"")
        + dir + String("/cells.textproto\" cell: \"blue\" resources: \"app.json\" } }\n"),
    )
    return m^


def _run(machine: String, plan: Bool) -> List[String]:
    var l = List[String]()
    for s in ["run", "--machine"]:
        l.append(String(s))
    l.append(machine.copy())
    for s in ["--stage", "deploy", "--revision-id"]:
        l.append(String(s))
    l.append(String(_REV))
    for s in ["--run-id", "gh-7", "--attempt", "2", "--release-dir", "/r", "--release-set-hash"]:
        l.append(String(s))
    l.append(String(_SET_HASH))
    if plan:
        l.append(String("--plan"))
    return l^


struct _Seen(Movable):
    var rc: Int
    var outcome: String
    var retry: String
    var error_id: String
    var message: String
    var landed: Int
    var calls: Int

    def __init__(out self):
        self.rc = -1
        self.outcome = String("")
        self.retry = String("")
        self.error_id = String("")
        self.message = String("")
        self.landed = -1
        self.calls = -1


def _deploy(var cloud: FakeCloud, tag: String, plan: Bool) raises -> _Seen:
    """One run of the deploy stage on `cloud`; what it ended with."""
    var m = _machine(_root(tag))
    var steps = Steps()
    var deploys = CloudDeploys[FakeCloud, InMemoryStateStore](cloud^, InMemoryStateStore(), Creds.none())
    var rec = CliRecorder.memory(String(""))
    var seen = _Seen()
    seen.rc = kci_main_with(_run(m, plan), steps, deploys, rec)
    var r = parse_result(rec.records[len(rec.records) - 1], String("record"))
    seen.outcome = r.outcome.copy()
    seen.retry = r.retry.copy()
    seen.error_id = r.error.id.copy()
    seen.message = r.error.message.copy()
    seen.landed = len(r.steps[0].deploy.landed)
    seen.calls = deploys.cloud.mutations()
    return seen^


def test_a_raising_trust_check_is_failed() raises:
    """Catches: a raising `trust_check` taken as a trust finding (REFUSED)
    or let through to the apply."""
    var s = _deploy(FakeCloud(trust_check_raises=True), String("trust"), False)
    assert_equal(s.rc, 4, s.message)
    assert_equal(s.outcome, String("FAILED"))
    assert_equal(s.retry, String("SAFE"))
    assert_equal(s.error_id, String("KCI-E-CLOUD"))
    assert_true(s.message.find(String("trust_check")) >= 0, s.message)
    assert_equal(s.calls, 0)


def test_a_plan_whose_presence_read_raises_is_failed() raises:
    """Catches: a failed read under `--plan` given NEEDS_HUMAN (taken for a
    defect) or reported as a refusal."""
    var reads = List[String]()
    reads.append(String("logs/bucket"))
    var s = _deploy(FakeCloud(presence_read_raises=reads), String("read-plan"), True)
    assert_equal(s.rc, 4, s.message)
    assert_equal(s.outcome, String("FAILED"))
    assert_equal(s.retry, String("SAFE"))
    assert_equal(s.error_id, String("KCI-E-DEPLOY"))
    assert_true(s.message.find(String("logs/bucket")) >= 0, s.message)
    assert_equal(s.calls, 0)


def test_an_apply_whose_presence_read_raises_is_partial() raises:
    """Catches: an engine error told apart by where it was raised (the
    engine's pre-flight read is PARTIAL, as any engine error)."""
    var reads = List[String]()
    reads.append(String("logs/bucket"))
    var s = _deploy(FakeCloud(presence_read_raises=reads), String("read-apply"), False)
    assert_equal(s.rc, 6, s.message)
    assert_equal(s.outcome, String("PARTIAL"))
    assert_equal(s.retry, String("UNSAFE"))


def test_a_lowering_contract_break_is_failed_needs_human() raises:
    """Catches: a broken lowering contract given retry SAFE (taken for a
    failed read)."""
    for plan in [True, False]:
        var s = _deploy(FakeCloud(lower_misowned=String("logs")), String("lower"), plan)
        assert_equal(s.rc, 4, s.message)
        assert_equal(s.outcome, String("FAILED"))
        assert_equal(s.retry, String("NEEDS_HUMAN"))
        assert_true(s.message.find(String("lower_data")) >= 0, s.message)
        assert_equal(s.landed, 0)
        assert_equal(s.calls, 0)


def test_a_raising_realize_is_failed_needs_human() raises:
    """Catches: a raising `realize` given retry SAFE (the row's mutant)."""
    for plan in [True, False]:
        var s = _deploy(FakeCloud(realize_raises=True), String("realize"), plan)
        assert_equal(s.rc, 4, s.message)
        assert_equal(s.outcome, String("FAILED"))
        assert_equal(s.retry, String("NEEDS_HUMAN"))
        assert_true(s.message.find(String("realize")) >= 0, s.message)
        assert_equal(s.landed, 0)
        assert_equal(s.calls, 0)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
