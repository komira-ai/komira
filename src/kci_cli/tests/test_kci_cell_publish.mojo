# =============================================================================
# src/kci_cli/tests/test_kci_cell_publish.mojo -- a PUBLISH step into a cell
#   end to end through `kci_main_with`, on
#   `CloudDeploys[FakeCloud, InMemoryStateStore, _Registry]`.
# =============================================================================
#
# The machine file is named `shop`; its stage `cell` holds one PUBLISH step,
# `push`, into cell `blue` (cloud `fake`) of a cells file. The release
# directory is a real one: one OCI member `web` (a layout komira_oci's
# `write_test_layout` writes, its artifact manifest, and the `release.json`
# kci_release_set computes), so the step's own load (`verify_member`) runs
# over real bytes. The registry is komira_oci's in-process `FakeOciRegistry`
# whose host is the fake cell's registry, `shop-blue-images`, written here
# as a literal (the fakes' `<machine>-<cell>-images`), not asked of the code
# under test. It answers 404 to any other host. `_Registry` shares one fake
# registry between the copies the step makes (one per push), and can serve
# another digest when the pushed manifest is read back by digest.
#
#   1. A push to the cell's registry: SUCCEEDED, exit 0; the tag `<revision>`
#      of repository `web` on host `shop-blue-images` names the member's
#      digest; the row is a PUBLISH row naming the cell and its cloud; the
#      artifact row is `shop-blue-images/web@<digest>`, UPLOADED; the
#      registry saw the basic auth of the adapter's `registry_login`
#      (`oauth2accesstoken` and the credential's token) and nothing else
#      ever reached it (it refuses any other authorization); the token is in
#      no message and not in the summary; the seam's channel `publish` was
#      never called. Then a second push: NOOP, exit 0, ALREADY_PRESENT, and
#      no PUT reached the registry.
#   2. A registry that serves another digest at read-back: INDETERMINATE,
#      exit 5, KCI-E-IMAGE-PUSH (komira_oci's step 6; asserted here only as
#      the cell path's mapping).
#   3. `--plan`: SUCCEEDED, exit 0, zero requests on the registry, the image
#      WOULD_UPLOAD, no set hash handed on.
#   4. The step holds the release set itself: a run handed a set hash the
#      start-up check accepts (the seam's recompute is faked to agree) but
#      the release directory does not recompute to is REFUSED by the step,
#      exit 3, KCI-E-SET-HASH, with zero requests.
#   5. A trust finding (the cell's `principal` is not who the credential
#      is): REFUSED, exit 3, KCI-E-CLOUD, zero requests.
#   6. The kci binary's cells (`NoCloudBuilt`): REFUSED, exit 3, "this kci
#      was not built with that cloud".
#   7. Without --release-set-hash: a usage error, exit 2.
# =============================================================================

from std.ffi import external_call
from std.memory import ArcPointer
from std.os import getenv, makedirs
from std.pathlib import Path
from std.testing import TestSuite, assert_equal, assert_false, assert_true

from komira_http_core.codec.types import HTTP_METHOD_HEAD, HTTP_METHOD_PUT
from komira_oci.oci_fake_registry import FakeOciRegistry
from komira_oci.oci_layout_fixture import write_test_layout
from komira_oci.oci_transport import OciRequest, OciResponse, OciTransport

from kci_build import BuildRequest
from kci_reconciler import Creds, InMemoryStateStore
from kci_cloud_fake import FakeCloud
from kci_cli import (
    NOT_BUILT_WITH,
    CliRecorder,
    CloudDeploys,
    SecretStoreChoice,
    StageSteps,
    StepEnd,
    kci_main_with,
    write_whole_file,
)
from kci_api import ResultValidation, parse_result
from kci_api import RunResult as KciRunResult
from kci_publish import NewNamesReport, PublishRequest
from kci_release_set import ReleaseIdentity, ReleaseMember, release_manifest_of, render_release_manifest, verify_member
from kci_validate import ValidateRequest

comptime _REV: String = "a1b2c3d4e5f60718293a4b5c6d7e8f9012345678"
comptime _HOST: String = "shop-blue-images"
comptime _TOKEN: String = "tok-secret-do-not-print"
comptime _OTHER_HASH: String = "0000000000000000000000000000000000000000000000000000000000000000"
comptime _OTHER_DIGEST: String = "sha256:1111111111111111111111111111111111111111111111111111111111111111"


struct Steps(StageSteps, Movable):
    """The seam's other steps, never reached here (a channel `publish`
    counts its calls), and the set hash the start-up check recomputes to
    (`hash`). Layout: owned values only."""

    var hash: String
    var published: Int

    def __init__(out self, hash: String):
        self.hash = hash.copy()
        self.published = 0

    def build(mut self, req: BuildRequest, mut result: KciRunResult, mut recorder: CliRecorder) -> StepEnd:
        return StepEnd(String("FAILED"), String("KCI-E-INTERNAL"), String("no BUILD step runs here"))

    def publish(
        mut self, req: PublishRequest, mut result: KciRunResult, mut recorder: CliRecorder, store: SecretStoreChoice
    ) -> StepEnd:
        self.published += 1
        return StepEnd(String("FAILED"), String("KCI-E-INTERNAL"), String("no channel PUBLISH step runs here"))

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
        return self.hash.copy()


struct _Registry(OciTransport, Copyable, Movable, Deinitable):
    """One `FakeOciRegistry` shared by every copy (the step copies its
    registry client into each push). With `lie_digest` set, a manifest
    HEAD by digest that would answer 200 answers 200 with that digest
    instead: a registry serving another digest at read-back."""

    var reg: ArcPointer[FakeOciRegistry]
    var lie_digest: String

    def __init__(out self, lie_digest: String = String("")):
        self.reg = ArcPointer[FakeOciRegistry](FakeOciRegistry(String(_HOST)))
        self.lie_digest = lie_digest.copy()

    def send(mut self, var request: OciRequest) raises -> OciResponse:
        var by_digest = request.method == HTTP_METHOD_HEAD and request.path.find(String("/manifests/sha256:")) >= 0
        var r = self.reg[].send(request^)
        if self.lie_digest.byte_length() > 0 and by_digest and r.status == 200:
            var lied = OciResponse(200)
            lied.with_header(String("docker-content-digest"), self.lie_digest.copy())
            return lied^
        return r^


def _chdir(path: String) raises:
    var c = path.copy()
    # SAFETY: `c` is a local that outlives the call; chdir reads the
    # NUL-terminated string and keeps no pointer to it.
    var rc = external_call["chdir", Int32](c.as_c_string_slice().unsafe_ptr())
    if rc != 0:
        raise Error("chdir failed: " + path)


def _bytes(s: String) -> List[UInt8]:
    var out = List[UInt8]()
    var src = s.as_bytes()
    for i in range(len(src)):
        out.append(src[i])
    return out^


struct _Fixture(Movable):
    """A case's directory (the working directory), its machine file, and
    the release set's hash and image digest."""

    var dir: String
    var machine: String
    var set_hash: String
    var digest: String

    def __init__(out self, var dir: String, var machine: String, var set_hash: String, var digest: String):
        self.dir = dir^
        self.machine = machine^
        self.set_hash = set_hash^
        self.digest = digest^


def _fixture(tag: String, settings: String = String("")) raises -> _Fixture:
    """The machine file, cells file, artifacts file and release directory
    (file header) in a fresh directory, made the working directory."""
    var base = getenv("TEST_TMPDIR")
    if base.byte_length() == 0:
        base = getenv("TMPDIR")
    if base.byte_length() == 0:
        raise Error("neither TEST_TMPDIR nor TMPDIR is set")
    var d = base + String("/kci_cell_publish_") + tag + String("_") + String(Int(external_call["getpid", Int32]()))
    makedirs(d, exist_ok=True)
    _chdir(d)
    write_whole_file(
        d + String("/cells.textproto"),
        String("schema_version: 1\ncell { name: \"blue\" cloud: \"fake\" ") + settings + String(" bootstrap_level: 1 }\n"),
    )
    write_whole_file(
        d + String("/a.textproto"),
        String("schema_version: 1\nbuild_systems {\n  name: \"buck2\"\n  executable: \"buck2\"\n  args: \"build\"\n}\n")
        + String("artifacts {\n  name: \"web\"\n  build_system: \"buck2\"\n  args: \"//src/web:release\"\n")
        + String("  args: \"--out\"\n  args: \"{out_dir}\"\n}\n"),
    )
    var member = d + String("/rel/linux-x86_64/web")
    var layers = List[List[UInt8]]()
    layers.append(_bytes(String("web-layer-one-") + tag))
    var digest = write_test_layout(member + String("/web.oci"), layers, String("linux"), String("amd64"))
    write_whole_file(
        member + String("/manifest.json"),
        String('{"format":"kci.artifact_manifest","schema_version":1,"artifact_type":"OCI",')
        + String('"name":"web","version":"0.1.0","platform":"linux-x86_64",')
        + String('"file":"web.oci","sha256":"') + String(digest[byte=7:]) + String('"}\n'),
    )
    var members = List[ReleaseMember]()
    members.append(verify_member(String("web"), member))
    var manifest = release_manifest_of(members, ReleaseIdentity(String(_REV), String("linux-x86_64"), String("gh-1"), 1))
    write_whole_file(d + String("/rel/linux-x86_64/release.json"), render_release_manifest(manifest))
    var m = d + String("/machine.textproto")
    write_whole_file(
        m,
        String("schema_version: 1\nname: \"shop\"\n")
        + String("stage { name: \"cell\" step { name: \"push\" kind: PUBLISH platform: \"linux-x86_64\" ")
        + String("artifacts: \"a.textproto\" cells: \"cells.textproto\" cell: \"blue\" } }\n"),
    )
    return _Fixture(d^, m^, manifest.set_hash.copy(), digest^)


def _run(f: _Fixture, summary: String, plan: Bool = False, hash: String = String("-")) -> List[String]:
    var l = List[String]()
    for s in ["run", "--machine"]:
        l.append(String(s))
    l.append(f.machine.copy())
    for s in ["--stage", "cell", "--revision-id"]:
        l.append(String(s))
    l.append(String(_REV))
    for s in ["--run-id", "gh-7", "--attempt", "2", "--release-dir"]:
        l.append(String(s))
    l.append(f.dir + String("/rel"))
    l.append(String("--summary-file"))
    l.append(summary.copy())
    var h = f.set_hash.copy() if hash == String("-") else hash.copy()
    if h.byte_length() > 0:
        l.append(String("--release-set-hash"))
        l.append(h^)
    if plan:
        l.append(String("--plan"))
    return l^


def _last(rec: CliRecorder) raises -> KciRunResult:
    return parse_result(rec.records[len(rec.records) - 1], String("record"))


def _cells(var registry: _Registry) raises -> CloudDeploys[FakeCloud, InMemoryStateStore, _Registry]:
    return CloudDeploys[FakeCloud, InMemoryStateStore, _Registry](
        FakeCloud(), InMemoryStateStore(), Creds(String(_TOKEN)), registry^, 0
    )


def _basic_auth() -> String:
    """The Authorization a client presenting the fakes' registry login
    (`oauth2accesstoken`, the token) sends, as komira_oci spells it."""
    var probe = OciRequest(HTTP_METHOD_HEAD, String(_HOST), String("/v2/"))
    probe.with_basic(String("oauth2accesstoken"), String(_TOKEN))
    return probe.header_value(String("authorization"))


def test_a_push_to_the_cells_registry_then_a_second_push_is_noop() raises:
    """Catches: the push sent anywhere but `image_registry(ctx)`, the login
    not the adapter's, the cell PUBLISH routed to the channel seam, a NOOP
    re-push reported as SUCCEEDED (the row's success case)."""
    var f = _fixture(String("push"))
    var steps = Steps(f.set_hash)
    var cells = _cells(_Registry())
    cells.registry.reg[].required_authorization = _basic_auth()
    var rec = CliRecorder.memory(String(""))
    var summary = f.dir + String("/summary.md")
    assert_equal(kci_main_with(_run(f, summary), steps, cells, rec), 0)
    var r = _last(rec)
    assert_equal(r.outcome, String("SUCCEEDED"), r.error.message)
    assert_equal(steps.published, 0, "a PUBLISH into a cell never reaches the channel seam")
    assert_equal(len(r.steps), 1)
    ref row = r.steps[0]
    assert_equal(row.kind, String("PUBLISH"))
    assert_equal(row.name, String("push"))
    assert_equal(row.deploy.cell, String("blue"))
    assert_equal(row.deploy.cloud, String("fake"))
    ref reg = cells.registry.reg[]
    assert_equal(reg.tag_digest(String("web"), String(_REV)), f.digest, "the tag is the revision and names the set's digest")
    assert_equal(reg.calls_to_other_hosts(), 0)
    assert_true(reg.count_calls(HTTP_METHOD_PUT, String("/manifests/")) >= 1)
    for i in range(reg.call_count()):
        assert_equal(reg.call_auth(i), _basic_auth(), "every request carries registry_login's credential")
    assert_equal(len(r.artifacts), 1)
    assert_equal(r.artifacts[0].file, String(_HOST) + String("/web@") + f.digest)
    assert_equal(r.artifacts[0].effect, String("UPLOADED"))
    assert_equal(r.artifacts[0].artifact_type, String("OCI"))
    assert_equal(r.artifacts[0].revision, String(_REV))
    assert_equal(r.set_hash, f.set_hash, "the recomputed set is handed on")
    var text = Path(summary).read_text()
    assert_true(text.find(String("into cell `blue`")) >= 0, text)
    assert_equal(text.find(String(_TOKEN)), -1, "the token is never in the summary")
    assert_equal(r.error.message.find(String(_TOKEN)), -1)
    var puts = reg.count_calls(HTTP_METHOD_PUT, String(""))
    var rec2 = CliRecorder.memory(String(""))
    assert_equal(kci_main_with(_run(f, f.dir + String("/summary2.md")), steps, cells, rec2), 0)
    var r2 = _last(rec2)
    assert_equal(r2.outcome, String("NOOP"), r2.error.message)
    assert_equal(r2.steps[0].outcome, String("NOOP"))
    assert_equal(r2.artifacts[0].effect, String("ALREADY_PRESENT"))
    assert_equal(cells.registry.reg[].count_calls(HTTP_METHOD_PUT, String("")), puts, "a NOOP sends no PUT")


def test_another_digest_at_read_back_is_indeterminate_exit_5() raises:
    """Catches: komira_oci's read-back mismatch (PUSH_INDETERMINATE) mapped
    to anything but INDETERMINATE, exit 5, through the cell path."""
    var f = _fixture(String("readback"))
    var steps = Steps(f.set_hash)
    var cells = _cells(_Registry(String(_OTHER_DIGEST)))
    var rec = CliRecorder.memory(String(""))
    assert_equal(kci_main_with(_run(f, f.dir + String("/summary.md")), steps, cells, rec), 5)
    var r = _last(rec)
    assert_equal(r.outcome, String("INDETERMINATE"))
    assert_equal(r.steps[0].outcome, String("INDETERMINATE"))
    assert_equal(r.error.id, String("KCI-E-IMAGE-PUSH"))
    assert_true(r.error.message.find(String("read-back")) >= 0, r.error.message)


def test_plan_sends_nothing_to_the_registry() raises:
    """Catches: `--plan` passed to the push as an apply (requests sent)."""
    var f = _fixture(String("plan"))
    var steps = Steps(f.set_hash)
    var cells = _cells(_Registry())
    var rec = CliRecorder.memory(String(""))
    assert_equal(kci_main_with(_run(f, f.dir + String("/summary.md"), plan=True), steps, cells, rec), 0)
    var r = _last(rec)
    assert_equal(r.outcome, String("SUCCEEDED"), r.error.message)
    assert_true(r.plan)
    assert_equal(cells.registry.reg[].call_count(), 0, "a plan sends nothing")
    assert_equal(r.artifacts[0].effect, String("WOULD_UPLOAD"))
    assert_equal(r.set_hash, String(""), "a dry run hands on no set")


def test_the_step_holds_the_release_set_itself() raises:
    """Catches: the step trusting the start-up check alone (the set-hash
    comparison removed from `load_cell_release`)."""
    var f = _fixture(String("sethash"))
    var steps = Steps(String(_OTHER_HASH))
    var cells = _cells(_Registry())
    var rec = CliRecorder.memory(String(""))
    assert_equal(kci_main_with(_run(f, f.dir + String("/summary.md"), hash=String(_OTHER_HASH)), steps, cells, rec), 3)
    var r = _last(rec)
    assert_equal(r.outcome, String("REFUSED"))
    assert_equal(r.error.id, String("KCI-E-SET-HASH"))
    assert_equal(len(r.steps), 1, "the step ran and refused")
    assert_true(r.error.message.find(f.set_hash) >= 0, r.error.message)
    assert_equal(cells.registry.reg[].call_count(), 0)


def test_a_trust_finding_is_refused_before_any_request() raises:
    """Catches: a trust finding let through to the push."""
    var f = _fixture(String("trust"), String("setting { key: \"principal\" value: \"deployer\" }"))
    var steps = Steps(f.set_hash)
    var cells = _cells(_Registry())
    var rec = CliRecorder.memory(String(""))
    assert_equal(kci_main_with(_run(f, f.dir + String("/summary.md")), steps, cells, rec), 3)
    var r = _last(rec)
    assert_equal(r.outcome, String("REFUSED"))
    assert_equal(r.error.id, String("KCI-E-CLOUD"))
    assert_true(r.error.message.find(String("deployer")) >= 0, r.error.message)
    assert_equal(cells.registry.reg[].call_count(), 0)


def test_the_kci_binary_refuses_every_publish_into_a_cell() raises:
    """Catches: the binary's cells (no cloud built in) pushing, or refusing
    for another reason."""
    var f = _fixture(String("binary"))
    var steps = Steps(f.set_hash)
    var rec = CliRecorder.memory(String(""))
    assert_equal(kci_main_with(_run(f, f.dir + String("/summary.md")), steps, rec), 3)
    var r = _last(rec)
    assert_equal(r.outcome, String("REFUSED"))
    assert_equal(r.error.id, String("KCI-E-CLOUD"))
    assert_true(r.error.message.find(String(NOT_BUILT_WITH)) >= 0, r.error.message)
    assert_equal(r.steps[0].deploy.cloud, String("fake"))


def test_the_set_hash_flag_is_required() raises:
    """Catches: a PUBLISH into a cell run with no set to hold it to."""
    var f = _fixture(String("flag"))
    var steps = Steps(f.set_hash)
    var cells = _cells(_Registry())
    var rec = CliRecorder.memory(String(""))
    assert_equal(kci_main_with(_run(f, f.dir + String("/summary.md"), hash=String("")), steps, cells, rec), 2)
    assert_equal(_last(rec).error.id, String("KCI-E-USAGE"))
    assert_true(_last(rec).error.message.find(String("--release-set-hash")) >= 0)
    assert_equal(cells.registry.reg[].call_count(), 0)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
