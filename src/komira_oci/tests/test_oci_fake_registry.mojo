# =============================================================================
# test_oci_fake_registry.mojo — the in-process registry the push tests run
#   against answers like a registry where they do not look.
# =============================================================================
#
# The pusher's tests trust `FakeOciRegistry` to refuse what a registry
# refuses; a fake that accepted everything would let a pusher bug through.
# This file drives `send` directly:
#
#   (1) a call to another host, or to a path outside `/v2/`, is 404 even when
#       the same blob is stored;
#   (2) a verb a route does not take is 405 (GET on an upload, PUT on a blob,
#       POST on a manifest); an unknown route is 404;
#   (3) finishing an upload: no query is 400, no `digest=` is 400, a body that
#       does not hash to `digest=` is 400 (and the session stays open), and a
#       `digest=` followed by another parameter is accepted;
#   (4) a manifest PUT by a digest its body does not hash to is 400, and one
#       naming a blob the repository lacks is 400;
#   (5) re-seeding a tag MOVES it (one tag, the latest digest).
# =============================================================================

from std.testing import assert_equal, assert_true

from komira_http_core.codec.types import (
    HTTP_METHOD_GET,
    HTTP_METHOD_HEAD,
    HTTP_METHOD_POST,
    HTTP_METHOD_PUT,
)

from komira_oci.oci_digest import digest_of_bytes
from komira_oci.oci_fake_registry import FakeOciRegistry
from komira_oci.oci_transport import OciRequest, OciResponse

comptime _HOST: String = "registry.example.com"
comptime _REPO: String = "team/app"


def _bytes(s: String) -> List[UInt8]:
    var out = List[UInt8]()
    var src = s.as_bytes()
    for i in range(len(src)):
        out.append(src[i])
    return out^


def _send(
    mut reg: FakeOciRegistry,
    method: UInt8,
    path: String,
    var body: List[UInt8] = List[UInt8](),
    host: String = _HOST,
) raises -> OciResponse:
    var req = OciRequest(method, host.copy(), path.copy())
    req.with_body(body^)
    return reg.send(req^)


def test_other_host_and_non_v2_path_are_404() raises:
    var reg = FakeOciRegistry(_HOST)
    var d = reg.seed_blob(_REPO, _bytes(String("blob")))
    var path = String("/v2/") + _REPO + String("/blobs/") + d
    assert_equal(_send(reg, HTTP_METHOD_HEAD, path).status, 200, "the blob is there")
    assert_equal(
        _send(reg, HTTP_METHOD_HEAD, path, List[UInt8](), String("other.example.com")).status,
        404,
        "another host does not serve this registry's blobs",
    )
    assert_equal(
        _send(reg, HTTP_METHOD_HEAD, String("/v3/") + _REPO + String("/blobs/") + d).status,
        404,
        "only /v2/ is the API",
    )
    print("  test_other_host_and_non_v2_path_are_404: PASS")


def test_wrong_verb_is_405_and_unknown_route_is_404() raises:
    var reg = FakeOciRegistry(_HOST)
    var d = reg.seed_blob(_REPO, _bytes(String("blob")))
    var base = String("/v2/") + _REPO
    assert_equal(_send(reg, HTTP_METHOD_GET, base + String("/blobs/uploads/sess-1")).status, 405)
    assert_equal(_send(reg, HTTP_METHOD_PUT, base + String("/blobs/") + d).status, 405)
    assert_equal(_send(reg, HTTP_METHOD_POST, base + String("/manifests/latest")).status, 405)
    assert_equal(_send(reg, HTTP_METHOD_GET, base + String("/tags/list")).status, 404)
    print("  test_wrong_verb_is_405_and_unknown_route_is_404: PASS")


def _open(mut reg: FakeOciRegistry) raises -> String:
    var r = _send(reg, HTTP_METHOD_POST, String("/v2/") + _REPO + String("/blobs/uploads/"))
    assert_equal(r.status, 202)
    return r.header(String("location"))


def test_finishing_an_upload_checks_query_and_bytes() raises:
    var reg = FakeOciRegistry(_HOST)
    var data = _bytes(String("layer-data"))
    var d = digest_of_bytes(Span(data))
    var loc = _open(reg)
    assert_equal(_send(reg, HTTP_METHOD_PUT, loc, data.copy()).status, 400, "no query")
    assert_equal(
        _send(reg, HTTP_METHOD_PUT, loc + String("?x=1"), data.copy()).status,
        400,
        "no digest=",
    )
    assert_equal(
        _send(reg, HTTP_METHOD_PUT, loc + String("?digest=") + d, _bytes(String("other-data"))).status,
        400,
        "bytes that do not hash to digest=",
    )
    assert_true(not reg.has_blob(_REPO, d), "nothing stored by a refused PUT")
    # The session is still open, and a trailing parameter does not join the
    # digest.
    var ok = _send(reg, HTTP_METHOD_PUT, loc + String("?digest=") + d + String("&_state=z"), data.copy())
    assert_equal(ok.status, 201, "digest= then another parameter")
    assert_equal(ok.header(String("docker-content-digest")), d)
    assert_true(reg.has_blob(_REPO, d))
    print("  test_finishing_an_upload_checks_query_and_bytes: PASS")


def _manifest_naming(cfg: String) -> List[UInt8]:
    return _bytes(
        String('{"schemaVersion":2,"config":{"digest":"') + cfg + String('","size":2},"layers":[]}')
    )


def test_manifest_put_checks_digest_and_blobs() raises:
    var reg = FakeOciRegistry(_HOST)
    var cfg = reg.seed_blob(_REPO, _bytes(String("{}")))
    var manifest = _manifest_naming(cfg)
    var md = digest_of_bytes(Span(manifest))
    var base = String("/v2/") + _REPO + String("/manifests/")
    var wrong = String("sha256:") + "bb" * 32
    assert_equal(
        _send(reg, HTTP_METHOD_PUT, base + wrong, manifest.copy()).status,
        400,
        "a PUT by a digest the body does not hash to (its blob is present)",
    )
    assert_equal(_send(reg, HTTP_METHOD_HEAD, base + wrong).status, 404, "nothing stored")

    var orphan = _manifest_naming(String("sha256:") + "aa" * 32)
    var od = digest_of_bytes(Span(orphan))
    assert_equal(
        _send(reg, HTTP_METHOD_PUT, base + od, orphan.copy()).status,
        400,
        "a manifest naming a blob the repository lacks",
    )
    assert_equal(_send(reg, HTTP_METHOD_HEAD, base + od).status, 404, "nothing stored")

    assert_equal(
        _send(reg, HTTP_METHOD_PUT, base + md, manifest.copy()).status,
        201,
        "the right digest with its blob present is accepted",
    )
    print("  test_manifest_put_checks_digest_and_blobs: PASS")


def test_reseeding_a_tag_moves_it() raises:
    var reg = FakeOciRegistry(_HOST)
    var a = String("sha256:") + "aa" * 32
    var b = String("sha256:") + "bb" * 32
    reg.seed_tag(_REPO, String("v1"), a)
    reg.seed_tag(_REPO, String("v2"), a)
    reg.seed_tag(_REPO, String("v1"), b)
    assert_equal(reg.tag_digest(_REPO, String("v1")), b, "the tag moved")
    assert_equal(reg.tag_digest(_REPO, String("v2")), a, "the other tag did not")
    print("  test_reseeding_a_tag_moves_it: PASS")


def main() raises:
    test_other_host_and_non_v2_path_are_404()
    test_wrong_verb_is_405_and_unknown_route_is_404()
    test_finishing_an_upload_checks_query_and_bytes()
    test_manifest_put_checks_digest_and_blobs()
    test_reseeding_a_tag_moves_it()
    print("test_oci_fake_registry: ALL PASS")
