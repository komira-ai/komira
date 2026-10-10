# =============================================================================
# test_oci_push_steps.mojo — LayoutPusher, one step at a time, over a SCRIPTED
#   conversation: every answer the registry gives is named in the test, so each
#   row reaches exactly one decision.
# =============================================================================
#
#   (1) HEAD manifest: a 401 is FAILED with the scope and the registry's own
#       challenge; a 400 is FAILED without them; a transport fault is FAILED;
#   (2) reading the tag: a malformed Docker-Content-Digest is unreadable
#       (FAILED before anything is sent); with no digest header the tag is
#       GET: 404 means absent, any other non-200 is unreadable;
#   (3) blobs: a 401 on the blob HEAD names the scope; a session that cannot
#       be opened is FAILED; a blob PUT answered 403 names the scope; a blob
#       PUT transport fault gets a NEW session;
#   (4) the manifest PUT: 401 (with words), 400 (without), a 201 confirming
#       another digest, and a transport fault (INDETERMINATE);
#   (5) the tag PUT: a 201 confirming another digest is INDETERMINATE; a
#       transport fault with an unreadable tag is INDETERMINATE;
#   (6) read-back: the HEAD by digest answering non-200, answering another
#       digest, or faulting, and a tag that does not read back, are each
#       INDETERMINATE;
#   (7) a retry sleeps `backoff_ms * attempt` before it is sent.
#
# Hermetic: ScriptedOciTransport, a real layout directory under TEST_TMPDIR.
# =============================================================================

from std.os import getenv
from std.time import perf_counter_ns
from std.testing import assert_equal, assert_true

from komira_http_core.codec.types import (
    HTTP_METHOD_GET,
    HTTP_METHOD_HEAD,
    HTTP_METHOD_POST,
    HTTP_METHOD_PUT,
)

from komira_oci.oci_auth import OciAuth
from komira_oci.oci_layout_fixture import write_test_layout
from komira_oci.oci_layout_reader import OciLayout, read_oci_layout
from komira_oci.oci_push import (
    LayoutPusher,
    MAX_SEND_ATTEMPTS,
    PUSH_FAILED,
    PUSH_INDETERMINATE,
    PUSH_NOOP,
    PushResult,
    push_outcome_name,
)
from komira_oci.oci_transport import OciResponse, ScriptedOciTransport

comptime _HOST: String = "us-central1-docker.pkg.dev"
comptime _REPO: String = "acme-prod/images/orders"
comptime _TAG: String = "v1.2.3"
comptime _CHALLENGE: String = 'Bearer realm="https://auth.example/token",scope="repository:acme-prod/images/orders:push"'
comptime _OTHER: String = "sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
comptime _SCOPE: String = "pushing needs the scope 'repository:acme-prod/images/orders:pull,push'"


def _bytes(s: String) -> List[UInt8]:
    var out = List[UInt8]()
    var src = s.as_bytes()
    for i in range(len(src)):
        out.append(src[i])
    return out^


def _layout() raises -> OciLayout:
    var dir = getenv("TEST_TMPDIR", "/tmp") + String("/komira_oci_push_steps")
    var layers = List[List[UInt8]]()
    layers.append(_bytes(String("steps-layer-one-aaaaaaaa")))
    layers.append(_bytes(String("steps-layer-two-bbbbbbbbbbbb")))
    _ = write_test_layout(dir, layers)
    return read_oci_layout(dir)


def _st(code: Int) -> OciResponse:
    return OciResponse(code)


def _denied(code: Int) -> OciResponse:
    var r = OciResponse(code)
    r.with_header(String("www-authenticate"), String(_CHALLENGE))
    return r^


def _digest_header(code: Int, digest: String) -> OciResponse:
    var r = OciResponse(code)
    r.with_header(String("docker-content-digest"), digest.copy())
    return r^


def _session() -> OciResponse:
    var r = OciResponse(202)
    r.with_header(
        String("location"), String("/v2/") + _REPO + String("/blobs/uploads/s1")
    )
    return r^


def _pusher(var t: ScriptedOciTransport, backoff_ms: Int = 0) -> LayoutPusher[ScriptedOciTransport]:
    return LayoutPusher[ScriptedOciTransport](
        t^, OciAuth.bearer(String("cred-q7xT")), False, backoff_ms
    )


def _expect(r: PushResult, outcome: Int, needle: String, why: String) raises:
    assert_true(
        r.outcome == outcome,
        why
        + String(": expected ")
        + push_outcome_name(outcome)
        + String(" but got ")
        + push_outcome_name(r.outcome)
        + String(": ")
        + r.detail,
    )
    assert_true(
        r.detail.find(needle) >= 0,
        why + String(": expected '") + needle + String("' in: ") + r.detail,
    )
    assert_true(
        r.detail.find(String("cred-q7xT")) < 0,
        why + String(": the credential is never in the detail"),
    )


# ---- the opening of a tag push whose tag is absent ----------------------------


def _tag_absent(mut t: ScriptedOciTransport):
    t.queue(_st(404))  # 0 HEAD tag


def _manifest_absent_blobs_present(mut t: ScriptedOciTransport):
    _tag_absent(t)
    t.queue(_st(404))  # 1 HEAD manifest by digest
    t.queue(_st(200))  # 2 HEAD layer one
    t.queue(_st(200))  # 3 HEAD layer two
    t.queue(_st(200))  # 4 HEAD config


# =============================================================================
# (1) HEAD manifest
# =============================================================================


def test_head_manifest_refusals() raises:
    var layout = _layout()

    var t = ScriptedOciTransport()
    _tag_absent(t)
    t.queue(_denied(401))
    var p = _pusher(t^)
    var r = p.push(layout, _HOST, _REPO, _TAG)
    _expect(r, PUSH_FAILED, String("HEAD manifest returned HTTP 401: the registry ") + _HOST, String("401"))
    _expect(r, PUSH_FAILED, String(_SCOPE), String("401 scope"))
    _expect(r, PUSH_FAILED, String("The registry's challenge: ") + _CHALLENGE, String("401 challenge"))

    var t2 = ScriptedOciTransport()
    _tag_absent(t2)
    t2.queue(_denied(400))
    var p2 = _pusher(t2^)
    var r2 = p2.push(layout, _HOST, _REPO, _TAG)
    _expect(r2, PUSH_FAILED, String("HEAD manifest returned HTTP 400"), String("400"))
    assert_equal(r2.detail, String("HEAD manifest returned HTTP 400"), "a 400 is not a credential refusal")

    var t3 = ScriptedOciTransport()
    _tag_absent(t3)  # then nothing: every HEAD manifest attempt faults
    var p3 = _pusher(t3^)
    var r3 = p3.push(layout, _HOST, _REPO, _TAG)
    _expect(r3, PUSH_FAILED, String("HEAD manifest failed: ScriptedOciTransport.send"), String("fault"))
    assert_equal(p3.transport().call_count(), 1 + MAX_SEND_ATTEMPTS, "the fault was retried, bounded")
    print("  test_head_manifest_refusals: PASS")


# =============================================================================
# (2) reading the tag
# =============================================================================


def test_tag_read_paths() raises:
    var layout = _layout()

    # A malformed digest header: unreadable, FAILED before any write.
    var t = ScriptedOciTransport()
    t.queue(_digest_header(200, String("sha256:XYZ")))
    var p = _pusher(t^)
    var r = p.push(layout, _HOST, _REPO, _TAG)
    _expect(r, PUSH_FAILED, String("could not read the tag before pushing: oci: malformed digest"), String("bad header"))
    assert_equal(p.transport().call_count(), 1)

    # No digest header, and the GET says 404: the tag is absent, so the push
    # goes on to HEAD the manifest.
    var t2 = ScriptedOciTransport()
    t2.queue(_st(200))  # 0 HEAD tag: present, no digest header
    t2.queue(_st(404))  # 1 GET tag: gone
    t2.queue(_st(400))  # 2 HEAD manifest
    var p2 = _pusher(t2^)
    var r2 = p2.push(layout, _HOST, _REPO, _TAG)
    _expect(r2, PUSH_FAILED, String("HEAD manifest returned HTTP 400"), String("GET 404"))
    assert_equal(p2.transport().call_method(1), HTTP_METHOD_GET)
    assert_true(p2.transport().call_path(2).find(layout.manifest_digest) >= 0)

    # No digest header, and the GET says 400: unreadable.
    var t3 = ScriptedOciTransport()
    t3.queue(_st(200))
    t3.queue(_st(400))
    var p3 = _pusher(t3^)
    var r3 = p3.push(layout, _HOST, _REPO, _TAG)
    _expect(r3, PUSH_FAILED, String("could not read the tag before pushing: GET tag returned HTTP 400"), String("GET 400"))
    assert_equal(p3.transport().call_count(), 2)
    print("  test_tag_read_paths: PASS")


# =============================================================================
# (3) blobs
# =============================================================================


def test_blob_step_refusals() raises:
    var layout = _layout()
    var first = layout.push_blobs()[0].digest.copy()

    var t = ScriptedOciTransport()
    _tag_absent(t)
    t.queue(_st(404))  # HEAD manifest
    t.queue(_denied(401))  # HEAD layer one
    var p = _pusher(t^)
    var r = p.push(layout, _HOST, _REPO, _TAG)
    _expect(r, PUSH_FAILED, String("HEAD blob ") + first + String(" returned HTTP 401: the registry"), String("blob HEAD 401"))
    _expect(r, PUSH_FAILED, String(_SCOPE), String("blob HEAD 401 scope"))

    var t2 = ScriptedOciTransport()
    _tag_absent(t2)
    t2.queue(_st(404))  # HEAD manifest
    t2.queue(_st(404))  # HEAD layer one; then every POST faults
    var p2 = _pusher(t2^)
    var r2 = p2.push(layout, _HOST, _REPO, _TAG)
    _expect(r2, PUSH_FAILED, String("opening an upload session failed: ScriptedOciTransport"), String("session fault"))

    var t3 = ScriptedOciTransport()
    _tag_absent(t3)
    t3.queue(_st(404))
    t3.queue(_st(404))
    t3.queue(_session())  # 3 POST
    t3.queue(_denied(403))  # 4 PUT blob
    var p3 = _pusher(t3^)
    var r3 = p3.push(layout, _HOST, _REPO, _TAG)
    _expect(r3, PUSH_FAILED, String("PUT blob ") + first + String(" returned HTTP 403: the registry"), String("blob PUT 403"))
    _expect(r3, PUSH_FAILED, String("The registry's challenge: ") + _CHALLENGE, String("blob PUT 403 challenge"))
    assert_equal(p3.transport().call_count(), 5, "a 403 without retry_forbidden is final")

    # A transport fault on the PUT is transient: a NEW session is opened.
    var t4 = ScriptedOciTransport()
    _tag_absent(t4)
    t4.queue(_st(404))
    t4.queue(_st(404))
    t4.queue(_session())  # 3 POST; then the PUT and everything after fault
    var p4 = _pusher(t4^)
    var r4 = p4.push(layout, _HOST, _REPO, _TAG)
    _expect(r4, PUSH_FAILED, String("opening an upload session failed"), String("PUT fault"))
    assert_equal(p4.transport().call_method(4), HTTP_METHOD_PUT)
    assert_equal(p4.transport().call_method(5), HTTP_METHOD_POST, "a faulted PUT gets a new session")
    print("  test_blob_step_refusals: PASS")


# =============================================================================
# (4) the manifest PUT
# =============================================================================


def test_manifest_put_refusals() raises:
    var layout = _layout()

    var t = ScriptedOciTransport()
    _manifest_absent_blobs_present(t)
    t.queue(_denied(401))  # 5 PUT manifest
    var p = _pusher(t^)
    var r = p.push(layout, _HOST, _REPO, _TAG)
    _expect(
        r,
        PUSH_FAILED,
        String("PUT manifest ") + layout.manifest_digest + String(" returned HTTP 401: the registry"),
        String("manifest PUT 401"),
    )
    _expect(r, PUSH_FAILED, String("The registry's challenge: ") + _CHALLENGE, String("manifest PUT 401 challenge"))

    var t2 = ScriptedOciTransport()
    _manifest_absent_blobs_present(t2)
    t2.queue(_denied(400))
    var p2 = _pusher(t2^)
    var r2 = p2.push(layout, _HOST, _REPO, _TAG)
    _expect(r2, PUSH_FAILED, String(" returned HTTP 400"), String("manifest PUT 400"))
    assert_true(r2.detail.find(String("the registry")) < 0, "a 400 carries no credential words: " + r2.detail)

    var t3 = ScriptedOciTransport()
    _manifest_absent_blobs_present(t3)
    t3.queue(_digest_header(201, String(_OTHER)))
    var p3 = _pusher(t3^)
    var r3 = p3.push(layout, _HOST, _REPO, _TAG)
    _expect(
        r3,
        PUSH_FAILED,
        String("the registry stored the manifest as ") + _OTHER + String(" but it is ") + layout.manifest_digest,
        String("manifest PUT confirms another digest"),
    )

    var t4 = ScriptedOciTransport()
    _manifest_absent_blobs_present(t4)  # then the PUT faults, every attempt
    var p4 = _pusher(t4^)
    var r4 = p4.push(layout, _HOST, _REPO, _TAG)
    _expect(r4, PUSH_INDETERMINATE, String("PUT manifest: the outcome could not be read"), String("manifest PUT fault"))
    print("  test_manifest_put_refusals: PASS")


# =============================================================================
# (5) the tag PUT
# =============================================================================


def _manifest_present(mut t: ScriptedOciTransport):
    _tag_absent(t)
    t.queue(_st(200))  # 1 HEAD manifest: present, so no blob is touched


def test_tag_put_refusals() raises:
    var layout = _layout()

    var t = ScriptedOciTransport()
    _manifest_present(t)
    t.queue(_digest_header(201, String(_OTHER)))  # 2 PUT tag
    var p = _pusher(t^)
    var r = p.push(layout, _HOST, _REPO, _TAG)
    _expect(
        r,
        PUSH_INDETERMINATE,
        String("the registry tagged ") + _OTHER + String(" but the image is ") + layout.manifest_digest,
        String("tag PUT confirms another digest"),
    )
    assert_equal(p.transport().call_count(), 3, "no read-back after a wrong confirmation")

    var t2 = ScriptedOciTransport()
    _manifest_present(t2)  # then the tag PUT and the tag read fault
    var p2 = _pusher(t2^)
    var r2 = p2.push(layout, _HOST, _REPO, _TAG)
    _expect(
        r2,
        PUSH_INDETERMINATE,
        String("the tag PUT failed (HTTP -1) and the tag could not be read: ScriptedOciTransport"),
        String("tag PUT fault"),
    )
    assert_equal(p2.transport().call_count(), 3 + MAX_SEND_ATTEMPTS, "one PUT, then the bounded tag read")
    print("  test_tag_put_refusals: PASS")


# =============================================================================
# (6) read-back
# =============================================================================


def test_read_back_refusals() raises:
    var layout = _layout()
    var d = layout.manifest_digest.copy()

    # By digest: 0 HEAD manifest present, 1 the read-back HEAD.
    var t = ScriptedOciTransport()
    t.queue(_st(200))
    t.queue(_st(404))
    var p = _pusher(t^)
    _expect(
        p.push_by_digest(layout, _HOST, _REPO, d),
        PUSH_INDETERMINATE,
        String("read-back: HEAD manifest by digest returned HTTP 404"),
        String("read-back 404"),
    )

    var t2 = ScriptedOciTransport()
    t2.queue(_st(200))
    t2.queue(_digest_header(200, String(_OTHER)))
    var p2 = _pusher(t2^)
    _expect(
        p2.push_by_digest(layout, _HOST, _REPO, d),
        PUSH_INDETERMINATE,
        String("read-back: the registry serves ") + _OTHER + String(" at ") + d,
        String("read-back another digest"),
    )

    var t3 = ScriptedOciTransport()
    t3.queue(_st(200))  # then the read-back faults
    var p3 = _pusher(t3^)
    _expect(
        p3.push_by_digest(layout, _HOST, _REPO, d),
        PUSH_INDETERMINATE,
        String("read-back failed: ScriptedOciTransport"),
        String("read-back fault"),
    )

    # Tagged: the tag PUT succeeds, the digest reads back, the tag does not.
    var t4 = ScriptedOciTransport()
    _manifest_present(t4)
    t4.queue(_st(201))  # 2 PUT tag
    t4.queue(_digest_header(200, d))  # 3 read-back HEAD by digest
    t4.queue(_st(404))  # 4 read-back HEAD tag
    var p4 = _pusher(t4^)
    _expect(
        p4.push(layout, _HOST, _REPO, _TAG),
        PUSH_INDETERMINATE,
        String("read-back: the tag '") + _TAG + String("' does not read back as ") + d,
        String("tag does not read back"),
    )
    print("  test_read_back_refusals: PASS")


# =============================================================================
# (7) the backoff
# =============================================================================


def test_retry_sleeps_the_backoff() raises:
    var layout = _layout()
    var t = ScriptedOciTransport()
    t.queue(_st(503))  # 0 HEAD manifest: retried after backoff_ms * 1
    t.queue(_st(200))  # 1 HEAD manifest: present
    t.queue(_digest_header(200, layout.manifest_digest))  # 2 read-back
    var p = _pusher(t^, 100)
    var start = perf_counter_ns()
    var r = p.push_by_digest(layout, _HOST, _REPO, layout.manifest_digest)
    var elapsed_ms = Int(perf_counter_ns() - start) // 1_000_000
    _expect(r, PUSH_NOOP, String(""), String("a retried HEAD"))
    assert_equal(p.transport().call_count(), 3)
    assert_true(
        elapsed_ms >= 100,
        String("one retry sleeps at least 100 ms; slept ") + String(elapsed_ms),
    )
    print("  test_retry_sleeps_the_backoff: PASS")


def main() raises:
    test_head_manifest_refusals()
    test_tag_read_paths()
    test_blob_step_refusals()
    test_manifest_put_refusals()
    test_tag_put_refusals()
    test_read_back_refusals()
    test_retry_sleeps_the_backoff()
    print("test_oci_push_steps: ALL PASS")
