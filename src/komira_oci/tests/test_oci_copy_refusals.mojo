# =============================================================================
# test_oci_copy_refusals.mojo — OciCopier's refusals and its less-travelled
#   paths, each driven through `copy_by_digest` over a scripted conversation.
# =============================================================================
#
#   (1) a destination pinning a DIFFERENT digest is refused before any call;
#   (2) a manifest GET answered with a non-200 raises with the status and a
#       body excerpt cut at 400 bytes;
#   (3) an index naming the same child twice fetches that child ONCE;
#   (4) a manifest served with no Content-Type is PUT as an OCI image manifest;
#   (5) an index with no `manifests` key has no children (the walk ends);
#   (6) a redirected manifest GET carries `accept` to the next hop and drops
#       the bearer on another host;
#   (7) each redirect refusal (no Location, no path, empty host, unresolvable)
#       raises with its own words;
#   (8) the blob mount: 201 transfers nothing; 404 and 405 open an upload
#       session; any other status raises;
#   (9) across two registries no mount is tried, and an upload session that
#       does not open (non-202) raises;
#  (10) a blob PUT other than 201, and a manifest PUT other than 200/201,
#       raise; a manifest PUT with no Docker-Content-Digest confirms the digest
#       that was PUT.
#
# Hermetic: ScriptedOciTransport (and a recording wrapper around it), no
# network, no sockets.
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
from komira_oci.oci_ref import (
    MEDIA_TYPE_OCI_INDEX,
    MEDIA_TYPE_OCI_MANIFEST,
    manifest_accept_header,
)
from komira_oci.oci_transport import (
    OciRequest,
    OciResponse,
    OciTransport,
    ScriptedOciTransport,
)


comptime _HOST: String = "europe-docker.pkg.dev"
comptime _OTHER: String = "us-docker.pkg.dev"
comptime _CDN: String = "storage.example-cdn.net"
comptime _SRC_REPO: String = "example-build/images/worker"
comptime _DST_REPO: String = "example-release/images/worker"


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
        + String('","config":{"mediaType":"application/vnd.oci.image.config.v1+json","size":37,"digest":"')
        + config_digest
        + String('"},"layers":[{"mediaType":"application/vnd.oci.image.layer.v1.tar+gzip","size":19,"digest":"')
        + layer_digest
        + String('"}]}')
    )


def _served(var body: List[UInt8], media: String) -> OciResponse:
    var r = OciResponse(200)
    if media.byte_length() > 0:
        r.with_header(String("content-type"), media.copy())
    r.with_body(body^)
    return r^


def _status(code: Int) -> OciResponse:
    return OciResponse(code)


def _with_body(code: Int, body: String) -> OciResponse:
    var r = OciResponse(code)
    r.with_body(_bytes(body))
    return r^


def _created(var digest: String) -> OciResponse:
    var r = OciResponse(201)
    r.with_header(String("docker-content-digest"), digest^)
    return r^


def _located(code: Int, var location: String) -> OciResponse:
    var r = OciResponse(code)
    r.with_header(String("location"), location^)
    return r^


struct _Image(Copyable, Movable, Deinitable):
    """A one-layer image whose config and layer are REAL bytes, so a blob GET
    that serves them passes the content-address check."""

    var config: List[UInt8]
    var config_digest: String
    var layer: List[UInt8]
    var layer_digest: String
    var manifest: List[UInt8]
    var digest: String

    def __init__(out self):
        self.config = _bytes(String('{"architecture":"amd64","os":"linux"}'))
        self.config_digest = digest_of_bytes(Span(self.config))
        self.layer = _bytes(String("layer-bytes-0123456"))
        self.layer_digest = digest_of_bytes(Span(self.layer))
        self.manifest = _bytes(_manifest(self.config_digest, self.layer_digest))
        self.digest = digest_of_bytes(Span(self.manifest))

    def copy(self) -> Self:
        return _Image()

    def src(self, host: String = _HOST) -> String:
        return host + String("/") + _SRC_REPO + String("@") + self.digest

    def dst(self, host: String = _HOST) -> String:
        return host + String("/") + _DST_REPO + String("@") + self.digest


struct _HeaderLog(OciTransport, Movable, Deinitable):
    """ScriptedOciTransport plus a record of the `accept` and `content-type`
    header each call carried (the scripted double records only the
    credential)."""

    var inner: ScriptedOciTransport
    var accepts: List[String]
    var content_types: List[String]

    def __init__(out self, var inner: ScriptedOciTransport):
        self.inner = inner^
        self.accepts = List[String]()
        self.content_types = List[String]()

    def send(mut self, var request: OciRequest) raises -> OciResponse:
        self.accepts.append(request.header_value(String("accept")))
        self.content_types.append(request.header_value(String("content-type")))
        return self.inner.send(request^)


def _copier(var t: ScriptedOciTransport) -> OciCopier[ScriptedOciTransport]:
    return OciCopier[ScriptedOciTransport](
        t^, String("src-tok"), String("dst-tok")
    )


def _copy_refused(
    mut copier: OciCopier[ScriptedOciTransport],
    src: String,
    dst: String,
    needle: String,
    why: String,
) raises:
    var raised = False
    try:
        _ = copier.copy_by_digest(src, dst)
    except e:
        raised = True
        assert_true(
            String(e).find(needle) >= 0,
            why + String(": expected '") + needle + String("' in: ") + String(e),
        )
    assert_true(raised, why + String(": must raise"))


# =============================================================================
# (1) a destination pinning another digest
# =============================================================================


def test_destination_pinning_another_digest_is_refused_before_any_call() raises:
    var img = _Image()
    var other = String("sha256:") + "ab" * 32
    var copier = _copier(ScriptedOciTransport())
    _copy_refused(
        copier,
        img.src(),
        _HOST + String("/") + _DST_REPO + String("@") + other,
        String("a digest-preserving copy cannot change the digest"),
        String("a destination pinning another digest"),
    )
    assert_equal(copier.transport().call_count(), 0, "refused before any call")
    print("  test_destination_pinning_another_digest_is_refused_before_any_call: PASS")


# =============================================================================
# (2) a manifest GET that fails, and the body excerpt
# =============================================================================


def test_manifest_get_non_200_raises_with_status_and_body_excerpt() raises:
    var img = _Image()
    var t = ScriptedOciTransport()
    t.queue(_with_body(404, String('{"errors":[{"code":"MANIFEST_UNKNOWN"}]}')))
    var copier = _copier(t^)
    _copy_refused(
        copier,
        img.src(),
        img.dst(),
        String("returned HTTP 404 — {\"errors\":[{\"code\":\"MANIFEST_UNKNOWN\"}]}"),
        String("a manifest GET answered 404"),
    )

    # A body longer than 400 bytes is cut at exactly 400. The body is 401
    # bytes: 399 `x`, the marker `Y` as byte 400, and the sentinel `Z` as byte
    # 401. The excerpt is the last thing in the message, so the message must
    # end with ` — ` and the first 400 bytes: a cut at 399 drops `Y`, a cut at
    # 401 or later keeps `Z`, and either breaks the `endswith` below.
    var first_400 = String("x") * 399 + String("Y")
    var long_body = first_400 + String("Z")
    var t2 = ScriptedOciTransport()
    t2.queue(_with_body(500, long_body))
    var copier2 = _copier(t2^)
    var raised = False
    try:
        _ = copier2.copy_by_digest(img.src(), img.dst())
    except e:
        raised = True
        var msg = String(e)
        assert_true(msg.find(String("returned HTTP 500 — ")) >= 0, msg)
        assert_true(
            msg.endswith(String(" — ") + first_400),
            "the message ends with exactly the first 400 bytes: " + msg,
        )
        assert_true(
            msg.find(first_400 + String("Z")) < 0,
            "byte 401 (the sentinel) is cut: " + msg,
        )
    assert_true(raised, "a manifest GET answered 500 must raise")
    print("  test_manifest_get_non_200_raises_with_status_and_body_excerpt: PASS")


# =============================================================================
# (3) an index naming one child twice
# =============================================================================


def test_index_naming_a_child_twice_fetches_it_once() raises:
    var img = _Image()
    var index = _bytes(
        String('{"schemaVersion":2,"mediaType":"')
        + MEDIA_TYPE_OCI_INDEX
        + String('","manifests":[{"digest":"')
        + img.digest
        + String('"},{"digest":"')
        + img.digest
        + String('"}]}')
    )
    var index_digest = digest_of_bytes(Span(index))
    var t = ScriptedOciTransport()
    t.queue(_served(index.copy(), MEDIA_TYPE_OCI_INDEX))
    t.queue(_served(img.manifest.copy(), MEDIA_TYPE_OCI_MANIFEST))
    t.queue(_status(200))  # HEAD config: present
    t.queue(_status(200))  # HEAD layer: present
    t.queue(_created(img.digest.copy()))
    t.queue(_created(index_digest.copy()))
    var copier = _copier(t^)
    var src = _HOST + String("/") + _SRC_REPO + String("@") + index_digest
    var dst = _HOST + String("/") + _DST_REPO + String("@") + index_digest
    assert_equal(copier.copy_by_digest(src, dst), index_digest)
    ref log = copier.transport()
    assert_equal(log.call_count(), 6, "GET index, GET child ONCE, 2 HEAD, 2 PUT")
    var child_gets = 0
    for i in range(log.call_count()):
        if log.call_method(i) == HTTP_METHOD_GET and log.call_path(i).find(img.digest) >= 0:
            child_gets += 1
    assert_equal(child_gets, 1, "the shared child is fetched once")
    print("  test_index_naming_a_child_twice_fetches_it_once: PASS")


# =============================================================================
# (4) no Content-Type on the manifest GET
# =============================================================================


def test_manifest_without_content_type_is_put_as_an_oci_manifest() raises:
    var img = _Image()
    var t = ScriptedOciTransport()
    t.queue(_served(img.manifest.copy(), String("")))  # no content-type
    t.queue(_status(200))
    t.queue(_status(200))
    t.queue(_created(img.digest.copy()))
    var copier = OciCopier[_HeaderLog](
        _HeaderLog(t^), String("src-tok"), String("dst-tok")
    )
    assert_equal(copier.copy_by_digest(img.src(), img.dst()), img.digest)
    ref log = copier.transport()
    assert_equal(len(log.content_types), 4)
    assert_equal(log.inner.call_method(3), HTTP_METHOD_PUT)
    assert_equal(
        log.content_types[3],
        String(MEDIA_TYPE_OCI_MANIFEST),
        "the PUT declares the OCI image manifest type when the source named none",
    )
    print("  test_manifest_without_content_type_is_put_as_an_oci_manifest: PASS")


# =============================================================================
# (5) an index with no `manifests` key
# =============================================================================


def test_index_without_manifests_key_has_no_children() raises:
    var index = _bytes(String('{"schemaVersion":2}'))
    var index_digest = digest_of_bytes(Span(index))
    var t = ScriptedOciTransport()
    t.queue(_served(index.copy(), MEDIA_TYPE_OCI_INDEX))
    t.queue(_created(index_digest.copy()))
    var copier = _copier(t^)
    var src = _HOST + String("/") + _SRC_REPO + String("@") + index_digest
    var dst = _HOST + String("/") + _DST_REPO + String("@") + index_digest
    assert_equal(copier.copy_by_digest(src, dst), index_digest)
    assert_equal(copier.transport().call_count(), 2, "GET the index, PUT it")
    assert_equal(copier.transport().call_method(1), HTTP_METHOD_PUT)
    print("  test_index_without_manifests_key_has_no_children: PASS")


# =============================================================================
# (6) a redirected manifest GET
# =============================================================================


def test_redirected_manifest_get_carries_accept_and_drops_bearer_off_host() raises:
    var img = _Image()
    var t = ScriptedOciTransport()
    t.queue(_located(307, String("https://") + _CDN + String("/m/") + img.digest))
    t.queue(_served(img.manifest.copy(), MEDIA_TYPE_OCI_MANIFEST))
    t.queue(_status(200))
    t.queue(_status(200))
    t.queue(_created(img.digest.copy()))
    var copier = OciCopier[_HeaderLog](
        _HeaderLog(t^), String("src-tok"), String("dst-tok")
    )
    assert_equal(copier.copy_by_digest(img.src(), img.dst()), img.digest)
    ref log = copier.transport()
    assert_equal(log.inner.call_registry(1), String(_CDN), "the hop went to the CDN")
    assert_equal(
        log.accepts[1],
        manifest_accept_header(),
        "`accept` selects index-vs-manifest, so it is carried to the hop",
    )
    assert_equal(log.inner.call_auth(0), String("Bearer src-tok"))
    assert_equal(
        log.inner.call_auth(1), String(""), "the bearer never reaches another host"
    )
    print("  test_redirected_manifest_get_carries_accept_and_drops_bearer_off_host: PASS")


# =============================================================================
# (7) each redirect refusal
# =============================================================================


def _redirect_refused(var answer: OciResponse, needle: String, why: String) raises:
    var img = _Image()
    var t = ScriptedOciTransport()
    t.queue(answer^)
    var copier = _copier(t^)
    _copy_refused(copier, img.src(), img.dst(), needle, why)
    assert_equal(copier.transport().call_count(), 1, why + ": nothing followed")


def test_each_redirect_refusal_raises_with_its_own_words() raises:
    _redirect_refused(
        _status(302),
        String("answered a redirect with NO Location header"),
        String("a 302 with no Location"),
    )
    _redirect_refused(
        _located(302, String("https://") + _CDN),
        String("names a host but no path"),
        String("a Location with no path"),
    )
    _redirect_refused(
        _located(302, String("https:///blobs/x")),
        String("has an EMPTY host"),
        String("a Location with an empty host"),
    )
    _redirect_refused(
        _located(302, String("downloads/relative")),
        String("cannot resolve the redirect Location 'downloads/relative'"),
        String("a path-relative Location"),
    )
    print("  test_each_redirect_refusal_raises_with_its_own_words: PASS")


# =============================================================================
# (8) the blob mount
# =============================================================================


def test_mount_created_transfers_nothing() raises:
    var img = _Image()
    var t = ScriptedOciTransport()
    t.queue(_served(img.manifest.copy(), MEDIA_TYPE_OCI_MANIFEST))
    t.queue(_status(404))  # HEAD config
    t.queue(_status(201))  # mount config: linked
    t.queue(_status(404))  # HEAD layer
    t.queue(_status(201))  # mount layer: linked
    t.queue(_created(img.digest.copy()))
    var copier = _copier(t^)
    assert_equal(copier.copy_by_digest(img.src(), img.dst()), img.digest)
    ref log = copier.transport()
    assert_equal(log.call_count(), 6, "GET, (HEAD, mount) x2, PUT manifest")
    assert_equal(log.call_method(2), HTTP_METHOD_POST)
    assert_true(log.call_path(2).find(String("?mount=") + img.config_digest) >= 0)
    for i in range(log.call_count()):
        assert_true(
            log.call_path(i).find(String("/blobs/sha256:")) < 0
            or log.call_method(i) != HTTP_METHOD_GET,
            "a mounted blob is never fetched",
        )
    print("  test_mount_created_transfers_nothing: PASS")


def test_mount_404_and_405_open_an_upload_session() raises:
    var img = _Image()
    var session = String("/v2/") + _DST_REPO + String("/blobs/uploads/s1")
    var t = ScriptedOciTransport()
    t.queue(_served(img.manifest.copy(), MEDIA_TYPE_OCI_MANIFEST))
    t.queue(_status(404))  # 1 HEAD config
    t.queue(_status(404))  # 2 mount config: not supported here
    t.queue(_located(202, session.copy()))  # 3 POST open session
    t.queue(_served(img.config.copy(), String("")))  # 4 GET config
    t.queue(_status(201))  # 5 PUT config
    t.queue(_status(404))  # 6 HEAD layer
    t.queue(_status(405))  # 7 mount layer: method not allowed
    t.queue(_located(202, session.copy()))  # 8 POST open session
    t.queue(_served(img.layer.copy(), String("")))  # 9 GET layer
    t.queue(_status(201))  # 10 PUT layer
    t.queue(_created(img.digest.copy()))  # 11 PUT manifest
    var copier = _copier(t^)
    assert_equal(copier.copy_by_digest(img.src(), img.dst()), img.digest)
    ref log = copier.transport()
    assert_equal(log.call_count(), 12)
    var opens = List[Int]()
    opens.append(3)
    opens.append(8)
    for k in range(len(opens)):
        var i = opens[k]
        assert_equal(log.call_method(i), HTTP_METHOD_POST)
        assert_equal(
            log.call_path(i),
            String("/v2/") + _DST_REPO + String("/blobs/uploads/"),
            "a declined mount opens a plain upload session",
        )
    assert_equal(
        log.call_path(5), session + String("?digest=") + img.config_digest
    )
    assert_equal(log.call_auth(3), String("Bearer dst-tok"))
    print("  test_mount_404_and_405_open_an_upload_session: PASS")


def test_mount_answering_another_status_raises() raises:
    var img = _Image()
    var t = ScriptedOciTransport()
    t.queue(_served(img.manifest.copy(), MEDIA_TYPE_OCI_MANIFEST))
    t.queue(_status(404))
    t.queue(_with_body(500, String("backend unavailable")))
    var copier = _copier(t^)
    _copy_refused(
        copier,
        img.src(),
        img.dst(),
        String("blob mount of ")
        + img.config_digest
        + String(" into ")
        + _DST_REPO
        + String(" returned HTTP 500 — backend unavailable"),
        String("a mount answered 500"),
    )
    print("  test_mount_answering_another_status_raises: PASS")


# =============================================================================
# (9) two registries
# =============================================================================


def test_cross_registry_copy_skips_the_mount() raises:
    var img = _Image()
    var session = String("/v2/") + _DST_REPO + String("/blobs/uploads/s9")
    var t = ScriptedOciTransport()
    t.queue(_served(img.manifest.copy(), MEDIA_TYPE_OCI_MANIFEST))
    t.queue(_status(404))  # 1 HEAD config at the destination
    t.queue(_located(202, session.copy()))  # 2 POST open session (no mount)
    t.queue(_served(img.config.copy(), String("")))  # 3 GET config
    t.queue(_status(201))  # 4 PUT config
    t.queue(_status(200))  # 5 HEAD layer: present
    t.queue(_created(img.digest.copy()))  # 6 PUT manifest
    var copier = _copier(t^)
    assert_equal(copier.copy_by_digest(img.src(), img.dst(_OTHER)), img.digest)
    ref log = copier.transport()
    assert_equal(log.call_count(), 7)
    for i in range(log.call_count()):
        assert_true(
            log.call_path(i).find(String("mount=")) < 0,
            "no mount is tried across registries",
        )
    assert_equal(log.call_registry(2), String(_OTHER))
    assert_equal(log.call_registry(3), String(_HOST), "the blob is read from the source")
    assert_equal(log.call_registry(4), String(_OTHER))
    print("  test_cross_registry_copy_skips_the_mount: PASS")


def test_upload_session_that_does_not_open_raises() raises:
    var img = _Image()
    var t = ScriptedOciTransport()
    t.queue(_served(img.manifest.copy(), MEDIA_TYPE_OCI_MANIFEST))
    t.queue(_status(404))
    t.queue(_with_body(403, String("denied")))
    var copier = _copier(t^)
    _copy_refused(
        copier,
        img.src(),
        img.dst(_OTHER),
        String("opening a blob upload session in ")
        + _DST_REPO
        + String(" returned HTTP 403 (expected 202) — denied"),
        String("a session answered 403"),
    )
    print("  test_upload_session_that_does_not_open_raises: PASS")


# =============================================================================
# (10) the PUTs
# =============================================================================


def test_blob_put_other_than_201_raises() raises:
    var img = _Image()
    var t = ScriptedOciTransport()
    t.queue(_served(img.manifest.copy(), MEDIA_TYPE_OCI_MANIFEST))
    t.queue(_status(404))
    t.queue(_located(202, String("/v2/") + _DST_REPO + String("/blobs/uploads/s2")))
    t.queue(_served(img.config.copy(), String("")))
    t.queue(_status(202))  # the PUT answered 202, not 201
    var copier = _copier(t^)
    _copy_refused(
        copier,
        img.src(),
        img.dst(_OTHER),
        String("PUT blob ")
        + img.config_digest
        + String(" to ")
        + _DST_REPO
        + String(" returned HTTP 202 (expected 201 Created)"),
        String("a blob PUT answered 202"),
    )
    print("  test_blob_put_other_than_201_raises: PASS")


def test_manifest_put_other_than_200_or_201_raises() raises:
    var img = _Image()
    var t = ScriptedOciTransport()
    t.queue(_served(img.manifest.copy(), MEDIA_TYPE_OCI_MANIFEST))
    t.queue(_status(200))
    t.queue(_status(200))
    t.queue(_with_body(400, String("MANIFEST_INVALID")))
    var copier = _copier(t^)
    _copy_refused(
        copier,
        img.src(),
        img.dst(),
        String("PUT manifest ")
        + img.digest
        + String(" to ")
        + _HOST
        + String("/")
        + _DST_REPO
        + String(" returned HTTP 400 — MANIFEST_INVALID"),
        String("a manifest PUT answered 400"),
    )
    print("  test_manifest_put_other_than_200_or_201_raises: PASS")


def test_manifest_put_200_without_digest_header_confirms_the_put_digest() raises:
    var img = _Image()
    var t = ScriptedOciTransport()
    t.queue(_served(img.manifest.copy(), MEDIA_TYPE_OCI_MANIFEST))
    t.queue(_status(200))
    t.queue(_status(200))
    t.queue(_status(200))  # PUT manifest: 200, no Docker-Content-Digest
    var copier = _copier(t^)
    assert_equal(
        copier.copy_by_digest(img.src(), img.dst()),
        img.digest,
        "with no registry assertion the confirmed digest is the one PUT",
    )
    print("  test_manifest_put_200_without_digest_header_confirms_the_put_digest: PASS")


def main() raises:
    test_destination_pinning_another_digest_is_refused_before_any_call()
    test_manifest_get_non_200_raises_with_status_and_body_excerpt()
    test_index_naming_a_child_twice_fetches_it_once()
    test_manifest_without_content_type_is_put_as_an_oci_manifest()
    test_index_without_manifests_key_has_no_children()
    test_redirected_manifest_get_carries_accept_and_drops_bearer_off_host()
    test_each_redirect_refusal_raises_with_its_own_words()
    test_mount_created_transfers_nothing()
    test_mount_404_and_405_open_an_upload_session()
    test_mount_answering_another_status_raises()
    test_cross_registry_copy_skips_the_mount()
    test_upload_session_that_does_not_open_raises()
    test_blob_put_other_than_201_raises()
    test_manifest_put_other_than_200_or_201_raises()
    test_manifest_put_200_without_digest_header_confirms_the_put_digest()
    print("test_oci_copy_refusals: ALL PASS")
