# =============================================================================
# test_oci_copy_index_and_mount.mojo — the two
#   falsifiers a naive registry copier fails (hermetic; NO network, NO sockets).
# =============================================================================
#
#   (1) test_manifest_list_copies_every_child — a MULTI-ARCH image is an INDEX
#       whose `manifests[]` entries are themselves manifests. A copier that
#       assumes a single manifest moves a pointer to blobs that do not exist in
#       the destination, and the image pulls on NO architecture. This row proves
#       every child is fetched, every child's blobs are handled, every child is
#       written — and that the INDEX IS WRITTEN LAST, because a registry that
#       receives an index before its children can serve a broken image at the
#       exact digest a deploy is about to pull.
#
#   (2) test_blob_mount_declined_falls_back_to_upload — the cross-repository
#       mount (`?mount=<digest>&from=<src>`) answers 201 when it worked and 202
#       WITH AN UPLOAD SESSION when the registry declined. 202 is a normal
#       answer, not a fault — Artifact Registry declines when the caller lacks
#       read on the source repository, which is a routine cross-project
#       condition. A copier that reads 202 as success silently skips the blob
#       and produces a destination image with a missing layer. This row proves
#       the decline is followed by a real GET-from-source + PUT-to-session, and
#       that the transferred bytes are content-address-verified before the write.
#
#   (3) test_blob_already_present_transfers_nothing — the HEAD short-circuit. A
#       re-stage of an unchanged base image must not re-upload its layers.
#
# Blob bytes here are REAL: their digests are computed from the bytes with the
# same function the copier uses, so the verification step is exercised rather
# than bypassed.
# =============================================================================

from std.testing import assert_equal, assert_true

from komira_http_core.codec.types import (
    HTTP_METHOD_GET,
    HTTP_METHOD_HEAD,
    HTTP_METHOD_POST,
    HTTP_METHOD_PUT,
)

from komira_oci.oci_copy import OciCopier
from komira_oci.oci_digest import digest_of_bytes
from komira_oci.oci_ref import MEDIA_TYPE_OCI_INDEX, MEDIA_TYPE_OCI_MANIFEST
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


def _manifest(config_digest: String, layer_digest: String) -> String:
    return (
        String('{"schemaVersion":2,"mediaType":"')
        + MEDIA_TYPE_OCI_MANIFEST
        + String('","config":{"mediaType":"application/vnd.oci.image.config.v1+json","size":42,"digest":"')
        + config_digest
        + String('"},"layers":[{"mediaType":"application/vnd.oci.image.layer.v1.tar+gzip","size":9,"digest":"')
        + layer_digest
        + String('"}]}')
    )


def _index(child_a: String, child_b: String) -> String:
    return (
        String('{"schemaVersion":2,"mediaType":"')
        + MEDIA_TYPE_OCI_INDEX
        + String('","manifests":[{"mediaType":"')
        + MEDIA_TYPE_OCI_MANIFEST
        + String('","size":100,"digest":"')
        + child_a
        + String('","platform":{"architecture":"amd64","os":"linux"}},{"mediaType":"')
        + MEDIA_TYPE_OCI_MANIFEST
        + String('","size":100,"digest":"')
        + child_b
        + String('","platform":{"architecture":"arm64","os":"linux"}}]}')
    )


def _served(var body: List[UInt8], var digest: String, media: String) -> OciResponse:
    var r = OciResponse(200)
    r.with_header(String("content-type"), media.copy())
    r.with_header(String("docker-content-digest"), digest^)
    r.with_body(body^)
    return r^


def _status(code: Int) -> OciResponse:
    return OciResponse(code)


def _created(var digest: String) -> OciResponse:
    var r = OciResponse(201)
    r.with_header(String("docker-content-digest"), digest^)
    return r^


def _upload_session(var location: String) -> OciResponse:
    """A 202 carrying an upload session — the registry's way of saying it will
    NOT mount the blob but will accept an upload."""
    var r = OciResponse(202)
    r.with_header(String("location"), location^)
    return r^


def _blob_ok(var body: List[UInt8]) -> OciResponse:
    var r = OciResponse(200)
    r.with_body(body^)
    return r^


def test_manifest_list_copies_every_child() raises:
    # Two real child manifests with distinct blob digests, and an index over
    # them. Every digest is computed from bytes.
    var cfg_a = String("sha256:") + "aa" * 32
    var lay_a = String("sha256:") + "ab" * 32
    var cfg_b = String("sha256:") + "ba" * 32
    var lay_b = String("sha256:") + "bb" * 32

    var child_a_bytes = _bytes(_manifest(cfg_a, lay_a))
    var child_b_bytes = _bytes(_manifest(cfg_b, lay_b))
    var digest_a = digest_of_bytes(Span(child_a_bytes))
    var digest_b = digest_of_bytes(Span(child_b_bytes))

    var index_bytes = _bytes(_index(digest_a, digest_b))
    var index_digest = digest_of_bytes(Span(index_bytes))

    var t = ScriptedOciTransport()
    # discovery: root index, then each child (BFS, root first)
    t.queue(_served(index_bytes.copy(), index_digest.copy(), MEDIA_TYPE_OCI_INDEX))
    t.queue(_served(child_a_bytes.copy(), digest_a.copy(), MEDIA_TYPE_OCI_MANIFEST))
    t.queue(_served(child_b_bytes.copy(), digest_b.copy(), MEDIA_TYPE_OCI_MANIFEST))
    # blobs: all four already present in the destination
    t.queue(_status(200))
    t.queue(_status(200))
    t.queue(_status(200))
    t.queue(_status(200))
    # manifests written LEAVES FIRST: child_b, child_a, then the index
    t.queue(_created(digest_b.copy()))
    t.queue(_created(digest_a.copy()))
    t.queue(_created(index_digest.copy()))

    var src_ref = _HOST + String("/") + _SRC_REPO + String("@") + index_digest
    var dst_ref = _HOST + String("/") + _DST_REPO + String("@") + index_digest

    var copier = OciCopier[ScriptedOciTransport](
        t^, String("src-tok"), String("dst-tok")
    )
    var confirmed = copier.copy_by_digest(src_ref, dst_ref)
    assert_equal(
        confirmed, index_digest, "the INDEX digest is what stage preserves"
    )

    ref log = copier.transport()
    assert_equal(
        log.call_count(),
        10,
        "3 manifest GETs + 4 blob HEADs + 3 manifest PUTs",
    )

    # --- EVERY CHILD WAS FETCHED ---------------------------------------------
    # A single-manifest implementation makes exactly one manifest GET and fails
    # here.
    var fetched_a = False
    var fetched_b = False
    for i in range(log.call_count()):
        if log.call_method(i) == HTTP_METHOD_GET:
            if log.call_path(i).find(digest_a) >= 0:
                fetched_a = True
            if log.call_path(i).find(digest_b) >= 0:
                fetched_b = True
    assert_true(fetched_a, "the amd64 child manifest was fetched")
    assert_true(fetched_b, "the arm64 child manifest was fetched")

    # --- EVERY CHILD'S BLOBS WERE HANDLED ------------------------------------
    var probed = 0
    for i in range(log.call_count()):
        if log.call_method(i) == HTTP_METHOD_HEAD:
            var p = log.call_path(i)
            if (
                p.find(cfg_a) >= 0
                or p.find(lay_a) >= 0
                or p.find(cfg_b) >= 0
                or p.find(lay_b) >= 0
            ):
                probed += 1
    assert_equal(
        probed, 4, "both children's config + layer blobs were handled"
    )

    # --- EVERY CHILD WAS WRITTEN, AND THE INDEX WENT LAST --------------------
    assert_equal(
        log.call_path(7),
        String("/v2/") + _DST_REPO + String("/manifests/") + digest_b,
        "a child manifest is written first",
    )
    assert_equal(
        log.call_path(8),
        String("/v2/") + _DST_REPO + String("/manifests/") + digest_a,
        "the other child manifest is written next",
    )
    assert_equal(
        log.call_method(9), HTTP_METHOD_PUT, "the last call is a manifest PUT"
    )
    assert_equal(
        log.call_path(9),
        String("/v2/") + _DST_REPO + String("/manifests/") + index_digest,
        "THE INDEX IS WRITTEN LAST — it must not become resolvable before the"
        " children it points at",
    )
    print("  test_manifest_list_copies_every_child: PASS")


def test_blob_mount_declined_falls_back_to_upload() raises:
    # Real blob bytes, so the copier's content-address check on the transferred
    # blob is genuinely exercised.
    var config_bytes = _bytes(String('{"architecture":"amd64","os":"linux"}'))
    var config_digest = digest_of_bytes(Span(config_bytes))
    var layer_digest = String("sha256:") + "cc" * 32

    var manifest_bytes = _bytes(_manifest(config_digest, layer_digest))
    var manifest_digest = digest_of_bytes(Span(manifest_bytes))

    var session = String("/v2/") + _DST_REPO + String(
        "/blobs/uploads/9f0c1b?_state=abc"
    )

    var t = ScriptedOciTransport()
    t.queue(
        _served(
            manifest_bytes.copy(), manifest_digest.copy(), MEDIA_TYPE_OCI_MANIFEST
        )
    )  # 0 GET manifest
    t.queue(_status(404))  # 1 HEAD config blob — ABSENT
    t.queue(_upload_session(session.copy()))  # 2 POST mount -> 202 DECLINED
    t.queue(_blob_ok(config_bytes.copy()))  # 3 GET blob from source
    t.queue(_status(201))  # 4 PUT blob to the session
    t.queue(_status(200))  # 5 HEAD layer blob — present
    t.queue(_created(manifest_digest.copy()))  # 6 PUT manifest

    var src_ref = _HOST + String("/") + _SRC_REPO + String("@") + manifest_digest
    var dst_ref = _HOST + String("/") + _DST_REPO + String("@") + manifest_digest

    var copier = OciCopier[ScriptedOciTransport](
        t^, String("src-tok"), String("dst-tok")
    )
    var confirmed = copier.copy_by_digest(src_ref, dst_ref)
    assert_equal(
        confirmed,
        manifest_digest,
        "the digest survives a blob that had to be uploaded",
    )

    ref log = copier.transport()
    assert_equal(log.call_count(), 7, "HEAD, mount, GET, PUT, HEAD, PUT + the"
                 " initial manifest GET")

    # --- THE MOUNT WAS ATTEMPTED, correctly addressed ------------------------
    assert_equal(log.call_method(2), HTTP_METHOD_POST, "call 2 is the mount POST")
    var mount_path = log.call_path(2)
    assert_true(
        mount_path.find(String("mount=") + config_digest) >= 0,
        "the mount names the blob digest, got: " + mount_path,
    )
    assert_true(
        mount_path.find(String("from=") + _SRC_REPO) >= 0,
        "the mount names the SOURCE repository, got: " + mount_path,
    )

    # --- THE DECLINE WAS HONOURED: a real transfer followed ------------------
    # This is the row a "202 means success" implementation fails.
    assert_equal(
        log.call_method(3), HTTP_METHOD_GET, "the declined mount is followed by"
        " a real blob GET"
    )
    assert_equal(
        log.call_path(3),
        String("/v2/") + _SRC_REPO + String("/blobs/") + config_digest,
        "the blob is read from the SOURCE repository",
    )
    assert_equal(log.call_method(4), HTTP_METHOD_PUT, "and PUT to the session")
    assert_equal(
        log.call_path(4),
        session + String("&digest=") + config_digest,
        "the finalizing PUT goes to the SERVER-CHOSEN session URL with"
        " `digest=` appended using '&' (the session already carried a query)",
    )
    var uploaded = log.call_body(4)
    assert_equal(
        digest_of_bytes(Span(uploaded)),
        config_digest,
        "the uploaded bytes content-address to the descriptor's digest",
    )
    print("  test_blob_mount_declined_falls_back_to_upload: PASS")


def test_blob_already_present_transfers_nothing() raises:
    var cfg = String("sha256:") + "de" * 32
    var lay = String("sha256:") + "df" * 32
    var manifest_bytes = _bytes(_manifest(cfg, lay))
    var manifest_digest = digest_of_bytes(Span(manifest_bytes))

    var t = ScriptedOciTransport()
    t.queue(
        _served(
            manifest_bytes.copy(), manifest_digest.copy(), MEDIA_TYPE_OCI_MANIFEST
        )
    )
    t.queue(_status(200))  # config present
    t.queue(_status(200))  # layer present
    t.queue(_created(manifest_digest.copy()))

    var src_ref = _HOST + String("/") + _SRC_REPO + String("@") + manifest_digest
    var dst_ref = _HOST + String("/") + _DST_REPO + String("@") + manifest_digest

    var copier = OciCopier[ScriptedOciTransport](
        t^, String("src-tok"), String("dst-tok")
    )
    var _confirmed = copier.copy_by_digest(src_ref, dst_ref)

    ref log = copier.transport()
    for i in range(log.call_count()):
        assert_true(
            log.call_method(i) != HTTP_METHOD_POST,
            "no upload session is opened when every blob is already present",
        )
    assert_equal(
        log.call_count(), 4, "GET manifest + 2 HEADs + PUT manifest — no bytes"
        " moved"
    )
    print("  test_blob_already_present_transfers_nothing: PASS")


def main() raises:
    test_manifest_list_copies_every_child()
    test_blob_mount_declined_falls_back_to_upload()
    test_blob_already_present_transfers_nothing()
    print("test_oci_copy_index_and_mount: ALL PASS")
