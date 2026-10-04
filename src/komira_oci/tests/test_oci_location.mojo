# =============================================================================
# test_oci_location.mojo — Upload Location resolution, the copier over it, and request bodies by move.
# =============================================================================
#
#   (1) `resolve_upload_location` over the five shapes: relative, absolute on
#       the same host, absolute on another host (refused), plaintext (refused),
#       and a Location carrying its own query;
#   (2) the COPIER, which had the same gap, now follows an absolute same-host
#       Location and refuses a cross-host or plaintext one — over the in-process
#       registry, with the same bytes and the same digest at the end;
#   (3) `with_basic` encodes `user:password`, and is a no-op on an empty
#       password; `take_body` MOVES a request's body out.
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

from komira_oci.oci_copy import OciCopier
from komira_oci.oci_location import append_query, resolve_upload_location
from komira_oci.oci_transport import OciRequest, OciResponse, ScriptedOciTransport


def _refused(location: String, needle: String) raises:
    var raised = False
    try:
        var _t = resolve_upload_location(_HOST, location)
    except e:
        raised = True
        assert_true(String(e).find(needle) >= 0, "'" + location + "': " + String(e))
    assert_true(raised, "'" + location + "' must be refused")


def test_resolve_five_shapes() raises:
    var rel = resolve_upload_location(_HOST, String("/v2/r/blobs/uploads/abc"))
    assert_equal(rel.host, _HOST)
    assert_equal(rel.path, String("/v2/r/blobs/uploads/abc"))

    var abs_same = resolve_upload_location(
        _HOST, String("https://") + _HOST + String("/v2/r/blobs/uploads/abc?_state=1")
    )
    assert_equal(abs_same.host, _HOST)
    assert_equal(abs_same.path, String("/v2/r/blobs/uploads/abc?_state=1"))

    var with_query = resolve_upload_location(_HOST, String("/v2/r/blobs/uploads/abc?_state=1"))
    assert_equal(with_query.path, String("/v2/r/blobs/uploads/abc?_state=1"))
    assert_equal(
        append_query(with_query.path, String("digest=sha256:x")),
        String("/v2/r/blobs/uploads/abc?_state=1&digest=sha256:x"),
    )
    assert_equal(
        append_query(rel.path, String("digest=sha256:x")),
        String("/v2/r/blobs/uploads/abc?digest=sha256:x"),
    )

    _refused(String("https://other.example.net/v2/r/blobs/uploads/abc"), String("another host"))
    _refused(String("http://") + _HOST + String("/v2/x"), String("PLAINTEXT"))
    _refused(String(""), String("no Location"))
    _refused(String("https://") + _HOST, String("no path"))
    _refused(String("relative/path"), String("cannot resolve"))
    # A case variant of the same host is another host: it fails closed.
    _refused(String("https://US-CENTRAL1-DOCKER.PKG.DEV/v2/x"), String("another host"))
    print("  test_resolve_five_shapes: PASS")


def _seeded_copy_registry(mode: Int, name: String) raises -> FakeOciRegistry:
    var layout = _layout(name)
    var reg = FakeOciRegistry(_HOST)
    reg.location_mode = mode
    var blobs = layout.push_blobs()
    for i in range(len(blobs)):
        _ = reg.seed_blob(String("src/app"), layout.read_blob(blobs[i]))
    _ = reg.seed_manifest(String("src/app"), layout.manifest_media_type, layout.manifest_raw)
    return reg^


def test_copier_follows_absolute_same_host_location() raises:
    var layout = _layout(String("loc_copy_abs"))
    var reg = _seeded_copy_registry(LOCATION_ABSOLUTE_SAME_HOST, String("loc_copy_abs"))
    var copier = OciCopier[FakeOciRegistry](reg^, String("tok"), String("tok"))
    var src = _HOST + String("/src/app@") + layout.manifest_digest
    var dst = _HOST + String("/dst/app@") + layout.manifest_digest
    var got = copier.copy_by_digest(src, dst)
    assert_equal(got, layout.manifest_digest)
    assert_true(copier.transport().has_manifest(String("dst/app"), layout.manifest_digest), "copied")
    assert_equal(copier.transport().blob_count(String("dst/app")), 3)
    print("  test_copier_follows_absolute_same_host_location: PASS")


def test_copier_refuses_cross_host_and_plaintext_locations() raises:
    var layout = _layout(String("loc_copy_x"))
    var reg = _seeded_copy_registry(LOCATION_ABSOLUTE_OTHER_HOST, String("loc_copy_x"))
    var copier = OciCopier[FakeOciRegistry](reg^, String("tok"), String("tok"))
    var raised = False
    try:
        var _d = copier.copy_by_digest(
            _HOST + String("/src/app@") + layout.manifest_digest,
            _HOST + String("/dst/app@") + layout.manifest_digest,
        )
    except e:
        raised = True
        assert_true(String(e).find(String("another host")) >= 0, String(e))
    assert_true(raised, "a cross-host upload Location is refused by the copier too")
    assert_equal(copier.transport().calls_to_other_hosts(), 0)
    assert_equal(copier.transport().count_calls(HTTP_METHOD_PUT, String("/blobs/uploads/")), 0)

    var reg2 = _seeded_copy_registry(LOCATION_PLAINTEXT, String("loc_copy_p"))
    var copier2 = OciCopier[FakeOciRegistry](reg2^, String("tok"), String("tok"))
    var raised2 = False
    try:
        var _d2 = copier2.copy_by_digest(
            _HOST + String("/src/app@") + layout.manifest_digest,
            _HOST + String("/dst/app@") + layout.manifest_digest,
        )
    except e:
        raised2 = True
        assert_true(String(e).find(String("PLAINTEXT")) >= 0, String(e))
    assert_true(raised2, "a plaintext upload Location is refused by the copier")
    print("  test_copier_refuses_cross_host_and_plaintext_locations: PASS")


def test_basic_auth_and_take_body() raises:
    var req = OciRequest(HTTP_METHOD_PUT, String("h"), String("/p"))
    req.with_basic(String("oauth2accesstoken"), String("tok"))
    assert_equal(
        req.header_value(String("authorization")),
        String("Basic b2F1dGgyYWNjZXNzdG9rZW46dG9r"),
    )
    var anon = OciRequest(HTTP_METHOD_GET, String("h"), String("/p"))
    anon.with_basic(String("u"), String(""))
    assert_equal(anon.header_value(String("authorization")), String(""))

    req.with_body(_bytes(String("payload")))
    var taken = req.take_body()
    assert_equal(len(taken), 7)
    assert_equal(len(req.body), 0)
    print("  test_basic_auth_and_take_body: PASS")


def _scripted(status: Int) -> OciResponse:
    return OciResponse(status)


def test_pusher_over_scripted_transport_refuses_cross_host_without_sending() raises:
    """The same refusal over the SCRIPTED double, which records the exact
    conversation: the call after the session POST must not exist."""
    var layout = _layout(String("loc_scripted"))
    var t = ScriptedOciTransport()
    t.queue(_scripted(404))  # HEAD tag: absent
    t.queue(_scripted(404))  # HEAD manifest by digest: absent
    t.queue(_scripted(404))  # HEAD first blob: absent
    var session = OciResponse(202)
    session.with_header(
        String("location"), String("https://elsewhere.example.net/v2/x/blobs/uploads/1")
    )
    t.queue(session^)  # POST: a session on ANOTHER host
    var pusher = LayoutPusher[ScriptedOciTransport](
        t^, OciAuth.bearer(String("tok-123")), False, 0
    )
    var r = pusher.push(layout, _HOST, _REPO, _TAG)
    _expect(r, PUSH_FAILED)
    ref seen = pusher.transport()
    assert_equal(seen.call_count(), 4)
    for i in range(seen.call_count()):
        assert_equal(seen.call_registry(i), _HOST)
        assert_equal(seen.call_auth(i), String("Bearer tok-123"))
    assert_equal(seen.call_method(3), HTTP_METHOD_POST)
    print("  test_pusher_over_scripted_transport_refuses_cross_host_without_sending: PASS")


def main() raises:
    test_pusher_over_scripted_transport_refuses_cross_host_without_sending()
    test_resolve_five_shapes()
    test_copier_follows_absolute_same_host_location()
    test_copier_refuses_cross_host_and_plaintext_locations()
    test_basic_auth_and_take_body()
    print("test_oci_location: ALL PASS")
