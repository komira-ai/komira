# =============================================================================
# test_oci_push_basic.mojo — LayoutPusher over an in-process registry: the ordinary pushes.
# =============================================================================
#
#   (1) a fresh push uploads every blob, then the manifest by digest, then the
#       tag, and reads it back — asserted on the registry's state AND on the
#       ORDER of the conversation (a manifest sent before its blobs is refused
#       by a real registry);
#   (2) re-publishing the same image is a NOOP that sends nothing;
#   (3) manifest present but tag missing adds the tag (TAG_ADDED), no blob sent;
#   (4) a blob that exists in ANOTHER repository is not visible here, so it is
#       uploaded (no mount is attempted); a blob already in THIS repository is
#       skipped;
#   (5) the credential is attached to every request and never appears in the
#       result.
# =============================================================================

from std.os import getenv
from std.testing import assert_equal, assert_true

from komira_http_core.codec.types import (
    HTTP_METHOD_GET,
    HTTP_METHOD_HEAD,
    HTTP_METHOD_POST,
    HTTP_METHOD_PUT,
)

from komira_oci.oci_auth import OciAuth
from komira_oci.oci_fake_registry import (
    FakeOciRegistry,
    LOCATION_ABSOLUTE_OTHER_HOST,
    LOCATION_ABSOLUTE_SAME_HOST,
    LOCATION_EMPTY,
    LOCATION_PLAINTEXT,
    LOCATION_RELATIVE_WITH_QUERY,
)
from komira_oci.oci_layout_fixture import (
    layout_blob_path,
    overwrite_layout_blob,
    write_test_layout,
)
from komira_oci.oci_layout_reader import OciLayout, read_oci_layout
from komira_oci.oci_push import (
    LayoutPusher,
    MAX_FORBIDDEN_RETRIES,
    MAX_SEND_ATTEMPTS,
    MAX_UPLOAD_SESSION_ATTEMPTS,
    PUSH_FAILED,
    PUSH_INDETERMINATE,
    PUSH_NOOP,
    PUSH_PARTIAL,
    PUSH_REFUSED,
    PUSH_TAG_ADDED,
    PUSH_UPLOADED,
    PushResult,
    push_outcome_name,
)

comptime _HOST: String = "us-central1-docker.pkg.dev"
comptime _REPO: String = "acme-prod/kci-images/orders_image"
comptime _OTHER_REPO: String = "acme-prod/kci-images/other_image"
# A revision id: a full commit hash is a valid tag.
comptime _TAG: String = "3f2a9c1d8b7e6f5a4c3b2a1908f7e6d5c4b3a291"


def _scratch(name: String) -> String:
    return getenv("TEST_TMPDIR", "/tmp") + String("/komira_oci_") + name


def _bytes(s: String) -> List[UInt8]:
    var out = List[UInt8]()
    var src = s.as_bytes()
    for i in range(len(src)):
        out.append(src[i])
    return out^


def _two_layers() -> List[List[UInt8]]:
    var layers = List[List[UInt8]]()
    layers.append(_bytes(String("layer-one-bytes-aaaaaaaaaaaaaaaa")))
    layers.append(_bytes(String("layer-two-bytes-bbbbbbbbbbbbbbbbbbbbbb")))
    return layers^


def _layout(name: String) raises -> OciLayout:
    var dir = _scratch(name)
    _ = write_test_layout(dir, _two_layers())
    return read_oci_layout(dir)


def _pusher(
    var reg: FakeOciRegistry, retry_forbidden: Bool = False
) -> LayoutPusher[FakeOciRegistry]:
    return LayoutPusher[FakeOciRegistry](
        reg^,
        OciAuth.basic(String("oauth2accesstoken"), String("secret-token-value")),
        retry_forbidden,
        0,
    )


def _expect(r: PushResult, outcome: Int) raises:
    assert_true(
        r.outcome == outcome,
        String("expected ")
        + push_outcome_name(outcome)
        + String(" but got ")
        + push_outcome_name(r.outcome)
        + String(": ")
        + r.detail,
    )


def _seed_all_blobs(mut reg: FakeOciRegistry, repo: String, layout: OciLayout) raises:
    var blobs = layout.push_blobs()
    for i in range(len(blobs)):
        _ = reg.seed_blob(repo, layout.read_blob(blobs[i]))


def test_fresh_push() raises:
    var layout = _layout(String("push_fresh"))
    var pusher = _pusher(FakeOciRegistry(_HOST))
    var r = pusher.push(layout, _HOST, _REPO, _TAG)
    _expect(r, PUSH_UPLOADED)
    assert_equal(r.registry, _HOST)
    assert_equal(r.repository, _REPO)
    assert_equal(r.digest, layout.manifest_digest)
    assert_equal(r.platform, String("linux/amd64"))
    assert_equal(r.tag, _TAG)
    assert_equal(r.blobs_uploaded, 3)  # two layers + the config
    assert_equal(r.blobs_skipped, 0)
    assert_equal(r.bytes_uploaded, layout.layers[0].size + layout.layers[1].size + layout.config.size)
    assert_equal(
        r.reference(), _HOST + String("/") + _REPO + String("@") + layout.manifest_digest
    )
    ref reg = pusher.transport()
    assert_equal(reg.blob_count(_REPO), 3)
    assert_true(reg.has_manifest(_REPO, layout.manifest_digest), "manifest stored")
    assert_equal(reg.tag_digest(_REPO, _TAG), layout.manifest_digest)

    # ORDER: every blob PUT precedes the manifest PUT-by-digest, which precedes
    # the tag PUT.
    var last_blob_put = -1
    var digest_put = -1
    var tag_put = -1
    for i in range(reg.call_count()):
        if reg.call_method(i) != HTTP_METHOD_PUT:
            continue
        var p = reg.call_path(i)
        if p.find(String("/blobs/uploads/")) >= 0:
            last_blob_put = i
        elif p.endswith(layout.manifest_digest):
            digest_put = i
        elif p.endswith(_TAG):
            tag_put = i
    assert_true(last_blob_put >= 0 and digest_put > last_blob_put, "blobs before the manifest")
    assert_true(tag_put > digest_put, "the tag after the manifest")
    # ...and nothing was ever sent to another host.
    assert_equal(reg.calls_to_other_hosts(), 0)
    print("  test_fresh_push: PASS")


def test_credential_on_every_request_and_not_in_result() raises:
    var layout = _layout(String("push_auth"))
    var pusher = _pusher(FakeOciRegistry(_HOST))
    var r = pusher.push(layout, _HOST, _REPO, _TAG)
    _expect(r, PUSH_UPLOADED)
    ref reg = pusher.transport()
    for i in range(reg.call_count()):
        # base64("oauth2accesstoken:secret-token-value")
        assert_true(
            reg.call_auth(i).startswith(String("Basic ")),
            "request " + String(i) + " carries the Basic credential",
        )
    var blob = r.detail + r.registry + r.repository + r.reference() + r.tag
    assert_true(blob.find(String("secret-token-value")) < 0, "no secret in the result")
    print("  test_credential_on_every_request_and_not_in_result: PASS")


def test_republish_is_noop() raises:
    var layout = _layout(String("push_noop"))
    var pusher = _pusher(FakeOciRegistry(_HOST))
    _expect(pusher.push(layout, _HOST, _REPO, _TAG), PUSH_UPLOADED)
    var puts_before = pusher.transport().count_calls(HTTP_METHOD_PUT, String(""))
    var posts_before = pusher.transport().count_calls(HTTP_METHOD_POST, String(""))
    var again = pusher.push(layout, _HOST, _REPO, _TAG)
    _expect(again, PUSH_NOOP)
    assert_true(again.is_success(), "NOOP is a success")
    assert_equal(again.blobs_uploaded, 0)
    assert_equal(again.bytes_uploaded, 0)
    assert_equal(again.digest, layout.manifest_digest)
    assert_equal(pusher.transport().count_calls(HTTP_METHOD_PUT, String("")), puts_before)
    assert_equal(pusher.transport().count_calls(HTTP_METHOD_POST, String("")), posts_before)
    print("  test_republish_is_noop: PASS")


def test_manifest_present_tag_missing_adds_the_tag() raises:
    var layout = _layout(String("push_tag_added"))
    var reg = FakeOciRegistry(_HOST)
    _seed_all_blobs(reg, _REPO, layout)
    _ = reg.seed_manifest(_REPO, layout.manifest_media_type, layout.manifest_raw)
    var pusher = _pusher(reg^)
    var r = pusher.push(layout, _HOST, _REPO, _TAG)
    _expect(r, PUSH_TAG_ADDED)
    assert_true(r.is_success(), "TAG_ADDED is a success")
    assert_equal(r.blobs_uploaded, 0)
    ref seen = pusher.transport()
    assert_equal(seen.tag_digest(_REPO, _TAG), layout.manifest_digest)
    assert_equal(seen.count_calls(HTTP_METHOD_POST, String("/blobs/uploads/")), 0)
    assert_equal(seen.count_calls(HTTP_METHOD_PUT, String("/blobs/uploads/")), 0)
    print("  test_manifest_present_tag_missing_adds_the_tag: PASS")


def test_blob_in_another_repository_is_uploaded_here() raises:
    var layout = _layout(String("push_elsewhere"))
    var reg = FakeOciRegistry(_HOST)
    # Every blob exists in ANOTHER repository of the same registry.
    _seed_all_blobs(reg, _OTHER_REPO, layout)
    var pusher = _pusher(reg^)
    var r = pusher.push(layout, _HOST, _REPO, _TAG)
    _expect(r, PUSH_UPLOADED)
    assert_equal(r.blobs_uploaded, 3)
    assert_equal(r.blobs_skipped, 0)
    ref seen = pusher.transport()
    # No cross-repository mount was attempted: the pusher has no source repo.
    assert_equal(seen.count_calls(HTTP_METHOD_POST, String("mount=")), 0)
    print("  test_blob_in_another_repository_is_uploaded_here: PASS")


def test_blob_already_in_this_repository_is_skipped() raises:
    var layout = _layout(String("push_skip"))
    var reg = FakeOciRegistry(_HOST)
    _ = reg.seed_blob(_REPO, layout.read_blob(layout.layers[0]))
    var pusher = _pusher(reg^)
    var r = pusher.push(layout, _HOST, _REPO, _TAG)
    _expect(r, PUSH_UPLOADED)
    assert_equal(r.blobs_skipped, 1)
    assert_equal(r.blobs_uploaded, 2)
    assert_equal(
        r.bytes_uploaded, layout.layers[1].size + layout.config.size
    )
    print("  test_blob_already_in_this_repository_is_skipped: PASS")


def test_head_without_digest_header_falls_back_to_get() raises:
    var layout = _layout(String("push_nohdr"))
    var reg = FakeOciRegistry(_HOST)
    reg.omit_digest_header_on_head = True
    var pusher = _pusher(reg^)
    _expect(pusher.push(layout, _HOST, _REPO, _TAG), PUSH_UPLOADED)
    # The tag's digest was then COMPUTED from the GET body, never assumed.
    assert_true(
        pusher.transport().count_calls(HTTP_METHOD_GET, String("/manifests/")) > 0,
        "the digest was read from the manifest bytes",
    )
    print("  test_head_without_digest_header_falls_back_to_get: PASS")


def main() raises:
    test_fresh_push()
    test_credential_on_every_request_and_not_in_result()
    test_republish_is_noop()
    test_manifest_present_tag_missing_adds_the_tag()
    test_blob_in_another_repository_is_uploaded_here()
    test_blob_already_in_this_repository_is_skipped()
    test_head_without_digest_header_falls_back_to_get()
    print("test_oci_push_basic: ALL PASS")
