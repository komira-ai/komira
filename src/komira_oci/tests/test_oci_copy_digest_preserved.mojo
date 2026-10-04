# =============================================================================
# test_oci_copy_digest_preserved.mojo — the
#   DIGEST-PRESERVATION falsifiers (hermetic; NO cloud, NO network, NO sockets).
# =============================================================================
#
# WHAT THESE PROVE, over the SAME `OciCopier` code the production path runs, with
# a `ScriptedOciTransport` in place of HTTPS:
#
#   (1) test_cross_project_copy_preserves_digest — THE CORE CONTRACT. A
#       cross-PROJECT promote (`example-build/images/app` ->
#       `example-release/images/app`) returns the SOURCE digest, having READ
#       from the source repository and WRITTEN to the destination
#       repository, with each side's own bearer on its own leg. Asserted on
#       the recorded conversation, not on the return value alone — a copier
#       that returned the right String while writing to the wrong repository
#       would pass a return-value-only test.
#
#   (2) test_manifest_digest_mismatch_refuses — THE REFUSAL. When the registry
#       serves manifest bytes that do NOT content-address to the requested
#       digest, the copy RAISES and performs NO write. This is the row that
#       separates "we checked" from "we assumed": the digest is recomputed from
#       the bytes received, so a registry cannot talk its way past it with a
#       `Docker-Content-Digest` header.
#
#   (3) test_by_tag_source_refuses — a by-TAG source is rejected outright. A tag
#       can be repointed between resolve and copy, so a content-addressed
#       promote from a tag is not a copy of a known artifact.
#
#   (4) test_docker_content_digest_disagreement_refuses — if the destination
#       stores the manifest under a DIFFERENT digest than the one pushed, that
#       is refused too. The destination does not get to redefine the artifact.
#
# The SHA-256 here is the real one (aws-lc linked). A falsifier for digest
# preservation computed over a stubbed hash would prove nothing.
# =============================================================================

from std.testing import assert_equal, assert_true

from komira_http_core.codec.types import (
    HTTP_METHOD_GET,
    HTTP_METHOD_HEAD,
    HTTP_METHOD_PUT,
)

from komira_oci.oci_copy import OciCopier
from komira_oci.oci_digest import digest_of_bytes
from komira_oci.oci_ref import MEDIA_TYPE_OCI_MANIFEST
from komira_oci.oci_transport import (
    OciResponse,
    ScriptedOciTransport,
)


# Two GCP projects. Same Artifact Registry HOST, different project — which is
# exactly why nothing reaches the release project without a registry-to-registry
# copy, and why the cross-repository blob mount is worth attempting at all.
comptime _HOST: String = "europe-docker.pkg.dev"
comptime _SRC_REPO: String = "example-build/images/app"
comptime _DST_REPO: String = "example-release/images/app"

comptime _SRC_TOKEN: String = "src-project-bearer"
comptime _DST_TOKEN: String = "dst-project-bearer"


def _bytes(s: String) -> List[UInt8]:
    var out = List[UInt8]()
    var src = s.as_bytes()
    for i in range(len(src)):
        out.append(src[i])
    return out^


def _image_manifest(config_digest: String, layer_digest: String) -> String:
    """A minimal but SCHEMA-REAL OCI image manifest.

    ⚠ THE INDENTATION IS LOAD-BEARING. Compact JSON is a FIXED POINT of a JSON
    parse/serialize round-trip, so against a compact fixture a broken copier
    that re-serialized the manifest through the JSON DOM would still produce
    byte-identical output and the test would PASS, proving nothing about the
    property it claims to guard.

    Real registries serve pretty-printed manifests (Docker's own build output is
    3-space-indented), and a manifest's digest covers those exact bytes. With the
    whitespace present, a re-serializing copier emits compact JSON, the digest
    changes, and the assertion below goes RED — which is what it is for."""
    return (
        String('{\n   "schemaVersion": 2,\n   "mediaType": "')
        + MEDIA_TYPE_OCI_MANIFEST
        + String(
            '",\n   "config": {\n      "mediaType":'
            ' "application/vnd.oci.image.config.v1+json",\n      "size": 123,\n'
            '      "digest": "'
        )
        + config_digest
        + String(
            '"\n   },\n   "layers": [\n      {\n         "mediaType":'
            ' "application/vnd.oci.image.layer.v1.tar+gzip",\n         "size":'
            ' 4096,\n         "digest": "'
        )
        + layer_digest
        + String('"\n      }\n   ]\n}\n')
    )


def _ok_manifest(var body: List[UInt8], var digest: String) -> OciResponse:
    var r = OciResponse(200)
    r.with_header(String("content-type"), MEDIA_TYPE_OCI_MANIFEST)
    r.with_header(String("docker-content-digest"), digest^)
    r.with_body(body^)
    return r^


def _status(code: Int) -> OciResponse:
    return OciResponse(code)


def _created_with_digest(var digest: String) -> OciResponse:
    var r = OciResponse(201)
    r.with_header(String("docker-content-digest"), digest^)
    return r^


# A pair of plausible blob digests. Their VALUES never have to match real
# content in this file because every blob is scripted as already-present (HEAD
# 200) — the blob-transfer path is falsified in
# test_oci_copy_index_and_mount.mojo, where the bytes ARE checked.
comptime _CONFIG_DIGEST: String = "sha256:" + "11" * 32
comptime _LAYER_DIGEST: String = "sha256:" + "22" * 32


def test_cross_project_copy_preserves_digest() raises:
    var manifest = _image_manifest(_CONFIG_DIGEST, _LAYER_DIGEST)
    var mbytes = _bytes(manifest)
    # The expected digest is derived FROM THE BYTES, so this test cannot pass by
    # agreeing with a hard-coded constant that the implementation also hard-codes.
    var mdigest = digest_of_bytes(Span(mbytes))

    var t = ScriptedOciTransport()
    t.queue(_ok_manifest(mbytes.copy(), mdigest.copy()))  # 0: GET manifest (src)
    t.queue(_status(200))  # 1: HEAD config blob (dst) — present
    t.queue(_status(200))  # 2: HEAD layer blob  (dst) — present
    t.queue(_created_with_digest(mdigest.copy()))  # 3: PUT manifest (dst)

    var src_ref = _HOST + String("/") + _SRC_REPO + String("@") + mdigest
    var dst_ref = _HOST + String("/") + _DST_REPO + String("@") + mdigest

    var copier = OciCopier[ScriptedOciTransport](
        t^, _SRC_TOKEN, _DST_TOKEN
    )
    var confirmed = copier.copy_by_digest(src_ref, dst_ref)

    # --- THE PRESERVED DIGEST -------------------------------------------------
    assert_equal(
        confirmed,
        mdigest,
        "the staged digest MUST equal the source digest (this is what `stage`"
        " means)",
    )

    # --- and the conversation that produced it -------------------------------
    ref log = copier.transport()
    assert_equal(log.call_count(), 4, "GET manifest, HEAD x2, PUT manifest")

    # (0) read the manifest FROM THE SOURCE repository, with the SOURCE bearer.
    assert_equal(log.call_method(0), HTTP_METHOD_GET, "call 0 is a GET")
    assert_equal(log.call_registry(0), _HOST, "call 0 hits the source host")
    assert_equal(
        log.call_path(0),
        String("/v2/") + _SRC_REPO + String("/manifests/") + mdigest,
        "call 0 reads the SOURCE repository by digest",
    )
    assert_equal(
        log.call_auth(0),
        String("Bearer ") + _SRC_TOKEN,
        "the SOURCE leg carries the SOURCE project's bearer",
    )

    # (1)(2) blob presence probed against the DESTINATION, with the DEST bearer.
    assert_equal(log.call_method(1), HTTP_METHOD_HEAD, "call 1 is a HEAD")
    assert_equal(
        log.call_path(1),
        String("/v2/") + _DST_REPO + String("/blobs/") + _CONFIG_DIGEST,
        "the config blob is probed in the DESTINATION repository",
    )
    assert_equal(
        log.call_path(2),
        String("/v2/") + _DST_REPO + String("/blobs/") + _LAYER_DIGEST,
        "the layer blob is probed in the DESTINATION repository",
    )
    assert_equal(
        log.call_auth(2),
        String("Bearer ") + _DST_TOKEN,
        "the DESTINATION leg carries the DESTINATION project's bearer",
    )

    # (3) the manifest is written to the DESTINATION, BY DIGEST, VERBATIM.
    assert_equal(log.call_method(3), HTTP_METHOD_PUT, "call 3 is a PUT")
    assert_equal(
        log.call_path(3),
        String("/v2/") + _DST_REPO + String("/manifests/") + mdigest,
        "the manifest is PUT to the DESTINATION repository under the SAME digest",
    )
    # VERBATIM is the load-bearing bit: re-serialized JSON would be equivalent
    # but would hash differently, silently breaking every by-digest reference.
    var pushed = log.call_body(3)
    assert_equal(
        digest_of_bytes(Span(pushed)),
        mdigest,
        "the bytes PUT to the destination re-hash to the source digest — the"
        " manifest was forwarded byte-for-byte, not re-serialized",
    )
    print("  test_cross_project_copy_preserves_digest: PASS")


def test_manifest_digest_mismatch_refuses() raises:
    # The registry serves bytes for a DIFFERENT manifest than the digest asked
    # for, and asserts the requested digest in its own header. Believing the
    # header is precisely the failure this row exists to prevent.
    var honest = _image_manifest(_CONFIG_DIGEST, _LAYER_DIGEST)
    var tampered = _image_manifest(_CONFIG_DIGEST, String("sha256:") + "33" * 32)
    var requested = digest_of_bytes(Span(_bytes(honest)))
    var served = _bytes(tampered)

    var t = ScriptedOciTransport()
    t.queue(_ok_manifest(served^, requested.copy()))

    var src_ref = _HOST + String("/") + _SRC_REPO + String("@") + requested
    var dst_ref = _HOST + String("/") + _DST_REPO + String("@") + requested

    var copier = OciCopier[ScriptedOciTransport](t^, _SRC_TOKEN, _DST_TOKEN)
    var raised = False
    try:
        var _ignored = copier.copy_by_digest(src_ref, dst_ref)
    except e:
        raised = True
        assert_true(
            String(e).find(String("DIGEST MISMATCH")) >= 0,
            "the refusal must name the content-address violation, got: "
            + String(e),
        )
    assert_true(
        raised,
        "a manifest whose bytes do not match its digest MUST be refused, never"
        " recorded as a deployable ref",
    )
    # And nothing was written: the only call made was the source GET.
    ref log = copier.transport()
    assert_equal(
        log.call_count(),
        1,
        "the copy must abort on the failed content-address check — no blob"
        " probe, no manifest PUT",
    )
    print("  test_manifest_digest_mismatch_refuses: PASS")


def test_by_tag_source_refuses() raises:
    var t = ScriptedOciTransport()
    var copier = OciCopier[ScriptedOciTransport](t^, _SRC_TOKEN, _DST_TOKEN)
    var raised = False
    try:
        var _ignored = copier.copy_by_digest(
            _HOST + String("/") + _SRC_REPO + String(":latest"),
            _HOST + String("/") + _DST_REPO + String(":latest"),
        )
    except e:
        raised = True
        assert_true(
            String(e).find(String("by-TAG")) >= 0,
            "the refusal must name the by-tag source, got: " + String(e),
        )
    assert_true(raised, "a by-TAG source is not a content-addressed copy")
    assert_equal(
        copier.transport().call_count(), 0, "refused before any network call"
    )
    print("  test_by_tag_source_refuses: PASS")


def test_docker_content_digest_disagreement_refuses() raises:
    var manifest = _image_manifest(_CONFIG_DIGEST, _LAYER_DIGEST)
    var mbytes = _bytes(manifest)
    var mdigest = digest_of_bytes(Span(mbytes))
    var other = String("sha256:") + "44" * 32

    var t = ScriptedOciTransport()
    t.queue(_ok_manifest(mbytes.copy(), mdigest.copy()))
    t.queue(_status(200))
    t.queue(_status(200))
    # The destination claims it stored something else.
    t.queue(_created_with_digest(other.copy()))

    var src_ref = _HOST + String("/") + _SRC_REPO + String("@") + mdigest
    var dst_ref = _HOST + String("/") + _DST_REPO + String("@") + mdigest

    var copier = OciCopier[ScriptedOciTransport](t^, _SRC_TOKEN, _DST_TOKEN)
    var raised = False
    try:
        var _ignored = copier.copy_by_digest(src_ref, dst_ref)
    except e:
        raised = True
        assert_true(
            String(e).find(String("DIFFERENT digest")) >= 0,
            "the refusal must name the destination's disagreement, got: "
            + String(e),
        )
    assert_true(
        raised,
        "a destination that stores the manifest under another digest has not"
        " preserved the content-address, and the copy must fail",
    )
    print("  test_docker_content_digest_disagreement_refuses: PASS")


def main() raises:
    test_cross_project_copy_preserves_digest()
    test_manifest_digest_mismatch_refuses()
    test_by_tag_source_refuses()
    test_docker_content_digest_disagreement_refuses()
    print("test_oci_copy_digest_preserved: ALL PASS")
