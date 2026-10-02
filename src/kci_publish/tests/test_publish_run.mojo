# =============================================================================
# src/kci_publish/tests/test_publish_run.mojo -- reading the plan from the
#   registry, and carrying it out.
# =============================================================================
#
# ROWS
#   (1) `plan_publish` reads presence once per target, anonymously, at the
#       subdir's repodata.json: ABSENT plans UPLOAD, identical plans SKIP;
#   (2) `verify_target_files` refuses a file whose sha256 is not its
#       manifest's, naming the file and both digests;
#   (3) --dry-run makes NO registry call: the transport fails on ANY request
#       and the credential records every ask, and both stay at zero;
#   (4) an upload is read back until identical: CREATED + identical is
#       UPLOADED; the index lagging one poll still converges; never
#       identical within the polls is exit 5;
#   (5) a 409 is settled by reading back: identical is SKIPPED, different
#       fails (exit 3 when nothing was uploaded yet);
#   (6) a lost upload answer (a transport fault) is settled the same way:
#       identical is UPLOADED, absent is exit 5;
#   (7) exit 4 once something was uploaded; exit 3 when the first upload
#       fails, and later entries are NOT-ATTEMPTED with no request sent;
#   (8) the credential is asked before the first upload: a refusal there is
#       exit 3 with zero requests;
#   (9) a plan holding a REFUSE uploads nothing: exit 3, or 5 when every
#       refusal is a read that could not be answered;
#  (10) a file that changed since it was planned is refused before its
#       upload request.
#
# Hermetic: scripted transports and credentials over staged fixture files;
# no network.
# =============================================================================

from std.pathlib import Path
from std.testing import assert_equal, assert_false, assert_true

from komira_http.codec.types import HTTP_METHOD_GET, HTTP_METHOD_POST

from kci_pkg_upload import (
    PRESENCE_ABSENT,
    PRESENCE_PRESENT_DIFFERENT,
    PRESENCE_UNKNOWN,
    SURFACE_PREFIX_DEV,
    AnonymousCredential,
    ApprovedNames,
    ContentIdentity,
    PkgRequest,
    PkgResponse,
    PkgTransport,
    Presence,
    RegistrySet,
    ScriptedCredential,
    ScriptedPkgTransport,
)
from kci_pkg_upload.wire import bytes_of
from kci_release_channel import ChannelDeclaration, find_channel, parse_channels_file

from komira_retry import RecordingSleeper

from kci_publish import (
    ACTION_SKIP,
    ACTION_UPLOAD,
    EXIT_CANNOT_TELL,
    EXIT_FAILED,
    EXIT_OK,
    EXIT_REFUSED,
    ArtifactManifest,
    PublishPlan,
    PublishReport,
    PublishTarget,
    RunOptions,
    plan_from_presence,
    plan_publish,
    read_artifact_manifest,
    resolve_targets,
    run_publish,
    verify_target_files,
)


comptime _FX: String = "src/kci_publish/tests/fixtures/"
comptime _FILE: String = "example-pkg-1.2.3-h0_0.conda"
comptime _LINUX_SHA: String = "d92ee691780d0dbc4dd45de1287d8980462041de9bd2fe3d7f8b89044a18cf52"
comptime _OSX_SHA: String = "53fdee8fee19ebc9e3dd1441e92ad0a97d70a1f59a0b0066e005eaff188db73f"
comptime _TOKEN: String = "Bearer example-token-not-a-credential"


struct _Tripwire(PkgTransport, Deinitable):
    """A transport that fails on ANY request and counts them."""

    var calls: Int

    def __init__(out self):
        self.calls = 0

    def exchange(mut self, req: PkgRequest) raises -> PkgResponse:
        self.calls += 1
        raise Error(String("tripwire: a request was sent to ") + req.host + req.path)


def _decls() raises -> List[ChannelDeclaration]:
    return parse_channels_file(Path(String(_FX) + String("channels.textproto")).read_text())


def _targets(*manifests: String) raises -> List[PublishTarget]:
    var ms = List[ArtifactManifest]()
    for m in manifests:
        ms.append(read_artifact_manifest(String(_FX) + String(m)))
    return resolve_targets(_decls(), String("example-stable"), ms)


def _plan(targets: List[PublishTarget], *kinds: Int) raises -> PublishPlan:
    var ps = List[Presence]()
    for k in kinds:
        ps.append(Presence(k, 200, ContentIdentity.none(), String("")))
    return plan_from_presence(find_channel(_decls(), String("example-stable")), targets, ps)


def _names() raises -> ApprovedNames:
    var n = ApprovedNames()
    n.approve(String("example-pkg"))
    return n^


def _cred() -> ScriptedCredential:
    var c = ScriptedCredential()
    c.serve(SURFACE_PREFIX_DEV, String(_TOKEN))
    return c^


def _repodata(subdir: String, sha: String) -> PkgResponse:
    var r = PkgResponse(200)
    var listed = String("")
    if sha.byte_length() > 0:
        listed = String('"') + String(_FILE) + String('": {"sha256": "') + sha + String('", "size": 29}')
    r.with_body(
        bytes_of(
            String('{"info": {"subdir": "')
            + subdir
            + String('"}, "packages": {}, "packages.conda": {')
            + listed
            + String("}}")
        )
    )
    return r^


def _set(var t: ScriptedPkgTransport) -> RegistrySet[ScriptedPkgTransport, ScriptedCredential]:
    return RegistrySet[ScriptedPkgTransport, ScriptedCredential](t^, _cred())


def _quick() -> RunOptions:
    return RunOptions(3, 250)


def _posts(rs: RegistrySet[ScriptedPkgTransport, ScriptedCredential]) -> Int:
    var n = 0
    for i in range(rs.transport().call_count()):
        if rs.transport().call(i).method == HTTP_METHOD_POST:
            n += 1
    return n


def _dump(r: PublishReport) -> String:
    return String("exit=") + String(r.exit_code) + String("\n") + String("\n").join(r.lines)


def test_plan_publish_reads_presence_anonymously() raises:
    var sl = RecordingSleeper()
    var ts = _targets(String("linux-64.json"), String("osx-arm64.json"))
    var t = ScriptedPkgTransport()
    t.queue(_repodata(String("linux-64"), String("")))
    t.queue(_repodata(String("osx-arm64"), String(_OSX_SHA)))
    var reader = RegistrySet[ScriptedPkgTransport, AnonymousCredential](t^, AnonymousCredential())
    var plan = plan_publish(reader, find_channel(_decls(), String("example-stable")), ts)
    assert_equal(plan.entries[0].action, ACTION_UPLOAD)
    assert_equal(plan.entries[1].action, ACTION_SKIP)
    assert_equal(reader.transport().call_count(), 2)
    var req = reader.transport().call(0)
    assert_equal(req.method, HTTP_METHOD_GET)
    assert_equal(req.host, String("conda.example.invalid"))
    assert_equal(req.path, String("/example-stable/linux-64/repodata.json"))
    assert_equal(req.header_value(String("Authorization")), String(""))
    assert_equal(reader.transport().call(1).path, String("/example-stable/osx-arm64/repodata.json"))


def test_verify_target_files() raises:
    var sl = RecordingSleeper()
    verify_target_files(_targets(String("linux-64.json"), String("osx-arm64.json")))
    var why = String("")
    try:
        verify_target_files(_targets(String("bad_sha.json")))
    except e:
        why = String(e)
    assert_true(why.find(String("refused before any upload")) >= 0, why)
    assert_true(why.find(String("linux-64/example-pkg-1.2.3-h0_0.conda' has sha256 ") + String(_LINUX_SHA)) >= 0, why)
    assert_true(why.find(String("its manifest says ") + String(_OSX_SHA)) >= 0, why)


def test_dry_run_makes_no_registry_call() raises:
    var sl = RecordingSleeper()
    var plan = _plan(_targets(String("linux-64.json"), String("osx-arm64.json")), PRESENCE_ABSENT, PRESENCE_ABSENT)
    var rs = RegistrySet[_Tripwire, ScriptedCredential](_Tripwire(), _cred())
    var r = run_publish(plan, rs, _names(), True, _quick(), sl)
    assert_equal(r.exit_code, EXIT_OK, _dump(r))
    assert_equal(rs.transport().calls, 0)
    assert_equal(rs.credential().asked_count(), 0)
    assert_equal(r.uploaded, 0)
    assert_true(r.has_line_containing(String("(dry run)")), _dump(r))
    assert_true(r.has_line_containing(String("UPLOAD https://conda.example.invalid/example-stable/linux-64/") + String(_FILE)), _dump(r))
    assert_true(r.has_line_containing(String("DRY RUN: nothing was uploaded")), _dump(r))
    assert_false(r.has_line_containing(String("UPLOADED")), _dump(r))
    assert_equal(len(sl.slept), 0)
    # The same plan, not a dry run, does reach the transport: the tripwire is live.
    var live = RegistrySet[_Tripwire, ScriptedCredential](_Tripwire(), _cred())
    var r2 = run_publish(plan, live, _names(), False, _quick(), sl)
    assert_true(live.transport().calls > 0)
    assert_true(r2.exit_code != EXIT_OK, _dump(r2))


def test_upload_is_read_back_until_identical() raises:
    var sl = RecordingSleeper()
    var plan = _plan(_targets(String("linux-64.json")), PRESENCE_ABSENT)
    var t = ScriptedPkgTransport()
    t.queue(PkgResponse(201))
    t.queue(_repodata(String("linux-64"), String(_LINUX_SHA)))
    var rs = _set(t^)
    var r = run_publish(plan, rs, _names(), False, _quick(), sl)
    assert_equal(r.exit_code, EXIT_OK, _dump(r))
    assert_equal(r.uploaded, 1)
    assert_true(r.has_line_containing(String("UPLOADED https://conda.example.invalid/example-stable/linux-64/") + String(_FILE)), _dump(r))
    assert_true(r.has_line_containing(String("RESULT exit=0 uploaded=1 skipped=0")), _dump(r))
    var post = rs.transport().call(0)
    assert_equal(post.method, HTTP_METHOD_POST)
    assert_equal(post.path, String("/api/v1/upload/example-stable"))
    assert_equal(post.header_value(String("Authorization")), String(_TOKEN))
    assert_equal(rs.transport().unconsumed(), 0)
    # the credential is asked once before any upload, then by the upload and the read-back
    assert_equal(rs.credential().asked_count(), 3)
    assert_equal(len(sl.slept), 0)

    var lag = ScriptedPkgTransport()
    lag.queue(PkgResponse(201))
    lag.queue(_repodata(String("linux-64"), String("")))
    lag.queue(_repodata(String("linux-64"), String(_LINUX_SHA)))
    var rs2 = _set(lag^)
    var r2 = run_publish(plan, rs2, _names(), False, _quick(), sl)
    assert_equal(r2.exit_code, EXIT_OK, _dump(r2))
    assert_equal(rs2.transport().unconsumed(), 0)
    # one wait, of the configured length, between the two read-backs
    assert_equal(len(sl.slept), 1)
    assert_equal(sl.slept[0], Int64(250))

    var never = ScriptedPkgTransport()
    never.queue(PkgResponse(201))
    never.queue(_repodata(String("linux-64"), String("")))
    never.queue(_repodata(String("linux-64"), String("")))
    var rs3 = _set(never^)
    var r3 = run_publish(plan, rs3, _names(), False, RunOptions(2, 250), sl)
    assert_equal(r3.exit_code, EXIT_CANNOT_TELL, _dump(r3))
    assert_true(r3.has_line_containing(String("UNCONFIRMED")), _dump(r3))
    assert_equal(len(sl.slept), 2)

    var other = ScriptedPkgTransport()
    other.queue(PkgResponse(201))
    other.queue(_repodata(String("linux-64"), String(_OSX_SHA)))
    var rs4 = _set(other^)
    var r4 = run_publish(plan, rs4, _names(), False, _quick(), sl)
    assert_equal(r4.exit_code, EXIT_FAILED, _dump(r4))
    assert_true(r4.has_line_containing(String("uploaded, but the registry reads back PRESENT_DIFFERENT")), _dump(r4))


def test_a_409_is_settled_by_reading_back() raises:
    var sl = RecordingSleeper()
    var plan = _plan(_targets(String("linux-64.json")), PRESENCE_ABSENT)
    var t = ScriptedPkgTransport()
    t.queue(PkgResponse(409))
    t.queue(_repodata(String("linux-64"), String(_LINUX_SHA)))
    var rs = _set(t^)
    var r = run_publish(plan, rs, _names(), False, _quick(), sl)
    assert_equal(r.exit_code, EXIT_OK, _dump(r))
    assert_equal(r.uploaded, 0)
    assert_equal(r.skipped, 1)
    assert_true(r.has_line_containing(String("uploaded by someone else since the plan, identical")), _dump(r))

    var d = ScriptedPkgTransport()
    d.queue(PkgResponse(409))
    d.queue(_repodata(String("linux-64"), String(_OSX_SHA)))
    var rs2 = _set(d^)
    var r2 = run_publish(plan, rs2, _names(), False, _quick(), sl)
    assert_equal(r2.exit_code, EXIT_REFUSED, _dump(r2))
    assert_true(r2.has_line_containing(String("DUPLICATE_REFUSED")), _dump(r2))
    assert_true(r2.has_line_containing(String("PRESENT_DIFFERENT")), _dump(r2))
    assert_equal(_posts(rs2), 1)


def test_a_lost_answer_is_settled_by_reading_back() raises:
    var sl = RecordingSleeper()
    var plan = _plan(_targets(String("linux-64.json")), PRESENCE_ABSENT)
    var t = ScriptedPkgTransport()
    t.queue_fault(String("connection reset after the body was sent"))
    t.queue(_repodata(String("linux-64"), String(_LINUX_SHA)))
    var rs = _set(t^)
    var r = run_publish(plan, rs, _names(), False, _quick(), sl)
    assert_equal(r.exit_code, EXIT_OK, _dump(r))
    assert_equal(r.uploaded, 1)
    assert_true(r.has_line_containing(String("the upload's answer was lost")), _dump(r))

    var a = ScriptedPkgTransport()
    a.queue_fault(String("connection reset after the body was sent"))
    a.queue(_repodata(String("linux-64"), String("")))
    var rs2 = _set(a^)
    var r2 = run_publish(plan, rs2, _names(), False, _quick(), sl)
    assert_equal(r2.exit_code, EXIT_CANNOT_TELL, _dump(r2))
    assert_true(r2.has_line_containing(String("UNCONFIRMED")), _dump(r2))


def test_exit_4_after_an_upload_and_3_before() raises:
    var sl = RecordingSleeper()
    var plan = _plan(_targets(String("linux-64.json"), String("osx-arm64.json")), PRESENCE_ABSENT, PRESENCE_ABSENT)
    var t = ScriptedPkgTransport()
    t.queue(PkgResponse(201))
    t.queue(_repodata(String("linux-64"), String(_LINUX_SHA)))
    t.queue(PkgResponse(422))
    var rs = _set(t^)
    var r = run_publish(plan, rs, _names(), False, _quick(), sl)
    assert_equal(r.exit_code, EXIT_FAILED, _dump(r))
    assert_equal(r.uploaded, 1)
    assert_true(r.has_line_containing(String("FAILED https://conda.example.invalid/example-stable/osx-arm64/")), _dump(r))
    assert_true(r.has_line_containing(String("REJECTED (HTTP 422)")), _dump(r))

    var f = ScriptedPkgTransport()
    f.queue(PkgResponse(403))
    var rs2 = _set(f^)
    var r2 = run_publish(plan, rs2, _names(), False, _quick(), sl)
    assert_equal(r2.exit_code, EXIT_REFUSED, _dump(r2))
    assert_true(r2.has_line_containing(String("AUTH_REFUSED")), _dump(r2))
    assert_true(r2.has_line_containing(String("NOT-ATTEMPTED https://conda.example.invalid/example-stable/osx-arm64/")), _dump(r2))
    assert_equal(rs2.transport().call_count(), 1)


def test_the_credential_is_asked_before_the_first_upload() raises:
    var sl = RecordingSleeper()
    var plan = _plan(_targets(String("linux-64.json")), PRESENCE_ABSENT)
    var rs = RegistrySet[_Tripwire, ScriptedCredential](_Tripwire(), ScriptedCredential())
    var r = run_publish(plan, rs, _names(), False, _quick(), sl)
    assert_equal(r.exit_code, EXIT_REFUSED, _dump(r))
    assert_true(r.has_line_containing(String("REFUSED credential")), _dump(r))
    assert_true(r.has_line_containing(String("NOT-ATTEMPTED")), _dump(r))
    assert_equal(rs.transport().calls, 0)


def test_a_plan_with_a_refusal_uploads_nothing() raises:
    var sl = RecordingSleeper()
    var ts = _targets(String("linux-64.json"), String("osx-arm64.json"))
    var definite = _plan(ts, PRESENCE_ABSENT, PRESENCE_PRESENT_DIFFERENT)
    var rs = RegistrySet[_Tripwire, ScriptedCredential](_Tripwire(), _cred())
    var r = run_publish(definite, rs, _names(), False, _quick(), sl)
    assert_equal(r.exit_code, EXIT_REFUSED, _dump(r))
    assert_true(r.has_line_containing(String("REFUSE https://conda.example.invalid/example-stable/osx-arm64/")), _dump(r))
    assert_true(r.has_line_containing(String("REFUSED before any upload: 1 artifact(s)")), _dump(r))
    assert_equal(rs.transport().calls, 0)
    assert_equal(rs.credential().asked_count(), 0)
    var unknown = _plan(ts, PRESENCE_ABSENT, PRESENCE_UNKNOWN)
    var r2 = run_publish(unknown, rs, _names(), False, _quick(), sl)
    assert_equal(r2.exit_code, EXIT_CANNOT_TELL, _dump(r2))
    assert_equal(rs.transport().calls, 0)


def test_a_changed_file_is_refused_before_its_upload() raises:
    var sl = RecordingSleeper()
    var plan = _plan(_targets(String("bad_sha.json")), PRESENCE_ABSENT)
    var t = ScriptedPkgTransport()
    var rs = _set(t^)
    var r = run_publish(plan, rs, _names(), False, _quick(), sl)
    assert_equal(r.exit_code, EXIT_REFUSED, _dump(r))
    assert_true(r.has_line_containing(String("changed since it was planned")), _dump(r))
    assert_equal(rs.transport().call_count(), 0)


def main() raises:
    test_plan_publish_reads_presence_anonymously()
    test_verify_target_files()
    test_dry_run_makes_no_registry_call()
    test_upload_is_read_back_until_identical()
    test_a_409_is_settled_by_reading_back()
    test_a_lost_answer_is_settled_by_reading_back()
    test_exit_4_after_an_upload_and_3_before()
    test_the_credential_is_asked_before_the_first_upload()
    test_a_plan_with_a_refusal_uploads_nothing()
    test_a_changed_file_is_refused_before_its_upload()
    print("test_publish_run: ALL PASS")
