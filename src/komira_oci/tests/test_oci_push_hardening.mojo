# =============================================================================
# test_oci_push_hardening.mojo — LayoutPusher: digest-only pushes, the registry's
# own digest header on a blob, manifest media types, and 401/403 messages.
#
#   (1) a destination pinned by digest (no tag) uploads, reads back by digest,
#       and NEVER writes a tag;
#   (2) a pinned digest that is not the layout's root is refused before ANY
#       request is made (zero calls);
#   (3) a blob PUT answered with a `Docker-Content-Digest` naming other content
#       is refused; an ABSENT header is accepted;
#   (4) a manifest whose mediaType disagrees with its index.json descriptor, or
#       that states neither, is refused when the layout is read;
#   (5) a 401 names the scope a push needs and the registry's challenge, and
#       carries no credential byte.
# Everything runs over the in-process fake registry: no network, no sockets.
# =============================================================================

from std.os import getenv
from std.testing import assert_equal, assert_true

from komira_http_core.codec.types import HTTP_METHOD_PUT

from komira_oci.oci_auth import OciAuth
from komira_oci.oci_fake_registry import FakeOciRegistry
from komira_oci.oci_layout_fixture import write_test_layout
from komira_oci.oci_layout_reader import OciLayout, read_oci_layout
from komira_oci.oci_push import (
    LayoutPusher,
    PUSH_FAILED,
    PUSH_NOOP,
    PUSH_REFUSED,
    PUSH_UPLOADED,
    PushResult,
    push_outcome_name,
)

comptime _HOST: String = "us-central1-docker.pkg.dev"
comptime _REPO: String = "acme-prod/kci-images/orders_image"
comptime _TAG: String = "3f2a9c1d8b7e6f5a4c3b2a1908f7e6d5c4b3a291"
comptime _SECRET: String = "secret-token-value"


def _scratch(name: String) -> String:
    return getenv("TEST_TMPDIR", "/tmp") + String("/komira_oci_hard_") + name


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


def _pusher(var reg: FakeOciRegistry) -> LayoutPusher[FakeOciRegistry]:
    return LayoutPusher[FakeOciRegistry](
        reg^, OciAuth.basic(String("oauth2accesstoken"), String(_SECRET)), False, 0
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


# ---- (1) + (2) digest-only ----------------------------------------------------


def test_digest_only_push_uploads_and_writes_no_tag() raises:
    var layout = _layout(String("bydigest_ok"))
    var pusher = _pusher(FakeOciRegistry(_HOST))
    var r = pusher.push_by_digest(layout, _HOST, _REPO, layout.manifest_digest)
    _expect(r, PUSH_UPLOADED)
    assert_equal(r.digest, layout.manifest_digest)
    assert_equal(r.tag, String(""))
    assert_true(pusher.transport().has_manifest(_REPO, layout.manifest_digest), "manifest stored")
    assert_equal(pusher.transport().blob_count(_REPO), 3)
    # Exactly one manifest PUT, and it is by digest: no tag was written.
    assert_equal(pusher.transport().count_calls(HTTP_METHOD_PUT, String("/manifests/")), 1)
    assert_equal(
        pusher.transport().count_calls(HTTP_METHOD_PUT, String("/manifests/sha256:")), 1
    )
    # A second push finds the manifest and does nothing further.
    var again = pusher.push_by_digest(layout, _HOST, _REPO, layout.manifest_digest)
    _expect(again, PUSH_NOOP)
    print("  test_digest_only_push_uploads_and_writes_no_tag: PASS")


def test_pinned_digest_mismatch_is_refused_before_any_request() raises:
    var layout = _layout(String("bydigest_bad"))
    var pusher = _pusher(FakeOciRegistry(_HOST))
    var wrong = String("sha256:") + String("0") * 64
    var r = pusher.push_by_digest(layout, _HOST, _REPO, wrong)
    _expect(r, PUSH_REFUSED)
    assert_true(r.detail.find(wrong) >= 0, "names the pinned digest: " + r.detail)
    assert_true(r.detail.find(layout.manifest_digest) >= 0, "names the layout's: " + r.detail)
    assert_equal(pusher.transport().call_count(), 0)
    # A pin that is not even a digest is refused the same way.
    var junk = pusher.push_by_digest(layout, _HOST, _REPO, String("latest"))
    _expect(junk, PUSH_REFUSED)
    assert_equal(pusher.transport().call_count(), 0)
    print("  test_pinned_digest_mismatch_is_refused_before_any_request: PASS")


# ---- (3) Docker-Content-Digest on a blob PUT ---------------------------------


def test_blob_put_with_wrong_digest_header_is_refused() raises:
    var layout = _layout(String("blobhdr_wrong"))
    var reg = FakeOciRegistry(_HOST)
    var other = String("sha256:") + String("f") * 64
    reg.blob_put_digest_header = other.copy()
    var pusher = _pusher(reg^)
    var r = pusher.push(layout, _HOST, _REPO, _TAG)
    _expect(r, PUSH_FAILED)
    assert_true(r.detail.find(other) >= 0, "names the digest the registry claimed: " + r.detail)
    # The manifest and the tag were never written over a blob it mis-stored.
    assert_equal(pusher.transport().count_calls(HTTP_METHOD_PUT, String("/manifests/")), 0)
    print("  test_blob_put_with_wrong_digest_header_is_refused: PASS")


def test_blob_put_with_absent_digest_header_is_accepted() raises:
    var layout = _layout(String("blobhdr_absent"))
    var reg = FakeOciRegistry(_HOST)
    reg.blob_put_digest_header = String("omit")
    var pusher = _pusher(reg^)
    _expect(pusher.push(layout, _HOST, _REPO, _TAG), PUSH_UPLOADED)
    print("  test_blob_put_with_absent_digest_header_is_accepted: PASS")


# ---- (4) manifest media types --------------------------------------------------


def _read_refused(dir: String, needle: String) raises:
    var raised = False
    try:
        var _l = read_oci_layout(dir)
    except e:
        raised = True
        assert_true(String(e).find(needle) >= 0, "wrong refusal: " + String(e))
    assert_true(raised, "the layout must be refused: " + needle)


def test_manifest_media_type_disagreeing_with_descriptor_is_refused() raises:
    var dir = _scratch(String("mt_disagree"))
    _ = write_test_layout(
        dir,
        _two_layers(),
        descriptor_media_type=String("application/vnd.oci.image.manifest.v1+json"),
        manifest_media_type=String("application/vnd.docker.distribution.manifest.v2+json"),
    )
    _read_refused(dir, String("refusing to choose"))
    print("  test_manifest_media_type_disagreeing_with_descriptor_is_refused: PASS")


def test_manifest_stating_no_media_type_is_refused() raises:
    var dir = _scratch(String("mt_neither"))
    _ = write_test_layout(
        dir,
        _two_layers(),
        descriptor_media_type=String(""),
        manifest_media_type=String(""),
    )
    _read_refused(dir, String("states no mediaType"))
    print("  test_manifest_stating_no_media_type_is_refused: PASS")


def test_one_stated_media_type_is_enough() raises:
    # Descriptor only, and manifest only: each is a complete statement.
    var d1 = _scratch(String("mt_desc_only"))
    _ = write_test_layout(d1, _two_layers(), manifest_media_type=String(""))
    var l1 = read_oci_layout(d1)
    assert_equal(l1.manifest_media_type, String("application/vnd.oci.image.manifest.v1+json"))
    var d2 = _scratch(String("mt_doc_only"))
    _ = write_test_layout(d2, _two_layers(), descriptor_media_type=String(""))
    var l2 = read_oci_layout(d2)
    assert_equal(l2.manifest_media_type, String("application/vnd.oci.image.manifest.v1+json"))
    print("  test_one_stated_media_type_is_enough: PASS")


# ---- (5) 401 message -----------------------------------------------------------


def test_unauthorized_names_the_scope_and_the_challenge_without_secrets() raises:
    var layout = _layout(String("auth401"))
    var reg = FakeOciRegistry(_HOST)
    # Anything but what the pusher sends is a 401.
    reg.required_authorization = String("Bearer something-else")
    var challenge = String(
        'Bearer realm="https://auth.example.net/token",service="registry",'
        'scope="repository:acme-prod/kci-images/orders_image:pull,push"'
    )
    reg.www_authenticate = challenge.copy()
    var pusher = _pusher(reg^)
    var r = pusher.push(layout, _HOST, _REPO, _TAG)
    assert_true(not r.is_success(), "a 401 is not a success")
    assert_true(r.detail.find(String("HTTP 401")) >= 0, "names the status: " + r.detail)
    assert_true(
        r.detail.find(String("repository:") + _REPO + String(":pull,push")) >= 0,
        "names the push scope: " + r.detail,
    )
    assert_true(r.detail.find(challenge) >= 0, "carries the challenge: " + r.detail)
    assert_true(r.detail.find(_SECRET) < 0, "no credential in the message")
    assert_true(r.detail.find(String("oauth2accesstoken")) < 0, "no user in the message")
    print("  test_unauthorized_names_the_scope_and_the_challenge_without_secrets: PASS")


def main() raises:
    test_digest_only_push_uploads_and_writes_no_tag()
    test_pinned_digest_mismatch_is_refused_before_any_request()
    test_blob_put_with_wrong_digest_header_is_refused()
    test_blob_put_with_absent_digest_header_is_accepted()
    test_manifest_media_type_disagreeing_with_descriptor_is_refused()
    test_manifest_stating_no_media_type_is_refused()
    test_one_stated_media_type_is_enough()
    test_unauthorized_names_the_scope_and_the_challenge_without_secrets()
    print("test_oci_push_hardening: ALL PASS")
