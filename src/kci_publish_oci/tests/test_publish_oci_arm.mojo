# =============================================================================
# src/kci_publish_oci/tests/test_publish_oci_arm.mojo
#   The OCI image arm over komira_oci's in-process fake registry: every row of
#   the PUSH_* -> outcome mapping, --plan and the platform and revision checks
#   with zero requests, an identical re-push as NOOP exit 0, and no
#   credential in any error. Every image row's artifact type is the literal
#   "OCI" (kci_release_channel's ARTIFACT_TYPE_OCI, the one word for an
#   image), never compared with the arm's own constant.
# =============================================================================

from std.os import getenv
from std.testing import TestSuite, assert_equal, assert_false, assert_true

from komira_http_core.codec.types import HTTP_METHOD_HEAD, HTTP_METHOD_PUT

from komira_oci.oci_auth import OciAuth
from komira_oci.oci_fake_registry import FakeOciRegistry
from komira_oci.oci_layout_fixture import write_test_layout
from komira_oci.oci_layout_reader import read_oci_layout
from komira_oci.oci_push import LayoutPusher

from kci_api import (
    ARTIFACT_ALREADY_PRESENT,
    ARTIFACT_NOT_REACHED,
    ARTIFACT_UPLOADED,
    ARTIFACT_WOULD_UPLOAD,
    ERROR_IMAGE_PLATFORM,
    ERROR_IMAGE_PUSH,
    ERROR_PLATFORM,
    ERROR_REVISION,
    OUTCOME_FAILED,
    OUTCOME_INDETERMINATE,
    OUTCOME_NOOP,
    OUTCOME_PARTIAL,
    OUTCOME_REFUSED,
    OUTCOME_SUCCEEDED,
    RunResult,
    VERB_RUN,
)
from kci_publish_oci import ImagePublish, publish_layout, record_image_publish

comptime _HOST: String = "registry.example.test"
comptime _REPO: String = "example/kci-images/encoding_image"
comptime _REV: String = "3f2a9c1d8b7e6f5a4c3b2a1908f7e6d5c4b3a291"
comptime _PLATFORM: String = "linux-x86_64"
comptime _SECRET: String = "secret-token-value-do-not-print"


def _bytes(s: String) -> List[UInt8]:
    var out = List[UInt8]()
    var src = s.as_bytes()
    for i in range(len(src)):
        out.append(src[i])
    return out^


def _layout_dir(name: String, arch: String = String("amd64")) raises -> String:
    var dir = getenv("TEST_TMPDIR", "/tmp") + String("/kci_publish_oci_") + name
    var layers = List[List[UInt8]]()
    layers.append(_bytes(String("layer-one-bytes-") + name))
    layers.append(_bytes(String("layer-two-bytes-") + name + String("-more")))
    _ = write_test_layout(dir, layers, String("linux"), arch)
    return dir^


def _pusher(var reg: FakeOciRegistry) -> LayoutPusher[FakeOciRegistry]:
    return LayoutPusher[FakeOciRegistry](reg^, OciAuth.basic(String("publisher"), String(_SECRET)), False, 0)


def _push(mut pusher: LayoutPusher[FakeOciRegistry], dir: String, plan: Bool = False) -> ImagePublish:
    return publish_layout(pusher, dir, String(_HOST), String(_REPO), String(_REV), String(_PLATFORM), plan)


def _expect(p: ImagePublish, outcome: String, code: Int, error_id: String) raises:
    assert_equal(p.outcome, outcome, p.message)
    assert_equal(p.exit_code(), code, p.message)
    assert_equal(p.error_id, error_id, p.message)
    assert_equal(p.message.find(String(_SECRET)), -1, p.message)
    # The one word for an image, whatever the outcome: the literal, so the
    # arm's constant set to another word goes red here.
    assert_equal(p.artifact.artifact_type, "OCI", p.message)
    # Every message names the step (`kci run --stage S` is the one verb for
    # stages), never a removed verb.
    assert_true(p.message.startswith(String("PUBLISH step (image): ")), p.message)


def test_uploaded_then_identical_repush_is_noop_exit_0() raises:
    var dir = _layout_dir(String("noop"))
    var pusher = _pusher(FakeOciRegistry(_HOST))
    var first = _push(pusher, dir)
    _expect(first, String(OUTCOME_SUCCEEDED), 0, String(""))
    assert_equal(first.artifact.effect, String(ARTIFACT_UPLOADED))
    assert_equal(first.artifact.artifact_type, "OCI")
    assert_equal(first.artifact.revision, String(_REV))
    assert_equal(first.artifact.platform, String(_PLATFORM))
    var digest = read_oci_layout(dir).manifest_digest
    assert_equal(pusher.transport().tag_digest(_REPO, _REV), digest)
    assert_equal(first.artifact.file, String(_HOST) + String("/") + String(_REPO) + String("@") + digest)
    # the same bytes again: the tag already names them, which is success
    var again = _push(pusher, dir)
    _expect(again, String(OUTCOME_NOOP), 0, String(""))
    assert_equal(again.artifact.effect, String(ARTIFACT_ALREADY_PRESENT))
    assert_true(again.ok())


def test_tag_on_another_digest_is_refused_exit_3() raises:
    var dir = _layout_dir(String("other"))
    var reg = FakeOciRegistry(_HOST)
    var other = reg.seed_manifest(
        _REPO, String("application/vnd.oci.image.manifest.v1+json"), _bytes(String('{"schemaVersion": 2, "other": true}'))
    )
    reg.seed_tag(_REPO, _REV, other)
    var pusher = _pusher(reg^)
    var p = _push(pusher, dir)
    _expect(p, String(OUTCOME_REFUSED), 3, String(ERROR_IMAGE_PUSH))
    assert_true(p.message.find(other) >= 0, p.message)
    assert_equal(p.artifact.effect, String(ARTIFACT_NOT_REACHED))
    assert_equal(pusher.transport().count_calls(HTTP_METHOD_PUT, String("")), 0)
    assert_equal(pusher.transport().tag_digest(_REPO, _REV), other)


def test_platform_mismatch_is_refused_with_zero_requests() raises:
    var dir = _layout_dir(String("arm64"), String("arm64"))
    var pusher = _pusher(FakeOciRegistry(_HOST))
    var p = _push(pusher, dir)
    _expect(p, String(OUTCOME_REFUSED), 3, String(ERROR_IMAGE_PLATFORM))
    assert_true(p.message.find(String("is for linux/arm64; this step publishes linux-x86_64 (linux/amd64)")) >= 0, p.message)
    assert_equal(pusher.transport().call_count(), 0)


def test_plan_reads_the_layout_and_sends_nothing() raises:
    var dir = _layout_dir(String("plan"))
    var pusher = _pusher(FakeOciRegistry(_HOST))
    var p = _push(pusher, dir, True)
    _expect(p, String(OUTCOME_SUCCEEDED), 0, String(""))
    assert_equal(p.artifact.effect, String(ARTIFACT_WOULD_UPLOAD))
    assert_equal(p.artifact.sha256.byte_length(), 64)
    assert_equal(pusher.transport().call_count(), 0)
    assert_equal(pusher.transport().tag_digest(_REPO, _REV), String(""))


def test_revision_and_platform_refused_before_any_request() raises:
    var dir = _layout_dir(String("rev"))
    var pusher = _pusher(FakeOciRegistry(_HOST))
    var short = publish_layout(pusher, dir, String(_HOST), String(_REPO), String("3f2a9c1"), String(_PLATFORM), False)
    _expect(short, String(OUTCOME_REFUSED), 3, String(ERROR_REVISION))
    assert_true(short.message.find(String("the image's tag is the revision")) >= 0, short.message)
    var reserved = publish_layout(pusher, dir, String(_HOST), String(_REPO), String(_REV), String("darwin-arm64"), False)
    _expect(reserved, String(OUTCOME_REFUSED), 3, String(ERROR_PLATFORM))
    var noarch = publish_layout(pusher, dir, String(_HOST), String(_REPO), String(_REV), String("noarch"), False)
    _expect(noarch, String(OUTCOME_REFUSED), 3, String(ERROR_PLATFORM))
    var missing = _push(pusher, dir + String("/not-there"))
    _expect(missing, String(OUTCOME_REFUSED), 3, String(ERROR_IMAGE_PUSH))
    assert_equal(pusher.transport().call_count(), 0)


def test_credential_refused_is_failed_exit_4_without_the_secret() raises:
    var dir = _layout_dir(String("auth"))
    var reg = FakeOciRegistry(_HOST)
    reg.required_authorization = String("Basic c29tZW9uZS1lbHNl")
    var pusher = _pusher(reg^)
    var p = _push(pusher, dir)
    _expect(p, String(OUTCOME_FAILED), 4, String(ERROR_IMAGE_PUSH))
    assert_equal(p.artifact.effect, String(ARTIFACT_NOT_REACHED))


def test_unreadable_tag_after_failed_put_is_indeterminate_exit_5() raises:
    var dir = _layout_dir(String("indet"))
    var reg = FakeOciRegistry(_HOST)
    reg.add_fault(HTTP_METHOD_PUT, _REV, 500, 1)
    reg.add_fault(HTTP_METHOD_HEAD, String("/manifests/") + String(_REV), 503, 100, 1)
    var pusher = _pusher(reg^)
    var p = _push(pusher, dir)
    _expect(p, String(OUTCOME_INDETERMINATE), 5, String(ERROR_IMAGE_PUSH))
    assert_false(p.ok())


def test_tag_never_added_is_partial_exit_6_retry_unsafe() raises:
    var dir = _layout_dir(String("partial"))
    var reg = FakeOciRegistry(_HOST)
    reg.add_fault(HTTP_METHOD_PUT, _REV, 503, 100)
    var pusher = _pusher(reg^)
    var p = _push(pusher, dir)
    _expect(p, String(OUTCOME_PARTIAL), 6, String(ERROR_IMAGE_PUSH))
    # usable by digest: the image's bytes landed
    assert_equal(p.artifact.effect, String(ARTIFACT_UPLOADED))
    var r = RunResult(String(VERB_RUN), String(VERB_RUN))
    record_image_publish(p, String("image"), String(_PLATFORM), r)
    var done = r.finish_record(p.outcome.copy(), 1)
    assert_equal(done.exit_code, 6)
    assert_equal(done.retry, String("UNSAFE"))
    assert_equal(done.error.id, String(ERROR_IMAGE_PUSH))
    assert_equal(done.steps[0].name, String("image"))
    assert_equal(len(done.artifacts), 1)
    assert_equal(done.artifacts[0].artifact_type, "OCI")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
