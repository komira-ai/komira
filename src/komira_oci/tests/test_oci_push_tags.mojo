# =============================================================================
# test_oci_push_tags.mojo — LayoutPusher: the tag is classified by a READ, never a status code.
# =============================================================================
#
#   (1) a tag already on a DIFFERENT digest is refused before a byte is sent;
#   (2) the same refusal when the tag appears BETWEEN our read and our PUT (a
#       racing publisher) is reached through the failed PUT, and must be
#       REFUSED for each of the statuses 400, 403 and 409 — the code is not what
#       decides it;
#   (3) a racing publisher of the SAME bytes is a success, however the registry
#       words its refusal;
#   (4) a failed tag PUT whose follow-up read cannot be made is INDETERMINATE;
#   (5) a failed tag PUT with the tag absent: transient failures are retried a
#       bounded number of times then PARTIAL; a 403 is retried only when the
#       caller said the repository is new, also bounded;
#   (6) the tag grammar: a bad tag is refused before any call.
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


def _different_manifest(mut reg: FakeOciRegistry, layout: OciLayout) -> String:
    """A manifest that is not `layout`'s, stored in the registry; its digest."""
    return reg.seed_manifest(
        _REPO, layout.manifest_media_type, _bytes(String('{"schemaVersion": 2, "other": true}'))
    )


def test_tag_on_other_digest_is_refused_before_any_send() raises:
    var layout = _layout(String("tags_pre"))
    var reg = FakeOciRegistry(_HOST)
    var other = _different_manifest(reg, layout)
    reg.seed_tag(_REPO, _TAG, other)
    var pusher = _pusher(reg^)
    var r = pusher.push(layout, _HOST, _REPO, _TAG)
    _expect(r, PUSH_REFUSED)
    assert_true(r.detail.find(other) >= 0 and r.detail.find(layout.manifest_digest) >= 0, "names both digests: " + r.detail)
    ref seen = pusher.transport()
    assert_equal(seen.count_calls(HTTP_METHOD_PUT, String("")), 0)
    assert_equal(seen.count_calls(HTTP_METHOD_POST, String("")), 0)
    assert_equal(seen.tag_digest(_REPO, _TAG), other)
    print("  test_tag_on_other_digest_is_refused_before_any_send: PASS")


def _race_refusal(status: Int, name: String) raises:
    var layout = _layout(String("tags_race_") + String(status))
    var reg = FakeOciRegistry(_HOST)
    reg.tag_conflict_status = status
    var other = _different_manifest(reg, layout)
    reg.race_tag(_REPO, _TAG, other)
    var pusher = _pusher(reg^)
    var r = pusher.push(layout, _HOST, _REPO, _TAG)
    _expect(r, PUSH_REFUSED)
    assert_true(r.detail.find(other) >= 0, "names the other digest: " + r.detail)
    assert_equal(pusher.transport().tag_digest(_REPO, _TAG), other)
    print("  " + name + ": PASS")


def test_immutable_conflict_400_is_refused() raises:
    _race_refusal(400, String("test_immutable_conflict_400_is_refused"))


def test_immutable_conflict_403_is_refused() raises:
    _race_refusal(403, String("test_immutable_conflict_403_is_refused"))


def test_immutable_conflict_409_is_refused() raises:
    _race_refusal(409, String("test_immutable_conflict_409_is_refused"))


def test_immutable_conflict_403_with_retry_forbidden_is_still_refused() raises:
    # 403 is ALSO the not-yet-propagated class; the read, not the code, decides.
    var layout = _layout(String("tags_race_403_retry"))
    var reg = FakeOciRegistry(_HOST)
    reg.tag_conflict_status = 403
    var other = _different_manifest(reg, layout)
    reg.race_tag(_REPO, _TAG, other)
    var pusher = _pusher(reg^, True)
    _expect(pusher.push(layout, _HOST, _REPO, _TAG), PUSH_REFUSED)
    # Refused on the FIRST failed PUT: a conflict is not retried.
    assert_equal(pusher.transport().count_calls(HTTP_METHOD_PUT, _TAG), 1)
    print("  test_immutable_conflict_403_with_retry_forbidden_is_still_refused: PASS")


def _race_same_digest(status: Int, name: String) raises:
    var layout = _layout(String("tags_same_") + String(status))
    var reg = FakeOciRegistry(_HOST)
    reg.tag_conflict_status = status
    reg.reject_same_digest_tag_put = True
    # The racing publisher pushed THESE bytes; its manifest is already stored.
    _seed_all_blobs(reg, _REPO, layout)
    _ = reg.seed_manifest(_REPO, layout.manifest_media_type, layout.manifest_raw)
    reg.race_tag(_REPO, _TAG, layout.manifest_digest)
    var pusher = _pusher(reg^)
    var r = pusher.push(layout, _HOST, _REPO, _TAG)
    assert_true(r.is_success(), "racing identical bytes is a success: " + push_outcome_name(r.outcome) + r.detail)
    assert_equal(pusher.transport().tag_digest(_REPO, _TAG), layout.manifest_digest)
    print("  " + name + ": PASS")


def test_racing_publisher_same_digest_400() raises:
    _race_same_digest(400, String("test_racing_publisher_same_digest_400"))


def test_racing_publisher_same_digest_403() raises:
    _race_same_digest(403, String("test_racing_publisher_same_digest_403"))


def test_racing_publisher_same_digest_409() raises:
    _race_same_digest(409, String("test_racing_publisher_same_digest_409"))


def test_failed_tag_put_with_unreadable_tag_is_indeterminate() raises:
    var layout = _layout(String("tags_unreadable"))
    var reg = FakeOciRegistry(_HOST)
    # The tag PUT fails; then every read of the tag (after the pre-read) is 503.
    reg.add_fault(HTTP_METHOD_PUT, _TAG, 500, 1)
    reg.add_fault(HTTP_METHOD_HEAD, String("/manifests/") + _TAG, 503, 100, 1)
    var pusher = _pusher(reg^)
    var r = pusher.push(layout, _HOST, _REPO, _TAG)
    _expect(r, PUSH_INDETERMINATE)
    assert_true(not r.is_success(), "INDETERMINATE is never a pass")
    print("  test_failed_tag_put_with_unreadable_tag_is_indeterminate: PASS")


def test_transient_tag_failure_is_retried_then_succeeds() raises:
    var layout = _layout(String("tags_transient"))
    var reg = FakeOciRegistry(_HOST)
    reg.add_fault(HTTP_METHOD_PUT, _TAG, 503, 2)
    var pusher = _pusher(reg^)
    _expect(pusher.push(layout, _HOST, _REPO, _TAG), PUSH_UPLOADED)
    assert_equal(pusher.transport().count_calls(HTTP_METHOD_PUT, _TAG), 3)
    print("  test_transient_tag_failure_is_retried_then_succeeds: PASS")


def test_persistent_tag_failure_is_partial_after_the_bound() raises:
    var layout = _layout(String("tags_partial"))
    var reg = FakeOciRegistry(_HOST)
    reg.add_fault(HTTP_METHOD_PUT, _TAG, 503, 100)
    var pusher = _pusher(reg^)
    var r = pusher.push(layout, _HOST, _REPO, _TAG)
    _expect(r, PUSH_PARTIAL)
    assert_equal(pusher.transport().count_calls(HTTP_METHOD_PUT, _TAG), MAX_SEND_ATTEMPTS)
    # The image IS usable by digest.
    assert_true(
        pusher.transport().has_manifest(_REPO, layout.manifest_digest), "pushed by digest"
    )
    assert_equal(pusher.transport().tag_digest(_REPO, _TAG), String(""))
    print("  test_persistent_tag_failure_is_partial_after_the_bound: PASS")


def test_forbidden_tag_put_is_not_retried_without_the_flag() raises:
    var layout = _layout(String("tags_403_noflag"))
    var reg = FakeOciRegistry(_HOST)
    reg.add_fault(HTTP_METHOD_PUT, _TAG, 403, 100)
    var pusher = _pusher(reg^, False)
    _expect(pusher.push(layout, _HOST, _REPO, _TAG), PUSH_PARTIAL)
    assert_equal(pusher.transport().count_calls(HTTP_METHOD_PUT, _TAG), 1)
    print("  test_forbidden_tag_put_is_not_retried_without_the_flag: PASS")


def test_forbidden_tag_put_is_retried_with_the_flag_and_bounded() raises:
    var layout = _layout(String("tags_403_flag"))
    var reg = FakeOciRegistry(_HOST)
    reg.add_fault(HTTP_METHOD_PUT, _TAG, 403, 100)
    var pusher = _pusher(reg^, True)
    _expect(pusher.push(layout, _HOST, _REPO, _TAG), PUSH_PARTIAL)
    assert_equal(
        pusher.transport().count_calls(HTTP_METHOD_PUT, _TAG), 1 + MAX_FORBIDDEN_RETRIES
    )
    print("  test_forbidden_tag_put_is_retried_with_the_flag_and_bounded: PASS")


def test_forbidden_then_propagated_succeeds() raises:
    var layout = _layout(String("tags_403_then_ok"))
    var reg = FakeOciRegistry(_HOST)
    reg.add_fault(HTTP_METHOD_PUT, _TAG, 403, 2)
    var pusher = _pusher(reg^, True)
    _expect(pusher.push(layout, _HOST, _REPO, _TAG), PUSH_UPLOADED)
    print("  test_forbidden_then_propagated_succeeds: PASS")


def _refused_tag(tag: String) raises:
    var layout = _layout(String("tags_grammar"))
    var pusher = _pusher(FakeOciRegistry(_HOST))
    var r = pusher.push(layout, _HOST, _REPO, tag)
    assert_true(
        r.outcome == PUSH_REFUSED,
        "tag '" + tag + "' must be refused, got " + push_outcome_name(r.outcome),
    )
    assert_equal(pusher.transport().call_count(), 0)


def test_tag_grammar() raises:
    _refused_tag(String(""))
    _refused_tag(String("sha256:abcdef"))
    _refused_tag(String("a/b"))
    _refused_tag(String(".leading-dot"))
    _refused_tag(String("-leading-dash"))
    _refused_tag(String("has space"))
    var long = String("")
    for _ in range(129):
        long += String("a")
    _refused_tag(long)
    # Valid ones are not refused by the grammar.
    var layout = _layout(String("tags_grammar_ok"))
    var pusher = _pusher(FakeOciRegistry(_HOST))
    _expect(pusher.push(layout, _HOST, _REPO, String("v1.2.3-rc_1")), PUSH_UPLOADED)
    var pusher2 = _pusher(FakeOciRegistry(_HOST))
    _expect(pusher2.push(layout, _HOST, _REPO, String("_underscore-first")), PUSH_UPLOADED)
    print("  test_tag_grammar: PASS")


def main() raises:
    test_tag_on_other_digest_is_refused_before_any_send()
    test_immutable_conflict_400_is_refused()
    test_immutable_conflict_403_is_refused()
    test_immutable_conflict_409_is_refused()
    test_immutable_conflict_403_with_retry_forbidden_is_still_refused()
    test_racing_publisher_same_digest_400()
    test_racing_publisher_same_digest_403()
    test_racing_publisher_same_digest_409()
    test_failed_tag_put_with_unreadable_tag_is_indeterminate()
    test_transient_tag_failure_is_retried_then_succeeds()
    test_persistent_tag_failure_is_partial_after_the_bound()
    test_forbidden_tag_put_is_not_retried_without_the_flag()
    test_forbidden_tag_put_is_retried_with_the_flag_and_bounded()
    test_forbidden_then_propagated_succeeds()
    test_tag_grammar()
    print("test_oci_push_tags: ALL PASS")
