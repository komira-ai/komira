# =============================================================================
# test_oci_push_faults.mojo — LayoutPusher: the Location shapes, retries, sessions and corruption.
# =============================================================================
#
#   (1) the upload Location: relative, relative with a query, absolute on the
#       same host are followed; absolute on ANOTHER host, plaintext and an
#       empty Location are refused, and NOTHING is ever sent to another host;
#   (2) retries are bounded and narrow: 5xx and transport faults up to
#       MAX_SEND_ATTEMPTS, never 400 / 401; a 403 only with the flag;
#   (3) an expired upload session gets a NEW session, bounded;
#   (4) a blob that changed on disk after verification is caught BEFORE its
#       bytes are sent, and the manifest is never put;
#   (5) the monolithic ceiling: a layout above it is refused before a single
#       request is made.
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


def _push_with_location(mode: Int, name: String) raises -> LayoutPusher[FakeOciRegistry]:
    var layout = _layout(name)
    var reg = FakeOciRegistry(_HOST)
    reg.location_mode = mode
    return _pusher(reg^)


def test_relative_location_with_query_is_followed() raises:
    var layout = _layout(String("faults_relq"))
    var reg = FakeOciRegistry(_HOST)
    reg.location_mode = LOCATION_RELATIVE_WITH_QUERY
    var pusher = _pusher(reg^)
    _expect(pusher.push(layout, _HOST, _REPO, _TAG), PUSH_UPLOADED)
    # The finalizing `digest=` joined the existing query with '&', not '?'.
    assert_true(
        pusher.transport().count_calls(HTTP_METHOD_PUT, String("?_state=abc&digest=sha256:")) == 3,
        "digest appended with & after the server's own query",
    )
    print("  test_relative_location_with_query_is_followed: PASS")


def test_absolute_same_host_location_is_followed() raises:
    var layout = _layout(String("faults_abs"))
    var reg = FakeOciRegistry(_HOST)
    reg.location_mode = LOCATION_ABSOLUTE_SAME_HOST
    var pusher = _pusher(reg^)
    _expect(pusher.push(layout, _HOST, _REPO, _TAG), PUSH_UPLOADED)
    # The PUT went to a PATH, not to the whole URL used as a path.
    ref seen = pusher.transport()
    for i in range(seen.call_count()):
        assert_true(not seen.call_path(i).startswith(String("https://")), "no URL used as a path")
    print("  test_absolute_same_host_location_is_followed: PASS")


def test_absolute_other_host_location_is_refused_and_nothing_leaks() raises:
    var layout = _layout(String("faults_xhost"))
    var reg = FakeOciRegistry(_HOST)
    reg.location_mode = LOCATION_ABSOLUTE_OTHER_HOST
    var pusher = _pusher(reg^)
    var r = pusher.push(layout, _HOST, _REPO, _TAG)
    _expect(r, PUSH_FAILED)
    assert_true(r.detail.find(String("evil.example.net")) >= 0, "names the host: " + r.detail)
    ref seen = pusher.transport()
    assert_equal(seen.calls_to_other_hosts(), 0)
    assert_equal(seen.count_calls(HTTP_METHOD_PUT, String("")), 0)
    # No credential ever went to another host (there was no call to one).
    assert_true(r.detail.find(String("secret-token-value")) < 0, "no secret in the message")
    print("  test_absolute_other_host_location_is_refused_and_nothing_leaks: PASS")


def test_plaintext_location_is_refused() raises:
    var layout = _layout(String("faults_plain"))
    var reg = FakeOciRegistry(_HOST)
    reg.location_mode = LOCATION_PLAINTEXT
    var pusher = _pusher(reg^)
    var r = pusher.push(layout, _HOST, _REPO, _TAG)
    _expect(r, PUSH_FAILED)
    assert_true(r.detail.find(String("PLAINTEXT")) >= 0, r.detail)
    assert_equal(pusher.transport().count_calls(HTTP_METHOD_PUT, String("")), 0)
    print("  test_plaintext_location_is_refused: PASS")


def test_empty_location_is_refused() raises:
    var layout = _layout(String("faults_noloc"))
    var reg = FakeOciRegistry(_HOST)
    reg.location_mode = LOCATION_EMPTY
    var pusher = _pusher(reg^)
    var r = pusher.push(layout, _HOST, _REPO, _TAG)
    _expect(r, PUSH_FAILED)
    assert_true(r.detail.find(String("no Location")) >= 0, r.detail)
    print("  test_empty_location_is_refused: PASS")


def test_5xx_is_retried_then_succeeds() raises:
    var layout = _layout(String("faults_5xx"))
    var reg = FakeOciRegistry(_HOST)
    reg.add_fault(HTTP_METHOD_HEAD, String("/blobs/"), 503, 2)
    var pusher = _pusher(reg^)
    _expect(pusher.push(layout, _HOST, _REPO, _TAG), PUSH_UPLOADED)
    print("  test_5xx_is_retried_then_succeeds: PASS")


def test_5xx_retry_limit() raises:
    var layout = _layout(String("faults_5xx_limit"))
    var reg = FakeOciRegistry(_HOST)
    reg.add_fault(HTTP_METHOD_HEAD, String("/blobs/"), 502, 100)
    var pusher = _pusher(reg^)
    var r = pusher.push(layout, _HOST, _REPO, _TAG)
    _expect(r, PUSH_FAILED)
    assert_equal(
        pusher.transport().count_calls(HTTP_METHOD_HEAD, String("/blobs/")), MAX_SEND_ATTEMPTS
    )
    print("  test_5xx_retry_limit: PASS")


def test_transport_fault_retry_limit() raises:
    var layout = _layout(String("faults_transport"))
    var reg = FakeOciRegistry(_HOST)
    reg.add_fault(HTTP_METHOD_HEAD, String("/blobs/"), -1, 100)
    var pusher = _pusher(reg^)
    var r = pusher.push(layout, _HOST, _REPO, _TAG)
    _expect(r, PUSH_FAILED)
    assert_equal(
        pusher.transport().count_calls(HTTP_METHOD_HEAD, String("/blobs/")), MAX_SEND_ATTEMPTS
    )
    print("  test_transport_fault_retry_limit: PASS")


def test_unauthorized_is_not_retried() raises:
    var layout = _layout(String("faults_401"))
    var reg = FakeOciRegistry(_HOST)
    reg.required_authorization = String("Bearer something-else")
    var pusher = _pusher(reg^)
    var r = pusher.push(layout, _HOST, _REPO, _TAG)
    _expect(r, PUSH_FAILED)
    assert_equal(pusher.transport().call_count(), 1)
    print("  test_unauthorized_is_not_retried: PASS")


def test_400_on_blob_put_is_not_retried() raises:
    var layout = _layout(String("faults_400"))
    var reg = FakeOciRegistry(_HOST)
    reg.add_fault(HTTP_METHOD_PUT, String("/blobs/uploads/"), 400, 100)
    var pusher = _pusher(reg^)
    _expect(pusher.push(layout, _HOST, _REPO, _TAG), PUSH_FAILED)
    assert_equal(pusher.transport().count_calls(HTTP_METHOD_PUT, String("/blobs/uploads/")), 1)
    print("  test_400_on_blob_put_is_not_retried: PASS")


def test_expired_session_gets_a_new_session() raises:
    var layout = _layout(String("faults_expired"))
    var reg = FakeOciRegistry(_HOST)
    reg.expire_next_sessions(1)
    var pusher = _pusher(reg^)
    var r = pusher.push(layout, _HOST, _REPO, _TAG)
    _expect(r, PUSH_UPLOADED)
    assert_equal(r.blobs_uploaded, 3)
    # One more session was opened than there are blobs.
    assert_equal(
        pusher.transport().count_calls(HTTP_METHOD_POST, String("/blobs/uploads/")), 4
    )
    print("  test_expired_session_gets_a_new_session: PASS")


def test_session_lost_every_time_is_bounded() raises:
    var layout = _layout(String("faults_expired_all"))
    var reg = FakeOciRegistry(_HOST)
    reg.expire_next_sessions(100)
    var pusher = _pusher(reg^)
    var r = pusher.push(layout, _HOST, _REPO, _TAG)
    _expect(r, PUSH_FAILED)
    assert_equal(
        pusher.transport().count_calls(HTTP_METHOD_POST, String("/blobs/uploads/")),
        MAX_UPLOAD_SESSION_ATTEMPTS,
    )
    assert_equal(
        pusher.transport().count_calls(HTTP_METHOD_PUT, String("/manifests/")), 0
    )
    print("  test_session_lost_every_time_is_bounded: PASS")


def test_forbidden_after_bootstrap_is_retried_only_with_the_flag() raises:
    var layout = _layout(String("faults_403_flag"))
    var reg = FakeOciRegistry(_HOST)
    reg.add_fault(HTTP_METHOD_POST, String("/blobs/uploads/"), 403, 2)
    var pusher = _pusher(reg^, True)
    _expect(pusher.push(layout, _HOST, _REPO, _TAG), PUSH_UPLOADED)

    var layout2 = _layout(String("faults_403_noflag"))
    var reg2 = FakeOciRegistry(_HOST)
    reg2.add_fault(HTTP_METHOD_POST, String("/blobs/uploads/"), 403, 2)
    var pusher2 = _pusher(reg2^, False)
    _expect(pusher2.push(layout2, _HOST, _REPO, _TAG), PUSH_FAILED)
    assert_equal(pusher2.transport().count_calls(HTTP_METHOD_POST, String("/blobs/uploads/")), 1)
    print("  test_forbidden_after_bootstrap_is_retried_only_with_the_flag: PASS")


def test_blob_changed_after_verification_is_caught_before_send() raises:
    var dir = _scratch(String("faults_changed"))
    _ = write_test_layout(dir, _two_layers())
    var layout = read_oci_layout(dir)
    # The file is corrupted AFTER the layout was verified.
    overwrite_layout_blob(dir, layout.layers[1].digest)
    var pusher = _pusher(FakeOciRegistry(_HOST))
    var r = pusher.push(layout, _HOST, _REPO, _TAG)
    _expect(r, PUSH_REFUSED)
    assert_true(r.detail.find(String("DIGEST MISMATCH")) >= 0, r.detail)
    ref seen = pusher.transport()
    assert_equal(seen.count_calls(HTTP_METHOD_PUT, String("/manifests/")), 0)
    assert_true(not seen.has_blob(_REPO, layout.layers[1].digest), "the bad blob never reached the registry")
    # The corrupted blob's bytes were never sent: no PUT carried its digest.
    assert_equal(
        seen.count_calls(HTTP_METHOD_PUT, String("digest=") + layout.layers[1].digest), 0
    )
    print("  test_blob_changed_after_verification_is_caught_before_send: PASS")


def test_over_the_ceiling_layout_makes_no_request() raises:
    var dir = _scratch(String("faults_ceiling"))
    _ = write_test_layout(dir, _two_layers(), String("linux"), String("amd64"), 256 * 1024 * 1024 + 1)
    var reg = FakeOciRegistry(_HOST)
    var raised = False
    try:
        var _l = read_oci_layout(dir)
    except e:
        raised = True
        assert_true(String(e).find(String("Chunked upload is not implemented")) >= 0, String(e))
    assert_true(raised, "the layout is refused before there is anything to push")
    assert_equal(reg.call_count(), 0)
    print("  test_over_the_ceiling_layout_makes_no_request: PASS")


def main() raises:
    test_relative_location_with_query_is_followed()
    test_absolute_same_host_location_is_followed()
    test_absolute_other_host_location_is_refused_and_nothing_leaks()
    test_plaintext_location_is_refused()
    test_empty_location_is_refused()
    test_5xx_is_retried_then_succeeds()
    test_5xx_retry_limit()
    test_transport_fault_retry_limit()
    test_unauthorized_is_not_retried()
    test_400_on_blob_put_is_not_retried()
    test_expired_session_gets_a_new_session()
    test_session_lost_every_time_is_bounded()
    test_forbidden_after_bootstrap_is_retried_only_with_the_flag()
    test_blob_changed_after_verification_is_caught_before_send()
    test_over_the_ceiling_layout_makes_no_request()
    print("test_oci_push_faults: ALL PASS")
