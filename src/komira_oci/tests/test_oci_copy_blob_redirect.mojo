# =============================================================================
# test_oci_copy_blob_redirect.mojo — the falsifier for a blob GET that is
#   answered with a redirect.
# =============================================================================
#
# ★ THE SHAPE THIS PINS. A registry may answer a blob GET with a 3xx instead of
#   the bytes. Artifact Registry answers EVERY blob GET with a 302 whose
#   `location` is a RELATIVE path on the SAME host
#   (`/artifacts-downloads/namespaces/…/downloads/<single-use-token>`), and the
#   second hop returns the bytes. A copier with no redirect handling fails such
#   a copy deterministically with "returned HTTP 302".
#
# ★ WHY IT IS EASY TO MISS. The blob GET is the copier's THIRD move, reached
#   only when the destination HEAD misses AND the cross-repo mount misses. A
#   copy into a destination repository that already exists short-circuits
#   before it; the first copy into a NEW destination repository reaches it.
#
#   That is why row (1) drives the WHOLE mount-declined path rather than calling
#   a redirect helper directly: a unit test of the resolver would pass against
#   a copier that never calls one.
#
# THE FIVE ROWS
#   (1) a 302 on the blob GET is FOLLOWED, and the bytes that come back are the
#       ones that get uploaded — the row a copier without redirect handling
#       fails;
#   (2) the bearer is NOT forwarded off-host, and IS re-attached on a same-host
#       hop (Artifact Registry's shape). A leaked registry token is the
#       standard way redirect following is written wrongly;
#   (3) an A -> B -> B chain does not walk the token onto B — the reason the
#       host comparison is against the ORIGINAL request and not the previous
#       hop;
#   (4) a redirect LOOP is bounded rather than followed forever;
#   (5) a plaintext `http://` redirect is REFUSED, not silently upgraded.
#
# Blob bytes are REAL and their digests are computed with the same function the
# copier uses, so following the redirect is only "correct" if it produces bytes
# that actually hash to the descriptor.
#
# Hermetic: ScriptedOciTransport, NO network, NO sockets.
# =============================================================================

from std.testing import assert_equal, assert_true, assert_raises

from komira_http_core.codec.types import (
    HTTP_METHOD_GET,
    HTTP_METHOD_PUT,
)

from komira_oci.oci_copy import OciCopier
from komira_oci.oci_digest import digest_of_bytes
from komira_oci.oci_ref import MEDIA_TYPE_OCI_MANIFEST
from komira_oci.oci_transport import OciResponse, ScriptedOciTransport


comptime _HOST: String = "europe-docker.pkg.dev"
comptime _CDN: String = "storage.example-cdn.net"
comptime _SRC_REPO: String = "example-build/images/worker"
comptime _DST_REPO: String = "example-release/images/worker"

# Artifact Registry's shape: a relative path on the same host with a single-use
# token in it.
comptime _AR_DOWNLOAD: String = (
    "/artifacts-downloads/namespaces/example-build/repositories/images/downloads/"
    "Q7xTmLkPzRvNbWsJ"
)


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
        + String(
            '","config":{"mediaType":"application/vnd.oci.image.config.v1+json","size":42,"digest":"'
        )
        + config_digest
        + String(
            '"},"layers":[{"mediaType":"application/vnd.oci.image.layer.v1.tar+gzip","size":9,"digest":"'
        )
        + layer_digest
        + String('"}]}')
    )


def _served(
    var body: List[UInt8], var digest: String, media: String
) -> OciResponse:
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
    var r = OciResponse(202)
    r.with_header(String("location"), location^)
    return r^


def _redirect(code: Int, var location: String) -> OciResponse:
    var r = OciResponse(code)
    r.with_header(String("location"), location^)
    # A real 302 carries a tiny HTML body. Queue it, so a copier that returned
    # the redirect's own body instead of following would upload THIS and fail
    # its content-address check for the right reason.
    r.with_body(_bytes(String('<a href="…">Found</a>.')))
    return r^


def _blob_ok(var body: List[UInt8]) -> OciResponse:
    var r = OciResponse(200)
    r.with_body(body^)
    return r^


# =============================================================================
# The shared fixture: a one-layer image whose CONFIG blob is absent at the
# destination and whose mount is declined — i.e. the exact path that reaches the
# blob GET, which is the only path that reaches a redirect.
# =============================================================================


struct _Fixture(Copyable, Movable, Deinitable):
    var config_bytes: List[UInt8]
    var config_digest: String
    var layer_digest: String
    var manifest_bytes: List[UInt8]
    var manifest_digest: String
    var session: String

    def __init__(out self):
        self.config_bytes = _bytes(
            String('{"architecture":"amd64","os":"linux"}')
        )
        self.config_digest = digest_of_bytes(Span(self.config_bytes))
        self.layer_digest = String("sha256:") + "cc" * 32
        self.manifest_bytes = _bytes(
            _manifest(self.config_digest, self.layer_digest)
        )
        self.manifest_digest = digest_of_bytes(Span(self.manifest_bytes))
        self.session = String("/v2/") + _DST_REPO + String(
            "/blobs/uploads/9f0c1b?_state=abc"
        )

    def copy(self) -> Self:
        return _Fixture()

    def src_ref(self) -> String:
        return _HOST + String("/") + _SRC_REPO + String("@") + self.manifest_digest

    def dst_ref(self) -> String:
        return _HOST + String("/") + _DST_REPO + String("@") + self.manifest_digest

    def queue_up_to_blob_get(self, mut t: ScriptedOciTransport) raises:
        """Calls 0-2: manifest GET, config HEAD (absent), mount (declined).
        The NEXT queued response is what the blob GET receives."""
        t.queue(
            _served(
                self.manifest_bytes.copy(),
                self.manifest_digest.copy(),
                MEDIA_TYPE_OCI_MANIFEST,
            )
        )
        t.queue(_status(404))
        t.queue(_upload_session(self.session.copy()))

    def queue_tail(self, mut t: ScriptedOciTransport) raises:
        """The PUT of the transferred blob, the layer HEAD (present) and the
        manifest PUT."""
        t.queue(_status(201))
        t.queue(_status(200))
        t.queue(_created(self.manifest_digest.copy()))


# =============================================================================
# (1) A 302 is followed, and the bytes from the SECOND hop are the ones that
#     get uploaded.
# =============================================================================


def test_blob_get_follows_redirect_and_uploads_the_redirected_bytes() raises:
    var f = _Fixture()
    var t = ScriptedOciTransport()
    f.queue_up_to_blob_get(t)
    t.queue(_redirect(302, String(_AR_DOWNLOAD)))  # 3 GET blob -> 302
    t.queue(_blob_ok(f.config_bytes.copy()))  # 4 the follow -> the bytes
    f.queue_tail(t)  # 5 PUT blob, 6 HEAD layer, 7 PUT manifest

    var copier = OciCopier[ScriptedOciTransport](
        t^, String("src-tok"), String("dst-tok")
    )
    # A copier that does not follow redirects RAISES "returned HTTP 302" here.
    var confirmed = copier.copy_by_digest(f.src_ref(), f.dst_ref())
    assert_equal(
        confirmed,
        f.manifest_digest,
        "the digest survives a blob that had to be fetched through a redirect",
    )

    ref log = copier.transport()
    assert_equal(
        log.call_count(),
        8,
        "GET manifest, HEAD, mount, GET blob(302), GET follow, PUT blob, HEAD"
        " layer, PUT manifest",
    )

    # --- the follow went to the LOCATION, on the SAME host --------------------
    assert_equal(log.call_method(4), HTTP_METHOD_GET, "the follow is a GET")
    assert_equal(
        log.call_path(4),
        String(_AR_DOWNLOAD),
        "the follow goes to the path the `location` header named",
    )
    assert_equal(
        log.call_registry(4),
        _HOST,
        "a RELATIVE location resolves against the host that issued it",
    )

    # --- THE UPLOADED BYTES ARE THE REDIRECTED ONES --------------------------
    # A copier that uploaded the 302's own HTML body would fail its digest check
    # before reaching here; this asserts the positive.
    assert_equal(log.call_method(5), HTTP_METHOD_PUT, "call 5 uploads the blob")
    var uploaded = log.call_body(5)
    assert_equal(
        len(uploaded),
        len(f.config_bytes),
        "the bytes PUT are the ones the SECOND hop served, not the redirect"
        " body",
    )
    assert_equal(
        digest_of_bytes(Span(uploaded)),
        f.config_digest,
        "and they hash to the descriptor — following a redirect never bypasses"
        " the content-address check",
    )
    print(
        "  test_blob_get_follows_redirect_and_uploads_the_redirected_bytes:"
        " PASS"
    )


# =============================================================================
# (2) THE CREDENTIAL ROW — the bearer does not leave its host.
# =============================================================================


def test_bearer_is_not_forwarded_off_host_but_is_kept_on_host() raises:
    # --- off-host: the token must be DROPPED ---------------------------------
    var f = _Fixture()
    var t = ScriptedOciTransport()
    f.queue_up_to_blob_get(t)
    t.queue(
        _redirect(
            307,
            String("https://") + _CDN + String("/signed/abc?sig=signed-token"),
        )
    )
    t.queue(_blob_ok(f.config_bytes.copy()))
    f.queue_tail(t)

    var copier = OciCopier[ScriptedOciTransport](
        t^, String("src-tok"), String("dst-tok")
    )
    var _confirmed = copier.copy_by_digest(f.src_ref(), f.dst_ref())

    ref log = copier.transport()
    assert_equal(
        log.call_registry(4), _CDN, "an ABSOLUTE location changes the host"
    )
    assert_equal(
        log.call_path(4),
        String("/signed/abc?sig=signed-token"),
        "the query string survives the split — it is the CDN's signature",
    )
    assert_equal(
        log.call_auth(4),
        String(""),
        "THE REGISTRY BEARER IS NOT SENT TO A THIRD-PARTY HOST — forwarding it"
        " leaks the credential, and several object stores 400 on a request"
        " carrying both a bearer and their own signature",
    )
    assert_equal(
        log.call_auth(3),
        String("Bearer src-tok"),
        "...while the ORIGINAL request to the registry did carry it",
    )

    # --- same-host: the token must be KEPT (Artifact Registry's shape) --------
    var f2 = _Fixture()
    var t2 = ScriptedOciTransport()
    f2.queue_up_to_blob_get(t2)
    t2.queue(_redirect(302, String(_AR_DOWNLOAD)))
    t2.queue(_blob_ok(f2.config_bytes.copy()))
    f2.queue_tail(t2)

    var copier2 = OciCopier[ScriptedOciTransport](
        t2^, String("src-tok"), String("dst-tok")
    )
    var _c2 = copier2.copy_by_digest(f2.src_ref(), f2.dst_ref())
    ref log2 = copier2.transport()
    assert_equal(
        log2.call_auth(4),
        String("Bearer src-tok"),
        "a SAME-HOST hop keeps the bearer — dropping it unconditionally would"
        " break every registry that redirects within itself and still"
        " authorizes",
    )
    print("  test_bearer_is_not_forwarded_off_host_but_is_kept_on_host: PASS")


# =============================================================================
# (3) A -> B -> B does not walk the token onto B.
# =============================================================================


def test_bearer_is_not_reattached_when_a_later_hop_matches_a_previous_hop() raises:
    var f = _Fixture()
    var t = ScriptedOciTransport()
    f.queue_up_to_blob_get(t)
    # hop 1: registry -> CDN.   hop 2: CDN -> CDN (a relative location).
    t.queue(_redirect(302, String("https://") + _CDN + String("/first")))
    t.queue(_redirect(302, String("/second")))
    t.queue(_blob_ok(f.config_bytes.copy()))
    f.queue_tail(t)

    var copier = OciCopier[ScriptedOciTransport](
        t^, String("src-tok"), String("dst-tok")
    )
    var _confirmed = copier.copy_by_digest(f.src_ref(), f.dst_ref())

    ref log = copier.transport()
    assert_equal(log.call_registry(4), _CDN, "hop 1 landed on the CDN")
    assert_equal(log.call_registry(5), _CDN, "hop 2 stayed on the CDN")
    assert_equal(
        log.call_path(5),
        String("/second"),
        "the relative location resolved against the CDN, not the registry",
    )
    assert_equal(
        log.call_auth(5),
        String(""),
        "THE TOKEN IS COMPARED AGAINST THE ORIGINAL HOST, NOT THE PREVIOUS ONE"
        " — comparing against the previous hop would call this hop 'same host'"
        " and hand the registry credential to the CDN",
    )
    print(
        "  test_bearer_is_not_reattached_when_a_later_hop_matches_a_previous_hop:"
        " PASS"
    )


# =============================================================================
# (4) A redirect LOOP terminates.
# =============================================================================


def test_redirect_loop_is_bounded() raises:
    var f = _Fixture()
    var t = ScriptedOciTransport()
    f.queue_up_to_blob_get(t)
    # Ten hops that each point at the next — more than the budget allows.
    for _i in range(10):
        t.queue(_redirect(302, String("/round-and-round")))

    var copier = OciCopier[ScriptedOciTransport](
        t^, String("src-tok"), String("dst-tok")
    )
    with assert_raises(contains="exceeded"):
        var _c = copier.copy_by_digest(f.src_ref(), f.dst_ref())
    print("  test_redirect_loop_is_bounded: PASS")


# =============================================================================
# (5) A plaintext redirect is REFUSED.
# =============================================================================


def test_plaintext_redirect_is_refused() raises:
    var f = _Fixture()
    var t = ScriptedOciTransport()
    f.queue_up_to_blob_get(t)
    t.queue(_redirect(302, String("http://") + _CDN + String("/cleartext")))
    t.queue(_blob_ok(f.config_bytes.copy()))

    var copier = OciCopier[ScriptedOciTransport](
        t^, String("src-tok"), String("dst-tok")
    )
    # NOT silently upgraded to https, and NOT followed: refused by name.
    with assert_raises(contains="PLAINTEXT"):
        var _c = copier.copy_by_digest(f.src_ref(), f.dst_ref())
    print("  test_plaintext_redirect_is_refused: PASS")


# =============================================================================
# (6) A NON-redirect status is still returned untouched — the callers use status
#     as control flow, and a 404 that stopped meaning "not there" would break
#     the HEAD-then-upload path this module is built on.
# =============================================================================


def test_a_missing_blob_still_reports_404_not_a_redirect_error() raises:
    var f = _Fixture()
    var t = ScriptedOciTransport()
    f.queue_up_to_blob_get(t)
    t.queue(_status(404))  # the source does not have the blob either

    var copier = OciCopier[ScriptedOciTransport](
        t^, String("src-tok"), String("dst-tok")
    )
    with assert_raises(contains="returned HTTP 404"):
        var _c = copier.copy_by_digest(f.src_ref(), f.dst_ref())
    print("  test_a_missing_blob_still_reports_404_not_a_redirect_error: PASS")


def main() raises:
    test_blob_get_follows_redirect_and_uploads_the_redirected_bytes()
    test_bearer_is_not_forwarded_off_host_but_is_kept_on_host()
    test_bearer_is_not_reattached_when_a_later_hop_matches_a_previous_hop()
    test_redirect_loop_is_bounded()
    test_plaintext_redirect_is_refused()
    test_a_missing_blob_still_reports_404_not_a_redirect_error()
    print("test_oci_copy_blob_redirect: ALL PASS")
