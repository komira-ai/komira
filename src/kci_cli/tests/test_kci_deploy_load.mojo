# =============================================================================
# src/kci_cli/tests/test_kci_deploy_load.mojo -- a DEPLOY step's step 1
#   (deploy_step.mojo `_load`): the files it reads, and what each one it
#   cannot use ends the run with. FakeCloud and an in-memory state store; no
#   cloud call is made by any refused run.
# =============================================================================
#
#   1. A resource list that is not JSON: REFUSED, exit 3, KCI-E-FORMAT,
#      naming the file. Mutant: the resource list's refusal given another
#      error id (the message check fails).
#   2. A `definitions` file that is not JSON: REFUSED, exit 3, KCI-E-FORMAT,
#      naming the file.
#   3. A `definitions` file defining `kci.job`, a definition kci ships:
#      REFUSED, exit 3, naming the file and the definition. Mutant: the
#      shipped-name loop removed (the run plans and exits 0).
#   4. A `definitions` file defining a new name: the plan runs, exit 0 (the
#      definition is added after the shipped ones, not refused).
#
# The machine file, cells file and resource list are test_kci_deploy_step's
# shape (each gated test is built from its one file, so each carries its own
# copy of the helpers).
# =============================================================================

from std.ffi import external_call
from std.os import getenv, makedirs
from std.testing import TestSuite, assert_equal, assert_true

from kci_build import BuildRequest
from kci_reconciler import Creds, InMemoryStateStore
from kci_cloud_fake import FakeCloud
from kci_cli import (
    CliRecorder,
    CloudDeploys,
    NoRegistryClient,
    SecretStoreChoice,
    StageSteps,
    StepEnd,
    kci_main_with,
    write_whole_file,
)
from kci_api import ResultValidation, parse_result
from kci_api import RunResult as KciRunResult
from kci_publish import NewNamesReport, PublishRequest
from kci_validate import ValidateRequest


comptime _REV: String = "a1b2c3d4e5f60718293a4b5c6d7e8f9012345678"
comptime _SET_HASH: String = "5e7a5e7a5e7a5e7a5e7a5e7a5e7a5e7a5e7a5e7a5e7a5e7a5e7a5e7a5e7a5e7a"
comptime _BUCKETS: String = '{"resource":[{"id":"media","bucket":{}}]}'


struct Steps(StageSteps, Movable):
    """The seam's other steps, never reached here. Layout: no fields."""

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

    def main_tip_past(mut self, revision: String) raises -> String:
        raise Error(String("main_tip_past is not asked in this test"))

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
    var d = base + String("/kci_deploy_load_") + tag + String("_") + String(Int(external_call["getpid", Int32]()))
    makedirs(d, exist_ok=True)
    _chdir(d)
    return d^


def _machine(dir: String, resources: String, definitions: String = String("")) raises -> String:
    """The machine file in `dir` (the working directory), its cells file, the
    resource list `resources` (app.json) and, when `definitions` is not "",
    one definitions file holding it (defs.json)."""
    write_whole_file(dir + String("/cells.textproto"), String("schema_version: 1\ncell { name: \"blue\" cloud: \"fake\" bootstrap_level: 1 }\n"))
    write_whole_file(dir + String("/app.json"), resources)
    var defs = String("")
    if definitions.byte_length() > 0:
        write_whole_file(dir + String("/defs.json"), definitions)
        defs = String(" definitions: \"defs.json\"")
    var m = dir + String("/machine.textproto")
    write_whole_file(
        m,
        String("schema_version: 1\nname: \"shop\"\n")
        + String("stage { name: \"build\" step { name: \"b\" kind: BUILD platform: \"linux-x86_64\" artifacts: \"a.textproto\" } }\n")
        + String("stage { name: \"deploy\" after: \"build\" step { name: \"apply\" kind: DEPLOY cells: \"")
        + dir + String("/cells.textproto\" cell: \"blue\" resources: \"app.json\"") + defs + String(" } }\n"),
    )
    return m^


def _run(machine: String) -> List[String]:
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
    l.append(String("--plan"))
    return l^


struct _Seen(Movable):
    var rc: Int
    var outcome: String
    var error_id: String
    var message: String
    var calls: Int

    def __init__(out self):
        self.rc = -1
        self.outcome = String("")
        self.error_id = String("")
        self.message = String("")
        self.calls = -1


def _deploy(tag: String, resources: String, definitions: String = String("")) raises -> _Seen:
    """One `--plan` run of the deploy stage; what it ended with."""
    var m = _machine(_root(tag), resources, definitions)
    var steps = Steps()
    var deploys = CloudDeploys[FakeCloud, InMemoryStateStore, NoRegistryClient](
        FakeCloud(), InMemoryStateStore(), Creds.none(), NoRegistryClient()
    )
    var rec = CliRecorder.memory(String(""))
    var seen = _Seen()
    seen.rc = kci_main_with(_run(m), steps, deploys, rec)
    var r = parse_result(rec.records[len(rec.records) - 1], String("record"))
    seen.outcome = r.outcome.copy()
    seen.error_id = r.error.id.copy()
    seen.message = r.error.message.copy()
    seen.calls = deploys.cloud.mutations()
    return seen^


def _refused(s: _Seen, message: String) raises:
    assert_equal(s.rc, 3, s.message)
    assert_equal(s.outcome, String("REFUSED"))
    assert_equal(s.error_id, String("KCI-E-FORMAT"))
    assert_true(s.message.startswith(message), s.message)
    assert_equal(s.calls, 0)


def test_a_resource_list_that_is_not_json_is_refused() raises:
    _refused(_deploy(String("resources"), String("{not json")), String("the resource list 'app.json': "))


def test_a_definitions_file_that_is_not_json_is_refused() raises:
    _refused(
        _deploy(String("defs-bad"), String(_BUCKETS), String("{not json")), String("the definitions file 'defs.json': ")
    )


def test_a_definitions_file_redefining_a_shipped_definition_is_refused() raises:
    _refused(
        _deploy(String("defs-shipped"), String(_BUCKETS), String('{"name":"kci.job","version":"1"}')),
        String("the definitions file 'defs.json' redefines 'kci.job', a definition kci ships"),
    )


def test_a_definitions_file_with_a_new_name_is_added() raises:
    var s = _deploy(String("defs-new"), String(_BUCKETS), String('{"name":"shop.thing","version":"1","component":[{"id":"files","bucket":{}}]}'))
    assert_equal(s.rc, 0, s.message)
    assert_equal(s.calls, 0, "a plan calls nothing")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
