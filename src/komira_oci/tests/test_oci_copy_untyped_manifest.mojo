# =============================================================================
# test_oci_copy_untyped_manifest.mojo — a manifest GET answered with NO
#   `Content-Type` (hermetic; NO network, NO sockets).
# =============================================================================
#
# The copier learns whether a manifest is an INDEX (walk `manifests[]`) or an
# IMAGE MANIFEST (copy `config` + `layers`) from the GET's `Content-Type`, and
# it declares that same type on the destination PUT. A registry that omits the
# header leaves only the body to decide from. A copier that defaults every
# untyped body to the OCI image manifest drops an index's children: it never
# fetches them, copies no blob, PUTs the index alone declared as an image
# manifest, and still reports success because the root digest matches.
#
#   (1) test_untyped_oci_index_copies_every_child — an OCI index whose body
#       says `"mediaType": "...index.v1+json"`. Every child is fetched, both
#       children are written before the index, and the index is declared as an
#       index. A copier that ignores the body makes 2 calls and fails here.
#   (2) test_untyped_docker_manifest_list_is_walked — the same for a Docker
#       manifest list, whose child is itself untyped and says it is a Docker
#       image manifest; each PUT declares the type the body names.
#   (3) test_untyped_index_without_media_type_field — `mediaType` is optional
#       in an OCI index; a body with a `manifests` array is an index.
#   (4) test_untyped_manifest_without_media_type_field — a body with neither
#       `mediaType` nor `manifests` keeps the OCI image manifest default.
#   (5) test_untyped_index_with_empty_media_type — `"mediaType": ""` names
#       no type; the `manifests` array still makes the body an index. A copier
#       that returns the empty string drops every child and PUTs with an empty
#       content-type.
#   (6) test_untyped_index_with_non_string_media_type — `"mediaType": 5` is
#       not a type either; the body is still an index and the copy succeeds.
#   (7) test_untyped_manifest_with_non_array_manifests — `"manifests": null`
#       or `{}` beside `config` and `layers` is an image manifest: its blobs
#       are checked and the PUT declares an OCI image manifest, not an index.
#   (8) test_typed_manifest_header_wins_over_body — the body is consulted
#       ONLY when the header is absent: a Docker image manifest served WITH its
#       Content-Type and a body that carries no `mediaType` is PUT declared as
#       the Docker type the header names.
# =============================================================================

from std.testing import assert_equal, assert_true

from komira_http_core.codec.types import (
    HTTP_METHOD_GET,
    HTTP_METHOD_HEAD,
    HTTP_METHOD_PUT,
)

from komira_oci.oci_copy import OciCopier
from komira_oci.oci_digest import digest_of_bytes
from komira_oci.oci_ref import (
    MEDIA_TYPE_DOCKER_MANIFEST,
    MEDIA_TYPE_DOCKER_MANIFEST_LIST,
    MEDIA_TYPE_OCI_INDEX,
    MEDIA_TYPE_OCI_MANIFEST,
)
from komira_oci.oci_transport import OciResponse, ScriptedOciTransport


comptime _HOST: String = "europe-docker.pkg.dev"
comptime _SRC_REPO: String = "example-build/images/app"
comptime _DST_REPO: String = "example-release/images/app"


def _bytes(s: String) -> List[UInt8]:
    var out = List[UInt8]()
    var src = s.as_bytes()
    for i in range(len(src)):
        out.append(src[i])
    return out^


def _manifest_body(media_field: String, cfg: String, lay: String) -> String:
    """An image manifest; `media_field` is the `"mediaType":"...",` prefix, or
    empty for a body that carries no `mediaType`."""
    return (
        String('{"schemaVersion":2,')
        + media_field
        + String('"config":{"mediaType":"application/vnd.oci.image.config.v1+json","size":42,"digest":"')
        + cfg
        + String('"},"layers":[{"mediaType":"application/vnd.oci.image.layer.v1.tar+gzip","size":9,"digest":"')
        + lay
        + String('"}]}')
    )


def _index_body(media_field: String, children: List[String]) -> String:
    var out = String('{"schemaVersion":2,') + media_field + String(
        '"manifests":['
    )
    for i in range(len(children)):
        if i > 0:
            out += String(",")
        out += (
            String('{"mediaType":"')
            + MEDIA_TYPE_OCI_MANIFEST
            + String('","size":100,"digest":"')
            + children[i]
            + String('"}')
        )
    out += String("]}")
    return out^


def _media_field(media: String) -> String:
    return String('"mediaType":"') + media + String('",')


def _untyped(var body: List[UInt8], var digest: String) -> OciResponse:
    """A 200 manifest answer that carries NO `content-type` header."""
    var r = OciResponse(200)
    r.with_header(String("docker-content-digest"), digest^)
    r.with_body(body^)
    return r^


def _typed(var body: List[UInt8], var digest: String, media: String) -> OciResponse:
    var r = OciResponse(200)
    r.with_header(String("content-type"), media.copy())
    r.with_header(String("docker-content-digest"), digest^)
    r.with_body(body^)
    return r^


def _present() -> OciResponse:
    return OciResponse(200)


def _created(var digest: String) -> OciResponse:
    var r = OciResponse(201)
    r.with_header(String("docker-content-digest"), digest^)
    return r^


def _copy(var t: ScriptedOciTransport, root: String) raises -> OciCopier[
    ScriptedOciTransport
]:
    var copier = OciCopier[ScriptedOciTransport](
        t^, String("src-tok"), String("dst-tok")
    )
    var src_ref = _HOST + String("/") + _SRC_REPO + String("@") + root
    var dst_ref = _HOST + String("/") + _DST_REPO + String("@") + root
    var confirmed = copier.copy_by_digest(src_ref, dst_ref)
    assert_equal(confirmed, root, "the root digest is what the copy preserves")
    return copier^


def _fetched(log: ScriptedOciTransport, digest: String) -> Bool:
    for i in range(log.call_count()):
        if log.call_method(i) == HTTP_METHOD_GET:
            if log.call_path(i).find(String("/manifests/") + digest) >= 0:
                return True
    return False


def _assert_put(
    log: ScriptedOciTransport, i: Int, digest: String, media: String
) raises:
    assert_equal(log.call_method(i), HTTP_METHOD_PUT, "call is a manifest PUT")
    assert_equal(
        log.call_path(i),
        String("/v2/") + _DST_REPO + String("/manifests/") + digest,
        "the PUT writes this manifest",
    )
    assert_equal(
        log.call_content_type(i),
        media,
        "the PUT declares the source header's type, else the body's own",
    )


def test_untyped_oci_index_copies_every_child() raises:
    var cfg_a = String("sha256:") + "a1" * 32
    var lay_a = String("sha256:") + "a2" * 32
    var cfg_b = String("sha256:") + "b1" * 32
    var lay_b = String("sha256:") + "b2" * 32
    var child_a = _bytes(
        _manifest_body(_media_field(MEDIA_TYPE_OCI_MANIFEST), cfg_a, lay_a)
    )
    var child_b = _bytes(
        _manifest_body(_media_field(MEDIA_TYPE_OCI_MANIFEST), cfg_b, lay_b)
    )
    var digest_a = digest_of_bytes(Span(child_a))
    var digest_b = digest_of_bytes(Span(child_b))
    var kids = List[String]()
    kids.append(digest_a.copy())
    kids.append(digest_b.copy())
    var index = _bytes(_index_body(_media_field(MEDIA_TYPE_OCI_INDEX), kids))
    var index_digest = digest_of_bytes(Span(index))

    var t = ScriptedOciTransport()
    t.queue(_untyped(index.copy(), index_digest.copy()))
    t.queue(_typed(child_a.copy(), digest_a.copy(), MEDIA_TYPE_OCI_MANIFEST))
    t.queue(_typed(child_b.copy(), digest_b.copy(), MEDIA_TYPE_OCI_MANIFEST))
    for _ in range(4):
        t.queue(_present())
    t.queue(_created(digest_b.copy()))
    t.queue(_created(digest_a.copy()))
    t.queue(_created(index_digest.copy()))

    var copier = _copy(t^, index_digest)
    ref log = copier.transport()
    assert_equal(
        log.call_count(),
        10,
        "3 manifest GETs + 4 blob HEADs + 3 manifest PUTs; an untyped index"
        " read as an image manifest makes only GET root + PUT root",
    )
    assert_true(_fetched(log, digest_a), "the first child was fetched")
    assert_true(_fetched(log, digest_b), "the second child was fetched")
    _assert_put(log, 7, digest_b, MEDIA_TYPE_OCI_MANIFEST)
    _assert_put(log, 8, digest_a, MEDIA_TYPE_OCI_MANIFEST)
    _assert_put(log, 9, index_digest, MEDIA_TYPE_OCI_INDEX)
    print("  test_untyped_oci_index_copies_every_child: PASS")


def test_untyped_docker_manifest_list_is_walked() raises:
    var cfg = String("sha256:") + "c1" * 32
    var lay = String("sha256:") + "c2" * 32
    var child = _bytes(
        _manifest_body(_media_field(MEDIA_TYPE_DOCKER_MANIFEST), cfg, lay)
    )
    var child_digest = digest_of_bytes(Span(child))
    var kids = List[String]()
    kids.append(child_digest.copy())
    var list_bytes = _bytes(
        _index_body(_media_field(MEDIA_TYPE_DOCKER_MANIFEST_LIST), kids)
    )
    var list_digest = digest_of_bytes(Span(list_bytes))

    var t = ScriptedOciTransport()
    t.queue(_untyped(list_bytes.copy(), list_digest.copy()))
    t.queue(_untyped(child.copy(), child_digest.copy()))
    t.queue(_present())
    t.queue(_present())
    t.queue(_created(child_digest.copy()))
    t.queue(_created(list_digest.copy()))

    var copier = _copy(t^, list_digest)
    ref log = copier.transport()
    assert_equal(
        log.call_count(), 6, "2 manifest GETs + 2 blob HEADs + 2 manifest PUTs"
    )
    assert_true(_fetched(log, child_digest), "the list's child was fetched")
    _assert_put(log, 4, child_digest, MEDIA_TYPE_DOCKER_MANIFEST)
    _assert_put(log, 5, list_digest, MEDIA_TYPE_DOCKER_MANIFEST_LIST)
    print("  test_untyped_docker_manifest_list_is_walked: PASS")


def test_untyped_index_without_media_type_field() raises:
    var cfg = String("sha256:") + "d1" * 32
    var lay = String("sha256:") + "d2" * 32
    var child = _bytes(
        _manifest_body(_media_field(MEDIA_TYPE_OCI_MANIFEST), cfg, lay)
    )
    var child_digest = digest_of_bytes(Span(child))
    var kids = List[String]()
    kids.append(child_digest.copy())
    var index = _bytes(_index_body(String(""), kids))
    var index_digest = digest_of_bytes(Span(index))

    var t = ScriptedOciTransport()
    t.queue(_untyped(index.copy(), index_digest.copy()))
    t.queue(_typed(child.copy(), child_digest.copy(), MEDIA_TYPE_OCI_MANIFEST))
    t.queue(_present())
    t.queue(_present())
    t.queue(_created(child_digest.copy()))
    t.queue(_created(index_digest.copy()))

    var copier = _copy(t^, index_digest)
    ref log = copier.transport()
    assert_equal(
        log.call_count(),
        6,
        "a body with a manifests array and no mediaType is walked as an index",
    )
    assert_true(_fetched(log, child_digest), "the index's child was fetched")
    _assert_put(log, 4, child_digest, MEDIA_TYPE_OCI_MANIFEST)
    _assert_put(log, 5, index_digest, MEDIA_TYPE_OCI_INDEX)
    print("  test_untyped_index_without_media_type_field: PASS")


def test_untyped_manifest_without_media_type_field() raises:
    var cfg = String("sha256:") + "e1" * 32
    var lay = String("sha256:") + "e2" * 32
    var body = _bytes(_manifest_body(String(""), cfg, lay))
    var digest = digest_of_bytes(Span(body))

    var t = ScriptedOciTransport()
    t.queue(_untyped(body.copy(), digest.copy()))
    t.queue(_present())
    t.queue(_present())
    t.queue(_created(digest.copy()))

    var copier = _copy(t^, digest)
    ref log = copier.transport()
    assert_equal(log.call_count(), 4, "GET manifest + 2 blob HEADs + PUT")
    _assert_put(log, 3, digest, MEDIA_TYPE_OCI_MANIFEST)
    print("  test_untyped_manifest_without_media_type_field: PASS")


def _untyped_index_with_media_value(media_json: String, seed: String) raises:
    """An untyped index whose `mediaType` is the raw JSON `media_json` (a value
    that names no media type) and whose `manifests` array has one child."""
    var cfg = String("sha256:") + (seed + "1") * 32
    var lay = String("sha256:") + (seed + "2") * 32
    var child = _bytes(
        _manifest_body(_media_field(MEDIA_TYPE_OCI_MANIFEST), cfg, lay)
    )
    var child_digest = digest_of_bytes(Span(child))
    var kids = List[String]()
    kids.append(child_digest.copy())
    var index = _bytes(
        _index_body(String('"mediaType":') + media_json + String(","), kids)
    )
    var index_digest = digest_of_bytes(Span(index))

    var t = ScriptedOciTransport()
    t.queue(_untyped(index.copy(), index_digest.copy()))
    t.queue(_typed(child.copy(), child_digest.copy(), MEDIA_TYPE_OCI_MANIFEST))
    t.queue(_present())
    t.queue(_present())
    t.queue(_created(child_digest.copy()))
    t.queue(_created(index_digest.copy()))

    var copier = _copy(t^, index_digest)
    ref log = copier.transport()
    assert_equal(
        log.call_count(),
        6,
        "a mediaType that names no type does not hide the manifests array:"
        " GET index + GET child + 2 blob HEADs + 2 PUTs",
    )
    assert_true(_fetched(log, child_digest), "the index's child was fetched")
    _assert_put(log, 4, child_digest, MEDIA_TYPE_OCI_MANIFEST)
    _assert_put(log, 5, index_digest, MEDIA_TYPE_OCI_INDEX)


def test_untyped_index_with_empty_media_type() raises:
    _untyped_index_with_media_value(String('""'), String("f"))
    print("  test_untyped_index_with_empty_media_type: PASS")


def test_untyped_index_with_non_string_media_type() raises:
    _untyped_index_with_media_value(String("5"), String("9"))
    print("  test_untyped_index_with_non_string_media_type: PASS")


def _untyped_manifest_with_manifests_value(
    manifests_json: String, seed: String
) raises:
    """An untyped image manifest (config + layers, no `mediaType`) that also
    carries `"manifests": <manifests_json>`, a value that is not an array."""
    var cfg = String("sha256:") + (seed + "1") * 32
    var lay = String("sha256:") + (seed + "2") * 32
    var body = _bytes(
        _manifest_body(
            String('"manifests":') + manifests_json + String(","), cfg, lay
        )
    )
    var digest = digest_of_bytes(Span(body))

    var t = ScriptedOciTransport()
    t.queue(_untyped(body.copy(), digest.copy()))
    t.queue(_present())
    t.queue(_present())
    t.queue(_created(digest.copy()))

    var copier = _copy(t^, digest)
    ref log = copier.transport()
    assert_equal(
        log.call_count(),
        4,
        "a manifests field that is not an array does not make an index:"
        " GET manifest + 2 blob HEADs + PUT",
    )
    assert_equal(
        log.call_method(1), HTTP_METHOD_HEAD, "the config blob is checked"
    )
    assert_true(
        log.call_path(1).find(String("/blobs/") + cfg) >= 0,
        "the first HEAD is the config blob",
    )
    assert_true(
        log.call_path(2).find(String("/blobs/") + lay) >= 0,
        "the second HEAD is the layer blob",
    )
    _assert_put(log, 3, digest, MEDIA_TYPE_OCI_MANIFEST)


def test_untyped_manifest_with_non_array_manifests() raises:
    _untyped_manifest_with_manifests_value(String("null"), String("7"))
    _untyped_manifest_with_manifests_value(String("{}"), String("8"))
    print("  test_untyped_manifest_with_non_array_manifests: PASS")


def test_typed_manifest_header_wins_over_body() raises:
    var cfg = String("sha256:") + "61" * 32
    var lay = String("sha256:") + "62" * 32
    var body = _bytes(_manifest_body(String(""), cfg, lay))
    var digest = digest_of_bytes(Span(body))

    var t = ScriptedOciTransport()
    t.queue(_typed(body.copy(), digest.copy(), MEDIA_TYPE_DOCKER_MANIFEST))
    t.queue(_present())
    t.queue(_present())
    t.queue(_created(digest.copy()))

    var copier = _copy(t^, digest)
    ref log = copier.transport()
    assert_equal(log.call_count(), 4, "GET manifest + 2 blob HEADs + PUT")
    _assert_put(log, 3, digest, MEDIA_TYPE_DOCKER_MANIFEST)
    print("  test_typed_manifest_header_wins_over_body: PASS")


def main() raises:
    test_untyped_oci_index_copies_every_child()
    test_untyped_docker_manifest_list_is_walked()
    test_untyped_index_without_media_type_field()
    test_untyped_manifest_without_media_type_field()
    test_untyped_index_with_empty_media_type()
    test_untyped_index_with_non_string_media_type()
    test_untyped_manifest_with_non_array_manifests()
    test_typed_manifest_header_wins_over_body()
    print("test_oci_copy_untyped_manifest: ALL PASS")
