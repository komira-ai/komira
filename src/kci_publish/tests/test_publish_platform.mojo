# =============================================================================
# src/kci_publish/tests/test_publish_platform.mojo -- the release identity a
#   PUBLISH step publishes: the revision and the platform, and where it
#   reads the release from.
# =============================================================================
#
# ROWS
#   (1) `--revision-id` must be the revision `release.json` names: another
#       full commit id is REFUSED (KCI-E-REVISION-MISMATCH) with ZERO
#       requests and no RUNNING record; an abbreviated one is REFUSED
#       (KCI-E-REVISION);
#   (2) the step's platform must be one kci releases: a reserved one
#       (darwin-arm64) and the member-only `noarch` are REFUSED
#       (KCI-E-PLATFORM), zero requests;
#   (3) the step reads `<release-dir>/<platform>/`: a release written at
#       the top of `--release-dir` (no platform directory) is REFUSED
#       (KCI-E-MEMBER), zero requests;
#   (4) every file lands in its platform's conda subdir (linux-x86_64 ->
#       linux-64), and the result's rows name the platform and the revision;
#   (5) the request's own values: a concurrency outside 1..16 and an empty
#       stage are each REFUSED with KCI-E-USAGE, which the exit table makes
#       exit 2, before anything is read. There is no set-hash or claim input
#       to refuse.
#
# Hermetic: TEST_TMPDIR, ScriptedChannel; no network.
# =============================================================================

from std.ffi import external_call
from std.os import getenv, makedirs
from std.testing import assert_equal, assert_true

from kci_api import (
    ERROR_MEMBER,
    ERROR_PLATFORM,
    ERROR_REVISION,
    ERROR_REVISION_MISMATCH,
    ERROR_USAGE,
    EXIT_OK,
    EXIT_REFUSED,
    EXIT_USAGE,
    MemoryRecorder,
)
from kci_api import RunResult as KciRunResult
from kci_pkg_upload import RegistrySet, ScriptedPkgTransport
from kci_publish import (
    ActionsOidcEnv,
    NoSecretStore,
    NoWaitSleeper,
    PublishCredential,
    PublishReport,
    PublishRequest,
    RunOptions,
    ScriptedChannel,
    publish_flow,
)
from kci_publish.release_fixture import EXAMPLE_HOST, ExampleRelease, example_channel_path, write_example_inputs


def _root(tag: String) raises -> String:
    var base = getenv("TEST_TMPDIR")
    if base.byte_length() == 0:
        base = getenv("TMPDIR")
    if base.byte_length() == 0:
        raise Error("neither TEST_TMPDIR nor TMPDIR is set")
    var d = base + String("/ppl_") + tag + String("_") + String(Int(external_call["getpid", Int32]()))
    makedirs(d, exist_ok=True)
    return d^


def _bytes(s: String) -> List[UInt8]:
    var out = List[UInt8]()
    var b = s.as_bytes()
    for i in range(len(b)):
        out.append(b[i])
    return out^


def _channel() raises -> ScriptedChannel:
    var ch = ScriptedChannel(String(EXAMPLE_HOST), example_channel_path(String("example-stable")), String("linux-64"))
    ch.put(String("linux-64"), String("komira_alpha-0.9.0-h00000000_1.conda"), _bytes(String("old a")))
    ch.put(String("linux-64"), String("komira_beta-0.9.0-h00000000_1.conda"), _bytes(String("old b")))
    ch.put(String("linux-64"), String("komira-0.9.0-h00000000_1.conda"), _bytes(String("old m")))
    return ch^


def _req(tag: String, plan: Bool = True) raises -> PublishRequest:
    return write_example_inputs(ExampleRelease(), _root(tag), String("example-stable"), plan)


def _refused_before_anything(
    req: PublishRequest, error_id: String, needle: String, exit_code: Int = EXIT_REFUSED
) raises:
    var reg = RegistrySet[ScriptedChannel, PublishCredential](_channel(), PublishCredential())
    var store = NoSecretStore()
    var sl = NoWaitSleeper()
    var result = KciRunResult(String("run"), String("publish"))
    var rec = MemoryRecorder()
    var rep = publish_flow(req, result, rec, reg, ScriptedPkgTransport(), ActionsOidcEnv.absent(), store, RunOptions(), sl)
    var lines = String("\n").join(rep.lines)
    assert_equal(rep.outcome(), String("REFUSED"), lines)
    assert_equal(rep.exit_code(), exit_code, lines)
    assert_equal(rep.error_id, error_id, lines)
    assert_true(rep.has_line_containing(needle), String("no line says '") + needle + String("':\n") + lines)
    assert_equal(reg.transport().call_count(), 0)
    assert_equal(len(rec.records), 0)
    assert_equal(result.error.id, error_id)


def test_the_revision_must_be_release_jsons() raises:
    var req = _req(String("rev"))
    req.revision_id = String("0000000000000000000000000000000000000001")
    _refused_before_anything(
        req,
        String(ERROR_REVISION_MISMATCH),
        String("was built from revision a1b2c3d4e5f60718293a4b5c6d7e8f9012345678, not --revision-id")
        + String(" 0000000000000000000000000000000000000001"),
    )
    var short = _req(String("rev_short"))
    short.revision_id = String("a1b2c3d")
    _refused_before_anything(short, String(ERROR_REVISION), String("--revision-id 'a1b2c3d' is not a full commit id"))
    print("  test_the_revision_must_be_release_jsons: PASS")


def test_the_platform_must_be_one_kci_releases() raises:
    var req = _req(String("plat"))
    req.platform = String("darwin-arm64")
    _refused_before_anything(req, String(ERROR_PLATFORM), String("platform 'darwin-arm64' is not released"))
    var noarch = _req(String("plat_noarch"))
    noarch.platform = String("noarch")
    _refused_before_anything(noarch, String(ERROR_PLATFORM), String("platform 'noarch' is a member's platform"))
    print("  test_the_platform_must_be_one_kci_releases: PASS")


def test_the_release_is_read_under_its_platform() raises:
    var r = ExampleRelease()
    var root = _root(String("layout"))
    var req = write_example_inputs(r, root, String("example-stable"), True)
    # the same release, written at the top of --release-dir instead
    var flat = _root(String("layout_flat"))
    r.write(flat + String("/release"))
    req.release_dir = flat + String("/release")
    _refused_before_anything(
        req, String(ERROR_MEMBER), String("the release directory '") + flat + String("/release/linux-x86_64' is not a directory")
    )
    print("  test_the_release_is_read_under_its_platform: PASS")


def test_files_land_in_the_platforms_subdir() raises:
    var r = ExampleRelease()
    var req = write_example_inputs(r, _root(String("subdir")), String("example-stable"), False)
    var reg = RegistrySet[ScriptedChannel, PublishCredential](_channel(), PublishCredential())
    var store = NoSecretStore()
    var sl = NoWaitSleeper()
    var result = KciRunResult(String("run"), String("publish"))
    var rec = MemoryRecorder()
    # an API-token channel; the store refuses, so make it a dry run's reads only
    req.plan = True
    var rep = publish_flow(req, result, rec, reg, ScriptedPkgTransport(), ActionsOidcEnv.absent(), store, RunOptions(), sl)
    assert_equal(rep.exit_code(), EXIT_OK, String("\n").join(rep.lines))
    for i in range(len(rep.files)):
        assert_equal(rep.files[i].subdir, String("linux-64"))
        assert_true(rep.files[i].file.startswith(String("linux-64/")))
    for i in range(len(result.artifacts)):
        assert_equal(result.artifacts[i].platform, String("linux-x86_64"))
        assert_equal(result.artifacts[i].revision, r.revision)
    assert_equal(result.steps[0].platform, String("linux-x86_64"))
    assert_equal(result.steps[0].name, String("publish"))
    assert_equal(result.platform, String("linux-x86_64"))
    assert_equal(result.revision, r.revision)
    print("  test_files_land_in_the_platforms_subdir: PASS")


def test_the_requests_own_values() raises:
    var b = _req(String("u_conc"))
    b.concurrency = 0
    _refused_before_anything(b, String(ERROR_USAGE), String("--concurrency 0 is not in 1..16"), EXIT_USAGE)
    var d = _req(String("u_stage"))
    d.stage = String("")
    _refused_before_anything(d, String(ERROR_USAGE), String("the stage is EMPTY"), EXIT_USAGE)
    print("  test_the_requests_own_values: PASS")


def main() raises:
    test_the_revision_must_be_release_jsons()
    test_the_platform_must_be_one_kci_releases()
    test_the_release_is_read_under_its_platform()
    test_files_land_in_the_platforms_subdir()
    test_the_requests_own_values()
    print("test_publish_platform: ALL PASS")
