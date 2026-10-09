# =============================================================================
# src/kci_cli/tests/test_kci_deploy_step.mojo -- a DEPLOY step end to end
#   through `kci_main_with`, on `CloudDeploys[FakeCloud, InMemoryStateStore,
#   NoRegistryClient]` (no PUBLISH into a cell runs here).
# =============================================================================
#
# The machine file is named `shop` and has a `build` stage (the BUILD step
# whose release a DEPLOY step deploys) and a `deploy` stage that no other
# stage names in `after` (a promoted DEPLOY is refused by the parser until
# probes exist). Its DEPLOY step deploys a resource list into cell `blue`
# of a cells file whose cloud is `fake`. Each case asserts the exit number,
# the result's outcome and retry, and the step row's deploy keys:
#
#   1. `--plan` writes nothing: no call on the cloud, no intent in the store,
#      `landed` empty, `plan_hash` 64 hex, `set_hash` not handed on, and the
#      plan in the summary.
#   2. An apply, then a second run on the same cloud and store: SUCCEEDED
#      with every node landed as a create, then NOOP with every node a noop.
#   3. The scope's machine is the machine file's `name`: every object
#      carries `kci_machine` = `shop` (not the stage, not the file's path).
#   4. A planted foreign object: REFUSED, exit 3, `landed` empty, no call.
#   5. A fault on the second mutating call: PARTIAL, exit 6, UNSAFE, one node
#      landed and the rest pending, the failing node first and in `failed`.
#   6. A fault on the FIRST mutating call: still PARTIAL, exit 6, UNSAFE
#      (never FAILED: the failing call may have landed), `landed` empty,
#      `pending` starting at that node.
#   7. A `kci.app` instance plans to its primitives (a golden plan).
#   8. A wrong `--release-set-hash`: REFUSED, exit 3, KCI-E-SET-HASH, no
#      call; without the flag: a usage error, exit 2.
#   9. The kci binary's deploys (`NoCloudBuilt`, the 3-argument
#      `kci_main_with`): REFUSED, exit 3, "this kci was not built with that
#      cloud".
#  10. A trust finding (the cell's `principal` is not who the credentials
#      are): REFUSED, exit 3, KCI-E-CLOUD, no call.
#  11. `plan_hash` is the sha256 of the actions in node-id order: a golden
#      over actions handed in another order, and the same golden from a
#      `--plan` of the three buckets (computed outside kci).
#  12. A second apply of a file that dropped `cache` and turned `media` from
#      a bucket into a secret: `cache/bucket` is leftover and `media/bucket`
#      (a KEEP bucket the file no longer lowers) is left behind, in the row
#      and the summary; nothing is deleted and both objects stand; the
#      summary states the two v1 limits (no lease, no destroy).
#  13. A step naming a cell its cells file does not declare: REFUSED at
#      load (KCI-E-FORMAT), no step run, no call.
#
# The step reads `resources` relative to the directory kci runs in (the
# parser refuses an absolute path, and kci has no working-directory flag),
# so each case changes into its own directory first.
# =============================================================================

from std.ffi import external_call
from std.os import getenv, makedirs
from std.pathlib import Path
from std.testing import TestSuite, assert_equal, assert_false, assert_true

from kci_build import BuildRequest
from kci_reconciler import ChangeAction, CellScope, Creds, InMemoryStateStore, LABEL_MACHINE, Provenance, VERB_CREATE
from kci_cloud import decode_label_value
from kci_cloud_fake import FakeCloud
from kci_cli import (
    CliRecorder,
    CloudDeploys,
    NOT_BUILT_WITH,
    NoRegistryClient,
    SecretStoreChoice,
    StageSteps,
    StepEnd,
    kci_main_with,
    plan_hash_of,
    write_whole_file,
)
from kci_api import OUTCOME_SUCCEEDED, ResultValidation, parse_result
from kci_api import RunResult as KciRunResult
from kci_publish import NewNamesReport, PublishRequest
from kci_validate import ValidateRequest


comptime _REV: String = "a1b2c3d4e5f60718293a4b5c6d7e8f9012345678"
comptime _SET_HASH: String = "5e7a5e7a5e7a5e7a5e7a5e7a5e7a5e7a5e7a5e7a5e7a5e7a5e7a5e7a5e7a5e7a"
comptime _OTHER_HASH: String = "0000000000000000000000000000000000000000000000000000000000000000"
comptime _BUCKETS: String = '{"resource":[{"id":"media","bucket":{}},{"id":"logs","bucket":{}},{"id":"cache","bucket":{}}]}'
comptime _APP: String = '{"resource":[{"id":"web","composite":{"definition":"kci.app","version":"1","input":{"public":{"literal":"true"}},"imageInput":{"image":{"digest":"sha256:a1"}}}}]}'


struct Steps(StageSteps, Movable):
    """The seam's other steps, never reached here, and the release set every
    run is handed (`_SET_HASH`). Layout: owned values only."""

    var hashed: List[String]

    def __init__(out self):
        self.hashed = List[String]()

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
        self.hashed.append(artifacts_file + String(" ") + platform_dir)
        return String(_SET_HASH)


def _chdir(path: String) raises:
    var c = path.copy()
    # SAFETY: `c` is a local that outlives the call; chdir reads the
    # NUL-terminated string and keeps no pointer to it.
    var rc = external_call["chdir", Int32](c.as_c_string_slice().unsafe_ptr())
    if rc != 0:
        raise Error("chdir failed: " + path)


def _root(tag: String) raises -> String:
    """A fresh directory, made the working directory: the step reads its
    resource list relative to it."""
    var base = getenv("TEST_TMPDIR")
    if base.byte_length() == 0:
        base = getenv("TMPDIR")
    if base.byte_length() == 0:
        raise Error("neither TEST_TMPDIR nor TMPDIR is set")
    var d = base + String("/kci_deploy_") + tag + String("_") + String(Int(external_call["getpid", Int32]()))
    makedirs(d, exist_ok=True)
    _chdir(d)
    return d^


def _machine(
    dir: String, resources: String, settings: String = String(""), cell: String = String("blue")
) raises -> String:
    """The machine file (file header) in `dir`, its cells file and the
    resource list `resources` (as app.json, relative)."""
    write_whole_file(
        dir + String("/cells.textproto"),
        String("schema_version: 1\ncell { name: \"blue\" cloud: \"fake\" ") + settings + String(" bootstrap_level: 1 }\n"),
    )
    write_whole_file(dir + String("/app.json"), resources)
    var m = dir + String("/machine.textproto")
    write_whole_file(
        m,
        String("schema_version: 1\nname: \"shop\"\n")
        + String("stage { name: \"build\" step { name: \"b\" kind: BUILD platform: \"linux-x86_64\" artifacts: \"a.textproto\" } }\n")
        + String("stage { name: \"deploy\" after: \"build\" step { name: \"apply\" kind: DEPLOY cells: \"")
        + dir + String("/cells.textproto\" cell: \"") + cell + String("\" resources: \"app.json\" } }\n"),
    )
    return m^


def _run(machine: String, summary: String, plan: Bool = False, hash: String = String(_SET_HASH)) -> List[String]:
    var l = List[String]()
    for s in ["run", "--machine"]:
        l.append(String(s))
    l.append(machine.copy())
    for s in ["--stage", "deploy", "--revision-id"]:
        l.append(String(s))
    l.append(String(_REV))
    for s in ["--run-id", "gh-7", "--attempt", "2", "--release-dir", "/r", "--summary-file"]:
        l.append(String(s))
    l.append(summary.copy())
    if hash.byte_length() > 0:
        l.append(String("--release-set-hash"))
        l.append(hash.copy())
    if plan:
        l.append(String("--plan"))
    return l^


def _last(rec: CliRecorder) raises -> KciRunResult:
    return parse_result(rec.records[len(rec.records) - 1], String("record"))


def _deploys(var cloud: FakeCloud) raises -> CloudDeploys[FakeCloud, InMemoryStateStore, NoRegistryClient]:
    return CloudDeploys[FakeCloud, InMemoryStateStore, NoRegistryClient](
        cloud^, InMemoryStateStore(), Creds.none(), NoRegistryClient()
    )


def _scope() -> CellScope:
    return CellScope(String("shop"), String("blue"), Provenance(String("gh-7"), String(_REV)))


def _three(r: KciRunResult) raises:
    """landed + pending are the three bucket nodes, each once."""
    ref d = r.steps[0].deploy
    var seen = List[String]()
    for i in range(len(d.landed)):
        seen.append(d.landed[i].node.copy())
    for i in range(len(d.pending)):
        seen.append(d.pending[i].copy())
    assert_equal(len(seen), 3)
    for want in ["media/bucket", "logs/bucket", "cache/bucket"]:
        var n = 0
        for i in range(len(seen)):
            if seen[i] == String(want):
                n += 1
        assert_equal(n, 1, String(want))


def test_plan_writes_nothing() raises:
    """Catches: `--plan` routed to apply (calls on the cloud, intents in the
    store, `landed` set)."""
    var d = _root(String("plan"))
    var m = _machine(d, String(_BUCKETS))
    var steps = Steps()
    var deploys = _deploys(FakeCloud())
    var rec = CliRecorder.memory(String(""))
    assert_equal(kci_main_with(_run(m, d + String("/summary.md"), plan=True), steps, deploys, rec), 0)
    var r = _last(rec)
    assert_equal(r.outcome, String("SUCCEEDED"))
    assert_equal(deploys.cloud.mutations(), 0, "a plan calls nothing that mutates")
    assert_equal(deploys.store.total_intents(_scope().key(String("media/bucket"))), 0, "a plan records no intent")
    assert_equal(len(r.steps), 1)
    ref row = r.steps[0]
    assert_equal(row.kind, String("DEPLOY"))
    assert_equal(row.deploy.cell, String("blue"))
    assert_equal(row.deploy.cloud, String("fake"))
    assert_equal(len(row.deploy.landed), 0)
    assert_equal(row.deploy.plan_hash.byte_length(), 64)
    assert_equal(r.set_hash, String(""), "a dry run hands on no set")
    assert_equal(len(steps.hashed), 1, "the set hash is recomputed")
    assert_equal(steps.hashed[0], String("a.textproto /r/linux-x86_64"))
    var summary = Path(d + String("/summary.md")).read_text()
    assert_true(summary.find(String("media: create media/bucket")) >= 0, summary)
    assert_true(summary.find(String("Dry run (--plan)")) >= 0, summary)


def test_apply_then_a_second_run_is_noop() raises:
    """Catches: an apply that lands nothing, a re-run that is not NOOP
    (every apply counted as a change)."""
    var d = _root(String("apply"))
    var m = _machine(d, String(_BUCKETS))
    var steps = Steps()
    var deploys = _deploys(FakeCloud())
    var rec = CliRecorder.memory(String(""))
    assert_equal(kci_main_with(_run(m, d + String("/summary.md")), steps, deploys, rec), 0)
    var r = _last(rec)
    assert_equal(r.outcome, String("SUCCEEDED"))
    assert_equal(r.set_hash, String(_SET_HASH), "the recomputed set is handed on")
    assert_equal(len(r.steps[0].deploy.landed), 3)
    for i in range(3):
        assert_equal(r.steps[0].deploy.landed[i].verb, String("create"))
    assert_equal(len(r.steps[0].deploy.pending), 0)
    assert_false(r.steps[0].deploy.has_failed)
    assert_equal(r.steps[0].deploy.plan_hash, String(""), "an apply emits no plan_hash")
    assert_equal(deploys.store.count_confirmed(_scope().key(String("media/bucket"))), 1)
    var calls = deploys.cloud.mutations()
    assert_equal(calls, 3)
    var rec2 = CliRecorder.memory(String(""))
    assert_equal(kci_main_with(_run(m, d + String("/summary2.md")), steps, deploys, rec2), 0)
    var r2 = _last(rec2)
    assert_equal(r2.outcome, String("NOOP"))
    assert_equal(deploys.cloud.mutations(), calls, "a converged cell takes no call")
    assert_equal(len(r2.steps[0].deploy.landed), 3)
    for i in range(3):
        assert_equal(r2.steps[0].deploy.landed[i].verb, String("noop"))


def test_the_scope_machine_is_the_files_name() raises:
    """Catches: the scope's machine taken from anything but the machine
    file's `name` (the stage, the path)."""
    var d = _root(String("machine"))
    var m = _machine(d, String(_BUCKETS))
    var steps = Steps()
    var deploys = _deploys(FakeCloud())
    var rec = CliRecorder.memory(String(""))
    assert_equal(kci_main_with(_run(m, d + String("/summary.md")), steps, deploys, rec), 0)
    var labels = deploys.cloud.live_labels(String("media/bucket"))
    var machine = String("")
    for i in range(len(labels)):
        if labels[i].key == String(LABEL_MACHINE):
            machine = decode_label_value(labels[i].value)
    assert_equal(machine, String("shop"))
    assert_equal(deploys.store.count_confirmed(_scope().key(String("logs/bucket"))), 1, "keyed (shop, blue, node)")


def test_a_foreign_object_is_refused() raises:
    """Catches: the engine's ownership refusal reported as a partial apply."""
    var d = _root(String("foreign"))
    var m = _machine(d, String(_BUCKETS))
    var steps = Steps()
    var foreign = List[String]()
    foreign.append(String("logs/bucket"))
    var deploys = _deploys(FakeCloud(foreign=foreign))
    var rec = CliRecorder.memory(String(""))
    assert_equal(kci_main_with(_run(m, d + String("/summary.md")), steps, deploys, rec), 3)
    var r = _last(rec)
    assert_equal(r.outcome, String("REFUSED"))
    assert_equal(r.retry, String("NEEDS_HUMAN"))
    assert_equal(r.error.id, String("KCI-E-DEPLOY"))
    assert_true(r.error.message.find(String("logs/bucket")) >= 0, r.error.message)
    assert_equal(len(r.steps[0].deploy.landed), 0)
    assert_equal(deploys.cloud.mutations(), 0)


def test_a_mid_graph_fault_is_partial() raises:
    """Catches: a stopped apply reported without `landed`, `pending` or
    `failed`, or as FAILED."""
    var d = _root(String("mid"))
    var m = _machine(d, String(_BUCKETS))
    var steps = Steps()
    var deploys = _deploys(FakeCloud(fail_at_call=2))
    var rec = CliRecorder.memory(String(""))
    assert_equal(kci_main_with(_run(m, d + String("/summary.md")), steps, deploys, rec), 6)
    var r = _last(rec)
    assert_equal(r.outcome, String("PARTIAL"))
    assert_equal(r.retry, String("UNSAFE"))
    assert_equal(r.error.id, String("KCI-E-DEPLOY"))
    ref row = r.steps[0]
    assert_equal(len(row.deploy.landed), 1)
    assert_equal(len(row.deploy.pending), 2)
    assert_true(row.deploy.has_failed)
    assert_equal(row.deploy.failed.node, row.deploy.pending[0], "the failing node is pending's first")
    assert_equal(row.deploy.failed.verb, String("create"))
    assert_true(row.deploy.failed.fault_domain.byte_length() > 0)
    _three(r)


def test_a_fault_on_the_first_node_is_partial_not_failed() raises:
    """Catches: an engine error with `landed` empty mapped to FAILED
    (`ApplyOutcome.partial()` used as the classifier)."""
    var d = _root(String("first"))
    var m = _machine(d, String(_BUCKETS))
    var steps = Steps()
    var deploys = _deploys(FakeCloud(fail_at_call=1))
    var rec = CliRecorder.memory(String(""))
    assert_equal(kci_main_with(_run(m, d + String("/summary.md")), steps, deploys, rec), 6)
    var r = _last(rec)
    assert_equal(r.outcome, String("PARTIAL"))
    assert_equal(r.exit_code, 6)
    assert_equal(r.retry, String("UNSAFE"))
    ref row = r.steps[0]
    assert_equal(len(row.deploy.landed), 0)
    assert_equal(len(row.deploy.pending), 3)
    assert_equal(row.deploy.failed.node, row.deploy.pending[0])
    _three(r)


# `web` expands to `web/account` (a service account: its identity and the
# implicit `cell LOGS WRITE` grant) and `web/api` (a public service running
# as the account: its own identity turned off, a no-op on an empty cell);
# no `domain`, so no `web/host`. The grant id is the one kci_cloud_fake's
# own kci.app golden pins.
comptime _APP_PLAN: String = (
    "web: create web/account/identity, create web/account/u-b6mdyh, noop web/api/identity, create web/api/run,"
    " create web/api/public"
)


def test_a_kci_app_instance_plans_to_its_primitives() raises:
    """Catches: the definitions kci ships not passed (the instance is
    refused), or an instance planned as anything but its primitives."""
    var d = _root(String("app"))
    var m = _machine(d, String(_APP))
    var steps = Steps()
    var deploys = _deploys(FakeCloud())
    var rec = CliRecorder.memory(String(""))
    var rc = kci_main_with(_run(m, d + String("/summary.md"), plan=True), steps, deploys, rec)
    var r = _last(rec)
    assert_equal(rc, 0, r.error.message)
    var summary = Path(d + String("/summary.md")).read_text()
    var open = summary.find(String("```\n"))
    var close = summary.find(String("\n```"), open + 4)
    assert_true(open >= 0 and close > open, summary)
    assert_equal(String(summary[byte = open + 4 : close]), String(_APP_PLAN))


def test_a_wrong_set_hash_is_refused() raises:
    """Catches: the set-hash recompute skipped for a DEPLOY step; and the
    flag not required."""
    var d = _root(String("hash"))
    var m = _machine(d, String(_BUCKETS))
    var steps = Steps()
    var deploys = _deploys(FakeCloud())
    var rec = CliRecorder.memory(String(""))
    assert_equal(kci_main_with(_run(m, d + String("/summary.md"), hash=String(_OTHER_HASH)), steps, deploys, rec), 3)
    var r = _last(rec)
    assert_equal(r.outcome, String("REFUSED"))
    assert_equal(r.error.id, String("KCI-E-SET-HASH"))
    assert_equal(deploys.cloud.mutations(), 0)
    assert_equal(len(r.steps), 0, "refused at start: no step ran")
    var rec2 = CliRecorder.memory(String(""))
    assert_equal(kci_main_with(_run(m, d + String("/summary.md"), hash=String("")), steps, deploys, rec2), 2)
    assert_equal(_last(rec2).error.id, String("KCI-E-USAGE"))
    assert_true(_last(rec2).error.message.find(String("--release-set-hash")) >= 0)


def test_the_kci_binary_refuses_every_deploy() raises:
    """Catches: the binary's deploys (no cloud built in) running a step, or
    refusing it for another reason."""
    var d = _root(String("binary"))
    var m = _machine(d, String(_BUCKETS))
    var steps = Steps()
    var rec = CliRecorder.memory(String(""))
    assert_equal(kci_main_with(_run(m, d + String("/summary.md")), steps, rec), 3)
    var r = _last(rec)
    assert_equal(r.outcome, String("REFUSED"))
    assert_equal(r.error.id, String("KCI-E-CLOUD"))
    assert_true(r.error.message.startswith(String(NOT_BUILT_WITH)), r.error.message)
    assert_equal(r.steps[0].deploy.cloud, String("fake"))


def test_a_trust_finding_is_refused() raises:
    """Catches: a trust finding let through to the plan or apply."""
    var d = _root(String("trust"))
    var m = _machine(d, String(_BUCKETS), String("setting { key: \"principal\" value: \"deployer\" }"))
    var steps = Steps()
    var deploys = _deploys(FakeCloud())
    var rec = CliRecorder.memory(String(""))
    assert_equal(kci_main_with(_run(m, d + String("/summary.md")), steps, deploys, rec), 3)
    var r = _last(rec)
    assert_equal(r.outcome, String("REFUSED"))
    assert_equal(r.error.id, String("KCI-E-CLOUD"))
    assert_true(r.error.message.find(String("deployer")) >= 0, r.error.message)
    assert_equal(deploys.cloud.mutations(), 0)


comptime _PLAN_HASH: String = "035885901bad7ddde215dd5bd8c07dec302c280c1260a4ad80df35fb3d86185f"
"""sha256 of `[{"node":"cache/bucket","owner":"cache","verb":"create"},{"node":"logs/bucket",...},{"node":"media/bucket",...}]`,
computed outside kci (Python hashlib)."""


def test_plan_hash_is_over_the_actions_in_node_id_order() raises:
    """Catches: the sort by node id turned off (the hash then follows the
    order the actions came in)."""
    var unsorted = List[ChangeAction]()
    for n in ["media", "logs", "cache"]:
        unsorted.append(ChangeAction(String(n) + String("/bucket"), VERB_CREATE, String(""), 0, String(n)))
    assert_equal(plan_hash_of(unsorted), String(_PLAN_HASH))
    var sorted = List[ChangeAction]()
    for n in ["cache", "logs", "media"]:
        sorted.append(ChangeAction(String(n) + String("/bucket"), VERB_CREATE, String(""), 0, String(n)))
    assert_equal(plan_hash_of(sorted), String(_PLAN_HASH))
    var d = _root(String("hash-golden"))
    var m = _machine(d, String(_BUCKETS))
    var steps = Steps()
    var deploys = _deploys(FakeCloud())
    var rec = CliRecorder.memory(String(""))
    assert_equal(kci_main_with(_run(m, d + String("/summary.md"), plan=True), steps, deploys, rec), 0)
    assert_equal(_last(rec).steps[0].deploy.plan_hash, String(_PLAN_HASH))


def _deletes(deploys: CloudDeploys[FakeCloud, InMemoryStateStore, NoRegistryClient]) -> Int:
    var n = 0
    ref calls = deploys.cloud.store[].calls
    for i in range(len(calls)):
        if calls[i].startswith(String("delete ")):
            n += 1
    return n


def test_leftover_and_left_behind_are_reported_and_never_deleted() raises:
    """Catches: `leftover` or `left_behind` not set in the step row, not in
    the summary, or acted on (deleted)."""
    var d = _root(String("leftover"))
    var m = _machine(d, String(_BUCKETS))
    var steps = Steps()
    var deploys = _deploys(FakeCloud())
    var rec = CliRecorder.memory(String(""))
    assert_equal(kci_main_with(_run(m, d + String("/summary.md")), steps, deploys, rec), 0)
    write_whole_file(d + String("/app.json"), String('{"resource":[{"id":"media","secret":{}},{"id":"logs","bucket":{}}]}'))
    var rec2 = CliRecorder.memory(String(""))
    var rc = kci_main_with(_run(m, d + String("/summary2.md")), steps, deploys, rec2)
    var r = _last(rec2)
    assert_equal(rc, 0, r.error.message)
    ref row = r.steps[0].deploy
    assert_equal(len(row.leftover), 1)
    assert_equal(row.leftover[0], String("cache/bucket"))
    assert_equal(len(row.left_behind), 1)
    assert_equal(row.left_behind[0], String("media/bucket"))
    assert_equal(_deletes(deploys), 0, "kci deletes neither")
    assert_true(len(deploys.cloud.live_labels(String("cache/bucket"))) > 0, "the leftover object stands")
    assert_true(len(deploys.cloud.live_labels(String("media/bucket"))) > 0, "the left-behind object stands")
    var summary = Path(d + String("/summary2.md")).read_text()
    assert_true(summary.find(String("leftover (owned by resources the file no longer names; kci does not delete them): `cache/bucket`")) >= 0, summary)
    assert_true(summary.find(String("left behind (retained objects the file no longer lowers; kci does not delete them): `media/bucket`")) >= 0, summary)
    assert_true(summary.find(String("an apply run by hand outside CI is serialized with nothing")) >= 0, summary)
    assert_true(summary.find(String("v1 has no destroy verb")) >= 0, summary)


def test_a_cell_its_cells_file_does_not_declare_is_refused_at_load() raises:
    """Catches: the cells file not read at load (the step would run and
    refuse the cell itself, with a step row)."""
    var d = _root(String("undeclared"))
    var m = _machine(d, String(_BUCKETS), cell=String("green"))
    var steps = Steps()
    var deploys = _deploys(FakeCloud())
    var rec = CliRecorder.memory(String(""))
    assert_equal(kci_main_with(_run(m, d + String("/summary.md")), steps, deploys, rec), 3)
    var r = _last(rec)
    assert_equal(r.outcome, String("REFUSED"))
    assert_equal(r.error.id, String("KCI-E-FORMAT"))
    assert_true(r.error.message.find(String("names cell 'green'")) >= 0, r.error.message)
    assert_equal(len(r.steps), 0, "refused at load: no step ran")
    assert_equal(len(steps.hashed), 0, "refused before the start checks")
    assert_equal(deploys.cloud.mutations(), 0)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
